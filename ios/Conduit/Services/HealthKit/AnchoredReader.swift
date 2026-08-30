import Foundation
import HealthKit

/// Performs an incremental (anchored) read of a single HealthKit type and maps
/// the results into wire-format `Conduit_V1_Sample` values.
///
/// ## Critical invariant (ARCHITECTURE.md §4.4)
///
/// The `newAnchor` returned here marks "everything up to this point has been
/// read". The caller MUST persist that anchor **and** enqueue the returned
/// `samples` in the **same** SQLite transaction. If the anchor is saved without
/// the samples (e.g. a crash between two separate writes), the next read starts
/// *after* those samples and they are **permanently lost** — HealthKit will
/// never hand them to us again.
///
/// `OutboxDAO.ingest(samples:hkTypeId:webhookId:anchorBlob:)` is the supported
/// way to satisfy this: it enqueues and advances the anchor atomically. Do not
/// save `result.newAnchorData` through any other path.
struct AnchoredReader {
    /// Result of one anchored read.
    struct Result {
        /// Newly observed samples, already converted to wire format.
        let samples: [Conduit_V1_Sample]
        /// UUIDs of samples HealthKit reported as DELETED since the last anchor
        /// (from the anchored query's `deletedObjects`). Because an anchored read
        /// is per `HealthDataType`, every uuid here belongs to this read's type,
        /// so the caller knows which stream each tombstone routes to. Empty for
        /// the import path (a point-in-time snapshot has nothing to delete) and
        /// for any read with no deletions — so the upsert flow is unchanged.
        let deletedUuids: [String]
        /// The anchor to persist (atomically with `samples`) so the next read
        /// resumes from here. `nil` only if HealthKit returned no anchor.
        let newAnchor: HKQueryAnchor?

        /// The anchor encoded for storage in `data_type_config.anchor_blob`.
        var newAnchorData: Data? {
            guard let newAnchor else { return nil }
            return try? AnchoredReader.archiveAnchor(newAnchor)
        }

        /// The `end_unix_ms` of the OLDEST sample in this page, as a `Date`, or
        /// `nil` if the page is empty. This is the newest-first import paging
        /// cursor: pass it as the next page's `before` bound. Because
        /// `readImportPage` sorts by `endDate` descending, the oldest sample is
        /// the last element.
        var oldestEndDate: Date? {
            guard let last = samples.last else { return nil }
            return Date(timeIntervalSince1970: Double(last.endUnixMs) / 1000.0)
        }
    }

    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// Read all samples for `type` newer than `anchor`.
    ///
    /// ## Forward-only default (ARCHITECTURE.md §4.4)
    ///
    /// On the **first** read for a type the caller has no anchor (`anchor ==
    /// nil`). An anchor-less, predicate-less anchored query returns the user's
    /// **entire** Apple Health history for the type — millions of samples. To
    /// capture only recent data going forward, the caller passes
    /// `since = start-of-today` (device-local midnight, via
    /// `SyncEngine.forwardCaptureFloor()`) on that first read: we then run the
    /// query with a `predicateForSamples(withStart: since, ...)` floor so it
    /// returns just today's samples from midnight → now (one bounded day) and
    /// hands back a fresh anchor marking "everything up to now has been seen".
    /// That bounded result + anchor are persisted, and every subsequent read
    /// uses the stored (non-nil) anchor with **no** predicate — so incremental
    /// capture is unaffected.
    ///
    /// The floor is applied **only** when `anchor == nil && since != nil`. When
    /// an anchor exists we ignore `since` and keep `predicate: nil`; when both
    /// are nil (e.g. an explicit historical import) we read all history.
    ///
    /// - Parameters:
    ///   - type: the data type to read.
    ///   - anchor: the last persisted anchor, or `nil` to read from the start.
    ///   - since: forward-only capture floor (start-of-today), applied only on
    ///     the first (anchor-less) read. `nil` reads all history (import path).
    ///   - limit: max samples to return in this pass (default: no limit).
    /// - Returns: the new samples and the anchor to persist atomically with them.
    func read(
        type: HealthDataType,
        anchor: HKQueryAnchor?,
        since: Date? = nil,
        limit: Int = HKObjectQueryNoLimit
    ) async throws -> Result {
        guard let sampleType = type.sampleType else {
            return Result(samples: [], deletedUuids: [], newAnchor: anchor)
        }

        // Forward-only floor applies ONLY on the first (anchor-less) read.
        // Once an anchor exists, ongoing incremental reads stay predicate-less.
        let predicate: NSPredicate? = (anchor == nil)
            ? Self.importPredicate(since: since)
            : nil

        return try await runAnchoredQuery(
            sampleType: sampleType,
            type: type,
            predicate: predicate,
            anchor: anchor,
            limit: limit
        )
    }

