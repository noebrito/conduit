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
    var syncStatus: SyncStatus { appState.status.status }
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
    var stagedTodayCount: Int { appState.status.stagedToday(asOf: Date()) }
    var pendingCount: Int { appState.status.pending }
    var failedCount: Int { appState.status.failed }

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        // Everything this screen shows comes from `AppState.status`, which the
        // shared observation republishes the moment the flush writes — whether
        // the stamp lands synchronously (an empty-but-successful sync) or later
        // on the background URLSession completion.
        await appState.syncEngine.flushNow()
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

    /// Snapshot of the app's sync status, recomputed on every relevant DB change
    /// by the single observation in `AppState` and consumed both by this screen
    /// and by the Lock Screen widget's transport type.
    struct StatusSnapshot {
        let pending: Int
        let failed: Int
        let today: Int
        /// The local start-of-day `today` was tallied for — `staged_daily_count`
        /// is bucketed per day, so the count means nothing without it.
        let todayStart: Date
        let lastSynced: Date?
        let status: SyncStatus

        /// The staged tally as of `now`, which is 0 once the local day has moved
        /// on from the one it was counted for. This snapshot is only recomputed
        /// when a tracked table is written, and a clock crossing midnight is not
        /// a write — so the reader's own clock, not the fetch's, decides what
        /// "today" means.
        func stagedToday(asOf now: Date, calendar: Calendar = .current) -> Int {
            calendar.isDate(todayStart, inSameDayAs: now) ? today : 0
        }
    }

    /// The single place these status counts are read from the database.
    static func fetchStatus(_ db: Database) throws -> StatusSnapshot {
        let pending = try OutboxRow
            .filter(Column("state") == OutboxState.pending.rawValue ||
                    Column("state") == OutboxState.inflight.rawValue)
            .fetchCount(db)
        let failed = try OutboxRow
            .filter(Column("state") == OutboxState.failed.rawValue)
            .fetchCount(db)
        // "Staged today" is the persisted tally, not a live outbox row count,
        // so it keeps rising as the queue drains (delivered rows are deleted).
        let todayStart = StagedDailyCountDAO.day(for: Date())
        let today = try StagedDailyCountDAO.count(db, on: todayStart)
        // Track the sync-completion stamp + latest delivery so the "Synced X
        // ago" label updates reactively the moment a background upload lands
        // (or an empty flush stamps). The relative-time wording itself is
        // ticked forward by the HomeView TimelineView, not a DB-reading timer.
        let lastSynced = try SyncStateDAO.lastSyncedAt(db)
        let status = deriveStatus(
            lastSynced: lastSynced,
            latestDelivery: try DeliveryLogEntry
                .order(Column("sent_at").desc, Column("id").desc)
                .fetchOne(db)
        )
        return StatusSnapshot(
            pending: pending,
            failed: failed,
            today: today,
            todayStart: todayStart,
            lastSynced: lastSynced,
            status: status
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
