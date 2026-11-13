import HealthKit
import SwiftUI
import UIKit
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

/// Regression for TestFlight feedback on 1.9 (137): an import across a year of
/// history showed a red "Import failed … Protected health data is inaccessible
/// (while importing Heart Rate Variability (SDNN))". HealthKit raises that
/// (`HKError.errorDatabaseInaccessible`) for ANY read once the iPhone locks, and
/// the runner's catch-all recorded it as `.failed` — the one status that is never
/// auto-resumed. The lock is a pause: the run must keep its place, say so calmly,
/// and continue by itself after unlock.
///
/// The reproduction injects that exact error mid-type through
/// `SyncEngine`'s `readImportPage` seam; nothing here touches a live store.
@MainActor
final class ImportLockedPauseTests: XCTestCase {

    /// A Health store whose reads fail the way a locked iPhone's do.
    private final class LockableHealth: @unchecked Sendable {
        private let lock = NSLock()
        private var histories: [String: [Int64]] = [:]
        private var isLocked = false
        private var lockAfterPages: (typeID: String, pages: Int)?
        private var pagesRead: [String: Int] = [:]
        private(set) var cursorsRead: [String: [Date?]] = [:]
        /// Non-lock error to raise instead, for the "genuine failure" guard.
        var otherError: Error?
        /// Runs just before the locked read throws (a Cancel racing the lock).
        var beforeLockedThrow: (() -> Void)?

        init(histories: [String: [Int64]]) { self.histories = histories }

        func lockAfter(_ pages: Int, readsOf typeID: String) {
            lock.lock(); defer { lock.unlock() }
            lockAfterPages = (typeID, pages)
        }

        func unlock() {
            lock.lock(); defer { lock.unlock() }
            isLocked = false
            lockAfterPages = nil
        }

