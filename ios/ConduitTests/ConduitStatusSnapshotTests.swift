import XCTest
@testable import Conduit

/// Tests for the Lock Screen widget's status snapshot: the codec that crosses
/// the App Group boundary, the `accessoryRectangular` second-line chooser, the
/// `accessoryCircular` symbol chooser, the reload-budget gate, and the app-side
/// policy deciding which import runs earn the widget's second line. None of the
/// snapshot helpers touch the App Group container or GRDB — the widget
/// extension never opens either (`data/conduit-live-activities-scout/report.md`
/// §7.2); the import-headline and shared-observation groups below do read real
/// rows, since the states they must distinguish are ones the DAOs write.
final class ConduitStatusSnapshotTests: XCTestCase {
    private func makeSnapshot(
        syncStatus: ConduitStatusSnapshot.SyncStatus = .synced,
        lastSyncedAt: Date? = Date(timeIntervalSince1970: 1_000),
        pendingCount: Int = 0,
        failedCount: Int = 0,
        stagedTodayCount: Int = 0,
        stagedTodayDay: Date = ConduitStatusSnapshotTests.noon,
        importStatusHeadline: String? = nil
    ) -> ConduitStatusSnapshot {
        ConduitStatusSnapshot(
            syncStatus: syncStatus,
            lastSyncedAt: lastSyncedAt,
            pendingCount: pendingCount,
            failedCount: failedCount,
            stagedTodayCount: stagedTodayCount,
            stagedTodayDay: stagedTodayDay,
            importStatusHeadline: importStatusHeadline
        )
    }

