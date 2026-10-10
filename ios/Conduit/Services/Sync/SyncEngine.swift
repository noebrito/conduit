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
    private let reader: AnchoredReader
    private let readAnchored: (HealthDataType, HKQueryAnchor?, Date?, Int, Bool) async throws -> AnchoredReader.Result
    private let scanWorkouts: (Date?, Date?, Int) async throws -> [HKWorkout]
    private let readRoutes: (HKWorkout) async throws -> [Conduit_V1_Sample]
    private let outboxDAO: OutboxDAO
    private let webhookConfigDAO: WebhookConfigDAO
    private let dataTypeConfigDAO: DataTypeConfigDAO
    private var throttle: Throttle
    private let batcher: Batcher
    private let bearerToken: @MainActor () -> String?
    private let submitUpload: @MainActor (Batcher.BatchResult, String, String) -> Bool
    private let keychain: KeychainStore
    private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "SyncEngine")

    /// Workouts with a nonempty route set fully staged in this process. Observer
    /// and Shortcuts capture share the memo; no-route and cap-limited reads remain
    /// retryable so late-finalized or partially staged routes can be picked up.
    /// In-memory by design: relaunch may repeat capture of delivered routes.
    /// See `OutboxDAO.enqueue` for queue dedupe scope and
    /// `docs/webhook/HTTP_CONTRACT.md` for receiver replay requirements.
    private var workoutsWithCapturedRoute: Set<String> = []

    /// BGAppRefreshTask identifier for the background catch-up flush. MUST match
    /// an entry in `Info.plist`'s `BGTaskSchedulerPermittedIdentifiers` — iOS
    /// refuses to register or schedule an identifier that isn't listed there.
    static let bgRefreshTaskID = "dev.noebrito.Conduit.flush"

    /// How far out to ask iOS to schedule the next app-refresh flush. This is a
    /// *floor*, not a guarantee — iOS decides the actual cadence based on usage,
    /// battery, and budget, and may run it later (or not at all). ~15 min is the
    /// practical minimum iOS honours for `BGAppRefreshTask`.
    static let bgRefreshInterval: TimeInterval = 15 * 60

    /// How long a row may sit `.inflight` before `flush` treats it as stuck
    /// and reclaims it back to `.pending` for retry, regardless of what the
    /// background `URLSession` currently reports for its batch. See
    /// `OutboxDAO.reclaimStaleInflight`.
    ///
    /// Generous relative to how long a single upload of an at-most-8-MiB
    /// batch should ever genuinely take on any real connection (including its
    /// own transport-level retries), but short enough to self-heal within one
    /// app session rather than requiring the user to force-quit/relaunch to
    /// un-stick the queue.
    static let staleInflightTimeout: TimeInterval = 30 * 60

    init(
        database: AppDatabase,
        store: HKHealthStore = HKHealthStore(),
        uploader: Uploader = .shared,
        keychain: KeychainStore = .shared,
        readAnchored: ((HealthDataType, HKQueryAnchor?, Date?, Int, Bool) async throws -> AnchoredReader.Result)? = nil,
        scanWorkouts: ((Date?, Date?, Int) async throws -> [HKWorkout])? = nil,
        readRoutes: ((HKWorkout) async throws -> [Conduit_V1_Sample])? = nil,
        bearerToken: (@MainActor () -> String?)? = nil,
        submitUpload: (@MainActor (Batcher.BatchResult, String, String) -> Bool)? = nil
    ) {
        self.database = database
        let reader = AnchoredReader(store: store)
        let routeReader = WorkoutRouteReader(store: store)
        self.reader = reader
        self.readAnchored = readAnchored ?? { type, anchor, since, limit, includeHR in
            try await reader.read(type: type, anchor: anchor, since: since, limit: limit, includeHeartRateStatistics: includeHR)
        }
        self.scanWorkouts = scanWorkouts ?? { since, before, limit in
            try await routeReader.workouts(since: since, before: before, limit: limit)
        }
        self.readRoutes = readRoutes ?? { try await routeReader.routeSamples(for: $0) }
        self.outboxDAO = OutboxDAO(database)
        self.webhookConfigDAO = WebhookConfigDAO(database)
        self.dataTypeConfigDAO = DataTypeConfigDAO(database)
        self.batcher = Batcher(database: database)
        self.bearerToken = bearerToken ?? { keychain.webhookBearerToken }
        self.submitUpload = submitUpload ?? { uploader.upload(batch: $0, webhookURL: $1, bearerToken: $2) }
        self.keychain = keychain
        // Default throttle; replaced from stored webhook config on first use.
        self.throttle = Throttle(minInterval: 900, forceFlushThreshold: 200)
    }

    private var shortcutIsRunning = false

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

            let result = try await readAnchored(
                dataType, anchor, captureFloor, HKObjectQueryNoLimit,
                try includeHeartRateStatisticsForWorkouts()
            )

            // §4.4 critical invariant: anchor advance + sample enqueue in one transaction.
            // `cap` enforces the configured outbox back-pressure limit: if the
            // batch would exceed it, ingest stages what fits and leaves the
            // anchor UNADVANCED so the rest is re-delivered next read (no loss).
            guard let inserted = try outboxDAO.ingest(
                samples: result.samples,
                hkTypeId: typeIdentifier,
                webhookId: webhookID,
                anchorBlob: result.newAnchorData,
                expectedAnchorBlob: typeConfig.anchorBlob,
                expectedIngestRevision: typeConfig.ingestRevision,
                deletedUuids: result.deletedUuids,
                cap: webhook.outboxCap
            ) else { return }
            if result.deletedUuids.isEmpty {
                logger.info("Observer wake for \(typeIdentifier, privacy: .public): \(inserted) new samples staged")
            } else {
                logger.info("Observer wake for \(typeIdentifier, privacy: .public): \(inserted) new samples staged, \(result.deletedUuids.count) deletion(s) tombstoned")
            }

            // A workout wake is also the trigger for GPS route capture — routes
            // have no observer of their own (see `captureRecentRoutes`).
            if dataType.stream == .workout {
                await captureRecentRoutes(webhookID: webhookID, cap: webhook.outboxCap)
            }

            let pendingCount = try outboxDAO.count(state: .pending)
            guard throttle.shouldFlush(pendingCount: pendingCount) else {
                logger.debug("Throttle gate closed (pending=\(pendingCount))")
                return
            }
            throttle.recordFlush()

            try await flush()
        } catch {
            logger.error("handleObserverWake(\(typeIdentifier, privacy: .public)) error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Workout heart-rate privacy gate

    /// Resolve the read-time Heart Rate toggle for workout enrichment.
    /// The authoritative staging check is in `OutboxDAO.enqueue`, because
    /// Settings can change while a HealthKit read suspends.
    ///
    /// Internal so `AnchoredReaderTests` can verify the read-time DB lookup.
    func includeHeartRateStatisticsForWorkouts() throws -> Bool {
        try dataTypeConfigDAO.find(hkTypeId: HealthDataType.heartRate.identifier)?.enabled ?? true
    }

    // MARK: - GPS route capture (workout-driven)

    /// Capture GPS routes for recent workouts, called after every **workout**
    /// observer wake.
    ///
    /// ## Why a re-scan rather than "read the route of the workout we just read"
    ///
    /// Apple attaches a workout's route **shortly after** the workout ends, so the
    /// wake that delivers the workout very often precedes the route existing — and
    /// by then the workout anchor has advanced past it, so that workout is never
    /// handed to us again. Instead of trying to time it, this walks **every**
    /// workout in the last `rescanWindowDays` that we haven't already captured a
    /// route for, and attempts the read. A route that wasn't ready on wake N is
    /// therefore picked up on wake N+1 (workouts wake often, and the
    /// `BGAppRefreshTask` fallback drives it too).
    ///
    /// Shared capture/deduplication invariants live with `workoutsWithCapturedRoute`
    /// and `stageCapturedRoutes`, which Shortcuts also uses.
    ///
    /// Routes never advance a HealthKit anchor: capture is driven by the workout
    /// and made idempotent by dedupe, so there is no anchor to keep. That's why
    /// this stages via `stageImport` (enqueue-only) and not `ingest`.
    private func captureRecentRoutes(webhookID: Int64, cap: Int?) async {
        do {
            guard
                let routeConfig = try dataTypeConfigDAO.find(hkTypeId: HealthDataType.workoutRoute.identifier),
                routeConfig.enabled
            else {
                logger.debug("Route capture disabled — skipping route pass")
                return
            }

            let since = Calendar.current.date(
                byAdding: .day,
                value: -WorkoutRouteReader.rescanWindowDays,
                to: Date()
            )
            let workouts = try await scanWorkouts(since, nil, HKObjectQueryNoLimit)

            var stagedRoutes = 0
            for workout in workouts {
                let workoutUUID = workout.uuid.uuidString
                guard !workoutsWithCapturedRoute.contains(workoutUUID) else { continue }

                // One workout's route read failing must not block the rest of the
                // window: log it and move on, leaving it unmemoized so a later
                // wake retries it.
                let samples: [Conduit_V1_Sample]
                do {
                    samples = try await readRoutes(workout)
                } catch {
                    logger.error("Route read failed for workout \(workoutUUID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
                // No route is the NORMAL outcome for most workouts: stage nothing,
                // don't memoize, and try again next wake in case Apple hasn't
                // finished attaching one yet.
                guard !samples.isEmpty else { continue }

                let staged = try stageCapturedRoutes(samples, for: workout, webhookID: webhookID, cap: cap)
                stagedRoutes += staged.inserted
                if staged.hitCap {
                    logger.info("Route capture paused: outbox at cap")
                    break
                }
            }
            if stagedRoutes > 0 {
                logger.info("Route capture: staged \(stagedRoutes) new route(s)")
            }
        } catch {
            // Route capture is strictly additive to the workout read that already
            // committed — never let it fail the wake.
            logger.error("captureRecentRoutes error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stageCapturedRoutes(
        _ samples: [Conduit_V1_Sample], for workout: HKWorkout, webhookID: Int64, cap: Int?
    ) throws -> (inserted: Int, hitCap: Bool) {
        guard !samples.isEmpty, !workoutsWithCapturedRoute.contains(workout.uuid.uuidString) else {
            return (0, false)
        }
        let staged = try outboxDAO.stageImport(samples: samples,
            hkTypeId: HealthDataType.workoutRoute.identifier, webhookId: webhookID, cap: cap)
        if !staged.hitCap { workoutsWithCapturedRoute.insert(workout.uuid.uuidString) }
        return staged
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
    ///   anchor. Ongoing incremental capture is therefore unaffected;
    ///   deduplication follows `OutboxDAO.enqueue`'s contract.
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
    ///   - startCursor: the persisted resume point from an interrupted run of the
    ///     same import; `nil` starts at the newest end.
    ///   - onCheckpoint: called after each page with the resume cursor and the
    ///     running staged total, so the caller can persist durable progress.
    /// - Returns: how many rows were staged, the resume cursor, whether the range
    ///   was exhausted, whether the outbox cap stopped the import early (queue
    ///   never drained), and whether it was cancelled.
    /// - Throws: whatever the HealthKit read or the outbox staging threw, plus
    ///   `ImportError.noWebhookConfigured`. **This method must never turn a
    ///   failure into a success-shaped summary** — a swallowed read error (e.g.
    ///   protected data unavailable while the device is locked) silently truncates
    ///   the user's health history while the UI claims it worked.
    func importHistory(
        typeIdentifier: String,
        since: Date?,
        pageSize: Int = SyncEngine.importPageSize,
        startCursor: Date? = nil,
        isCancelled: @escaping () -> Bool = { Task.isCancelled },
        onProgress: @escaping (Int) -> Void = { _ in },
        onCheckpoint: @escaping (Date?, Int) throws -> Void = { _, _ in }
    ) async throws -> HistoryImporter.Summary {
        guard let webhook = try webhookConfigDAO.first(), let webhookID = webhook.id else {
            logger.error("importHistory: no webhook configured")
            throw ImportError.noWebhookConfigured
        }
        guard let dataType = HealthTypeRegistry.shared.type(forIdentifier: typeIdentifier) else {
            // Not a failure: there is genuinely nothing to import for a type this
            // build doesn't know about, so the range is trivially exhausted.
            logger.debug("importHistory: unknown type \(typeIdentifier, privacy: .public) — skipping")
            return HistoryImporter.Summary(staged: 0, hitCap: false, cancelled: false, exhausted: true)
        }

        // Routes can't be imported by the generic anchored/sample read — they
        // are found FROM their workout — so the route type's import is its own
        // workout-driven pass over the same user-chosen window. Because
        // `SettingsViewModel.runImport` iterates the enabled registry, this is
        // what gives "Import History" historical routes, behind the same
        // volume-warning confirmation.
        if dataType.stream == .route {
            return try await importRoutes(
                since: since,
                webhook: webhook,
                webhookID: webhookID,
                pageSize: pageSize,
                startCursor: startCursor,
                isCancelled: isCancelled,
                onProgress: onProgress,
                onCheckpoint: onCheckpoint
            )
        }

        // Resume once the outbox has room for at least a full page again, so
        // resuming doesn't immediately re-trip the cap after staging a few rows.
        let resumeThreshold = max(0, webhook.outboxCap - pageSize)

        let summary = try await HistoryImporter.run(
            pageSize: pageSize,
            startCursor: startCursor,
            isCancelled: isCancelled,
            readPage: { before in
                try await self.reader.readImportPage(
                    type: dataType,
                    since: since,
                    before: before,
                    limit: pageSize,
                    includeHeartRateStatistics: try self.includeHeartRateStatisticsForWorkouts()
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
            onCheckpoint: onCheckpoint,
            waitForCapacity: {
                await self.drainBelowCap(
                    webhook: webhook,
                    webhookID: webhookID,
                    resumeThreshold: resumeThreshold,
                    isCancelled: isCancelled
                )
            }
        )
        logger.info("importHistory(\(typeIdentifier, privacy: .public)): staged \(summary.staged) rows, hitCap=\(summary.hitCap), cancelled=\(summary.cancelled), exhausted=\(summary.exhausted)")
        return summary
    }

    /// Import GPS routes for every workout in the user-chosen window — the route
    /// type's counterpart to `HistoryImporter.run`.
    ///
    /// It mirrors the sample import's contract deliberately: workouts are paged
    /// **newest-first** so recent routes stage and upload first; staging goes
    /// through `stageImport`, so no HealthKit anchor is ever touched; the outbox
    /// `cap` bounds volume and the loop **auto-resumes** by draining below it
    /// (routes are the heaviest data Conduit stages, so an "All time" import of
    /// years of outdoor workouts is exactly what that machinery is for); and
    /// `Task.isCancelled` stops it promptly at a workout boundary.
    ///
    /// A route read that fails for ONE workout is skipped and logged (a routeless
    /// or unreadable workout is the common case and must not fail the import),
    /// but an error from the workout scan or from staging propagates — the caller
    /// records a real failure rather than a success-shaped summary.
    ///
    /// - Returns: rows staged, the resume cursor, whether the range was
    ///   exhausted, whether a stuck queue stopped it, and cancellation.
    private func importRoutes(
        since: Date?,
        webhook: WebhookConfig,
        webhookID: Int64,
        pageSize: Int,
        startCursor: Date?,
        isCancelled: @escaping () -> Bool,
        onProgress: @escaping (Int) -> Void,
        onCheckpoint: @escaping (Date?, Int) throws -> Void
    ) async throws -> HistoryImporter.Summary {
        let routeTypeID = HealthDataType.workoutRoute.identifier
        let resumeThreshold = max(0, webhook.outboxCap - pageSize)
        var staged = 0
        var cursor: Date? = startCursor

        // Same hard ceiling HistoryImporter.run applies, for the same reason:
        // a reader that never advances its cursor cannot loop forever.
        for _ in 0..<HistoryImporter.defaultMaxPages {
            if isCancelled() {
                return HistoryImporter.Summary(staged: staged, hitCap: false, cancelled: true, cursor: cursor)
            }

            let workouts = try await scanWorkouts(since, cursor, pageSize)
            guard !workouts.isEmpty else {
                return HistoryImporter.Summary(
                    staged: staged, hitCap: false, cancelled: false, cursor: cursor, exhausted: true
                )
            }

            for workout in workouts {
                if isCancelled() {
                    return HistoryImporter.Summary(staged: staged, hitCap: false, cancelled: true, cursor: cursor)
                }
                let samples: [Conduit_V1_Sample]
                do {
                    samples = try await readRoutes(workout)
                } catch {
                    logger.error("Route read failed for workout \(workout.uuid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
                guard !samples.isEmpty else { continue }

                var result = try outboxDAO.stageImport(
                    samples: samples,
                    hkTypeId: routeTypeID,
                    webhookId: webhookID,
                    cap: webhook.outboxCap
                )
                if result.hitCap {
                    // Wait for room, then retry this workout under the replay
                    // contract documented at `OutboxDAO.enqueue`. Stop if the
                    // queue never drains rather than spin.
                    guard await drainBelowCap(
                        webhook: webhook,
                        webhookID: webhookID,
                        resumeThreshold: resumeThreshold,
                        isCancelled: isCancelled
                    ) else {
                        staged += result.inserted
                        try onCheckpoint(cursor, staged)
                        return HistoryImporter.Summary(
                            staged: staged, hitCap: true, cancelled: false, cursor: cursor
                        )
                    }
                    let retried = try outboxDAO.stageImport(
                        samples: samples,
                        hkTypeId: routeTypeID,
                        webhookId: webhookID,
                        cap: webhook.outboxCap
                    )
                    result.inserted += retried.inserted
                    result.hitCap = retried.hitCap
                }
                staged += result.inserted
                if !result.hitCap { workoutsWithCapturedRoute.insert(workout.uuid.uuidString) }
                onProgress(staged)
            }

            // Newest-first paging cursor: continue from the oldest workout of
            // this page. Inclusive bounds mean that workout is re-read once and
            // deduped, which is safer than risking a same-timestamp sibling.
            guard let oldest = workouts.last?.endDate, oldest != cursor else {
                return HistoryImporter.Summary(
                    staged: staged, hitCap: false, cancelled: false, cursor: cursor, exhausted: true
                )
            }
            cursor = oldest
            try onCheckpoint(cursor, staged)
        }

        logger.info("importRoutes: staged \(staged) route(s)")
        return HistoryImporter.Summary(staged: staged, hitCap: false, cancelled: false, cursor: cursor)
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
        resumeThreshold: Int,
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(SyncEngine.importDrainTimeout)
        while Date() < deadline {
            if isCancelled() { return false }
            _ = try? await flush()
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
            try await flush()
        } catch {
            logger.error("flushNow error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A bounded read must never establish a type's initial forward anchor:
    /// later anchored reads drop the date floor and could upload pre-existing
    /// backdated records. Initialization stays on the normal observer path.
    func syncFromShortcut() async -> String {
        guard !shortcutIsRunning else { return "A Shortcuts sync is already running. Try again after it finishes." }
        shortcutIsRunning = true
        defer { shortcutIsRunning = false }
        do {
            guard let webhook = try webhookConfigDAO.first(), let webhookID = webhook.id else {
                return "Open Conduit and configure your destination first. Nothing was captured or queued."
            }
            guard let token = await bearerToken(), !token.isEmpty else {
                return "The destination token is unavailable. Unlock your iPhone and check Conduit setup. Nothing was captured or queued."
            }
            let enabled = try dataTypeConfigDAO.enabled().map(\.hkTypeId).sorted()
            guard !enabled.isEmpty else { return "No Health types are enabled. Enable types in Conduit first. Nothing was captured or queued." }
            let deadline = Date().addingTimeInterval(ShortcutSync.timeBudget)
            let summary = await ShortcutSync.run(
                identifiers: enabled,
                shouldStop: { Task.isCancelled || Date() >= deadline },
                capture: { identifier in
                    // Re-check the toggle after actor reentrancy during each read.
                    guard let config = try self.dataTypeConfigDAO.find(hkTypeId: identifier), config.enabled,
                          let type = HealthTypeRegistry.shared.type(forIdentifier: identifier), type.sampleType != nil else {
                        return ShortcutSync.Capture()
                    }
                    if type.stream == .route {
                        let since = Calendar.current.date(byAdding: .day, value: -WorkoutRouteReader.rescanWindowDays, to: Date())
                        let workouts = try await self.scanWorkouts(since, nil, ShortcutSync.workoutLimit)
                        var capture = ShortcutSync.Capture(limited: workouts.count == ShortcutSync.workoutLimit)
                        for workout in workouts {
                            if Task.isCancelled || Date() >= deadline { capture.limited = true; break }
                            guard !self.workoutsWithCapturedRoute.contains(workout.uuid.uuidString) else { continue }
                            do {
                                let samples = try await self.readRoutes(workout)
                                capture.captured += samples.count
                                guard try self.dataTypeConfigDAO.find(hkTypeId: identifier)?.enabled == true else { capture.limited = true; break }
                                let staged = try self.stageCapturedRoutes(samples, for: workout, webhookID: webhookID, cap: webhook.outboxCap)
                                capture.queued += staged.inserted
                                if staged.hitCap { capture.limited = true; break }
                            } catch {
                                capture.notice = ShortcutSync.failureMessage(error)
                                break
                            }
                        }
                        return capture
                    }
                    guard let anchor = AnchoredReader.unarchiveAnchor(config.anchorBlob) else {
                        return ShortcutSync.Capture(limited: true, uninitializedType: type.displayName)
                    }
                    let result = try await self.readAnchored(type, anchor, nil, ShortcutSync.pageSize,
                        try self.includeHeartRateStatisticsForWorkouts())
                    guard try self.dataTypeConfigDAO.find(hkTypeId: identifier)?.enabled == true else {
                        return ShortcutSync.Capture(captured: result.samples.count, limited: true)
                    }
                    do {
                        guard let inserted = try self.outboxDAO.ingest(samples: result.samples, hkTypeId: identifier,
                            webhookId: webhookID, anchorBlob: result.newAnchorData,
                            expectedAnchorBlob: config.anchorBlob,
                            expectedIngestRevision: config.ingestRevision,
                            deletedUuids: result.deletedUuids, cap: webhook.outboxCap) else {
                            return ShortcutSync.Capture(captured: result.samples.count, limited: true)
                        }
                        return ShortcutSync.Capture(captured: result.samples.count, queued: inserted,
                            deletions: result.deletedUuids.count,
                            limited: result.samples.count + result.deletedUuids.count >= ShortcutSync.pageSize || inserted < result.samples.count)
                    } catch {
                        return ShortcutSync.Capture(captured: result.samples.count, notice: ShortcutSync.failureMessage(error))
                    }
                },
                flush: { try await self.flush() }
            )
            return summary.message
        } catch {
            return "Could not read Conduit configuration. Unlock your iPhone and open Conduit, then retry. Nothing was captured or queued by this action."
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
    /// `onFinished` is awaited after the flush, before the task is completed.
    nonisolated func registerBackgroundTask(onFinished: @escaping @Sendable () async -> Void = {}) {
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
                await onFinished()
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

    // MARK: - Outbox drain status

    /// Whether the outbox is fully drained: no rows waiting to send, and none
    /// currently `.inflight`. Only this state may stamp "last synced" on an
    /// otherwise-empty flush — an empty *pending* count alone is not enough,
    /// since a `.inflight` batch (genuinely still uploading, or stuck and
    /// awaiting `reclaimStaleInflight`) is still undelivered data. Pure so the
    /// decision is unit-testable without a database.
    static func outboxIsFullyDrained(pendingCount: Int, inflightCount: Int) -> Bool {
        pendingCount == 0 && inflightCount == 0
    }

    // MARK: - Private

    /// Capture destination and token together on MainActor, then revalidate both
    /// there immediately before submission, without an intervening await.
    /// Settings saves on that actor; mixing snapshots can disclose a new token
    /// to the old endpoint.
    @discardableResult
    private func flush() async throws -> Int {
        let destinationDAO = webhookConfigDAO
        let token = self.bearerToken
        guard let (webhook, bearerToken) = try await MainActor.run(body: {
            guard let webhook = try destinationDAO.first(), webhook.id != nil,
                  let credential = token(), !credential.isEmpty else { return nil as (WebhookConfig, String)? }
            return (webhook, credential)
        }), let webhookID = webhook.id else { return 0 }
        // Reclaim any batch that's been `.inflight` long enough to be stuck
        // rather than genuinely still uploading (see `staleInflightTimeout`),
        // BEFORE draining — so a reclaimed row is immediately eligible for the
        // batch this same flush is about to build. Without this, a batch whose
        // upload silently wedges (e.g. mid-request during a connectivity
        // outage) sits `.inflight` forever: `Batcher.buildBatch` only ever
        // drains `.pending` rows, and `Uploader.reconcileInflight` only runs
        // once, at app launch — which a long-lived session may never reach.
        let reclaimed = try outboxDAO.reclaimStaleInflight(staleAfter: SyncEngine.staleInflightTimeout)
        if reclaimed > 0 {
            logger.info("flush: reclaimed \(reclaimed) stale inflight row(s) for retry")
        }

        let deviceID = keychain.deviceID
        guard let batch = try batcher.buildBatch(
            webhookID: webhookID,
            limit: webhook.batchMaxSize,
            deviceID: deviceID
        ) else {
            logger.debug("Nothing to upload")
            // An empty flush is still a successful sync only when the outbox
            // is FULLY drained — no pending work waiting AND nothing still
            // `.inflight` — e.g. a "Sync Now" with nothing new to send. Stamp
            // "last synced" so the timestamp advances even though zero items
            // were uploaded. Checking pending alone was the bug: a batch
            // sitting `.inflight` (whether genuinely still uploading, or stuck
            // and awaiting the next reclaim above) is still undelivered data,
            // so a "Synced just now" status while it sits there is misleading
            // — this is what let a stuck outbox report success. When pending
            // rows exist but are all in backoff, there IS undelivered data
            // too, so we don't claim a fresh sync either way.
            let drained = SyncEngine.outboxIsFullyDrained(
                pendingCount: try outboxDAO.count(state: .pending),
                inflightCount: try outboxDAO.count(state: .inflight)
            )
            if drained {
                try SyncStateDAO(database).setLastSyncedAt()
            }
            return 0
        }

        let submitUpload = self.submitUpload
        let submitted: Bool?
        do {
            submitted = try await MainActor.run { () -> Bool? in
                guard try destinationDAO.first() == webhook, token() == bearerToken else { return nil }
                guard !Task.isCancelled else { return nil }
                return submitUpload(batch, webhook.url, bearerToken)
            }
        } catch {
            try outboxDAO.releaseUnsubmittedBatch(batchID: batch.batchID)
            throw error
        }
        guard let submitted else {
            try outboxDAO.releaseUnsubmittedBatch(batchID: batch.batchID)
            return 0
        }
        guard submitted else { return 0 }

        // Keep a background-refresh request pending so the outbox still drains if
        // the app is suspended before the next observer wake or foreground open.
        scheduleBackgroundFlush()
        return batch.rowIDs.count
    }
}
