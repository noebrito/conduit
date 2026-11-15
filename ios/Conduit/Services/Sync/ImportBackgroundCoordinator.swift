import BackgroundTasks
import Foundation
import UIKit
import os

private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "ImportBackground")

/// Lets a large "Import history" survive the user leaving the app — as far as
/// iOS actually permits, and no further.
///
/// ## What this honestly is (and is not)
///
/// iOS does **not** let an app keep working indefinitely in the background, so
/// this deliberately does not try to. What it guarantees is:
///
/// 1. **A clean stop.** When the app backgrounds mid-import we take a
///    `beginBackgroundTask` assertion and ask the run to stop at its next page
///    boundary, so the page it is reading finishes and **checkpoints** its cursor
///    instead of being frozen mid-page and thrown away.
/// 2. **Automatic resumption in whatever windows iOS grants.** A
///    `BGProcessingTaskRequest` asks to be woken to continue from the persisted
///    cursor. iOS decides if and when that happens — it is a request, never a
///    guarantee, and the UI copy says so.
/// 3. **Instant resumption on return.** Coming back to the foreground with a
///    resumable run continues it automatically rather than making the user tap
///    Resume.
///
/// ## Where the lifecycle comes from
///
/// This is the one owner of the import's leave-screen / return-to-screen
/// handling, driven by UIKit's application lifecycle notifications
/// (`observeAppLifecycle`). It deliberately does NOT hang off
/// `UIApplicationDelegate.applicationDidEnterBackground` /
/// `applicationWillEnterForeground`: in this SwiftUI (scene-based) app UIKit
/// sends those events to the scene, never to the app delegate — measured in the
/// real app on the simulator — so hooks placed there are dead code.
///
/// It is emphatically NOT "the import keeps churning while you use other apps".
/// Nothing here should ever be described that way to the user.
///
/// ## Why it can't start a second run
///
/// Every path goes through `ImportRunner`, which takes the process-wide
/// `ImportRunCoordinator` claim. A background wake that fires while a foreground
/// run is live is refused (`Outcome.alreadyRunning`) rather than driving the same
/// run twice, and vice versa — so foreground and background can never both be
/// checkpointing the same rows.
final class ImportBackgroundCoordinator {
    /// BGProcessingTask identifier for resuming a paused import. MUST match an
    /// entry in `Info.plist`'s `BGTaskSchedulerPermittedIdentifiers` — iOS refuses
    /// to register or schedule an identifier that isn't listed there. Deliberately
    /// distinct from `SyncEngine.bgRefreshTaskID`, which drains uploads and must
    /// stay exactly as it is.
    static let taskID = "dev.noebrito.Conduit.import"

    /// How far out to ask iOS to schedule a resume. A floor, not a promise.
    static let earliestBeginInterval: TimeInterval = 60

    /// How long the backgrounding assertion waits for the in-flight page to land
    /// and checkpoint. iOS grants roughly 30 s for a `beginBackgroundTask`
    /// assertion, so this is deliberately well inside that — we are buying ONE
    /// page's checkpoint, not trying to finish an import.
    static let checkpointGrace: TimeInterval = 20
    static let checkpointPollInterval: TimeInterval = 0.2

    private let database: AppDatabase
    private let engine: SyncEngine
    private let coordinator: ImportRunCoordinator
    private let probe: HistoryAccessProbing
    /// Whether HealthKit's protected data is readable right now — false while
    /// the iPhone is locked. A seam so the lock policy is testable without a
    /// device; production reads `UIApplication.isProtectedDataAvailable`.
    private let isProtectedDataAvailable: @MainActor () -> Bool
    /// Whether the app is on screen (not in the background). A seam for the
    /// same reason as `isProtectedDataAvailable`.
    private let isInForeground: @MainActor () -> Bool
    /// Whether the app is fully active (on screen and frontmost). Only then is a
    /// lock-pause retried on the spot; a seam for the same reason as the others.
    private let isActive: @MainActor () -> Bool

    /// The `UIApplication` background-task assertion held while a paused run
    /// finishes its page. Only ever touched on the main actor.
    private var assertionID: UIBackgroundTaskIdentifier = .invalid