        func read(_ type: HealthDataType, before: Date?, limit: Int) throws -> AnchoredReader.Result {
            lock.lock(); defer { lock.unlock() }
            cursorsRead[type.identifier, default: []].append(before)
            if let trigger = lockAfterPages, trigger.typeID == type.identifier,
               pagesRead[type.identifier, default: 0] >= trigger.pages {
                isLocked = true
            }
            if isLocked {
                beforeLockedThrow?()
                if let otherError { throw otherError }
                throw NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: "Protected health data is inaccessible"])
            }
            pagesRead[type.identifier, default: 0] += 1
            let upper = before.map { AnchoredReader.unixMillis($0) } ?? Int64.max
            let page = (histories[type.identifier] ?? []).filter { $0 < upper }.prefix(limit)
            return AnchoredReader.Result(
                samples: page.map { ImportLockedPauseTests.sample(type: type, endMs: $0) },
                deletedUuids: [],
                newAnchor: nil
            )
        }
    }

    private struct NoFloorsProbe: HistoryAccessProbing {
        func limitedHistoryFloors(for types: [HealthDataType]) async -> HistoryAccessFloors {
            HistoryAccessFloors()
        }
    }

    nonisolated static func sample(type: HealthDataType, endMs: Int64) -> Conduit_V1_Sample {
        var sample = Conduit_V1_Sample()
        sample.uuid = "\(type.identifier)-\(endMs)"
        sample.startUnixMs = endMs
        sample.endUnixMs = endMs
        sample.quantity.value = 1
        sample.quantity.unit = type.defaultUnit ?? "count"
        return sample
    }

    private let pageSize = SyncEngine.importPageSize
    private let hrv = HealthDataType.heartRateVariabilitySDNN
    private let steps = HealthDataType.stepCount

    /// Base one year back, one sample a minute, newest first — unique end times.
    private func history(count: Int, offsetMs: Int64) -> [Int64] {
        let newest: Int64 = 1_760_000_000_000 + offsetMs
        return (0..<count).map { newest - Int64($0) * 60_000 }
    }

    private struct Fixture {
        let database: AppDatabase
        let health: LockableHealth
        let engine: SyncEngine
        let coordinator: ImportRunCoordinator
        let types: [HealthDataType]
    }

    /// Steps (one short page) and HRV (two full pages and a partial third), both
    /// enabled, with a webhook to stage to — the registry decides their order,
    /// exactly as the app's own resume does.
    private func makeFixture() throws -> Fixture {
        let database = try AppDatabase.makeInMemory()
        var webhook = WebhookConfig.makeDefault(url: "https://receiver.example/sync", bearerTokenKeychainRef: "test")
        webhook.outboxCap = 50_000
        try WebhookConfigDAO(database).save(&webhook)
        for type in [steps, hrv] {
            try DataTypeConfigDAO(database).upsert(DataTypeConfig(
                hkTypeId: type.identifier, enabled: true, minIntervalSeconds: nil,
                anchorBlob: nil, lastSyncAt: nil, lastAttemptAt: nil))
        }
        let health = LockableHealth(histories: [
            steps.identifier: history(count: 10, offsetMs: 7),
            hrv.identifier: history(count: pageSize * 2 + 2_000, offsetMs: 0),
        ])
        let engine = SyncEngine(database: database, readImportPage: { type, _, before, limit, _ in
            try health.read(type, before: before, limit: limit)
        })
        let enabled: Set<String> = [steps.identifier, hrv.identifier]
        let types = HealthTypeRegistry.shared.all.filter { enabled.contains($0.identifier) }
        return Fixture(database: database, health: health, engine: engine,
                       coordinator: ImportRunCoordinator(), types: types)
    }

    private func runner(_ f: Fixture) -> ImportRunner {
        ImportRunner(database: f.database, engine: f.engine, coordinator: f.coordinator, probe: NoFloorsProbe())
    }

    /// The reproduction: the iPhone locks while HRV is on its third page.
    func testDeviceLockMidImportPausesInPlaceInsteadOfFailing() async throws {
        let f = try makeFixture()
        f.health.lockAfter(2, readsOf: hrv.identifier)

        let outcome = await runner(f).start(range: .lastYear, since: nil, types: f.types)

        XCTAssertEqual(outcome.status, .interrupted, "A locked iPhone is a pause, never .failed")
        XCTAssertTrue(outcome.pausedForLockedDevice)
        XCTAssertNil(outcome.failureReason)
        XCTAssertFalse(outcome.status.isSuccess)
        XCTAssertFalse(SettingsViewModel.outcomeText(outcome).contains("failed"))
        XCTAssertEqual(SettingsViewModel.outcomeText(outcome),
                       SettingsViewModel.lockedPauseText(count: outcome.staged.formatted()))

        let dao = ImportProgressDAO(f.database)
        let run = try XCTUnwrap(dao.currentRun())
        XCTAssertEqual(run.status, .interrupted)
        XCTAssertEqual(run.stopCause, .deviceLocked)
        XCTAssertTrue(run.autoResume)
        XCTAssertNil(run.failureReason)
        XCTAssertTrue(ImportBackgroundCoordinator.shouldAutoResume(run))
        XCTAssertEqual(SettingsViewModel.statusTitle(for: run), "Paused until you unlock your iPhone")
        XCTAssertNotEqual(SettingsViewModel.statusTitle(for: run), "Import failed")

        // Progress is preserved: both HRV pages read before the lock stay
        // counted, and the cursor is where the third page starts.
        let hrvRow = try XCTUnwrap(dao.typeProgress(hkTypeId: hrv.identifier))
        XCTAssertEqual(hrvRow.status, .interrupted)
        XCTAssertEqual(hrvRow.stagedCount, pageSize * 2)
        let lockedRead = try XCTUnwrap(f.health.cursorsRead[hrv.identifier]?.last)
        XCTAssertEqual(hrvRow.cursor, lockedRead, "The resume point is the page the lock interrupted")
        XCTAssertNotNil(hrvRow.cursor)
        XCTAssertEqual(run.stagedCount, try OutboxDAO(f.database).totalCount(),
                       "Everything staged before the lock is still counted")
    }

    /// …and continues by itself once the iPhone is unlocked, from the same place.
    func testLockedPauseWaitsForUnlockThenResumesFromTheSamePlace() async throws {
        let f = try makeFixture()
        f.health.lockAfter(2, readsOf: hrv.identifier)
        _ = await runner(f).start(range: .lastYear, since: nil, types: f.types)
        let dao = ImportProgressDAO(f.database)
        let pausedCursor = try XCTUnwrap(dao.typeProgress(hkTypeId: hrv.identifier)?.cursor)
        let readsBeforeUnlock = f.health.cursorsRead[hrv.identifier]?.count

        var protectedDataAvailable = false
        let background = ImportBackgroundCoordinator(
            database: f.database, engine: f.engine, coordinator: f.coordinator, probe: NoFloorsProbe(),
            isProtectedDataAvailable: { protectedDataAvailable },
            isInForeground: { true }
        )
        let center = NotificationCenter()
        background.observeProtectedDataAvailability(center: center)

        // Still locked: a foreground/background wake holds rather than re-failing.
        let heldResult = await background.resumePausedRun(trigger: "foreground")
        XCTAssertEqual(heldResult, .notCompleted)
        XCTAssertEqual(f.health.cursorsRead[hrv.identifier]?.count, readsBeforeUnlock,
                       "Nothing may be read while protected data is unavailable")
        XCTAssertEqual(try dao.currentRun()?.stopCause, .deviceLocked)

        // Unlock — no Resume tap.
        f.health.unlock()
        protectedDataAvailable = true
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        let resumed = try XCTUnwrap(background.unlockResume, "Unlocking must start the resume")
        let result = await resumed.value

        XCTAssertEqual(result, .completed)
        let hrvReads = try XCTUnwrap(f.health.cursorsRead[hrv.identifier])
        XCTAssertEqual(hrvReads[readsBeforeUnlock ?? 0], pausedCursor,
                       "The resume continues at the paused cursor, not the newest end")
        let run = try XCTUnwrap(dao.currentRun())
        XCTAssertEqual(run.status, .completed)
        XCTAssertNil(run.stopCause)
        XCTAssertEqual(run.typesCompleted, 2)
        XCTAssertEqual(try dao.typeProgress(hkTypeId: hrv.identifier)?.stagedCount, pageSize * 2 + 2_000)
        XCTAssertEqual(try OutboxDAO(f.database).totalCount(), pageSize * 2 + 2_000 + 10,
                       "Every sample staged exactly once across the pause")
    }

    /// The guard the other way: any other HealthKit error is still a failure.
    func testAGenuineReadErrorStillFails() async throws {
        let f = try makeFixture()
        f.health.otherError = NSError(domain: HKErrorDomain, code: HKError.Code.errorAuthorizationDenied.rawValue)
        f.health.lockAfter(1, readsOf: hrv.identifier)

        let outcome = await runner(f).start(range: .lastYear, since: nil, types: f.types)

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertFalse(outcome.pausedForLockedDevice)
        XCTAssertNotNil(outcome.failureReason)
        let run = try XCTUnwrap(ImportProgressDAO(f.database).currentRun())
        XCTAssertEqual(run.status, .failed)
        XCTAssertFalse(run.autoResume)
        XCTAssertNotEqual(run.stopCause, .deviceLocked)
        XCTAssertEqual(SettingsViewModel.statusTitle(for: run), "Import failed")
    }

    /// A user's Cancel outranks the lock: it stays cancelled, never auto-resumed.
    func testACancelRequestedBeforeTheLockStaysCancelled() async throws {
        let f = try makeFixture()
        f.health.lockAfter(1, readsOf: hrv.identifier)
        // The user taps Cancel while the read the lock is about to fail is in flight.
        f.health.beforeLockedThrow = { [coordinator = f.coordinator] in coordinator.requestCancellation() }

        let outcome = await runner(f).start(range: .lastYear, since: nil, types: f.types)

        let run = try XCTUnwrap(ImportProgressDAO(f.database).currentRun())
        XCTAssertNotEqual(run.status, .failed)
        XCTAssertFalse(run.autoResume)
        XCTAssertEqual(run.stopCause, .userCancelled)
        XCTAssertFalse(outcome.pausedForLockedDevice)
    }

    /// When the unlock resumes the run, Settings must stop saying "paused"
    /// under the "Importing…" heading — but a late tick from before the pause
    /// still must not clobber the paused copy.
    func testAutomaticResumeSupersedesThePausedCopy() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = SettingsViewModel(appState: AppState(database: database), importCoordinator: ImportRunCoordinator())
        let dao = ImportProgressDAO(database)
        viewModel.observeImportState()
        try dao.beginRun(runId: "r", rangeId: ImportRange.lastYear.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "r", cursor: Date(), stagedCount: 25, status: .interrupted)
        try dao.finishRun(status: .interrupted, autoResume: true, stopCause: .deviceLocked)
        let outcome = ImportRunner.Outcome(status: .interrupted, staged: 25, failureReason: nil,
                                           hitCap: false, cancelled: false, pausedForLockedDevice: true)
        viewModel.importProgressText = SettingsViewModel.outcomeText(outcome)
        viewModel.loadImportState(preserveOutcome: true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(viewModel.importProgressText.contains("locked"), "The paused copy survives late ticks")

        try dao.resumeRun(now: Date().addingTimeInterval(1))
        for _ in 0..<40 where viewModel.importProgressText != "Importing…" {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(viewModel.importProgressText, "Importing…")
        viewModel.stopObservingImportState()
    }

    /// The Lock Screen widget treats this pause like any other routine pause.
    func testLockedPauseIsARoutinePauseForTheWidgetHeadline() {
        let run = ImportRunState(
            id: ImportProgressDAO.singletonID, runId: "r", rangeId: ImportRange.lastYear.rawValue,
            rangeStart: nil, status: .interrupted, stagedCount: 3, failureReason: nil,
            typesTotal: 2, typesCompleted: 1, oldestReachedAt: nil, historyFloor: nil,
            autoResume: true, stopCause: .deviceLocked, startedAt: Date(), updatedAt: Date())
        XCTAssertNil(AppState.importHeadline(for: run))
    }
}

