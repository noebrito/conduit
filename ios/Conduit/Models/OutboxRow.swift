import Foundation
import GRDB

/// Delivery state of an outbox row (ARCHITECTURE.md §4.7).
enum OutboxState: String, Codable, DatabaseValueConvertible {
    case pending
    case inflight
    case sent
    case failed
}

/// What a staged outbox row asks the ingester to do.
///
/// - `upsert`: create the sample's document (the default; every pre-existing row
///   is an upsert, which is why the migration defaults the column to it).
/// - `delete`: a **tombstone** — a HealthKit-deleted sample whose document must
///   be removed from OpenSearch so an edited/removed food doesn't leave a ghost
///   that inflates nutrition totals. A tombstone carries only
///   `{hk_sample_uuid, hk_type_id}` and an empty `payload_blob`.
enum OutboxOp: String, Codable, DatabaseValueConvertible {
    case upsert
    case delete
}

/// A single staged HealthKit sample awaiting (or completing) delivery
/// (ARCHITECTURE.md §4.7 `outbox`).
///
/// `hkSampleUuid` is UNIQUE — re-observed samples (e.g. after a permission flip)
/// are `INSERT OR IGNORE`d, never duplicated (§4.4). `payloadBlob` holds the
/// proto3-canonical-JSON encoding of the `Conduit_V1_Sample` so the batcher (I3)
/// can reassemble envelopes without re-reading HealthKit.
struct OutboxRow: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    /// FK to the destination `webhook_config` row.
    var webhookId: Int64
    /// HealthKit sample UUID — the dedupe key (UNIQUE column).
    var hkSampleUuid: String
    /// HealthKit type identifier string this sample belongs to.
    var hkTypeId: String
    /// Whether this row upserts the sample or is a delete tombstone. Defaults to
    /// `.upsert` so decoding a pre-`op` row (and the upsert insert path, which
    /// omits the column and relies on its `DEFAULT 'upsert'`) is unchanged.
    var op: OutboxOp = .upsert
    /// Serialized `Conduit_V1_Sample` (proto3 canonical JSON). Empty for a
    /// tombstone (`op == .delete`), which has no payload.
    var payloadBlob: Data
    var createdAt: Date
    var state: OutboxState
    /// Batch this row was last assigned to (set when moved to `inflight`).
    var batchId: String?
    var attemptCount: Int
    /// Earliest time this row may be retried (backoff schedule).
    var nextAttemptAt: Date?
    var lastError: String?
    /// When this row was last marked `.inflight` (migration `v10-outbox-inflight-at`).
    /// `nil` for a row that has never been batched, or one marked inflight
    /// before this column existed. Drives `OutboxDAO.reclaimStaleInflight`'s
    /// time-based staleness check, independent of whether the background
    /// `URLSession` still reports the batch as active.
    var inflightAt: Date?

    static let databaseTableName = "outbox"

    enum CodingKeys: String, CodingKey {
        case id
        case webhookId = "webhook_id"
        case hkSampleUuid = "hk_sample_uuid"
        case hkTypeId = "hk_type_id"
        case op
        case payloadBlob = "payload_blob"
        case createdAt = "created_at"
        case state
        case batchId = "batch_id"
        case attemptCount = "attempt_count"
        case nextAttemptAt = "next_attempt_at"
        case lastError = "last_error"
        case inflightAt = "inflight_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
