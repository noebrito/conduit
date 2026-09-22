import Foundation
import GRDB
import HealthKit
import Observation
import WidgetKit
import os

private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "AppState")

/// Top-level app state shared across all screens via SwiftUI environment.
///
/// Holds the database, sync engine, and onboarding state. Created once on launch
/// in `ConduitApp` and propagated down the view tree with `.environment(appState)`.
@Observable
final class AppState {
    static let shared: AppState = {
        do {
            let db = try AppDatabase.makeShared()
            return AppState(database: db)
        } catch {
            logger.fault("Failed to open database: \(error.localizedDescription, privacy: .public)")
            fatalError("Cannot open Conduit database: \(error)")
        }
    }()

    let database: AppDatabase
    let keychain: KeychainStore = .shared
    /// Shared HealthKit handle used by both the sync engine (reads) and the
    /// observer coordinator (observer queries + background delivery).
    let healthStore: HKHealthStore
    let syncEngine: SyncEngine
    /// Registers the HealthKit observer queries that actually drive data capture.
    /// Without starting this, nothing is ever read or enqueued (§4.4).
    let observerCoordinator: ObserverCoordinator
    /// Keeps a paused "Import history" run resumable across backgrounding: takes
    /// the checkpoint assertion, schedules the BGProcessingTask resume, and
    /// auto-resumes on foreground. See `ImportBackgroundCoordinator`.
    let importBackground: ImportBackgroundCoordinator

    private(set) var isOnboardingComplete: Bool

    /// The current sync status, recomputed on every relevant database change by
    /// the one observation this app runs for it.
    ///
    /// Process-lifetime and owned here — not by `HomeViewModel`, which only
    /// exists while Home is on screen — so every path that changes status
    /// (observer wakes, `BGAppRefreshTask`, foreground sync) is covered even
    /// when Home was never opened this launch. Home reads this rather than
    /// opening a second observation over the same tables: both wanted the
    /// identical fetch, and a duplicate would scan the outbox state index twice
    /// per committed transaction for the rest of the process lifetime.
    ///
    /// The defaults stand in for the window between launch and the observation's
    /// first (asynchronous) value; the initial read stays off the main thread
    /// because a bulk import's in-flight write would otherwise stall launch.
    private(set) var status = HomeViewModel.StatusSnapshot(
        pending: 0,
        failed: 0,
        today: 0,
        todayStart: StagedDailyCountDAO.day(for: Date()),
        lastSynced: nil,
        status: .idle
    )

    private var statusSnapshotCancellable: AnyDatabaseCancellable?
    /// What the App Group container already holds, so the reload gate compares
    /// against the snapshot the widget is actually showing rather than against
    /// "nothing yet". Seeded from the container in
    /// `startStatusSnapshotObservation`: background launches are the dominant
    /// case (≥96 `BGAppRefreshTask` wakes/day plus HealthKit observer wakes),
    /// and each one starts the observation fresh and receives an initial value,
    /// so a purely in-memory nil would make every wake look like a first-ever
    /// snapshot and spend a reload the gate exists to withhold.
    private var lastPersistedStatusSnapshot: ConduitStatusSnapshot?

    init(database: AppDatabase) {
        let store = HKHealthStore()
        self.database = database
        self.healthStore = store
        let engine = SyncEngine(database: database, store: store)
        self.syncEngine = engine
        self.observerCoordinator = ObserverCoordinator(store: store, syncEngine: engine)
        self.importBackground = ImportBackgroundCoordinator(database: database, engine: engine)
        self.isOnboardingComplete = UserDefaults.standard.bool(forKey: "conduit.onboardingComplete")
        startStatusSnapshotObservation()
    }

    // MARK: - Lock Screen widget status snapshot

