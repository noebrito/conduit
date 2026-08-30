import XCTest
import GRDB
@testable import Conduit

final class BatcherTests: XCTestCase {
    private var db: AppDatabase!
    private var webhookID: Int64!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        var wh = WebhookConfig.makeDefault(url: "https://example.com", bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(db).save(&wh)
        webhookID = wh.id
    }

    // MARK: - Helpers

    private func makeSample(uuid: String, typeID: String) -> Conduit_V1_Sample {
        var s = Conduit_V1_Sample()
        s.uuid = uuid
        s.startUnixMs = 1_700_000_000_000
        s.endUnixMs   = 1_700_000_060_000
        var q = Conduit_V1_QuantityValue(); q.value = 72; q.unit = "count/min"
        s.quantity = q
        return s
    }

    private func enqueue(uuid: String, typeID: String) throws {
        let sample = makeSample(uuid: uuid, typeID: typeID)
        try OutboxDAO(db).enqueue(sample: sample, hkTypeId: typeID, webhookId: webhookID)
    }

    // MARK: - Empty outbox

    func test_buildBatch_emptyOutbox_returnsNil() throws {
        let batcher = Batcher(database: db)
        let result = try batcher.buildBatch(webhookID: webhookID, limit: 100, deviceID: "dev-1")
        XCTAssertNil(result)
    }

    // MARK: - Basic grouping

    func test_buildBatch_groupsByHkTypeId() throws {
        try enqueue(uuid: "hr-1", typeID: "HKQuantityTypeIdentifierHeartRate")
        try enqueue(uuid: "hr-2", typeID: "HKQuantityTypeIdentifierHeartRate")
        try enqueue(uuid: "step-1", typeID: "HKQuantityTypeIdentifierStepCount")

        let batcher = Batcher(database: db)
        let result = try XCTUnwrap(batcher.buildBatch(webhookID: webhookID, limit: 100, deviceID: "dev-1"))

        // JSON should be decodable
        let envelope = try Conduit_V1_Envelope(jsonUTF8Data: result.encodedJSON)
        XCTAssertEqual(envelope.schemaVersion, "v1")
        XCTAssertEqual(envelope.batches.count, 2)

        let hrBatch = envelope.batches.first { $0.hkTypeID == "HKQuantityTypeIdentifierHeartRate" }
        XCTAssertNotNil(hrBatch)
        XCTAssertEqual(hrBatch?.samples.count, 2)

        let stepBatch = envelope.batches.first { $0.hkTypeID == "HKQuantityTypeIdentifierStepCount" }
        XCTAssertNotNil(stepBatch)
        XCTAssertEqual(stepBatch?.samples.count, 1)
    }

    // MARK: - Rows marked inflight

    func test_buildBatch_marksRowsInflight() throws {
        try enqueue(uuid: "hr-1", typeID: "HKQuantityTypeIdentifierHeartRate")

        let batcher = Batcher(database: db)
        let result = try XCTUnwrap(batcher.buildBatch(webhookID: webhookID, limit: 100, deviceID: "dev-1"))

        let dao = OutboxDAO(db)
        let inflightCount = try dao.count(state: .inflight)
        let pendingCount  = try dao.count(state: .pending)
        XCTAssertEqual(inflightCount, 1)
        XCTAssertEqual(pendingCount,  0)
        XCTAssertEqual(result.rowIDs.count, 1)
    }

    // MARK: - inflight_at is stamped (feeds OutboxDAO.reclaimStaleInflight)

    func test_buildBatch_stampsInflightAt() throws {
        try enqueue(uuid: "hr-1", typeID: "HKQuantityTypeIdentifierHeartRate")

        // A fixed, whole-second `now` sidesteps GRDB's millisecond-precision
        // datetime storage (see SyncStateTests' note on the same footgun) —
        // round-tripping a sub-millisecond `Date()` can read back a hair below
        // the value captured just before the call.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let batcher = Batcher(database: db)
        _ = try XCTUnwrap(batcher.buildBatch(webhookID: webhookID, limit: 100, deviceID: "dev-1", now: now))

        let row = try XCTUnwrap(OutboxDAO(db).find(hkSampleUuid: "hr-1"))
        let inflightAt = try XCTUnwrap(row.inflightAt, "buildBatch must stamp inflight_at so staleness is measurable")
        XCTAssertEqual(inflightAt, now)
    }

    // MARK: - Batch size limit

