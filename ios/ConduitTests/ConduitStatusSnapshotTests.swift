import XCTest
@testable import Conduit

/// Tests for the Lock Screen widget's status snapshot: the codec that crosses
/// the App Group boundary, the `accessoryRectangular` second-line chooser, the
/// `accessoryCircular` symbol chooser, the reload-budget gate, and the app-side
/// policy deciding which import runs earn the widget's second line. None of the
/// snapshot helpers touch the App Group container or GRDB — the widget
/// extension never opens either (`data/conduit-live-activities-scout/report.md`
/// §7.2); only the import-headline group below reads a real run row, since the
/// state it must distinguish is one the `ImportProgressDAO` writes.
final class ConduitStatusSnapshotTests: XCTestCase {
    private func makeSnapshot(
        syncStatus: ConduitStatusSnapshot.SyncStatus = .synced,
        lastSyncedAt: Date? = Date(timeIntervalSince1970: 1_000),
        pendingCount: Int = 0,
        failedCount: Int = 0,
        stagedTodayCount: Int = 0,
        importStatusHeadline: String? = nil
    ) -> ConduitStatusSnapshot {
        ConduitStatusSnapshot(
            syncStatus: syncStatus,
            lastSyncedAt: lastSyncedAt,
            pendingCount: pendingCount,
            failedCount: failedCount,
            stagedTodayCount: stagedTodayCount,
            importStatusHeadline: importStatusHeadline
        )
    }

    // MARK: - Codec round-trip

