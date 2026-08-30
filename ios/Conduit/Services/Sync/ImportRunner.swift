import Foundation
import os

private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "ImportRunner")

/// Process-wide claim on the single "Import history" run, plus the cancellation
/// channel that reaches whoever holds it.
///
/// Whether a run is being driven is a property of the RUN, not of whichever view
/// model happens to be on screen: onboarding's optional import runs in a detached
/// task owned by `OnboardingViewModel`, so a `SettingsViewModel` that judged
/// liveness by its own `isImporting` flag would (a) reconcile that live run to
/// `.interrupted` the moment Settings opened and (b) then offer Resume, starting a
/// SECOND `ImportRunner.execute` over the same run id — two tasks checkpointing the
/// same rows and racing on `finishRun`. The claim makes both impossible.
///
/// Cancellation lives here for the same reason: `Task.cancel()` only reaches the
/// task handle its caller happens to own, so Settings could never stop the
/// onboarding-owned run. `requestCancellation()` is observed by whichever task
/// holds the claim, so Cancel works regardless of which path started the import.
/// Why someone asked the live import to stop. Both reasons stop the run at the
/// same clean page boundary; they differ only in what the app is allowed to do
/// next, so the run must record which one it was.
enum ImportStopReason: String, Sendable {
    /// The user tapped Cancel. The run must stay stopped until they say otherwise.
    case userCancelled
    /// iOS is taking the foreground away (the app backgrounded, or a background
    /// task's window is expiring). The run may be picked back up automatically.
    case backgrounded
}

final class ImportRunCoordinator: @unchecked Sendable {
    static let shared = ImportRunCoordinator()

    private let lock = NSLock()
    private var activeRunId: String?
    private var stopReason: ImportStopReason?

    /// The run id a task in this process is currently driving, if any.
    var activeRun: String? {
        lock.lock()
        defer { lock.unlock() }
        return activeRunId
    }

    /// True while any task in this process is driving an import.
    var isRunning: Bool { activeRun != nil }

    /// True once someone asked the live run to stop, for any reason. The claim
    /// holder polls this at every page/type boundary.
    var isCancellationRequested: Bool { requestedStopReason != nil }

    /// Why the live run was asked to stop, if it was. This is what lets an
    /// iOS-forced pause be resumed automatically while a user's Cancel is not.
    var requestedStopReason: ImportStopReason? {
        lock.lock()
        defer { lock.unlock() }
        return stopReason
    }

    /// Take the claim. Returns false when another task already holds it — the
    /// caller must not start a competing run. A fresh claim starts unstopped.
    func claim(_ runId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeRunId == nil else { return false }
        activeRunId = runId
        stopReason = nil
        return true
    }

    /// Release a claim this caller holds. A no-op for anyone else's claim.
    func release(_ runId: String) {
        lock.lock()
        defer { lock.unlock() }
        if activeRunId == runId {
            activeRunId = nil
            stopReason = nil
        }
    }

    /// Ask the live run — whoever owns it — to stop at its next boundary.
    ///
    /// A user cancellation is the stronger signal: once the user has said stop,
    /// a later background pause must not downgrade it into something the app
    /// resumes on its own.
    func requestStop(_ reason: ImportStopReason) {
        lock.lock()
        defer { lock.unlock() }
        guard activeRunId != nil else { return }
        if stopReason == .userCancelled { return }
        stopReason = reason
    }

    /// Ask the live run to stop because the **user** cancelled it.
    func requestCancellation() {
        requestStop(.userCancelled)
    }
}

