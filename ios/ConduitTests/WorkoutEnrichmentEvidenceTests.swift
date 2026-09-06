import XCTest
import HealthKit
import GRDB
@testable import Conduit

/// End-to-end evidence for workout-payload enrichment (brand/indoor labels,
/// laps/segments/pauses, avg/max/min heart rate) — the iOS half of the change
/// whose server-side half (proto, ingester, OpenSearch mapping) already shipped
/// and is live in production.
///
/// Drives a real, enriched `HKWorkout` through the app's ACTUAL capture path —
/// `AnchoredReader.makeSample` → `OutboxDAO.ingest` → `Batcher.buildBatch` —
/// and asserts on the decoded envelope, exactly the model `RunningDynamicsEvidenceTests`
/// uses. Writes the JSON body to `CONDUIT_EVIDENCE_DIR` (when set) for pasting
/// into the ingester's own end-to-end test, so both halves are proven to
/// actually meet.
///
/// **What this test can and cannot prove about heart-rate statistics.**
/// `HKWorkout.statistics(for:)` is populated only by `HKWorkoutBuilder`/
/// `HKLiveWorkoutBuilder` — a workout built with the deprecated
/// `workoutWithActivityType:...:metadata:` initializer (the only way to
/// construct one outside a live, authorized `HKHealthStore`) never carries any.
/// So this test's workout legitimately has no HR statistics, and asserts their
/// ABSENCE on the wire — it is not evidence that a real Apple Watch workout
/// populates them. `AnchoredReaderTests.testHeartRateStatisticsMapWhenPresentAndAreAbsentWhenNil`
/// covers the presence branch against the pure `makeWorkoutValue` core with
/// plain values; only a real device can confirm HealthKit actually populates
/// `statistics(for:)` for a genuine Watch workout.
final class WorkoutEnrichmentEvidenceTests: XCTestCase {

    func testEnrichedWorkoutReachesTheWebhookPayload() throws {
        let db = try AppDatabase.makeInMemory()
        var webhook = WebhookConfig.makeDefault(
            url: "https://health.noebrito.dev/webhook",
            bearerTokenKeychainRef: "webhook_bearer_token"
        )
        try WebhookConfigDAO(db).save(&webhook)
        let webhookID = try XCTUnwrap(webhook.id)
        let outbox = OutboxDAO(db)

        // A fixed morning run so the artifact is byte-stable across runs.
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let end = start.addingTimeInterval(1800)

        let events = [
            HKWorkoutEvent(
                type: .lap,
                dateInterval: DateInterval(start: start, duration: 600),
                metadata: nil
            ),
            HKWorkoutEvent(
                type: .pause,
                dateInterval: DateInterval(start: start.addingTimeInterval(600), duration: 0),
                metadata: nil
            ),
            HKWorkoutEvent(
                type: .resume,
                dateInterval: DateInterval(start: start.addingTimeInterval(660), duration: 0),
                metadata: nil
            ),
        ]

        let workout = HKWorkout(
            activityType: .running,
            start: start,
            end: end,
            workoutEvents: events,
            totalEnergyBurned: HKQuantity(unit: .kilocalorie(), doubleValue: 320),
            totalDistance: HKQuantity(unit: .meter(), doubleValue: 5000),
            metadata: [
                HKMetadataKeyWorkoutBrandName: "Orangetheory",
                HKMetadataKeyIndoorWorkout: true,
            ]
        )

        let sample = try XCTUnwrap(
            AnchoredReader.makeSample(from: workout, type: .workout),
            "an enriched HKWorkout did not map to a wire sample"
        )

        // The mapping itself (brand/indoor/events) — asserted here so a broken
        // capture path fails loudly before the envelope round-trip below.
        XCTAssertEqual(sample.workout.activityType, "running")
        XCTAssertEqual(sample.workout.brandName, "Orangetheory")
        XCTAssertTrue(sample.workout.hasIsIndoor)
        XCTAssertTrue(sample.workout.isIndoor)
        XCTAssertEqual(sample.workout.events.map(\.type), ["lap", "pause", "resume"])
        // Cannot be fabricated outside a live HKWorkoutBuilder — see the class
        // doc comment. Asserting absence pins the honest-absence contract.
        XCTAssertFalse(sample.workout.hasAvgHeartRateBpm)
        XCTAssertFalse(sample.workout.hasMaxHeartRateBpm)
        XCTAssertFalse(sample.workout.hasMinHeartRateBpm)

        _ = try outbox.ingest(
            samples: [sample],
            hkTypeId: HealthDataType.workout.identifier,
            webhookId: webhookID,
            anchorBlob: Data("anchor-workout".utf8)
        )

        // The real batcher builds the body the background URLSession POSTs.
        let batch = try XCTUnwrap(
            Batcher(database: db).buildBatch(
                webhookID: webhookID,
                limit: 500,
                deviceID: "evidence-device",
                now: end.addingTimeInterval(60)
            ),
            "no batch was built from the staged enriched workout"
        )

        let envelope = try Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON)
        XCTAssertEqual(envelope.schemaVersion, "v1")

        let typeBatch = try XCTUnwrap(
            envelope.batches.first { $0.hkTypeID == HealthDataType.workout.identifier },
            "webhook body has no batch for the workout type"
        )
        XCTAssertEqual(typeBatch.samples.count, 1)
        let wire = try XCTUnwrap(typeBatch.samples.first)
        XCTAssertEqual(wire.workout.brandName, "Orangetheory")
        XCTAssertTrue(wire.workout.isIndoor)
        XCTAssertEqual(wire.workout.events.count, 3)

        try writeArtifact(prettyPrint(batch.encodedJSON), named: "webhook-payload-workout-enrichment.json")
    }
}
