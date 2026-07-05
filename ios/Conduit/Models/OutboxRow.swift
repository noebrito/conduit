import Foundation
import GRDB

/// Delivery state of an outbox row (ARCHITECTURE.md §4.7).
enum OutboxState: String, Codable, DatabaseValueConvertible {
    case pending
    case inflight
    case sent
    case failed
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
    /// Serialized `Conduit_V1_Sample` (proto3 canonical JSON).
    var payloadBlob: Data
    var createdAt: Date
    var state: OutboxState
    /// Batch this row was last assigned to (set when moved to `inflight`).
    var batchId: String?
    var attemptCount: Int
    /// Earliest time this row may be retried (backoff schedule).
    var nextAttemptAt: Date?
    var lastError: String?

    static let databaseTableName = "outbox"

    enum CodingKeys: String, CodingKey {
        case id
        case webhookId = "webhook_id"
        case hkSampleUuid = "hk_sample_uuid"
        case hkTypeId = "hk_type_id"
        case payloadBlob = "payload_blob"
        case createdAt = "created_at"
        case state
        case batchId = "batch_id"
        case attemptCount = "attempt_count"
        case nextAttemptAt = "next_attempt_at"
        case lastError = "last_error"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