/// Drives an explicit "Import history" run across every enabled type, and makes
/// it **durable and honest**:
///
/// - **Durable** — after every page it checkpoints the type's paging cursor and
///   staged total to `import_progress` (see `ImportProgressDAO`), so an import
///   interrupted by backgrounding, force-quit or a crash has a real resume point
///   and `resume()` continues from it instead of re-reading the range from the
///   newest end.
/// - **Honest** — a thrown error from a HealthKit read or from staging ends the
///   run as `.failed` with the reason attached. It is NEVER converted into a
///   zero-sample "success", which is how a locked-device read failure used to
///   truncate a user's history under a green checkmark. A run is `.completed`
///   only when every type read its range to the end.
///
/// It deliberately owns no UI state: `SettingsViewModel` renders the persisted
/// state, and onboarding's optional import uses the same runner so its progress
/// is equally visible and resumable.
///
/// It never touches a forward-capture anchor — staging goes through
/// `SyncEngine.importHistory` → `OutboxDAO.stageImport` (ARCHITECTURE.md §4.4).
final class ImportRunner {
    /// Live progress for the UI while a run is in flight.
    struct Progress {
        let typeDisplayName: String
        let typeIndex: Int
        let typeCount: Int
        let stagedTotal: Int
    }

    /// What a run ended as. `status.isSuccess` is true only for a fully
    /// exhausted range.
    struct Outcome {
        let status: ImportRunStatus
        let staged: Int
        let failureReason: String?
        /// True when the run stopped because the outbox never drained.
        let hitCap: Bool
        /// True when the user (or a cancelled task) stopped it.
        let cancelled: Bool
        /// True when iOS took the foreground away and the run stopped at a clean
        /// page boundary to checkpoint. The run is picked back up automatically —
        /// on the next foreground, or in a background window iOS grants.
        var pausedForBackground: Bool = false
        /// True when the call was refused because another task in this process is
        /// already driving an import. Nothing was started and nothing was reset.
        var alreadyRunning: Bool = false
    }

    private let progressDAO: ImportProgressDAO
    private let engine: SyncEngine
    private let coordinator: ImportRunCoordinator

    init(database: AppDatabase, engine: SyncEngine, coordinator: ImportRunCoordinator = .shared) {
        self.progressDAO = ImportProgressDAO(database)
        self.engine = engine
        self.coordinator = coordinator
    }

    /// Whether a task in this process is driving an import right now — regardless
    /// of which view model started it.
    var isRunningInThisProcess: Bool { coordinator.isRunning }

    /// Stop the live run whoever owns it — the Settings Cancel action, which must
    /// also reach an import onboarding started in its own detached task.
    func requestCancellation() {
        coordinator.requestCancellation()
    }

    /// Begin a brand-new run, discarding any previous run's resume points (they
    /// belong to a different range and must never be reused).
    func start(
        range: ImportRange,
        since: Date?,
        types: [HealthDataType],
        onProgress: @escaping (Progress) -> Void = { _ in }
    ) async -> Outcome {
        let runId = UUID().uuidString
        // Refuse rather than wipe a live run's cursors out from under the task
        // driving it (onboarding's import runs detached, in another view model).
        guard coordinator.claim(runId) else { return busyOutcome() }
        defer { coordinator.release(runId) }
        do {
            try progressDAO.beginRun(
                runId: runId,
                rangeId: range.rawValue,
                rangeStart: since,
                typesTotal: types.count
            )
        } catch {
            return await fail(error, staged: 0)
        }
        return await execute(runId: runId, since: since, types: types, onProgress: onProgress)
    }

    /// Continue the persisted run from each type's stored cursor.
    ///
    /// Types that already read their range to the end are skipped; every other
    /// type restarts its paging at the persisted cursor, which is the whole point
    /// of the durable state.
    func resume(
        types: [HealthDataType],
        onProgress: @escaping (Progress) -> Void = { _ in }
    ) async -> Outcome {
        guard let run = try? progressDAO.currentRun() else {
            return Outcome(status: .interrupted, staged: 0, failureReason: nil, hitCap: false, cancelled: false)
        }
        // A run already being driven must never be driven a second time: two
        // executions would checkpoint the same rows and race on finishRun.
        guard coordinator.claim(run.runId) else { return busyOutcome() }
        defer { coordinator.release(run.runId) }
        do {
            // The enabled set can have grown since the run began; without this the
            // status renders "5/3 types finished" and floorReached's
            // `rows.count >= typesTotal` guard passes while newly-enabled types
            // have no row yet — a floor that OVERSTATES coverage.
            try progressDAO.updateTypesTotal(types.count)
            try progressDAO.resumeRun()
        } catch {
            return await fail(error, staged: run.stagedCount)
        }
        return await execute(
            runId: run.runId,
            since: run.rangeStart,
            types: types,
            onProgress: onProgress
        )
    }

