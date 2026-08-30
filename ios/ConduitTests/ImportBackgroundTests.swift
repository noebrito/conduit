import XCTest
@testable import Conduit

/// Tests for letting a large "Import history" continue without the app open —
/// as far as iOS actually permits.
///
/// What is testable here is the *policy and state machine*: which stop reason a
/// run records, which paused runs may be picked back up on their own, that a
/// background wake can never drive a run a foreground task already owns, and that
/// none of it can turn a truncated import into a success.
///
/// What is NOT testable here is whether iOS ever grants the `BGProcessingTask`
/// window — that is entirely at the OS's discretion and cannot be forced from a
/// simulator, which is precisely why the UI copy promises the foreground resume
/// and only *offers* the background one.
final class ImportBackgroundTests: XCTestCase {

    private func makeDAO() throws -> ImportProgressDAO {
        ImportProgressDAO(try AppDatabase.makeInMemory())
    }

    // MARK: - Stop reason: a pause is not a cancellation

    /// A user Cancel and an iOS-forced pause stop the run at the same boundary,
    /// but only the second may be resumed automatically — so the coordinator has
    /// to keep them apart.
    func testStopReasonDistinguishesAUserCancelFromABackgroundPause() {
        let coordinator = ImportRunCoordinator()

        // Nothing running: there is nothing to stop.
        coordinator.requestStop(.backgrounded)
        XCTAssertNil(coordinator.requestedStopReason)

        XCTAssertTrue(coordinator.claim("run"))
        coordinator.requestStop(.backgrounded)
        XCTAssertEqual(coordinator.requestedStopReason, .backgrounded)
        XCTAssertTrue(coordinator.isCancellationRequested,
                      "A pause must still stop the paging loop at its next boundary")

        coordinator.release("run")
        XCTAssertNil(coordinator.requestedStopReason, "Release clears the reason")
    }

    /// Once the user has said stop, a later backgrounding must not quietly
    /// upgrade their decision into "and we'll restart it for you".
    func testUserCancellationIsNotDowngradedByALaterBackgroundPause() {
        let coordinator = ImportRunCoordinator()
        XCTAssertTrue(coordinator.claim("run"))

        coordinator.requestCancellation()
        coordinator.requestStop(.backgrounded)

        XCTAssertEqual(coordinator.requestedStopReason, .userCancelled,
                       "Backgrounding must never overwrite a user cancellation")
    }

    /// The reverse order is fine: a pause may be superseded by a real cancel.
    func testBackgroundPauseCanBeUpgradedToAUserCancellation() {
        let coordinator = ImportRunCoordinator()
        XCTAssertTrue(coordinator.claim("run"))
        coordinator.requestStop(.backgrounded)
        coordinator.requestCancellation()
        XCTAssertEqual(coordinator.requestedStopReason, .userCancelled)
    }

    // MARK: - Auto-resume policy

