import Foundation
import GRDB

/// One row from the `delivery_log` ring-buffer table (ARCHITECTURE.md §4.7).
///
/// Written by `Uploader` after each batch upload attempt. Capped at ~500 rows.
/// Used by the Activity Log screen.
struct DeliveryLogEntry: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var batchId: String
    var sentAt: Date
    var httpStatus: Int?
    var sampleCount: Int
    var errorMessage: String?
    /// New documents the ingester actually wrote (from the 200 body). `nil` for
    /// non-2xx deliveries or rows written before the v3 migration.
    var accepted: Int?
    /// Documents the ingester rejected as already-indexed duplicates (409).
    var deduped: Int?

    static let databaseTableName = "delivery_log"

    enum CodingKeys: String, CodingKey {
        case id
        case batchId = "batch_id"
        case sentAt = "sent_at"
        case httpStatus = "http_status"
        case sampleCount = "sample_count"
        case errorMessage = "error_message"
        case accepted
        case deduped
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var isSuccess: Bool {
        errorMessage == nil && httpStatus.map { (200...299).contains($0) } ?? false
    }

    var statusLabel: String {
        if let status = httpStatus {
            return "HTTP \(status)"
        }
        return errorMessage != nil ? "Error" : "Unknown"
    }

    /// One-line write outcome for a successful delivery, e.g. "500 sent · 0 new"
    /// (all duplicates) vs "500 sent · 500 new". `nil` when the write outcome is
    /// unknown (non-2xx, or a row from before the v3 migration recorded it).
    var writeOutcomeLabel: String? {
        guard isSuccess, let accepted else { return nil }
        return "\(sampleCount) sent · \(accepted) new"
    }

    /// `true` for a successful batch where the ingester wrote zero new docs —
    /// every sample was already indexed (a dedupe-only upload). This is the
    /// state that used to be invisible: a 200 that changed nothing.
    var isAllDeduped: Bool {
        isSuccess && (accepted == 0) && (deduped ?? 0) > 0
    }
}
