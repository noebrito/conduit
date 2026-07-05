import XCTest
import SwiftUI
import UIKit
@testable import Conduit

/// App Store marketing-screenshot **generator** for Conduit.
///
/// This is deliberately NOT a comparison snapshot test (that job belongs to
/// `ScreenSnapshotTests`, which pins the layout against committed baselines).
/// Instead it *renders* the five marketing screens — with rich, populated
/// fixtures — at Apple's currently-required App Store iPhone pixel sizes in both
/// light and dark appearance, and writes the PNGs into the committed
/// `conduit/ios/docs/appstore-screenshots/` tree so they're ready to drag into
/// App Store Connect.
///
/// ## Why this mechanism (vs. fastlane snapshot / a live-app XCUITest)
/// Conduit gates its home surface behind completed onboarding **and** a live
/// HealthKit authorization dialog — neither of which a headless UITest can drive
/// deterministically (HealthKit permission sheets can't be scripted, and a
/// populated Home needs seeded local data). The merged `ScreenSnapshotTests`
/// already proved the reliable path: host each SwiftUI screen in a real key
/// window over an in-memory, seeded `AppState`, pump the run loop so `.onAppear`
/// loaders settle, and capture the live framebuffer. This generator reuses that
/// exact discipline (see `SnapshotSupport.swift`), so there is **zero app-code
/// change, no new dependency, no fragile navigation**, and the marketing images
/// stay in lockstep with how the app actually renders.
///
/// ## How to (re)generate — one command
/// ```
/// GENERATE_APPSTORE_SCREENSHOTS=1 xcodebuild test \
///   -project conduit/ios/Conduit.xcodeproj -scheme Conduit \
///   -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' \
///   -only-testing:ConduitTests/AppStoreScreenshotTests \
///   CODE_SIGNING_ALLOWED=NO
/// ```
/// See `docs/appstore-screenshots/README.md` for the full flow.
///
/// ## CI safety
/// The single test method is **skipped** unless `GENERATE_APPSTORE_SCREENSHOTS=1`
/// is set in the environment, so the normal `conduit-ios` gate (which runs the
/// whole `ConduitTests` bundle) pays only an instant `XCTSkip` and is never
/// slowed or made flaky by rendering.
@MainActor
final class AppStoreScreenshotTests: XCTestCase {

    // MARK: - Device targets (Apple App Store Connect, verified 2026)

    /// The App Store iPhone screenshot sizes we emit. Portrait, exact pixels
    /// (Apple enforces no off-by-one). Rendered at scale 3, so the point size is
    /// pixels / 3.
    ///
    /// - `6.9"` (1320×2868, iPhone 16/17 Pro Max) is the **required** slot.
    /// - `6.5"` (1284×2778, iPhone 14 Plus / 13 Pro Max class) is still accepted
    ///   and given so the captain can upload either.
    struct DeviceTarget {
        let slug: String
        let pointSize: CGSize
        let scale: CGFloat
        var pixelSize: CGSize { CGSize(width: pointSize.width * scale, height: pointSize.height * scale) }
    }

    static let devices: [DeviceTarget] = [
        DeviceTarget(slug: "iphone-6.9-inch-1320x2868", pointSize: CGSize(width: 440, height: 956), scale: 3),
        DeviceTarget(slug: "iphone-6.5-inch-1284x2778", pointSize: CGSize(width: 428, height: 926), scale: 3),
    ]

    static let appearances: [(name: String, style: UIUserInterfaceStyle)] = [
        ("light", .light),
        ("dark", .dark),
    ]

    override func setUp() {
        super.setUp()
        // A stored token makes the Settings "Webhook" section render its populated
        // (masked-token present) state rather than an empty field.
        _ = KeychainStore.shared.setWebhookBearerToken("demo-token-for-screenshots")
    }

    override func tearDown() {
        _ = KeychainStore.shared.deleteWebhookBearerToken()
        super.tearDown()
    }

    // MARK: - The generator

