import Foundation
import HealthKit
import os

/// Registers an `HKObserverQuery` and enables background delivery for every
/// enabled HealthKit type (ARCHITECTURE.md §4.4).
///
/// ## Critical invariant
/// iOS permanently disables background delivery for a type if we fail to call
/// the observer `completionHandler` within ~30 seconds. Every code path must
/// call it; this class guarantees that by placing `defer { completionHandler() }`
/// at the very top of each handler and doing all slow work in a `Task` that
/// calls `completionHandler` via its own `defer`.
///
/// The `completionHandler` is called AFTER the `SyncEngine.handleObserverWake`
/// coroutine completes (anchored read + outbox enqueue), so iOS receives the
/// signal once durable work is done. The subsequent background URLSession upload
/// runs independently of this window.
final class ObserverCoordinator {
    private let store: HKHealthStore
    private let syncEngine: SyncEngine
    private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "ObserverCoordinator")

    private var activeQueries: [String: HKObserverQuery] = [:]

    init(store: HKHealthStore = HKHealthStore(), syncEngine: SyncEngine) {
        self.store = store
        self.syncEngine = syncEngine
    }

    /// Register observer queries and enable background delivery for every type
    /// in `types`. Already-registered types are skipped (idempotent).
    func start(for types: [HealthDataType]) {
        for type in types {
            // Routes have no observer of their own: HealthKit only associates a
            // route forward (workout → route), so capture is driven off the
            // WORKOUT wake, which re-scans recent workouts for routes that Apple
            // finalized after their workout arrived. See `WorkoutRouteReader`.
            guard type.stream != .route else { continue }
            guard let sampleType = type.sampleType else { continue }
            guard activeQueries[type.identifier] == nil else { continue }

            let identifier = type.identifier
            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
                guard let self else {
                    completionHandler()
                    return
                }
                if let error {
                    self.logger.error("Observer error for \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    completionHandler()
                    return
                }
                // Start async sync work. completionHandler is called in the Task's
                // defer so it fires when the durable enqueue work is done (< 30s).
                Task {
                    defer { completionHandler() }
                    await self.syncEngine.handleObserverWake(typeIdentifier: identifier)
                }
            }

            activeQueries[identifier] = query
            store.execute(query)

            store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { [weak self] success, error in
                if let error {
                    self?.logger.error("Background delivery enable failed for \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
                } else {
                    self?.logger.info("Background delivery enabled for \(identifier, privacy: .public) (success=\(success))")
                }
            }

            // Initial read. An HKObserverQuery is not guaranteed to fire for
            // samples that already exist when it is registered, so perform an
            // explicit anchored read now. `handleObserverWake` reads from the
            // persisted anchor and enqueues atomically. On the very first run the
            // anchor is nil, so the read is **forward-only**: it seeds a capture
            // floor of "now" and stages only samples created at/after setup — no
            // historical backfill (ARCHITECTURE.md §4.4). Idempotent: the stored
            // anchor advances and `OutboxDAO` dedupes on sample UUID, so
            // re-starting the observers never duplicates rows or re-seeds.
            Task { [weak self] in
                await self?.syncEngine.handleObserverWake(typeIdentifier: identifier)
            }
        }
    }

    /// Stop all active observer queries and disable background delivery.
    func stop() {
        for (identifier, query) in activeQueries {
            store.stop(query)
            if let type = HealthTypeRegistry.shared.type(forIdentifier: identifier),
               let sampleType = type.sampleType {
                store.disableBackgroundDelivery(for: sampleType) { _, _ in }
            }
        }
        activeQueries.removeAll()
    }
}
