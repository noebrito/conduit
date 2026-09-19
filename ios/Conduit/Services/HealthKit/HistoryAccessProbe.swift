import Foundation
import HealthKit
import os

private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "HistoryAccessProbe")

/// What iOS said about how far back Conduit may read each requested type.
///
/// "No floors" and "we don't know" must never be the same value. An empty
/// `resolved` dictionary is a POSITIVE statement — iOS confirmed full access for
/// every type asked about — and collapsing a failed probe into it is exactly how
/// a 30-day-truncated "All time" import earned a green checkmark in the first
/// place. `unresolved` keeps that ambiguity visible to the caller so it can
/// refuse to call the run complete.
enum HistoryAccessFloors: Sendable, Equatable {
    /// iOS answered for every requested type. A type absent from the dictionary
    /// has confirmed full access.
    case resolved([String: Date])
    /// iOS could not answer, so NO type's history access is confirmed.
    case unresolved

    /// The floors iOS reported, keyed by `HealthDataType.identifier` — empty
    /// when nothing is known. Never read this alone to decide that access is
    /// unrestricted; pair it with `isResolved`.
    var floors: [String: Date] {
        switch self {
        case .resolved(let floors): return floors
        case .unresolved: return [:]
        }
    }

    /// Whether the floors above are a real answer rather than an absence of one.
    var isResolved: Bool {
        switch self {
        case .resolved: return true
        case .unresolved: return false
        }
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
    /// read, keyed by `HealthDataType.identifier`. A type absent from a
    /// `.resolved` result has no floor: either the OS predates this API
    /// (iOS < 27) or iOS reports full access. A probe that could not be
    /// completed returns `.unresolved` instead.
    func limitedHistoryFloors(for types: [HealthDataType]) async -> HistoryAccessFloors
}

/// The live implementation, backed by `HKHealthStore.earliestAuthorizedSampleDate(for:)`.
struct HealthKitHistoryAccessProbe: HistoryAccessProbing {
    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    func limitedHistoryFloors(for types: [HealthDataType]) async -> HistoryAccessFloors {
        // Below iOS 27 there is no limited-history grant to discover, and with
        // nothing to ask about there is nothing to restrict — both are real
        // answers, not failures.
        guard #available(iOS 27.0, *) else { return .resolved([:]) }
        let objectTypes = Set(types.flatMap(\.authorizationTypes))
        guard !objectTypes.isEmpty else { return .resolved([:]) }
        do {
            let raw = try await store.earliestAuthorizedSampleDate(for: objectTypes)
            return .resolved(Self.floors(for: types, from: raw))
        } catch {
            logger.error("earliestAuthorizedSampleDate failed: \(error.localizedDescription, privacy: .public)")
            return .unresolved
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
