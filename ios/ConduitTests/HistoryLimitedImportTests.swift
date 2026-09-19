import XCTest
@testable import Conduit

/// Tests for the iOS 27 "limited history" defect: under a "Past 30 Days" grant,
/// an "All time" import used to silently stage only the in-range samples while
/// still recording `status = completed, isSuccess = true` — pixel-identical to a
/// genuinely complete import (scout report `report.md` §3).
///
/// The runner tests below never touch a live `HKHealthStore`: every enabled
/// type is pre-seeded as `.completed` in the DAO before `resume(types:)` is
/// called, so `ImportRunner`'s `existing?.status == .completed { continue }`
/// skip fires for each one and the type loop never calls
/// `SyncEngine.importHistory`. That isolates exactly the new logic under test
/// — the post-loop probe + downgrade decision — from HealthKit itself, using
/// only the injected `HistoryAccessProbing` stub.
final class HistoryLimitedImportTests: XCTestCase {

    private struct StubHistoryAccessProbe: HistoryAccessProbing {
        let floors: [String: Date]
        /// Stands in for a thrown `earliestAuthorizedSampleDate`: iOS could not
        /// answer, which must never read as "full access confirmed".
        let unresolved: Bool

        init(floors: [String: Date] = [:], unresolved: Bool = false) {
            self.floors = floors
            self.unresolved = unresolved
        }

        func limitedHistoryFloors(for types: [HealthDataType]) async -> HistoryAccessFloors {
            if unresolved { return .unresolved }
            var result: [String: Date] = [:]
            for type in types {
                if let floor = floors[type.identifier] { result[type.identifier] = floor }
            }
            return .resolved(result)
        }
    }

    private func makeRunner(
        database: AppDatabase,
        probe: HistoryAccessProbing,
        coordinator: ImportRunCoordinator = ImportRunCoordinator()
    ) -> ImportRunner {
        ImportRunner(
            database: database,
            engine: SyncEngine(database: database),
            coordinator: coordinator,
            probe: probe
        )
    }

