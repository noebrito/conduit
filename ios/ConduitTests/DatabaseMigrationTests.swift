import XCTest
import GRDB
@testable import Conduit

final class DatabaseMigrationTests: XCTestCase {
    func testMigrationCreatesAllTables() throws {
        let appDB = try AppDatabase.makeInMemory()
        try appDB.dbWriter.read { db in
            for table in ["webhook_config", "data_type_config", "outbox", "delivery_log", "staged_daily_count", "sync_state"] {
                XCTAssertTrue(try db.tableExists(table), "Missing table: \(table)")
            }
        }
    }

    func testOutboxHasUniqueSampleIndexAndCompositeStateIndex() throws {
        let appDB = try AppDatabase.makeInMemory()
        try appDB.dbWriter.read { db in
            let indexes = try db.indexes(on: "outbox")

            // UNIQUE on hk_sample_uuid drives INSERT OR IGNORE dedupe (§4.4).
            XCTAssertTrue(
                indexes.contains { $0.isUnique && $0.columns == ["hk_sample_uuid"] },
                "outbox is missing a UNIQUE index on hk_sample_uuid"
            )

            // Composite index on (state, next_attempt_at) for the flush hot path.
            XCTAssertTrue(
                indexes.contains { $0.columns == ["state", "next_attempt_at"] },
                "outbox is missing the (state, next_attempt_at) index"
            )
        }
    }

    func testOutboxColumns() throws {
        let appDB = try AppDatabase.makeInMemory()
        try appDB.dbWriter.read { db in
            let columns = try Set(db.columns(in: "outbox").map(\.name))
            let expected = [
                "id", "webhook_id", "hk_sample_uuid", "hk_type_id", "payload_blob",
                "created_at", "state", "batch_id", "attempt_count", "next_attempt_at", "last_error",
                // v6 — op discriminator (upsert | delete tombstone).
                "op",
                // v10 — when a row was last marked inflight, for time-based
                // stale-inflight reclaim independent of the launch-time
                // URLSession-active check (see OutboxDAO.reclaimStaleInflight).
                "inflight_at",
            ]
            for column in expected {
                XCTAssertTrue(columns.contains(column), "outbox missing column: \(column)")
            }
        }
    }

