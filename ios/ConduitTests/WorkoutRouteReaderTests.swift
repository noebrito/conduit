import CoreLocation
import HealthKit
import XCTest
@testable import Conduit

/// Covers everything about GPS route capture that does NOT need a real
/// `HKWorkoutRoute` — which is everything except the HealthKit read itself.
///
/// The simulator cannot produce a genuine `HKWorkoutRoute` (there is no API to
/// author one, and no real workout to attach it to), so the two-step read and
/// Apple's route-finalization timing are validated on-device, not here. What IS
/// covered here is the part that would silently produce wrong data: the mapping
/// to wire format, the downsampling, the empty-route path, and dedupe.
final class WorkoutRouteReaderTests: XCTestCase {
    private let routeUUID = "AAAAAAAA-0000-0000-0000-000000000001"
    private let workoutUUID = "BBBBBBBB-0000-0000-0000-000000000002"
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    /// A location on a due-north straight line from `start`, `metres` along.
    private func location(
        northOf start: CLLocationCoordinate2D,
        metres: Double,
        at offsetSeconds: TimeInterval,
        altitude: Double = 100,
        speed: Double = 1.4,
        course: Double = 0
    ) -> CLLocation {
        let coordinate = CLLocationCoordinate2D(
            latitude: start.latitude + metres / 111_320.0,
            longitude: start.longitude
        )
        return CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: 5,
            verticalAccuracy: 3,
            course: course,
            speed: speed,
            timestamp: epoch.addingTimeInterval(offsetSeconds)
        )
    }

    private var origin: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
    }

    /// A straight-line walk: `count` points, one per second, one metre apart.
    private func straightLine(count: Int) -> [CLLocation] {
        (0..<count).map {
            location(northOf: origin, metres: Double($0), at: TimeInterval($0))
        }
    }

    private func makeSample(locations: [CLLocation]) -> Conduit_V1_Sample? {
        var source = Conduit_V1_Source()
        source.name = "Apple Watch"
        source.bundleID = "com.apple.health"
        source.productType = "Watch7,1"
        return WorkoutRouteReader.makeRouteSample(
            routeUUID: routeUUID,
            workoutUUID: workoutUUID,
            activityType: "walking",
            source: source,
            locations: locations
        )
    }

    // MARK: - Mapping

    func testBuildsRouteSampleFromLocations() throws {
        let locations = [
            location(northOf: origin, metres: 0, at: 0, altitude: 100, speed: 1.2, course: 10),
            location(northOf: origin, metres: 10, at: 5, altitude: 104, speed: 1.6, course: 12),
            location(northOf: origin, metres: 25, at: 12, altitude: 108, speed: 1.9, course: 15),
        ]

        let sample = try XCTUnwrap(makeSample(locations: locations))

        // The enclosing Sample.uuid is the ROUTE's uuid — that is the dedupe key
        // the ingester writes the whole route under.
        XCTAssertEqual(sample.uuid, routeUUID)
        XCTAssertEqual(sample.route.workoutUuid, workoutUUID)
        XCTAssertEqual(sample.route.activityType, "walking")
        XCTAssertEqual(sample.source.name, "Apple Watch")

        // Span is the route's own first/last fix.
        XCTAssertEqual(sample.startUnixMs, Int64(epoch.timeIntervalSince1970 * 1000))
        XCTAssertEqual(sample.endUnixMs, Int64(epoch.addingTimeInterval(12).timeIntervalSince1970 * 1000))

        XCTAssertEqual(sample.route.points.count, 3)
        let first = sample.route.points[0]
        XCTAssertEqual(first.lat, origin.latitude, accuracy: 1e-9)
        XCTAssertEqual(first.lng, origin.longitude, accuracy: 1e-9)
        XCTAssertEqual(first.altitudeM, 100, accuracy: 1e-6)
        XCTAssertEqual(first.horizontalAccuracyM, 5, accuracy: 1e-6)
        XCTAssertEqual(first.verticalAccuracyM, 3, accuracy: 1e-6)
        XCTAssertEqual(first.speedMps, 1.2, accuracy: 1e-6)
        XCTAssertEqual(first.courseDeg, 10, accuracy: 1e-6)
        XCTAssertEqual(first.timestampUnixMs, Int64(epoch.timeIntervalSince1970 * 1000))
    }

    func testPointsAreOrderedOldestToNewest() throws {
        let shuffled = [
            location(northOf: origin, metres: 20, at: 20),
            location(northOf: origin, metres: 0, at: 0),
            location(northOf: origin, metres: 10, at: 10),
        ]

        let sample = try XCTUnwrap(makeSample(locations: shuffled))

        let timestamps = sample.route.points.map(\.timestampUnixMs)
        XCTAssertEqual(timestamps, timestamps.sorted(), "wire contract is oldest → newest")
        XCTAssertLessThan(sample.startUnixMs, sample.endUnixMs)
    }

    /// The common case: indoor / treadmill / manual / GPS-off workouts have no
    /// route. Nothing is built, so nothing can be enqueued.
    func testEmptyRouteProducesNoSample() {
        XCTAssertNil(makeSample(locations: []))
    }

    // MARK: - Downsampling

    func testRouteAtOrUnderBudgetIsSentVerbatim() {
        let locations = straightLine(count: 100)

        let kept = WorkoutRouteReader.downsample(locations, budget: 100)

        XCTAssertEqual(kept.count, 100, "a route within budget must not be simplified at all")
        XCTAssertEqual(kept.map(\.timestamp), locations.map(\.timestamp))
    }

    func testOversizedRouteIsBoundedToTheBudget() throws {
        // 40k points: the shape of a long hike or ride, and far over any budget.
        let locations = straightLine(count: 40_000)

        let sample = try XCTUnwrap(makeSample(locations: WorkoutRouteReader.downsample(locations)))

        XCTAssertLessThanOrEqual(
            sample.route.points.count,
            WorkoutRouteReader.pointBudget,
            "a route must fit one bounded document"
        )
        XCTAssertGreaterThan(sample.route.points.count, 0)
    }

    /// The endpoints are what the server indexes as `start_point`/`end_point`, so
    /// downsampling must never move them.
    func testDownsamplingPreservesTheRouteEndpoints() {
        let locations = straightLine(count: 40_000)

        let kept = WorkoutRouteReader.downsample(locations)

        XCTAssertEqual(kept.first?.timestamp, locations.first?.timestamp)
        XCTAssertEqual(kept.last?.timestamp, locations.last?.timestamp)
        XCTAssertEqual(kept.first?.coordinate.latitude, locations.first?.coordinate.latitude)
        XCTAssertEqual(kept.last?.coordinate.latitude, locations.last?.coordinate.latitude)
    }

    /// Douglas–Peucker is shape-preserving: the distance the server derives by
    /// summing consecutive points stays accurate even though points were dropped.
    /// This is what keeps the route's stats honest after simplification.
    func testSimplifiedRouteKeepsItsDistance() {
        let locations = straightLine(count: 40_000)
        let fullDistance = totalDistance(locations)

        let simplifiedDistance = totalDistance(WorkoutRouteReader.downsample(locations))

        XCTAssertEqual(
            simplifiedDistance,
            fullDistance,
            accuracy: fullDistance * 0.01,
            "simplification must stay within 1% of the true route distance"
        )
    }

    /// A straight line is exactly the case DP should collapse: every interior
    /// point is within tolerance of the line its neighbours describe.
    func testDouglasPeuckerCollapsesAStraightLine() {
        let kept = WorkoutRouteReader.douglasPeucker(straightLine(count: 500), epsilonMeters: 5)

        XCTAssertEqual(kept.count, 2, "only the endpoints carry shape on a straight line")
    }

    /// …and it must NOT collapse turns, which are the whole shape of a real route.
    func testDouglasPeuckerKeepsTurnsBeyondTolerance() {
        // An L: 100 m north, then 100 m east. The corner is far off the diagonal.
        var locations = (0..<100).map { location(northOf: origin, metres: Double($0), at: TimeInterval($0)) }
        let corner = locations.last!.coordinate
        locations += (1...100).map { i -> CLLocation in
            let coordinate = CLLocationCoordinate2D(
                latitude: corner.latitude,
                longitude: corner.longitude + Double(i) / (111_320.0 * cos(corner.latitude * .pi / 180))
            )
            return CLLocation(
                coordinate: coordinate,
                altitude: 100,
                horizontalAccuracy: 5,
                verticalAccuracy: 3,
                course: 90,
                speed: 1.4,
                timestamp: epoch.addingTimeInterval(TimeInterval(100 + i))
            )
        }

        let kept = WorkoutRouteReader.douglasPeucker(locations, epsilonMeters: 5)

        // Endpoints + the corner, at minimum.
        XCTAssertGreaterThanOrEqual(kept.count, 3)
        XCTAssertTrue(
            kept.contains { abs($0.coordinate.latitude - corner.latitude) < 1e-9
                && abs($0.coordinate.longitude - corner.longitude) < 1e-9 },
            "the turn must survive simplification"
        )
    }

    func testStrideKeepsFirstAndLastAndHitsTheBudget() {
        let locations = straightLine(count: 1_000)

        let kept = WorkoutRouteReader.stride(locations, to: 10)

        XCTAssertLessThanOrEqual(kept.count, 10)
        XCTAssertEqual(kept.first?.timestamp, locations.first?.timestamp)
        XCTAssertEqual(kept.last?.timestamp, locations.last?.timestamp)
    }

    private func totalDistance(_ locations: [CLLocation]) -> Double {
        zip(locations, locations.dropFirst()).reduce(0) { $0 + $1.1.distance(from: $1.0) }
    }

    // MARK: - Registry wiring

    func testRouteTypeIsRegisteredUnderWorkouts() throws {
        let type = try XCTUnwrap(
            HealthTypeRegistry.shared.type(forIdentifier: "HKWorkoutRouteTypeIdentifier")
        )

        XCTAssertEqual(type.stream, .route)
        XCTAssertEqual(type.category, .workouts)
        XCTAssertNil(type.defaultUnit)
        XCTAssertTrue(HealthTypeRegistry.shared.types(in: .workouts).contains(type))
    }

    /// Registering the type is what earns the auth re-request on upgrade
    /// (`AppState.reconcileRegistry` fires when this set grows), the default-ON
    /// config row, and the Data Types toggle.
    func testRouteSeriesTypeIsInTheReadAuthorizationSet() {
        XCTAssertTrue(
            HealthTypeRegistry.shared.readTypes.contains(HKSeriesType.workoutRoute()),
            "route capture authorizes as the workout-route SERIES type"
        )
        XCTAssertEqual(HealthDataType.workoutRoute.authorizationTypes.count, 1)
        XCTAssertEqual(
            HealthDataType.workoutRoute.sampleType,
            HKSeriesType.workoutRoute()
        )
    }

    /// Routes are a two-step async read, so the synchronous 1:1 map must not try
    /// to produce one.
    func testAnchoredReaderDoesNotMapRouteSamples() {
        let workout = HKWorkout(activityType: .walking, start: epoch, end: epoch.addingTimeInterval(600))

        XCTAssertNil(AnchoredReader.makeSample(from: workout, type: .workoutRoute))
    }
}

