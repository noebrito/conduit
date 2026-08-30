import XCTest
@testable import Conduit

/// Tests for the two defects that made "Import History" untrustworthy:
///
/// 1. **No resume point.** The paging cursor lived only in a local `var`, so an
///    import interrupted by a force-quit restarted from the newest end and
///    re-read everything. It is now checkpointed to `import_progress` after every
///    page and fed back in as `startCursor`.
/// 2. **Fail-quiet.** A failed HealthKit read was swallowed and returned as a
///    zero-sample success summary, so the UI showed a green "Imported N samples"
///    over a silently truncated history. A failure now propagates and is recorded
///    as `.failed` with a reason.
final class ImportResumeTests: XCTestCase {

    private func makeSample(uuid: String, endMs: Int64) -> Conduit_V1_Sample {
        var sample = Conduit_V1_Sample()
        sample.uuid = uuid
        sample.endUnixMs = endMs
        return sample
    }

    /// Newest-first, date-cursor reader over a synthetic history.
    private func newestFirstReader(
        endMsNewestFirst: [Int64],
        pageSize: Int
    ) -> (Date?) async throws -> AnchoredReader.Result {
        return { before in
            let upper = before.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? Int64.max
            let page = endMsNewestFirst.filter { $0 < upper }.prefix(pageSize)
            let samples = page.map { self.makeSample(uuid: "e\($0)", endMs: $0) }
            return AnchoredReader.Result(samples: Array(samples), deletedUuids: [], newAnchor: nil)
        }
    }

    // MARK: - Resume (defect 1)

    /// An import killed mid-run must continue from the persisted cursor, NOT
    /// restart at the newest end.
    func testInterruptedImportResumesFromCursorInsteadOfRestarting() async throws {
        let pageSize = 5
        let history: [Int64] = Array(stride(from: 100, through: 1, by: -1))
        let reader = newestFirstReader(endMsNewestFirst: history, pageSize: pageSize)

        // --- Run 1: stopped ("force quit") after two pages. ---
        var firstRunStaged: [Int64] = []
        var checkpoints: [Date?] = []
        var pagesRead = 0

        let first = try await HistoryImporter.run(
            pageSize: pageSize,
            isCancelled: { pagesRead >= 2 },
            readPage: { before in pagesRead += 1; return try await reader(before) },
            stagePage: { samples in
                firstRunStaged.append(contentsOf: samples.map(\.endUnixMs))
                return (inserted: samples.count, hitCap: false)
            },
            onCheckpoint: { cursor, _ in checkpoints.append(cursor) }
        )

        XCTAssertTrue(first.cancelled)
        XCTAssertFalse(first.exhausted, "A stopped import must never report the range as exhausted")
        let resumePoint = try XCTUnwrap(first.cursor, "The stopped run must expose a resume point")
        XCTAssertEqual(checkpoints.compactMap { $0 }.last, resumePoint)
        XCTAssertEqual(firstRunStaged, [100, 99, 98, 97, 96, 95, 94, 93, 92, 91])

        // --- Run 2: resume from the persisted cursor. ---
        var secondRunStaged: [Int64] = []
        let second = try await HistoryImporter.run(
            pageSize: pageSize,
            startCursor: resumePoint,
            readPage: reader,
            stagePage: { samples in
                secondRunStaged.append(contentsOf: samples.map(\.endUnixMs))
                return (inserted: samples.count, hitCap: false)
            }
        )

        XCTAssertTrue(second.exhausted)
        XCTAssertFalse(secondRunStaged.contains(100),
                       "Resuming must NOT re-read the newest page — that is the restart bug")
        XCTAssertEqual(secondRunStaged.first, 90, "Resume continues exactly where it stopped")
        XCTAssertEqual(firstRunStaged + secondRunStaged, history,
                       "Between them the two runs cover the whole range exactly once")
    }

    /// Reading the same range with no persisted cursor DOES restart — the guard
    /// that proves the test above is measuring the cursor, not a coincidence.
    func testFreshRunWithoutCursorStartsAtNewestEnd() async throws {
        let pageSize = 5
        let history: [Int64] = Array(stride(from: 20, through: 1, by: -1))
        var staged: [Int64] = []
        _ = try await HistoryImporter.run(
            pageSize: pageSize,
            readPage: newestFirstReader(endMsNewestFirst: history, pageSize: pageSize),
            stagePage: { samples in
                staged.append(contentsOf: samples.map(\.endUnixMs))
                return (inserted: samples.count, hitCap: false)
            }
        )
        XCTAssertEqual(staged.first, 20)
    }

