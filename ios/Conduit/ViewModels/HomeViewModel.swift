import Foundation
import Observation
import GRDB
import os

private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "HomeViewModel")

/// Drives the Home screen status, counts, and Sync Now action.
@Observable
final class HomeViewModel {
    enum SyncStatus: Equatable {
        case idle
        case synced(Date)
        case error(String)
    }

    /// The persisted sync status (last-synced time / last error / never synced).
    /// The transient "a sync is running right now" state is tracked separately by
    /// `isSyncing` so an in-flight completion can update `syncStatus` without the
    /// two fighting.
    private(set) var syncStatus: SyncStatus = .idle
    /// True only while a manually-triggered "Sync Now" is in progress.
    private(set) var isSyncing: Bool = false
    /// Cumulative number of samples *staged (enqueued) today*, read from the
    /// persisted `staged_daily_count` tally — NOT a live count of outbox rows.
    ///
    /// It must be the persisted tally because since #505 a successful upload
    /// DELETES the delivered outbox row, so counting today's rows still in the
    /// outbox would collapse to the live Pending count and *shrink* as the queue
    /// drains. The tally instead only ever grows as new samples stage today and
    /// resets at the local-day boundary (each day is its own bucket). The bucket
    /// key is the enqueue timestamp's local day, NOT the health sample's recorded
    /// date, so the UI labels it "Staged today" rather than "Samples today".
    private(set) var stagedTodayCount: Int = 0
    private(set) var pendingCount: Int = 0
    private(set) var failedCount: Int = 0

    private let appState: AppState
    private var observationCancellable: AnyDatabaseCancellable?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        Task { await loadInitialStatus() }
        observeOutbox()
    }

    func stop() {}

    func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        await appState.syncEngine.flushNow()
        // For an empty-but-successful sync the stamp already landed synchronously
        // inside flushNow, so this reflects it immediately. For a batch upload the
        // stamp lands later on the background URLSession completion — the outbox
        // observation picks that up reactively (see `observeOutbox`).
        await loadInitialStatus()
    }

    // MARK: - Private

    /// Derive the persisted sync status from the last-synced stamp and the most
    /// recent delivery-log entry. Pure so it can be unit-tested without a DB.
    ///
    /// A failed delivery that is newer than the last success surfaces as an error;
    /// otherwise the last successful-sync stamp wins. `latestDelivery` is only used
    /// to (a) detect a fresh failure and (b) back-fill the synced time for installs
    /// that delivered before the `sync_state` stamp existed.
    static func deriveStatus(lastSynced: Date?, latestDelivery: DeliveryLogEntry?) -> SyncStatus {
        if let latest = latestDelivery, !latest.isSuccess,
           lastSynced == nil || latest.sentAt > lastSynced! {
            return .error(latest.errorMessage ?? "Unknown error")
        }
        if let lastSynced {
            return .synced(lastSynced)
        }
        if let latest = latestDelivery, latest.isSuccess {
            return .synced(latest.sentAt)
        }
        return .idle
    }

    /// Load the Home stats **off the main thread**, then publish on the main
    /// actor. The reads run inside a single `dbWriter.read` block on a background
    /// executor so a large import's in-flight write transaction can't stall the
    /// main thread while Home is on screen (the old synchronous main-thread read
    /// blocked behind bulk import inserts → visible UI hitches). Steady-state
    /// updates flow reactively through `observeOutbox`; this async load only
    /// primes the very first frame and refreshes after a manual "Sync Now".
    private func loadInitialStatus() async {
        do {
            let snapshot = try await appState.database.dbWriter.read { db -> StatusSnapshot in
                let pending = try OutboxRow
                    .filter(Column("state") == OutboxState.pending.rawValue ||
                            Column("state") == OutboxState.inflight.rawValue)
                    .fetchCount(db)
                let failed = try OutboxRow
                    .filter(Column("state") == OutboxState.failed.rawValue)
                    .fetchCount(db)
                let today = try StagedDailyCountDAO.count(db)
                let status = Self.deriveStatus(
                    lastSynced: try SyncStateDAO.lastSyncedAt(db),
                    latestDelivery: try DeliveryLogEntry
                        .order(Column("sent_at").desc, Column("id").desc)
                        .fetchOne(db)
                )
                return StatusSnapshot(pending: pending, failed: failed, today: today, status: status)
            }
            await MainActor.run {
                self.pendingCount = snapshot.pending
                self.failedCount = snapshot.failed
                self.stagedTodayCount = snapshot.today
                self.syncStatus = snapshot.status
            }
        } catch {
            logger.error("Failed to load home stats: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Snapshot the observation computes on every relevant DB change.
    private struct StatusSnapshot {
        let pending: Int
        let failed: Int
        let today: Int
        let status: SyncStatus
    }

    private func observeOutbox() {
        let observation = ValueObservation.tracking { db -> StatusSnapshot in
            let pending = try OutboxRow
                .filter(Column("state") == OutboxState.pending.rawValue ||
                        Column("state") == OutboxState.inflight.rawValue)
                .fetchCount(db)
            let failed = try OutboxRow
                .filter(Column("state") == OutboxState.failed.rawValue)
                .fetchCount(db)
            // "Staged today" is the persisted tally, not a live outbox row count,
            // so it keeps rising as the queue drains (delivered rows are deleted).
            let today = try StagedDailyCountDAO.count(db)
            // Track the sync-completion stamp + latest delivery so the "Synced X
            // ago" label updates reactively the moment a background upload lands
            // (or an empty flush stamps). The relative-time wording itself is
            // ticked forward by the HomeView TimelineView, not a DB-reading timer.
            let status = Self.deriveStatus(
                lastSynced: try SyncStateDAO.lastSyncedAt(db),
                latestDelivery: try DeliveryLogEntry
                    .order(Column("sent_at").desc, Column("id").desc)
                    .fetchOne(db)
            )
            return StatusSnapshot(pending: pending, failed: failed, today: today, status: status)
        }

        observationCancellable = observation.start(
            in: appState.database.dbWriter,
            onError: { error in
                logger.error("Outbox observation error: \(error.localizedDescription, privacy: .public)")
            },
            onChange: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.pendingCount = snapshot.pending
                    self?.failedCount = snapshot.failed
                    self?.stagedTodayCount = snapshot.today
                    self?.syncStatus = snapshot.status
                }
            }
        )
    }

    var syncStatusLabel: String {
        if isSyncing { return "Syncing…" }
        switch syncStatus {
        case .idle: return "No syncs yet"
        case .synced(let date):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "Synced \(formatter.localizedString(for: date, relativeTo: Date()))"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var statusIsError: Bool {
        if isSyncing { return false }
        if case .error = syncStatus { return true }
        return false
    }
}