    func testOutboxOpColumnDefaultsToUpsert() throws {
        // v6 migration adds `op` defaulting to 'upsert', so the unchanged upsert
        // insert path (which omits the column) and every pre-existing row stay
        // upserts — the deletion feature is purely additive.
        let appDB = try AppDatabase.makeInMemory()
        var wh = WebhookConfig.makeDefault(url: "https://example.com/hook", bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(appDB).save(&wh)
        let webhookID = try XCTUnwrap(wh.id)
        try appDB.dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO outbox
                        (webhook_id, hk_sample_uuid, hk_type_id, payload_blob, created_at, state, attempt_count)
                    VALUES (?, 'u1', 'HKQuantityTypeIdentifierHeartRate', ?, ?, 'pending', 0)
                    """,
                arguments: [webhookID, Data("{}".utf8), Date()]
            )
            let op = try String.fetchOne(db, sql: "SELECT op FROM outbox WHERE hk_sample_uuid = 'u1'")
            XCTAssertEqual(op, "upsert", "a row inserted without op must default to upsert")
        }
    }

    func testDataTypeConfigHasCaptureStartedAtColumn() throws {
        // v2 migration adds the forward-only capture floor column.
        let appDB = try AppDatabase.makeInMemory()
        try appDB.dbWriter.read { db in
            let columns = try Set(db.columns(in: "data_type_config").map(\.name))
            XCTAssertTrue(
                columns.contains("capture_started_at"),
                "data_type_config missing capture_started_at column"
            )
        }
    }

    func testDeliveryLogHasAcceptedAndDedupedColumns() throws {
        // v3 migration adds the upload write-visibility columns.
        let appDB = try AppDatabase.makeInMemory()
        try appDB.dbWriter.read { db in
            let columns = try Set(db.columns(in: "delivery_log").map(\.name))
            XCTAssertTrue(columns.contains("accepted"), "delivery_log missing accepted column")
            XCTAssertTrue(columns.contains("deduped"), "delivery_log missing deduped column")
        }
    }

    func testStagedDailyCountColumns() throws {
        // v4 migration adds the persisted "staged today" tally table.
        let appDB = try AppDatabase.makeInMemory()
        try appDB.dbWriter.read { db in
            let columns = try Set(db.columns(in: "staged_daily_count").map(\.name))
            XCTAssertTrue(columns.contains("day"), "staged_daily_count missing day column")
            XCTAssertTrue(columns.contains("count"), "staged_daily_count missing count column")
        }
    }

    func testSyncStateColumns() throws {
        // v5 migration adds the singleton "last synced" store.
        let appDB = try AppDatabase.makeInMemory()
        try appDB.dbWriter.read { db in
            let columns = try Set(db.columns(in: "sync_state").map(\.name))
            XCTAssertTrue(columns.contains("id"), "sync_state missing id column")
            XCTAssertTrue(columns.contains("last_synced_at"), "sync_state missing last_synced_at column")
        }
    }

    func testImportProgressTablesAndColumns() throws {
        // v7 migration adds the durable "Import history" progress store.
        let appDB = try AppDatabase.makeInMemory()
        try appDB.dbWriter.read { db in
            XCTAssertTrue(try db.tableExists("import_run"))
            XCTAssertTrue(try db.tableExists("import_type_progress"))

            let run = try Set(db.columns(in: "import_run").map(\.name))
            for column in [
                "id", "run_id", "range_id", "range_start", "status", "staged_count",
                "failure_reason", "types_total", "types_completed", "oldest_reached_at",
                "started_at", "updated_at",
                // v8 — whether a paused run may be picked back up on its own.
                "auto_resume",
                // v9 — WHY it stopped, so the reason survives a relaunch.
                "stop_cause"
            ] {
                XCTAssertTrue(run.contains(column), "import_run missing \(column)")
            }
            // Conservative default: a run persisted before v8 is never resumed
            // automatically, only by an explicit tap.
            let autoResumeDefault = try db.columns(in: "import_run")
                .first { $0.name == "auto_resume" }?.defaultValueSQL
            XCTAssertEqual(autoResumeDefault, "0")

            let types = try Set(db.columns(in: "import_type_progress").map(\.name))
            for column in ["hk_type_id", "run_id", "cursor", "staged_count", "status", "failure_reason", "updated_at"] {
                XCTAssertTrue(types.contains(column), "import_type_progress missing \(column)")
            }
        }
    }

    /// v7 must be purely additive — it may not alter any pre-existing table, so
    /// it is safe to run against the live App Store install's populated database.
    func testImportProgressMigrationDoesNotTouchExistingTables() throws {
        let appDB = try AppDatabase.makeInMemory()
        try appDB.dbWriter.read { db in
            let outbox = try Set(db.columns(in: "outbox").map(\.name))
            XCTAssertFalse(outbox.contains("cursor"))
            let config = try Set(db.columns(in: "data_type_config").map(\.name))
            // The forward-capture anchor state is untouched by the import store.
            XCTAssertTrue(config.contains("anchor_blob"))
            XCTAssertTrue(config.contains("capture_started_at"))
            XCTAssertFalse(config.contains("import_cursor"),
                           "Import progress must live in its own table, never on the anchor row")
        }
    }

    func testRemigrationIsIdempotent() throws {
        // Running the same migrator over an already-migrated DB is a no-op.
        let appDB = try AppDatabase.makeInMemory()
        XCTAssertNoThrow(try appDB.migrator.migrate(appDB.dbWriter))
    }

    func testIngestRevisionMigrationPreservesExistingCaptureStateAndSurvivesReopen() throws {
        let writer = try DatabaseQueue()
        let migrator = try AppDatabase.makeInMemory().migrator
        try migrator.migrate(writer, upTo: "v11-import-history-floor")
        let identifier = HealthDataType.stepCount.identifier
        let anchor = Data([0x01])
        let syncedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO data_type_config
                        (hk_type_id, enabled, anchor_blob, last_sync_at, last_attempt_at, capture_started_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [identifier, true, anchor, syncedAt, syncedAt, syncedAt]
            )
        }
        let upgraded = try AppDatabase(writer)
        let config = try XCTUnwrap(DataTypeConfigDAO(upgraded).find(hkTypeId: identifier))
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.anchorBlob, anchor)
        XCTAssertEqual(config.lastSyncAt, syncedAt)
        XCTAssertEqual(config.lastAttemptAt, syncedAt)
        XCTAssertEqual(config.captureStartedAt, syncedAt)
        XCTAssertEqual(config.ingestRevision, 0)
        var webhook = WebhookConfig.makeDefault(url: "https://example.com/sync", bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(upgraded).save(&webhook)
        var sample = Conduit_V1_Sample()
        sample.uuid = "blocked-by-cap"
        XCTAssertEqual(try OutboxDAO(upgraded).ingest(
            samples: [sample], hkTypeId: identifier, webhookId: try XCTUnwrap(webhook.id),
            anchorBlob: Data([0x02]), expectedAnchorBlob: anchor, expectedIngestRevision: 0, cap: 0
        ), 0)
        var expected = config
        expected.ingestRevision = 1
        let reopened = try AppDatabase(writer)
        XCTAssertEqual(try DataTypeConfigDAO(reopened).find(hkTypeId: identifier), expected)
        XCTAssertEqual(try OutboxDAO(reopened).totalCount(), 0)
    }
}