    func test_buildBatch_respectsLimit() throws {
        for i in 0..<10 {
            try enqueue(uuid: "hr-\(i)", typeID: "HKQuantityTypeIdentifierHeartRate")
        }

        let batcher = Batcher(database: db)
        let result = try XCTUnwrap(batcher.buildBatch(webhookID: webhookID, limit: 4, deviceID: "dev-1"))

        XCTAssertEqual(result.rowIDs.count, 4)
        // Remaining 6 rows stay pending
        let pendingCount = try OutboxDAO(db).count(state: .pending)
        XCTAssertEqual(pendingCount, 6)
    }

    // MARK: - Batch splits (two calls)

    func test_buildBatch_secondCallDrainsRemainder() throws {
        for i in 0..<6 {
            try enqueue(uuid: "hr-\(i)", typeID: "HKQuantityTypeIdentifierHeartRate")
        }

        let batcher = Batcher(database: db)
        let first  = try XCTUnwrap(batcher.buildBatch(webhookID: webhookID, limit: 4, deviceID: "dev-1"))
        let second = try XCTUnwrap(batcher.buildBatch(webhookID: webhookID, limit: 4, deviceID: "dev-1"))

        XCTAssertNotEqual(first.batchID, second.batchID)
        XCTAssertEqual(first.rowIDs.count, 4)
        XCTAssertEqual(second.rowIDs.count, 2)
        XCTAssertEqual(try OutboxDAO(db).count(state: .pending), 0)
    }

    // MARK: - Byte ceiling

    /// Insert a pending row with an exact payload size and creation order, so the
    /// byte ceiling can be exercised without building a real multi-MiB sample.
    private func insertRow(uuid: String, bytes: Int, createdAt: Date) throws {
        try db.dbWriter.write { grdb in
            try grdb.execute(
                sql: """
                    INSERT INTO outbox
                        (webhook_id, hk_sample_uuid, hk_type_id, payload_blob,
                         created_at, state, attempt_count, next_attempt_at)
                    VALUES (?, ?, 'HKWorkoutRouteTypeIdentifier', ?, ?, 'pending', 0, NULL)
                    """,
                arguments: [webhookID, uuid, Data(repeating: 0x41, count: bytes), createdAt]
            )
        }
    }

    /// A route sample big enough to stand in for a real one: ~5k GPS points.
    private func enqueueRouteRow(uuid: String, points: Int) throws {
        var sample = Conduit_V1_Sample()
        sample.uuid = uuid
        sample.startUnixMs = 1_700_000_000_000
        sample.endUnixMs = 1_700_000_600_000
        var route = Conduit_V1_RouteValue()
        route.workoutUuid = "workout-\(uuid)"
        route.activityType = "walking"
        route.points = (0..<points).map { i in
            var p = Conduit_V1_RoutePoint()
            p.lat = 34.05 + Double(i) * 0.00001
            p.lng = -118.24 - Double(i) * 0.00001
            p.altitudeM = 100
            p.timestampUnixMs = 1_700_000_000_000 + Int64(i) * 1000
            p.horizontalAccuracyM = 5
            p.verticalAccuracyM = 3
            p.speedMps = 1.4
            p.courseDeg = 90
            return p
        }
        sample.route = route
        try OutboxDAO(db).enqueue(
            sample: sample,
            hkTypeId: "HKWorkoutRouteTypeIdentifier",
            webhookId: webhookID
        )
    }

    func test_buildBatch_splitsRouteRowsAcrossBatchesUnderCeiling() throws {
        // ~5k points each ≈ hundreds of KB per row — enough rows that the row-count
        // limit alone would build a single multi-MiB-over-cap envelope.
        for i in 0..<40 {
            try enqueueRouteRow(uuid: "route-\(i)", points: 5_000)
        }

        let batcher = Batcher(database: db)
        var batches: [Batcher.BatchResult] = []
        while let result = try batcher.buildBatch(webhookID: webhookID, limit: 500, deviceID: "dev-1") {
            batches.append(result)
        }

        XCTAssertGreaterThan(batches.count, 1, "Large route rows must split across batches")
        for batch in batches {
            XCTAssertFalse(batch.rowIDs.isEmpty, "A batch must never be empty")
            XCTAssertLessThan(
                batch.encodedJSON.count,
                16 * 1024 * 1024,
                "Every batch must stay under the ingester's 16 MiB body cap"
            )
        }
        XCTAssertEqual(batches.reduce(0) { $0 + $1.rowIDs.count }, 40, "Every row still drains")
        XCTAssertEqual(try OutboxDAO(db).count(state: .pending), 0)
    }