    func testOnlyAnAutoResumableInterruptedRunIsPickedBackUp() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)

        // Running: nothing to resume — a live run is driven by its claim holder.
        XCTAssertFalse(ImportBackgroundCoordinator.shouldAutoResume(try dao.currentRun()))

        // Paused by iOS.
        try dao.finishRun(status: .interrupted, autoResume: true)
        XCTAssertTrue(ImportBackgroundCoordinator.shouldAutoResume(try dao.currentRun()))

        // Cancelled by the user: stays stopped until they say otherwise.
        try dao.finishRun(status: .interrupted, autoResume: false)
        XCTAssertFalse(ImportBackgroundCoordinator.shouldAutoResume(try dao.currentRun()))

        // Failed: resumable by hand, but never retried on a timer — a read that
        // failed (locked device, revoked permission) would just fail every window.
        try dao.finishRun(status: .failed, failureReason: "Protected data unavailable", autoResume: true)
        XCTAssertFalse(ImportBackgroundCoordinator.shouldAutoResume(try dao.currentRun()))

        // Completed: there is nothing left to do.
        try dao.finishRun(status: .completed)
        XCTAssertFalse(ImportBackgroundCoordinator.shouldAutoResume(try dao.currentRun()))

        // No run at all.
        XCTAssertFalse(ImportBackgroundCoordinator.shouldAutoResume(nil))
    }

    /// A force-quit mid-import is exactly the case the captain expects to just
    /// continue: the user never asked it to stop.
    func testForceQuitMidImportBecomesAutoResumable() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.lastYear.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "r1", cursor: Date(), stagedCount: 9, status: .running)

        // Relaunch after the app died mid-run.
        try dao.reconcileStaleRun()

        let run = try XCTUnwrap(try dao.currentRun())
        XCTAssertEqual(run.status, .interrupted)
        XCTAssertTrue(run.autoResume)
        XCTAssertTrue(ImportBackgroundCoordinator.shouldAutoResume(run))
        XCTAssertFalse(run.status.isSuccess, "A resumable pause is still not a success")
        XCTAssertEqual(run.stagedCount, 9, "The resume point and progress survive")
    }

    /// Driving the run again must clear the flag, so whatever stops THIS pass
    /// gets to record the answer fresh (a resume the user then cancels must not
    /// inherit "auto-resume" from the pause before it).
    func testResumingClearsTheAutoResumeFlagUntilTheRunStopsAgain() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.finishRun(status: .interrupted, autoResume: true)

        try dao.resumeRun()
        let running = try XCTUnwrap(try dao.currentRun())
        XCTAssertEqual(running.status, .running)
        XCTAssertFalse(running.autoResume)

        try dao.finishRun(status: .interrupted, autoResume: false)
        XCTAssertFalse(ImportBackgroundCoordinator.shouldAutoResume(try dao.currentRun()))
    }

    /// A stuck upload queue is NOT an iOS pause: it means the drain timed out, so
    /// it must stop for a decision instead of silently re-stalling for the whole
    /// drain timeout on every foreground and launch.
    func testAQueueThatNeverDrainedIsNotAutoResumed() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.finishRun(status: .interrupted, autoResume: false, stopCause: .queueNotDraining)

        let run = try XCTUnwrap(try dao.currentRun())
        XCTAssertFalse(ImportBackgroundCoordinator.shouldAutoResume(run))
        XCTAssertEqual(run.stopCause, .queueNotDraining)
    }

    /// Anything whose cause we never recorded (every row written before the cause
    /// existed) stays on the conservative default: no automatic resume.
    func testAnUnknownStopCauseIsNeverAutoResumed() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.finishRun(status: .interrupted)

        let run = try XCTUnwrap(try dao.currentRun())
        XCTAssertNil(run.stopCause)
        XCTAssertFalse(ImportBackgroundCoordinator.shouldAutoResume(run))
    }

    /// Driving the run again clears the recorded cause with the flag, so a resume
    /// can't inherit the previous pass's reason.
    func testResumingClearsTheRecordedStopCause() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.finishRun(status: .interrupted, autoResume: true, stopCause: .backgrounded)

        try dao.resumeRun()
        XCTAssertNil(try dao.currentRun()?.stopCause)
    }

    // MARK: - Keeping the background window booked

    /// A run still live when we ask (its page outlasted the checkpoint grace, or
    /// a background window is expiring under it) must KEEP its pending request —
    /// withdrawing it there is exactly when another window matters most.
    func testAStillLiveRunKeepsItsScheduledResume() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        let running = try XCTUnwrap(try dao.currentRun())

        XCTAssertFalse(ImportBackgroundCoordinator.shouldAutoResume(running),
                       "A live run isn't resumable — something is already driving it")
        XCTAssertTrue(ImportBackgroundCoordinator.needsScheduledResume(run: running, isLive: true),
                      "…but the window it will need must stay booked")

        // Once it really has stopped, the ordinary auto-resume policy decides.
        try dao.finishRun(status: .interrupted, autoResume: true, stopCause: .backgrounded)
        let paused = try XCTUnwrap(try dao.currentRun())
        XCTAssertTrue(ImportBackgroundCoordinator.needsScheduledResume(run: paused, isLive: false))

        try dao.finishRun(status: .completed)
        XCTAssertFalse(
            ImportBackgroundCoordinator.needsScheduledResume(run: try dao.currentRun(), isLive: false),
            "A finished run must withdraw the request rather than book windows forever"
        )
        XCTAssertFalse(ImportBackgroundCoordinator.needsScheduledResume(run: nil, isLive: false))
    }

    // MARK: - Honest status copy

    /// The paused copy must describe what actually happens — it keeps its place,
    /// resumes on reopen, and *may* get background time — without claiming the
    /// import keeps churning while the user is elsewhere.
    func testPausedCopyPromisesResumptionWithoutClaimingContinuousBackgroundWork() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "r1", cursor: Date(), stagedCount: 1_234, status: .interrupted)
        try dao.finishRun(status: .interrupted, autoResume: true)

        let run = try XCTUnwrap(try dao.currentRun())
        let text = SettingsViewModel.statusText(for: run)
        XCTAssertTrue(text.contains("paused"), "A pause reads as paused, not 'interrupted — go tap Resume'")
        XCTAssertTrue(text.contains("reopen"), "The guaranteed half (reopening resumes it) must be stated")
        XCTAssertFalse(text.hasPrefix("Imported "), "A truncated import must never read as a success")
        XCTAssertFalse(run.status.isSuccess)

        // A run the user cancelled keeps the old, non-promising wording.
        try dao.finishRun(status: .interrupted, autoResume: false)
        let cancelledText = SettingsViewModel.statusText(for: try XCTUnwrap(try dao.currentRun()))
        XCTAssertTrue(cancelledText.contains("Resume to continue"))
        XCTAssertFalse(cancelledText.contains("background"))
    }

    /// The stuck-queue reason must survive a relaunch, not collapse into the
    /// generic "interrupted" line — that specific cause is the only thing that
    /// tells the user what to go fix.
    func testAStuckQueueKeepsItsHonestReasonAfterARelaunch() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "r1", cursor: Date(), stagedCount: 2_500, status: .interrupted)
        try dao.finishRun(status: .interrupted, autoResume: false, stopCause: .queueNotDraining)

        let run = try XCTUnwrap(try dao.currentRun())
        let text = SettingsViewModel.statusText(for: run)
        XCTAssertTrue(text.contains("upload queue"), "The real cause must survive the relaunch")
        XCTAssertFalse(text.contains("iOS grants"),
                       "A stuck queue must never hide behind 'waiting for iOS background time'")
        XCTAssertFalse(run.status.isSuccess)

        // The in-session wording for the same stop is the same sentence.
        let outcome = ImportRunner.Outcome(
            status: .interrupted,
            staged: 2_500,
            failureReason: nil,
            hitCap: true,
            cancelled: false
        )
        XCTAssertEqual(SettingsViewModel.outcomeText(outcome), text)
    }

    /// The heading and the sentence under it must describe the same thing. A
    /// stuck queue is paused pending a drain — "Import interrupted" over "…paused
    /// for now" is exactly the incoherent status this work exists to remove.
    func testAStuckQueueHeadingAgreesWithItsDetailLine() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.finishRun(status: .interrupted, autoResume: false, stopCause: .queueNotDraining)

        let run = try XCTUnwrap(try dao.currentRun())
        XCTAssertEqual(SettingsViewModel.statusTitle(for: run), "Import paused")
        XCTAssertTrue(SettingsViewModel.statusText(for: run).contains("paused for now"))
        XCTAssertFalse(ImportBackgroundCoordinator.shouldAutoResume(run),
                       "Reading as paused is copy only — a stuck queue still waits for a tap")
    }

    /// A run the user cancelled keeps saying so after a relaunch; the reason is
    /// already in the row, so decaying to the generic line would be a needless
    /// loss of the truth.
    func testACancelledRunStillReadsAsCancelledAfterARelaunch() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "r1", cursor: Date(), stagedCount: 700, status: .interrupted)
        try dao.finishRun(status: .interrupted, autoResume: false, stopCause: .userCancelled)

        let run = try XCTUnwrap(try dao.currentRun())
        XCTAssertEqual(SettingsViewModel.statusTitle(for: run), "Import cancelled")

        let text = SettingsViewModel.statusText(for: run)
        XCTAssertTrue(text.contains("cancelled"))
        XCTAssertFalse(text.contains("iOS grants"), "A cancelled run is not waiting on a background window")

        // The relaunch copy is the same sentence the run itself reported.
        let outcome = ImportRunner.Outcome(
            status: .interrupted,
            staged: 700,
            failureReason: nil,
            hitCap: false,
            cancelled: true
        )
        XCTAssertEqual(SettingsViewModel.outcomeText(outcome), text)
        XCTAssertFalse(ImportBackgroundCoordinator.shouldAutoResume(run))
    }

    /// A cause we never recorded stays generic in BOTH the heading and the line —
    /// the conservative default for every pre-v9 row.
    func testAnUnknownStopCauseKeepsTheGenericInterruptedCopy() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.finishRun(status: .interrupted)

        let run = try XCTUnwrap(try dao.currentRun())
        XCTAssertEqual(SettingsViewModel.statusTitle(for: run), "Import interrupted")
        XCTAssertTrue(SettingsViewModel.statusText(for: run).contains("didn't finish the range"))
    }

    func testPausedOutcomeCopyIsDistinctFromCancelledAndFromSuccess() {
        let paused = ImportRunner.Outcome(
            status: .interrupted,
            staged: 500,
            failureReason: nil,
            hitCap: false,
            cancelled: false,
            pausedForBackground: true
        )
        let cancelled = ImportRunner.Outcome(
            status: .interrupted,
            staged: 500,
            failureReason: nil,
            hitCap: false,
            cancelled: true
        )
        XCTAssertTrue(SettingsViewModel.outcomeText(paused).contains("paused"))
        XCTAssertTrue(SettingsViewModel.outcomeText(cancelled).contains("cancelled"))
        XCTAssertNotEqual(SettingsViewModel.outcomeText(paused), SettingsViewModel.outcomeText(cancelled))
        XCTAssertFalse(paused.status.isSuccess)
    }

    // MARK: - Never two runs at once

    /// The acceptance criterion: no interleaving of the foreground and background
    /// paths may ever produce two executions over the same run. Both go through
    /// the same claim, so whichever gets there first drives it and the other is
    /// refused verbatim — without resetting anything.
    func testBackgroundResumeIsRefusedWhileTheForegroundRunHoldsTheClaim() async throws {
        let database = try AppDatabase.makeInMemory()
        let dao = ImportProgressDAO(database)
        let coordinator = ImportRunCoordinator()
        let runner = ImportRunner(
            database: database,
            engine: SyncEngine(database: database),
            coordinator: coordinator
        )
        try dao.beginRun(runId: "live", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "live", cursor: Date(), stagedCount: 31, status: .running)

        // The foreground import is running.
        XCTAssertTrue(coordinator.claim("live"))

        // iOS grants a background window while it does. It must do nothing.
        let background = await runner.resume(types: [])
        XCTAssertTrue(background.alreadyRunning)
        XCTAssertEqual(try dao.currentRun()?.status, .running, "The live run is untouched")
        XCTAssertEqual(try dao.typeProgress(hkTypeId: "A")?.stagedCount, 31,
                       "The refused wake must not re-checkpoint the live run's rows")
    }

    /// The claim itself under contention: however the foreground and background
    /// paths interleave, **two holders can never exist at once**. Anything that
    /// slipped through here would mean two tasks checkpointing the same rows.
    func testClaimIsMutuallyExclusiveUnderContention() async {
        let coordinator = ImportRunCoordinator()
        let concurrentPeak = ConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask {
                    let runId = "run-\(index)"
                    guard coordinator.claim(runId) else { return }
                    concurrentPeak.enter()
                    // A real run does work (reads a page, checkpoints) while
                    // holding the claim; this stands in for that window.
                    try? await Task.sleep(nanoseconds: 1_000_000)
                    concurrentPeak.leave()
                    coordinator.release(runId)
                }
            }
        }

        XCTAssertEqual(concurrentPeak.peak, 1, "Two tasks must never drive an import at the same time")
        XCTAssertGreaterThan(concurrentPeak.entries, 0, "The probe must actually have observed executions")
        XCTAssertFalse(coordinator.isRunning, "Every holder released its claim")
    }

    /// Counts how many tasks are inside the claim at once.
    private final class ConcurrencyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var peak = 0
        private(set) var entries = 0

        func enter() {
            lock.lock()
            defer { lock.unlock() }
            current += 1
            entries += 1
            peak = max(peak, current)
        }

        func leave() {
            lock.lock()
            defer { lock.unlock() }
            current -= 1
        }
    }

    // MARK: - Background task identity

    /// A `BGTaskScheduler` identifier that isn't listed in `Info.plist` is
    /// refused at registration time, and the upload-drain task must keep its own.
    func testImportTaskIdentifierIsPermittedAndDistinctFromTheUploadDrain() throws {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        let ids = try XCTUnwrap(permitted)
        XCTAssertTrue(ids.contains(ImportBackgroundCoordinator.taskID))
        XCTAssertTrue(ids.contains(SyncEngine.bgRefreshTaskID),
                      "The existing upload-drain task must stay registered — it is unrelated to imports")
        XCTAssertNotEqual(ImportBackgroundCoordinator.taskID, SyncEngine.bgRefreshTaskID)

        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        let backgroundModes = try XCTUnwrap(modes)
        XCTAssertTrue(backgroundModes.contains("processing"), "BGProcessingTask requires the processing mode")
        XCTAssertTrue(backgroundModes.contains("fetch"), "The upload-drain BGAppRefreshTask still needs fetch")
    }

    /// The assertion window is sized for ONE page's checkpoint, not for finishing
    /// an import — iOS grants roughly 30 s and killing the app is the penalty for
    /// overstaying.
    func testCheckpointGraceStaysWellInsideTheAssertionBudget() {
        XCTAssertLessThan(ImportBackgroundCoordinator.checkpointGrace, 30)
        XCTAssertGreaterThan(ImportBackgroundCoordinator.checkpointGrace, 5)
    }
}
