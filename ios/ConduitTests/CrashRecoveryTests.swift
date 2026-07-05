import XCTest
import GRDB
@testable import Conduit

/// Tests for crash recovery: `reconcileInflight` resets orphaned `inflight` rows
/// back to `pending` on relaunch (ARCHITECTURE.md §4.6).
final class CrashRecoveryTests: XCTestCase {
    private var db: AppDatabase!
    private var webhookID: Int64!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        var wh = WebhookConfig.makeDefault(url: "https://example.com", bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(db).save(&wh)
        webhookID = wh.id
    }

    // MARK: - Helpers

    private func insertInflightRow(uuid: String, batchID: String) throws {
        try db.dbWriter.write { grdb in
            var s = Conduit_V1_Sample(); s.uuid = uuid
            let payload = (try? s.jsonUTF8Data()) ?? Data()
            try grdb.execute(
                sql: """
                    INSERT INTO outbox
                        (webhook_id, hk_sample_uuid, hk_type_id, payload_blob,
                         created_at, state, batch_id, attempt_count)
                    VALUES (?, ?, 'HKQuantityTypeIdentifierHeartRate', ?, ?, 'inflight', ?, 0)
                    """,
                arguments: [webhookID, uuid, payload, Date(), batchID]
            )
        }
    }

    // MARK: - Core reconcile logic

    /// Simulates what `Uploader.reconcileInflight()` does: given a set of
    /// batch IDs that are still genuinely in-flight (active URLSession tasks),
    /// reset any inflight rows not in that set to pending.
    private func runReconcile(activeBatchIDs: Set<String>) throws {
        try db.dbWriter.write { grdb in
            let orphans = try OutboxRow
                .filter(Column("state") == OutboxState.inflight.rawValue)
                .fetchAll(grdb)
                .filter { row in
                    guard let bid = row.batchId else { return true }
                    return !activeBatchIDs.contains(bid)
                }
            guard !orphans.isEmpty else { return }
            let ids = orphans.compactMap(\.id)
            try OutboxRow
                .filter(ids.contains(Column("id")))
                .updateAll(
                    grdb,
                    Column("state").set(to: OutboxState.pending.rawValue),
                    Column("batch_id").set(to: nil as String?)
                )
        }
    }

    // MARK: - All inflight orphaned (app crash scenario)

    func test_reconcile_allOrphaned_resetsToPending() throws {
        let batchA = "batch-A"
        let batchB = "batch-B"
        try insertInflightRow(uuid: "hr-1", batchID: batchA)
        try insertInflightRow(uuid: "hr-2", batchID: batchB)

        // No active tasks — both batches are orphaned
        try runReconcile(activeBatchIDs: [])

        let dao = OutboxDAO(db)
        XCTAssertEqual(try dao.count(state: .pending),  2)
        XCTAssertEqual(try dao.count(state: .inflight), 0)

        let row = try dao.find(hkSampleUuid: "hr-1")
        XCTAssertNil(row?.batchId, "batch_id should be cleared on reset")
    }

    // MARK: - Partial orphan (one batch survived, one didn't)

    func test_reconcile_partialOrphan_onlyResetsOrphans() throws {
        let aliveID  = "batch-alive"
        let deadID   = "batch-dead"
        try insertInflightRow(uuid: "hr-alive", batchID: aliveID)
        try insertInflightRow(uuid: "hr-dead",  batchID: deadID)

        // Only aliveID has an active task
        try runReconcile(activeBatchIDs: [aliveID])

        let dao = OutboxDAO(db)
        XCTAssertEqual(try dao.count(state: .inflight), 1)
        XCTAssertEqual(try dao.count(state: .pending),  1)

        let alive = try XCTUnwrap(dao.find(hkSampleUuid: "hr-alive"))
        XCTAssertEqual(alive.state, .inflight)
        XCTAssertEqual(alive.batchId, aliveID)

        let dead = try XCTUnwrap(dao.find(hkSampleUuid: "hr-dead"))
        XCTAssertEqual(dead.state, .pending)
        XCTAssertNil(dead.batchId)
    }

    // MARK: - Nothing to reconcile

    func test_reconcile_noInflightRows_isNoOp() throws {
        // Only pending rows
        try OutboxDAO(db).enqueue(
            sample: { var s = Conduit_V1_Sample(); s.uuid = "pend-1"; return s }(),
            hkTypeId: "HKQuantityTypeIdentifierHeartRate",
            webhookId: webhookID
        )

        try runReconcile(activeBatchIDs: [])

        let dao = OutboxDAO(db)
        XCTAssertEqual(try dao.count(state: .pending),  1)
        XCTAssertEqual(try dao.count(state: .inflight), 0)
    }

    // MARK: - All inflight are still active (normal operation)

    func test_reconcile_allActive_doesNotReset() throws {
        let batchID = "batch-ok"
        try insertInflightRow(uuid: "hr-1", batchID: batchID)

        try runReconcile(activeBatchIDs: [batchID])

        let dao = OutboxDAO(db)
        XCTAssertEqual(try dao.count(state: .inflight), 1)
        XCTAssertEqual(try dao.count(state: .pending),  0)
    }

    // MARK: - Inflight row with nil batchId (defensive)

    func test_reconcile_inflightRowWithNilBatchId_isReset() throws {
        // This shouldn't happen in practice, but guard against it.
        try db.dbWriter.write { grdb in
            try grdb.execute(
                sql: """
                    INSERT INTO outbox
                        (webhook_id, hk_sample_uuid, hk_type_id, payload_blob,
                         created_at, state, attempt_count)
                    VALUES (?, 'nil-batch', 'HKQuantityTypeIdentifierHeartRate', ?, ?, 'inflight', 0)
                    """,
                arguments: [webhookID, Data(), Date()]
            )
        }

        try runReconcile(activeBatchIDs: ["some-other-batch"])

        let row = try XCTUnwrap(OutboxDAO(db).find(hkSampleUuid: "nil-batch"))
        XCTAssertEqual(row.state, .pending)
    }
}
