import XCTest
@testable import Conduit

/// Tests for the pure helpers behind the Lock Screen widget: the codec that
/// crosses the App Group boundary, the `accessoryRectangular` second-line
/// chooser, the `accessoryCircular` symbol chooser, and the reload-budget
/// gate. None of these touch the App Group container or GRDB — the widget
/// extension never opens either (`data/conduit-live-activities-scout/report.md`
/// §7.2).
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
}
