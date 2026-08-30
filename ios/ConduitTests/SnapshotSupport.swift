import SwiftUI
import UIKit
import SnapshotTesting
@testable import Conduit

// MARK: - Snapshot environment

/// Shared knobs for the screen snapshot suite.
///
/// The committed baselines were recorded on the `conduit-ios` GitHub Actions
/// simulator, which pinned the rendering OS + scale run-to-run. The tolerances
/// below only absorb sub-pixel anti-aliasing drift between two runs on that same
/// image; genuine layout changes still exceed them and fail loudly — which is
/// also why the comparison is now opt-in (see `isEnabled`).
enum SnapshotEnv {
    /// Whether the pixel-diff assertions actually run.
    ///
    /// They are **opt-in**, because the environment the baselines were recorded
    /// on no longer exists: the `conduit-ios` job was deleted along with all
    /// GitHub Actions macOS CI (10x billing — see the root AGENTS.md), and Xcode
    /// Cloud, now the only CI that runs this bundle, renders on a different
    /// simulator image. Every reference mismatched there on every commit, so all
    /// five screens failed unconditionally — a red gate carrying no signal, which
    /// only masked the logic tests around it. A pixel-diff is only meaningful on
    /// a host whose renderer matches the references, so the suite runs when a
    /// human opts in on such a host (`SNAPSHOT_TESTS=1`) or re-records
    /// (`SNAPSHOT_RECORD=1`), and otherwise `XCTSkip`s. Same shape as
    /// `AppStoreScreenshotTests`' `GENERATE_APPSTORE_SCREENSHOTS` gate. Under
    /// `xcodebuild`, prefix the var with `TEST_RUNNER_` so it reaches the test
    /// process. See AGENTS.md.
    static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["SNAPSHOT_TESTS"] == "1" || env["SNAPSHOT_RECORD"] == "1"
    }

    /// Fixed logical canvas (iPhone-class portrait). The layout is pinned here so
    /// it never depends on whatever device the test host happens to be; the
    /// rendering device only supplies the OS renderer + display scale.
    static let canvasSize = CGSize(width: 393, height: 852)

    static let precision: Float = 0.98
    static let perceptualPrecision: Float = 0.97

    /// Recording policy. `nil` uses the library default (`.missing` — record any
    /// baseline that doesn't exist yet, then compare), which is exactly what we
    /// want for the first CI run that generates the references. Set
    /// `SNAPSHOT_RECORD=1` to force a full re-record of every baseline.
    static let recordMode: SnapshotTestingConfiguration.Record? =
        ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1" ? .all : nil

    /// The four required variants: {light, dark} × {default, large} Dynamic Type.
    /// "default" is the system default content size (`.large`); "large" uses an
    /// accessibility size to exercise type scaling and reflow.
    static let variants: [(name: String, style: UIUserInterfaceStyle, category: UIContentSizeCategory)] = [
        ("light-default", .light, .large),
        ("light-accessibilityXXXL", .light, .accessibilityExtraExtraExtraLarge),
        ("dark-default", .dark, .large),
        ("dark-accessibilityXXXL", .dark, .accessibilityExtraExtraExtraLarge),
    ]
}

// MARK: - In-memory app state

/// A fully in-memory `AppState` for snapshot rendering — no on-disk database, no
/// live HealthKit reads, no network. Screens observe this exactly as they would
/// the real shared state.
@MainActor
func makeSnapshotAppState() -> AppState {
    // makeInMemory runs all migrations, so every DAO the screens touch is present.
    let db = try! AppDatabase.makeInMemory()
    return AppState(database: db)
}

// MARK: - Hosting + settle