    func testGenerateAppStoreScreenshots() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["GENERATE_APPSTORE_SCREENSHOTS"] == "1",
            "Set GENERATE_APPSTORE_SCREENSHOTS=1 to render App Store marketing screenshots."
        )

        let outputRoot = Self.outputRoot()
        // Fresh output each run so removed screens don't leave stale PNGs behind.
        try? FileManager.default.removeItem(at: outputRoot)

        var written = 0
        for device in Self.devices {
            for appearance in Self.appearances {
                for screen in Screen.allCases {
                    let image = render(screen, device: device, style: appearance.style)
                    try writePNG(
                        image,
                        to: outputRoot
                            .appendingPathComponent(device.slug, isDirectory: true)
                            .appendingPathComponent(appearance.name, isDirectory: true)
                            .appendingPathComponent("\(screen.order)-\(screen.slug).png")
                    )
                    // Guard the App Store's exact-pixel rule at generation time.
                    XCTAssertEqual(image.size.width * image.scale, device.pixelSize.width, accuracy: 0.5)
                    XCTAssertEqual(image.size.height * image.scale, device.pixelSize.height, accuracy: 0.5)
                    written += 1
                }
            }
        }
        XCTAssertEqual(written, Self.devices.count * Self.appearances.count * Screen.allCases.count)
        print("[AppStoreScreenshots] wrote \(written) PNGs to \(outputRoot.path)")
    }

    // MARK: - Screens

    /// The five marketing-worthy screens, each built with populated fixtures.
    enum Screen: CaseIterable {
        case home, activity, settings, permission, welcome

        var order: Int {
            switch self {
            case .home: return 1
            case .activity: return 2
            case .settings: return 3
            case .permission: return 4
            case .welcome: return 5
            }
        }

        var slug: String {
            switch self {
            case .home: return "home"
            case .activity: return "activity"
            case .settings: return "settings"
            case .permission: return "healthkit-permission"
            case .welcome: return "welcome"
            }
        }
    }

    @MainActor
    private func makeView(for screen: Screen) -> AnyView {
        switch screen {
        case .home:
            let appState = makeSeededAppState()
            return AnyView(HomeView().environment(appState))
        case .activity:
            let appState = makeSeededAppState()
            return AnyView(ActivityLogView().environment(appState))
        case .settings:
            let appState = makeSeededAppState()
            return AnyView(SettingsView().environment(appState))
        case .permission:
            let appState = makeSeededAppState()
            let vm = OnboardingViewModel(appState: appState)
            return AnyView(NavigationStack { HKPermissionStepView(viewModel: vm) })
        case .welcome:
            return AnyView(NavigationStack { WelcomeStepView(onContinue: {}) })
        }
    }

    // MARK: - Render + host

    /// Host `screen`'s view in a real key window at the device's point size and
    /// appearance, pump the run loop so lazy `.onAppear` loaders settle, then
    /// capture the live framebuffer at the device scale (exact App Store pixels,
    /// opaque = no alpha channel, as Apple requires).
    @MainActor
    private func render(_ screen: Screen, device: DeviceTarget, style: UIUserInterfaceStyle) -> UIImage {
        let vc = UIHostingController(rootView: makeView(for: screen))
        let window = UIWindow(frame: CGRect(origin: .zero, size: device.pointSize))
        // Appearance must be driven by the window's `overrideUserInterfaceStyle`
        // (a `traitOverrides` value is not honored for a window's rendered
        // appearance — the sharp edge documented in SnapshotSupport). Mirror it
        // onto the hosting controller so the trait environment is unambiguous.
        window.overrideUserInterfaceStyle = style
        vc.overrideUserInterfaceStyle = style
        window.rootViewController = vc
        window.makeKeyAndVisible()

        vc.view.frame = window.bounds
        vc.view.layoutIfNeeded()

        // Home nests two `.onAppear`s (build VM → start loaders); Activity/Settings
        // deliver their first GRDB observation via a main-actor continuation.
        // Pumping the run loop (not sleeping) lets those continuations actually run.
        let deadline = Date().addingTimeInterval(1.6)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        vc.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = device.scale       // force exact 3x regardless of host sim
        format.opaque = true              // RGB, no alpha channel (App Store rule)
        let renderer = UIGraphicsImageRenderer(size: device.pointSize, format: format)
        return renderer.image { _ in
            // Live key-window framebuffer, so SwiftUI text and UIKit-backed List
            // cells share one consistent appearance (a plain layer.render left
            // them mismatched in dark mode).
            vc.view.drawHierarchy(in: vc.view.bounds, afterScreenUpdates: true)
        }
    }

    // MARK: - Seeded state

    /// An in-memory `AppState` seeded with rich, deterministic marketing data:
    /// a saved webhook + all data types enabled (Settings), a recent successful
    /// sync + a "staged today" tally + a little pending work (Home), and a mixed
    /// delivery history (Activity).
    @MainActor
    private func makeSeededAppState() -> AppState {
        let appState = makeSnapshotAppState()
        // Webhook + every registry data type enabled → Settings renders populated.
        SnapshotFixtures.seedSettings(appState.database)
        AppStoreFixtures.seedActivityAndHome(appState.database)
        return appState
    }

    // MARK: - Output

    /// `conduit/ios/docs/appstore-screenshots/`, derived from this file's on-disk
    /// path (the iOS Simulator can read/write real host paths, which is exactly
    /// how swift-snapshot-testing persists its `__Snapshots__`).
    private static func outputRoot(file: StaticString = #filePath) -> URL {
        // …/conduit/ios/ConduitTests/AppStoreScreenshotTests.swift
        let thisFile = URL(fileURLWithPath: "\(file)")
        let iosDir = thisFile.deletingLastPathComponent().deletingLastPathComponent() // …/conduit/ios
        return iosDir
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("appstore-screenshots", isDirectory: true)
    }

    private func writePNG(_ image: UIImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = image.pngData() else {
            throw XCTSkip("Failed to PNG-encode \(url.lastPathComponent)")
        }
        try data.write(to: url)
    }
}

