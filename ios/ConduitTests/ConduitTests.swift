import XCTest
import SwiftUI
import UIKit
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

/// Guards the App Store version train the app ships under.
///
/// App Store Connect rejected the 1.4 upload twice over — `ITMS-90186` ("the
/// train version '1.4' is closed for new build submissions") and `ITMS-90062`
/// ("CFBundleShortVersionString [1.4] ... must contain a higher version than
/// that of the previously approved version [1.4]"). Once a version is approved,
/// no further build can be accepted at that number, so every future upload —
/// Xcode Cloud release workflow or manual archive — needs a marketing version
/// strictly past it.
///
/// The contract asserted here is the built bundle's `Info.plist`, which is the
/// artifact App Store Connect actually validates, not the project file that
/// happens to feed it: `MARKETING_VERSION` reaches the upload only by way of
/// `CFBundleShortVersionString`, and Xcode Cloud's `ci_post_clone.sh` rewrites
/// `CURRENT_PROJECT_VERSION` in the same file, so reading the emitted plist is
/// what proves the value survives the build. The unit-test host runs inside
/// `Conduit.app`, so `Bundle.main` is that shipped bundle (same mechanism
/// `BackgroundTaskConfigTests` above relies on).
///
/// The bound is a lower bound, not a pin, so a later bump keeps passing.
final class AppStoreVersionTests: XCTestCase {

    /// The version App Store Connect has already approved; its train is closed.
    private static let closedTrain = "1.4"

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    func test_bundleUnderTest_isTheShippedApp() {
        // Pins what `Bundle.main` resolves to, so the version assertions below
        // can't quietly start reading some other bundle's Info.plist.
        XCTAssertEqual(Bundle.main.bundleIdentifier, "dev.noebrito.Conduit")
    }

    func test_marketingVersion_isPastTheClosedAppStoreTrain() {
        XCTAssertFalse(shortVersion.isEmpty, "CFBundleShortVersionString is missing from the built app bundle")
        XCTAssertEqual(
            shortVersion.compare(Self.closedTrain, options: .numeric),
            .orderedDescending,
            """
            CFBundleShortVersionString is \(shortVersion); App Store Connect \
            already approved \(Self.closedTrain) and closed that train, so any \
            upload at or below it is rejected (ITMS-90186 / ITMS-90062).
            """
        )
    }

    func test_marketingVersion_isAValidDottedVersion() {
        // App Store Connect requires a numeric dotted version; a stray suffix
        // ("1.5-beta") is rejected at upload, and would also make the numeric
        // comparison above meaningless.
        let components = shortVersion.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertTrue((1...3).contains(components.count), "Unexpected version shape: \(shortVersion)")
        for component in components {
            XCTAssertNotNil(Int(component), "Non-numeric component in version \(shortVersion)")
        }
    }
}

/// The version bump as a user actually sees it: Settings → About → "Version".
///
/// `AppStoreVersionTests` above owns the upload contract (the built bundle's
/// `CFBundleShortVersionString`); this owns the screen that reads it. The
/// assertion is on the exact string `SettingsView`'s About row renders
/// (`SettingsViewModel.appVersion`), and the capture is the human-reviewable
/// half — a SwiftUI `List` builds its cells' accessibility elements lazily from
/// an accessibility server that isn't attached in a unit-test process, so the
/// rendered text can't be read back out of the hierarchy (same split, and same
/// reason, as `RunningDynamicsEvidenceTests`' picker capture).
///
/// The PNG is written only when `CONDUIT_EVIDENCE_DIR` names a writable
/// directory; without it the test still runs and still asserts.
@MainActor
final class SettingsVersionEvidenceTests: XCTestCase {

    func test_settingsAboutRow_rendersTheShippedMarketingVersion() throws {
        let appState = makeSnapshotAppState()
        SnapshotFixtures.seedSettings(appState.database)

        let shortVersion = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
        let build = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )

        // The About row renders this string verbatim, so asserting it pins that
        // the screen reports the shipped bundle's version rather than the
        // hardcoded "1.0" fallback the view model falls back to.
        let viewModel = SettingsViewModel(appState: appState)
        viewModel.load()
        XCTAssertEqual(viewModel.appVersion, "Version \(shortVersion) (\(build))")
        XCTAssertEqual(
            shortVersion.compare("1.4", options: .numeric),
            .orderedDescending,
            "Settings would show the closed 1.4 train to the user"
        )

        // Render the real screen and scroll to the bottom, where About lives.
        let canvas = CGSize(width: 393, height: 852)
        let vc = UIHostingController(rootView: SettingsView().environment(appState))
        let window = UIWindow(frame: CGRect(origin: .zero, size: canvas))
        window.overrideUserInterfaceStyle = .light
        vc.overrideUserInterfaceStyle = .light
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc.view.frame = window.bounds
        vc.view.layoutIfNeeded()
        settle(1.6)

        let scrollView = try XCTUnwrap(Self.firstScrollView(in: vc.view), "Settings did not host a scroll view")
        let maxOffset = scrollView.contentSize.height
            - scrollView.bounds.height
            + scrollView.adjustedContentInset.bottom
        scrollView.setContentOffset(CGPoint(x: 0, y: max(0, maxOffset)), animated: false)
        vc.view.layoutIfNeeded()
        settle(0.8)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            vc.view.drawHierarchy(in: vc.view.bounds, afterScreenUpdates: true)
        }
        let label = ProcessInfo.processInfo.environment["CONDUIT_EVIDENCE_LABEL"] ?? "after"
        try writeArtifact(XCTUnwrap(image.pngData()), named: "settings-about-version-\(label).png")
    }

    /// Pump the main run loop so `onAppear`, the view model's load, and the
    /// list's cell layout all land before capture.
    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
