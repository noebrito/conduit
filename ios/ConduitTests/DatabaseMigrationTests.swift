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
            ]
            for column in expected {
                XCTAssertTrue(columns.contains(column), "outbox missing column: \(column)")
            }
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

    func testRemigrationIsIdempotent() throws {
        // Running the same migrator over an already-migrated DB is a no-op.
        let appDB = try AppDatabase.makeInMemory()
        XCTAssertNoThrow(try appDB.migrator.migrate(appDB.dbWriter))
    }
}
