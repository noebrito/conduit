import Foundation
import GRDB

/// Per-HealthKit-type sync configuration and anchor state
/// (ARCHITECTURE.md §4.7 `data_type_config`).
///
/// One row per HK type the user has enabled. `anchorBlob` is the archived
/// `HKQueryAnchor` for incremental reads — it MUST only ever be advanced in the
/// same transaction that enqueues the samples that anchor covers (§4.4). See
/// `AnchoredReader` and `OutboxDAO.ingest(...)`.
struct DataTypeConfig: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    /// HealthKit type identifier string, e.g. `HKQuantityTypeIdentifierHeartRate`.
    var hkTypeId: String
    /// Whether the user has enabled syncing for this type.
    var enabled: Bool
    /// Optional per-type override of the webhook's `minIntervalSeconds`.
    var minIntervalSeconds: Int?
    /// Archived `HKQueryAnchor` (NSKeyedArchiver). Nil means "read from the start".
    var anchorBlob: Data?
    /// Last time a read for this type completed successfully.
    var lastSyncAt: Date?
    /// Last time a read was attempted (success or failure).
    var lastAttemptAt: Date?
    /// The forward-only capture floor: the point in time from which this type
    /// started capturing. Set once, on the very first (anchor-less) read, and
    /// used as the `withStart:` predicate so first-run capture skips existing
    /// history and only stages samples created at/after setup (ARCHITECTURE.md
    /// §4.4, forward-only default). Nil until the first read seeds it.
    var captureStartedAt: Date? = nil

    var id: String { hkTypeId }

    static let databaseTableName = "data_type_config"

    enum CodingKeys: String, CodingKey {
        case hkTypeId = "hk_type_id"
        case enabled
        case minIntervalSeconds = "min_interval_seconds"
        case anchorBlob = "anchor_blob"
        case lastSyncAt = "last_sync_at"
        case lastAttemptAt = "last_attempt_at"
        case captureStartedAt = "capture_started_at"
    }
}
