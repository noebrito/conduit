import CoreLocation
import Foundation
import HealthKit

/// Reads a workout's stored GPS route (`HKWorkoutRoute`) and maps it into a
/// wire-format `Conduit_V1_Sample` carrying a `RouteValue`.
///
/// ## Why this isn't a fifth `AnchoredReader.makeSample` case
///
/// `makeSample` is a **synchronous 1:1 map** from one `HKSample` to one
/// `Conduit_V1_Sample`. A route can't be produced that way: given an `HKWorkout`
/// you must (1) run an `HKAnchoredObjectQuery` to find its route objects, then
/// (2) run an `HKWorkoutRouteQuery` per route, which streams `CLLocation` batches
/// through repeated callbacks until `done`. That two-step async read is this
/// type's whole reason to exist. Everything downstream of "produce a
/// `Conduit_V1_Sample`" — outbox, dedupe, throttle, batcher, upload — is reused
/// verbatim.
///
/// ## Privacy: no location permission is involved
///
/// This reads a route Apple **already stored** with the workout, after the fact.
/// It never starts live location, so there is no CoreLocation authorization, no
/// `NSLocation*UsageDescription`, no blue location indicator, and no new
/// entitlement — the existing HealthKit read authorization for
/// `HKSeriesType.workoutRoute()` is the whole permission story.
///
/// ## Association and timing (the fiddly HealthKit part)
///
/// HealthKit's association is **forward only**: given a workout, find its route
/// (`HKQuery.predicateForObjects(from: workout)`). There is no public reverse
/// lookup, so capture must be workout-driven. And Apple attaches the route
/// **shortly after** the workout ends, so the first observer wake for a workout
/// often finds no route yet. `SyncEngine` handles that by re-scanning recent
/// workouts on each wake; UUID dedupe makes the re-attempts free.
///
/// ## Batch-size note
///
/// Each route is ONE outbox row with a comparatively large payload. The point
/// budget (`pointBudget`) is what keeps a batch of several routes comfortably
/// under the ingester's 16 MiB body cap.
struct WorkoutRouteReader {
    /// Maximum points carried on the wire for a single route. A 1 Hz recording is
    /// ~3,600 points/hour, so this passes a typical workout through untouched
    /// while bounding a long hike or ride (which can reach 20k–40k points) to one
    /// document with one dedupe key. Routes at or under the budget are sent
    /// **verbatim** — simplification only ever kicks in above it.
    static let pointBudget = 5_000

    /// Douglas–Peucker tolerance. At ~5 m a simplified polyline is visually
    /// indistinguishable from the raw trace at any map zoom a workout is viewed
    /// at, while collapsing the long straight runs that dominate a big route.
    static let simplificationEpsilonMeters = 5.0

    /// How far back the workout re-scan looks for workouts whose route may not
    /// have been captured yet. Comfortably longer than Apple's route
    /// finalization delay, and short enough that the re-scan stays cheap.
    static let rescanWindowDays = 7

    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    // MARK: - The two-step read

    /// Every route sample for `workout`, ready to stage. Returns an **empty
    /// array** when the workout has no route — the common case (treadmill,
    /// strength training, yoga, manually entered workouts, and any outdoor
    /// workout recorded with GPS off). That is a normal outcome, not an error:
    /// capture nothing, enqueue nothing.
    func routeSamples(for workout: HKWorkout) async throws -> [Conduit_V1_Sample] {
        let routes = try await routes(for: workout)
        var samples: [Conduit_V1_Sample] = []
        for route in routes {
            let locations = try await locations(for: route)
            guard let sample = Self.makeRouteSample(route: route, workout: workout, locations: locations) else {
                continue
            }
            samples.append(sample)
        }
        return samples
    }

