import GRDB
import os
import SwiftUI
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

    // MARK: - coarseAge — never finer than a minute

    func test_coarseAge_neverReportsSeconds() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ConduitStatusSnapshot.coarseAge(from: t, to: t.addingTimeInterval(45)), "less than a minute")
        XCTAssertEqual(ConduitStatusSnapshot.coarseAge(from: t, to: t.addingTimeInterval(125)), "2 min")
        XCTAssertEqual(ConduitStatusSnapshot.coarseAge(from: t, to: t.addingTimeInterval(3 * 3600 + 500)), "3 hr")
        XCTAssertEqual(ConduitStatusSnapshot.coarseAge(from: t, to: t.addingTimeInterval(-30)), "less than a minute")
    }

    // MARK: - timelineEntryDates — 5-minute entries plus the midnight boundary

    /// The spacing invariant WidgetKit asks for: consecutive entries at least
    /// 5 minutes apart, except `now` itself when midnight is closer than that.
    private func assertEntrySpacing(_ dates: [Date], from now: Date, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(dates, dates.sorted(), "entries must be in order", file: file, line: line)
        for (earlier, later) in zip(dates, dates.dropFirst()) where earlier != now {
            XCTAssertGreaterThanOrEqual(
                later.timeIntervalSince(earlier), ConduitStatusSnapshot.timelineEntrySpacing,
                "\(earlier) → \(later)", file: file, line: line
            )
        }
    }

    /// iOS 17 renders a static age against the entry date, so a timeline of
    /// `[now, midnight]` froze the age at the rebuild for the rest of the hour
    /// — under-reporting staleness on a reliability surface. The regular
    /// entries must cover the whole refresh interval, 5 minutes apart.
    func test_timelineEntryDates_coverTheRefreshIntervalInFiveMinuteSteps() {
        let now = Self.noon
        let dates = ConduitStatusSnapshot.timelineEntryDates(from: now)

        XCTAssertEqual(ConduitStatusSnapshot.timelineEntrySpacing, 5 * 60)
        let regular = dates.filter { $0 <= now.addingTimeInterval(ConduitStatusSnapshot.timelineRefreshInterval) }
        XCTAssertEqual(regular, (0...12).map { now.addingTimeInterval(Double($0) * 5 * 60) })
        assertEntrySpacing(dates, from: now)
    }

    /// What the 5-minute entries buy on iOS 17: the static age rendered
    /// against each entry advances between rebuilds instead of freezing.
    func test_timelineEntryDates_advanceTheIOS17StaticAgeBetweenRebuilds() {
        let lastSyncedAt = Self.noon.addingTimeInterval(-60)
        let ages = ConduitStatusSnapshot.timelineEntryDates(from: Self.noon)
            .prefix(4)
            .map { ConduitStatusSnapshot.coarseAge(from: lastSyncedAt, to: $0) }

        XCTAssertEqual(ages, ["1 min", "6 min", "11 min", "16 min"])
    }

    /// A timeline renders its last entry until the next rebuild, so without a
    /// boundary entry the widget keeps yesterday's tally on screen past
    /// midnight. When midnight falls inside the window it must be an entry of
    /// its own, still at least 5 minutes from its neighbours.
    func test_timelineEntryDates_carriesTheMidnightBoundaryWhenItIsImminent() {
        let midnight = Calendar.current.startOfDay(for: Self.nextDayNoon)
        for minutesToMidnight in [2.0, 7.0, 10.0, 33.5] {
            let now = midnight.addingTimeInterval(-minutesToMidnight * 60)
            let dates = ConduitStatusSnapshot.timelineEntryDates(from: now)

            XCTAssertEqual(dates.first, now, "\(minutesToMidnight) min to midnight")
            XCTAssertEqual(dates.filter { $0 == midnight }.count, 1, "\(minutesToMidnight) min to midnight")
            assertEntrySpacing(dates, from: now)
        }
    }

    /// The boundary cannot be conditional on midnight falling inside one
    /// refresh interval: WidgetKit treats the refresh policy as a hint, not a
    /// promise (Low Power Mode suspends refreshes outright), so a timeline
    /// built at noon and never rebuilt must still flip the tally at midnight
    /// rather than render "Staged today 1204" on a day nothing was staged.
    func test_timelineEntryDates_carriesTheMidnightBoundaryEvenWhenItIsHoursAway() {
        let now = Self.noon
        let midnight = Calendar.current.startOfDay(for: Self.nextDayNoon)
        let dates = ConduitStatusSnapshot.timelineEntryDates(from: now)

        XCTAssertEqual(dates.last, midnight)
        XCTAssertEqual(dates.filter { $0 == midnight }.count, 1)
        assertEntrySpacing(dates, from: now)
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

    /// A bare stamp or staged-count change is not a state *class* change —
    /// whether a new stamp earns a reload is `reloadDecision`'s rule, below.
    func test_shouldReload_timestampOrStagedCountOnlyChange_isNotAClassChange() {
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

    // MARK: - reloadDecision — the one reload rule

    private static let reloadNow = Date(timeIntervalSince1970: 1_700_000_000)
    private static let reloadedStamp = Date(timeIntervalSince1970: 1_699_990_000)
    private static let newStamp = Date(timeIntervalSince1970: 1_699_999_000)

    private func reloadDecision(
        previous: ConduitStatusSnapshot? = nil,
        next: ConduitStatusSnapshot,
        lastReloadAgo: TimeInterval?,
        lastReloadedStamp: Date? = ConduitStatusSnapshotTests.reloadedStamp,
        isForeground: Bool
    ) -> Bool {
        ConduitStatusSnapshot.reloadDecision(
            previous: previous ?? makeSnapshot(lastSyncedAt: Self.reloadedStamp),
            next: next,
            lastReloadAt: lastReloadAgo.map { Self.reloadNow.addingTimeInterval(-$0) },
            lastReloadedStamp: lastReloadedStamp,
            isForeground: isForeground,
            now: Self.reloadNow
        )
    }

    /// The captain's bug: the widget's age is anchored to the stamp its
    /// timeline was built with, and a stamp-only change never asked for a
    /// rebuild — so the Lock Screen kept counting from the previous sync.
    /// In the foreground a reload is budget-exempt, so every new stamp gets
    /// one, however recently the last was requested.
    func test_reloadDecision_stampChangeInTheForeground_alwaysReloads() {
        XCTAssertTrue(reloadDecision(next: makeSnapshot(lastSyncedAt: Self.newStamp), lastReloadAgo: 1, isForeground: true))
        XCTAssertTrue(reloadDecision(next: makeSnapshot(lastSyncedAt: Self.newStamp), lastReloadAgo: nil, isForeground: true))
    }

    /// In the background every reload is budgeted, and a stamp can land on
    /// every wake, so they coalesce behind the 15-minute floor.
    func test_reloadDecision_stampChangeInTheBackgroundInsideTheFloor_doesNotReload() {
        XCTAssertEqual(ConduitStatusSnapshot.widgetReloadFloor, 15 * 60)
        XCTAssertFalse(reloadDecision(
            next: makeSnapshot(lastSyncedAt: Self.newStamp),
            lastReloadAgo: ConduitStatusSnapshot.widgetReloadFloor - 1,
            isForeground: false
        ))
    }

    func test_reloadDecision_stampChangeInTheBackgroundPastTheFloor_reloads() {
        XCTAssertTrue(reloadDecision(
            next: makeSnapshot(lastSyncedAt: Self.newStamp),
            lastReloadAgo: ConduitStatusSnapshot.widgetReloadFloor,
            isForeground: false
        ))
    }

    /// No record of an earlier reload (a fresh install, or the first launch
    /// of this build) is not a reason to withhold one.
    func test_reloadDecision_stampChangeInTheBackgroundWithNoRecord_reloads() {
        XCTAssertTrue(reloadDecision(
            next: makeSnapshot(lastSyncedAt: Self.newStamp),
            lastReloadAgo: nil,
            lastReloadedStamp: nil,
            isForeground: false
        ))
    }

    /// A stamp the floor withheld is already in the container, so `previous`
    /// equals `next` by the next wake. It is compared against the stamp the
    /// last reload carried, or it would never be reloaded at all.
    func test_reloadDecision_stampTheFloorWithheld_reloadsOncePastTheFloorEvenThoughTheContainerHoldsIt() {
        let withheld = makeSnapshot(lastSyncedAt: Self.newStamp)
        XCTAssertFalse(reloadDecision(previous: withheld, next: withheld, lastReloadAgo: 60, isForeground: false))
        XCTAssertTrue(reloadDecision(
            previous: withheld, next: withheld,
            lastReloadAgo: ConduitStatusSnapshot.widgetReloadFloor + 60,
            isForeground: false
        ))
    }

    /// The stamp the last reload carried comes back from the App Group's JSON,
    /// which can move it by an ulp from what `sync_state` reads. That is the
    /// same stamp, not a new one worth a reload.
    func test_reloadDecision_sameStampAfterAJSONRoundTrip_doesNotReload() throws {
        let stamp = Date(timeIntervalSince1970: 1_758_724_429.123)
        let roundTripped = try XCTUnwrap(
            try ConduitStatusSnapshot.decoded(from: makeSnapshot(lastSyncedAt: stamp).encoded()).lastSyncedAt
        )
        for drift in [0, 1e-7, -1e-7] {
            XCTAssertFalse(reloadDecision(
                previous: makeSnapshot(lastSyncedAt: stamp),
                next: makeSnapshot(lastSyncedAt: stamp),
                lastReloadAgo: 10 * 3_600,
                lastReloadedStamp: roundTripped.addingTimeInterval(drift),
                isForeground: true
            ), "drift \(drift)")
        }
        XCTAssertTrue(reloadDecision(
            next: makeSnapshot(lastSyncedAt: stamp.addingTimeInterval(0.001)),
            lastReloadAgo: 10 * 3_600,
            lastReloadedStamp: roundTripped,
            isForeground: true
        ), "a stamp one millisecond later is a new sync")
    }

    /// A clock set back before the last request must not freeze the widget
    /// until the clock catches up again.
    func test_reloadDecision_clockSetBackBeforeTheLastReload_reloads() {
        XCTAssertTrue(reloadDecision(next: makeSnapshot(lastSyncedAt: Self.newStamp), lastReloadAgo: -3_600, isForeground: false))
    }

    /// A state-class change is pushed at once wherever it lands, even for the
    /// stamp the widget already has and inside the floor.
    func test_reloadDecision_classChange_alwaysReloads() {
        let previous = makeSnapshot(lastSyncedAt: Self.reloadedStamp, failedCount: 0)
        let next = makeSnapshot(lastSyncedAt: Self.reloadedStamp, failedCount: 1)
        XCTAssertTrue(reloadDecision(previous: previous, next: next, lastReloadAgo: 1, isForeground: false))
        XCTAssertTrue(reloadDecision(previous: previous, next: next, lastReloadAgo: 1, isForeground: true))
        XCTAssertTrue(ConduitStatusSnapshot.reloadDecision(
            previous: nil, next: next, lastReloadAt: Self.reloadNow, lastReloadedStamp: Self.reloadedStamp,
            isForeground: false, now: Self.reloadNow
        ), "a first-ever snapshot always reloads")
    }

    /// Nothing the widget shows has changed: never a reload, in any phase.
    func test_reloadDecision_unchangedSnapshot_neverReloads() {
        let snapshot = makeSnapshot(lastSyncedAt: Self.reloadedStamp, pendingCount: 3)
        for isForeground in [true, false] {
            XCTAssertFalse(
                reloadDecision(previous: snapshot, next: snapshot, lastReloadAgo: 10 * 3_600, isForeground: isForeground),
                "isForeground \(isForeground)"
            )
        }
    }

    /// A count moving under the same stamp is left to the hourly self-refresh,
    /// in the foreground too — the ~10^4 deliveries of an import must not each
    /// spend a reload when only the pending count moved.
    func test_reloadDecision_countOnlyChange_doesNotReload() {
        let previous = makeSnapshot(lastSyncedAt: Self.reloadedStamp, pendingCount: 4_000)
        let next = makeSnapshot(lastSyncedAt: Self.reloadedStamp, pendingCount: 4_001)
        for isForeground in [true, false] {
            XCTAssertFalse(
                reloadDecision(previous: previous, next: next, lastReloadAgo: 10 * 3_600, isForeground: isForeground),
                "isForeground \(isForeground)"
            )
        }
    }

    // MARK: - timelineRefreshDate — the follow-up rebuild at floor expiry

    /// Quiet periods keep the hourly baseline.
    func test_timelineRefreshDate_noRecentReload_isHourly() {
        let now = Self.reloadNow
        let hourly = now.addingTimeInterval(ConduitStatusSnapshot.timelineRefreshInterval)
        XCTAssertEqual(ConduitStatusSnapshot.timelineRefreshDate(from: now, lastReloadRequestAt: nil), hourly)
        XCTAssertEqual(ConduitStatusSnapshot.timelineRefreshDate(
            from: now, lastReloadRequestAt: now.addingTimeInterval(-ConduitStatusSnapshot.widgetReloadFloor)
        ), hourly, "a rebuild at (or after) floor expiry is the follow-up itself, and gets no other")
        XCTAssertEqual(ConduitStatusSnapshot.timelineRefreshDate(
            from: now, lastReloadRequestAt: now.addingTimeInterval(-2 * 3_600)
        ), hourly)
    }

    /// A timeline built inside the background floor's window rebuilds when
    /// the window closes, so a stamp the floor withheld in it is picked up
    /// even if no further wake ever requests it.
    func test_timelineRefreshDate_insideTheFloorWindow_rebuildsAtFloorExpiry() {
        let requestedAt = Self.reloadNow
        for elapsed: TimeInterval in [0, 1, 5 * 60, ConduitStatusSnapshot.widgetReloadFloor - 1] {
            XCTAssertEqual(
                ConduitStatusSnapshot.timelineRefreshDate(
                    from: requestedAt.addingTimeInterval(elapsed), lastReloadRequestAt: requestedAt
                ),
                requestedAt.addingTimeInterval(ConduitStatusSnapshot.widgetReloadFloor),
                "\(elapsed) s after the request"
            )
        }
    }

    /// A request dated after `now` (a clock set back) is not trusted to
    /// schedule anything — beyond the ulp a JSON round-trip can add.
    func test_timelineRefreshDate_requestInTheFuture_isHourly() {
        let now = Self.reloadNow
        XCTAssertEqual(
            ConduitStatusSnapshot.timelineRefreshDate(from: now, lastReloadRequestAt: now.addingTimeInterval(1e-6)),
            now.addingTimeInterval(1e-6 + ConduitStatusSnapshot.widgetReloadFloor),
            "an ulp of round-trip drift is still the request that was just made"
        )
        XCTAssertEqual(
            ConduitStatusSnapshot.timelineRefreshDate(from: now, lastReloadRequestAt: now.addingTimeInterval(600)),
            now.addingTimeInterval(ConduitStatusSnapshot.timelineRefreshInterval)
        )
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

    /// A background wake's completion hook calls `flushStatusSnapshot` as soon
    /// as its last write returns — before GRDB has delivered that write's value
    /// to `onChange` on the main queue. Off screen that delivery is a probe
    /// carrying the old counts, so the flush is the only thing that can get the
    /// new pending count into the container before iOS suspends the app; it
    /// must not decide "nothing to flush" just because the delivery has not
    /// landed yet. Runs on the main actor so the delivery genuinely cannot land
    /// before the flush is enqueued.
    @MainActor
    func test_flushStatusSnapshot_recountsAWriteWhoseDeliveryHasNotLandedYet() async throws {
        let sentinel = makeSnapshot(pendingCount: 999)
        try sentinel.writeToAppGroup()

        let database = try AppDatabase.makeInMemory()
        var webhook = WebhookConfig.makeDefault(url: "https://example.com", bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(database).save(&webhook)
        let webhookID = try XCTUnwrap(webhook.id)
        let appState = AppState(database: database)

        try await Self.waitUntil("the first full fetch is written") {
            ConduitStatusSnapshot.readFromAppGroup()?.pendingCount == 0
        }
        await appState.flushStatusSnapshot()

        // The synchronous DAO call, so the main actor is never given up
        // between the committing writes and the flush below.
        for index in 0..<5 {
            var sample = Conduit_V1_Sample()
            sample.uuid = "flush-\(index)"
            sample.startUnixMs = 1_700_000_000_000
            sample.endUnixMs = 1_700_000_060_000
            _ = try OutboxDAO(database).enqueue(
                sample: sample, hkTypeId: "HKQuantityTypeIdentifierHeartRate", webhookId: webhookID
            )
        }
        await appState.flushStatusSnapshot()

        XCTAssertEqual(ConduitStatusSnapshot.readFromAppGroup()?.pendingCount, 5,
                       "the wake's flush must recount the write it follows, not wait for its delivery")
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

/// A completed background delivery commits on the URLSession delegate's queue,
/// after the wake that started the upload has ended. The stamp and pending
/// purge must still reach the widget's container without waiting for another
/// wake. The fixture starts from a two-hour-old stamp (steady state): from a
/// never-synced state the first sync is a state-class change that writes
/// immediately, which passes with or without the fix.
final class WidgetDeliveryFlushTests: XCTestCase {
    private let oldStamp = Date().addingTimeInterval(-2 * 3600)

    override func tearDown() {
        Uploader.shared.database = nil
        Uploader.shared.backgroundCompletionHandler = nil
        Uploader.shared.onDeliveryCommitted = nil
        super.tearDown()
    }

    private func makeFixture() throws -> (AppDatabase, Int64) {
        let database = try AppDatabase.makeInMemory()
        var webhook = WebhookConfig.makeDefault(url: "https://example.com", bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(database).save(&webhook)
        let stamp = oldStamp
        try database.dbWriter.write { try SyncStateDAO.setLastSyncedAt($0, stamp) }
        return (database, try XCTUnwrap(webhook.id))
    }

    private func stage(_ count: Int, database: AppDatabase, webhookID: Int64) throws {
        for index in 0..<count {
            var sample = Conduit_V1_Sample()
            sample.uuid = "delivery-\(index)"
            sample.startUnixMs = 1_700_000_000_000
            sample.endUnixMs = 1_700_000_060_000
            _ = try OutboxDAO(database).enqueue(
                sample: sample, hkTypeId: "HKQuantityTypeIdentifierHeartRate", webhookId: webhookID
            )
        }
    }

    private func waitUntil(_ what: String, _ condition: @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for: \(what)")
    }

    @MainActor
    func test_backgroundDeliveryCompletionReachesContainerWithoutAnotherWake() async throws {
        let (database, webhookID) = try makeFixture()
        let appState = AppState(database: database)     // not foreground, as on a background launch
        Uploader.shared.database = database
        try await waitUntil("the first full fetch is written") {
            ConduitStatusSnapshot.readFromAppGroup()?.pendingCount == 0
        }

        try stage(5, database: database, webhookID: webhookID)
        let batch = try XCTUnwrap(Batcher(database: database).buildBatch(webhookID: webhookID, limit: 500, deviceID: "dev"))
        await appState.flushStatusSnapshot()            // the wake's own flush: old stamp, 5 pending
        XCTAssertEqual(ConduitStatusSnapshot.readFromAppGroup()?.pendingCount, 5)

        // The delivery lands after the wake, on the session's private delegate queue.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                Uploader.shared.markSent(batchID: batch.batchID, httpStatus: 200, accepted: 5, deduped: 0)
                done.resume()
            }
        }
        await Uploader.shared.awaitDeliveryFlushes()

        let container = try XCTUnwrap(ConduitStatusSnapshot.readFromAppGroup())
        XCTAssertEqual(container.pendingCount, 0, "the delivered batch must not stay pending in the container")
        XCTAssertGreaterThan(
            try XCTUnwrap(container.lastSyncedAt), oldStamp.addingTimeInterval(60),
            "the container must carry this delivery's stamp, not the previous one's"
        )
    }

    @MainActor
    func test_backgroundSessionCompletionHandlerWaitsForTheDeliveryFlush() async throws {
        let (database, _) = try makeFixture()
        _ = AppState(database: database)
        Uploader.shared.database = database
        let flushFinished = OSAllocatedUnfairLock(initialState: false)
        Uploader.shared.onDeliveryCommitted = {
            try? await Task.sleep(nanoseconds: 300_000_000)
            flushFinished.withLock { $0 = true }
        }
        let handlerSawFlush = expectation(description: "completion handler called")
        Uploader.shared.backgroundCompletionHandler = {
            XCTAssertTrue(flushFinished.withLock { $0 }, "iOS must not be told we are done before the flush lands")
            handlerSawFlush.fulfill()
        }

        Uploader.shared.markSent(batchID: "none", httpStatus: 200, accepted: 0, deduped: 0)
        Uploader.shared.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        await fulfillment(of: [handlerSawFlush], timeout: 5)
    }
}

/// The Lock Screen's "last synced" age is anchored to the stamp its timeline
/// was built with, and the widget re-reads the App Group container only when
/// WidgetKit rebuilds that timeline. These drive the real `AppState` — its
/// observation, flushes and `Uploader` delivery hook — with the reload seam
/// injected, and stand in for WidgetKit by reading the container at the
/// moment a reload is requested, exactly as `getTimeline` would.
///
/// Every fixture starts from a two-hour-old stamp that the container and the
/// reload record already agree on (steady state), so the only reload a test
/// can see is the one its own stamp change earns.
final class WidgetReloadOnSyncTests: XCTestCase {
    private let oldStamp = WidgetReloadOnSyncTests.wholeSecond(Date().addingTimeInterval(-2 * 3600))

    /// `sync_state` stores dates to the millisecond, so a stamp a test writes
    /// and later compares against what the observation read back is whole.
    private static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// The rebuilds WidgetKit would have run: the container as each one read
    /// it, and when that timeline asked to be rebuilt next — both exactly as
    /// `ConduitStatusProvider.getTimeline` computes them.
    private final class ReloadSpy: @unchecked Sendable {
        private let reads = OSAllocatedUnfairLock<[(snapshot: ConduitStatusSnapshot?, refreshAt: Date)]>(initialState: [])
        var rebuilds: [ConduitStatusSnapshot?] { reads.withLock { $0.map(\.snapshot) } }
        var refreshDates: [Date] { reads.withLock { $0.map(\.refreshAt) } }
        var count: Int { rebuilds.count }
        func reload(at now: Date) {
            let rebuild = WidgetReloadOnSyncTests.rebuild(at: now)
            reads.withLock { $0.append(rebuild) }
        }
    }

    /// One `getTimeline` run: the container it reads and its refresh date.
    private static func rebuild(at now: Date) -> (snapshot: ConduitStatusSnapshot?, refreshAt: Date) {
        (
            ConduitStatusSnapshot.readFromAppGroup(),
            ConduitStatusSnapshot.timelineRefreshDate(
                from: now, lastReloadRequestAt: WidgetReloadRecord.readFromAppGroup()?.requestedAt
            )
        )
    }

    /// A clock the test can move forward: the reload floor is measured on it.
    private final class Clock: @unchecked Sendable {
        private let current = OSAllocatedUnfairLock(initialState: Date())
        var now: Date { current.withLock { $0 } }
        func advance(by interval: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(interval) } }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The container-dependent assertions below must run, not skip: the
        // unsigned test host falls back to a temp container (DEBUG + XCTest).
        _ = try XCTUnwrap(ConduitStatusSnapshot.appGroupFileURL("probe"), "no App Group container, not even the test fallback")
        WidgetReloadRecord.removeFromAppGroup()
    }

    override func tearDown() {
        WidgetReloadRecord.removeFromAppGroup()
        Uploader.shared.database = nil
        Uploader.shared.backgroundCompletionHandler = nil
        Uploader.shared.onDeliveryCommitted = nil
        super.tearDown()
    }

    /// A database two hours past its last sync, and a container plus reload
    /// record that already reflect it: what a real device looks like between
    /// syncs, and what a fresh background process seeds itself from.
    private func makeFixture(clock: Clock, lastReloadAgo: TimeInterval = 2 * 3600) throws -> (AppDatabase, Int64) {
        let database = try AppDatabase.makeInMemory()
        var webhook = WebhookConfig.makeDefault(url: "https://example.com", bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(database).save(&webhook)
        let stamp = oldStamp
        try database.dbWriter.write { try SyncStateDAO.setLastSyncedAt($0, stamp) }
        let snapshot = try database.dbWriter.read { db in
            AppState.widgetSnapshot(from: try HomeViewModel.fetchStatus(db), importHeadline: nil)
        }
        assertSameStamp(snapshot.lastSyncedAt, stamp)
        try snapshot.writeToAppGroup()
        try WidgetReloadRecord(requestedAt: clock.now.addingTimeInterval(-lastReloadAgo), lastSyncedAt: stamp)
            .writeToAppGroup()
        return (database, try XCTUnwrap(webhook.id))
    }

    private func stage(_ count: Int, database: AppDatabase, webhookID: Int64) throws {
        for index in 0..<count {
            var sample = Conduit_V1_Sample()
            sample.uuid = "reload-\(index)"
            sample.startUnixMs = 1_700_000_000_000
            sample.endUnixMs = 1_700_000_060_000
            _ = try OutboxDAO(database).enqueue(
                sample: sample, hkTypeId: "HKQuantityTypeIdentifierHeartRate", webhookId: webhookID
            )
        }
    }

    private func makeAppState(_ database: AppDatabase, spy: ReloadSpy, clock: Clock) -> AppState {
        AppState(database: database, reloadTimelines: { spy.reload(at: clock.now) }, now: { clock.now })
    }

    /// Waits for the observation's first value to be published and handed to
    /// the snapshot queue, then drains that queue with a flush.
    @MainActor
    private func settle(_ appState: AppState, stamp: Date) async throws {
        try await waitUntil("the observation publishes the stamp") { await appState.status.lastSynced == stamp }
        await appState.flushStatusSnapshot()
    }

    /// Stamps compared the way `reloadDecision` compares them: a JSON
    /// round-trip through the container can move one by an ulp.
    private func assertSameStamp(_ lhs: Date?, _ rhs: Date?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ConduitStatusSnapshot.isSameStamp(lhs, rhs), "\(String(describing: lhs)) vs \(String(describing: rhs)) \(message)", file: file, line: line)
    }

    private func lastSyncedAt(in database: AppDatabase) throws -> Date? {
        try database.dbWriter.read { try SyncStateDAO.lastSyncedAt($0) }
    }

    private func waitUntil(_ what: String, _ condition: @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for: \(what)")
    }

    @available(iOS 18, *)
    private func ageText(for stamp: Date, at now: Date) -> String {
        String(ConduitStatusSnapshot.liveAgeFormat(for: stamp).locale(Locale(identifier: "en_US")).format(now).characters)
    }

    /// The captain's report, end to end: a background delivery commits on the
    /// URLSession delegate's queue after its wake ended. PR 7 already got the
    /// new stamp into the container; the widget kept showing the old one
    /// because nothing asked WidgetKit to rebuild. Now the delivery's flush
    /// requests a reload (past the floor), the rebuild reads this delivery's
    /// stamp, and the age reads "1 minute ago" a minute later instead of
    /// counting from the previous sync.
    ///
    /// Then a second process a minute later — a background launch starts
    /// fresh — must not spend another budgeted reload on the same stamp; that
    /// needs the reload bookkeeping persisted, not held in memory.
    @MainActor
    func test_backgroundDelivery_reloadsWithItsStamp_andTheNextProcessDoesNotReloadItAgain() async throws {
        let clock = Clock()
        let (database, webhookID) = try makeFixture(clock: clock)
        let spy = ReloadSpy()
        var appState: AppState? = makeAppState(database, spy: spy, clock: clock)   // not foreground: a background launch
        Uploader.shared.database = database
        try await settle(try XCTUnwrap(appState), stamp: oldStamp)
        XCTAssertEqual(spy.count, 0, "the steady state the widget already shows earns no reload")

        try stage(5, database: database, webhookID: webhookID)
        let batch = try XCTUnwrap(Batcher(database: database).buildBatch(webhookID: webhookID, limit: 500, deviceID: "dev"))
        await appState?.flushStatusSnapshot()
        XCTAssertEqual(spy.count, 0, "a pending count under the same stamp waits for the hourly self-refresh")

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                Uploader.shared.markSent(batchID: batch.batchID, httpStatus: 200, accepted: 5, deduped: 0)
                done.resume()
            }
        }
        await Uploader.shared.awaitDeliveryFlushes()

        let deliveredStamp = try XCTUnwrap(try lastSyncedAt(in: database))
        XCTAssertGreaterThan(deliveredStamp, oldStamp.addingTimeInterval(60))
        let container = try XCTUnwrap(ConduitStatusSnapshot.readFromAppGroup())
        assertSameStamp(container.lastSyncedAt, deliveredStamp)
        XCTAssertEqual(spy.count, 1, "the delivery's stamp must reach the widget with a rebuild")
        let rebuild = try XCTUnwrap(spy.rebuilds.last ?? nil, "the rebuild must find a snapshot in the container")
        assertSameStamp(rebuild.lastSyncedAt, deliveredStamp, "the rebuild must read this delivery's stamp, not the previous one's")
        XCTAssertEqual(rebuild.pendingCount, 0)
        assertSameStamp(WidgetReloadRecord.readFromAppGroup()?.lastSyncedAt, deliveredStamp)

        // What the widget renders from that rebuild, one minute later.
        let entryStamp = try XCTUnwrap(rebuild.lastSyncedAt)
        let oneMinuteLater = entryStamp.addingTimeInterval(60)
        if #available(iOS 18, *) {
            XCTAssertEqual(ageText(for: entryStamp, at: oneMinuteLater), "1 minute ago")
            XCTAssertEqual(ageText(for: oldStamp, at: oneMinuteLater), "2 hours ago",
                           "the pre-fix widget, anchored to the previous stamp")
        }
        XCTAssertEqual(ConduitStatusSnapshot.coarseAge(from: entryStamp, to: oneMinuteLater), "1 min",
                       "the iOS 17 static age from the same rebuild")

        // A fresh process one minute later, for the same stamp.
        appState = nil
        clock.advance(by: 60)
        let nextSpy = ReloadSpy()
        let nextProcess = makeAppState(database, spy: nextSpy, clock: clock)
        Uploader.shared.database = database
        try await settle(nextProcess, stamp: deliveredStamp)
        await nextProcess.flushStatusSnapshot()
        XCTAssertEqual(nextSpy.count, 0, "the stamp the last process already reloaded must not be reloaded again")

        // A new stamp inside the floor (an observer wake that drained nothing)
        // is written but withheld...
        let wakeStamp = Self.wholeSecond(deliveredStamp).addingTimeInterval(60)
        try await database.dbWriter.write { try SyncStateDAO.setLastSyncedAt($0, wakeStamp) }
        try await settle(nextProcess, stamp: wakeStamp)
        assertSameStamp(ConduitStatusSnapshot.readFromAppGroup()?.lastSyncedAt, wakeStamp)
        XCTAssertEqual(nextSpy.count, 0, "inside the floor a background stamp waits")

        // ...and must not be left without a rebuild once the floor has passed,
        // even though no new fetch comes along to carry it.
        clock.advance(by: ConduitStatusSnapshot.widgetReloadFloor)
        await nextProcess.flushStatusSnapshot()
        XCTAssertEqual(nextSpy.count, 1)
        assertSameStamp(nextSpy.rebuilds.last??.lastSyncedAt, wakeStamp)
    }

    /// The case the floor alone leaves open: a background stamp lands inside
    /// the floor window and nothing wakes the app again. The stamp is in the
    /// container (the wake's flush wrote it) but no reload asks for it — so
    /// the rebuild the last reload triggered must itself have scheduled the
    /// follow-up for floor expiry, and that follow-up reads the stamp. It
    /// buys no further one: quiet periods go back to hourly.
    @MainActor
    func test_stampWithheldByTheFloor_isCoveredByAFollowUpRebuildAtFloorExpiry_withNoFurtherWake() async throws {
        let clock = Clock()
        let (database, _) = try makeFixture(clock: clock)
        let spy = ReloadSpy()
        let appState = makeAppState(database, spy: spy, clock: clock)
        try await settle(appState, stamp: oldStamp)

        let reloaded = Self.wholeSecond(Date())
        try await database.dbWriter.write { try SyncStateDAO.setLastSyncedAt($0, reloaded) }
        try await settle(appState, stamp: reloaded)
        XCTAssertEqual(spy.count, 1, "past the floor, the first background stamp is reloaded")
        let reloadAt = clock.now
        let followUpAt = try XCTUnwrap(spy.refreshDates.last)
        XCTAssertLessThanOrEqual(followUpAt, reloadAt.addingTimeInterval(ConduitStatusSnapshot.widgetReloadFloor),
                                 "the rebuild must ask to be rebuilt no later than floor expiry")

        clock.advance(by: 5 * 60)
        let withheld = reloaded.addingTimeInterval(5 * 60)
        try await database.dbWriter.write { try SyncStateDAO.setLastSyncedAt($0, withheld) }
        try await settle(appState, stamp: withheld)
        XCTAssertEqual(spy.count, 1, "inside the floor a background stamp waits")
        assertSameStamp(ConduitStatusSnapshot.readFromAppGroup()?.lastSyncedAt, withheld,
                        "the wake's flush must still leave it in the container")

        // No further delivery or wake. WidgetKit runs the follow-up it was asked for.
        XCTAssertGreaterThan(followUpAt, clock.now, "the follow-up is still ahead")
        let followUp = Self.rebuild(at: followUpAt)
        assertSameStamp(followUp.snapshot?.lastSyncedAt, withheld, "the follow-up must show the withheld stamp")
        XCTAssertEqual(followUp.refreshAt, followUpAt.addingTimeInterval(ConduitStatusSnapshot.timelineRefreshInterval),
                       "one follow-up per reload, then hourly")
    }

    /// Sync Now in the foreground stamps through `SyncEngine.flush`'s drained
    /// branch. A foreground reload is budget-exempt, so it is requested at
    /// once — even a minute after the last one, and even though the hourly
    /// write floor alone would not have written the stamp yet.
    @MainActor
    func test_foregroundStamp_reloadsImmediately_insideTheFloor() async throws {
        let clock = Clock()
        let (database, _) = try makeFixture(clock: clock, lastReloadAgo: 60)
        let spy = ReloadSpy()
        let appState = makeAppState(database, spy: spy, clock: clock)
        appState.statusSurfaceDidBecomeActive()
        try await settle(appState, stamp: oldStamp)
        XCTAssertEqual(spy.count, 0)

        let syncNowStamp = Self.wholeSecond(Date())
        try await database.dbWriter.write { try SyncStateDAO.setLastSyncedAt($0, syncNowStamp) }
        try await waitUntil("the foreground stamp is reloaded") { spy.count == 1 }

        assertSameStamp(spy.rebuilds.last??.lastSyncedAt, syncNowStamp, "the rebuild must read the new stamp")
        assertSameStamp(ConduitStatusSnapshot.readFromAppGroup()?.lastSyncedAt, syncNowStamp)
        await appState.flushStatusSnapshot()
        XCTAssertEqual(spy.count, 1, "one stamp, one reload")
    }

    /// Scene phase `.inactive` reloads once when the stamp differs from the
    /// last reloaded one — here a background stamp the floor withheld — and
    /// not again for the same stamp.
    @MainActor
    func test_inactive_reloadsAStampTheFloorWithheld_once() async throws {
        let clock = Clock()
        let (database, _) = try makeFixture(clock: clock, lastReloadAgo: 60)
        let spy = ReloadSpy()
        let appState = makeAppState(database, spy: spy, clock: clock)
        try await settle(appState, stamp: oldStamp)

        let withheld = Self.wholeSecond(Date())
        try await database.dbWriter.write { try SyncStateDAO.setLastSyncedAt($0, withheld) }
        try await settle(appState, stamp: withheld)
        XCTAssertEqual(spy.count, 0, "inside the floor a background stamp waits")

        await appState.flushStatusSnapshot(reloadingAnyNewStamp: true)
        XCTAssertEqual(spy.count, 1)
        assertSameStamp(spy.rebuilds.last??.lastSyncedAt, withheld)
        await appState.flushStatusSnapshot(reloadingAnyNewStamp: true)
        XCTAssertEqual(spy.count, 1, "the same stamp is reloaded once")
    }
}