    /// The persisted state the UI renders. Reconciles a `running` row left behind
    /// by a force-quit into `interrupted` first, so a relaunch never claims an
    /// import is still going when no process is driving it.
    func loadPersistedState(reconcileStale: Bool = true) -> (run: ImportRunState?, types: [ImportTypeProgress]) {
        // Never reconcile a run a live task is still driving — "running" is only
        // stale when NO process holds the claim.
        if reconcileStale && !coordinator.isRunning {
            _ = try? progressDAO.reconcileStaleRun()
        }
        let run = try? progressDAO.currentRun()
        let types = (try? progressDAO.allTypeProgress()) ?? []
        return (run, types)
    }

    /// Forget the last run (the "Start Over" action). Refuses while a task is
    /// driving an import, so a live run's cursors can't be deleted underneath it.
    func clear() {
        guard !coordinator.isRunning else { return }
        try? progressDAO.clear()
    }

    /// The no-op outcome for a call refused because a run is already in flight.
    /// It reports the persisted run verbatim: nothing was started or reset.
    private func busyOutcome() -> Outcome {
        let run = try? progressDAO.currentRun()
        logger.info("import request ignored — a run is already in flight")
        return Outcome(
            status: run?.status ?? .running,
            staged: run?.stagedCount ?? 0,
            failureReason: nil,
            hitCap: false,
            cancelled: false,
            alreadyRunning: true
        )
    }

    // MARK: - Internals

