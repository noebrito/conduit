import Foundation
import Observation
import os

private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "SettingsViewModel")

/// Drives the Settings screen — webhook config, sync intervals, data types, about.
@Observable
final class SettingsViewModel {
    enum SettingsError: LocalizedError {
        case keychainWriteFailed

        var errorDescription: String? {
            "Couldn't securely save your webhook token. Please try again."
        }
    }

    // Webhook section
    var webhookURL: String = ""
    var tokenInput: String = ""
    var testResult: WebhookTester.Result? = nil
    var isTesting = false

    // Sync section
    var minIntervalSeconds: Int = 900
    var batchMaxSize: Int = 500
    var forceFlushThreshold: Int = 200
    var outboxCap: Int = 50_000

    // Data types
    var enabledTypeIDs: Set<String> = []
    private var dataTypeConfigsByID: [String: DataTypeConfig] = [:]

    // Import history (explicit opt-in)
    var importRange: ImportRange = .last30Days
    var customImportStart: Date = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
    var isImporting = false
    var importProgressText: String = ""
    var importStagedCount: Int = 0
    var importHitCap = false
    var importCancelled = false
    var importFinished = false
    var importError: String? = nil

    /// The running staged from types already fully imported, so per-type
    /// `onProgress` can report a monotonic total across the whole run.
    private var importBaseline = 0
    private var importTask: Task<Void, Never>?