// MARK: - Reviewer evidence (opt-in: set CONDUIT_EVIDENCE_DIR)

/// Renders the real Settings → Import History screen over the exact persisted
/// state the TestFlight run reached: a "Last year" import of HRV + Steps that the
/// iPhone's lock interrupted mid-HRV, then the same screen after the unlock
/// resumed it on its own. Skips unless `CONDUIT_EVIDENCE_DIR` is set.
extension ImportLockedPauseTests {

    func testEvidenceImportHistoryScreenPausedByLockThenResumedByUnlock() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUIT_EVIDENCE_DIR"] != nil)
        let f = try makeFixture()
        f.health.lockAfter(2, readsOf: hrv.identifier)
        let outcome = await runner(f).start(range: .lastYear, since: nil, types: f.types)
        XCTAssertTrue(outcome.pausedForLockedDevice)

        let app = AppState(database: f.database)
        let (window, collection) = try presentSettings(app)
        defer { window.isHidden = true }
        try openImportHistory(collection)
        let pausedTitle = SettingsViewModel.statusTitle(for: try XCTUnwrap(ImportProgressDAO(f.database).currentRun()))
        XCTAssertEqual(pausedTitle, "Paused until you unlock your iPhone")
        XCTAssertNotEqual(pausedTitle, "Import failed")
        try writeArtifact(capture(window), named: "import-history-1-paused-while-locked.png")