    /// Only a fully-read range may be reported as complete.
    func testExhaustedIsOnlyTrueWhenTheRangeIsFullyRead() async throws {
        let pageSize = 5
        let history: [Int64] = Array(stride(from: 10, through: 1, by: -1))
        let summary = try await HistoryImporter.run(
            pageSize: pageSize,
            readPage: newestFirstReader(endMsNewestFirst: history, pageSize: pageSize),
            stagePage: { samples in (inserted: samples.count, hitCap: false) }
        )
        XCTAssertTrue(summary.exhausted)
        XCTAssertEqual(summary.staged, 10)
    }

    // MARK: - Fail-quiet (defect 2)

    private struct FakeReadFailure: LocalizedError {
        var errorDescription: String? { "Protected health data is unavailable while the device is locked." }
    }

    /// A HealthKit read failure mid-import must PROPAGATE, not be converted into
    /// a success-shaped summary.
    func testReadFailureMidImportPropagatesInsteadOfLookingLikeSuccess() async throws {
        let pageSize = 5
        let history: [Int64] = Array(stride(from: 100, through: 1, by: -1))
        let reader = newestFirstReader(endMsNewestFirst: history, pageSize: pageSize)
        var pagesRead = 0
        var staged = 0

        do {
            _ = try await HistoryImporter.run(
                pageSize: pageSize,
                readPage: { before in
                    pagesRead += 1
                    if pagesRead == 3 { throw FakeReadFailure() }
                    return try await reader(before)
                },
                stagePage: { samples in
                    staged += samples.count
                    return (inserted: samples.count, hitCap: false)
                }
            )
            XCTFail("A read failure must not be swallowed into a summary")
        } catch is FakeReadFailure {
            // Expected: the caller now sees a real error and records .failed.
            XCTAssertEqual(staged, 10, "Whatever was staged before the failure is kept")
        }
    }

    /// A failure that reaches the runner's outcome must never be success-shaped.
    func testFailedOutcomeIsNeverRenderedAsSuccess() {
        let outcome = ImportRunner.Outcome(
            status: .failed,
            staged: 1_234,
            failureReason: FakeReadFailure().localizedDescription,
            hitCap: false,
            cancelled: false
        )
        XCTAssertFalse(outcome.status.isSuccess)
        XCTAssertTrue(outcome.status.isResumable)
        let text = SettingsViewModel.outcomeText(outcome)
        XCTAssertTrue(text.contains("failed"), "Copy must say it failed, not 'Imported N samples'")
        XCTAssertFalse(text.hasPrefix("Imported "))
        XCTAssertTrue(text.contains("device is locked"), "The reason must be surfaced to the user")
    }

    func testInterruptedAndCancelledOutcomesAreNotSuccess() {
        for status in [ImportRunStatus.interrupted, .failed, .running] {
            XCTAssertFalse(status.isSuccess, "\(status.rawValue) must not be styled as a success")
        }
        XCTAssertTrue(ImportRunStatus.completed.isSuccess)
    }

    // MARK: - Durable state

    private func makeDAO() throws -> ImportProgressDAO {
        ImportProgressDAO(try AppDatabase.makeInMemory())
    }

    func testCheckpointPersistsResumePointAndAggregates() throws {
        let dao = try makeDAO()
        let cursor = Date(timeIntervalSince1970: 1_700_000_000)
        try dao.beginRun(runId: "r1", rangeId: ImportRange.lastYear.rawValue, rangeStart: nil, typesTotal: 2)

        try dao.checkpoint(hkTypeId: "A", runId: "r1", cursor: cursor, stagedCount: 40, status: .running)
        try dao.checkpoint(hkTypeId: "B", runId: "r1", cursor: nil, stagedCount: 10, status: .completed)

        let stored = try XCTUnwrap(dao.typeProgress(hkTypeId: "A"))
        let storedCursor = try XCTUnwrap(stored.cursor)
        XCTAssertEqual(storedCursor.timeIntervalSince1970, cursor.timeIntervalSince1970, accuracy: 0.001)

        let run = try XCTUnwrap(dao.currentRun())
        XCTAssertEqual(run.stagedCount, 50)
        XCTAssertEqual(run.typesCompleted, 1)
        let oldest = try XCTUnwrap(run.oldestReachedAt)
        XCTAssertEqual(oldest.timeIntervalSince1970, cursor.timeIntervalSince1970, accuracy: 0.001)
    }