/// Host `view` in a real key window at the fixed canvas size with the given
/// appearance + Dynamic Type overrides, then pump the run loop so `.onAppear`
/// fires (the screens lazily build their view model there) and any GRDB
/// `ValueObservation` delivers its first value before we capture.
@MainActor
func hostForSnapshot<V: View>(
    _ view: V,
    style: UIUserInterfaceStyle,
    sizeCategory: UIContentSizeCategory,
    settle: TimeInterval
) -> UIViewController {
    let vc = UIHostingController(rootView: view)
    let window = UIWindow(frame: CGRect(origin: .zero, size: SnapshotEnv.canvasSize))
    // Appearance is driven by the window's dedicated `overrideUserInterfaceStyle`
    // (a `traitOverrides.userInterfaceStyle` is NOT honored for a window's actual
    // rendered appearance — it only leaks into SwiftUI's color scheme, which is
    // what produced the earlier half-dark render). Dynamic Type goes through
    // `traitOverrides` (which the window does honor). Both are also mirrored onto
    // the hosting controller so the trait environment is unambiguous, and we
    // capture via `drawHierarchyInKeyWindow` (the live framebuffer) so SwiftUI
    // text and UIKit-backed List cells share one consistent appearance.
    window.overrideUserInterfaceStyle = style
    window.traitOverrides.preferredContentSizeCategory = sizeCategory
    vc.overrideUserInterfaceStyle = style
    vc.traitOverrides.preferredContentSizeCategory = sizeCategory
    window.rootViewController = vc
    window.makeKeyAndVisible()

    vc.view.frame = window.bounds
    vc.view.layoutIfNeeded()

    // Let onAppear + async view-model/DB observation settle. Pumping the main run
    // loop (rather than sleeping) lets the main-actor continuations that deliver
    // the observation's initial value actually run.
    let deadline = Date().addingTimeInterval(settle)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    vc.view.layoutIfNeeded()
    return vc
}

/// Render `makeView()` across all four appearance × Dynamic Type variants and
/// assert each against its committed baseline. Each variant re-instantiates the
/// view so hosting starts clean.
@MainActor
func assertScreenSnapshots<V: View>(
    _ makeView: @autoclosure () -> V,
    settle: TimeInterval = 1.2,
    file: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line
) {
    for variant in SnapshotEnv.variants {
        let vc = hostForSnapshot(
            makeView(),
            style: variant.style,
            sizeCategory: variant.category,
            settle: settle
        )
        assertSnapshot(
            of: vc.view,
            // `drawHierarchyInKeyWindow: true` captures the live (dark, key)
            // window framebuffer rather than a detached `layer.render`, so the
            // appearance is consistent across SwiftUI text AND the UIKit-backed
            // List cell backgrounds (a plain layer render left them mismatched:
            // dark text on light cards).
            as: .image(
                drawHierarchyInKeyWindow: true,
                precision: SnapshotEnv.precision,
                perceptualPrecision: SnapshotEnv.perceptualPrecision
            ),
            named: variant.name,
            record: SnapshotEnv.recordMode,
            file: file,
            testName: testName,
            line: line
        )
    }
}

// MARK: - Fixtures

/// Deterministic seed data for the data-backed screens. All values are fixed
/// strings so nothing in the captured pixels depends on wall-clock time, locale,
/// or time zone.
enum SnapshotFixtures {
    /// Settings: a saved webhook + every registry type enabled, so the Webhook,
    /// Sync (15-minute interval), and Data Types (N/N per category) sections all
    /// render populated. Settings loads synchronously in its outer `onAppear`, so
    /// this seed is reliably reflected in the capture.
    @MainActor
    static func seedSettings(_ database: AppDatabase) {
        let webhookDAO = WebhookConfigDAO(database)
        var config = WebhookConfig.makeDefault(
            url: "https://example.com/webhook",
            bearerTokenKeychainRef: "webhook_bearer_token"
        )
        _ = try? webhookDAO.save(&config)

        let typeDAO = DataTypeConfigDAO(database)
        for type in HealthTypeRegistry.shared.all {
            try? typeDAO.setEnabled(true, hkTypeId: type.identifier)
        }
    }
}
