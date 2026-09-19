import Foundation
import HealthKit
import os

private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "HistoryAccessProbe")

/// What iOS said about how far back Conduit may read each requested type.
///
/// Three states per type, and the third is the whole point: a floor, a
/// confirmed absence of one, or **unknown**. Absent from `floors` while also
/// absent from `unresolvedTypeIDs` is a POSITIVE statement — iOS confirmed full
/// access — and collapsing an unanswerable probe into that is exactly how a
/// 30-day-truncated "All time" import earned a green checkmark in the first
/// place. Unknown stays visible to the caller so it can refuse to call the run
/// complete without claiming a floor it never learned.
///
/// Resolution is per data type, on the failure path as much as the success one:
/// one type iOS won't answer for must not erase what it did say about the rest.
struct HistoryAccessFloors: Sendable, Equatable {
    /// The earliest readable date per limited type, keyed by
    /// `HealthDataType.identifier`.
    var floors: [String: Date] = [:]
    /// Types iOS would not answer for. Neither limited nor confirmed-full.
    var unresolvedTypeIDs: Set<String> = []

    /// Whether iOS answered for this type at all. `false` is "unknown", never
    /// "unrestricted".
    func isResolved(_ type: HealthDataType) -> Bool {
        !unresolvedTypeIDs.contains(type.identifier)
    }
}

/// Detects whether iOS has limited how far back Conduit may read a given
/// HealthKit type's history.
///
/// iOS 27 added a two-stage history-access choice to the read-authorization
/// sheet: alongside Allow/Don't Allow, the user can choose "Past 30 Days and
/// Future Data" instead of "All Recorded Data and Future Data". Under the
/// limited choice, a read entirely outside the granted window returns an
/// EMPTY page with `error == nil` — indistinguishable, to a paging import, from
/// "the user genuinely has no older data" — so this is the only way to learn
/// the floor before (or instead of) reading straight into it.
protocol HistoryAccessProbing: Sendable {
    /// The earliest date each of the given types is currently authorized to
    /// read. A type in neither `floors` nor `unresolvedTypeIDs` has no floor:
    /// the OS predates this API (iOS < 27), iOS reports full access, or the type
    /// has no sample-date floor to report (see
    /// `HealthKitHistoryAccessProbe.carriesSampleDateFloor`).
    func limitedHistoryFloors(for types: [HealthDataType]) async -> HistoryAccessFloors
}

/// The live implementation, backed by `HKHealthStore.earliestAuthorizedSampleDate(for:)`.
struct HealthKitHistoryAccessProbe: HistoryAccessProbing {
    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// Whether `earliestAuthorizedSampleDate(for:)` has an answer to give about
    /// this object type at all.
    ///
    /// `HKWorkoutType` and `HKSeriesType.workoutRoute()` are not
    /// sample-date-bearing types, so asking about them throws — and because the
    /// API answers a whole set at once, including either one poisons every other
    /// type's answer in the same call. They are therefore **not applicable**
    /// rather than unknown: excluded from what is asked and from what must be
    /// confirmed, so they can never hold a run back from `.completed`.
    ///
    /// Accepted tradeoff, deliberate: if these two types turn out to be
    /// limitable by the same iOS 27 grant with no API to detect it, a narrow,
    /// type-scoped version of the original bug applies to them. That is judged
    /// better than the alternative this replaced, where one undetectable type
    /// permanently blocked EVERY iOS 27 user's import from ever completing —
    /// including users with full access and nothing truncated at all.
    static func carriesSampleDateFloor(_ objectType: HKObjectType) -> Bool {
        objectType != HKObjectType.workoutType() && objectType != HKSeriesType.workoutRoute()
    }

    /// The object types of `type` worth asking about. Empty means the whole type
    /// is not applicable — nothing to ask, nothing to confirm.
    static func floorBearingObjectTypes(of type: HealthDataType) -> Set<HKObjectType> {
        Set(type.authorizationTypes.filter(carriesSampleDateFloor))
    }

    func limitedHistoryFloors(for types: [HealthDataType]) async -> HistoryAccessFloors {
        // Below iOS 27 there is no limited-history grant to discover.
        guard #available(iOS 27.0, *) else { return HistoryAccessFloors() }

        // Asked type by type rather than in one batched call: the API answers a
        // set all-or-nothing, so a single member it won't answer for takes every
        // other type's answer down with it. Detection is per data type, and that
        // has to hold on the failure path too.
        var result = HistoryAccessFloors()
        for type in types {
            let objectTypes = Self.floorBearingObjectTypes(of: type)
            guard !objectTypes.isEmpty else { continue }
            do {
                let raw = try await store.earliestAuthorizedSampleDate(for: objectTypes)
                if let floor = Self.floors(for: [type], from: raw)[type.identifier] {
                    result.floors[type.identifier] = floor
                }
            } catch {
                logger.error("earliestAuthorizedSampleDate failed for \(type.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
                result.unresolvedTypeIDs.insert(type.identifier)
            }
        }
        return result
    }

    /// Pure mapping from HealthKit's per-object-type floors to Conduit's
    /// per-Conduit-type floors. No live store needed — unit-testable directly.
    ///
    /// A composite type (blood pressure = systolic + diastolic) is only fully
    /// readable where EVERY constituent is, so its floor is the LATEST (most
    /// restrictive) date among whichever constituents `raw` reports a floor
    /// for. A constituent absent from `raw` has full access and contributes no
    /// floor; a type with no restricted constituent at all has no entry in the
    /// result (full access).
    static func floors(for types: [HealthDataType], from raw: [HKObjectType: Date]) -> [String: Date] {
        var result: [String: Date] = [:]
        for type in types {
            let constituentFloors = floorBearingObjectTypes(of: type).compactMap { raw[$0] }
            guard let latest = constituentFloors.max() else { continue }
            result[type.identifier] = latest
        }
        return result
    }
}