    /// A fixed local day the staged tally is attributed to, plus the same wall
    /// clock a day later. Built from the current calendar so the day boundary
    /// under test is the one the code actually uses.
    private static let noon = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        .addingTimeInterval(12 * 3_600)
    private static var nextDayNoon: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: noon)!
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
        XCTAssertEqual(ConduitStatusSnapshot.secondLine(for: snapshot, now: Self.noon), "1 failed")
    }

    func test_secondLine_importHeadline_whenNoFailures() {
        let snapshot = makeSnapshot(pendingCount: 5, importStatusHeadline: "History limited")
        XCTAssertEqual(ConduitStatusSnapshot.secondLine(for: snapshot, now: Self.noon), "History limited")
    }

    func test_secondLine_pendingCount_whenNoFailuresOrImportHeadline() {
        let snapshot = makeSnapshot(pendingCount: 7, stagedTodayCount: 12)
        XCTAssertEqual(ConduitStatusSnapshot.secondLine(for: snapshot, now: Self.noon), "7 pending")
    }

    func test_secondLine_stagedToday_steadyState() {
        let snapshot = makeSnapshot(stagedTodayCount: 1_204)
        XCTAssertEqual(ConduitStatusSnapshot.secondLine(for: snapshot, now: Self.noon), "Staged today 1204")
    }

    /// `staged_daily_count` buckets per local day, and a clock crossing midnight
    /// is not a database write — so nothing recomputes the snapshot sitting in
    /// the App Group container. Rendered against the next day it must read 0,
    /// not yesterday's tally under a "today" label.
    func test_secondLine_stagedToday_isZeroOnceTheDayHasTurned() {
        let snapshot = makeSnapshot(stagedTodayCount: 1_204, stagedTodayDay: Self.noon)
        XCTAssertEqual(
            ConduitStatusSnapshot.secondLine(for: snapshot, now: Self.nextDayNoon),
            "Staged today 0"
        )
    }

    /// The same rule must not fire early: any moment still inside the tallied
    /// day keeps the real count.
    func test_secondLine_stagedToday_survivesToTheEndOfItsOwnDay() {
        let snapshot = makeSnapshot(stagedTodayCount: 1_204, stagedTodayDay: Self.noon)
        let lastSecond = Calendar.current.startOfDay(for: Self.nextDayNoon).addingTimeInterval(-1)
        XCTAssertEqual(
            ConduitStatusSnapshot.secondLine(for: snapshot, now: lastSecond),
            "Staged today 1204"
        )
    }

    // MARK: - timelineEntryDates — the midnight boundary entry

    /// A timeline holding one entry renders that entry's date until the next
    /// rebuild, so without a boundary entry the widget keeps yesterday's tally
    /// on screen past midnight.
    func test_timelineEntryDates_carriesTheMidnightBoundaryWhenItIsImminent() {
        let midnight = Calendar.current.startOfDay(for: Self.nextDayNoon)
        let now = midnight.addingTimeInterval(-10 * 60)

        XCTAssertEqual(ConduitStatusSnapshot.timelineEntryDates(from: now), [now, midnight])
    }

    /// The boundary cannot be conditional on midnight falling inside one
    /// refresh interval: WidgetKit treats the refresh policy as a hint, not a
    /// promise (Low Power Mode suspends refreshes outright), so a timeline
    /// built at noon and never rebuilt must still flip the tally at midnight
    /// rather than render "Staged today 1204" on a day nothing was staged.
    func test_timelineEntryDates_carriesTheMidnightBoundaryEvenWhenItIsHoursAway() {
        let now = Self.noon
        let midnight = Calendar.current.startOfDay(for: Self.nextDayNoon)

        XCTAssertEqual(ConduitStatusSnapshot.timelineEntryDates(from: now), [now, midnight])
    }

    /// The entry only pays off if rendering against it actually zeroes the
    /// tally — the whole point of carrying `stagedTodayDay`.
    func test_timelineEntryDates_midnightEntryRendersTheTallyAsZero() throws {
        let snapshot = makeSnapshot(stagedTodayCount: 1_204, stagedTodayDay: Self.noon)
        let midnight = try XCTUnwrap(ConduitStatusSnapshot.timelineEntryDates(from: Self.noon).last)

        XCTAssertEqual(
            ConduitStatusSnapshot.secondLine(for: snapshot, now: midnight),
            "Staged today 0"
        )
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
    /// claiming the app has never synced until the best-effort hourly
    /// timeline policy happens to fire.
    func test_shouldReload_firstSyncLeavingIdle_reloads() {
        let previous = makeSnapshot(syncStatus: .idle, lastSyncedAt: nil)
        let next = makeSnapshot(syncStatus: .synced, lastSyncedAt: Date(timeIntervalSince1970: 5_000))
        XCTAssertTrue(ConduitStatusSnapshot.shouldReloadTimelines(previous: previous, next: next))
    }

    // MARK: - shouldWriteToAppGroup — the App Group write gate

    /// A fixed clock for the gate's interval arithmetic.
    private static let writeGateNow = Date(timeIntervalSince1970: 1_700_000_000)

    func test_shouldWrite_nothingWrittenYet_writes() {
        XCTAssertTrue(ConduitStatusSnapshot.shouldWriteToAppGroup(
            previous: nil,
            writtenAt: nil,
            next: makeSnapshot(),
            now: Self.writeGateNow
        ))
    }

    func test_shouldWrite_unchangedSnapshot_doesNotWrite() {
        let snapshot = makeSnapshot(pendingCount: 4)
        XCTAssertFalse(ConduitStatusSnapshot.shouldWriteToAppGroup(
            previous: snapshot,
            writtenAt: Self.writeGateNow.addingTimeInterval(-10 * ConduitStatusSnapshot.timelineRefreshInterval),
            next: snapshot,
            now: Self.writeGateNow
        ))
    }

    /// The case that dominates a large import: ~10^4 deliveries that only move
    /// a count or a stamp. Nothing reads the container between rebuilds, so
    /// each of those writes publishes a state no one sees — at the price of an
    /// encode and an atomic file write apiece, on a path a background-only
    /// launch pays with no screen to show for it.
    func test_shouldWrite_countOnlyChangeInsideTheRefreshInterval_doesNotWrite() {
        let previous = makeSnapshot(pendingCount: 4_000)
        let next = makeSnapshot(pendingCount: 4_001)
        XCTAssertFalse(ConduitStatusSnapshot.shouldWriteToAppGroup(
            previous: previous,
            writtenAt: Self.writeGateNow.addingTimeInterval(-60),
            next: next,
            now: Self.writeGateNow
        ))
    }

    /// The other half of that rule: coalescing must not turn into staleness.
    /// By the time the widget rebuilds, the container owes it the current
    /// counts.
    func test_shouldWrite_countOnlyChangeOnceTheRefreshIntervalHasElapsed_writes() {
        let previous = makeSnapshot(pendingCount: 4_000)
        let next = makeSnapshot(pendingCount: 4_001)
        XCTAssertTrue(ConduitStatusSnapshot.shouldWriteToAppGroup(
            previous: previous,
            writtenAt: Self.writeGateNow.addingTimeInterval(-ConduitStatusSnapshot.timelineRefreshInterval),
            next: next,
            now: Self.writeGateNow
        ))
    }

    /// A state-class change is pushed to the widget the instant it is written,
    /// so it can never wait out the interval — the reload would otherwise
    /// redraw from a container that still holds the previous state.
    func test_shouldWrite_stateClassChange_writesImmediatelyRegardlessOfInterval() {
        let previous = makeSnapshot(failedCount: 0)
        let next = makeSnapshot(failedCount: 1)
        XCTAssertTrue(ConduitStatusSnapshot.shouldReloadTimelines(previous: previous, next: next))
        XCTAssertTrue(ConduitStatusSnapshot.shouldWriteToAppGroup(
            previous: previous,
            writtenAt: Self.writeGateNow.addingTimeInterval(-1),
            next: next,
            now: Self.writeGateNow
        ))
    }

    // MARK: - AppState.importHeadline — which runs earn the widget's second line

    /// The `import_run` row is a singleton that survives until a brand-new run
    /// begins, and `secondLine` ranks the headline above the pending count. So a
    /// run the user cancelled must not produce a headline at all, or the Lock
    /// Screen reads "Import cancelled" forever and can never again surface the
    /// stuck upload queue this widget exists to expose.
    func test_importHeadline_routinePauses_doNotPinTheSecondLine() throws {
        let cases: [(ImportStopCause, String)] = [
            (.userCancelled, "Import cancelled"),
            (.backgrounded, "Import paused"),
        ]
        for (cause, settingsWording) in cases {
            let dao = ImportProgressDAO(try AppDatabase.makeInMemory())
            try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
            try dao.finishRun(status: .interrupted, autoResume: cause == .backgrounded, stopCause: cause)

            let run = try XCTUnwrap(dao.currentRun())
            XCTAssertEqual(SettingsViewModel.statusTitle(for: run), settingsWording,
                           "Settings still names it — only the Lock Screen declines to pin it")
            XCTAssertNil(AppState.importHeadline(for: run), "stopCause \(cause)")

            let snapshot = makeSnapshot(pendingCount: 7, importStatusHeadline: AppState.importHeadline(for: run))
            XCTAssertEqual(ConduitStatusSnapshot.secondLine(for: snapshot, now: Self.noon), "7 pending",
                           "stopCause \(cause)")
        }
    }

    /// The other half of the same rule: a stop that names an ongoing problem
    /// keeps its priority over the pending count.
    func test_importHeadline_actionableStopCauses_keepPriority() throws {
        let cases: [(ImportStopCause, String)] = [
            (.historyLimited, "History limited"),
            (.historyAccessUnknown, "History access unknown"),
            (.queueNotDraining, "Import paused"),
            (.endedShort, "Import interrupted"),
        ]
        for (cause, expected) in cases {
            let dao = ImportProgressDAO(try AppDatabase.makeInMemory())
            try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
            try dao.finishRun(status: .interrupted, autoResume: false, stopCause: cause)

            let run = try XCTUnwrap(dao.currentRun())
            XCTAssertEqual(AppState.importHeadline(for: run), expected, "stopCause \(cause)")

            let snapshot = makeSnapshot(pendingCount: 7, importStatusHeadline: AppState.importHeadline(for: run))
            XCTAssertEqual(ConduitStatusSnapshot.secondLine(for: snapshot, now: Self.noon), expected, "stopCause \(cause)")
        }
    }

    /// A row written before `stop_cause` existed carries `nil`, which is not
    /// evidence the stop was routine — the conservative reading keeps the
    /// headline rather than silently hiding a real problem.
    func test_importHeadline_interruptedWithNoRecordedCause_keepsPriority() throws {
        let dao = ImportProgressDAO(try AppDatabase.makeInMemory())
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.finishRun(status: .interrupted, autoResume: false, stopCause: nil)

        let run = try XCTUnwrap(dao.currentRun())
        XCTAssertNil(run.stopCause)
        XCTAssertEqual(AppState.importHeadline(for: run), "Import interrupted")
    }

    func test_importHeadline_failedRun_keepsPriority() throws {
        let dao = ImportProgressDAO(try AppDatabase.makeInMemory())
        try dao.beginRun(runId: "r1", rangeId: ImportRange.allTime.rawValue, rangeStart: nil, typesTotal: 1)
        try dao.finishRun(status: .failed, failureReason: "boom")

        XCTAssertEqual(AppState.importHeadline(for: try XCTUnwrap(dao.currentRun())), "Import failed")
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

    // MARK: - Home's own staged-today day check

    /// Home reads the same day-bucketed tally the widget does, from a snapshot
    /// only recomputed on a tracked write — so a clock crossing midnight leaves
    /// it describing yesterday. Monday's last staging write, read on Tuesday,
    /// must not render under a "today" label.
    func test_homeStatusSnapshot_stagedTodayIsZeroOnceTheDayHasTurned() {
        let snapshot = HomeViewModel.StatusSnapshot(
            pending: 0,
            failed: 0,
            today: 1_204,
            todayStart: Calendar.current.startOfDay(for: Self.noon),
            lastSynced: nil,
            status: .idle
        )

        XCTAssertEqual(snapshot.stagedToday(asOf: Self.noon), 1_204)
        XCTAssertEqual(snapshot.stagedToday(asOf: Self.nextDayNoon), 0)
    }

    // MARK: - The single shared status observation

    /// Home renders `AppState.status`, republished by the one observation this
    /// app runs over the outbox/staged/sync tables. That is the behavior the
    /// duplicate-observation removal had to preserve: a write must still reach
    /// the screen's public surface even though `HomeViewModel` no longer opens
    /// an observation, and no longer has a `start()` to call.
    @MainActor
    func test_homeViewModel_reflectsWritesThroughTheSharedObservation() async throws {
        let database = try AppDatabase.makeInMemory()
        let appState = AppState(database: database)
        let viewModel = HomeViewModel(appState: appState)

        let syncedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await database.dbWriter.write { db in
            try SyncStateDAO.setLastSyncedAt(db, syncedAt)
            try StagedDailyCountDAO.increment(db, enqueuedAt: Date(), by: 42)
        }

        try await Self.waitUntil("Home sees the staged tally") { await viewModel.stagedTodayCount == 42 }

        XCTAssertEqual(viewModel.syncStatus, .synced(syncedAt))
        XCTAssertFalse(viewModel.statusIsError)
        XCTAssertEqual(viewModel.syncStatusLabel.hasPrefix("Synced"), true, viewModel.syncStatusLabel)
        XCTAssertEqual(viewModel.pendingCount, 0)
        XCTAssertEqual(viewModel.failedCount, 0)
    }

    /// GRDB cancels a `ValueObservation` the moment it hands an error to
    /// `onError`, and this is the only observation the app runs over these
    /// tables — so a single failed fetch used to freeze `AppState.status`, and
    /// with it the App Group snapshot the Lock Screen renders, for the rest of
    /// the process. An `import_run` row carrying a status string this build
    /// does not know (a rollback past a build that added an enum case, a
    /// partially-applied migration) is the reachable form of that: it makes
    /// the observation's `ImportRunState.fetchOne` throw.
    @MainActor
    func test_statusObservation_restartsAfterAFailedFetch() async throws {
        let database = try AppDatabase.makeInMemory()
        let appState = AppState(database: database)
        let viewModel = HomeViewModel(appState: appState)

        try ImportProgressDAO(database).beginRun(
            runId: "r1",
            rangeId: ImportRange.allTime.rawValue,
            rangeStart: nil,
            typesTotal: 1
        )
        try await database.dbWriter.write { db in
            try StagedDailyCountDAO.increment(db, enqueuedAt: Date(), by: 1)
        }
        try await Self.waitUntil("the observation is live") { await viewModel.stagedTodayCount == 1 }

        try await database.dbWriter.write { db in
            try db.execute(sql: "UPDATE import_run SET status = 'a-case-this-build-does-not-know'")
        }
        try await Self.waitUntil("the fetch fails and the observation is cancelled") {
            await appState.statusObservationFailures >= 1
        }

        try await database.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE import_run SET status = ?",
                arguments: [ImportRunStatus.completed.rawValue]
            )
            try StagedDailyCountDAO.increment(db, enqueuedAt: Date(), by: 41)
        }

        try await Self.waitUntil("the restarted observation delivers again") {
            await viewModel.stagedTodayCount == 42
        }
        XCTAssertEqual(appState.statusObservationFailures, 0,
                       "a delivered value must put the backoff back at the bottom")
    }

    /// The bound that keeps a permanently-failing fetch from spinning the
    /// writer queue. It caps rather than gives up: a cause that clears an hour
    /// later still gets picked back up, which a spent attempt budget could not
    /// do.
    func test_statusObservationRetryDelay_doublesThenCaps() {
        XCTAssertEqual(AppState.statusObservationRetryDelay(consecutiveFailures: 1), 1)
        XCTAssertEqual(AppState.statusObservationRetryDelay(consecutiveFailures: 2), 2)
        XCTAssertEqual(AppState.statusObservationRetryDelay(consecutiveFailures: 5), 16)
        XCTAssertEqual(
            AppState.statusObservationRetryDelay(consecutiveFailures: 1_000),
            AppState.statusObservationRetryCeiling
        )
    }

    /// The observation delivers asynchronously (deliberately — the initial read
    /// stays off the main thread), so poll rather than assume a fixed delay.
    private static func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for: \(what)")
    }
}
