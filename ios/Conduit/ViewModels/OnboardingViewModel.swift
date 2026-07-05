import Foundation
import Observation

private let kPendingURL = "conduit.onboarding.pendingURL"
private let kPendingTokenKeychainRef = "conduit.onboarding.pendingToken"
private let kLastStep = "conduit.onboarding.lastStep"

/// Drives the 4-step onboarding flow.
///
/// Partial state is persisted so the user can exit and resume without losing
/// their webhook URL or selected data types (§I4 spec: "can be exited and
/// resumed without losing partial config").
///
/// - Step 0 Welcome
/// - Step 1 Webhook Setup (URL + token + Test Connection)
/// - Step 2 Data Type picker
/// - Step 3 HealthKit permission trigger
@Observable
final class OnboardingViewModel {
    enum OnboardingError: LocalizedError {
        case keychainWriteFailed

        var errorDescription: String? {
            "Couldn't securely save your webhook token. Please try again."
        }
    }

    enum Step: Int, CaseIterable {
        case welcome = 0
        case webhookSetup = 1
        case dataTypes = 2
        case hkPermission = 3
    }

    var currentStep: Step = .welcome

    // Webhook setup fields
    var webhookURL: String = ""
    var tokenInput: String = ""
    var testResult: WebhookTester.Result? = nil
    var isTesting = false

    // Data type selection — all enabled by default
    var enabledTypeIDs: Set<String> = Set(HealthTypeRegistry.shared.all.map(\.identifier))

    // Optional: import existing history after setup. OFF by default — the
    // default is forward-only capture. When enabled the user picks how far back.
    var importExistingHistory = false
    var importRange: ImportRange = .lastYear
    var customImportStart: Date = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()

    // HealthKit authorizer
    private let authorizer = HealthKitAuthorizer()
    var hkAuthError: String? = nil
    var hkAuthCompleted = false

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        restorePartialState()
    }

    // MARK: - Navigation

    func advance() {
        guard let next = Step(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
        persist()
    }

    var canAdvanceFromWebhookSetup: Bool {
        testResult?.isSuccess == true
    }

    // MARK: - Test Connection

    func testConnection() async {
        guard !webhookURL.isEmpty, !tokenInput.isEmpty else { return }
        isTesting = true
        testResult = nil
        let result = await WebhookTester.test(url: webhookURL, token: tokenInput)
        testResult = result
        isTesting = false
    }

    // MARK: - Data Types

    func toggle(typeID: String) {
        if enabledTypeIDs.contains(typeID) {
            enabledTypeIDs.remove(typeID)
        } else {
            enabledTypeIDs.insert(typeID)
        }
    }

    // MARK: - HK Permission

    func requestHealthKitPermission() async {
        let enabledTypes = HealthTypeRegistry.shared.all.filter {
            enabledTypeIDs.contains($0.identifier)
        }
        do {
            try await authorizer.request(for: enabledTypes)
            hkAuthCompleted = true
        } catch {
            hkAuthError = error.localizedDescription
            hkAuthCompleted = true
        }
    }

    // MARK: - Completion

    func finishOnboarding() throws {
        // Save enabled types to data_type_config
        let typeDAO = DataTypeConfigDAO(appState.database)
        for type in HealthTypeRegistry.shared.all {
            try typeDAO.setEnabled(enabledTypeIDs.contains(type.identifier), hkTypeId: type.identifier)
        }

        // Store bearer token in Keychain, save webhook config row
        let keychainRef = "webhook_bearer_token"
        guard appState.keychain.setWebhookBearerToken(tokenInput) else {
            throw OnboardingError.keychainWriteFailed
        }
        var config = WebhookConfig.makeDefault(url: webhookURL, bearerTokenKeychainRef: keychainRef)
        let webhookDAO = WebhookConfigDAO(appState.database)
        try webhookDAO.save(&config)

        // Clear pending onboarding state from UserDefaults
        UserDefaults.standard.removeObject(forKey: kPendingURL)
        UserDefaults.standard.removeObject(forKey: kLastStep)

        // Seed the authorized-registry signature so the launch-time
        // reconcileRegistry() doesn't re-present a duplicate permission sheet
        // right after onboarding just requested authorization. On a future app
        // update that adds a type, the signature will differ and reconcile will
        // prompt once for the new type(s).
        UserDefaults.standard.set(AppState.authorizedTypesSignature(), forKey: AppState.authorizedSignatureKey)

        appState.completeOnboarding()

        // Start capturing right away so new samples flow without an app
        // relaunch. Capture is forward-only by default: the first read seeds
        // each type's anchor to "now", so only data created at/after setup is
        // staged (no historical backfill).
        appState.startDataCapture()

        // Optional explicit opt-in: import PAST history over the chosen range.
        // Runs ONLY when the user turned it on (OFF by default) and ONLY after
        // startDataCapture(), so the forward anchors are seeded first. The import
        // stages via the enqueue-only path (no forward anchor advance) and is
        // paged + outbox-cap bounded, so it can't flood the queue.
        if importExistingHistory {
            let since = importRange.startDate(now: Date(), customStart: customImportStart)
            let enabledTypes = HealthTypeRegistry.shared.all.filter {
                enabledTypeIDs.contains($0.identifier)
            }
            let engine = appState.syncEngine
            Task.detached(priority: .utility) {
                for type in enabledTypes {
                    _ = await engine.importHistory(typeIdentifier: type.identifier, since: since)
                }
            }
        }
    }

    // MARK: - Partial State Persistence

    private func restorePartialState() {
        if let savedURL = UserDefaults.standard.string(forKey: kPendingURL) {
            webhookURL = savedURL
        }
        let savedStep = UserDefaults.standard.integer(forKey: kLastStep)
        currentStep = Step(rawValue: savedStep) ?? .welcome

        // Restore enabled types from data_type_config if any were saved
        if let configs = try? DataTypeConfigDAO(appState.database).all(), !configs.isEmpty {
            enabledTypeIDs = Set(configs.filter(\.enabled).map(\.hkTypeId))
        }
    }

    private func persist() {
        UserDefaults.standard.set(webhookURL, forKey: kPendingURL)
        UserDefaults.standard.set(currentStep.rawValue, forKey: kLastStep)
    }
}