// MARK: - Marketing fixtures

/// Deterministic-shape seed data for the data-backed marketing screens. Times are
/// relative to `now` so relative labels ("Synced 2 minutes ago") read naturally;
/// the exact minute is irrelevant to a marketing screenshot.
enum AppStoreFixtures {

    @MainActor
    static func seedActivityAndHome(_ database: AppDatabase, now: Date = Date()) {
        // Resolve the webhook id seeded by `SnapshotFixtures.seedSettings` so the
        // outbox foreign key is satisfied.
        let webhookId = (try? WebhookConfigDAO(database).first()?.id) ?? nil

        try? database.dbWriter.write { db in
            // --- Home: last successful sync + "staged today" tally ---
            try SyncStateDAO.setLastSyncedAt(db, now.addingTimeInterval(-120)) // 2 min ago
            try StagedDailyCountDAO.increment(db, enqueuedAt: now, by: 3_847)

            // A little pending work so the Outbox section isn't all zeros. Raw
            // insert (state = pending) keeps this independent of the proto payload
            // shape; a 2-byte "{}" blob satisfies the NOT NULL payload column.
            if let webhookId {
                for i in 0..<8 {
                    try db.execute(
                        sql: """
                            INSERT INTO outbox
                                (webhook_id, hk_sample_uuid, hk_type_id, payload_blob,
                                 created_at, state, attempt_count)
                            VALUES (?, ?, ?, ?, ?, ?, 0)
                            """,
                        arguments: [
                            webhookId,
                            "marketing-pending-\(i)-\(UUID().uuidString)",
                            "HKQuantityTypeIdentifierHeartRate",
                            Data([0x7b, 0x7d]),
                            now,
                            OutboxState.pending.rawValue,
                        ]
                    )
                }
            }

            // --- Activity: a compelling mixed delivery history ---
            // (secondsAgo, httpStatus, sampleCount, error, accepted, deduped)
            let rows: [(TimeInterval, Int?, Int, String?, Int?, Int?)] = [
                (-180,    200, 847,  nil,                 847,  0),
                (-1_080,  200, 1_203, nil,                1_150, 53),
                (-2_520,  200, 640,  nil,                 640,  0),
                (-3_600,  500, 210,  "Server error (500)", nil,  nil),
                (-7_200,  200, 2_011, nil,                2_011, 0),
                (-10_800, 200, 156,  nil,                 0,    156), // all-deduped (orange)
                (-18_000, 200, 924,  nil,                 924,  0),
            ]
            for (i, r) in rows.enumerated() {
                var entry = DeliveryLogEntry(
                    id: nil,
                    batchId: "marketing-batch-\(i)",
                    sentAt: now.addingTimeInterval(r.0),
                    httpStatus: r.1,
                    sampleCount: r.2,
                    errorMessage: r.3,
                    accepted: r.4,
                    deduped: r.5
                )
                try entry.insert(db)
            }
        }
    }
}