        // Unlock: no Resume tap — the protected-data notification drives it.
        var protectedDataAvailable = false
        let background = ImportBackgroundCoordinator(
            database: f.database, engine: f.engine, coordinator: f.coordinator, probe: NoFloorsProbe(),
            isProtectedDataAvailable: { protectedDataAvailable },
            isInForeground: { true }
        )
        let center = NotificationCenter()
        background.observeProtectedDataAvailability(center: center)
        f.health.unlock()
        protectedDataAvailable = true
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        let result = try await XCTUnwrap(background.unlockResume).value
        XCTAssertEqual(result, .completed)
        settle(1.5)
        XCTAssertEqual(try ImportProgressDAO(f.database).currentRun()?.status, .completed)
        try writeArtifact(capture(window), named: "import-history-2-resumed-after-unlock.png")
    }

    private func presentSettings(_ app: AppState) throws -> (UIWindow, UICollectionView) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: SettingsView().environment(app))
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        settle(1.5)
        let collection = try XCTUnwrap(scrollViews(host.view)
            .max(by: { $0.contentSize.height < $1.contentSize.height }) as? UICollectionView)
        return (window, collection)
    }

    /// Settings' "History" section sits directly above "About" (the last section).
    private func openImportHistory(_ collection: UICollectionView) throws {
        let row = IndexPath(item: 0, section: collection.numberOfSections - 2)
        collection.scrollToItem(at: row, at: .centeredVertically, animated: false)
        settle(0.5)
        let delegate = try XCTUnwrap(collection.delegate)
        delegate.collectionView?(collection, didSelectItemAt: row)
        settle(2.0)
    }

    private func capture(_ window: UIWindow) throws -> Data {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try XCTUnwrap(image.pngData())
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func scrollViews(_ view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
