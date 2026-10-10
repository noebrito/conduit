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
    /// Archived `HKQueryAnchor` (NSKeyedArchiver). See `SyncEngine.handleObserverWake`
    /// for initialization when nil.
    var anchorBlob: Data?
    /// Last time a read for this type completed successfully.
    var lastSyncAt: Date?
    /// Last time a read was attempted (success or failure).
    var lastAttemptAt: Date?
    /// Persisted lower bound for an anchor-less read; nil until first seeded.
    /// Seeding semantics live in `SyncEngine.forwardCaptureFloor`, and reuse
    /// lives in `SyncEngine.handleObserverWake`.
    var captureStartedAt: Date? = nil
    var ingestRevision: Int64 = 0

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
        case ingestRevision = "ingest_revision"
    }
}
