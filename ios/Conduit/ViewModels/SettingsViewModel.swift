import Foundation
import GRDB
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
    /// True from the moment Cancel is tapped until the run actually stops.
    /// Cancellation is a flag the run polls at page/type boundaries, so there is a
    /// real gap before it takes effect — the UI must say so instead of looking
    /// like the tap did nothing.
    var isCancellingImport = false
    /// The reason the last import FAILED. Set from the runner's failure outcome
    /// (it used to be declared, reset, and read by the UI but never assigned —
    /// dead state that let a failure render as a success).
    var importError: String? = nil

    /// The persisted state of the most recent run, loaded from the database — so
    /// the status the user sees survives backgrounding, force-quit and relaunch
    /// instead of resetting to "never imported".
    var importRun: ImportRunState? = nil

    private var importTask: Task<Void, Never>?
    private var importObservation: AnyDatabaseCancellable?
    /// True once this view model has rendered a run's terminal copy, which the
    /// run row alone can't reproduce (cancelled / queue-still-draining). Cleared
    /// the moment a new run starts.
    private var hasLocalOutcomeCopy = false
    /// Which run that terminal copy describes. A later observation tick for the
    /// SAME run must not clobber it; a tick for a different run must.
    private var outcomeCopyRunId: String?

    // About
    var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(build))"
    }

    var exportConfigJSON: String? = nil

    private let appState: AppState
    private var currentWebhookID: Int64? = nil

    private let importCoordinator: ImportRunCoordinator

    init(appState: AppState, importCoordinator: ImportRunCoordinator = .shared) {
        self.appState = appState
        self.importCoordinator = importCoordinator
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

        loadImportState()
        observeImportState()
    }

    /// Keep the Import History screen live off the database, so a run driven by
    /// ANY part of the app — including onboarding's detached task — updates its
    /// status, staged count and progress copy here as it checkpoints, instead of
    /// freezing on the snapshot taken at `.onAppear`.
    func observeImportState() {
        guard importObservation == nil else { return }
        // `checkpoint` writes the run row and the per-type rows in ONE
        // transaction, so tracking the run alone still sees every update.
        let observation = ValueObservation.tracking { db in
            try ImportRunState.fetchOne(db, key: ImportProgressDAO.singletonID)
        }
        importObservation = observation.start(
            in: appState.database.dbWriter,
            onError: { error in
                logger.error("Import observation error: \(error.localizedDescription, privacy: .public)")
            },
            onChange: { [weak self] run in
                Task { @MainActor [weak self] in
                    self?.applyObservedImportState(run: run)
                }
            }
        )
    }

    @MainActor
    private func applyObservedImportState(run: ImportRunState?) {
        importRun = run
        if run?.status != .running { isCancellingImport = false }
        // A locally-driven run publishes its own live copy through onProgress.
        guard !isImporting, let run else { return }
        importStagedCount = run.stagedCount
        importError = run.status == .failed ? run.failureReason : nil
        guard !isCancellingImport else { return }
        if let describedRun = outcomeCopyRunId, describedRun != run.runId {
            hasLocalOutcomeCopy = false
        }
        guard !hasLocalOutcomeCopy else { return }
        importProgressText = Self.statusText(for: run)
    }

    func stopObservingImportState() {
        importObservation?.cancel()
        importObservation = nil
    }

    deinit {
        importObservation?.cancel()
    }

    /// Read the import's status back out of the database. Called on every load so
    /// a relaunch after an interrupted import shows "interrupted / resumable"
    /// rather than a blank Import button, and a failure keeps its reason.
    ///
    /// - Parameter preserveOutcome: keep the terminal copy the caller just set
    ///   (cancelled / queue-still-draining wording, which the run row can't
    ///   reproduce) while still refreshing the persisted state.
    func loadImportState(preserveOutcome: Bool = false) {
        // Whether a run is live is a property of the RUN (the coordinator's
        // claim), not of this view model — onboarding's import runs in a detached
        // task this view model knows nothing about, and reconciling it here would
        // flip a live run to "interrupted" and offer a duplicate Resume.
        let state = importRunner.loadPersistedState(reconcileStale: !isImporting)
        importRun = state.run
        // ONLY a user cancellation may show the cancelling copy. A background
        // pause also asks the run to stop (so the paging loop stops at its next
        // boundary), but telling the user their import is "cancelling" because
        // they switched apps would be plainly false — and the gap is real, since
        // the run can sit in the drain wait for minutes before it observes it.
        isCancellingImport = state.run?.status == .running
            && importCoordinator.requestedStopReason == .userCancelled
        guard !isImporting, let run = state.run else { return }
        importStagedCount = run.stagedCount
        importError = run.status == .failed ? run.failureReason : nil
        // Only a resumable run's range may be restored: a finished run must never
        // silently revert a fresh picker choice (or make "Start Over" quote the
        // wrong range).
        if run.status.isResumable, let range = ImportRange(rawValue: run.rangeId) {
            importRange = range
        }
        guard !preserveOutcome else {
            markLocalOutcomeCopy()
            return
        }
        hasLocalOutcomeCopy = false
        outcomeCopyRunId = nil
        importProgressText = isCancellingImport ? Self.cancellingText : Self.statusText(for: run)
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

    /// Whether an import is being driven anywhere in this process — including
    /// onboarding's detached run, which this view model does not own.
    ///
    /// Derived from the OBSERVED run row rather than the coordinator's claim: the
    /// claim isn't observable, so SwiftUI would never re-render when a foreign run
    /// starts or ends. `importRun` is kept live by `observeImportState`, and a
    /// `.running` row is only truthful because the stale-run reconcile is itself
    /// claim-gated.
    var isImportActive: Bool { isImporting || importRun?.status == .running }

    /// The authoritative guard for actions: the observed row OR the coordinator's
    /// claim. Checked at tap time, so it can be stricter than what the UI shows.
    private var isImportBlocked: Bool { isImportActive || importRunner.isRunningInThisProcess }

    /// Whether the last run can be picked up where it stopped. Never offered
    /// while a run is in flight, so Resume can't start a second execution over
    /// the same run.
    var canResumeImport: Bool {
        guard let run = importRun, !isImportBlocked else { return false }
        return run.status.isResumable
    }

    /// The date every enabled type has been imported back to at least — the
    /// conservative floor, `nil` until every type has started.
    var importOldestReached: Date? { importRun?.oldestReachedAt }

    /// Start a paged, newest-first, cap-bounded historical import for every
    /// enabled type over the chosen range. Runs in a cancellable `Task` so the UI
    /// can offer a Cancel button; drives `ImportRunner` (which checkpoints a
    /// durable resume point per page) and never disturbs the live forward-capture
    /// anchors.
    @MainActor
    func startImport() {
        guard !isImportBlocked else { return }
        importTask = Task { await self.runImport(resuming: false) }
    }

    /// Continue the persisted, interrupted run from its stored per-type cursors
    /// instead of re-reading the range from the newest end.
    @MainActor
    func resumeImport() {
        guard canResumeImport else { return }
        importTask = Task { await self.runImport(resuming: true) }
    }

    /// Discard the persisted run so the next import starts fresh.
    @MainActor
    func discardImportRun() {
        guard !isImportBlocked else { return }
        importRunner.clear()
        importRun = nil
        importError = nil
        importStagedCount = 0
        importProgressText = ""
        hasLocalOutcomeCopy = false
        outcomeCopyRunId = nil
    }

    /// Cancel the in-progress import. The importer stops promptly at the next page
    /// boundary; anything already staged keeps uploading, and the persisted
    /// cursor means the next run resumes rather than restarts.
    ///
    /// Cancelling goes through the coordinator as well as this view model's own
    /// task handle, so Cancel stops the run whichever path started it — a
    /// `Task.cancel()` alone can't reach onboarding's detached import.
    @MainActor
    func cancelImport() {
        guard !isCancellingImport else { return }
        isCancellingImport = true
        importProgressText = Self.cancellingText
        importTask?.cancel()
        importRunner.requestCancellation()
    }

    @MainActor
    func runImport(resuming: Bool = false) async {
        guard !isImportBlocked else { return }
        isImporting = true
        isCancellingImport = false
        importError = nil
        hasLocalOutcomeCopy = false
        outcomeCopyRunId = nil
        defer {
            isImporting = false
            importTask = nil
            // Refresh the persisted state, but keep the specific terminal copy
            // the body just set — statusText has no cancelled / queue-draining
            // variant, so clobbering it would replace the honest reason with the
            // generic "interrupted" line.
            loadImportState(preserveOutcome: true)
        }

        let types = HealthTypeRegistry.shared.all.filter { enabledTypeIDs.contains($0.identifier) }
        guard !types.isEmpty else {
            importProgressText = "No data types are enabled."
            markLocalOutcomeCopy()
            return
        }

        let runner = importRunner
        let onProgress: @Sendable (ImportRunner.Progress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                self.importStagedCount = progress.stagedTotal
                guard !self.isCancellingImport else { return }
                self.importProgressText =
                    "Importing \(progress.typeDisplayName) (\(progress.typeIndex + 1)/\(progress.typeCount))…"
            }
        }

        let outcome: ImportRunner.Outcome
        if resuming {
            outcome = await runner.resume(types: types, onProgress: onProgress)
        } else {
            importStagedCount = 0
            outcome = await runner.start(
                range: importRange,
                since: importStartDate,
                types: types,
                onProgress: onProgress
            )
        }

        // The runner refused because another task (e.g. onboarding's detached
        // import) is already driving a run — nothing was started or reset, so
        // leave the persisted status to speak for itself.
        guard !outcome.alreadyRunning else {
            importProgressText = "An import is already running. Its progress is shown above."
            return
        }

        importStagedCount = outcome.staged
        isCancellingImport = false
        // A failure is reported AS a failure — never as a zero-sample success.
        importError = outcome.failureReason
        importProgressText = Self.outcomeText(outcome)
        markLocalOutcomeCopy()
    }

    private func markLocalOutcomeCopy() {
        hasLocalOutcomeCopy = true
        outcomeCopyRunId = importRun?.runId
    }

    /// The runner that owns durable import progress. Recreated per access — it is
    /// a thin wrapper over the shared database and sync engine.
    private var importRunner: ImportRunner {
        ImportRunner(
            database: appState.database,
            engine: appState.syncEngine,
            coordinator: importCoordinator
        )
    }

    // MARK: - Import status copy

    /// Provisional, in-flight copy for the gap between tapping Cancel and the run
    /// reaching a page boundary. Deliberately NOT protected by
    /// `hasLocalOutcomeCopy`: it is transient by construction, so the terminal
    /// status replaces it the moment the run actually stops.
    static let cancellingText = "Cancelling — finishing the page it's already reading…"

    /// One honest sentence for a finished/interrupted run.
    static func outcomeText(_ outcome: ImportRunner.Outcome) -> String {
        let count = outcome.staged.formatted()
        switch outcome.status {
        case .failed:
            return "Import failed after \(count) samples. \(outcome.failureReason ?? "Unknown error.") Your existing data is untouched — resume to finish the range."
        case .completed:
            return "Imported \(count) samples, newest first."
        case .running:
            return "Importing…"
        case .interrupted:
            if outcome.cancelled {
                return Self.cancelledText(count: count)
            }
            if outcome.pausedForBackground {
                return Self.pausedText(count: count)
            }
            if outcome.hitCap {
                return Self.queueNotDrainingText(count: count)
            }
            return "Import interrupted after \(count) samples — it didn't finish the range. Resume to continue where it stopped."
        }
    }

    /// Copy for a run iOS paused (backgrounding / an expiring background window).
    ///
    /// Careful with the promise here: Conduit **asks** iOS for a window to
    /// continue in and iOS decides whether to grant one, so this says "when iOS
    /// allows" and leads with the thing that is actually guaranteed — reopening
    /// the app continues it. Never claim it keeps importing while you're away.
    static func pausedText(count: String) -> String {
        "Import paused after \(count) samples — it kept its place. It continues when iOS grants Conduit background time, and as soon as you reopen the app."
    }

    /// Copy for a run the user stopped themselves. It stays cancelled until they
    /// say otherwise, so it never mentions resuming on its own.
    static func cancelledText(count: String) -> String {
        "Import cancelled after \(count) samples. Anything already queued will still upload — resume to finish the range."
    }

    /// Copy for a run that stopped because the upload queue never drained.
    ///
    /// Deliberately says the real cause: this run is NOT auto-resumed, precisely
    /// so a stuck webhook surfaces as something to look at instead of quietly
    /// re-stalling for the whole drain timeout on every launch.
    static func queueNotDrainingText(count: String) -> String {
        "The upload queue is still draining after \(count) samples — paused for now. It keeps uploading in the background; resume to finish the range."
    }

    /// The same honesty, reconstructed from persisted state after a relaunch.
    static func statusText(for run: ImportRunState) -> String {
        let count = run.stagedCount.formatted()
        switch run.status {
        case .completed:
            return "Imported \(count) samples, newest first."
        case .failed:
            return "Import failed after \(count) samples. \(run.failureReason ?? "Unknown error.") Resume to finish the range."
        case .running:
            return "Importing…"
        case .interrupted:
            // An auto-resumable pause is a different (and honest) statement than
            // "interrupted, go tap Resume" — the app really will pick this one up.
            if run.autoResume {
                return pausedText(count: count)
            }
            // A stuck upload queue keeps its specific reason across a relaunch;
            // collapsing it into the generic line loses the one thing the user
            // needs to know to fix it.
            if run.stopCause == .queueNotDraining {
                return queueNotDrainingText(count: count)
            }
            // The user's own Cancel is recorded in the row, so it keeps its
            // wording after a relaunch instead of decaying into the generic
            // "it didn't finish the range" line.
            if run.stopCause == .userCancelled {
                return cancelledText(count: count)
            }
            return "Import interrupted after \(count) samples — it didn't finish the range. Resume to continue where it stopped."
        }
    }

    /// The heading shown above `statusText(for:)`.
    ///
    /// Deliberately decided from the same run row, right beside the sentence it
    /// heads: a headline reading "Import interrupted" over a detail line saying
    /// the run is paused is the incoherent status this work exists to eliminate.
    ///
    /// Reading paused here is a copy decision only — a queue that never drained
    /// is still NOT auto-resumable (that stays iOS-forced pauses only).
    static func statusTitle(for run: ImportRunState) -> String {
        switch run.status {
        case .completed: return "Import complete"
        case .failed: return "Import failed"
        case .running: return "Importing…"
        case .interrupted:
            if run.autoResume || run.stopCause == .queueNotDraining {
                return "Import paused"
            }
            if run.stopCause == .userCancelled {
                return "Import cancelled"
            }
            return "Import interrupted"
        }
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
