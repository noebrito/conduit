import Foundation
import GRDB

/// Single-row store for the global "last synced" timestamp the Home screen reads:
/// the instant of the last SUCCESSFUL sync — either a delivered batch OR a
/// confirmed empty flush (nothing to upload with a clean outbox).
///
/// ## Why this exists (not `delivery_log`)
/// "Last synced" used to be inferred solely from `DeliveryLogDAO.latest()`. But a
/// `delivery_log` row is written only when a batch is actually delivered
/// (`Uploader.commitSent`), so a "Sync Now" that finds nothing to upload — an
/// empty-but-successful sync — never advanced the timestamp, and the UI wasn't
/// tied to the async upload completion at all (it read a stale value right after
/// `flushNow()` returned). This table decouples the concept: it is stamped on the
/// **shared completion path** for every trigger — manual "Sync Now", the
/// HealthKit observer wake, and the background-refresh flush — so a successful
/// sync always advances it, including a zero-item drain.
///
/// Stamped from two places, both on that shared path:
/// - `Uploader.commitSent` — a 2xx delivery (the queue actually drained).
/// - `SyncEngine.flush` — an empty successful flush (nothing ready to upload and
///   no pending work waiting).
///
/// Being DB-backed, a stamp fires the Home screen's `ValueObservation`, so the UI
/// reflects it reactively rather than depending on a poll timer.
struct SyncStateDAO {
    /// The one and only row's primary key.
    static let singletonID: Int64 = 1

    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    /// Stamp the last successful-sync time, within an existing transaction. Upsert
    /// on the singleton row. Callers on the shared completion path pass their own
    /// `Database` so the stamp lands in the same write that recorded the delivery.
    static func setLastSyncedAt(_ db: Database, _ date: Date = Date()) throws {
        try db.execute(
            sql: """
                INSERT INTO sync_state (id, last_synced_at)
                VALUES (?, ?)
                ON CONFLICT(id) DO UPDATE SET last_synced_at = excluded.last_synced_at
                """,
            arguments: [singletonID, date]
        )
    }

    /// Read the last successful-sync time inside an existing connection (used by
    /// the Home `ValueObservation`). `nil` when no sync has completed yet.
    static func lastSyncedAt(_ db: Database) throws -> Date? {
        try Date.fetchOne(
            db,
            sql: "SELECT last_synced_at FROM sync_state WHERE id = ?",
            arguments: [singletonID]
        )
    }

    /// Stamp in its own write transaction.
    func setLastSyncedAt(_ date: Date = Date()) throws {
        try database.dbWriter.write { try SyncStateDAO.setLastSyncedAt($0, date) }
    }

    /// Read in its own connection.
    func lastSyncedAt() throws -> Date? {
        try database.dbWriter.read { try SyncStateDAO.lastSyncedAt($0) }
    }
}
