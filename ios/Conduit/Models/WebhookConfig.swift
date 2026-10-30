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

/// The public demo receiver (`https://health.noebrito.dev/webhook-test`) renders
/// everything it receives on a world-readable page for 30 minutes
/// (`docs/webhook/README.md`). Sensitive types (`HealthDataType.isSensitive`,
/// i.e. cycle tracking) are never sent there: the app neither stages them while
/// it is the configured destination (`SyncEngine`'s read paths) nor drains
/// already-staged rows to it (`Batcher.buildBatch`'s exclusion), so rows staged
/// for the user's own receiver stay queued until the destination changes. The
/// demo receiver also drops these types server-side; this is the app-side half.
enum DemoReceiver {
    static let host = "health.noebrito.dev"
    static let path = "/webhook-test"

    /// Whether `urlString` points at the demo receiver. Host match is
    /// case-insensitive and ignores a trailing dot; the path matches with or
    /// without a trailing slash and any sub-path, query or fragment.
    static func matches(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              var host = components.host?.lowercased()
        else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        guard host == Self.host else { return false }
        let requestPath = components.path.lowercased()
        return requestPath == path || requestPath.hasPrefix(path + "/")
    }

    /// The registry identifiers that must never be sent to `urlString`: every
    /// sensitive type when it is the demo receiver, otherwise none.
    static func blockedTypeIDs(forURL urlString: String, registry: HealthTypeRegistry = .shared) -> Set<String> {
        guard matches(urlString) else { return [] }
        return Set(registry.all.filter(\.isSensitive).map(\.identifier))
    }

    /// Consent copy for sensitive picker groups (Settings and onboarding).
    static let sensitiveConsentFooter = "Cycle tracking entries describe your reproductive health. They stay off until you turn them on, iOS asks for permission when you do, and Conduit sends them only to the webhook you configured, never to the public demo receiver."

    /// In-app copy shown wherever sensitive types are toggled or saved while the
    /// demo receiver is the destination.
    static let refusalMessage = "Cycle Tracking isn't sent to the public demo receiver, because it shows everything it receives on a public page. Point Conduit at a webhook you control to send it."
}
