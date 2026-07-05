import Foundation
import HealthKit
import BackgroundTasks
import os

/// Orchestrates the full observer → read → enqueue → throttle → batch → upload
/// pipeline (ARCHITECTURE.md §4.4).
///
/// `SyncEngine` is an `actor` so all internal state mutations (Throttle, etc.)
/// are serialised without locks. `ObserverCoordinator` drives it via
/// `handleObserverWake`; the `AppDelegate` starts it once on launch.
actor SyncEngine {
    private let database: AppDatabase
    private let store: HKHealthStore
    private let reader: AnchoredReader
    private let outboxDAO: OutboxDAO
    private let webhookConfigDAO: WebhookConfigDAO
    private let dataTypeConfigDAO: DataTypeConfigDAO
    private var throttle: Throttle
    private let batcher: Batcher
    private let uploader: Uploader
    private let keychain: KeychainStore
    private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "SyncEngine")

    /// BGAppRefreshTask identifier for the background catch-up flush. MUST match
    /// an entry in `Info.plist`'s `BGTaskSchedulerPermittedIdentifiers` — iOS
    /// refuses to register or schedule an identifier that isn't listed there.
    static let bgRefreshTaskID = "dev.noebrito.Conduit.flush"

    /// How far out to ask iOS to schedule the next app-refresh flush. This is a
    /// *floor*, not a guarantee — iOS decides the actual cadence based on usage,
    /// battery, and budget, and may run it later (or not at all). ~15 min is the
    /// practical minimum iOS honours for `BGAppRefreshTask`.
    static let bgRefreshInterval: TimeInterval = 15 * 60

    init(
        database: AppDatabase,
        store: HKHealthStore = HKHealthStore(),
        uploader: Uploader = .shared,
        keychain: KeychainStore = .shared
    ) {
        self.database = database
        self.store = store
        self.reader = AnchoredReader(store: store)
        self.outboxDAO = OutboxDAO(database)
        self.webhookConfigDAO = WebhookConfigDAO(database)
        self.dataTypeConfigDAO = DataTypeConfigDAO(database)
        self.batcher = Batcher(database: database)
        self.uploader = uploader
        self.keychain = keychain
        // Default throttle; replaced from stored webhook config on first use.
        self.throttle = Throttle(minInterval: 900, forceFlushThreshold: 200)
    }

    // MARK: - Forward-only capture floor

    /// The forward-only capture floor seeded on the first (anchor-less) read of
    /// a type: the **start of the current local day** (device-local midnight)
    /// rather than the exact `now` instant.
    ///
    /// Seeding start-of-today means the first read pulls today's samples from
    /// local midnight → now (one bounded day) instead of only samples recorded
    /// after setup/reset. So a freshly set-up or just-reset device shows a
    /// COMPLETE Move/Exercise ring for the current day, not a truncated one —
    /// while still staying strictly one-day-bounded (never the old unbounded
    /// all-history backfill). Applied uniformly to every enabled type.
    ///
    /// Pure and injectable (`now`/`calendar`) so the seeded value is unit-testable.
    static func forwardCaptureFloor(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now)
    }

    // MARK: - Observer wake

    /// Called by `ObserverCoordinator` when HealthKit delivers new data for `typeIdentifier`.
    ///
    /// Steps (ARCHITECTURE.md §4.4):
    /// 1. Look up the webhook config and enabled state.
    /// 2. Perform anchored read for the type.
    /// 3. Enqueue new samples + advance anchor in ONE transaction (§4.4 invariant).
    /// 4. Check throttle; if green, build batch and enqueue upload.
    func handleObserverWake(typeIdentifier: String) async {
        do {
            guard let webhook = try webhookConfigDAO.first(), let webhookID = webhook.id else {
                logger.debug("No webhook configured — skipping sync")
                return
            }

            // Refresh throttle params from the stored config on every wake so
            // settings changes take effect without a restart. Update in place —
            // recreating the struct would reset `lastFlushAt` to nil and defeat
            // the min-interval time gate (see `Throttle.updateParameters`).
            throttle.updateParameters(
                minInterval: TimeInterval(webhook.minIntervalSeconds),
                forceFlushThreshold: webhook.forceFlushThreshold
            )

            guard
                let typeConfig = try dataTypeConfigDAO.find(hkTypeId: typeIdentifier),
                typeConfig.enabled,
                let dataType = HealthTypeRegistry.shared.type(forIdentifier: typeIdentifier)
            else {
                logger.debug("Type \(typeIdentifier, privacy: .public) not enabled — skipping")
                return
            }

            let anchor = AnchoredReader.unarchiveAnchor(typeConfig.anchorBlob)

            // Forward-only default: on the very first (anchor-less) read, seed a
            // capture floor of START-OF-TODAY (device-local midnight) so we skip
            // pre-today history but still stage TODAY's samples from midnight
            // onward — so the current day's Move/Exercise rings reflect the full
            // day, not just the post-setup/post-reset slice. Still strictly
            // one-day-bounded (never unbounded history). Gated STRICTLY on
            // `anchor == nil` — startDataCapture runs on every launch, so this
            // must never re-seed on relaunch. The floor is persisted the first
            // time and reused if the anchor ever fails to persist, so we don't
            // skip the gap between launches.
            let captureFloor: Date?
            if anchor == nil {
                if let existing = typeConfig.captureStartedAt {
                    captureFloor = existing
                } else {
                    let floor = SyncEngine.forwardCaptureFloor()
                    try dataTypeConfigDAO.setCaptureStartedAt(floor, hkTypeId: typeIdentifier)
                    captureFloor = floor
                }
            } else {
                captureFloor = nil
            }

            let result = try await reader.read(type: dataType, anchor: anchor, since: captureFloor)

            // §4.4 critical invariant: anchor advance + sample enqueue in one transaction.
            // `cap` enforces the configured outbox back-pressure limit: if the
            // batch would exceed it, ingest stages what fits and leaves the
            // anchor UNADVANCED so the rest is re-delivered next read (no loss).
            let inserted = try outboxDAO.ingest(
                samples: result.samples,
                hkTypeId: typeIdentifier,
                webhookId: webhookID,
                anchorBlob: result.newAnchorData,
                cap: webhook.outboxCap
            )
            logger.info("Observer wake for \(typeIdentifier, privacy: .public): \(inserted) new samples staged")

            let pendingCount = try outboxDAO.count(state: .pending)
            guard throttle.shouldFlush(pendingCount: pendingCount) else {
                logger.debug("Throttle gate closed (pending=\(pendingCount))")
                return
            }
            throttle.recordFlush()

            try await flush(webhook: webhook, webhookID: webhookID)
        } catch {
            logger.error("handleObserverWake(\(typeIdentifier, privacy: .public)) error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Import history (explicit opt-in)

    /// Default page size for a historical import. Large enough to keep the
    /// per-page overhead low, small enough that memory only ever holds one page.
    static let importPageSize = 5_000

    /// How often the auto-resume drain loop re-checks the outbox / re-kicks a
    /// flush while waiting for the queue to drain below the cap.
    static let importDrainPollInterval: TimeInterval = 2

    /// How long the auto-resume drain loop waits for the outbox to drain below
    /// the cap before giving up on a stuck queue (so a permanently-failing
    /// upload can't hang an import forever).
    static let importDrainTimeout: TimeInterval = 600

    /// Explicitly import PAST HealthKit history for one type over a user-chosen
    /// range (ARCHITECTURE.md §4.4, "Import history" opt-in).
    ///
    /// This is the deliberate, user-triggered counterpart to the forward-only
    /// default. Three invariants distinguish it from `handleObserverWake`:
    ///
    /// - **The forward anchor is never touched.** The read walks a local date
    ///   cursor (`before: nil` on the first page) and results are staged via
    ///   `OutboxDAO.stageImport`, which does not advance `data_type_config`'s
    ///   anchor. Ongoing incremental capture is therefore unaffected, and UUID
    ///   dedupe prevents any overlap between the import and the live stream from
    ///   double-staging.
    /// - **Newest-first, and self-resuming past the cap.** The read is paged
    ///   `endDate`-descending (`AnchoredReader.readImportPage`) so recent days
    ///   stage/upload first, and when a page hits `outboxCap` the loop drains the
    ///   queue below the cap (`drainBelowCap`) and continues automatically — a
    ///   range larger than the cap finishes without the user tapping Import again.
    /// - **The volume is bounded and cancellable.** The read is paged
    ///   (`importPageSize`) and staging never exceeds `outboxCap`, so even an
    ///   "All time" import drains in bounded chunks; `Task.isCancelled` stops it
    ///   promptly.
    ///
    /// - Parameters:
    ///   - typeIdentifier: the HealthKit type to import.
    ///   - since: the user-chosen start of the window; `nil` imports all history.
    ///   - onProgress: called with the running staged total (across pages) so the
    ///     UI can show live progress during a long import.
    /// - Returns: how many rows were staged, whether the outbox cap stopped the
    ///   import early (queue never drained), and whether it was cancelled.
    func importHistory(
        typeIdentifier: String,
        since: Date?,
        pageSize: Int = SyncEngine.importPageSize,
        onProgress: @escaping (Int) -> Void = { _ in }
    ) async -> HistoryImporter.Summary {
        do {
            guard let webhook = try webhookConfigDAO.first(), let webhookID = webhook.id else {
                logger.debug("importHistory: no webhook configured — skipping")
                return HistoryImporter.Summary(staged: 0, hitCap: false, cancelled: false)
            }
            guard let dataType = HealthTypeRegistry.shared.type(forIdentifier: typeIdentifier) else {
                logger.debug("importHistory: unknown type \(typeIdentifier, privacy: .public) — skipping")
                return HistoryImporter.Summary(staged: 0, hitCap: false, cancelled: false)
            }

            // Resume once the outbox has room for at least a full page again, so
            // resuming doesn't immediately re-trip the cap after staging a few rows.
            let resumeThreshold = max(0, webhook.outboxCap - pageSize)

            let summary = try await HistoryImporter.run(
                pageSize: pageSize,
                isCancelled: { Task.isCancelled },
                readPage: { before in
                    try await self.reader.readImportPage(
                        type: dataType,
                        since: since,
                        before: before,
                        limit: pageSize
                    )
                },
                stagePage: { samples in
                    try self.outboxDAO.stageImport(
                        samples: samples,
                        hkTypeId: typeIdentifier,
                        webhookId: webhookID,
                        cap: webhook.outboxCap
                    )
                },
                onProgress: onProgress,
                waitForCapacity: {
                    await self.drainBelowCap(
                        webhook: webhook,
                        webhookID: webhookID,
                        resumeThreshold: resumeThreshold
                    )
                }
            )
            logger.info("importHistory(\(typeIdentifier, privacy: .public)): staged \(summary.staged) rows, hitCap=\(summary.hitCap), cancelled=\(summary.cancelled)")
            return summary
        } catch {
            logger.error("importHistory(\(typeIdentifier, privacy: .public)) error: \(error.localizedDescription, privacy: .public)")
            return HistoryImporter.Summary(staged: 0, hitCap: false, cancelled: false)
        }
    }

    /// Drive uploads and wait until the outbox drains to at/below
    /// `resumeThreshold`, so a paged import can resume staging without ever
    /// exceeding `outboxCap`. Returns `true` once there is room again, or `false`
    /// if the queue didn't drain within `importDrainTimeout` (a stuck/failing
    /// upload) or the import was cancelled.
    ///
    /// Draining happens because a successful (2xx) upload DELETES its rows from
    /// the outbox (`Uploader.commitSent`), so `totalCount` falls as batches land.
    /// We re-kick a flush each poll so the background session keeps pulling the
    /// next pending batch even though no observer wake is firing during an import.
    private func drainBelowCap(
        webhook: WebhookConfig,
        webhookID: Int64,
        resumeThreshold: Int
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(SyncEngine.importDrainTimeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            try? await flush(webhook: webhook, webhookID: webhookID)
            try? await Task.sleep(nanoseconds: UInt64(SyncEngine.importDrainPollInterval * 1_000_000_000))
            let total = (try? outboxDAO.totalCount()) ?? webhook.outboxCap
            if total <= resumeThreshold { return true }
        }
        return false
    }

    /// Manually trigger a flush (e.g. "Sync Now" button, BGProcessingTask).
    /// Bypasses the time gate but still respects count-empty guard.
    func flushNow() async {
        do {
            guard let webhook = try webhookConfigDAO.first(), let webhookID = webhook.id else { return }
            try await flush(webhook: webhook, webhookID: webhookID)
        } catch {
            logger.error("flushNow error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Background flush (BGAppRefreshTask fallback)

    /// The app's background-sync fallback (ARCHITECTURE.md §4.4).
    ///
    /// HealthKit observer background delivery is the *primary* background-wake
    /// mechanism, but it is best-effort and iOS-budgeted (most quantity types are
    /// coalesced to at most ~hourly, and delivery is suppressed under system
    /// pressure / Low Power Mode). Without a fallback the outbox would only flush
    /// when the app is next opened. A single lightweight **BGAppRefreshTask**
    /// backs it up: iOS periodically wakes us for a brief window in which we call
    /// `flushNow`. The window is short, but that's fine — the actual upload runs
    /// out-of-process on the background `URLSession`, so it completes even after
    /// the window (and the app) ends. A heavier `BGProcessingTask` is deliberately
    /// NOT used: these uploads are small and incremental, so the frequent,
    /// low-cost app-refresh task is the right fit and lighter on the battery.
    ///
    /// iOS ultimately controls cadence — the schedule is a request, not a
    /// guarantee. Register the handler **before** launch returns
    /// (`registerBackgroundTask`), and keep a request pending
    /// (`scheduleBackgroundFlush`) on launch, on entering background, and after
    /// each flush.

    /// Register the BGAppRefreshTask handler. MUST be called from
    /// `application(_:didFinishLaunchingWithOptions:)` **before** it returns —
    /// iOS requires all task handlers to be registered by the end of launch.
    nonisolated func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: SyncEngine.bgRefreshTaskID,
            using: nil
        ) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            // Keep the chain alive: schedule the next request before doing work,
            // so one is always pending even if this run is expired early.
            self.scheduleBackgroundFlush()
            task.expirationHandler = { task.setTaskCompleted(success: false) }
            Task {
                await self.flushNow()
                task.setTaskCompleted(success: true)
            }
        }
    }

    /// Submit (or refresh) the pending BGAppRefreshTask request with an
    /// `earliestBeginDate` floor of `bgRefreshInterval` from now. Safe to call
    /// repeatedly — resubmitting with the same identifier replaces the pending
    /// request.
    ///
    /// Submission can fail on the simulator or when Background App Refresh is
    /// disabled; that's non-fatal and logged — the observer path and foreground
    /// flush still work.
    nonisolated func scheduleBackgroundFlush() {
        let request = BGAppRefreshTaskRequest(identifier: SyncEngine.bgRefreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(SyncEngine.bgRefreshInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.debug("Failed to schedule background flush: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private func flush(webhook: WebhookConfig, webhookID: Int64) async throws {
        let deviceID = keychain.deviceID
        guard let batch = try batcher.buildBatch(
            webhookID: webhookID,
            limit: webhook.batchMaxSize,
            deviceID: deviceID
        ) else {
            logger.debug("Nothing to upload")
            // An empty flush is still a successful sync when the outbox is clean
            // (no pending work waiting) — e.g. a "Sync Now" with nothing new to
            // send. Stamp "last synced" so the timestamp advances even though zero
            // items were uploaded. When pending rows exist but are all in backoff,
            // there IS undelivered data, so we don't claim a fresh sync.
            if try outboxDAO.count(state: .pending) == 0 {
                try SyncStateDAO(database).setLastSyncedAt()
            }
            return
        }

        guard let bearerToken = keychain.webhookBearerToken else {
            logger.error("No bearer token in keychain — cannot upload")
            return
        }

        uploader.upload(batch: batch, webhookURL: webhook.url, bearerToken: bearerToken)

        // Keep a background-refresh request pending so the outbox still drains if
        // the app is suspended before the next observer wake or foreground open.
        scheduleBackgroundFlush()
    }
}