    /// Recomputes `status` on every relevant DB change, publishes it for Home,
    /// and writes the widget's snapshot to the App Group container. Reuses
    /// `HomeViewModel.deriveStatus` and `SettingsViewModel.statusTitle(for:)`
    /// verbatim rather than inventing new wording for the same states.
    private func startStatusSnapshotObservation() {
        let observation = ValueObservation.tracking { db -> (HomeViewModel.StatusSnapshot, String?) in
            let home = try HomeViewModel.fetchStatus(db)
            let importRun = try ImportRunState.fetchOne(db, key: ImportProgressDAO.singletonID)
            return (home, AppState.importHeadline(for: importRun))
        }

        lastPersistedStatusSnapshot = ConduitStatusSnapshot.readFromAppGroup()
        statusSnapshotCancellable = observation.start(
            in: database.dbWriter,
            onError: { error in
                logger.error("Status snapshot observation error: \(error.localizedDescription, privacy: .public)")
            },
            onChange: { [weak self] home, importHeadline in
                self?.status = home
                self?.persistStatusSnapshot(AppState.widgetSnapshot(from: home, importHeadline: importHeadline))
            }
        )
    }

    /// Project the app's status onto the widget's transport type.
    static func widgetSnapshot(
        from home: HomeViewModel.StatusSnapshot,
        importHeadline: String?
    ) -> ConduitStatusSnapshot {
        let syncStatus: ConduitStatusSnapshot.SyncStatus
        let syncedAt: Date?
        switch home.status {
        case .idle:
            syncStatus = .idle
            syncedAt = nil
        case .synced(let date):
            syncStatus = .synced
            syncedAt = date
        case .error:
            syncStatus = .error
            syncedAt = home.lastSynced
        }

        return ConduitStatusSnapshot(
            syncStatus: syncStatus,
            lastSyncedAt: syncedAt,
            pendingCount: home.pending,
            failedCount: home.failed,
            stagedTodayCount: home.today,
            stagedTodayDay: home.todayStart,
            importStatusHeadline: importHeadline
        )
    }

    /// The import headline the Lock Screen surfaces, or `nil` when the most
    /// recent run has nothing this surface should say.
    ///
    /// `import_run` is a singleton row that survives until a brand-new run
    /// begins, so any headline returned here pins the widget's second line —
    /// it outranks the pending count in `ConduitStatusSnapshot.secondLine` —
    /// until the user imports again. Only a run that is live or still
    /// actionable earns that: a completed run has nothing to report, and a run
    /// the user deliberately cancelled is not a condition worth advertising
    /// over a stuck upload queue, which is the silent failure this surface
    /// exists to expose. Every other stop cause names a problem the user can
    /// still act on and keeps its priority.
    static func importHeadline(for run: ImportRunState?) -> String? {
        guard let run, run.status != .completed, run.stopCause != .userCancelled else { return nil }
        return SettingsViewModel.statusTitle(for: run)
    }

