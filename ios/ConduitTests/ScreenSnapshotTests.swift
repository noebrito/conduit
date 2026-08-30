import XCTest
import SwiftUI
import SnapshotTesting
@testable import Conduit

/// Image-snapshot coverage for Conduit's five primary user-facing screens, each
/// captured across the required 2×2 matrix: {light, dark} appearance ×
/// {default, large} Dynamic Type — 20 reference images total.
///
/// The five screens (verified against `Conduit/Views/`):
///   1. Onboarding Welcome  — `WelcomeStepView` (first screen a new user sees)
///   2. HealthKit Permission — `HKPermissionStepView` (the auth-grant step)
///   3. Home tab            — `HomeView`
///   4. Settings tab        — `SettingsView`
///   5. Activity tab        — `ActivityLogView`
///
/// Determinism: data-backed screens are fed an in-memory `AppState` seeded with
/// fixed fixtures (`SnapshotFixtures`); no screen touches live HealthKit or the
/// network on render. States were chosen so nothing rendered depends on
/// wall-clock time, locale, or time zone (Home shows the idle "No syncs yet"
/// label; Activity shows its empty state). See `SnapshotSupport.swift`.
///
/// Baselines are recorded on the CI simulator, NOT locally — see AGENTS.md. The
/// comparison is opt-in (`SnapshotEnv.isEnabled`): the simulator image the
/// references were recorded on is gone, so on any other host every screen
/// mismatches for reasons that have nothing to do with the code under test.
@MainActor
final class ScreenSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            SnapshotEnv.isEnabled,
            """
            Screen snapshots compare against baselines recorded on the retired \
            conduit-ios GitHub Actions simulator; any other renderer mismatches \
            them wholesale. Run with TEST_RUNNER_SNAPSHOT_TESTS=1 on a host that \
            matches the references (or TEST_RUNNER_SNAPSHOT_RECORD=1 to re-record \
            them). See AGENTS.md.
            """
        )
        // Keep `hasToken` deterministic regardless of any keychain residue left
        // on the simulator by another test/run: the Settings snapshot renders the
        // "no stored token" state.
        _ = KeychainStore.shared.deleteWebhookBearerToken()
    }

    // 1 — Onboarding Welcome
    func testWelcomeScreen() {
        assertScreenSnapshots(
            NavigationStack { WelcomeStepView(onContinue: {}) }
        )
    }

    // 2 — HealthKit permission step (default state: not yet authorized)
    func testHealthKitPermissionScreen() {
        let appState = makeSnapshotAppState()
        let viewModel = OnboardingViewModel(appState: appState)
        assertScreenSnapshots(
            NavigationStack { HKPermissionStepView(viewModel: viewModel) }
        )
    }

    // 3 — Home (clean/idle state)
    //
    // Home resolves to the stable idle layout: "No syncs yet" with zeroed outbox
    // counts. Its data-populated variant is driven by an inner `onAppear` load +
    // a GRDB observation that this static (non-interactive) host does not pump, so
    // the clean state is the deterministic thing to capture — and it's a real
    // first-launch state. No fixture is seeded, so nothing here depends on
    // wall-clock time (a populated status would render a relative "Synced N ago").
    func testHomeScreen() {
        let appState = makeSnapshotAppState()
        assertScreenSnapshots(
            HomeView().environment(appState)
        )
    }

    // 4 — Settings
    func testSettingsScreen() {
        let appState = makeSnapshotAppState()
        SnapshotFixtures.seedSettings(appState.database)
        assertScreenSnapshots(
            SettingsView().environment(appState)
        )
    }

    // 5 — Activity (empty state — deterministic, no dated rows)
    func testActivityScreen() {
        let appState = makeSnapshotAppState()
        assertScreenSnapshots(
            ActivityLogView().environment(appState)
        )
    }
}
