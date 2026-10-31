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
        /// The Medications API needs iOS 26 or later.
        case medicationsUnavailable
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

    /// Present the system sheet listing the medications in the Health app, so
    /// the user picks which ones Conduit may read. A grant covers the
    /// medication and its dose events; there is no separate dose-event request.
    ///
    /// Per-object authorization prompts on **every** call, even when the user
    /// already chose, so this runs only from an explicit tap or toggle — never
    /// from `request(for:)` or the launch-time `reconcileRegistry`. As with
    /// `request(for:)`, returning normally means only that the sheet was
    /// dismissed: iOS does not say which medications were shared.
    func requestMedicationAccess() async throws {
        guard isHealthDataAvailable else {
            throw AuthorizationError.healthDataUnavailable
        }
        guard #available(iOS 26.0, *) else {
            throw AuthorizationError.medicationsUnavailable
        }
        try await store.requestPerObjectReadAuthorization(for: HKObjectType.userAnnotatedMedicationType(), predicate: nil)
    }
}
