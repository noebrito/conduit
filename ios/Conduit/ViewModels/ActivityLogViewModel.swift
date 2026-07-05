import Foundation
import Observation
import GRDB
import os

private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "ActivityLogViewModel")

/// Drives the Activity Log screen — delivery log list with filter chips and retry support.
@Observable
final class ActivityLogViewModel {
    enum Filter: String, CaseIterable {
        case all = "All"
        case sent = "Sent"
        case failed = "Failed"
    }

    private(set) var entries: [DeliveryLogEntry] = []
    var filter: Filter = .all
    private var observation: AnyDatabaseCancellable?

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        let obs = ValueObservation.tracking { db in
            try DeliveryLogEntry
                .order(Column("sent_at").desc)
                .limit(200)
                .fetchAll(db)
        }
        observation = obs.start(
            in: appState.database.dbWriter,
            onError: { error in
                logger.error("Activity log observation error: \(error.localizedDescription, privacy: .public)")
            },
            onChange: { [weak self] entries in
                Task { @MainActor [weak self] in
                    self?.entries = entries
                }
            }
        )
    }

    var filteredEntries: [DeliveryLogEntry] {
        switch filter {
        case .all: return entries
        case .sent: return entries.filter(\.isSuccess)
        case .failed: return entries.filter { !$0.isSuccess }
        }
    }

    func retryBatch(_ entry: DeliveryLogEntry) async {
        do {
            try DeliveryLogDAO(appState.database).retryBatch(batchId: entry.batchId)
            await appState.syncEngine.flushNow()
        } catch {
            logger.error("Retry batch error: \(error.localizedDescription, privacy: .public)")
        }
    }

    func outboxRowsByType(batchId: String) -> [String: Int] {
        let rows = (try? DeliveryLogDAO(appState.database).outboxRows(batchId: batchId)) ?? []
        var counts: [String: Int] = [:]
        for row in rows {
            counts[row.hkTypeId, default: 0] += 1
        }
        return counts
    }
}