    private func execute(
        runId: String,
        since: Date?,
        types: [HealthDataType],
        onProgress: @escaping (Progress) -> Void
    ) async -> Outcome {
        let stored = (try? progressDAO.allTypeProgress()) ?? []
        let byID = Dictionary(uniqueKeysWithValues: stored.filter { $0.runId == runId }.map { ($0.hkTypeId, $0) })

        var stagedTotal = stored.filter { $0.runId == runId }.reduce(0) { $0 + $1.stagedCount }
        var hitCap = false
        var cancelled = false

        // Cancellation can arrive either from this task's own handle or from any
        // other part of the app via the coordinator (Settings cancelling the run
        // onboarding started), so both are one predicate all the way down.
        let isCancelled: @Sendable () -> Bool = { [coordinator] in
            Task.isCancelled || coordinator.isCancellationRequested
        }

        for (index, type) in types.enumerated() {
            if isCancelled() { cancelled = true; break }

            let existing = byID[type.identifier]
            // Already finished this type's range in this run — nothing to redo.
            if existing?.status == .completed { continue }

            // What this type already staged in an earlier (interrupted) pass. The
            // running UI total is the run total so far plus what THIS pass adds.
            let priorStaged = existing?.stagedCount ?? 0
            let startCursor = existing?.cursor
            let runTotalBefore = stagedTotal

            onProgress(Progress(
                typeDisplayName: type.displayName,
                typeIndex: index,
                typeCount: types.count,
                stagedTotal: stagedTotal
            ))

            let summary: HistoryImporter.Summary
            do {
                summary = try await engine.importHistory(
                    typeIdentifier: type.identifier,
                    since: since,
                    startCursor: startCursor,
                    isCancelled: isCancelled,
                    onProgress: { staged in
                        onProgress(Progress(
                            typeDisplayName: type.displayName,
                            typeIndex: index,
                            typeCount: types.count,
                            stagedTotal: runTotalBefore + staged
                        ))
                    },
                    onCheckpoint: { [progressDAO] cursor, staged in
                        try progressDAO.checkpoint(
                            hkTypeId: type.identifier,
                            runId: runId,
                            cursor: cursor,
                            stagedCount: priorStaged + staged,
                            status: .running
                        )
                    }
                )
            } catch {
                // The defect this whole change exists to kill: a read/stage
                // failure must surface as a failure, never as a quiet success.
                try? progressDAO.checkpoint(
                    hkTypeId: type.identifier,
                    runId: runId,
                    cursor: startCursor,
                    stagedCount: priorStaged,
                    status: .failed,
                    failureReason: error.localizedDescription
                )
                return await fail(error, staged: stagedTotal, typeName: type.displayName)
            }

            let typeStatus: ImportRunStatus
            if summary.exhausted {
                typeStatus = .completed
            } else if summary.cancelled {
                typeStatus = .interrupted
                cancelled = true
            } else {
                typeStatus = .interrupted
                hitCap = hitCap || summary.hitCap
            }

            try? progressDAO.checkpoint(
                hkTypeId: type.identifier,
                runId: runId,
                cursor: summary.cursor,
                stagedCount: priorStaged + summary.staged,
                status: typeStatus
            )
            stagedTotal = runTotalBefore + summary.staged

            if typeStatus != .completed { break }
        }

        if isCancelled() { cancelled = true }

        // Both a user Cancel and an iOS-forced pause stop the run at the same
        // clean boundary — but only the second may be picked back up without the
        // user asking, so the reason is recorded rather than inferred.
        let pausedForBackground = cancelled
            && coordinator.requestedStopReason == .backgrounded
            && !Task.isCancelled
        let stoppedByUser = cancelled && !pausedForBackground

        let finalStaged = (try? progressDAO.currentRun())?.stagedCount ?? stagedTotal
        let completedAll = !cancelled && !hitCap && completedEveryType(runId: runId, types: types)
        let status: ImportRunStatus = completedAll ? .completed : .interrupted

        // Why it stopped, recorded rather than inferred — `interrupted` alone
        // can't tell a pause from a cancel from a stuck upload queue, and after a
        // relaunch each deserves different copy.
        let stopCause: ImportStopCause?
        if completedAll {
            stopCause = nil
        } else if stoppedByUser {
            stopCause = .userCancelled
        } else if pausedForBackground {
            stopCause = .backgrounded
        } else if hitCap {
            stopCause = .queueNotDraining
        } else {
            stopCause = .endedShort
        }

        // Auto-resume ONLY a genuine iOS-forced pause. A hit-cap stop means the
        // outbox drain TIMED OUT (importDrainTimeout) — uploads are not getting
        // through, which is a problem the user must SEE, not something to retry
        // silently behind a "waiting for iOS background time" label: (1) that
        // generic copy on a stuck queue is exactly the comforting-but-vague
        // status this work exists to eliminate, and (2) with an unreachable
        // webhook a silent auto-resume would stall for the full drain timeout on
        // every foreground and launch — a ten-minute apparent hang on every app
        // open, far worse than one deliberate Resume tap. A healthy large import
        // drains and continues WITHIN the run and never reaches this path.
        try? progressDAO.finishRun(status: status, autoResume: pausedForBackground, stopCause: stopCause)
        logger.info("import run \(runId, privacy: .public) ended \(status.rawValue, privacy: .public) with \(finalStaged) staged")
        return Outcome(
            status: status,
            staged: finalStaged,
            failureReason: nil,
            hitCap: hitCap,
            cancelled: stoppedByUser,
            pausedForBackground: pausedForBackground
        )
    }

    private func completedEveryType(runId: String, types: [HealthDataType]) -> Bool {
        let stored = (try? progressDAO.allTypeProgress()) ?? []
        let completed = Set(
            stored.filter { $0.runId == runId && $0.status == .completed }.map(\.hkTypeId)
        )
        return types.allSatisfy { completed.contains($0.identifier) }
    }

    private func fail(_ error: Error, staged: Int, typeName: String? = nil) async -> Outcome {
        let base = error.localizedDescription
        let reason = typeName.map { "\(base) (while importing \($0))" } ?? base
        logger.error("import run failed: \(reason, privacy: .public)")
        try? progressDAO.finishRun(status: .failed, failureReason: reason)
        let finalStaged = (try? progressDAO.currentRun())?.stagedCount ?? staged
        return Outcome(
            status: .failed,
            staged: finalStaged,
            failureReason: reason,
            hitCap: false,
            cancelled: false
        )
    }
}
