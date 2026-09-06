import XCTest
import HealthKit
import GRDB
@testable import Conduit

/// Tests for the HealthKit-deletion honoring path at the seam we can exercise
/// without a live `HKHealthStore`.
///
/// The one piece that genuinely needs HealthKit — mapping the anchored query's
/// `[HKDeletedObject]` into `Result.deletedUuids` — is untestable in a unit test
/// (`HKDeletedObject` has no public initializer, and ConduitTests never touch
/// live HealthKit). So these tests pin the observable contract instead: a
/// `Result` carries deleted uuids, and those uuids flow end-to-end through
/// `OutboxDAO.ingest` → `Batcher` into the envelope's `deleted_uuids`, which is
/// what actually reaches the ingester.
final class AnchoredReaderTests: XCTestCase {
    private var db: AppDatabase!
    private var webhookID: Int64!
    private let heartRateID = HealthDataType.heartRate.identifier

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        var wh = WebhookConfig.makeDefault(url: "https://example.com/hook", bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(db).save(&wh)
        webhookID = try XCTUnwrap(wh.id)
    }

    private func makeSample(uuid: String) -> Conduit_V1_Sample {
        var s = Conduit_V1_Sample()
        s.uuid = uuid
        s.startUnixMs = 1_000
        s.endUnixMs = 2_000
        var q = Conduit_V1_QuantityValue(); q.value = 60; q.unit = "count/min"
        s.quantity = q
        return s
    }

    /// A `Result` surfaces deleted uuids alongside its samples — the field the
    /// anchored query now populates from `deletedObjects`.
    func testResultCarriesDeletedUuids() {
        let result = AnchoredReader.Result(
            samples: [makeSample(uuid: "live")],
            deletedUuids: ["ghost-a", "ghost-b"],
            newAnchor: nil
        )
        XCTAssertEqual(result.deletedUuids, ["ghost-a", "ghost-b"])
        XCTAssertEqual(result.samples.map(\.uuid), ["live"])
    }

