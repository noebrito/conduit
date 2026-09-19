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

    /// The earliest date iOS currently authorizes reading each enabled type's
    /// history back to. Only ever non-empty on a RE-run of onboarding
    /// ("Reset & Re-run Onboarding" in Settings) where a prior grant already
    /// exists — a fresh install has no HealthKit decision yet at this step
    /// (permission is requested one step later), so the probe has nothing to
    /// report. See `hasLimitedHistoryAccess`/`commonHistoryAccessFloor`.
    var historyAccessFloors: [String: Date] = [:]

    // HealthKit authorizer
    private let authorizer = HealthKitAuthorizer()
    private let historyAccessProbe: HistoryAccessProbing
    var hkAuthError: String? = nil
    var hkAuthCompleted = false

    private let appState: AppState

    init(appState: AppState, historyAccessProbe: HistoryAccessProbing = HealthKitHistoryAccessProbe()) {
        self.appState = appState
        self.historyAccessProbe = historyAccessProbe
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

    /// Skip the webhook step without configuring a destination. The user can set
    /// up (and Test) a webhook later in Settings. This is the App Review escape
    /// hatch: onboarding must never hard-gate the whole app behind a *live*
    /// webhook (a dead/expired reviewer URL previously locked the app out).
    /// Skipping simply advances; `finishOnboarding` writes NO webhook_config row
    /// when the URL/token are empty, so capture stays dormant (gracefully, no
    /// crash) until a webhook is added.
    func skipWebhookSetup() {
        webhookURL = ""
        tokenInput = ""
        testResult = nil
        advance()
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

    /// Re-check iOS's current per-type history-access floors. Cheap and
    /// side-effect-free — safe to call from `.onAppear` and after every
    /// toggle. See `historyAccessFloors`' doc for why this is usually empty.
    func loadHistoryAccessFloors() async {
        let types = HealthTypeRegistry.shared.all.filter { enabledTypeIDs.contains($0.identifier) }
        guard !types.isEmpty else {
            historyAccessFloors = [:]
            return
        }
        historyAccessFloors = await historyAccessProbe.limitedHistoryFloors(for: types)
    }

    /// Whether at least one enabled type is under a limited-history grant.
    /// Drives the range picker's annotation only — never hides or disables a
    /// preset, since the limitation can be per type.
    var hasLimitedHistoryAccess: Bool { !historyAccessFloors.isEmpty }

    /// The one floor to clamp the custom date picker's lower bound to. `nil`
    /// whenever the grant is mixed across enabled types.
    var commonHistoryAccessFloor: Date? {
        let types = HealthTypeRegistry.shared.all.filter { enabledTypeIDs.contains($0.identifier) }
        guard !types.isEmpty else { return nil }
        let floors = types.map { historyAccessFloors[$0.identifier] }
        guard let sharedFloor = floors[0] else { return nil }
        guard floors.allSatisfy({ $0 == sharedFloor }) else { return nil }
        return sharedFloor
    }

    /// Footer copy for the range picker when at least one enabled type is
    /// limited. Deliberately never suggests hiding/disabling a preset.
    var historyAccessFooterText: String {
        if let floor = commonHistoryAccessFloor {
            return "iOS is currently only letting Conduit read history back to \(floor.formatted(date: .abbreviated, time: .omitted)) for your enabled data types. A range further back will still stage everything iOS allows. To go further, widen access later in Settings → Privacy & Security → Health → Conduit."
        }
        return "iOS is currently limiting how far back Conduit can read history for at least one enabled data type (this can vary by type). A range further back will still stage everything iOS allows for each type. To go further, widen access later in Settings → Privacy & Security → Health → Conduit."
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

        // Store bearer token in Keychain, save webhook config row — ONLY when the
        // user actually configured a webhook. On the "Skip for now" path both
        // fields are empty, so we write no webhook_config row: the app still
        // completes onboarding and is fully usable, and the sync path skips
        // capture gracefully until a webhook is added later in Settings.
        if !webhookURL.isEmpty && !tokenInput.isEmpty {
            let keychainRef = "webhook_bearer_token"
            guard appState.keychain.setWebhookBearerToken(tokenInput) else {
                throw OnboardingError.keychainWriteFailed
            }
            var config = WebhookConfig.makeDefault(url: webhookURL, bearerTokenKeychainRef: keychainRef)
            let webhookDAO = WebhookConfigDAO(appState.database)
            try webhookDAO.save(&config)
        }

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
            // Driven through ImportRunner so this import gets the same durable
            // resume point and truthful outcome as the Settings one — its status
            // is then visible (and resumable) in Settings → Import History.
            let runner = ImportRunner(database: appState.database, engine: appState.syncEngine)
            let range = importRange
            Task.detached(priority: .utility) {
                _ = await runner.start(range: range, since: since, types: enabledTypes)
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