    private func date(_ daysAgo: Double) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400)
    }

    // MARK: - The key regression

    /// An `.allTime` run that exhausted its read (per-type `.completed`, as
    /// `HistoryImporter` reports when HealthKit returns an empty page) must
    /// NOT be reported complete when the post-loop probe reveals that "empty
    /// page" was actually the iOS 27 history-access wall, not the end of the
    /// user's real history.
    func testExhaustedRunIsNotReportedCompleteWhenAFloorWasReached() async throws {
        let database = try AppDatabase.makeInMemory()
        let dao = ImportProgressDAO(database)
        let type = HealthDataType.stepCount
        let floor = date(30)

        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        // Simulate the exact defect: HealthKit returned an empty page at the
        // 30-day floor, which `HistoryImporter` reports as `exhausted: true`,
        // so the type was checkpointed `.completed`.
        try dao.checkpoint(hkTypeId: type.identifier, runId: "r1", cursor: floor, stagedCount: 10, status: .completed)

        let runner = makeRunner(database: database, probe: StubHistoryAccessProbe(floors: [type.identifier: floor]))
        let outcome = await runner.resume(types: [type])

        XCTAssertEqual(outcome.status, .interrupted)
        XCTAssertFalse(outcome.status.isSuccess, "A run that hit a history-access floor must never render as a success")
        XCTAssertTrue(outcome.historyLimited)
        XCTAssertEqual(outcome.historyFloor, floor)

        let run = try XCTUnwrap(dao.currentRun())
        XCTAssertEqual(run.status, .interrupted)
        XCTAssertEqual(run.stopCause, .historyLimited)
        XCTAssertEqual(run.historyFloor, floor)
        XCTAssertEqual(try dao.typeProgress(hkTypeId: type.identifier)?.status, .interrupted,
                       "The type must be downgraded so a later Resume actually revisits it")
    }

    /// The regression guard in the other direction: with NO floor reported
    /// (pre-iOS-27, or full access), the exact same exhausted run MUST still
    /// be reported complete — this feature must not regress the existing
    /// "genuinely finished" case.
    func testExhaustedRunStaysCompleteWhenNoFloorWasReached() async throws {
        let database = try AppDatabase.makeInMemory()
        let dao = ImportProgressDAO(database)
        let type = HealthDataType.stepCount

        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: type.identifier, runId: "r1", cursor: nil, stagedCount: 26, status: .completed)

        let runner = makeRunner(database: database, probe: StubHistoryAccessProbe(floors: [:]))
        let outcome = await runner.resume(types: [type])

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertTrue(outcome.status.isSuccess)
        XCTAssertFalse(outcome.historyLimited)
        XCTAssertNil(outcome.historyFloor)

        let run = try XCTUnwrap(dao.currentRun())
        XCTAssertEqual(run.status, .completed)
        XCTAssertNil(run.stopCause)
        XCTAssertNil(run.historyFloor)
        XCTAssertEqual(try dao.typeProgress(hkTypeId: type.identifier)?.status, .completed)
    }

    /// Detection is per type: a mixed grant (one type limited, one not) must
    /// downgrade only the limited type and leave the other's `.completed`
    /// status untouched, while the RUN as a whole is still correctly reported
    /// non-complete.
    func testMixedGrantDowngradesOnlyTheLimitedType() async throws {
        let database = try AppDatabase.makeInMemory()
        let dao = ImportProgressDAO(database)
        let limited = HealthDataType.stepCount
        let full = HealthDataType.heartRate
        let floor = date(30)

        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 2)
        try dao.checkpoint(hkTypeId: limited.identifier, runId: "r1", cursor: floor, stagedCount: 5, status: .completed)
        try dao.checkpoint(hkTypeId: full.identifier, runId: "r1", cursor: nil, stagedCount: 13, status: .completed)

        let runner = makeRunner(database: database, probe: StubHistoryAccessProbe(floors: [limited.identifier: floor]))
        let outcome = await runner.resume(types: [limited, full])

        XCTAssertEqual(outcome.status, .interrupted)
        XCTAssertTrue(outcome.historyLimited)
        XCTAssertEqual(try dao.typeProgress(hkTypeId: limited.identifier)?.status, .interrupted)
        XCTAssertEqual(try dao.typeProgress(hkTypeId: full.identifier)?.status, .completed,
                       "An unrestricted type's completed status must not be touched by another type's floor")
    }

    /// A bounded range (not `.allTime`) that never reaches as far back as the
    /// floor must NOT be downgraded — the floor is irrelevant to a range that
    /// never asked to go that far.
    func testBoundedRangeThatDoesNotReachTheFloorIsNotDowngraded() async throws {
        let database = try AppDatabase.makeInMemory()
        let dao = ImportProgressDAO(database)
        let type = HealthDataType.stepCount
        let floor = date(90) // the grant only reaches back 90 days
        let rangeStart = date(30) // the run only asked for the last 30 days

        try dao.beginRun(runId: "r1", rangeId: ImportRange.last30Days.rawValue, rangeStart: rangeStart, typesTotal: 1)
        try dao.checkpoint(hkTypeId: type.identifier, runId: "r1", cursor: rangeStart, stagedCount: 30, status: .completed)

        let runner = makeRunner(database: database, probe: StubHistoryAccessProbe(floors: [type.identifier: floor]))
        let outcome = await runner.resume(types: [type])

        XCTAssertEqual(outcome.status, .completed, "The run's own intended range never reached the floor")
        XCTAssertFalse(outcome.historyLimited)
    }

    // MARK: - Probe that can't answer

    /// A probe that FAILED reports `.unresolved`, which is not the same fact as
    /// "iOS confirms full access" (`.resolved([:])`). An exhausted run whose
    /// floors could not be determined must therefore stay non-success: the
    /// empty page it stopped on may well have been a history-access wall.
    func testUnresolvedProbeNeverReportsAnExhaustedRunAsComplete() async throws {
        let database = try AppDatabase.makeInMemory()
        let dao = ImportProgressDAO(database)
        let type = HealthDataType.stepCount

        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: type.identifier, runId: "r1", cursor: nil, stagedCount: 10, status: .completed)

        let runner = makeRunner(database: database, probe: StubHistoryAccessProbe(unresolved: true))
        let outcome = await runner.resume(types: [type])

        XCTAssertEqual(outcome.status, .interrupted)
        XCTAssertFalse(outcome.status.isSuccess,
                       "An undetermined floor must never earn the green checkmark a truncated import can't have")
        XCTAssertTrue(outcome.status.isResumable, "Resume re-probes, so the user has a real way forward")

        let run = try XCTUnwrap(dao.currentRun())
        XCTAssertEqual(run.status, .interrupted)
        XCTAssertFalse(run.status.isSuccess)
        XCTAssertNil(run.historyFloor, "No floor is known, so none may be claimed")
        XCTAssertEqual(run.stopCause, .endedShort)
    }

    // MARK: - Resume under a still-narrow grant

    /// An explicit Resume while the grant is STILL narrow must land back on
    /// `.historyLimited` — the post-loop probe decides that afresh every pass,
    /// so no separate pre-flight check is needed to keep the state honest.
    func testResumeUnderAStillNarrowGrantLandsBackOnHistoryLimited() async throws {
        let database = try AppDatabase.makeInMemory()
        let dao = ImportProgressDAO(database)
        let type = HealthDataType.stepCount
        let floor = date(30)

        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        // Pre-seeded `.completed` so the loop's per-type skip fires and this
        // test never needs a live HealthKit read.
        try dao.checkpoint(hkTypeId: type.identifier, runId: "r1", cursor: floor, stagedCount: 10, status: .completed)
        try dao.finishRun(status: .interrupted, autoResume: false, stopCause: .historyLimited, historyFloor: floor)

        let runner = makeRunner(database: database, probe: StubHistoryAccessProbe(floors: [type.identifier: floor]))
        let outcome = await runner.resume(types: [type])

        XCTAssertEqual(outcome.status, .interrupted)
        XCTAssertTrue(outcome.historyLimited)
        XCTAssertEqual(outcome.historyFloor, floor)
        XCTAssertEqual(try dao.currentRun()?.stopCause, .historyLimited)
        XCTAssertEqual(try dao.typeProgress(hkTypeId: type.identifier)?.status, .interrupted,
                       "The type must stay downgraded so a later Resume revisits it once access widens")
    }

    /// A type the user enabled AFTER the run parked on `.historyLimited` must
    /// actually be attempted by Resume. It used to be skipped wholesale: a
    /// pre-flight "is any type still limited?" check returned before the type
    /// loop ever ran, so the new type's readable, in-window history was never
    /// staged and Resume looked like it did nothing.
    ///
    /// The attempt fails here only because this fixture has no webhook row to
    /// stage to (`ImportError.noWebhookConfigured`) — which is precisely what
    /// makes "was it attempted at all?" observable without a live HealthKit
    /// read.
    func testResumeAttemptsATypeEnabledAfterTheRunWasParked() async throws {
        let database = try AppDatabase.makeInMemory()
        let dao = ImportProgressDAO(database)
        let alreadyImported = HealthDataType.stepCount
        let newlyEnabled = HealthDataType.heartRate
        let floor = date(30)

        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: alreadyImported.identifier, runId: "r1", cursor: floor, stagedCount: 10, status: .completed)
        try dao.finishRun(status: .interrupted, autoResume: false, stopCause: .historyLimited, historyFloor: floor)

        let runner = makeRunner(
            database: database,
            probe: StubHistoryAccessProbe(floors: [alreadyImported.identifier: floor])
        )
        let outcome = await runner.resume(types: [alreadyImported, newlyEnabled])

        XCTAssertNotNil(try dao.typeProgress(hkTypeId: newlyEnabled.identifier),
                        "Resume must reach a type enabled after the run parked, not return before the type loop")
        XCTAssertEqual(try dao.currentRun()?.typesTotal, 2,
                       "\"N/M types finished\" must count the grown enabled set, not the stale one")
        XCTAssertFalse(outcome.historyLimited,
                       "Resume must not re-render the same parked state while readable work was still pending")
    }

    /// Once the user actually widens access, an explicit Resume must be free to
    /// complete — the outcome is keyed on the grant as it is NOW, never on the
    /// stop reason recorded from before.
    func testResumeProceedsNormallyOnceAccessHasBeenWidened() async throws {
        let database = try AppDatabase.makeInMemory()
        let dao = ImportProgressDAO(database)
        let type = HealthDataType.stepCount
        let floor = date(30)

        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        // Pre-seed as already `.completed` so the loop's per-type skip fires
        // and this test never needs a live HealthKit read.
        try dao.checkpoint(hkTypeId: type.identifier, runId: "r1", cursor: nil, stagedCount: 26, status: .completed)
        try dao.finishRun(status: .interrupted, autoResume: false, stopCause: .historyLimited, historyFloor: floor)

        // The user widened access: the probe now reports no floor at all.
        let runner = makeRunner(database: database, probe: StubHistoryAccessProbe(floors: [:]))
        let outcome = await runner.resume(types: [type])

        XCTAssertEqual(outcome.status, .completed, "Once widened, the run must be free to complete")
        XCTAssertFalse(outcome.historyLimited)
        XCTAssertNil(try dao.currentRun()?.historyFloor)
    }

    // MARK: - DAO round-trip

    func testHistoryFloorRoundTripsThroughFinishRun() throws {
        let dao = ImportProgressDAO(try AppDatabase.makeInMemory())
        let floor = date(30)
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.finishRun(status: .interrupted, autoResume: false, stopCause: .historyLimited, historyFloor: floor)

        let run = try XCTUnwrap(dao.currentRun())
        XCTAssertEqual(run.stopCause, .historyLimited)
        let roundTripped = try XCTUnwrap(run.historyFloor)
        XCTAssertEqual(roundTripped.timeIntervalSince1970, floor.timeIntervalSince1970, accuracy: 0.001)
    }

    /// A resume clears the prior floor/cause — whatever stops THIS pass
    /// records the answer afresh, exactly like `stopCause` and `autoResume`.
    func testResumeRunClearsThePriorHistoryFloor() throws {
        let dao = ImportProgressDAO(try AppDatabase.makeInMemory())
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.finishRun(status: .interrupted, stopCause: .historyLimited, historyFloor: date(30))

        try dao.resumeRun()
        XCTAssertNil(try dao.currentRun()?.historyFloor)
        XCTAssertNil(try dao.currentRun()?.stopCause)
    }

    // MARK: - Migration

    func testImportRunHasHistoryFloorColumn() throws {
        let appDB = try AppDatabase.makeInMemory()
        try appDB.dbWriter.read { db in
            let columns = try Set(db.columns(in: "import_run").map(\.name))
            XCTAssertTrue(columns.contains("history_floor"))
        }
    }

    /// v11 must be purely additive, like v8/v9/v10 before it.
    func testHistoryFloorMigrationDoesNotTouchExistingColumns() throws {
        let appDB = try AppDatabase.makeInMemory()
        try appDB.dbWriter.read { db in
            let columns = try Set(db.columns(in: "import_run").map(\.name))
            for existing in ["id", "run_id", "range_id", "status", "staged_count", "auto_resume", "stop_cause"] {
                XCTAssertTrue(columns.contains(existing))
            }
        }
    }

    // MARK: - Copy

    func testHistoryLimitedStatusTitleIsDistinctFromGenericInterrupted() throws {
        let dao = ImportProgressDAO(try AppDatabase.makeInMemory())
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.finishRun(status: .interrupted, stopCause: .historyLimited, historyFloor: date(30))

        let run = try XCTUnwrap(dao.currentRun())
        let title = SettingsViewModel.statusTitle(for: run)
        XCTAssertEqual(title, "History limited")
        XCTAssertNotEqual(title, "Import interrupted")
        XCTAssertNotEqual(title, "Import paused")
    }

    func testHistoryLimitedStatusTextNamesTheFixAndNeverClaimsAbsence() throws {
        let dao = ImportProgressDAO(try AppDatabase.makeInMemory())
        let floor = date(30)
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.checkpoint(hkTypeId: "A", runId: "r1", cursor: floor, stagedCount: 10, status: .interrupted)
        try dao.finishRun(status: .interrupted, stopCause: .historyLimited, historyFloor: floor)

        let run = try XCTUnwrap(dao.currentRun())
        let text = SettingsViewModel.statusText(for: run)
        XCTAssertTrue(text.contains("Settings"), "Must name the actual fix, not a vague retry")
        XCTAssertTrue(text.contains("Resume"))
        XCTAssertTrue(text.contains("may still exist") || text.contains("wasn't imported"),
                      "Must never assert the older data doesn't exist — Apple's own guidance is 'unknown', not 'absent'")
        XCTAssertFalse(text.hasPrefix("Import interrupted"))
    }

    func testHistoryLimitedOutcomeTextIsDistinctFromGenericInterrupted() {
        let outcome = ImportRunner.Outcome(
            status: .interrupted,
            staged: 10,
            failureReason: nil,
            hitCap: false,
            cancelled: false,
            historyLimited: true,
            historyFloor: date(30)
        )
        let text = SettingsViewModel.outcomeText(outcome)
        XCTAssertTrue(text.contains("Settings"))
        XCTAssertFalse(text.contains("didn't finish the range"),
                       "Must use the specific history-limited copy, not the generic interrupted line")
    }

    func testHistoryLimitedIsNeverStyledAsSuccess() {
        XCTAssertFalse(ImportRunStatus.interrupted.isSuccess)
        let outcome = ImportRunner.Outcome(
            status: .interrupted,
            staged: 10,
            failureReason: nil,
            hitCap: false,
            cancelled: false,
            historyLimited: true,
            historyFloor: date(30)
        )
        XCTAssertFalse(outcome.status.isSuccess)
        XCTAssertTrue(outcome.status.isResumable)
    }
}
