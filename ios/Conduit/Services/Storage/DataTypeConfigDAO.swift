import Foundation
import GRDB

/// CRUD for `data_type_config` rows (ARCHITECTURE.md §4.7).
struct DataTypeConfigDAO {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    /// Insert or replace the full config row for a type.
    func upsert(_ config: DataTypeConfig) throws {
        try database.dbWriter.write { db in
            try config.save(db)
        }
    }

    /// Enable/disable a type, creating the row if needed. Anchor and timing
    /// fields are preserved across toggles.
    func setEnabled(_ enabled: Bool, hkTypeId: String) throws {
        try database.dbWriter.write { db in
            if var existing = try DataTypeConfig.fetchOne(db, key: hkTypeId) {
                existing.enabled = enabled
                try existing.update(db)
            } else {
                try DataTypeConfig(
                    hkTypeId: hkTypeId,
                    enabled: enabled,
                    minIntervalSeconds: nil,
                    anchorBlob: nil,
                    lastSyncAt: nil,
                    lastAttemptAt: nil
                ).insert(db)
            }
        }
    }

    func find(hkTypeId: String) throws -> DataTypeConfig? {
        try database.dbWriter.read { db in
            try DataTypeConfig.fetchOne(db, key: hkTypeId)
        }
    }

    func all() throws -> [DataTypeConfig] {
        try database.dbWriter.read { db in
            try DataTypeConfig.fetchAll(db)
        }
    }

    func enabled() throws -> [DataTypeConfig] {
        try database.dbWriter.read { db in
            try DataTypeConfig
                .filter(Column("enabled") == true)
                .fetchAll(db)
        }
    }

    /// The stored anchor blob for a type, if any.
    func anchorBlob(hkTypeId: String) throws -> Data? {
        try find(hkTypeId: hkTypeId)?.anchorBlob
    }

    /// Record the forward-only capture floor for a type. Called once, on the
    /// first (anchor-less) read, so `handleObserverWake` can seed the initial
    /// anchored query with a `withStart:` predicate and skip existing history.
    /// Updates the existing row (the type is already enabled at this point).
    func setCaptureStartedAt(_ date: Date, hkTypeId: String) throws {
        try database.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE data_type_config SET capture_started_at = ? WHERE hk_type_id = ?",
                arguments: [date, hkTypeId]
            )
        }
    }

    /// One-time remediation: clear every type's stored anchor **and** its
    /// capture-start floor so the next read re-seeds forward-only from a fresh
    /// "now". Used together with `OutboxDAO.deleteAll()` to drain a device that
    /// staged its full Health history under the old all-history backfill. Also
    /// clears the sync timestamps so the UI reflects the reset.
    func resetAllAnchors() throws {
        try database.dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE data_type_config
                    SET anchor_blob = NULL,
                        capture_started_at = NULL,
                        last_sync_at = NULL,
                        last_attempt_at = NULL
                    """
            )
        }
    }

    /// Advance the anchor and sync timestamps for a type **within an existing
    /// transaction**.
    ///
    /// This is the half of the §4.4 invariant that lives in `data_type_config`:
    /// callers MUST invoke it inside the same `db` write that enqueues the
    /// samples the anchor covers, otherwise advancing the anchor without
    /// persisting the samples permanently loses data. `OutboxDAO.ingest(...)`
    /// composes both halves in one transaction; do not call this on its own
    /// after a separate enqueue.
    static func advanceAnchor(
        _ db: Database,
        hkTypeId: String,
        anchorBlob: Data?,
        enabledIfNew: Bool = true,
        syncedAt: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO data_type_config
                    (hk_type_id, enabled, anchor_blob, last_sync_at, last_attempt_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(hk_type_id) DO UPDATE SET
                    anchor_blob = excluded.anchor_blob,
                    last_sync_at = excluded.last_sync_at,
                    last_attempt_at = excluded.last_attempt_at
                """,
            arguments: [hkTypeId, enabledIfNew, anchorBlob, syncedAt, syncedAt]
        )
    }
}
