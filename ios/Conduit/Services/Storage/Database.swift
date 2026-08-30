import Foundation
import GRDB
import os

/// GRDB database setup + schema migrations for Conduit's local outbox store
/// (ARCHITECTURE.md §4.7).
///
/// The type is named `AppDatabase` (not `Database`) to avoid colliding with
/// `GRDB.Database`, the per-connection type passed into `write { db in ... }`.
/// The file is `Database.swift` per the architecture's folder layout.
///
/// Concurrency: all access goes through a single `DatabaseWriter` (a
/// `DatabaseQueue`), which serializes writes and gives us real SQLite
/// transactions — the foundation for the §4.4 "anchor + enqueue in one
/// transaction" invariant.
final class AppDatabase {
    private static let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "Database")

    /// The single writer all DAOs share.
    let dbWriter: any DatabaseWriter

    /// Creates a database from any GRDB writer and runs migrations.
    init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    // MARK: - Factories

    /// On-disk database in Application Support, used by the app.
    static func makeShared() throws -> AppDatabase {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Conduit", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("conduit.sqlite")

        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        logger.info("Opened database at \(url.path, privacy: .public)")
        return try AppDatabase(queue)
    }

    /// In-memory database for tests and previews.
    static func makeInMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    // MARK: - Migrations

    /// Schema migrator. Each migration is immutable once shipped; new schema
    /// changes are appended as new migrations.
    var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // Surface schema drift loudly during development.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            // webhook_config — destinations (one in v1 UI, many supported).
            try db.create(table: "webhook_config") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull()
                t.column("bearer_token_keychain_ref", .text).notNull()
                t.column("min_interval_seconds", .integer).notNull()
                t.column("batch_max_size", .integer).notNull()
                t.column("force_flush_threshold", .integer).notNull()
                t.column("outbox_cap", .integer).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            // data_type_config — per HK type enablement + anchor state.
            try db.create(table: "data_type_config") { t in
                t.column("hk_type_id", .text).notNull().primaryKey()
                t.column("enabled", .boolean).notNull().defaults(to: false)
                t.column("min_interval_seconds", .integer)
                t.column("anchor_blob", .blob)
                t.column("last_sync_at", .datetime)
                t.column("last_attempt_at", .datetime)
            }

            // outbox — staged samples. hk_sample_uuid UNIQUE drives dedupe.
            try db.create(table: "outbox") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("webhook_id", .integer)
                    .notNull()
                    .indexed()
                    .references("webhook_config", onDelete: .cascade)
                t.column("hk_sample_uuid", .text).notNull().unique()
                t.column("hk_type_id", .text).notNull()
                t.column("payload_blob", .blob).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("state", .text).notNull().defaults(to: OutboxState.pending.rawValue)
                t.column("batch_id", .text)
                t.column("attempt_count", .integer).notNull().defaults(to: 0)
                t.column("next_attempt_at", .datetime)
                t.column("last_error", .text)
            }
            // Hot-path index: "what is ready to send right now?"
            try db.create(
                index: "outbox_on_state_next_attempt_at",
                on: "outbox",
                columns: ["state", "next_attempt_at"]
            )

            // delivery_log — capped ring buffer (~500 rows) for the activity UI.
            try db.create(table: "delivery_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("batch_id", .text).notNull()
                t.column("sent_at", .datetime).notNull()
                t.column("http_status", .integer)
                t.column("sample_count", .integer).notNull()
                t.column("error_message", .text)
            }
        }

        // v2 — forward-only capture floor. `capture_started_at` records the
        // instant a type first began capturing so the first (anchor-less) read
        // can seed to "now" and skip existing history (ARCHITECTURE.md §4.4).
        migrator.registerMigration("v2-capture-started-at") { db in
            try db.alter(table: "data_type_config") { t in
                t.add(column: "capture_started_at", .datetime)
            }
        }

        // v3 — upload write visibility. The ingester's 200 body is
        // `{accepted, deduped}`; record both so a batch that wrote 0 new docs
        // (all duplicates) is distinguishable from one that wrote every sample.
        // Nullable: rows written before this migration, and non-2xx rows, leave
        // them nil (unknown).
        migrator.registerMigration("v3-delivery-accepted-deduped") { db in
            try db.alter(table: "delivery_log") { t in
                t.add(column: "accepted", .integer)
                t.add(column: "deduped", .integer)
            }
        }

        // v4 — persisted "staged today" tally. Since #505 a successful upload
        // DELETES the delivered outbox row (the outbox is a true drain), the old
        // "count outbox rows with created_at >= startOfDay" no longer measures how
        // many samples were staged today — it collapses to the live Pending count
        // and shrinks as uploads complete. This table records a per-local-day
        // running total that is incremented in the SAME transaction as each
        // enqueue (see `StagedDailyCountDAO.increment`), so it survives row
        // deletion and can't drift from what was actually staged.
        migrator.registerMigration("v4-staged-daily-count") { db in
            try db.create(table: "staged_daily_count") { t in
                // `day` is the LOCAL start-of-day (00:00:00 in the device's
                // calendar) of a sample's enqueue time — the bucket key.
                t.column("day", .datetime).notNull().primaryKey()
                t.column("count", .integer).notNull().defaults(to: 0)
            }
        }

        // v5 — single-row store for the global "last synced" timestamp the Home
        // screen shows. It must NOT be inferred from `delivery_log` alone: a
        // delivery_log row is written only when a batch is actually delivered, so
        // a "Sync Now" that finds nothing to upload (empty-but-successful) would
        // never advance the timestamp. This is stamped on the shared completion
        // path (`Uploader.commitSent` for a 2xx delivery, and `SyncEngine.flush`
        // for an empty successful flush) so every trigger — manual, observer,
        // background — updates it consistently (see `SyncStateDAO`). Being
        // DB-backed, a write here fires the Home `ValueObservation`, so the UI
        // reflects it reactively.
        migrator.registerMigration("v5-sync-state") { db in
            try db.create(table: "sync_state") { t in
                // Singleton row (id is always `SyncStateDAO.singletonID`).
                t.column("id", .integer).primaryKey()
                t.column("last_synced_at", .datetime)
            }
        }

        // v6 — outbox row op discriminator. Lets a row be either an `upsert`
        // (the sample's document, the default) or a `delete` tombstone (a
        // HealthKit-deleted sample whose OpenSearch doc must be removed so an
        // edited/removed food doesn't leave a ghost that inflates nutrition
        // totals). Additive + DEFAULT 'upsert', so every existing row and the
        // unchanged upsert insert path (which omits the column) stay `upsert` —
        // the upsert flow is byte-identical when there are no deletions.
        migrator.registerMigration("v6-outbox-op") { db in
            try db.alter(table: "outbox") { t in
                t.add(column: "op", .text).notNull().defaults(to: OutboxOp.upsert.rawValue)
            }
        }

        // v7 — durable "Import history" progress. Purely additive (two NEW
        // tables; no existing table, column or row is touched), so it is safe on
        // a populated production database and the forward-capture path is
        // byte-identical.
        //
        // Why it exists: the importer's paging cursor lived only in memory, so an
        // import interrupted by backgrounding/force-quit had NO resume point and
        // restarted from the newest end; and a failed import returned a
        // success-shaped summary, so the UI showed a green "Imported N samples"
        // over a truncated history. These tables give the resume point and the
        // terminal outcome (including a failure reason) that the UI reads back
        // after a relaunch. See `ImportProgressDAO`.
        migrator.registerMigration("v7-import-progress") { db in
            try db.create(table: "import_run") { t in
                // Singleton row (id is always `ImportProgressDAO.singletonID`).
                t.column("id", .integer).primaryKey()
                t.column("run_id", .text).notNull()
                t.column("range_id", .text).notNull()
                t.column("range_start", .datetime)
                t.column("status", .text).notNull()
                t.column("staged_count", .integer).notNull().defaults(to: 0)
                t.column("failure_reason", .text)
                t.column("types_total", .integer).notNull().defaults(to: 0)
                t.column("types_completed", .integer).notNull().defaults(to: 0)
                t.column("oldest_reached_at", .datetime)
                t.column("started_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "import_type_progress") { t in
                t.column("hk_type_id", .text).notNull().primaryKey()
                t.column("run_id", .text).notNull().indexed()
                // Newest-first paging cursor: samples with endDate <= cursor are
                // still unread. NULL = this type hasn't started.
                t.column("cursor", .datetime)
                t.column("staged_count", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull()
                t.column("failure_reason", .text)
                t.column("updated_at", .datetime).notNull()
            }
        }

        // v8 — does the paused run deserve to be picked back up on its own?
        // Purely additive (one nullable-by-default column with a literal default),
        // so an existing v7 row keeps working unchanged and the forward-capture
        // path is untouched.
        //
        // "Interrupted" alone can't answer it: an import the USER cancelled and an
        // import iOS suspended are the same status, but only the second should be
        // auto-resumed on the next foreground / background window. Defaulting to 0
        // is the conservative direction — a pre-existing paused run is only ever
        // resumed by an explicit tap until it stops for a reason we recorded.
        migrator.registerMigration("v8-import-auto-resume") { db in
            try db.alter(table: "import_run") { t in
                t.add(column: "auto_resume", .boolean).notNull().defaults(to: false)
            }
        }

        // v9 — WHY the run stopped, so the honest reason survives a relaunch.
        // Additive in exactly the same shape as v8 (one nullable column, no
        // existing column altered), so a v8 row keeps working unchanged.
        //
        // `auto_resume` answers "may we continue this on our own"; it cannot
        // answer "why did it stop". A run halted because the upload queue never
        // drained is a real problem the user has to see, and after a relaunch the
        // generic "interrupted" line is exactly the comforting-but-vague status
        // this work exists to eliminate. A NULL cause (any pre-existing row) is
        // unknown, which stays on the conservative generic copy.
        migrator.registerMigration("v9-import-stop-cause") { db in
            try db.alter(table: "import_run") { t in
                t.add(column: "stop_cause", .text)
            }
        }

        // v10 — WHEN a row was marked inflight, so a stuck batch can be
        // reclaimed by elapsed time alone rather than relying only on whether
        // the background URLSession still reports its task active (the §4.6
        // crash-recovery check, which only ever runs at app launch). Purely
        // additive: one nullable column, no existing row touched. A row
        // already `inflight` from before this migration simply has
        // `inflight_at == NULL`, which `OutboxDAO.reclaimStaleInflight`
        // treats as immediately eligible for reclaim.
        migrator.registerMigration("v10-outbox-inflight-at") { db in
            try db.alter(table: "outbox") { t in
                t.add(column: "inflight_at", .datetime)
            }
        }

        return migrator
    }
}