    // About
    var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(build))"
    }

    var exportConfigJSON: String? = nil

    private let appState: AppState
    private var currentWebhookID: Int64? = nil

    init(appState: AppState) {
        self.appState = appState
    }

    func load() {
        do {
            let webhookDAO = WebhookConfigDAO(appState.database)
            if let config = try webhookDAO.first() {
                webhookURL = config.url
                // Never expose the stored token — field stays empty (user must paste to change)
                minIntervalSeconds = config.minIntervalSeconds
                batchMaxSize = config.batchMaxSize
                forceFlushThreshold = config.forceFlushThreshold
                outboxCap = config.outboxCap
                currentWebhookID = config.id
            }

            let typeDAO = DataTypeConfigDAO(appState.database)
            let configs = try typeDAO.all()
            // Reflect the REAL persisted enabled state — a type with no
            // data_type_config row is not being captured, so it must not display
            // as enabled. The launch-time reconcileRegistry() writes a default-on
            // row for every newly-registered type before Settings is reachable,
            // so post-onboarding every type has a row and this is exact. (The old
            // "no row defaults to enabled" union masked new types as enabled while
            // startDataCapture — which reads only persisted rows — never captured
            // them.)
            enabledTypeIDs = Set(configs.filter(\.enabled).map(\.hkTypeId))
            dataTypeConfigsByID = Dictionary(uniqueKeysWithValues: configs.map { ($0.hkTypeId, $0) })
        } catch {
            logger.error("Settings load error: \(error.localizedDescription, privacy: .public)")
        }
    }

    func save() throws {
        let webhookDAO = WebhookConfigDAO(appState.database)
        if var existing = try webhookDAO.first() {
            existing.url = webhookURL
            existing.minIntervalSeconds = minIntervalSeconds
            existing.batchMaxSize = batchMaxSize
            existing.forceFlushThreshold = forceFlushThreshold
            existing.outboxCap = outboxCap
            try webhookDAO.save(&existing)
            currentWebhookID = existing.id

            if !tokenInput.isEmpty {
                guard appState.keychain.setWebhookBearerToken(tokenInput) else {
                    throw SettingsError.keychainWriteFailed
                }
                tokenInput = ""
            }
        } else {
            guard !webhookURL.isEmpty else { return }
            let ref = "webhook_bearer_token"
            if !tokenInput.isEmpty {
                guard appState.keychain.setWebhookBearerToken(tokenInput) else {
                    throw SettingsError.keychainWriteFailed
                }
                tokenInput = ""
            }
            var config = WebhookConfig(
                id: nil,
                url: webhookURL,
                bearerTokenKeychainRef: ref,
                minIntervalSeconds: minIntervalSeconds,
                batchMaxSize: batchMaxSize,
                forceFlushThreshold: forceFlushThreshold,
                outboxCap: outboxCap,
                createdAt: Date(),
                updatedAt: Date()
            )
            let dao = WebhookConfigDAO(appState.database)
            try dao.save(&config)
        }

        let typeDAO = DataTypeConfigDAO(appState.database)
        for type in HealthTypeRegistry.shared.all {
            let enabled = enabledTypeIDs.contains(type.identifier)
            try typeDAO.setEnabled(enabled, hkTypeId: type.identifier)
            if enabled {
                recordTypeEnabledDate(type.identifier)
            }
        }
    }

    func toggleType(_ typeID: String) {
        if enabledTypeIDs.contains(typeID) {
            enabledTypeIDs.remove(typeID)
        } else {
            enabledTypeIDs.insert(typeID)
        }
    }

    func testConnection() async {
        let token: String
        if !tokenInput.isEmpty {
            token = tokenInput
        } else if let stored = appState.keychain.webhookBearerToken {
            token = stored
        } else {
            testResult = WebhookTester.Result(statusCode: 0, latencyMs: 0, error: "No token configured")
            return
        }
        isTesting = true
        testResult = nil
        testResult = await WebhookTester.test(url: webhookURL, token: token)
        isTesting = false
    }

    func buildExportJSON() {
        do {
            let webhookDAO = WebhookConfigDAO(appState.database)
            let typeDAO = DataTypeConfigDAO(appState.database)
            guard let config = try webhookDAO.first() else {
                exportConfigJSON = "{}"
                return
            }
            let types = try typeDAO.all()
            let export: [String: Any] = [
                "schemaVersion": "v1",
                "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "webhook": [
                    "url": config.url,
                    "minIntervalSeconds": config.minIntervalSeconds,
                    "batchMaxSize": config.batchMaxSize,
                    "forceFlushThreshold": config.forceFlushThreshold,
                    "outboxCap": config.outboxCap,
                ],
                "dataTypes": types.map { ["hkTypeId": $0.hkTypeId, "enabled": $0.enabled] },
            ]
            let data = try JSONSerialization.data(withJSONObject: export, options: [.prettyPrinted, .sortedKeys])
            exportConfigJSON = String(data: data, encoding: .utf8)
        } catch {
            exportConfigJSON = "{ \"error\": \"\(error.localizedDescription)\" }"
        }
    }

    var hasToken: Bool { appState.keychain.webhookBearerToken != nil }

    func typeEnabledDate(_ typeID: String) -> Date? {
        UserDefaults.standard.object(forKey: "conduit.typeEnabledAt.\(typeID)") as? Date
    }

    func typeLastSyncDate(_ typeID: String) -> Date? {
        dataTypeConfigsByID[typeID]?.lastSyncAt
    }

    private func recordTypeEnabledDate(_ typeID: String) {
        let key = "conduit.typeEnabledAt.\(typeID)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(Date(), forKey: key)
        }
    }

    // MARK: - Import history (explicit opt-in)

    /// The user-chosen start date for the current range. `nil` means "All time"
    /// (no floor), which the reader turns into a predicate-less all-history read.
    var importStartDate: Date? {
        importRange.startDate(now: Date(), customStart: customImportStart)
    }

    /// Whether the chosen range warrants a stronger volume warning before it
    /// runs. "All time" and long custom windows can stage very large volumes.
    var importNeedsVolumeWarning: Bool {
        switch importRange {
        case .allTime:
            return true
        case .lastYear:
            return true
        case .custom:
            // Windows longer than ~180 days can be large.
            guard let start = importStartDate else { return true }
            return Date().timeIntervalSince(start) > 180 * 24 * 60 * 60
        case .last30Days, .last90Days:
            return false
        }
    }

    /// Start a paged, newest-first, cap-bounded historical import for every
    /// enabled type over the chosen range. Runs in a cancellable `Task` so the UI
    /// can offer a Cancel button; drives `SyncEngine.importHistory` per type and
    /// never disturbs the live forward-capture anchors.
    @MainActor
    func startImport() {
        guard !isImporting else { return }
        importTask = Task { await self.runImport() }
    }

    /// Cancel an in-progress import. The importer stops promptly at the next page
    /// boundary; anything already staged keeps uploading.
    @MainActor
    func cancelImport() {
        importTask?.cancel()
    }

    @MainActor
    func runImport() async {
        guard !isImporting else { return }
        isImporting = true
        importFinished = false
        importHitCap = false
        importCancelled = false
        importError = nil
        importStagedCount = 0
        importBaseline = 0
        defer {
            isImporting = false
            importFinished = true
            importTask = nil
        }

        let since = importStartDate
        let types = HealthTypeRegistry.shared.all.filter { enabledTypeIDs.contains($0.identifier) }
        guard !types.isEmpty else {
            importProgressText = "No data types are enabled."
            return
        }

        let engine = appState.syncEngine
        for (index, type) in types.enumerated() {
            if Task.isCancelled { break }
            importProgressText = "Importing \(type.displayName) (\(index + 1)/\(types.count))…"
            let summary = await engine.importHistory(
                typeIdentifier: type.identifier,
                since: since,
                onProgress: { [weak self] stagedForType in
                    Task { @MainActor in
                        guard let self else { return }
                        self.importStagedCount = self.importBaseline + stagedForType
                    }
                }
            )
            importBaseline += summary.staged
            importStagedCount = importBaseline
            if summary.cancelled {
                importCancelled = true
                importProgressText = "Import cancelled after \(importBaseline.formatted()) samples. Anything already queued will still upload."
                return
            }
            if summary.hitCap {
                importHitCap = true
                importProgressText = "The upload queue is still draining after \(importBaseline.formatted()) samples — stopping for now. It keeps uploading in the background; import again later to finish the range."
                return
            }
        }
        if Task.isCancelled {
            importCancelled = true
            importProgressText = "Import cancelled after \(importBaseline.formatted()) samples. Anything already queued will still upload."
            return
        }
        importProgressText = "Imported \(importBaseline.formatted()) samples, newest first."
    }
}

/// How far back an explicit "Import history" should reach. The chosen start date
/// becomes the read predicate floor; `.allTime` imports everything (no floor).
enum ImportRange: String, CaseIterable, Identifiable {
    case last30Days
    case last90Days
    case lastYear
    case allTime
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .last30Days: return "Last 30 days"
        case .last90Days: return "Last 90 days"
        case .lastYear: return "Last year"
        case .allTime: return "All time"
        case .custom: return "Custom start date"
        }
    }

    /// Resolve the window start. `nil` for "All time" (no date floor). For
    /// presets, `now` minus the preset span; for custom, the user's date.
    func startDate(now: Date, customStart: Date) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .last30Days: return calendar.date(byAdding: .day, value: -30, to: now)
        case .last90Days: return calendar.date(byAdding: .day, value: -90, to: now)
        case .lastYear: return calendar.date(byAdding: .year, value: -1, to: now)
        case .allTime: return nil
        case .custom: return customStart
        }
    }
}

extension SettingsViewModel {
    static let minIntervalOptions: [(label: String, seconds: Int)] = [
        ("5 minutes", 300),
        ("15 minutes", 900),
        ("30 minutes", 1800),
        ("1 hour", 3600),
        ("4 hours", 14400),
        ("Manual only", Int.max / 2),
    ]
}
