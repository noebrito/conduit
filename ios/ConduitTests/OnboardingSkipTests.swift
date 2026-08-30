import XCTest
@testable import Conduit

/// Covers the App Review unblock: the webhook step must be skippable so the app
/// is never hard-gated behind a live webhook Test Connection.
final class OnboardingSkipTests: XCTestCase {
    private func makeViewModel() -> OnboardingViewModel {
        let db = try! AppDatabase.makeInMemory()
        let appState = AppState(database: db)
        let vm = OnboardingViewModel(appState: appState)
        vm.currentStep = .webhookSetup
        return vm
    }

    func testSkipAdvancesPastWebhookSetup() {
        let vm = makeViewModel()
        vm.webhookURL = "https://example.com/hook"
        vm.tokenInput = "some-token"

        vm.skipWebhookSetup()

        XCTAssertEqual(vm.currentStep, .dataTypes, "Skip should advance to the data types step")
    }

    func testSkipClearsPartialWebhookInput() {
        let vm = makeViewModel()
        vm.webhookURL = "https://example.com/hook"
        vm.tokenInput = "some-token"

        vm.skipWebhookSetup()

        XCTAssertTrue(vm.webhookURL.isEmpty, "Skip should clear the URL so no webhook is saved")
        XCTAssertTrue(vm.tokenInput.isEmpty, "Skip should clear the token so no webhook is saved")
    }

    func testContinueStillGatedOnSuccessfulTest() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.canAdvanceFromWebhookSetup, "Without a passing test, Continue stays disabled")

        vm.testResult = WebhookTester.Result(statusCode: 200, latencyMs: 12, error: nil)
        XCTAssertTrue(vm.canAdvanceFromWebhookSetup, "A passing test enables Continue")

        vm.testResult = WebhookTester.Result(statusCode: 500, latencyMs: 12, error: "boom")
        XCTAssertFalse(vm.canAdvanceFromWebhookSetup, "A failing test keeps Continue disabled")
    }
}
