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

    /// The result of one batch build. Carries everything `Uploader` needs.
    struct BatchResult {
        let batchID: String
        let rowIDs: [Int64]
        let encodedJSON: Data
    }

    init(database: AppDatabase) {
        self.database = database
    }

    /// Drain up to `limit` pending rows, group them by `hk_type_id`, build an
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
            drainedRows = try OutboxRow
                .filter(Column("state") == OutboxState.pending.rawValue)
                .filter(Column("next_attempt_at") == nil || Column("next_attempt_at") <= now)
                .order(Column("created_at").asc)
                .limit(limit)
                .fetchAll(db)

            guard !drainedRows.isEmpty else { return }

            let ids = drainedRows.compactMap(\.id)
            try OutboxRow
                .filter(ids.contains(Column("id")))
                .updateAll(
                    db,
                    Column("state").set(to: OutboxState.inflight.rawValue),
                    Column("batch_id").set(to: batchID)
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
            batch.samples = rows.compactMap { row in
                try? Conduit_V1_Sample(jsonUTF8Data: row.payloadBlob)
            }
            envelope.batches.append(batch)
        }

        let encodedJSON = try envelope.jsonUTF8Data()
        let rowIDs = drainedRows.compactMap(\.id)

        logger.info("Built batch \(batchID, privacy: .public) with \(rowIDs.count) rows across \(grouped.count) types")
        return BatchResult(batchID: batchID, rowIDs: rowIDs, encodedJSON: encodedJSON)
    }
}
