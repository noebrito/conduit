import Foundation

/// Snapshot of Conduit's sync status, written to the shared App Group container
/// by the app and read by the Lock Screen widget extension.
///
/// This is deliberately a small transport type rather than a shared database:
/// the widget extension never opens GRDB or the app's SQLite file (memory
/// ceiling in an extension is tight and undocumented by Apple, and two
/// processes writing one SQLite file is its own hazard). Target membership:
/// `Conduit` (the writer, via `AppState`) and `ConduitWidgets` (the reader).
///
/// Sync-status data only. Never a health value (steps, heart rate, etc.) — the
/// captain's decision that this surface stays permanently out of scope for
/// health data (`data/conduit-live-activities-scout/report.md` §9.2/§9.3).
struct ConduitStatusSnapshot: Codable, Equatable {
    enum SyncStatus: String, Codable {
        case idle
        case synced
        case error
    }

    var syncStatus: SyncStatus
    var lastSyncedAt: Date?
    var pendingCount: Int
    var failedCount: Int
    var stagedTodayCount: Int
    /// The local start-of-day `stagedTodayCount` was tallied for.
    ///
    /// `staged_daily_count` is bucketed per local day, so the count is only
    /// true for the day it was read on — and a clock crossing midnight is not a
    /// database write, so the observation that produces this snapshot never
    /// re-fires for it. Carrying the bucket key lets the reader decide, against
    /// its own clock, whether the count still describes "today".
    var stagedTodayDay: Date
    /// `SettingsViewModel.statusTitle(for:)`'s wording, verbatim, when the most
    /// recent import run is not `.completed`. `nil` when there is no run or the
    /// run completed — the widget then falls back to pending/staged counts.
    var importStatusHeadline: String?

    static let appGroupIdentifier = "group.dev.noebrito.Conduit"
    private static let fileName = "conduit_status_snapshot.json"