    func test_codec_roundTripsAllFields() throws {
        let snapshot = makeSnapshot(
            syncStatus: .error,
            pendingCount: 3,
            failedCount: 2,
            stagedTodayCount: 42,
            importStatusHeadline: "History limited"
        )
        let data = try snapshot.encoded()
        let decoded = try ConduitStatusSnapshot.decoded(from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func test_codec_roundTripsNilOptionalFields() throws {
        let snapshot = makeSnapshot(syncStatus: .idle, lastSyncedAt: nil)
        let data = try snapshot.encoded()
        let decoded = try ConduitStatusSnapshot.decoded(from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    // MARK: - secondLine(for:) — accessoryRectangular, first match wins

    func test_secondLine_failedTakesPriorityOverEverything() {
        let snapshot = makeSnapshot(
            failedCount: 1,
            stagedTodayCount: 99,
            importStatusHeadline: "Import paused"
        )
        XCTAssertEqual(ConduitStatusSnapshot.secondLine(for: snapshot), "1 failed")
    }

    func test_secondLine_importHeadline_whenNoFailures() {
        let snapshot = makeSnapshot(pendingCount: 5, importStatusHeadline: "History limited")
        XCTAssertEqual(ConduitStatusSnapshot.secondLine(for: snapshot), "History limited")
    }

    func test_secondLine_pendingCount_whenNoFailuresOrImportHeadline() {
        let snapshot = makeSnapshot(pendingCount: 7, stagedTodayCount: 12)
        XCTAssertEqual(ConduitStatusSnapshot.secondLine(for: snapshot), "7 pending")
    }

    func test_secondLine_stagedToday_steadyState() {
        let snapshot = makeSnapshot(stagedTodayCount: 1_204)
        XCTAssertEqual(ConduitStatusSnapshot.secondLine(for: snapshot), "Staged today 1204")
    }

    // MARK: - symbolName(for:) — accessoryCircular

    func test_symbolName_failedCount_isFailing() {
        let snapshot = makeSnapshot(syncStatus: .synced, failedCount: 1)
        XCTAssertEqual(ConduitStatusSnapshot.symbolName(for: snapshot), "exclamationmark.triangle")
    }

    func test_symbolName_errorStatus_isFailing() {
        let snapshot = makeSnapshot(syncStatus: .error)
        XCTAssertEqual(ConduitStatusSnapshot.symbolName(for: snapshot), "exclamationmark.triangle")
    }

    func test_symbolName_idleStatus_isStale() {
        let snapshot = makeSnapshot(syncStatus: .idle, lastSyncedAt: nil)
        XCTAssertEqual(ConduitStatusSnapshot.symbolName(for: snapshot), "clock.badge.exclamationmark")
    }

    func test_symbolName_syncedNoFailures_isHealthy() {
        let snapshot = makeSnapshot(syncStatus: .synced)
        XCTAssertEqual(ConduitStatusSnapshot.symbolName(for: snapshot), "checkmark.circle")
    }

    // MARK: - shouldReloadTimelines — the reload-budget gate

    func test_shouldReload_noPreviousSnapshot_alwaysReloads() {
        XCTAssertTrue(ConduitStatusSnapshot.shouldReloadTimelines(previous: nil, next: makeSnapshot()))
    }

    func test_shouldReload_errorAppearing_reloads() {
        let previous = makeSnapshot(syncStatus: .synced)
        let next = makeSnapshot(syncStatus: .error)
        XCTAssertTrue(ConduitStatusSnapshot.shouldReloadTimelines(previous: previous, next: next))
    }

    func test_shouldReload_errorClearing_reloads() {
        let previous = makeSnapshot(syncStatus: .error)
        let next = makeSnapshot(syncStatus: .synced)
        XCTAssertTrue(ConduitStatusSnapshot.shouldReloadTimelines(previous: previous, next: next))
    }

    func test_shouldReload_failedCountCrossingZero_reloads() {
        let previous = makeSnapshot(failedCount: 0)
        let next = makeSnapshot(failedCount: 1)
        XCTAssertTrue(ConduitStatusSnapshot.shouldReloadTimelines(previous: previous, next: next))
    }

    func test_shouldReload_importHeadlineChanging_reloads() {
        let previous = makeSnapshot(importStatusHeadline: "Importing…")
        let next = makeSnapshot(importStatusHeadline: "History limited")
        XCTAssertTrue(ConduitStatusSnapshot.shouldReloadTimelines(previous: previous, next: next))
    }

    /// The masking case this whole gate exists to prevent: a bare timestamp or
    /// staged-count change (the common case, ≥96 background wakes/day) must
    /// NOT spend a reload, or the widget would blow its daily budget.
    func test_shouldReload_timestampOrStagedCountOnlyChange_doesNotReload() {
        let previous = makeSnapshot(lastSyncedAt: Date(timeIntervalSince1970: 1_000), stagedTodayCount: 10)
        let next = makeSnapshot(lastSyncedAt: Date(timeIntervalSince1970: 5_000), stagedTodayCount: 11)
        XCTAssertFalse(ConduitStatusSnapshot.shouldReloadTimelines(previous: previous, next: next))
    }

    func test_shouldReload_failedCountChangingButStayingPositive_doesNotReload() {
        let previous = makeSnapshot(failedCount: 2)
        let next = makeSnapshot(failedCount: 5)
        XCTAssertFalse(ConduitStatusSnapshot.shouldReloadTimelines(previous: previous, next: next))
    }

    /// A fresh install's first successful sync flips both the symbol
    /// (`clock.badge.exclamationmark` → `checkmark.circle`) and the first line
    /// ("No syncs yet" → "Synced N ago"). Without a reload the Lock Screen keeps
    /// claiming the app has never synced until the best-effort 15-minute
    /// timeline policy happens to fire.
    func test_shouldReload_firstSyncLeavingIdle_reloads() {
        let previous = makeSnapshot(syncStatus: .idle, lastSyncedAt: nil)
        let next = makeSnapshot(syncStatus: .synced, lastSyncedAt: Date(timeIntervalSince1970: 5_000))
        XCTAssertTrue(ConduitStatusSnapshot.shouldReloadTimelines(previous: previous, next: next))
    }

    // MARK: - AppState.importHeadline — which runs earn the widget's second line

    /// The `import_run` row is a singleton that survives until a brand-new run
    /// begins, and `secondLine` ranks the headline above the pending count. So a
    /// run the user cancelled must not produce a headline at all, or the Lock
    /// Screen reads "Import cancelled" forever and can never again surface the
    /// stuck upload queue this widget exists to expose.
    func test_importHeadline_cancelledRun_doesNotPinTheSecondLine() throws {
        let dao = ImportProgressDAO(try AppDatabase.makeInMemory())
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.finishRun(status: .interrupted, autoResume: false, stopCause: .userCancelled)

        let run = try XCTUnwrap(dao.currentRun())
        XCTAssertEqual(SettingsViewModel.statusTitle(for: run), "Import cancelled",
                       "Settings still names the cancel — only the Lock Screen declines to pin it")
        XCTAssertNil(AppState.importHeadline(for: run))

        let snapshot = makeSnapshot(pendingCount: 7, importStatusHeadline: AppState.importHeadline(for: run))
        XCTAssertEqual(ConduitStatusSnapshot.secondLine(for: snapshot), "7 pending")
    }

    /// The other half of the same rule: a stop the user can still act on keeps
    /// its priority over the pending count.
    func test_importHeadline_actionableStopCauses_keepPriority() throws {
        let cases: [(ImportStopCause, String)] = [
            (.historyLimited, "History limited"),
            (.historyAccessUnknown, "History access unknown"),
            (.queueNotDraining, "Import paused"),
            (.backgrounded, "Import paused"),
            (.endedShort, "Import interrupted"),
        ]
        for (cause, expected) in cases {
            let dao = ImportProgressDAO(try AppDatabase.makeInMemory())
            try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
            try dao.finishRun(
                status: .interrupted,
                autoResume: cause == .backgrounded,
                stopCause: cause
            )

            let run = try XCTUnwrap(dao.currentRun())
            XCTAssertEqual(AppState.importHeadline(for: run), expected, "stopCause \(cause)")

            let snapshot = makeSnapshot(pendingCount: 7, importStatusHeadline: AppState.importHeadline(for: run))
            XCTAssertEqual(ConduitStatusSnapshot.secondLine(for: snapshot), expected, "stopCause \(cause)")
        }
    }

    func test_importHeadline_runningRun_isSurfaced() throws {
        let dao = ImportProgressDAO(try AppDatabase.makeInMemory())
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)

        XCTAssertEqual(AppState.importHeadline(for: try XCTUnwrap(dao.currentRun())), "Importing…")
    }

    func test_importHeadline_completedRun_andNoRun_areSilent() throws {
        let dao = ImportProgressDAO(try AppDatabase.makeInMemory())
        XCTAssertNil(AppState.importHeadline(for: try dao.currentRun()))

        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.finishRun(status: .completed)

        XCTAssertNil(AppState.importHeadline(for: try XCTUnwrap(dao.currentRun())))
    }
}
