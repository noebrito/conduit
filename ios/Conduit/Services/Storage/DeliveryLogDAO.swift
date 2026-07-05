import Foundation
import GRDB

/// Read-only access to the `delivery_log` ring buffer (ARCHITECTURE.md §4.7).
///
/// Writes happen exclusively in `Uploader` to maintain the 500-row cap invariant.
struct DeliveryLogDAO {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    func recent(limit: Int = 100) throws -> [DeliveryLogEntry] {
        try database.dbWriter.read { db in
            try DeliveryLogEntry
                .order(Column("sent_at").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func latest() throws -> DeliveryLogEntry? {
        try database.dbWriter.read { db in
            try DeliveryLogEntry
                .order(Column("sent_at").desc, Column("id").desc)
                .fetchOne(db)
        }
    }

    /// Returns the outbox rows associated with a batch, for per-type breakdown.
    func outboxRows(batchId: String) throws -> [OutboxRow] {
        try database.dbWriter.read { db in
            try OutboxRow
                .filter(Column("batch_id") == batchId)
                .fetchAll(db)
        }
    }

    /// Re-enqueue failed rows for a batch (retry action).
    func retryBatch(batchId: String) throws {
        try database.dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE outbox
                    SET state = 'pending',
                        attempt_count = 0,
                        next_attempt_at = NULL,
                        last_error = NULL
                    WHERE batch_id = ? AND state = 'failed'
                    """,
                arguments: [batchId]
            )
        }
    }
}
