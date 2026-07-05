import XCTest
@testable import Conduit

/// Phase I1 placeholder test. Confirms the test target is wired to the app
/// target and runs. Real coverage (HealthKit registry, outbox dedup, migrations)
/// lands in Phase I2.
final class ConduitTests: XCTestCase {
    func testScaffoldingBuildsAndRuns() {
        XCTAssertTrue(true, "Conduit test target is wired up and runnable.")
    }
}

/// Guards the background-task wiring that drives sync when the app is not open.
///
/// The original bug: the background-task identifier in code
/// (`dev.noebrito.Conduit.catchup`) never matched the one permitted in
/// `Info.plist` (`dev.noebrito.Conduit.flush`), so iOS would refuse to register
/// or schedule it. `BGTaskScheduler` rejects any identifier that isn't listed in
/// `BGTaskSchedulerPermittedIdentifiers`, so these must stay in sync.
///
/// The unit test host runs inside `Conduit.app`, so `Bundle.main` is the app
/// bundle and exposes the app's `Info.plist`.
final class BackgroundTaskConfigTests: XCTestCase {

    private var permittedIdentifiers: [String] {
        Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    }

    func test_bgRefreshTaskID_isPermittedInInfoPlist() {
        XCTAssertTrue(
            permittedIdentifiers.contains(SyncEngine.bgRefreshTaskID),
            "BGAppRefreshTask id \(SyncEngine.bgRefreshTaskID) missing from BGTaskSchedulerPermittedIdentifiers \(permittedIdentifiers)"
        )
    }

    func test_bgRefreshTaskID_isStable() {
        // Pin the value so a rename can't silently drift from Info.plist again.
        XCTAssertEqual(SyncEngine.bgRefreshTaskID, "dev.noebrito.Conduit.flush")
    }

    func test_refreshInterval_isReasonable() {
        // iOS enforces a ~15 min floor for BGAppRefresh; keep our request at/above it.
        XCTAssertGreaterThanOrEqual(SyncEngine.bgRefreshInterval, 15 * 60)
    }

    func test_backgroundFetchModeDeclared() {
        // BGAppRefreshTask requires the `fetch` background mode.
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        XCTAssertTrue(modes.contains("fetch"), "UIBackgroundModes must include `fetch` for BGAppRefreshTask, got \(modes)")
    }
}
