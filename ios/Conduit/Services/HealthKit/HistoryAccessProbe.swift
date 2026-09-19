import Foundation
import HealthKit
import os

private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "HistoryAccessProbe")

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
    /// read, keyed by `HealthDataType.identifier`. A type absent from the
    /// result has no known floor: either the OS predates this API (iOS < 27),
    /// the probe couldn't be completed, or iOS reports full access.
    func limitedHistoryFloors(for types: [HealthDataType]) async -> [String: Date]
}

/// The live implementation, backed by `HKHealthStore.earliestAuthorizedSampleDate(for:)`.
struct HealthKitHistoryAccessProbe: HistoryAccessProbing {
    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    func limitedHistoryFloors(for types: [HealthDataType]) async -> [String: Date] {
        guard #available(iOS 27.0, *) else { return [:] }
        let objectTypes = Set(types.flatMap(\.authorizationTypes))
        guard !objectTypes.isEmpty else { return [:] }
        do {
            let raw = try await store.earliestAuthorizedSampleDate(for: objectTypes)
            return Self.floors(for: types, from: raw)
        } catch {
            // Surface rather than silently fail open to `[:]`: an empty result
            // here reads as "iOS confirms full access", which is the exact
            // ambiguity this probe exists to resolve, so a swallowed error
            // would recreate the original bug one layer up. There is no
            // useful way to propagate this failure into an import that has
            // already started, though — the caller's next probe call (the
            // post-loop check, or the next run) gets another chance, and a
            // logged failure at least distinguishes "we don't know" from "iOS
            // says full access" for anyone debugging a report.
            logger.error("earliestAuthorizedSampleDate failed: \(error.localizedDescription, privacy: .public)")
            return [:]
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