    private var protectedDataObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// The resume an unlock started, if any — exposed so a test can await it.
    private(set) var unlockResume: Task<ResumeResult, Never>?
    /// The resume the app becoming active started, if any — exposed so a test
    /// can await it.
    private(set) var activeResume: Task<ResumeResult, Never>?
    /// The launch's own resume, if any — exposed so a test can await it.
    private(set) var launchResume: Task<ResumeResult, Never>?
    /// What launch must finish (the registry reconcile) before any resume reads
    /// the enabled types; every resume awaits it.
    private var launchPreparation: Task<Void, Never>?
    /// The single retry of a run that ended as a lock pause while the app was
    /// active and unlocked, if any — exposed so a test can await it.
    private(set) var lockPauseRetry: Task<ResumeResult, Never>?
    /// True from the moment a lock-pause retry is scheduled until its resume
    /// returns. Read on whatever thread releases the claim, hence the lock.
    private let lockPauseRetryInFlight = OSAllocatedUnfairLock(initialState: false)

    init(
        database: AppDatabase,
        engine: SyncEngine,
        coordinator: ImportRunCoordinator = .shared,
        probe: HistoryAccessProbing = HealthKitHistoryAccessProbe(),
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable },
        isInForeground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState != .background },
        isActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
    ) {
        self.database = database
        self.engine = engine
        self.coordinator = coordinator
        self.probe = probe
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.isInForeground = isInForeground
        self.isActive = isActive
    }

    deinit {
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private var runner: ImportRunner {
        ImportRunner(database: database, engine: engine, coordinator: coordinator, probe: probe)
    }

    // MARK: - Should this run continue on its own?

    /// Whether a persisted run may be picked back up **without the user asking**.
    ///
    /// Pure, so the policy is unit-testable without HealthKit, `BGTaskScheduler`
    /// or a `UIApplication`. Deliberately narrow:
    ///
    /// - `.interrupted` **and** flagged `autoResume` — the app was backgrounded,
    ///   force-quit or otherwise stopped by something other than the user.
    /// - a user cancellation clears the flag, so Cancel means cancelled.
    /// - `.failed` is excluded even though it is resumable: a read that failed
    ///   (revoked permission, storage) would just fail again every window, so a
    ///   failure waits for a deliberate tap. The iPhone locking mid-read is NOT
    ///   a failure — it is an auto-resumable `.deviceLocked` pause, held by
    ///   `resumePausedRun` until protected data is readable again.
    static func shouldAutoResume(_ run: ImportRunState?) -> Bool {
        guard let run else { return false }
        return run.status == .interrupted && run.autoResume
    }

    /// Whether iOS should keep a resume window booked for us — which is a
    /// slightly wider question than "may we resume this run right now".
    ///
    /// A run that is STILL LIVE when we ask (its page outlasted the checkpoint
    /// grace, or a background window is expiring under it) is not yet flagged
    /// auto-resumable — it will be, the moment it stops or is reconciled. Reading
    /// that in-between row as "nothing to continue" and withdrawing the request
    /// is exactly backwards: a run iOS suspended mid-page is the case where the
    /// next window matters most.
    static func needsScheduledResume(run: ImportRunState?, isLive: Bool) -> Bool {
        if isLive && run?.status == .running { return true }
        return shouldAutoResume(run)
    }

    /// The persisted run, with a `running` row left behind by a force-quit
    /// reconciled to `interrupted` first — which is what makes an import the app
    /// *died* in the middle of eligible to continue on the next launch.
    ///
    /// Reconciliation goes through `ImportRunner.loadPersistedState`, so it is
    /// claim-gated: a run some other task is actually driving is never mistaken
    /// for a stale one.
    private func currentRun() -> ImportRunState? {
        runner.loadPersistedState().run
    }

    // MARK: - BGProcessingTask

    /// Register the resume handler. MUST be called from
    /// `application(_:didFinishLaunchingWithOptions:)` **before** it returns —
    /// iOS requires every task handler to be registered by the end of launch.
    ///
    /// This is a **`BGProcessingTask`**, not a `BGAppRefreshTask`: unlike the
    /// upload drain (which hands work to a background `URLSession` in seconds),
    /// resuming an import does real on-device work — paging HealthKit and writing
    /// to SQLite — and wants the longer, system-scheduled window that processing
    /// tasks get. The upload-drain `BGAppRefreshTask` is untouched and keeps
    /// running on its own identifier.
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ImportBackgroundCoordinator.taskID,
            using: nil
        ) { [weak self] task in
            let completion = TaskCompletion(task)
            guard let self else {
                completion.complete(success: false)
                return
            }
            // Set synchronously: the expiration handler can fire at any moment,
            // and it must reach the run rather than a task we haven't started.
            // `.backgrounded` (not a user cancel) so the run stays auto-resumable.
            task.expirationHandler = { [weak self] in
                self?.coordinator.requestStop(.backgrounded)
                // iOS allows an expiration handler only seconds, and the run's
                // next page boundary can be a drain-wait away — so hand the task
                // back NOW rather than letting the window run out into a
                // termination (which also costs future scheduling budget).
                // `TaskCompletion` makes this idempotent, so the async path below
                // finishing later is harmless.
                completion.complete(success: false)
                // The run is still live, so keep a request pending for it: this
                // is exactly the case where another window is most valuable.
                Task { @MainActor [weak self] in self?.scheduleResumeIfNeeded() }
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    completion.complete(success: false)
                    return
                }
                let result = await self.resumePausedRun(trigger: "background task")
                if result == .blockedNoWebhook {
                    // Nothing a future window could do — a resume with no webhook
                    // configured stages nowhere. Re-submitting would just book a
                    // guaranteed no-op forever.
                    self.cancelScheduledResume()
                } else {
                    // Keep the chain alive only while there is still work: this
                    // re-submits when the run is still paused and cancels when it
                    // is finished, cancelled or failed.
                    self.scheduleResumeIfNeeded()
                }
                completion.complete(success: result == .completed)
            }
        }
    }

    /// One-shot `setTaskCompleted` guard: the expiration handler and the async
    /// resume can both reach the end, and calling it twice is a hard error.
    private final class TaskCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var task: BGTask?

        init(_ task: BGTask) { self.task = task }

        func complete(success: Bool) {
            lock.lock()
            let pending = task
            task = nil
            lock.unlock()
            pending?.setTaskCompleted(success: success)
        }
    }

    /// Ask iOS to wake us to continue a paused import, or withdraw the request
    /// when there is nothing left to continue.
    ///
    /// - `requiresNetworkConnectivity = true`: a resumed import only makes real
    ///   progress if the outbox can drain — past the cap, staging blocks on
    ///   uploads completing — so a window without the network would burn a
    ///   scheduling opportunity to stage almost nothing.
    /// - `requiresExternalPower = false`: requiring the charger would mean most
    ///   users never see this run at all. The work is paged, cancellable and
    ///   stops the moment iOS expires the window, so it is a poor fit for the
    ///   "only while plugged in" contract.
    @MainActor
    func scheduleResumeIfNeeded() {
        guard ImportBackgroundCoordinator.needsScheduledResume(
            run: currentRun(),
            isLive: coordinator.isRunning
        ) else {
            cancelScheduledResume()
            return
        }
        let request = BGProcessingTaskRequest(identifier: ImportBackgroundCoordinator.taskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(
            ImportBackgroundCoordinator.earliestBeginInterval
        )
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled background import resume")
        } catch {
            // Non-fatal: the foreground auto-resume still picks the run up. This
            // fails routinely on the simulator and when Background App Refresh is
            // switched off — which is exactly why the UI never promises the
            // background window will happen.
            logger.debug("Failed to schedule import resume: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    func cancelScheduledResume() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: ImportBackgroundCoordinator.taskID)
    }

    // MARK: - Backgrounding: stop cleanly, keep the checkpoint

    /// The app left the screen (`UIApplication.didEnterBackgroundNotification`,
    /// via `observeAppLifecycle`).
    ///
    /// If an import is live we ask it to stop at its next page boundary and hold a
    /// `beginBackgroundTask` assertion until it does, so the in-flight page lands
    /// and checkpoints. Without the assertion iOS suspends us mid-page and that
    /// page's work is thrown away (the previous page's cursor is still durable, so
    /// nothing is ever lost — but we would re-read a page for no reason and the
    /// status would be a page staler than the truth).
    @MainActor
    func applicationDidEnterBackground(_ application: UIApplication) {
        guard coordinator.isRunning else {
            scheduleResumeIfNeeded()
            return
        }
        coordinator.requestStop(.backgrounded)
        beginCheckpointAssertion(application)
    }

    @MainActor
    private func beginCheckpointAssertion(_ application: UIApplication) {
        guard assertionID == .invalid else { return }
        assertionID = application.beginBackgroundTask(withName: "conduit.import.checkpoint") { [weak self] in
            // iOS is out of patience (~30 s). End the assertion or the app is
            // killed outright. At most the in-flight page is lost; the previous
            // page's cursor is already persisted, so the resume point stands.
            logger.info("Import checkpoint assertion expired before the page landed")
            self?.endCheckpointAssertion(application)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.waitForRunToStop()
            self.endCheckpointAssertion(application)
            self.scheduleResumeIfNeeded()
        }
    }

    @MainActor
    private func endCheckpointAssertion(_ application: UIApplication) {
        guard assertionID != .invalid else { return }
        application.endBackgroundTask(assertionID)
        assertionID = .invalid
    }

    /// Poll until the claim holder releases (the run reached its boundary and
    /// checkpointed), or the grace period runs out.
    @MainActor
    private func waitForRunToStop() async {
        let deadline = Date().addingTimeInterval(ImportBackgroundCoordinator.checkpointGrace)
        while Date() < deadline {
            if !coordinator.isRunning { return }
            try? await Task.sleep(
                nanoseconds: UInt64(ImportBackgroundCoordinator.checkpointPollInterval * 1_000_000_000)
            )
        }
    }

    // MARK: - Lifecycle: the one owner of leave-screen / return-to-screen

    /// Start handling the app leaving and returning to the screen, the iPhone
    /// unlocking, and a run that ends as a lock pause. Called once at launch.
    ///
    /// Driven by UIKit's application lifecycle notifications, which a
    /// scene-based app receives (unlike the app-delegate callbacks; see the type
    /// comment). `isEnabled` gates the leave/return handling exactly as the
    /// launch path is gated — production passes "onboarding is complete" — and
    /// is read per event, so finishing onboarding mid-session turns it on.
    ///
    /// - Leaving the screen: refresh the pending background flush, stop a live
    ///   import cleanly at its next page boundary and book a background window
    ///   (`applicationDidEnterBackground`).
    /// - Becoming active: continue a paused run. The phone is certainly
    ///   unlocked by then, which is why this — not "will enter foreground" — is
    ///   the trigger: an unlock usually lands before the app is back on screen,
    ///   when the unlock signal alone can only book a background window.
    @MainActor
    func observeAppLifecycle(
        center: NotificationCenter = .default,
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        guard lifecycleObservers.isEmpty else { return }
        observeProtectedDataAvailability(center: center)
        let onBackground: @MainActor () -> Void = { [weak self] in
            guard let self, isEnabled() else { return }
            self.engine.scheduleBackgroundFlush()
            self.applicationDidEnterBackground(UIApplication.shared)
        }
        let onActive: @MainActor () -> Void = { [weak self] in
            self?.applicationDidBecomeActive(isEnabled: isEnabled)
        }
        lifecycleObservers = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { onBackground() } },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { onActive() } },
        ]
        coordinator.onLockPausedRunReleased = { [weak self] in self?.lockPausedRunReleased() }
    }

    /// The app became active: continue a run iOS paused, so coming back to the
    /// app just picks up where it stopped. An import the user cancelled is
    /// deliberately left alone.
    @MainActor
    func applicationDidBecomeActive(isEnabled: @escaping @MainActor () -> Bool = { true }) {
        activeResume = Task { @MainActor [weak self] in
            guard let self, isEnabled() else { return .notCompleted }
            return await self.resumePausedRun(trigger: "active")
        }
    }

    /// Run launch's preparation, then continue a paused run. Every resume —
    /// whichever trigger fires first, including the app becoming active during
    /// launch — waits for `prepare` to finish, so none reads the enabled types
    /// before it has reconciled them.
    @MainActor
    func resumeAfterLaunch(preparing prepare: @escaping @MainActor () async -> Void) {
        launchPreparation = Task { @MainActor in await prepare() }
        launchResume = Task { @MainActor [weak self] in
            guard let self else { return .notCompleted }
            return await self.resumePausedRun(trigger: "launch")
        }
    }

    // MARK: - A lock pause that landed after the triggers fired

    /// A run that ended as a lock pause just released its claim. Runs on the
    /// releasing thread.
    ///
    /// The unlock and becoming-active triggers skip a run that is still in
    /// flight, so if the locked read's error lands AFTER they fired (the app was
    /// suspended with the read outstanding), the pause is recorded with nothing
    /// left to resume it. So when the app is active and protected data is
    /// readable at the moment the pause lands, try the resume once.
    ///
    /// Once per pause, never a loop: if the retry's own run pauses again (UIKit
    /// says unlocked but HealthKit still refuses), that pause is reported while
    /// the retry is still in flight — the claim is released before the resume
    /// returns — and is left for the next real trigger.
    private func lockPausedRunReleased() {
        guard !lockPauseRetryInFlight.withLock({ $0 }) else {
            logger.info("Import paused for the lock again during its retry — waiting for the next trigger")
            return
        }
        Task { @MainActor [weak self] in self?.retryLockPauseOnce() }
    }

    @MainActor
    private func retryLockPauseOnce() {
        guard isActive(), isProtectedDataAvailable() else { return }
        let claimed = lockPauseRetryInFlight.withLock { inFlight -> Bool in
            guard !inFlight else { return false }
            inFlight = true
            return true
        }
        guard claimed else { return }
        lockPauseRetry = Task { @MainActor [weak self] in
            guard let self else { return .notCompleted }
            defer { self.lockPauseRetryInFlight.withLock { $0 = false } }
            return await self.resumePausedRun(trigger: "lock pause retry")
        }
    }

    // MARK: - Unlock: continue a run the lock paused

    /// Start listening for the iPhone being unlocked. Called once at launch.
    ///
    /// Becoming active already resumes a paused run, but an unlock can land
    /// while the app is on screen without it becoming active again, in which
    /// case only this catches it, so a run paused by the lock continues on its
    /// own, from the same place, without anyone tapping Resume.
    @MainActor
    func observeProtectedDataAvailability(center: NotificationCenter = .default) {
        guard protectedDataObserver == nil else { return }
        let onUnlock: @MainActor () -> Void = { [weak self] in self?.protectedDataDidBecomeAvailable() }
        protectedDataObserver = center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onUnlock() }
        }
    }

    /// Resume on unlock when the app is on screen. In the background there is no
    /// assertion keeping the process alive through a page, so leave it to the
    /// booked background window (and the app becoming active) instead.
    @MainActor
    func protectedDataDidBecomeAvailable() {
        guard isInForeground() else {
            scheduleResumeIfNeeded()
            return
        }
        unlockResume = Task { @MainActor [weak self] in
            guard let self else { return .notCompleted }
            return await self.resumePausedRun(trigger: "unlock")
        }
    }

    /// Resume the persisted run if — and only if — it is one we may continue on
    /// our own and nothing else is already driving it.
    ///
    /// What a resume attempt did — enough for the caller to decide whether asking
    /// iOS for another window would accomplish anything.
    enum ResumeResult {
        /// The resumed run read its whole range. Only this is a success; nothing
        /// here can turn a truncated import into one.
        case completed
        /// It ran but stopped short, or there was nothing eligible to resume.
        case notCompleted
        /// Refused because no webhook is configured — staging has nowhere to go,
        /// so a future window would do exactly nothing.
        case blockedNoWebhook
    }

    @MainActor
    @discardableResult
    func resumePausedRun(trigger: String) async -> ResumeResult {
        await launchPreparation?.value
        // The claim is the real guard (checked again inside the runner); this is
        // just an early out so a background wake during a foreground import does
        // no work at all.
        guard !coordinator.isRunning else {
            logger.info("Import resume (\(trigger, privacy: .public)) skipped — a run is already in flight")
            return .notCompleted
        }
        guard ImportBackgroundCoordinator.shouldAutoResume(currentRun()) else { return .notCompleted }
        // While the iPhone is locked every HealthKit read fails with "Protected
        // health data is inaccessible", so starting now would only re-pause.
        // Hold the run; the unlock (or the app becoming active, or a background
        // window) picks it up from the same place.
        guard isProtectedDataAvailable() else {
            logger.info("Import resume (\(trigger, privacy: .public)) held — protected data unavailable (device locked)")
            return .notCompleted
        }
        // Staging needs somewhere to send to. Without this the resume would end
        // as `.failed` (noWebhookConfigured) and, worse, clear the auto-resume
        // flag on a run the user could otherwise still finish.
        let webhook = (try? WebhookConfigDAO(database).first()) ?? nil
        guard webhook != nil else {
            logger.debug("Import resume skipped — no webhook configured")
            return .blockedNoWebhook
        }
        let types = enabledTypes()
        guard !types.isEmpty else { return .notCompleted }

        logger.info("Resuming paused import (\(trigger, privacy: .public)) across \(types.count) type(s)")
        let outcome = await runner.resume(types: types)
        if outcome.alreadyRunning {
            return .notCompleted
        }
        return outcome.status == .completed ? .completed : .notCompleted
    }

    private func enabledTypes() -> [HealthDataType] {
        let enabledIDs = Set((try? DataTypeConfigDAO(database).enabled().map(\.hkTypeId)) ?? [])
        return HealthTypeRegistry.shared.all.filter { enabledIDs.contains($0.identifier) }
    }
}
