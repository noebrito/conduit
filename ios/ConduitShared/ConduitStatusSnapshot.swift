import Foundation
import SwiftUI

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
    ///
    /// Inside the XCTest host of a debug build, a process with no App Group
    /// entitlement (the unsigned test host, `CODE_SIGNING_ALLOWED=NO`) falls
    /// back to a temp directory so the container-dependent tests run instead of
    /// skipping. The app and widget never take the fallback.
    private static let containerURL: URL? = {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return url
        }
        #if DEBUG
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else { return nil }
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConduitStatusSnapshotFallbackContainer", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
        #else
        return nil
        #endif
    }()

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

    /// A file in the App Group container, or `nil` when there is none.
    static func appGroupFileURL(_ name: String) -> URL? {
        containerURL?.appendingPathComponent(name)
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

    /// Age text with minute granularity at best, for the pre-iOS 18 fallback:
    /// "less than a minute", "5 min", "3 hr".
    static func coarseAge(from date: Date, to now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) hr"
    }

    /// Spacing of the timeline's regular entries: WidgetKit's stated minimum
    /// between entries, and the step the iOS 17 static age advances in.
    static let timelineEntrySpacing: TimeInterval = 5 * 60

    /// Entry dates for one timeline: `now`, then every `timelineEntrySpacing`
    /// through one `timelineRefreshInterval`, plus the next local midnight.
    ///
    /// The regular entries are what make the iOS 17 age advance between
    /// rebuilds: that branch renders a static age against the entry date
    /// (`coarseAge`), so a timeline holding only `now` would show the age as of
    /// the rebuild for the rest of the hour, under-reporting staleness. iOS 18+
    /// ignores the entry date for the age, so there they only re-render the same
    /// view.
    ///
    /// The midnight entry is what makes `stagedToday(asOf:)` land on time. A
    /// timeline renders its last entry until the next rebuild, and a rebuild is
    /// something WidgetKit treats as a hint rather than a promise — Low Power
    /// Mode suspends refreshes outright, and a rarely-surfaced widget gets
    /// throttled — so the boundary is carried unconditionally rather than only
    /// when it happens to fall inside one refresh interval. Extra entries inside
    /// a timeline are free; only rebuilding one is budgeted.
    ///
    /// A regular entry closer than one spacing to midnight is dropped in its
    /// favor, so entries stay at least `timelineEntrySpacing` apart — except
    /// `now` itself, when midnight is closer than that.
    static func timelineEntryDates(from now: Date, calendar: Calendar = .current) -> [Date] {
        let steps = Int(timelineRefreshInterval / timelineEntrySpacing)
        let regular = (0...steps).map { now.addingTimeInterval(Double($0) * timelineEntrySpacing) }
        guard let midnight = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else {
            return regular
        }
        let kept = regular.filter { $0 == now || abs($0.timeIntervalSince(midnight)) >= timelineEntrySpacing }
        return (kept + [midnight]).sorted()
    }

    /// The live "last synced" age for iOS 18+: the system's reference-date
    /// format restricted to hour/minute fields ("5 minutes ago"), never
    /// seconds. Shared so the widget and the tests render the same wording.
    @available(iOS 18, *)
    static func liveAgeFormat(for lastSyncedAt: Date) -> SystemFormatStyle.DateReference {
        .reference(to: lastSyncedAt, allowedFields: [.hour, .minute])
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

    /// Whether moving from `previous` to `next` is a state-*class* change: an
    /// error appearing/clearing, the import headline changing, the failed count
    /// crossing zero, or the very first sync leaving `.idle`. A class change is
    /// written and reloaded at once, wherever it lands. A stamp or count change
    /// alone is not a class change; whether a new stamp earns a reload is
    /// `reloadDecision`'s call, not this one's.
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

    /// The shortest gap between two reloads a *background* stamp change may
    /// request: `SyncEngine.bgRefreshInterval`, so a stamp landing every
    /// background wake costs at most 96 reloads a day against WidgetKit's
    /// ~40-70/day budget, and realistic days far fewer. If WidgetKit throttles
    /// anyway, the failure mode is a delayed reload, not a lost one.
    static let widgetReloadFloor: TimeInterval = 15 * 60

    /// Whether writing `next` should also ask WidgetKit to rebuild the widget's
    /// timeline — the one reload rule, for every path that writes the
    /// container.
    ///
    /// The widget's age is anchored to the `lastSyncedAt` its timeline was
    /// built with; the container is only re-read at a rebuild. So a new stamp
    /// that is never followed by a reload leaves the Lock Screen counting from
    /// the previous one — off by up to the hourly self-refresh, and snapping
    /// back at each rebuild. Hence:
    ///
    /// - A state-class change (`shouldReloadTimelines`) always reloads.
    /// - Otherwise only a stamp different from the one the last reload carried
    ///   (`lastReloadedStamp`) can reload. It is compared against that, not
    ///   against `previous`: a stamp the floor withheld is already in the
    ///   container, and must still be reloaded once the floor has passed.
    /// - In the foreground it reloads unconditionally — WidgetKit exempts
    ///   reloads from the containing app in the foreground from the budget.
    /// - In the background it reloads once `widgetReloadFloor` has passed since
    ///   the last request (`lastReloadAt`), or when there is no record of one. A
    ///   clock set back before the last request counts as past the floor, so a
    ///   manual clock change cannot freeze the widget.
    static func reloadDecision(
        previous: ConduitStatusSnapshot?,
        next: ConduitStatusSnapshot,
        lastReloadAt: Date?,
        lastReloadedStamp: Date?,
        isForeground: Bool,
        now: Date
    ) -> Bool {
        if shouldReloadTimelines(previous: previous, next: next) { return true }
        guard !isSameStamp(next.lastSyncedAt, lastReloadedStamp) else { return false }
        if isForeground { return true }
        guard let lastReloadAt else { return true }
        let elapsed = now.timeIntervalSince(lastReloadAt)
        return elapsed >= widgetReloadFloor || elapsed < 0
    }

    /// Whether two sync stamps are the same `sync_state` value. `sync_state`
    /// keeps milliseconds, and a stamp that has been through the App Group's
    /// `secondsSince1970` JSON can come back an ulp away from the one GRDB
    /// reads, so exact equality would make every fresh process see a "new"
    /// stamp and spend a reload on it.
    static func isSameStamp(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return abs(lhs.timeIntervalSince(rhs)) < 0.000_5
        default: return false
        }
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
    /// `reloadDecision` grants (whose paths write regardless of this gate). Writing every delivery therefore spends
    /// thousands of encodes and file writes publishing states nothing reads,
    /// on a path a background-only launch pays with no screen to show for it.
    ///
    /// A state-*class* change is the one thing that cannot wait: it is pushed
    /// to the widget the moment it is written, so the container has to already
    /// hold it. Everything else — a climbing pending count, a fresh sync stamp
    /// — is written on the first delivery after the interval has passed. That
    /// floor is opportunistic, not scheduled: with no further delivery the
    /// change waits for `AppState.flushStatusSnapshot`, run when the app leaves
    /// the screen and at the end of every background wake.
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

/// The last `WidgetCenter.reloadAllTimelines()` the app requested, and the
/// sync stamp that reload carried — what `reloadDecision` compares against.
///
/// Persisted in the App Group rather than in memory because background
/// launches — the common case — are fresh processes: without it every one
/// would either reload every time or never. The container snapshot is no
/// substitute: it tracks what was *written*, and a stamp the background floor
/// withheld is written without being reloaded. Written and read only by the
/// app (`AppState`); the widget never touches it.
struct WidgetReloadRecord: Codable, Equatable {
    var requestedAt: Date
    var lastSyncedAt: Date?

    private static let fileName = "conduit_widget_reload_record.json"

    func writeToAppGroup() throws {
        guard let url = ConduitStatusSnapshot.appGroupFileURL(Self.fileName) else {
            throw ConduitStatusSnapshotError.appGroupContainerUnavailable
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func readFromAppGroup() -> WidgetReloadRecord? {
        guard let url = ConduitStatusSnapshot.appGroupFileURL(fileName),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetReloadRecord.self, from: data)
    }

    #if DEBUG
    /// Tests only: forget every earlier reload, as on a fresh install.
    static func removeFromAppGroup() {
        guard let url = ConduitStatusSnapshot.appGroupFileURL(fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }
    #endif
}

enum ConduitStatusSnapshotError: Error {
    case appGroupContainerUnavailable
}