    /// One page of an **explicit historical import**, delivered **NEWEST-FIRST**
    /// (ARCHITECTURE.md §4.4, "Import history" opt-in).
    ///
    /// The forward-capture path uses `HKAnchoredObjectQuery`, which returns
    /// samples in HealthKit insertion order (≈ oldest-first for an accumulated
    /// history) and cannot be sorted. For an import that is the wrong order: a
    /// multi-year import would grind through 2022 → today before the user sees
    /// any recent day. So the import instead uses a **date-windowed
    /// `HKSampleQuery` sorted by `endDate` descending**, walking a moving upper
    /// bound (`before`) backward through the range. Each page returns the most
    /// recent `limit` samples older than `before`, so recent days land first.
    ///
    /// Paging cursor: the caller passes `before: nil` for the first page (read
    /// from now backward) and, for each subsequent page, the `endDate` of the
    /// **oldest** sample returned by the previous page (available as
    /// `Result.oldestEndDate`). The window is boundary-**inclusive** (default
    /// predicate options), so a sample sitting exactly on the cursor is re-read
    /// on the next page and harmlessly skipped by `OutboxDAO.stageImport`'s UUID
    /// dedupe — this avoids ever dropping same-timestamp siblings that a fixed
    /// page limit split across two pages.
    ///
    /// Like the anchored import it replaced, this NEVER touches the live
    /// forward-capture anchor in `data_type_config`; results are staged via
    /// `OutboxDAO.stageImport(...)`, which does not advance that anchor.
    ///
    /// - Parameters:
    ///   - type: the data type to read.
    ///   - since: the user-chosen start of the import window (lower bound);
    ///     `nil` imports all history ("All time").
    ///   - before: the upper-bound page cursor — `nil` for the first page (up to
    ///     now), then the previous page's `oldestEndDate`.
    ///   - limit: page size, so a large import drains in bounded chunks.
    func readImportPage(
        type: HealthDataType,
        since: Date?,
        before: Date?,
        limit: Int
    ) async throws -> Result {
        guard let sampleType = type.sampleType else {
            return Result(samples: [], deletedUuids: [], newAnchor: nil)
        }
        let predicate = Self.importWindowPredicate(since: since, before: before)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: sort
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let mapped = (samples ?? []).compactMap { Self.makeSample(from: $0, type: type) }
                // Import is a point-in-time snapshot of current Health — nothing
                // to delete.
                continuation.resume(returning: Result(samples: mapped, deletedUuids: [], newAnchor: nil))
            }
            store.execute(query)
        }
    }

    /// Build the date-floor predicate for a **forward** read. `nil` start means
    /// "no floor" (all history) — the caller passes `nil` for an "All time"
    /// import or when a stored anchor already bounds the read. Extracted so the
    /// predicate construction is unit-testable without a live `HKHealthStore`.
    static func importPredicate(since: Date?) -> NSPredicate? {
        since.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: []) }
    }

    /// Build the date-window predicate for one **newest-first import** page:
    /// samples between `since` (lower) and `before` (upper). Both `nil` → no
    /// predicate (all history, up to now). Uses default (non-strict) options so
    /// the bounds are inclusive for point samples — a sample exactly on the
    /// `before` cursor is re-read on the next page and deduped, which is safer
    /// than a strict/exclusive bound that could drop same-timestamp samples a
    /// page split apart. Static + `HKHealthStore`-free so it is unit-testable.
    static func importWindowPredicate(since: Date?, before: Date?) -> NSPredicate? {
        guard since != nil || before != nil else { return nil }
        return HKQuery.predicateForSamples(withStart: since, end: before, options: [])
    }

    private func runAnchoredQuery(
        sampleType: HKSampleType,
        type: HealthDataType,
        predicate: NSPredicate?,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            // One-shot anchored read: a results handler with no update handler
            // fires exactly once with the batch newer than `anchor`. The third
            // handler param is `deletedObjects` — samples HealthKit removed since
            // the anchor (a LoseIt edit/remove deletes the old sample). We used
            // to discard it (`_`); now we collect each deleted uuid so the caller
            // can stage a tombstone, so an edited food doesn't leave a ghost doc.
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: predicate,
                anchor: anchor,
                limit: limit
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let mapped = (samples ?? []).compactMap { Self.makeSample(from: $0, type: type) }
                let deletedUuids = (deletedObjects ?? []).map { $0.uuid.uuidString }
                continuation.resume(returning: Result(samples: mapped, deletedUuids: deletedUuids, newAnchor: newAnchor))
            }
            store.execute(query)
        }
    }

    // MARK: - Anchor (de)serialization

    /// Archive an `HKQueryAnchor` to `Data` for storage.
    static func archiveAnchor(_ anchor: HKQueryAnchor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    /// Restore an `HKQueryAnchor` from stored `Data`, or `nil` if absent/invalid.
    static func unarchiveAnchor(_ data: Data?) -> HKQueryAnchor? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    // MARK: - HKSample → Conduit_V1_Sample

    /// Convert any supported `HKSample` into wire format, dispatching on the
    /// type's stream (the four value shapes from ARCHITECTURE.md §3.2).
    static func makeSample(from hkSample: HKSample, type: HealthDataType) -> Conduit_V1_Sample? {
        var sample = Conduit_V1_Sample()
        sample.uuid = hkSample.uuid.uuidString
        sample.startUnixMs = unixMillis(hkSample.startDate)
        sample.endUnixMs = unixMillis(hkSample.endDate)
        sample.source = makeSource(hkSample)

        switch type.stream {
        case .quantity:
            guard
                let quantitySample = hkSample as? HKQuantitySample,
                let unitString = type.defaultUnit
            else { return nil }
            var value = Conduit_V1_QuantityValue()
            value.value = quantitySample.quantity.doubleValue(for: HKUnit(from: unitString))
            value.unit = unitString
            sample.quantity = value

        case .category:
            guard let categorySample = hkSample as? HKCategorySample else { return nil }
            var value = Conduit_V1_CategoryValue()
            value.value = Int32(categorySample.value)
            value.valueName = categoryValueName(type: type, rawValue: categorySample.value)
            sample.category = value

        case .workout:
            guard let workout = hkSample as? HKWorkout else { return nil }
            var value = Conduit_V1_WorkoutValue()
            value.activityType = workoutActivityName(workout.workoutActivityType)
            value.durationSeconds = workout.duration
            value.totalEnergyKcal = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0
            value.totalDistanceM = workout.totalDistance?.doubleValue(for: .meter()) ?? 0
            sample.workout = value

        case .correlation:
            guard let correlation = hkSample as? HKCorrelation else { return nil }
            var value = Conduit_V1_CorrelationValue()
            // v1 correlation is blood pressure only: components are mmHg
            // quantity samples (systolic + diastolic).
            value.components = correlation.objects
                .compactMap { $0 as? HKQuantitySample }
                .map { makeCorrelationComponent($0, unitString: "mmHg") }
            sample.correlation = value

        case .route:
            // Routes are NOT produced here: a route is a two-step async read
            // (find the workout's route objects, then stream their locations),
            // which this synchronous 1:1 map cannot express. `WorkoutRouteReader`
            // owns them, driven off the workout observer wake. Returning nil keeps
            // any accidental generic read of the route series type a harmless
            // no-op rather than a malformed sample.
            return nil
        }

        return sample
    }

    private static func makeCorrelationComponent(
        _ quantitySample: HKQuantitySample,
        unitString: String
    ) -> Conduit_V1_Sample {
        var sample = Conduit_V1_Sample()
        sample.uuid = quantitySample.uuid.uuidString
        sample.startUnixMs = unixMillis(quantitySample.startDate)
        sample.endUnixMs = unixMillis(quantitySample.endDate)
        sample.source = makeSource(quantitySample)
        var value = Conduit_V1_QuantityValue()
        value.value = quantitySample.quantity.doubleValue(for: HKUnit(from: unitString))
        value.unit = unitString
        sample.quantity = value
        return sample
    }

    /// Wire `Source` for any HK sample. Shared with `WorkoutRouteReader`, whose
    /// route samples carry the route's own source revision.
    static func makeSource(_ hkSample: HKSample) -> Conduit_V1_Source {
        let revision = hkSample.sourceRevision
        var source = Conduit_V1_Source()
        source.name = revision.source.name
        source.bundleID = revision.source.bundleIdentifier
        source.productType = revision.productType ?? ""
        return source
    }

    static func unixMillis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Human-readable name for a sleep / heart-event category value. Falls back
    /// to the raw integer for types without a named mapping.
    static func categoryValueName(type: HealthDataType, rawValue: Int) -> String {
        switch type.identifier {
        case HKCategoryTypeIdentifier.sleepAnalysis.rawValue:
            guard let sleepValue = HKCategoryValueSleepAnalysis(rawValue: rawValue) else {
                return "value\(rawValue)"
            }
            switch sleepValue {
            case .inBed: return "inBed"
            case .asleepUnspecified: return "asleepUnspecified"
            case .awake: return "awake"
            case .asleepCore: return "asleepCore"
            case .asleepDeep: return "asleepDeep"
            case .asleepREM: return "asleepREM"
            @unknown default: return "value\(rawValue)"
            }
        case HKCategoryTypeIdentifier.appleStandHour.rawValue:
            guard let standValue = HKCategoryValueAppleStandHour(rawValue: rawValue) else {
                return "value\(rawValue)"
            }
            switch standValue {
            case .stood: return "stood"
            case .idle: return "idle"
            @unknown default: return "value\(rawValue)"
            }
        case HKCategoryTypeIdentifier.mindfulSession.rawValue:
            return "mindfulSession"
        case HKCategoryTypeIdentifier.highHeartRateEvent.rawValue:
            return "highHeartRateEvent"
        case HKCategoryTypeIdentifier.lowHeartRateEvent.rawValue:
            return "lowHeartRateEvent"
        case HKCategoryTypeIdentifier.irregularHeartRhythmEvent.rawValue:
            return "irregularHeartRhythmEvent"
        default:
            return "value\(rawValue)"
        }
    }

    /// Compact name for common workout activity types; numeric fallback keeps
    /// the value stable and unambiguous for the ingester (a keyword field).
    static func workoutActivityName(_ activity: HKWorkoutActivityType) -> String {
        switch activity {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .hiking: return "hiking"
        case .yoga: return "yoga"
        case .functionalStrengthTraining: return "functionalStrengthTraining"
        case .traditionalStrengthTraining: return "traditionalStrengthTraining"
        case .highIntensityIntervalTraining: return "highIntensityIntervalTraining"
        case .elliptical: return "elliptical"
        case .rowing: return "rowing"
        case .coreTraining: return "coreTraining"
        case .stairClimbing: return "stairClimbing"
        case .pilates: return "pilates"
        case .dance: return "dance"
        default: return "activityType\(activity.rawValue)"
        }
    }
}