/// Dedupe/idempotency of route staging, at the outbox layer the route pass
/// actually uses. This is what makes "re-scan recent workouts on every wake" free.
final class WorkoutRouteStagingTests: XCTestCase {
    private var appDB: AppDatabase!
    private var webhookId: Int64!
    private var outbox: OutboxDAO!

    private let routeTypeID = HealthDataType.workoutRoute.identifier

    override func setUpWithError() throws {
        appDB = try AppDatabase.makeInMemory()
        let webhookDAO = WebhookConfigDAO(appDB)
        var config = WebhookConfig.makeDefault(
            url: "https://example.com/hook",
            bearerTokenKeychainRef: "webhook_bearer_token"
        )
        try webhookDAO.save(&config)
        webhookId = try XCTUnwrap(config.id)
        outbox = OutboxDAO(appDB)
    }

    private func routeSample(uuid: String) -> Conduit_V1_Sample {
        var point = Conduit_V1_RoutePoint()
        point.lat = 34.0522
        point.lng = -118.2437
        point.timestampUnixMs = 1_700_000_000_000

        var route = Conduit_V1_RouteValue()
        route.workoutUuid = "BBBBBBBB-0000-0000-0000-000000000002"
        route.activityType = "walking"
        route.points = [point]

        var sample = Conduit_V1_Sample()
        sample.uuid = uuid
        sample.startUnixMs = 1_700_000_000_000
        sample.endUnixMs = 1_700_000_600_000
        sample.route = route
        return sample
    }

