import Foundation
import HealthKit

/// Requests HealthKit **read** authorization for a set of data types.
///
/// Conduit only ever reads from HealthKit (it shares nothing back), so the
/// share set is always empty. iOS intentionally does not reveal whether the
/// user granted read access (§8); a successful return here only means the user
/// dismissed the permission sheet, not that any particular type was allowed.
struct HealthKitAuthorizer {
    enum AuthorizationError: Error {
        /// HealthKit isn't available on this device (e.g. iPad without Health).
        case healthDataUnavailable
    }

    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// Whether HealthKit is usable on this device at all.
    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Request read authorization for the given data types.
    ///
    /// Triggers the system permission sheet (once per type, the first time it is
    /// requested). Safe to call repeatedly — subsequent calls for
    /// already-decided types resolve without UI.
    func request(for types: [HealthDataType]) async throws {
        guard isHealthDataAvailable else {
            throw AuthorizationError.healthDataUnavailable
        }
        // Build the read set from `authorizationTypes`, not `sampleType`: blood
        // pressure must authorize its constituent quantity types, since passing
        // the correlation type to `requestAuthorization` throws an NSException
        // that crashes the permission flow.
        let readTypes = Set(types.flatMap { $0.authorizationTypes })
        guard !readTypes.isEmpty else { return }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Convenience: request authorization for every registered v1 type.
    func requestAll(registry: HealthTypeRegistry = .shared) async throws {
        try await request(for: registry.all)
    }
}