    /// After a force-quit the row still says `running`; reading it back must
    /// report `interrupted` (resumable), never "running" and never "complete".
    func testStaleRunningRunIsReconciledToInterruptedOnRelaunch() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "r1", cursor: Date(), stagedCount: 7, status: .running)

        // Simulated relaunch.
        try dao.reconcileStaleRun()

        let run = try XCTUnwrap(dao.currentRun())
        XCTAssertEqual(run.status, .interrupted)
        XCTAssertTrue(run.status.isResumable)
        XCTAssertFalse(run.status.isSuccess)
        XCTAssertEqual(run.stagedCount, 7, "Progress survives the relaunch")
        XCTAssertEqual(try dao.typeProgress(hkTypeId: "A")?.status, .interrupted)
        XCTAssertNotNil(try dao.typeProgress(hkTypeId: "A")?.cursor, "The resume point survives the relaunch")
    }

    func testReconcileLeavesTerminalRunsAlone() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.last30Days.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.finishRun(status: .completed)
        try dao.reconcileStaleRun()
        XCTAssertEqual(try dao.currentRun()?.status, .completed)
    }

    /// Resuming keeps the per-type cursors; starting over must discard them.
    func testBeginRunClearsStaleCursorsButResumeKeepsThem() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.lastYear.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "r1", cursor: Date(), stagedCount: 5, status: .interrupted)

        try dao.resumeRun()
        XCTAssertEqual(try dao.currentRun()?.status, .running)
        XCTAssertNotNil(try dao.typeProgress(hkTypeId: "A"), "Resume must not drop the resume point")

        try dao.beginRun(runId: "r2", rangeId: ImportRange.last30Days.rawValue, rangeStart: nil, typesTotal: 1)
        XCTAssertNil(try dao.typeProgress(hkTypeId: "A"),
                     "A new run must not inherit a cursor from a different range")
        XCTAssertEqual(try dao.currentRun()?.stagedCount, 0)
    }

    func testFailedRunRecordsItsReasonDurably() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "r1", cursor: Date(), stagedCount: 3, status: .running)
        try dao.finishRun(status: .failed, failureReason: "Protected data unavailable")

        let run = try XCTUnwrap(dao.currentRun())
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.failureReason, "Protected data unavailable")
        let text = SettingsViewModel.statusText(for: run)
        XCTAssertTrue(text.contains("failed"))
        XCTAssertTrue(text.contains("Protected data unavailable"))
        XCTAssertFalse(text.hasPrefix("Imported "))
    }

    /// "Reached back to" must mean "EVERY type is imported back to at least this
    /// date". One type racing ahead must not make the run claim that depth.
    func testFloorReachedIsTheLeastDeepUnfinishedTypeNotTheDeepest() throws {
        let dao = try makeDAO()
        let deep = Date(timeIntervalSince1970: 1_500_000_000)
        let shallow = Date(timeIntervalSince1970: 1_700_000_000)
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 2)

        try dao.checkpoint(hkTypeId: "A", runId: "r1", cursor: deep, stagedCount: 900, status: .running)
        try dao.checkpoint(hkTypeId: "B", runId: "r1", cursor: shallow, stagedCount: 10, status: .running)

        let floor = try XCTUnwrap(dao.currentRun()?.oldestReachedAt)
        XCTAssertEqual(floor.timeIntervalSince1970, shallow.timeIntervalSince1970, accuracy: 0.001,
                       "The floor must be the least-deep type, never the deepest")
    }

    /// A type that hasn't started yet guarantees nothing, so there is no floor.
    func testFloorReachedIsNilUntilEveryTypeHasStarted() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.lastYear.rawValue, rangeStart: nil, typesTotal: 3)
        try dao.checkpoint(hkTypeId: "A", runId: "r1", cursor: Date(), stagedCount: 5, status: .running)
        XCTAssertNil(try dao.currentRun()?.oldestReachedAt)
    }

    /// A completed type has read its whole range — its (possibly nil) cursor must
    /// not drag the floor, and once all are complete the floor is the range start.
    func testCompletedTypesDoNotDragTheFloorAndAllCompleteReportsTheRangeStart() throws {
        let dao = try makeDAO()
        let rangeStart = Date(timeIntervalSince1970: 1_400_000_000)
        let cursor = Date(timeIntervalSince1970: 1_600_000_000)
        try dao.beginRun(runId: "r1", rangeId: ImportRange.custom.rawValue, rangeStart: rangeStart, typesTotal: 2)

        try dao.checkpoint(hkTypeId: "A", runId: "r1", cursor: nil, stagedCount: 3, status: .completed)
        try dao.checkpoint(hkTypeId: "B", runId: "r1", cursor: cursor, stagedCount: 4, status: .running)
        let partial = try XCTUnwrap(dao.currentRun()?.oldestReachedAt)
        XCTAssertEqual(partial.timeIntervalSince1970, cursor.timeIntervalSince1970, accuracy: 0.001)

        try dao.checkpoint(hkTypeId: "B", runId: "r1", cursor: nil, stagedCount: 9, status: .completed)
        let complete = try XCTUnwrap(dao.currentRun()?.oldestReachedAt)
        XCTAssertEqual(complete.timeIntervalSince1970, rangeStart.timeIntervalSince1970, accuracy: 0.001,
                       "Every type complete means the whole chosen range was covered")
    }

    // MARK: - Process liveness (a live run is never "stale")

    /// The reconcile decision belongs to the RUN, not to whichever view model is
    /// on screen: onboarding's detached import must not be flipped to
    /// `interrupted` just because Settings opened.
    func testLoadPersistedStateDoesNotReconcileARunAClaimHolderIsDriving() throws {
        let database = try AppDatabase.makeInMemory()
        let dao = ImportProgressDAO(database)
        let coordinator = ImportRunCoordinator()
        let runner = ImportRunner(
            database: database,
            engine: SyncEngine(database: database),
            coordinator: coordinator
        )
        try dao.beginRun(runId: "live", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)

        XCTAssertTrue(coordinator.claim("live"))
        let state = runner.loadPersistedState()
        XCTAssertEqual(state.run?.status, .running, "A claimed run is live, not stale")
        XCTAssertTrue(runner.isRunningInThisProcess)

        coordinator.release("live")
        XCTAssertEqual(runner.loadPersistedState().run?.status, .interrupted,
                       "With no claim holder, a surviving `running` row IS stale")
    }

    /// Resuming while a run is claimed must be refused outright — two executions
    /// over one run id would checkpoint the same rows and race on finishRun.
    func testResumeIsRefusedWhileAnotherTaskDrivesTheRun() async throws {
        let database = try AppDatabase.makeInMemory()
        let dao = ImportProgressDAO(database)
        let coordinator = ImportRunCoordinator()
        let runner = ImportRunner(
            database: database,
            engine: SyncEngine(database: database),
            coordinator: coordinator
        )
        try dao.beginRun(runId: "live", rangeId: ImportRange.lastYear.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "live", cursor: Date(), stagedCount: 12, status: .running)
        XCTAssertTrue(coordinator.claim("live"))

        let outcome = await runner.resume(types: [])
        XCTAssertTrue(outcome.alreadyRunning, "A second execution over the same run must be refused")
        XCTAssertEqual(outcome.staged, 12, "The refusal reports the live run verbatim")
        XCTAssertEqual(try dao.currentRun()?.status, .running, "The live run is untouched")
        XCTAssertNotNil(try dao.typeProgress(hkTypeId: "A")?.cursor)
    }

    /// Cancel must reach the run whoever owns it — a `Task.cancel()` on the
    /// Settings view model's own handle can't stop onboarding's detached task.
    func testCancellationRequestReachesTheClaimHolder() {
        let coordinator = ImportRunCoordinator()
        XCTAssertFalse(coordinator.isCancellationRequested)

        // With nothing running there is nothing to cancel.
        coordinator.requestCancellation()
        XCTAssertFalse(coordinator.isCancellationRequested)

        XCTAssertTrue(coordinator.claim("onboarding-run"))
        XCTAssertFalse(coordinator.isCancellationRequested, "A fresh claim starts uncancelled")
        coordinator.requestCancellation()
        XCTAssertTrue(coordinator.isCancellationRequested,
                      "The claim holder must see a cancellation asked for elsewhere")

        coordinator.release("onboarding-run")
        XCTAssertFalse(coordinator.isCancellationRequested, "Release clears the request")
        XCTAssertTrue(coordinator.claim("next-run"))
        XCTAssertFalse(coordinator.isCancellationRequested,
                       "A later run must not inherit the previous cancellation")
    }

    /// A coordinator cancellation stops the paging loop mid-range and leaves a
    /// resume point — the same predicate `ImportRunner` threads into
    /// `SyncEngine.importHistory`, so Cancel reaches a foreign run's inner read.
    func testCoordinatorCancellationStopsPagingAndIsNotSuccessShaped() async throws {
        let pageSize = 5
        let history: [Int64] = Array(stride(from: 100, through: 1, by: -1))
        let reader = newestFirstReader(endMsNewestFirst: history, pageSize: pageSize)
        let coordinator = ImportRunCoordinator()
        XCTAssertTrue(coordinator.claim("onboarding-run"))

        var staged: [Int64] = []
        var pagesRead = 0
        let summary = try await HistoryImporter.run(
            pageSize: pageSize,
            isCancelled: { coordinator.isCancellationRequested },
            readPage: { before in
                pagesRead += 1
                // Someone taps Cancel in Settings while onboarding's run pages.
                if pagesRead == 2 { coordinator.requestCancellation() }
                return try await reader(before)
            },
            stagePage: { samples in
                staged.append(contentsOf: samples.map(\.endUnixMs))
                return (inserted: samples.count, hitCap: false)
            }
        )

        XCTAssertTrue(summary.cancelled)
        XCTAssertFalse(summary.exhausted, "A cancelled range must never report as exhausted")
        XCTAssertNotNil(summary.cursor, "Cancelling still leaves a resume point")
        XCTAssertLessThan(staged.count, history.count)
    }

    /// Enabling more types between an interrupted run and its resume must restate
    /// `types_total`, or the status reads "5/3" and the floor guard goes soft.
    func testResumeRefreshesTypesTotalForANewlyEnabledType() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.lastYear.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "r1", cursor: Date(), stagedCount: 5, status: .completed)
        XCTAssertEqual(try dao.currentRun()?.typesCompleted, 1)

        try dao.updateTypesTotal(2)

        let run = try XCTUnwrap(dao.currentRun())
        XCTAssertEqual(run.typesTotal, 2, "The status must not claim more types finished than exist")
        XCTAssertNil(run.oldestReachedAt,
                     "A newly-enabled type with no row yet must not leave a floor that overstates coverage")
    }

    /// "Start Over" must not delete a live run's cursors underneath it.
    func testClearIsRefusedWhileARunIsClaimed() throws {
        let database = try AppDatabase.makeInMemory()
        let dao = ImportProgressDAO(database)
        let coordinator = ImportRunCoordinator()
        let runner = ImportRunner(
            database: database,
            engine: SyncEngine(database: database),
            coordinator: coordinator
        )
        try dao.beginRun(runId: "live", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "live", cursor: Date(), stagedCount: 4, status: .running)

        XCTAssertTrue(coordinator.claim("live"))
        runner.clear()
        XCTAssertNotNil(try dao.currentRun(), "A claimed run survives Start Over")

        coordinator.release("live")
        runner.clear()
        XCTAssertNil(try dao.currentRun())
    }

    // MARK: - Live status for a run this screen doesn't own

    @MainActor
    private func waitUntil(
        _ message: String,
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    /// Settings must render the LIVE state of a run driven by another part of the
    /// app (onboarding's detached task) — not a frozen `.onAppear` snapshot — and
    /// must therefore offer Cancel while it runs.
    @MainActor
    func testSettingsTracksARunDrivenElsewhereInsteadOfFreezing() async throws {
        let database = try AppDatabase.makeInMemory()
        // Its own coordinator: this test must never read (or be broken by) a claim
        // another test leaked into the process-wide singleton.
        let coordinator = ImportRunCoordinator()
        let viewModel = SettingsViewModel(
            appState: AppState(database: database),
            importCoordinator: coordinator
        )
        let dao = ImportProgressDAO(database)
        viewModel.observeImportState()

        try dao.beginRun(runId: "onboarding", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "onboarding", cursor: Date(), stagedCount: 42, status: .running)
        await waitUntil("Settings must pick up a run it did not start") {
            viewModel.importRun?.status == .running && viewModel.importStagedCount == 42
        }

        XCTAssertTrue(viewModel.isImportActive, "A live foreign run must offer Cancel, not Import")
        XCTAssertFalse(viewModel.canResumeImport, "Resume must never be offered while a run is live")

        try dao.checkpoint(hkTypeId: "A", runId: "onboarding", cursor: Date(), stagedCount: 90, status: .running)
        await waitUntil("The staged count must keep updating, not freeze at the first snapshot") {
            viewModel.importStagedCount == 90
        }

        try dao.finishRun(status: .interrupted)
        await waitUntil("The end of a foreign run must re-enable the Import action") {
            viewModel.importRun?.status == .interrupted
        }
        XCTAssertFalse(viewModel.isImportActive)
        XCTAssertTrue(viewModel.canResumeImport)
        viewModel.stopObservingImportState()
    }

    /// Tapping Cancel must be acknowledged immediately, even though the run only
    /// stops at its next page boundary — silence there reads as "the tap failed".
    @MainActor
    func testCancelIsAcknowledgedImmediatelyAndDoesNotInviteRepeatTaps() async throws {
        let database = try AppDatabase.makeInMemory()
        let coordinator = ImportRunCoordinator()
        let viewModel = SettingsViewModel(
            appState: AppState(database: database),
            importCoordinator: coordinator
        )
        let dao = ImportProgressDAO(database)
        viewModel.observeImportState()

        try dao.beginRun(runId: "onboarding", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "onboarding", cursor: Date(), stagedCount: 10, status: .running)
        XCTAssertTrue(coordinator.claim("onboarding"))
        await waitUntil("The live foreign run must be visible first") {
            viewModel.importRun?.status == .running
        }

        viewModel.cancelImport()
        XCTAssertTrue(viewModel.isCancellingImport, "The tap must be acknowledged at once")
        XCTAssertTrue(coordinator.isCancellationRequested, "The request must reach the live run")
        XCTAssertTrue(viewModel.importProgressText.contains("Cancelling"),
                      "The copy must say it is cancelling, not still 'Importing…'")

        // The run keeps checkpointing until it reaches a boundary; the
        // acknowledgement must survive those ticks.
        try dao.checkpoint(hkTypeId: "A", runId: "onboarding", cursor: Date(), stagedCount: 60, status: .running)
        await waitUntil("Progress keeps flowing while cancelling") { viewModel.importStagedCount == 60 }
        XCTAssertTrue(viewModel.isCancellingImport)
        XCTAssertTrue(viewModel.importProgressText.contains("Cancelling"))

        try dao.finishRun(status: .interrupted)
        coordinator.release("onboarding")
        await waitUntil("Once the run stops, the screen leaves the cancelling state") {
            !viewModel.isCancellingImport
        }
        await waitUntil("The provisional cancelling copy must be replaced by the real terminal status") {
            !viewModel.importProgressText.contains("Cancelling")
        }
        XCTAssertEqual(
            viewModel.importProgressText,
            SettingsViewModel.statusText(for: try XCTUnwrap(dao.currentRun())),
            "A stopped run must show its persisted status, not 'still cancelling'"
        )
        XCTAssertFalse(viewModel.importRun?.status.isSuccess ?? true,
                       "A cancelled run must never render as a success")
        viewModel.stopObservingImportState()
    }

    /// The local run's SPECIFIC terminal copy must still survive a late
    /// observation tick — the provisional cancelling text being transient must not
    /// take the round-1 preserved outcome down with it.
    @MainActor
    func testLocalTerminalOutcomeCopySurvivesALateObservationTick() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = SettingsViewModel(
            appState: AppState(database: database),
            importCoordinator: ImportRunCoordinator()
        )
        let dao = ImportProgressDAO(database)
        viewModel.observeImportState()

        try dao.beginRun(runId: "local", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "local", cursor: Date(), stagedCount: 25, status: .interrupted)
        try dao.finishRun(status: .interrupted)

        let outcome = ImportRunner.Outcome(
            status: .interrupted,
            staged: 25,
            failureReason: nil,
            hitCap: false,
            cancelled: true
        )
        viewModel.importProgressText = SettingsViewModel.outcomeText(outcome)
        viewModel.loadImportState(preserveOutcome: true)

        try dao.checkpoint(hkTypeId: "B", runId: "local", cursor: Date(), stagedCount: 1, status: .interrupted)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(viewModel.importProgressText.contains("cancelled"),
                      "The specific terminal copy must not be clobbered by the generic status text")
        viewModel.stopObservingImportState()
    }

    func testClearForgetsTheRun() throws {
        let dao = try makeDAO()
        try dao.beginRun(runId: "r1", rangeId: ImportRange.last30Days.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "r1", cursor: Date(), stagedCount: 1, status: .running)
        try dao.clear()
        XCTAssertNil(try dao.currentRun())
        XCTAssertTrue(try dao.allTypeProgress().isEmpty)
    }
}