    /// A route re-read by a later re-scan (or by an import overlapping the live
    /// stream) must never double-stage: the outbox's UNIQUE `hk_sample_uuid` +
    /// `INSERT OR IGNORE` is what lets the re-scan run on every workout wake.
    func testRestagingTheSameRouteIsANoOp() throws {
        let sample = routeSample(uuid: "AAAAAAAA-0000-0000-0000-000000000001")

        let first = try outbox.stageImport(samples: [sample], hkTypeId: routeTypeID, webhookId: webhookId)
        let second = try outbox.stageImport(samples: [sample], hkTypeId: routeTypeID, webhookId: webhookId)

        XCTAssertEqual(first.inserted, 1)
        XCTAssertEqual(second.inserted, 0, "a re-read route is ignored, not duplicated")
        XCTAssertEqual(try outbox.totalCount(), 1)
    }

    /// Route staging must never advance a HealthKit anchor: capture is driven by
    /// the workout and made safe by dedupe, so routes have no anchor of their own.
    func testStagingARouteDoesNotTouchAnyAnchor() throws {
        let configDAO = DataTypeConfigDAO(appDB)
        try configDAO.setEnabled(true, hkTypeId: routeTypeID)
        let anchorBefore = try configDAO.find(hkTypeId: routeTypeID)?.anchorBlob

        _ = try outbox.stageImport(
            samples: [routeSample(uuid: "AAAAAAAA-0000-0000-0000-000000000003")],
            hkTypeId: routeTypeID,
            webhookId: webhookId
        )

        XCTAssertEqual(try configDAO.find(hkTypeId: routeTypeID)?.anchorBlob, anchorBefore)
        XCTAssertNil(anchorBefore)
    }
}
