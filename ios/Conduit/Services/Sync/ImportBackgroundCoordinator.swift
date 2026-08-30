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

    /// The `UIApplication` background-task assertion held while a paused run
    /// finishes its page. Only ever touched on the main actor.
    private var assertionID: UIBackgroundTaskIdentifier = .invalid

    init(
        database: AppDatabase,
        engine: SyncEngine,
        coordinator: ImportRunCoordinator = .shared
    ) {
        self.database = database
        self.engine = engine
        self.coordinator = coordinator
    }

    private var runner: ImportRunner {
        ImportRunner(database: database, engine: engine, coordinator: coordinator)
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
    ///   (protected data while locked, revoked permission) would just fail again
    ///   every window, so a failure waits for a deliberate tap.
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

    /// Called from `applicationDidEnterBackground`.
    ///
    /// If an import is live we ask it to stop at its next page boundary and hold a
    /// `beginBackgroundTask` assertion until it does, so the in-flight page lands
    /// and checkpoints. Without the assertion iOS suspends us mid-page and that
    /// page's work is thrown away (the previous page's cursor is still durable, so
    /// nothing is ever lost — but we would re-read a page for no reason and the
    /// status would be a page staler than the truth).
    @MainActor
    func applicationDidEnterBackground(_ application: UIApplication = .shared) {
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

    // MARK: - Foreground: continue without making the user ask

    /// Called from `applicationWillEnterForeground` (and once on launch).
    /// Continues a run iOS paused, so coming back to the app just picks up where
    /// it stopped. An import the user cancelled is deliberately left alone.
    @MainActor
    func applicationWillEnterForeground() {
        Task { @MainActor [weak self] in
            _ = await self?.resumePausedRun(trigger: "foreground")
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
        // The claim is the real guard (checked again inside the runner); this is
        // just an early out so a background wake during a foreground import does
        // no work at all.
        guard !coordinator.isRunning else {
            logger.info("Import resume (\(trigger, privacy: .public)) skipped — a run is already in flight")
            return .notCompleted
        }
        guard ImportBackgroundCoordinator.shouldAutoResume(currentRun()) else { return .notCompleted }
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
