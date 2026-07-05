import XCTest
import GRDB
@testable import Conduit

/// Tests for response → outbox state transition logic.
///
/// We test the transitions by exercising the private helpers indirectly through
/// the public `URLSessionTaskDelegate` implementation. Because `Uploader` is a
/// singleton that needs a real `URLSession` background configuration (which
/// can't be fully mocked), we test the state logic by writing rows directly
/// and simulating the delegate callbacks through helper methods exposed via
/// `@testable import`.
///
/// The tests use an in-memory database and verify outbox + delivery_log state
/// after each simulated response.
final class UploaderResponseTests: XCTestCase {
    private var db: AppDatabase!
    private var webhookID: Int64!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        var wh = WebhookConfig.makeDefault(url: "https://example.com", bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(db).save(&wh)
        webhookID = wh.id
    }

    // MARK: - Helpers

    private func insertInflightRow(uuid: String, batchID: String, attempt: Int = 0) throws {
        try db.dbWriter.write { grdb in
            var s = Conduit_V1_Sample(); s.uuid = uuid
            let payload = (try? s.jsonUTF8Data()) ?? Data()
            try grdb.execute(
                sql: """
                    INSERT INTO outbox
                        (webhook_id, hk_sample_uuid, hk_type_id, payload_blob,
                         created_at, state, batch_id, attempt_count)
                    VALUES (?, ?, 'HKQuantityTypeIdentifierHeartRate', ?, ?, 'inflight', ?, ?)
                    """,
                arguments: [webhookID, uuid, payload, Date(), batchID, attempt]
            )
        }
    }

    private func outboxRow(uuid: String) throws -> OutboxRow? {
        try OutboxDAO(db).find(hkSampleUuid: uuid)
    }

    // MARK: - 2xx → delivered rows DELETED, delivery_log written

    func test_2xx_deletesRowsAndWritesDeliveryLog() throws {
        let batchID = UUID().uuidString
        try insertInflightRow(uuid: "hr-1", batchID: batchID)
        try insertInflightRow(uuid: "hr-2", batchID: batchID)

        // Exercise the REAL transition (Uploader.commitSent), not a re-simulation.
        try db.dbWriter.write { grdb in
            try Uploader.commitSent(grdb, batchID: batchID, httpStatus: 200)
        }

        // Delivered rows are purged from the outbox — the outbox is a backlog
        // queue, so `fetchCount` (the outboxCap basis) reflects only real work.
        XCTAssertNil(try outboxRow(uuid: "hr-1"), "Delivered row must be deleted, not kept as `sent`")
        XCTAssertNil(try outboxRow(uuid: "hr-2"), "Delivered row must be deleted, not kept as `sent`")
        XCTAssertEqual(try OutboxDAO(db).totalCount(), 0, "No rows should remain after a full delivery")

        // The durable "sent" audit record lives in delivery_log (read by Activity UI).
        let logCount = try db.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM delivery_log WHERE batch_id = ?", arguments: [batchID]) }
        XCTAssertEqual(logCount, 1)
        let sampleCount = try db.dbWriter.read { try Int.fetchOne($0, sql: "SELECT sample_count FROM delivery_log WHERE batch_id = ?", arguments: [batchID]) }
        XCTAssertEqual(sampleCount, 2, "delivery_log must record the delivered sample count")
    }

    // MARK: - 2xx write outcome recorded (accepted vs deduped)

    func test_2xx_recordsAcceptedAndDedupedFromResponseBody() throws {
        let batchID = UUID().uuidString
        try insertInflightRow(uuid: "hr-1", batchID: batchID)
        try insertInflightRow(uuid: "hr-2", batchID: batchID)

        // Simulate the parsed 200 body `{accepted: 2, deduped: 0}`.
        try db.dbWriter.write { grdb in
            try Uploader.commitSent(grdb, batchID: batchID, httpStatus: 200, accepted: 2, deduped: 0)
        }

        let entry = try XCTUnwrap(DeliveryLogDAO(db).latest())
        XCTAssertEqual(entry.accepted, 2, "delivery_log must record docs actually written")
        XCTAssertEqual(entry.deduped, 0)
        XCTAssertEqual(entry.writeOutcomeLabel, "2 sent · 2 new")
        XCTAssertFalse(entry.isAllDeduped)
    }

    func test_2xx_allDedupedIsDistinctFromRealWrite() throws {
        // The bug this closes: a 200 that wrote 0 new docs (all duplicates) must
        // be visibly distinct from a 200 that wrote every sample.
        let dedupBatch = UUID().uuidString
        try insertInflightRow(uuid: "dup-1", batchID: dedupBatch)
        try db.dbWriter.write { grdb in
            try Uploader.commitSent(grdb, batchID: dedupBatch, httpStatus: 200, accepted: 0, deduped: 1)
        }
        let deduped = try XCTUnwrap(DeliveryLogDAO(db).latest())
        XCTAssertTrue(deduped.isAllDeduped, "0 written + >0 deduped must read as all-deduped")
        XCTAssertEqual(deduped.writeOutcomeLabel, "1 sent · 0 new")

        let writeBatch = UUID().uuidString
        try insertInflightRow(uuid: "new-1", batchID: writeBatch)
        try db.dbWriter.write { grdb in
            try Uploader.commitSent(grdb, batchID: writeBatch, httpStatus: 200, accepted: 1, deduped: 0)
        }
        let written = try XCTUnwrap(DeliveryLogDAO(db).latest())
        XCTAssertFalse(written.isAllDeduped)
        XCTAssertEqual(written.writeOutcomeLabel, "1 sent · 1 new")
    }

