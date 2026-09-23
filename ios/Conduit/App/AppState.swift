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
    /// Serializes everything downstream of the observation that is not SwiftUI
    /// state: encoding the snapshot, the App Group write, the reload gate and
    /// its bookkeeping. `ValueObservation` delivers on the main queue, and this
    /// path runs after every committed transaction touching the observed region
    /// — on the order of 10^4 times across a large import — so the file I/O
    /// must not be there. Serial and single, so a write still lands before the
    /// reload that asks the widget to redraw from it.
    @ObservationIgnored
    private let statusSnapshotQueue = DispatchQueue(
        label: "dev.noebrito.Conduit.statusSnapshot",
        qos: .utility
    )
    /// What the App Group container already holds, so the reload gate compares
    /// against the snapshot the widget is actually showing rather than against
    /// "nothing yet". Seeded from the container in `init`: background launches
    /// are the dominant case (≥96 `BGAppRefreshTask` wakes/day plus HealthKit
    /// observer wakes), and each one starts the observation fresh and receives
    /// an initial value, so a purely in-memory nil would make every wake look
    /// like a first-ever snapshot and spend a reload the gate exists to
    /// withhold.
    ///
    /// Owned by `statusSnapshotQueue` — never read or written anywhere else.
    @ObservationIgnored
    private var lastPersistedStatusSnapshot: ConduitStatusSnapshot?
    /// When `lastPersistedStatusSnapshot` was written, so the write gate can
    /// tell "the container is already current enough" from "it is an hour
    /// behind". Left `nil` by the container seed above — the first delivery of
    /// every launch writes, and only then does the interval start counting.
    ///
    /// Owned by `statusSnapshotQueue` — never read or written anywhere else.
    @ObservationIgnored
    private var lastPersistedStatusSnapshotAt: Date?
    /// Consecutive observation failures since the last delivered value, which
    /// is what the restart delay backs off on. Reset on every delivery, so an
    /// unrelated failure much later starts over at the bottom of the backoff.
    ///
    /// Touched only from the observation's own callbacks, which GRDB delivers
    /// on the main queue.
    @ObservationIgnored
    private(set) var statusObservationFailures = 0

    private struct StatusFetchState {
        /// Whether a screen can be showing `status`; until then the outbox
        /// counts are only recounted when the write gate would publish them.
        var isForeground = false
        var lastFullFetch: (home: HomeViewModel.StatusSnapshot, importHeadline: String?, at: Date)?
        /// Whether the observation has fetched since the last flush, so
        /// `flushStatusSnapshot` only recounts when the container may be
        /// behind. A burst of observer wakes, one per enabled type, then pays
        /// for one recount rather than one each.
        ///
        /// Set by the fetch itself, which GRDB runs on the writer before the
        /// committing write returns — so a wake's completion hook always sees
        /// it, unlike anything set from the asynchronously delivered `onChange`.
        var hasUnflushedFetch = false
    }

    /// Read by the observation's fetch on GRDB's queue, written from the main
    /// queue by the scene-phase hooks — hence the lock.
    @ObservationIgnored
    private let statusFetchState = OSAllocatedUnfairLock(initialState: StatusFetchState())

    init(database: AppDatabase) {
        let store = HKHealthStore()
        self.database = database
        self.healthStore = store
        let engine = SyncEngine(database: database, store: store)
        self.syncEngine = engine
        self.observerCoordinator = ObserverCoordinator(store: store, syncEngine: engine)
        self.importBackground = ImportBackgroundCoordinator(database: database, engine: engine)
        self.isOnboardingComplete = UserDefaults.standard.bool(forKey: "conduit.onboardingComplete")
        statusSnapshotQueue.async { [weak self] in
            self?.lastPersistedStatusSnapshot = ConduitStatusSnapshot.readFromAppGroup()
        }
        observerCoordinator.onWakeHandled = { [weak self] in
            await self?.flushStatusSnapshot()
        }
        Uploader.shared.onDeliveryCommitted = { [weak self] in
            await self?.flushStatusSnapshot()
        }
        startStatusSnapshotObservation()
    }

    // MARK: - Lock Screen widget status snapshot

    /// Recomputes `status` on every relevant DB change, publishes it for Home,
    /// and writes the widget's snapshot to the App Group container. Reuses
    /// `HomeViewModel.deriveStatus` and `SettingsViewModel.statusTitle(for:)`
    /// verbatim rather than inventing new wording for the same states.
    private func startStatusSnapshotObservation() {
        let fetchState = statusFetchState
        let observation = ValueObservation.tracking { db -> (HomeViewModel.StatusSnapshot, String?, Bool) in
            let importRun = try ImportRunState.fetchOne(db, key: ImportProgressDAO.singletonID)
            let importHeadline = AppState.importHeadline(for: importRun)
            let (home, countsAreFresh) = try AppState.fetchStatus(
                db,
                importHeadline: importHeadline,
                state: fetchState,
                now: Date()
            )
            return (home, importHeadline, countsAreFresh)
        }

        statusSnapshotCancellable = observation.start(
            in: database.dbWriter,
            onError: { [weak self] error in
                logger.error("Status snapshot observation error: \(error.localizedDescription, privacy: .public)")
                self?.scheduleStatusSnapshotObservationRestart()
            },
            onChange: { [weak self] value in
                guard let self else { return }
                let (home, importHeadline, countsAreFresh) = value
                self.statusObservationFailures = 0
                self.status = home
                guard countsAreFresh else { return }
                let snapshot = AppState.widgetSnapshot(from: home, importHeadline: importHeadline)
                self.statusSnapshotQueue.async { [weak self] in
                    self?.persistStatusSnapshot(snapshot)
                }
            }
        )
    }

    /// The observation's status fetch, with the outbox counts gated by the same
    /// rule as the App Group write.
    ///
    /// Off screen, `status` only feeds the widget snapshot, so recounting a
    /// multi-million-row queue on each of an import's ~10^4 deliveries buys
    /// nothing `shouldWriteToAppGroup` would publish. The cheap reads run
    /// first; the counts are recounted only when that probe differs from the
    /// last full fetch by a state class, or once the refresh interval has
    /// passed. A probe result is never written to the App Group container —
    /// its counts are carried over, not current — so the second value is
    /// `false` for it and the observation skips the write.
    private static func fetchStatus(
        _ db: Database,
        importHeadline: String?,
        state: OSAllocatedUnfairLock<StatusFetchState>,
        now: Date
    ) throws -> (HomeViewModel.StatusSnapshot, countsAreFresh: Bool) {
        let (isForeground, lastFullFetch) = state.withLock {
            $0.hasUnflushedFetch = true
            return ($0.isForeground, $0.lastFullFetch)
        }
        if !isForeground, let lastFullFetch {
            let probe = try HomeViewModel.fetchStatus(db, reusingCountsFrom: lastFullFetch.home)
            let countsAreDue = ConduitStatusSnapshot.shouldWriteToAppGroup(
                previous: widgetSnapshot(from: lastFullFetch.home, importHeadline: lastFullFetch.importHeadline),
                writtenAt: lastFullFetch.at,
                next: widgetSnapshot(from: probe, importHeadline: importHeadline),
                now: now
            )
            if !countsAreDue { return (probe, false) }
        }
        let home = try HomeViewModel.fetchStatus(db)
        state.withLock { $0.lastFullFetch = (home, importHeadline, now) }
        return (home, true)
    }

    /// The app came on screen: recount everything from here on, and restart
    /// the observation so `status` is not left holding counts carried over
    /// while it was in the background.
    func statusSurfaceDidBecomeActive() {
        statusFetchState.withLock { $0.isForeground = true }
        startStatusSnapshotObservation()
    }

    /// The app is leaving the screen: stop recounting on every delivery and
    /// flush the current state to the widget.
    func statusSurfaceDidEnterBackground() {
        statusFetchState.withLock { $0.isForeground = false }
        Task { await flushStatusSnapshot() }
    }

    /// Writes a freshly counted snapshot to the App Group container past the
    /// interval floor, returning once it has landed. A no-op when the
    /// observation has not fetched since the last flush.
    ///
    /// The observation only writes when a delivery arrives, so without this a
    /// count change skipped by the floor — a stuck upload queue, say — would
    /// sit unwritten for as long as no further transaction came along. Called
    /// wherever the app is about to stop running: leaving the screen, and the
    /// end of each background wake (`BGAppRefreshTask`, HealthKit observer),
    /// since a background-only launch never passes through a scene phase.
    func flushStatusSnapshot() async {
        let database = self.database
        let fetchState = statusFetchState
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            statusSnapshotQueue.async { [weak self] in
                defer { continuation.resume() }
                let isDue = fetchState.withLock { state in
                    defer { state.hasUnflushedFetch = false }
                    return state.hasUnflushedFetch
                }
                guard isDue, let self else { return }
                do {
                    let snapshot = try database.dbWriter.read { db in
                        let importRun = try ImportRunState.fetchOne(db, key: ImportProgressDAO.singletonID)
                        return AppState.widgetSnapshot(
                            from: try HomeViewModel.fetchStatus(db),
                            importHeadline: AppState.importHeadline(for: importRun)
                        )
                    }
                    if !self.persistStatusSnapshot(snapshot, ignoringIntervalFloor: true) {
                        fetchState.withLock { $0.hasUnflushedFetch = true }
                    }
                } catch {
                    logger.error("Failed to flush status snapshot: \(error.localizedDescription, privacy: .public)")
                    fetchState.withLock { $0.hasUnflushedFetch = true }
                }
            }
        }
    }

    /// Re-arms the observation after a failed fetch, on a doubling backoff.
    ///
    /// GRDB cancels a `ValueObservation` the moment it hands an error to
    /// `onError`, and this is the only observation the app runs over these
    /// tables — so without a restart one failed fetch kills it for the rest of
    /// the process: `status` freezes at its last value, Home stops updating,
    /// and the Lock Screen keeps rendering whatever is already in the
    /// container. That last part is the worst of it: a stale reading is
    /// precisely what this widget asks the user to read as "sync is stuck".
    ///
    /// Backs off rather than spending a fixed attempt budget. A fetch that
    /// keeps throwing — an `import_run` row holding an enum case this build
    /// does not know, say — must not spin the writer queue, but it must also
    /// still recover whenever the cause clears, which an exhausted budget
    /// could not.
    private func scheduleStatusSnapshotObservationRestart() {
        statusObservationFailures += 1
        let delay = AppState.statusObservationRetryDelay(consecutiveFailures: statusObservationFailures)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startStatusSnapshotObservation()
        }
    }

    /// Longest gap between restart attempts, so a permanently-failing fetch
    /// costs at most one re-read of the writer queue per interval.
    static let statusObservationRetryCeiling: TimeInterval = 5 * 60

    /// Doubling backoff from one second up to `statusObservationRetryCeiling`.
    static func statusObservationRetryDelay(consecutiveFailures: Int) -> TimeInterval {
        let exponent = Double(min(max(consecutiveFailures - 1, 0), 16))
        return min(pow(2, exponent), statusObservationRetryCeiling)
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
    /// until the user imports again. Only a run that is live, failed, or
    /// stopped on something still worth acting on earns that: a completed run
    /// has nothing to report, and a routine pause is not a condition worth
    /// advertising over a stuck upload queue, which is the silent failure this
    /// surface exists to expose.
    static func importHeadline(for run: ImportRunState?) -> String? {
        guard let run, run.status != .completed, !isRoutinePause(run) else { return nil }
        return SettingsViewModel.statusTitle(for: run)
    }

    /// Whether a run stopped for a reason the user neither has to act on nor
    /// would read as a problem — the two ordinary ways an import ends early.
    ///
    /// Deliberately an exhaustive switch rather than a list of exclusions: a
    /// new `ImportStopCause` must not inherit a permanent pin on the Lock
    /// Screen by default, so adding one has to fail to compile here until it is
    /// classified. `nil` is not evidence of a routine stop — legacy rows
    /// predate the column — so it keeps the headline.
    private static func isRoutinePause(_ run: ImportRunState) -> Bool {
        guard run.status == .interrupted else { return false }
        switch run.stopCause {
        case .userCancelled, .backgrounded:
            return true
        case .queueNotDraining, .historyLimited, .historyAccessUnknown, .endedShort, .none:
            return false
        }
    }

    /// Writes the snapshot to the App Group container — but only when the
    /// container owes the widget that write (`shouldWriteToAppGroup`) — then
    /// reloads the widget's timelines only on a state-*class* change (an error
    /// appearing/clearing, the import headline changing, the failed count
    /// crossing zero, or the first sync leaving `.idle`) — never on every
    /// stamp, since Conduit's background cadence would exhaust the widget's
    /// daily reload budget otherwise.
    ///
    /// The same state-class rule gates both: a class change is written and
    /// pushed at once, anything else is written at most once per rebuild
    /// interval, so the ~10^4 deliveries of a large import no longer each pay
    /// an encode and an atomic file write nothing will read.
    /// `ignoringIntervalFloor` writes any change at once; the background flush
    /// uses it so a skipped change does not wait for a delivery that may never
    /// come.
    ///
    /// A failed write leaves the container holding the *previous* snapshot, so
    /// it also leaves `lastPersistedStatusSnapshot` where it is: reloading would
    /// only redraw stale content, and advancing the bookkeeping would make the
    /// next successful write of the same state class look like no change at all,
    /// suppressing the reload that actually matters.
    ///
    /// Runs on `statusSnapshotQueue`, which owns `lastPersistedStatusSnapshot`.
    @discardableResult
    private func persistStatusSnapshot(
        _ snapshot: ConduitStatusSnapshot,
        ignoringIntervalFloor: Bool = false,
        now: Date = Date()
    ) -> Bool {
        let isDue = ignoringIntervalFloor
            ? lastPersistedStatusSnapshot != snapshot
            : ConduitStatusSnapshot.shouldWriteToAppGroup(
                previous: lastPersistedStatusSnapshot,
                writtenAt: lastPersistedStatusSnapshotAt,
                next: snapshot,
                now: now
            )
        guard isDue else { return lastPersistedStatusSnapshot == snapshot }
        do {
            try snapshot.writeToAppGroup()
        } catch {
            logger.error("Failed to write status snapshot: \(error.localizedDescription, privacy: .public)")
            return false
        }
        if ConduitStatusSnapshot.shouldReloadTimelines(previous: lastPersistedStatusSnapshot, next: snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        lastPersistedStatusSnapshot = snapshot
        lastPersistedStatusSnapshotAt = now
        return true
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