    /// The deletion surfaces end-to-end: staging a `Result`'s deletedUuids via
    /// `ingest`, then batching, yields an envelope whose `deleted_uuids` carries
    /// the ghost — exactly what the ingester turns into a bulk delete.
    func testDeletionFlowsThroughIngestAndBatchIntoEnvelope() throws {
        let result = AnchoredReader.Result(
            samples: [makeSample(uuid: "fat-new")],
            deletedUuids: ["fat-ghost"],
            newAnchor: nil
        )

        let outbox = OutboxDAO(db)
        _ = try outbox.ingest(
            samples: result.samples,
            hkTypeId: heartRateID,
            webhookId: webhookID,
            anchorBlob: Data([0x01]),
            deletedUuids: result.deletedUuids
        )

        let batch = try XCTUnwrap(
            Batcher(database: db).buildBatch(webhookID: webhookID, limit: 100, deviceID: "dev-1")
        )
        let envelope = try Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON)
        let typeBatch = try XCTUnwrap(envelope.batches.first { $0.hkTypeID == heartRateID })
        XCTAssertEqual(typeBatch.samples.map(\.uuid), ["fat-new"])
        XCTAssertEqual(typeBatch.deletedUuids, ["fat-ghost"])
    }

    /// No deletions ⇒ an empty `deletedUuids`, and the staged/batched output is
    /// exactly what it was before the feature existed (no tombstone rows, empty
    /// deleted_uuids). Guards the additive contract at the iOS seam.
    func testNoDeletionsLeavesEnvelopeUnchanged() throws {
        let outbox = OutboxDAO(db)
        _ = try outbox.ingest(
            samples: [makeSample(uuid: "s1")],
            hkTypeId: heartRateID,
            webhookId: webhookID,
            anchorBlob: Data([0x01]),
            deletedUuids: []
        )
        XCTAssertEqual(try outbox.totalCount(), 1, "no tombstone rows when there are no deletions")

        let batch = try XCTUnwrap(
            Batcher(database: db).buildBatch(webhookID: webhookID, limit: 100, deviceID: "dev-1")
        )
        let envelope = try Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON)
        XCTAssertTrue(envelope.batches.allSatisfy { $0.deletedUuids.isEmpty })
    }

    // MARK: - Workout enrichment: makeWorkoutValue (pure core)

    /// Real, ordered `HKWorkoutEvent`s (lap with a nonzero duration, an instant
    /// pause, a segment with a nonzero duration) map to the correct type
    /// strings and start/end, and the mapper preserves the given order rather
    /// than re-sorting (HealthKit already hands them back ascending).
    func testWorkoutEventsAreMappedInOrder() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let lap = HKWorkoutEvent(
            type: .lap,
            dateInterval: DateInterval(start: start, duration: 300),
            metadata: nil
        )
        let pause = HKWorkoutEvent(
            type: .pause,
            dateInterval: DateInterval(start: start.addingTimeInterval(300), duration: 0),
            metadata: nil
        )
        let segment = HKWorkoutEvent(
            type: .segment,
            dateInterval: DateInterval(start: start.addingTimeInterval(600), duration: 120),
            metadata: nil
        )

        let value = AnchoredReader.makeWorkoutValue(
            activityType: "running",
            durationSeconds: 720,
            totalEnergyKcal: 500,
            totalDistanceM: 5000,
            brandName: nil,
            isIndoor: nil,
            avgHeartRateBpm: nil,
            maxHeartRateBpm: nil,
            minHeartRateBpm: nil,
            events: [lap, pause, segment]
        )

        XCTAssertEqual(value.events.map(\.type), ["lap", "pause", "segment"])
        XCTAssertEqual(value.events[0].startUnixMs, AnchoredReader.unixMillis(start))
        XCTAssertEqual(value.events[0].endUnixMs, AnchoredReader.unixMillis(start.addingTimeInterval(300)))
        XCTAssertGreaterThan(value.events[0].endUnixMs, value.events[0].startUnixMs, "a lap carries a nonzero duration")
        XCTAssertEqual(value.events[1].startUnixMs, value.events[1].endUnixMs, "an instant event has end == start")
        XCTAssertGreaterThan(value.events[2].endUnixMs, value.events[2].startUnixMs, "a segment carries a nonzero duration")
    }

    /// `@unknown default` falls back to a stable, unambiguous numeric name
    /// rather than crashing or silently dropping the event — the same pattern
    /// `workoutActivityName`/`categoryValueName` already use.
    func testUnknownWorkoutEventTypeFallsBackToNumericName() {
        let bogus = try! XCTUnwrap(HKWorkoutEventType(rawValue: 999))
        XCTAssertEqual(AnchoredReader.workoutEventTypeName(bogus), "eventType999")
    }

    /// No events ⇒ an empty `repeated`, and the wire JSON omits the field
    /// entirely rather than emitting `"events":[]`.
    func testWorkoutWithNoEventsEmitsNoEvents() throws {
        let value = AnchoredReader.makeWorkoutValue(
            activityType: "yoga",
            durationSeconds: 600,
            totalEnergyKcal: 0,
            totalDistanceM: 0,
            brandName: nil,
            isIndoor: nil,
            avgHeartRateBpm: nil,
            maxHeartRateBpm: nil,
            minHeartRateBpm: nil,
            events: []
        )
        XCTAssertTrue(value.events.isEmpty)
        let json = String(decoding: try value.jsonUTF8Data(), as: UTF8.self)
        XCTAssertFalse(json.contains("events"), "an empty repeated field must be omitted from the wire JSON, not emitted as []")
    }

    /// `brand_name`/`is_indoor` present when their metadata source is non-nil,
    /// and absent (not a fabricated `""`/`false`) when it isn't — most Apple
    /// Watch workouts carry neither, which is the expected steady state.
    func testBrandNameAndIndoorFlagFromMetadata() {
        let present = AnchoredReader.makeWorkoutValue(
            activityType: "running", durationSeconds: 600, totalEnergyKcal: 0, totalDistanceM: 0,
            brandName: "Orangetheory", isIndoor: true,
            avgHeartRateBpm: nil, maxHeartRateBpm: nil, minHeartRateBpm: nil, events: []
        )
        XCTAssertEqual(present.brandName, "Orangetheory")
        XCTAssertTrue(present.hasIsIndoor)
        XCTAssertTrue(present.isIndoor)

        let absent = AnchoredReader.makeWorkoutValue(
            activityType: "running", durationSeconds: 600, totalEnergyKcal: 0, totalDistanceM: 0,
            brandName: nil, isIndoor: nil,
            avgHeartRateBpm: nil, maxHeartRateBpm: nil, minHeartRateBpm: nil, events: []
        )
        XCTAssertEqual(absent.brandName, "", "most Apple Watch workouts carry no brand — empty is the honest steady state")
        XCTAssertFalse(absent.hasIsIndoor, "absent (the writer didn't say) must differ from an explicit false")
    }

    /// avg/max/min heart-rate statistics are set only when their source is
    /// non-nil — an explicit `0` bpm (a genuine reading) must stay present,
    /// and a workout with no HR samples must not fabricate one.
    func testHeartRateStatisticsMapWhenPresentAndAreAbsentWhenNil() {
        let present = AnchoredReader.makeWorkoutValue(
            activityType: "running", durationSeconds: 600, totalEnergyKcal: 0, totalDistanceM: 0,
            brandName: nil, isIndoor: nil,
            avgHeartRateBpm: 148.2, maxHeartRateBpm: 176, minHeartRateBpm: 0,
            events: []
        )
        XCTAssertTrue(present.hasAvgHeartRateBpm)
        XCTAssertEqual(present.avgHeartRateBpm, 148.2)
        XCTAssertTrue(present.hasMaxHeartRateBpm)
        XCTAssertEqual(present.maxHeartRateBpm, 176)
        XCTAssertTrue(present.hasMinHeartRateBpm, "an explicit 0 bpm is a real reading, not absence")
        XCTAssertEqual(present.minHeartRateBpm, 0)

        let absent = AnchoredReader.makeWorkoutValue(
            activityType: "yoga", durationSeconds: 600, totalEnergyKcal: 0, totalDistanceM: 0,
            brandName: nil, isIndoor: nil,
            avgHeartRateBpm: nil, maxHeartRateBpm: nil, minHeartRateBpm: nil,
            events: []
        )
        XCTAssertFalse(absent.hasAvgHeartRateBpm, "a workout with no HR samples must not fabricate a 0")
        XCTAssertFalse(absent.hasMaxHeartRateBpm)
        XCTAssertFalse(absent.hasMinHeartRateBpm)
    }

    /// The privacy-promise gate: turning the user's own Heart Rate data type
    /// off must suppress workout HR statistics even though Workouts stays on.
    /// No config row yet defaults to included, matching Heart Rate's own
    /// default-on registry convention — this only ever narrows on an explicit
    /// opt-out.
    func testHeartRateStatisticsSuppressedWhenHeartRateTypeDisabled() async throws {
        let engine = SyncEngine(database: db)
        let configDAO = DataTypeConfigDAO(db)

        let defaultedOn = try await engine.includeHeartRateStatisticsForWorkouts()
        XCTAssertTrue(defaultedOn, "no Heart Rate config row yet must default to included")

        try configDAO.setEnabled(false, hkTypeId: heartRateID)
        let suppressed = try await engine.includeHeartRateStatisticsForWorkouts()
        XCTAssertFalse(suppressed, "turning Heart Rate off must suppress workout HR stats")

        try configDAO.setEnabled(true, hkTypeId: heartRateID)
        let reenabled = try await engine.includeHeartRateStatisticsForWorkouts()
        XCTAssertTrue(reenabled)
    }
}