    /// Writes the snapshot to the App Group container, then reloads the
    /// widget's timelines only on a state-*class* change (an error
    /// appearing/clearing, the import headline changing, the failed count
    /// crossing zero, or the first sync leaving `.idle`) — never on every
    /// stamp, since Conduit's background cadence would exhaust the widget's
    /// daily reload budget otherwise.
    ///
    /// A failed write leaves the container holding the *previous* snapshot, so
    /// it also leaves `lastPersistedStatusSnapshot` where it is: reloading would
    /// only redraw stale content, and advancing the bookkeeping would make the
    /// next successful write of the same state class look like no change at all,
    /// suppressing the reload that actually matters.
    private func persistStatusSnapshot(_ snapshot: ConduitStatusSnapshot) {
        do {
            try snapshot.writeToAppGroup()
        } catch {
            logger.error("Failed to write status snapshot: \(error.localizedDescription, privacy: .public)")
            return
        }
        if ConduitStatusSnapshot.shouldReloadTimelines(previous: lastPersistedStatusSnapshot, next: snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        lastPersistedStatusSnapshot = snapshot
    }

    /// Start HealthKit data capture for the currently-enabled data types.
    ///
    /// Reads the persisted `data_type_config` (the set onboarding authorized —
    /// not the full registry) and starts observer queries for it. Starting the
    /// observers also performs an initial anchored read. Capture is
    /// **forward-only by default**: the first (anchor-less) read seeds a capture
    /// floor of "now", so only samples created at/after setup are staged — no
    /// historical backfill. Idempotent: safe to call on every launch and again
    /// right after onboarding (the forward seed only fires on the very first
    /// read per type, gated on a nil stored anchor).
    func startDataCapture() {
        let enabledIDs: Set<String>
        do {
            enabledIDs = Set(try DataTypeConfigDAO(database).enabled().map(\.hkTypeId))
        } catch {
            logger.error("Failed to load enabled data types: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !enabledIDs.isEmpty else {
            logger.info("No enabled data types — nothing to capture")
            return
        }
        let types = HealthTypeRegistry.shared.all.filter { enabledIDs.contains($0.identifier) }
        observerCoordinator.start(for: types)
    }

    /// Tear down all active observer queries (used when onboarding is reset).
    func stopDataCapture() {
        observerCoordinator.stop()
    }

    // MARK: - Registry reconcile (upgrade path for new data types)

    /// UserDefaults key holding the signature of the registry's authorization
    /// read set at the last time we requested HealthKit authorization. When the
    /// current signature differs (a new type grew the set), `reconcileRegistry`
    /// re-requests auth exactly once.
    static let authorizedSignatureKey = "conduit.lastAuthorizedRegistrySignature"

    /// Bring an existing (already-onboarded) user's persisted config **and**
    /// HealthKit authorization up to date with the current registry, so data
    /// types added in an app update (e.g. `appleStandHour` from #502) start
    /// capturing without the user having to re-run onboarding.
    ///
    /// Two independent gates, **both required** — auth without an enabled row
    /// means no observer is ever started; an enabled row without auth means the
    /// read returns nothing:
    ///
    /// 1. **Auto-enable newly-registered types.** Every registry type with no
    ///    `data_type_config` row yet is inserted **enabled** (default-on),
    ///    matching fresh-install onboarding and the registry's "enabled by
    ///    default" convention. Existing rows (enabled *or* disabled) are left
    ///    untouched, so a user's deliberate opt-outs are preserved.
    /// 2. **Re-request HealthKit authorization when the authorized set grew.**
    ///    Gated on a persisted signature of `HealthTypeRegistry.readTypes`, so an
    ///    existing user gets exactly **one** system permission sheet for the new
    ///    type(s) — not a sheet on every launch. The signature is persisted only
    ///    after a successful request, so a failure (e.g. HK unavailable) retries
    ///    next launch. Fresh installs seed the signature in
    ///    `OnboardingViewModel.finishOnboarding`, so they never get a duplicate
    ///    prompt right after onboarding.
    ///
    /// Call this **before** `startDataCapture()` on the returning-user launch
    /// path so the newly-enabled types get observers immediately.
    @MainActor
    func reconcileRegistry(registry: HealthTypeRegistry = .shared) async {
        await reconcileRegistry(
            registry: registry,
            defaults: .standard,
            authorize: { [healthStore] types in
                try await HealthKitAuthorizer(store: healthStore).request(for: types)
            }
        )
    }

    /// Testable core of `reconcileRegistry` with the two side-effecting
    /// dependencies injected: the `UserDefaults` holding the auth signature, and
    /// the authorization request itself (so tests can assert *whether and how
    /// often* it fires without touching a real `HKHealthStore`).
    @MainActor
    func reconcileRegistry(
        registry: HealthTypeRegistry,
        defaults: UserDefaults,
        authorize: (_ types: [HealthDataType]) async throws -> Void
    ) async {
        // (1) Auto-enable registry types that have no row yet.
        do {
            try AppState.enableNewlyRegisteredTypes(registry: registry, dao: DataTypeConfigDAO(database))
        } catch {
            logger.error("reconcileRegistry: auto-enable failed: \(error.localizedDescription, privacy: .public)")
        }

        // (2) Re-request authorization only when the authorized set has grown.
        let signature = AppState.authorizedTypesSignature(registry: registry)
        guard defaults.string(forKey: AppState.authorizedSignatureKey) != signature else { return }

        let enabledTypes: [HealthDataType]
        do {
            let enabledIDs = Set(try DataTypeConfigDAO(database).enabled().map(\.hkTypeId))
            enabledTypes = registry.all.filter { enabledIDs.contains($0.identifier) }
        } catch {
            logger.error("reconcileRegistry: loading enabled types failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !enabledTypes.isEmpty else { return }

        do {
            try await authorize(enabledTypes)
            // Persist only after a successful request so a failure retries next launch.
            defaults.set(signature, forKey: AppState.authorizedSignatureKey)
        } catch {
            logger.error("reconcileRegistry: authorization request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stable signature of the registry's authorization read set. When a newly
    /// registered type grows `HealthTypeRegistry.readTypes`, this string changes,
    /// which is the trigger for `reconcileRegistry` to re-request authorization.
    static func authorizedTypesSignature(registry: HealthTypeRegistry = .shared) -> String {
        registry.readTypes.map(\.identifier).sorted().joined(separator: ",")
    }

    /// Insert a default-on `data_type_config` row for every registry type that
    /// has no row yet. Existing rows are left untouched. Pure DB work, injectable
    /// so the reconcile behavior is unit-testable without a HealthKit store.
    static func enableNewlyRegisteredTypes(registry: HealthTypeRegistry = .shared, dao: DataTypeConfigDAO) throws {
        let savedIDs = Set(try dao.all().map(\.hkTypeId))
        for type in registry.all where !savedIDs.contains(type.identifier) {
            try dao.setEnabled(true, hkTypeId: type.identifier)
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "conduit.onboardingComplete")
        isOnboardingComplete = true
    }

    func resetOnboarding() {
        stopDataCapture()
        UserDefaults.standard.set(false, forKey: "conduit.onboardingComplete")
        isOnboardingComplete = false
    }

    /// One-time remediation: purge the entire outbox and reset every type's
    /// anchor + capture floor so capture resumes **forward-only**.
    ///
    /// Flipping the read path to forward-only does nothing for a device that
    /// already staged its full Apple Health history under the old all-history
    /// backfill — those millions of rows keep uploading. This drains them and
    /// re-seeds capture from "now".
    ///
    /// Sequence (safe ordering):
    /// 1. Stop capture so no observer wake races the purge.
    /// 2. Reconcile in-flight uploads back to a known state.
    /// 3. Purge the outbox and clear all anchors + capture floors (off the main
    ///    thread — an affected device has millions of rows to delete).
    /// 4. Restart capture — anchors are nil, so each type re-seeds to "now".
    func resetSyncQueue() {
        stopDataCapture()
        // Reset any inflight rows whose background task is gone; deleteAll below
        // removes every row regardless, but this keeps the session consistent.
        Uploader.shared.reconcileInflight()
        let database = self.database
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let deleted = try OutboxDAO(database).deleteAll()
                try DataTypeConfigDAO(database).resetAllAnchors()
                // Zero the "Staged today" tally too — this destructive reset wipes
                // all staging state, so the counter should start fresh alongside
                // the emptied outbox rather than report pre-reset stages.
                try StagedDailyCountDAO(database).deleteAll()
                logger.info("resetSyncQueue: purged \(deleted) outbox rows and reset all anchors")
            } catch {
                logger.error("resetSyncQueue failed: \(error.localizedDescription, privacy: .public)")
            }
            // Restart capture forward-only once the purge has committed.
            await MainActor.run { self?.startDataCapture() }
        }
    }
}
