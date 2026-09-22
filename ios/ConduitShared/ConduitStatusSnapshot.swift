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
    var errorMessage: String?
    var pendingCount: Int
    var failedCount: Int
    var stagedTodayCount: Int
    /// `SettingsViewModel.statusTitle(for:)`'s wording, verbatim, when the most
    /// recent import run is not `.completed`. `nil` when there is no run or the
    /// run completed — the widget then falls back to pending/staged counts.
    var importStatusHeadline: String?
    var historyFloor: Date?
    var updatedAt: Date

    static let appGroupIdentifier = "group.dev.noebrito.Conduit"
    private static let fileName = "conduit_status_snapshot.json"

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

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

    /// Second line for `accessoryRectangular`, first match wins. Reuses the
    /// app's existing wording (via `importStatusHeadline`, already produced by
    /// `SettingsViewModel.statusTitle(for:)`) rather than inventing new copy
    /// for the same states.
    static func secondLine(for snapshot: ConduitStatusSnapshot) -> String {
        if snapshot.failedCount > 0 {
            return "\(snapshot.failedCount) failed"
        }
        if let importStatusHeadline = snapshot.importStatusHeadline {
            return importStatusHeadline
        }
        if snapshot.pendingCount > 0 {
            return "\(snapshot.pendingCount) pending"
        }
        return "Staged today \(snapshot.stagedTodayCount)"
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
    /// appearing/clearing, the import headline changing, or the failed count
    /// crossing zero. Deliberately NOT true for a timestamp/count-only change —
    /// Conduit's background cadence (≥96 `BGAppRefreshTask` wakes/day, plus
    /// HealthKit observer wakes) would exhaust the widget's daily reload budget
    /// if every `sync_state` stamp triggered a reload.
    static func shouldReloadTimelines(previous: ConduitStatusSnapshot?, next: ConduitStatusSnapshot) -> Bool {
        guard let previous else { return true }
        let hadError = previous.syncStatus == .error
        let hasError = next.syncStatus == .error
        let hadFailures = previous.failedCount > 0
        let hasFailures = next.failedCount > 0
        return hadError != hasError
            || hadFailures != hasFailures
            || previous.importStatusHeadline != next.importStatusHeadline
    }
}

enum ConduitStatusSnapshotError: Error {
    case appGroupContainerUnavailable
}
