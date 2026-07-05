import Foundation
import GRDB

/// A configured webhook destination (ARCHITECTURE.md §4.7 `webhook_config`).
///
/// The v1 UI exposes a single webhook, but the schema supports many so adding
/// multi-webhook later is UI work, not a migration. The bearer token itself is
/// never stored here — only a Keychain reference; the secret lives in the
/// Keychain (§8).
struct WebhookConfig: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    /// Destination URL the envelopes are POSTed to.
    var url: String
    /// Keychain account name where the bearer token is stored (see `KeychainStore`).
    var bearerTokenKeychainRef: String
    /// Minimum seconds between flushes (throttle time gate).
    var minIntervalSeconds: Int
    /// Maximum samples drained into a single batch/envelope.
    var batchMaxSize: Int
    /// Pending-row count that forces an immediate flush regardless of the time gate.
    var forceFlushThreshold: Int
    /// Hard cap on outbox rows retained before back-pressure kicks in.
    var outboxCap: Int
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "webhook_config"

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case bearerTokenKeychainRef = "bearer_token_keychain_ref"
        case minIntervalSeconds = "min_interval_seconds"
        case batchMaxSize = "batch_max_size"
        case forceFlushThreshold = "force_flush_threshold"
        case outboxCap = "outbox_cap"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// GRDB writes the autoincrement rowid back after insert.
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension WebhookConfig {
    /// Sensible defaults for a freshly created webhook, per the throttle design
    /// in ARCHITECTURE.md §4.4–4.5.
    static func makeDefault(url: String, bearerTokenKeychainRef: String, now: Date = Date()) -> WebhookConfig {
        WebhookConfig(
            id: nil,
            url: url,
            bearerTokenKeychainRef: bearerTokenKeychainRef,
            minIntervalSeconds: 900,        // 15 min
            batchMaxSize: 500,
            forceFlushThreshold: 200,
            outboxCap: 50_000,
            createdAt: now,
            updatedAt: now
        )
    }
}