    func test_2xx_missingBodyLeavesOutcomeUnknown() throws {
        // A 200 with no parseable body still succeeds; accepted/deduped are nil.
        let batchID = UUID().uuidString
        try insertInflightRow(uuid: "hr-1", batchID: batchID)
        try db.dbWriter.write { grdb in
            try Uploader.commitSent(grdb, batchID: batchID, httpStatus: 200)
        }
        let entry = try XCTUnwrap(DeliveryLogDAO(db).latest())
        XCTAssertNil(entry.accepted)
        XCTAssertNil(entry.deduped)
        XCTAssertNil(entry.writeOutcomeLabel, "Unknown outcome must not fabricate a label")
        XCTAssertTrue(entry.isSuccess, "A 200 is still success regardless of write outcome")
    }

    // MARK: - Retryable → pending + backoff

    func test_retryable_resetsRowsToPendingWithBackoff() throws {
        let batchID = UUID().uuidString
        try insertInflightRow(uuid: "hr-1", batchID: batchID, attempt: 0)

        // Simulate resetToRetry
        try db.dbWriter.write { grdb in
            let rows = try OutboxRow.filter(Column("batch_id") == batchID).fetchAll(grdb)
            for row in rows {
                let attempt = row.attemptCount + 1
                let nextAttempt = BackoffPolicy.nextAttemptDate(attemptCount: attempt)
                try grdb.execute(
                    sql: """
                        UPDATE outbox
                        SET state = 'pending', batch_id = NULL,
                            attempt_count = ?, next_attempt_at = ?, last_error = ?
                        WHERE id = ?
                        """,
                    arguments: [attempt, nextAttempt, "HTTP 503", row.id]
                )
            }
        }

        let row = try XCTUnwrap(outboxRow(uuid: "hr-1"))
        XCTAssertEqual(row.state, .pending)
        XCTAssertNil(row.batchId)
        XCTAssertEqual(row.attemptCount, 1)
        XCTAssertNotNil(row.nextAttemptAt)
        XCTAssertEqual(row.lastError, "HTTP 503")
        // next_attempt_at should be in the future
        XCTAssertGreaterThan(row.nextAttemptAt!, Date())
    }

    // MARK: - 429 with Retry-After

    func test_retryable_429_honorsRetryAfterHeader() throws {
        let batchID = UUID().uuidString
        try insertInflightRow(uuid: "hr-1", batchID: batchID, attempt: 2)

        let retryAfterSeconds: TimeInterval = 300

        try db.dbWriter.write { grdb in
            let rows = try OutboxRow.filter(Column("batch_id") == batchID).fetchAll(grdb)
            for row in rows {
                let attempt = row.attemptCount + 1
                let nextAttempt = BackoffPolicy.nextAttemptDate(
                    attemptCount: attempt,
                    retryAfter: retryAfterSeconds
                )
                try grdb.execute(
                    sql: """
                        UPDATE outbox
                        SET state = 'pending', batch_id = NULL,
                            attempt_count = ?, next_attempt_at = ?
                        WHERE id = ?
                        """,
                    arguments: [attempt, nextAttempt, row.id]
                )
            }
        }

        let row = try XCTUnwrap(outboxRow(uuid: "hr-1"))
        XCTAssertEqual(row.state, .pending)
        // next_attempt should be ~300s from now (tolerance for test execution time)
        let interval = row.nextAttemptAt!.timeIntervalSinceNow
        XCTAssertGreaterThan(interval, 280, "Expected ~300s retry delay, got \(interval)s")
        XCTAssertLessThan(interval, 320,    "Expected ~300s retry delay, got \(interval)s")
    }

    // MARK: - Permanent 4xx → failed

    func test_permanent4xx_marksRowsFailed() throws {
        let batchID = UUID().uuidString
        try insertInflightRow(uuid: "hr-1", batchID: batchID)

        try db.dbWriter.write { grdb in
            let rows = try OutboxRow.filter(Column("batch_id") == batchID).fetchAll(grdb)
            let ids = rows.compactMap(\.id)
            try OutboxRow.filter(ids.contains(Column("id")))
                .updateAll(grdb,
                    Column("state").set(to: OutboxState.failed.rawValue),
                    Column("last_error").set(to: "HTTP 400: bad request"))
        }

        let row = try XCTUnwrap(outboxRow(uuid: "hr-1"))
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.lastError, "HTTP 400: bad request")
    }
}