    /// Resolved once per process: `containerURL(forSecurityApplicationGroupIdentifier:)`
    /// is an IPC round-trip to containermanagerd, and this is on the path taken
    /// after every committed transaction.
    private static let containerURL: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)

    // MARK: - Pure codec (directly testable without an App Group container)

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> ConduitStatusSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(ConduitStatusSnapshot.self, from: data)
    }

    // MARK: - App Group transport

    /// Atomic write so a concurrent widget-extension read never observes a
    /// partially-written file.
    func writeToAppGroup() throws {
        guard let containerURL = Self.containerURL else {
            throw ConduitStatusSnapshotError.appGroupContainerUnavailable
        }
        let data = try encoded()
        try data.write(to: containerURL.appendingPathComponent(Self.fileName), options: .atomic)
    }

    static func readFromAppGroup() -> ConduitStatusSnapshot? {
        guard let containerURL,
              let data = try? Data(contentsOf: containerURL.appendingPathComponent(fileName)) else {
            return nil
        }
        return try? decoded(from: data)
    }

    // MARK: - Pure view helpers, shared by the widget's three accessory families

    /// The staged tally as of `now`, which is 0 once the local day has moved on
    /// from the one it was counted for. The snapshot in the container can be
    /// arbitrarily old — nothing rewrites it until the next database write — so
    /// the reader's own clock, not the writer's, decides what "today" means.
    func stagedToday(asOf now: Date, calendar: Calendar = .current) -> Int {
        calendar.isDate(stagedTodayDay, inSameDayAs: now) ? stagedTodayCount : 0
    }

    /// Second line for `accessoryRectangular`, first match wins. Reuses the
    /// app's existing wording (via `importStatusHeadline`, already produced by
    /// `SettingsViewModel.statusTitle(for:)`) rather than inventing new copy
    /// for the same states.
    ///
    /// `now` is the date of the timeline entry being rendered, so the staged
    /// tally is judged against the moment the user actually sees it.
    static func secondLine(for snapshot: ConduitStatusSnapshot, now: Date, calendar: Calendar = .current) -> String {
        if snapshot.failedCount > 0 {
            return "\(snapshot.failedCount) failed"
        }
        if let importStatusHeadline = snapshot.importStatusHeadline {
            return importStatusHeadline
        }
        if snapshot.pendingCount > 0 {
            return "\(snapshot.pendingCount) pending"
        }
        return "Staged today \(snapshot.stagedToday(asOf: now, calendar: calendar))"
    }

    /// Entry dates for one timeline: `now`, plus the next local midnight.
    ///
    /// The midnight entry is what makes `stagedToday(asOf:)` land on time. A
    /// timeline holding one entry renders that entry's date until the next
    /// rebuild, and a rebuild is something WidgetKit treats as a hint rather
    /// than a promise — Low Power Mode suspends refreshes outright, and a
    /// rarely-surfaced widget gets throttled — so the boundary is carried
    /// unconditionally rather than only when it happens to fall inside one
    /// refresh interval. Extra entries inside a timeline are free; only
    /// rebuilding one is budgeted.
    static func timelineEntryDates(from now: Date, calendar: Calendar = .current) -> [Date] {
        guard let midnight = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else {
            return [now]
        }
        return [now, midnight]
    }

    /// Symbol for `accessoryCircular`. The Lock Screen renders widgets in
    /// vibrant (desaturated) mode, so the symbol — never a tint color — must
    /// carry the state.
    static func symbolName(for snapshot: ConduitStatusSnapshot) -> String {
        if snapshot.failedCount > 0 || snapshot.syncStatus == .error {
            return "exclamationmark.triangle"
        }
        if snapshot.syncStatus == .idle {
            return "clock.badge.exclamationmark"
        }
        return "checkmark.circle"
    }

    /// Whether moving from `previous` to `next` is a state-*class* change that
    /// justifies spending a `WidgetCenter.reloadAllTimelines()` call: an error
    /// appearing/clearing, the import headline changing, the failed count
    /// crossing zero, or the very first sync leaving `.idle`. Deliberately NOT
    /// true for a timestamp/count-only change — Conduit's background cadence
    /// (≥96 `BGAppRefreshTask` wakes/day, plus HealthKit observer wakes) would
    /// exhaust the widget's daily reload budget if every `sync_state` stamp
    /// triggered a reload.
    ///
    /// The `.idle` transition is on the list because it changes both the symbol
    /// and the first line ("No syncs yet" → "Synced N ago") and costs nothing
    /// ongoing: `HomeViewModel.deriveStatus` returns `.idle` only while there is
    /// neither a stamp nor a delivery, so an install leaves it exactly once.
    static func shouldReloadTimelines(previous: ConduitStatusSnapshot?, next: ConduitStatusSnapshot) -> Bool {
        guard let previous else { return true }
        let hadError = previous.syncStatus == .error
        let hasError = next.syncStatus == .error
        let hadFailures = previous.failedCount > 0
        let hasFailures = next.failedCount > 0
        let wasIdle = previous.syncStatus == .idle
        let isIdle = next.syncStatus == .idle
        return hadError != hasError
            || hadFailures != hasFailures
            || wasIdle != isIdle
            || previous.importStatusHeadline != next.importStatusHeadline
    }

    /// The widget's baseline timeline-rebuild cadence, and therefore the
    /// freshness the container actually owes it. Lives here rather than in the
    /// widget target so the writer's coalescing and the reader's refresh policy
    /// cannot drift apart.
    static let timelineRefreshInterval: TimeInterval = 60 * 60

    /// Whether `next` earns the encode plus `.atomic` App Group write, given
    /// what the container already holds (`previous`) and when that landed.
    ///
    /// The writer is a `ValueObservation` that re-delivers after every
    /// committed transaction touching the outbox/staged/sync tables — on the
    /// order of 10^4 times across an all-time import — while the container is
    /// read at most once per `timelineRefreshInterval`, plus the reloads
    /// `shouldReloadTimelines` grants. Writing every delivery therefore spends
    /// thousands of encodes and file writes publishing states nothing reads,
    /// on a path a background-only launch pays with no screen to show for it.
    ///
    /// A state-*class* change is the one thing that cannot wait: it is pushed
    /// to the widget the moment it is written, so the container has to already
    /// hold it. Everything else — a climbing pending count, a fresh sync stamp
    /// — is written on the first delivery after the interval has passed. That
    /// floor is opportunistic, not scheduled: with no further delivery the
    /// change waits for `AppState`'s flush when the app goes to the background.
    static func shouldWriteToAppGroup(
        previous: ConduitStatusSnapshot?,
        writtenAt: Date?,
        next: ConduitStatusSnapshot,
        now: Date
    ) -> Bool {
        guard let previous, let writtenAt else { return true }
        if previous == next { return false }
        if shouldReloadTimelines(previous: previous, next: next) { return true }
        return now.timeIntervalSince(writtenAt) >= timelineRefreshInterval
    }
}

enum ConduitStatusSnapshotError: Error {
    case appGroupContainerUnavailable
}
