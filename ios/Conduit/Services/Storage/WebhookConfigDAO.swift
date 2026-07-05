import Foundation
import GRDB

/// CRUD for `webhook_config` rows (ARCHITECTURE.md §4.7).
struct WebhookConfigDAO {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    /// Insert a new config (id == nil) or update an existing one. `updatedAt` is
    /// always refreshed. The id is written back into the passed value on insert.
    @discardableResult
    func save(_ config: inout WebhookConfig, now: Date = Date()) throws -> WebhookConfig {
        config.updatedAt = now
        var copy = config
        try database.dbWriter.write { db in
            try copy.save(db)
        }
        config = copy
        return copy
    }

    /// All configured webhooks, newest first.
    func all() throws -> [WebhookConfig] {
        try database.dbWriter.read { db in
            try WebhookConfig
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    /// The single webhook the v1 UI manages (the most recently created), if any.
    func first() throws -> WebhookConfig? {
        try database.dbWriter.read { db in
            try WebhookConfig
                .order(Column("created_at").desc)
                .fetchOne(db)
        }
    }

    func find(id: Int64) throws -> WebhookConfig? {
        try database.dbWriter.read { db in
            try WebhookConfig.fetchOne(db, key: id)
        }
    }

    /// Delete a webhook. Outbox rows referencing it cascade away (§4.7 FK).
    @discardableResult
    func delete(id: Int64) throws -> Bool {
        try database.dbWriter.write { db in
            try WebhookConfig.deleteOne(db, key: id)
        }
    }
}
