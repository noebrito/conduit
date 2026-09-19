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
    /// either the OS predates this API (iOS < 27) or iOS reports full access.
    func limitedHistoryFloors(for types: [HealthDataType]) async -> HistoryAccessFloors
}

/// The live implementation, backed by `HKHealthStore.earliestAuthorizedSampleDate(for:)`.
struct HealthKitHistoryAccessProbe: HistoryAccessProbing {
    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    func limitedHistoryFloors(for types: [HealthDataType]) async -> HistoryAccessFloors {
        // Below iOS 27 there is no limited-history grant to discover.
        guard #available(iOS 27.0, *) else { return HistoryAccessFloors() }

        // EVERY type goes in, workouts and routes included: `HKWorkoutType` and
        // `HKSeriesType` are ordinary `HKSampleType` subclasses, and the API's
        // documented contract takes any `NSSet<HKObjectType *>` and simply OMITS
        // from the result whichever types have no limited-access date. Omission
        // is the "not limited" answer, not a rejection — so singling any type out
        // would just hide a real floor and hand it a green checkmark over a
        // truncated history.
        let probeable = types.filter { !$0.authorizationTypes.isEmpty }
        let objectTypes = Set(probeable.flatMap(\.authorizationTypes))
        guard !objectTypes.isEmpty else { return HistoryAccessFloors() }

        do {
            let raw = try await store.earliestAuthorizedSampleDate(for: objectTypes)
            return HistoryAccessFloors(floors: Self.floors(for: probeable, from: raw))
        } catch {
            // A failure is documented as whole-call (nil dictionary + error), not
            // per member, so nothing is known about ANY type asked about. Every
            // one of them is unknown rather than confirmed-full — the fail-closed
            // direction, so no unconfirmed range can be called complete.
            logger.error("earliestAuthorizedSampleDate failed: \(error.localizedDescription, privacy: .public)")
            return HistoryAccessFloors(unresolvedTypeIDs: Set(probeable.map(\.identifier)))
        }
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
            let constituentFloors = type.authorizationTypes.compactMap { raw[$0] }
            guard let latest = constituentFloors.max() else { continue }
            result[type.identifier] = latest
        }
        return result
    }
}