    /// Step 1: find the route objects attached to `workout` (usually 0 or 1).
    func routes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout),
                anchor: nil,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }
    }

    /// Step 2: enumerate a route's locations. `HKWorkoutRouteQuery` delivers them
    /// in **multiple callback batches**; we accumulate until `done` and resume
    /// exactly once (a continuation resumed twice traps).
    func locations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            var accumulated: [CLLocation] = []
            var finished = false
            let query = HKWorkoutRouteQuery(route: route) { query, batch, done, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    self.store.stop(query)
                    continuation.resume(throwing: error)
                    return
                }
                accumulated.append(contentsOf: batch ?? [])
                if done {
                    finished = true
                    continuation.resume(returning: accumulated)
                }
            }
            store.execute(query)
        }
    }

    /// Workouts that ended within `[since, now]`, newest first — the re-scan and
    /// backfill candidate set. `limit` bounds one page.
    func workouts(since: Date?, before: Date? = nil, limit: Int) async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: AnchoredReader.importWindowPredicate(since: since, before: before),
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
    }

    // MARK: - HKWorkoutRoute → Conduit_V1_Sample (pure)

    /// Build the wire sample for one route. `nil` when the route carries no
    /// locations — an empty route is nothing worth sending.
    ///
    /// The enclosing `Sample.uuid` is the **route's** uuid, so the whole route
    /// (all its points) dedupes atomically as one document under `op_type:
    /// create`. `RouteValue.workoutUuid` is the FK back to the workout's own
    /// sample.
    static func makeRouteSample(
        route: HKWorkoutRoute,
        workout: HKWorkout,
        locations: [CLLocation]
    ) -> Conduit_V1_Sample? {
        makeRouteSample(
            routeUUID: route.uuid.uuidString,
            workoutUUID: workout.uuid.uuidString,
            activityType: AnchoredReader.workoutActivityName(workout.workoutActivityType),
            source: AnchoredReader.makeSource(route),
            locations: locations
        )
    }

    /// The `HKHealthStore`-free core, so route mapping is unit-testable from
    /// synthetic `CLLocation`s (the simulator cannot produce a real
    /// `HKWorkoutRoute`).
    static func makeRouteSample(
        routeUUID: String,
        workoutUUID: String,
        activityType: String,
        source: Conduit_V1_Source,
        locations: [CLLocation]
    ) -> Conduit_V1_Sample? {
        guard !locations.isEmpty else { return nil }

        // Oldest → newest, as the wire contract requires. HealthKit delivers
        // route locations in order, but sorting makes the guarantee ours.
        let ordered = locations.sorted { $0.timestamp < $1.timestamp }
        let points = downsample(ordered).map(makePoint)

        var value = Conduit_V1_RouteValue()
        value.workoutUuid = workoutUUID
        value.activityType = activityType
        value.points = points

        var sample = Conduit_V1_Sample()
        sample.uuid = routeUUID
        // The route's span is its own first/last fix, which can differ slightly
        // from the enclosing workout's start/end.
        sample.startUnixMs = AnchoredReader.unixMillis(ordered.first!.timestamp)
        sample.endUnixMs = AnchoredReader.unixMillis(ordered.last!.timestamp)
        sample.source = source
        sample.route = value
        return sample
    }

    static func makePoint(_ location: CLLocation) -> Conduit_V1_RoutePoint {
        var point = Conduit_V1_RoutePoint()
        point.lat = location.coordinate.latitude
        point.lng = location.coordinate.longitude
        point.altitudeM = location.altitude
        point.timestampUnixMs = AnchoredReader.unixMillis(location.timestamp)
        point.horizontalAccuracyM = location.horizontalAccuracy
        point.verticalAccuracyM = location.verticalAccuracy
        point.speedMps = location.speed
        point.courseDeg = location.course
        return point
    }

    // MARK: - Downsampling

    /// Bound a route to `budget` points, preserving its shape.
    ///
    /// A route at or under the budget is returned **unchanged** — the common case,
    /// so a typical workout ships at full fidelity. Above it:
    ///
    /// 1. **Douglas–Peucker** at `epsilonMeters` drops points that lie within the
    ///    tolerance of the line their neighbours already describe. This is
    ///    shape-preserving: it collapses long straight runs (where most of a big
    ///    route's points live) and keeps every turn.
    /// 2. If the simplified path is *still* over budget (a genuinely twisty
    ///    multi-hour route), an even **stride decimation** brings it to the budget.
    ///    First and last points are always kept, so the route's endpoints — which
    ///    the server indexes as `start_point`/`end_point` — stay exact.
    ///
    /// Retained points keep their full-fidelity altitude/speed/accuracy; only
    /// whole points are dropped, never averaged.
    static func downsample(
        _ locations: [CLLocation],
        budget: Int = pointBudget,
        epsilonMeters: Double = simplificationEpsilonMeters
    ) -> [CLLocation] {
        guard locations.count > budget, budget >= 2 else { return locations }
        let simplified = douglasPeucker(locations, epsilonMeters: epsilonMeters)
        guard simplified.count > budget else { return simplified }
        return stride(simplified, to: budget)
    }

    /// Keep `budget` points at an even stride, always including the first and last.
    static func stride(_ locations: [CLLocation], to budget: Int) -> [CLLocation] {
        guard locations.count > budget, budget >= 2 else { return locations }
        // Distribute `budget` samples across the index range inclusive of both ends.
        let lastIndex = Double(locations.count - 1)
        let step = lastIndex / Double(budget - 1)
        var kept: [CLLocation] = []
        kept.reserveCapacity(budget)
        var previousIndex = -1
        for i in 0..<budget {
            let index = min(locations.count - 1, Int((Double(i) * step).rounded()))
            if index != previousIndex {
                kept.append(locations[index])
                previousIndex = index
            }
        }
        return kept
    }

    /// Iterative Douglas–Peucker. Iterative rather than recursive so a 40k-point
    /// route can't blow the stack.
    static func douglasPeucker(_ locations: [CLLocation], epsilonMeters: Double) -> [CLLocation] {
        guard locations.count > 2 else { return locations }

        var keep = [Bool](repeating: false, count: locations.count)
        keep[0] = true
        keep[locations.count - 1] = true

        // Project once to a local flat plane (metres) so perpendicular distance is
        // a plain 2-D computation. Equirectangular projection about the route's
        // first latitude — exact enough at the scale of a single workout.
        let origin = locations[0].coordinate
        let metresPerDegreeLat = 111_320.0
        let metresPerDegreeLng = 111_320.0 * cos(origin.latitude * .pi / 180)
        let projected: [(x: Double, y: Double)] = locations.map {
            (x: ($0.coordinate.longitude - origin.longitude) * metresPerDegreeLng,
             y: ($0.coordinate.latitude - origin.latitude) * metresPerDegreeLat)
        }

        var stack: [(Int, Int)] = [(0, locations.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var farthestIndex = first
            var farthestDistance = 0.0
            for i in (first + 1)..<last {
                let distance = perpendicularDistance(projected[i], from: projected[first], to: projected[last])
                if distance > farthestDistance {
                    farthestDistance = distance
                    farthestIndex = i
                }
            }
            if farthestDistance > epsilonMeters {
                keep[farthestIndex] = true
                stack.append((first, farthestIndex))
                stack.append((farthestIndex, last))
            }
        }

        return zip(locations, keep).compactMap { $1 ? $0 : nil }
    }

    /// Perpendicular distance from `point` to the segment `start`–`end`, in the
    /// projected metre plane. A degenerate (zero-length) segment falls back to
    /// plain point distance.
    private static func perpendicularDistance(
        _ point: (x: Double, y: Double),
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double)
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        // Cross product magnitude / segment length = perpendicular distance to the
        // infinite line. DP's invariant (the endpoints are kept) makes the line
        // form the right measure here.
        let cross = abs(dx * (start.y - point.y) - (start.x - point.x) * dy)
        return cross / lengthSquared.squareRoot()
    }
}
