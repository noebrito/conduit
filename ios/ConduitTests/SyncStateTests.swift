import XCTest
import GRDB
@testable import Conduit

/// Regression tests for the "last synced" timestamp (`sync_state`).
///
/// The bug: tapping "Sync Now" drained the queue but the "last synced" label
/// never updated, because "last synced" was inferred solely from `delivery_log`
/// — which is written only when a batch is actually delivered. An empty-but-
/// successful sync (nothing to upload) therefore never advanced the timestamp,
/// and the UI wasn't tied to the async upload completion.
///
/// The fix stamps a dedicated `sync_state` row on the SHARED completion path —
/// `Uploader.commitSent` (a 2xx delivery) and the empty branch of
/// `SyncEngine.flush` — for every trigger (manual / observer / background). These
/// tests cover: the DAO round-trip, that a 2xx delivery (including an all-deduped
/// one that wrote nothing) stamps, and that `HomeViewModel.deriveStatus` surfaces
/// an empty-but-successful sync as "synced" even with no delivery-log row.
final class SyncStateTests: XCTestCase {
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

    private func delivery(sentAt: Date, httpStatus: Int?, error: String?) -> DeliveryLogEntry {
        DeliveryLogEntry(
            id: nil,
            batchId: UUID().uuidString,
            sentAt: sentAt,
            httpStatus: httpStatus,
            sampleCount: 1,
            errorMessage: error,
            accepted: nil,
            deduped: nil
        )
    }

    // MARK: - SyncStateDAO round-trip

    func test_syncState_startsEmpty() throws {
        XCTAssertNil(try SyncStateDAO(db).lastSyncedAt(), "No sync has completed yet")
    }

    func test_syncState_upsertsSingletonRow() throws {
        let dao = SyncStateDAO(db)
        let t1 = Date(timeIntervalSince1970: 1_000)
        try dao.setLastSyncedAt(t1)
        XCTAssertEqual(try dao.lastSyncedAt(), t1)

        let t2 = Date(timeIntervalSince1970: 2_000)
        try dao.setLastSyncedAt(t2)
        XCTAssertEqual(try dao.lastSyncedAt(), t2, "Second stamp overwrites in place")

        let rowCount = try db.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_state")
        }
        XCTAssertEqual(rowCount, 1, "sync_state is a singleton row")
    }

    // MARK: - 2xx delivery stamps last-synced (the "queue drained" path)

    func test_commitSent_stampsLastSynced() throws {
        XCTAssertNil(try SyncStateDAO(db).lastSyncedAt())

        let batchID = UUID().uuidString
        try insertInflightRow(uuid: "hr-1", batchID: batchID)
        // 1s slack on each side: GRDB truncates the stored Date to millisecond
        // precision, so the read-back stamp can land just below a full-precision
        // `Date()` captured in the same instant.
        let before = Date().addingTimeInterval(-1)
        try db.dbWriter.write { grdb in
            try Uploader.commitSent(grdb, batchID: batchID, httpStatus: 200, accepted: 1, deduped: 0)
        }

        let stamp = try XCTUnwrap(SyncStateDAO(db).lastSyncedAt(),
                                  "A 2xx delivery must stamp last-synced")
        XCTAssertGreaterThanOrEqual(stamp, before)
        XCTAssertLessThanOrEqual(stamp, Date().addingTimeInterval(1))
    }

    func test_commitSent_allDeduped_stillStamps() throws {
        // A 200 that wrote 0 new docs (all duplicates) is still a successful sync.
        let batchID = UUID().uuidString
        try insertInflightRow(uuid: "dup-1", batchID: batchID)
        try db.dbWriter.write { grdb in
            try Uploader.commitSent(grdb, batchID: batchID, httpStatus: 200, accepted: 0, deduped: 1)
        }
        XCTAssertNotNil(try SyncStateDAO(db).lastSyncedAt(),
                        "An all-deduped but successful delivery still counts as synced")
    }

    // MARK: - HomeViewModel.deriveStatus (what the UI shows)

    func test_deriveStatus_noSyncNoDelivery_isIdle() {
        XCTAssertEqual(HomeViewModel.deriveStatus(lastSynced: nil, latestDelivery: nil), .idle)
    }

    func test_deriveStatus_emptySuccessfulSync_showsSynced_withNoDeliveryRow() {
        // The empty-but-successful case: the flush stamped sync_state but wrote NO
        // delivery_log row (nothing was delivered). The UI must still show "Synced".
        let t = Date(timeIntervalSince1970: 5_000)
        XCTAssertEqual(HomeViewModel.deriveStatus(lastSynced: t, latestDelivery: nil), .synced(t))
    }

    func test_deriveStatus_prefersStampOverOlderDelivery() {
        let deliveredAt = Date(timeIntervalSince1970: 1_000)
        let syncedAt = Date(timeIntervalSince1970: 2_000)
        let entry = delivery(sentAt: deliveredAt, httpStatus: 200, error: nil)
        XCTAssertEqual(
            HomeViewModel.deriveStatus(lastSynced: syncedAt, latestDelivery: entry),
            .synced(syncedAt)
        )
    }

    func test_deriveStatus_freshFailureAfterSuccess_showsError() {
        let syncedAt = Date(timeIntervalSince1970: 1_000)
        let failedAt = Date(timeIntervalSince1970: 2_000)
        let entry = delivery(sentAt: failedAt, httpStatus: 500, error: "HTTP 500")
        XCTAssertEqual(
            HomeViewModel.deriveStatus(lastSynced: syncedAt, latestDelivery: entry),
            .error("HTTP 500")
        )
    }

    func test_deriveStatus_backfillsFromDeliveryWhenNoStamp() {
        // Installs that delivered before sync_state existed fall back to the
        // delivery log's success time so they don't regress to "No syncs yet".
        let deliveredAt = Date(timeIntervalSince1970: 3_000)
        let entry = delivery(sentAt: deliveredAt, httpStatus: 200, error: nil)
        XCTAssertEqual(
            HomeViewModel.deriveStatus(lastSynced: nil, latestDelivery: entry),
            .synced(deliveredAt)
        )
    }

    // MARK: - SyncEngine.outboxIsFullyDrained (2026-08-11 post-outage masking bug)

    /// The bug this guards: a flush with nothing NEW to batch (every candidate
    /// row already `.inflight` — e.g. a batch stuck after a destination
    /// outage) used to stamp "last synced" anyway, because the empty-flush
    /// branch only checked `count(state: .pending) == 0`, which is blind to
    /// `.inflight` rows. The captain saw a green "Synced 0 seconds ago" while
    /// 336 samples sat permanently undelivered and repeated "Sync Now" taps
    /// did nothing. See `OutboxDAO.reclaimStaleInflight` for the companion fix
    /// that actually un-sticks those rows.
    func test_outboxIsFullyDrained_pendingZeroButInflightOutstanding_isNotDrained() {
        XCTAssertFalse(
            SyncEngine.outboxIsFullyDrained(pendingCount: 0, inflightCount: 336),
            "an inflight batch is still undelivered data — must not report a fresh sync"
        )
    }

    func test_outboxIsFullyDrained_pendingOutstanding_isNotDrained() {
        XCTAssertFalse(SyncEngine.outboxIsFullyDrained(pendingCount: 5, inflightCount: 0))
    }

    func test_outboxIsFullyDrained_bothZero_isDrained() {
        XCTAssertTrue(SyncEngine.outboxIsFullyDrained(pendingCount: 0, inflightCount: 0))
    }
}