    func test_buildBatch_emitsSingleOverCeilingRowAloneAndKeepsDraining() throws {
        let start = Date()
        try insertRow(uuid: "huge", bytes: Batcher.maxBatchPayloadBytes + 1, createdAt: start)
        try insertRow(uuid: "small", bytes: 16, createdAt: start.addingTimeInterval(1))

        let batcher = Batcher(database: db)
        let first = try XCTUnwrap(batcher.buildBatch(webhookID: webhookID, limit: 500, deviceID: "dev-1"))
        XCTAssertEqual(first.rowIDs.count, 1, "An over-ceiling row must still be sent, alone")

        let second = try XCTUnwrap(batcher.buildBatch(webhookID: webhookID, limit: 500, deviceID: "dev-1"))
        XCTAssertEqual(second.rowIDs.count, 1, "The row behind it must not be wedged")
        XCTAssertEqual(try OutboxDAO(db).count(state: .pending), 0)
    }

    func test_buildBatch_smallRowsAreUnaffectedByTheCeiling() throws {
        let start = Date()
        for i in 0..<500 {
            try insertRow(uuid: "hr-\(i)", bytes: 200, createdAt: start.addingTimeInterval(Double(i)))
        }

        let batcher = Batcher(database: db)
        let result = try XCTUnwrap(batcher.buildBatch(webhookID: webhookID, limit: 500, deviceID: "dev-1"))

        XCTAssertEqual(result.rowIDs.count, 500, "Small rows still batch by row count alone")
        XCTAssertEqual(try OutboxDAO(db).count(state: .pending), 0)
    }

    // MARK: - Tombstones serialize into deleted_uuids

    /// A `.delete` tombstone row is serialized into its type's
    /// `SampleBatch.deleted_uuids`, not `samples`, and the batch still carries any
    /// upsert samples of the same type.
    func test_buildBatch_serializesTombstonesIntoDeletedUuids() throws {
        let hr = "HKQuantityTypeIdentifierHeartRate"
        try enqueue(uuid: "hr-live", typeID: hr)
        try db.dbWriter.write { grdb in
            try OutboxDAO.stageTombstone(grdb, hkSampleUuid: "hr-ghost", hkTypeId: hr, webhookId: webhookID, createdAt: Date())
        }

        let batcher = Batcher(database: db)
        let result = try XCTUnwrap(batcher.buildBatch(webhookID: webhookID, limit: 100, deviceID: "dev-1"))
        XCTAssertEqual(result.rowIDs.count, 2, "both the upsert and the tombstone drain in one batch")

        let envelope = try Conduit_V1_Envelope(jsonUTF8Data: result.encodedJSON)
        let hrBatch = try XCTUnwrap(envelope.batches.first { $0.hkTypeID == hr })
        XCTAssertEqual(hrBatch.samples.map(\.uuid), ["hr-live"], "the live sample rides in samples")
        XCTAssertEqual(hrBatch.deletedUuids, ["hr-ghost"], "the deletion rides in deleted_uuids")
    }

    /// An upsert-only batch leaves `deleted_uuids` empty so the wire stays
    /// byte-identical to before deletions existed.
    func test_buildBatch_upsertOnlyLeavesDeletedUuidsEmpty() throws {
        try enqueue(uuid: "hr-1", typeID: "HKQuantityTypeIdentifierHeartRate")

        let batcher = Batcher(database: db)
        let result = try XCTUnwrap(batcher.buildBatch(webhookID: webhookID, limit: 100, deviceID: "dev-1"))
        let envelope = try Conduit_V1_Envelope(jsonUTF8Data: result.encodedJSON)
        XCTAssertTrue(envelope.batches.allSatisfy { $0.deletedUuids.isEmpty },
                      "no deletions ⇒ empty deleted_uuids on every batch")
    }

    // MARK: - Rows in backoff are skipped

    func test_buildBatch_skipsRowsInBackoff() throws {
        // Enqueue a row that isn't due yet
        try db.dbWriter.write { grdb in
            try grdb.execute(
                sql: """
                    INSERT INTO outbox
                        (webhook_id, hk_sample_uuid, hk_type_id, payload_blob,
                         created_at, state, attempt_count, next_attempt_at)
                    VALUES (?, 'backoff-uuid', 'HKQuantityTypeIdentifierHeartRate', ?, ?, 'pending', 1, ?)
                    """,
                arguments: [
                    webhookID,
                    Data("{}".utf8),
                    Date(),
                    Date().addingTimeInterval(3600),  // due in 1h
                ]
            )
        }

        let batcher = Batcher(database: db)
        let result = try batcher.buildBatch(webhookID: webhookID, limit: 100, deviceID: "dev-1")
        XCTAssertNil(result, "Row in backoff should not be drained")
    }
}
