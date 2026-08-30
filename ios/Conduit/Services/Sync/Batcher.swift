import Foundation
import GRDB
import SwiftProtobuf
import os

/// Drains pending outbox rows into a serialized `Envelope` proto ready for upload
/// (ARCHITECTURE.md §4.4 — Batch step).
///
/// The drain + mark-inflight is a single GRDB write transaction so that a crash
/// between the two steps never leaves rows in an ambiguous state. `reconcileInflight`
/// in `Uploader` recovers from such crashes on next launch anyway, but the atomic
/// transaction minimises the recovery surface.
struct Batcher {
    private let database: AppDatabase
    private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "Batcher")

    /// Ceiling on the summed `payload_blob` bytes drained into one batch, applied
    /// on top of the row-count `limit` — whichever binds first stops the drain.
    ///
    /// The ingester caps a request body at 16 MiB (`ingester/http/handlers.go`
    /// `maxBodyBytes`) via `http.MaxBytesReader`; an over-cap body answers 400,
    /// which `Uploader` treats as a PERMANENT failure and marks the rows `failed`
    /// — so those samples, plus every unrelated sample batched with them, are lost
    /// for good rather than retried. 8 MiB leaves room for envelope/JSON overhead
    /// on top of the raw blobs. Never raise this to or past the ingester's cap.
    static let maxBatchPayloadBytes = 8 * 1024 * 1024

    /// The result of one batch build. Carries everything `Uploader` needs.
    struct BatchResult {
        let batchID: String
        let rowIDs: [Int64]
        let encodedJSON: Data
    }

    init(database: AppDatabase) {
        self.database = database
    }

    /// Drain up to `limit` pending rows — or fewer, when `maxBatchPayloadBytes` of
    /// payload is reached first — group them by `hk_type_id`, build an
    /// `Envelope` proto, JSON-encode it, and atomically mark the rows `inflight`.
    ///
    /// Returns `nil` when there are no rows ready to send (outbox is empty or
    /// all rows are still in backoff).
    func buildBatch(
        webhookID: Int64,
        limit: Int,
        deviceID: String,
        now: Date = Date()
    ) throws -> BatchResult? {
        let batchID = UUID().uuidString
        var drainedRows: [OutboxRow] = []

        try database.dbWriter.write { db in
            // Drain and mark inflight atomically in one transaction.
            //
            // The walk is lazy so peak memory tracks the ceiling rather than
            // `limit` × row size: a route row is ~0.5-1 MB, so materializing all
            // 500 candidates just to discard them down to 8 MiB would be a
            // hundreds-of-MB spike on a background wake. The first row is always
            // taken even when it alone exceeds the ceiling — sending it alone is
            // the only way it ever drains, and skipping it would wedge every row
            // behind it. Rows left behind stay `pending` for the next batch.
            let cursor = try OutboxRow
                .filter(Column("state") == OutboxState.pending.rawValue)
                .filter(Column("next_attempt_at") == nil || Column("next_attempt_at") <= now)
                .order(Column("created_at").asc)
                .limit(limit)
                .fetchCursor(db)

            var bytes = 0
            while let row = try cursor.next() {
                let size = row.payloadBlob.count
                if !drainedRows.isEmpty, bytes + size > Batcher.maxBatchPayloadBytes {
                    break
                }
                drainedRows.append(row)
                bytes += size
            }

            guard !drainedRows.isEmpty else { return }

            let ids = drainedRows.compactMap(\.id)
            try OutboxRow
                .filter(ids.contains(Column("id")))
                .updateAll(
                    db,
                    Column("state").set(to: OutboxState.inflight.rawValue),
                    Column("batch_id").set(to: batchID),
                    Column("inflight_at").set(to: now)
                )
        }

        guard !drainedRows.isEmpty else { return nil }

        // Group by hk_type_id and reassemble proto samples from stored blobs.
        let grouped = Dictionary(grouping: drainedRows, by: \.hkTypeId)

        var envelope = Conduit_V1_Envelope()
        envelope.schemaVersion = "v1"
        envelope.batchID = batchID
        envelope.deviceID = deviceID
        envelope.sentAtUnixMs = Int64(now.timeIntervalSince1970 * 1000)

        for (typeID, rows) in grouped {
            var batch = Conduit_V1_SampleBatch()
            batch.hkTypeID = typeID
            // Partition each type's rows: upserts decode their payload into
            // `samples`; delete tombstones contribute their uuid to
            // `deleted_uuids` (no payload). An upsert-only group leaves
            // `deletedUuids` empty, so the proto omits the field and the wire is
            // byte-identical to before deletions existed.
            var samples: [Conduit_V1_Sample] = []
            var deletedUuids: [String] = []
            for row in rows {
                switch row.op {
                case .delete:
                    deletedUuids.append(row.hkSampleUuid)
                case .upsert:
                    if let sample = try? Conduit_V1_Sample(jsonUTF8Data: row.payloadBlob) {
                        samples.append(sample)
                    }
                }
            }
            batch.samples = samples
            batch.deletedUuids = deletedUuids
            envelope.batches.append(batch)
        }

        let encodedJSON = try envelope.jsonUTF8Data()
        let rowIDs = drainedRows.compactMap(\.id)

        logger.info("Built batch \(batchID, privacy: .public) with \(rowIDs.count) rows across \(grouped.count) types")
        return BatchResult(batchID: batchID, rowIDs: rowIDs, encodedJSON: encodedJSON)
    }
}
