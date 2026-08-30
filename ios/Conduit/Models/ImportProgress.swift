import Foundation
import GRDB

/// Where an "Import history" run stands, as a value the UI can render truthfully
/// **after a relaunch** (ARCHITECTURE.md §4.4, "Import history" opt-in).
///
/// A run is never assumed to have succeeded. `running` is only meaningful while a
/// process is actually driving the import; a `running` row found at launch means
/// the app was backgrounded/force-quit mid-import, and is reconciled to
/// `interrupted` by `ImportProgressDAO.reconcileStaleRun()`.
enum ImportRunStatus: String, Codable, CaseIterable {
    /// An import is being driven right now by a live task.
    case running
    /// Stopped without finishing the range and without an error — the app was
    /// backgrounded/force-quit, the user cancelled, or the outbox never drained.
    /// Resumable from the persisted per-type cursors.
    case interrupted
    /// Stopped because a read/stage actually FAILED. Carries `failureReason`.
    /// **Never** rendered as a success.
    case failed
    /// The whole chosen range was read to its end for every enabled type.
    case completed

    /// Whether the user can pick up where this run left off.
    var isResumable: Bool {
        switch self {
        case .interrupted, .failed: return true
        case .running, .completed: return false
        }
    }

    /// Only a fully-exhausted range earns success styling. A truncated import
    /// must never show a green checkmark.
    var isSuccess: Bool { self == .completed }
}

/// Why a run stopped short, persisted so the reason survives a relaunch.
///
/// `auto_resume` says whether the app may pick a run back up on its own; it says
/// nothing about *why* it stopped, and after a relaunch the two questions have
/// different answers. A stuck upload queue in particular must keep its specific
/// wording rather than collapsing into the generic "interrupted" line.
///
/// An unknown (`nil`) cause — every row written before this existed — stays on
/// the conservative generic copy.
enum ImportStopCause: String, Codable {
    /// The user tapped Cancel.
    case userCancelled
    /// iOS took the foreground away (backgrounding, or an expiring background
    /// window). The only cause that is auto-resumable.
    case backgrounded
    /// Staging stopped because the outbox never drained inside
    /// `importDrainTimeout` — uploads are genuinely not getting through.
    case queueNotDraining
    /// A type stopped short for a reason that is neither of the above.
    case endedShort
}

/// Run-level state for the single most recent "Import history" run.
///
/// Singleton row (`id == ImportProgressDAO.singletonID`) because the UI only ever
/// offers one import at a time; per-type resume points live in
/// `ImportTypeProgress`.
struct ImportRunState: Codable, Equatable, FetchableRecord, PersistableRecord {
    var id: Int64
    /// Groups this run's per-type rows. A new run gets a new id so stale per-type
    /// rows from an older range can never be mistaken for resume points.
    var runId: String
    /// `ImportRange.rawValue` the run was started with.
    var rangeId: String
    /// Resolved window floor; `nil` for "All time".
    var rangeStart: Date?
    var status: ImportRunStatus
    /// Total rows staged across every type in this run (survives relaunch).
    var stagedCount: Int
    /// Human-readable failure reason — set iff `status == .failed`.
    var failureReason: String?
    /// How many types the run intends to cover, and how many finished their range.
    var typesTotal: Int
    var typesCompleted: Int
    /// The date **every** enabled type has been imported back to at least — the
    /// conservative floor computed by `ImportProgressDAO.floorReached`, not the
    /// deepest any single type reached. `nil` until every type has started.
    var oldestReachedAt: Date?
    /// Whether this paused run may be picked back up **without the user asking** —
    /// on the next foreground, or in a background window iOS grants.
    ///
    /// `interrupted` alone can't carry that: a run the user cancelled and a run
    /// iOS suspended land on the same status, and only the second should continue
    /// on its own. Set when the app pauses a live run (backgrounding, or a
    /// `running` row reconciled after a force-quit); deliberately **false** for a
    /// user cancellation, a failure (a failing read would just loop) and a
    /// completed run.
    var autoResume: Bool
    /// Why this run stopped, when it stopped short. `nil` while running, on a
    /// completed run, and on any row written before this was recorded.
    var stopCause: ImportStopCause?
    var startedAt: Date
    var updatedAt: Date

    static let databaseTableName = "import_run"

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case rangeId = "range_id"
        case rangeStart = "range_start"
        case status
        case stagedCount = "staged_count"
        case failureReason = "failure_reason"
        case typesTotal = "types_total"
        case typesCompleted = "types_completed"
        case oldestReachedAt = "oldest_reached_at"
        case autoResume = "auto_resume"
        case stopCause = "stop_cause"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
    }
}

/// Per-HealthKit-type resume point for the current import run.
///
/// `cursor` is the newest-first paging cursor `HistoryImporter` walks backward:
/// every sample with `endDate <= cursor` is still unread. `nil` means "start from
/// the newest end" (nothing read yet). This is the ONLY thing that makes an
/// interrupted import resumable rather than a full restart.
///
/// It is deliberately independent of `data_type_config.anchor_blob`: an import
/// must never touch a forward-capture anchor (§4.4).
struct ImportTypeProgress: Codable, Equatable, FetchableRecord, PersistableRecord {
    var hkTypeId: String
    var runId: String
    /// Resume point: read the next page strictly older than this. `nil` = not started.
    var cursor: Date?
    var stagedCount: Int
    var status: ImportRunStatus
    var failureReason: String?
    var updatedAt: Date

    static let databaseTableName = "import_type_progress"

    enum CodingKeys: String, CodingKey {
        case hkTypeId = "hk_type_id"
        case runId = "run_id"
        case cursor
        case stagedCount = "staged_count"
        case status
        case failureReason = "failure_reason"
        case updatedAt = "updated_at"
    }
}
