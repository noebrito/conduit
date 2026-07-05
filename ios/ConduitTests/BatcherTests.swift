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
