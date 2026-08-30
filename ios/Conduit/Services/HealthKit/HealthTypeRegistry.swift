import Foundation
import HealthKit

/// The OpenSearch data stream a type's samples are routed to (ARCHITECTURE.md §3).
/// Streams are grouped by value *shape*, not by HK type, so new HK types add no
/// schema work.
enum HealthStream: String, Codable, CaseIterable, Sendable {
    case quantity
    case category
    case workout
    case correlation
    /// A workout's GPS route: a `workout_uuid` FK plus an ordered point array.
    /// The only stream NOT produced by `AnchoredReader.makeSample`'s synchronous
    /// 1:1 map — a route is a two-step async read, so it has its own reader
    /// (`WorkoutRouteReader`) driven off the workout wake.
    case route
}

/// UI grouping for the Data Types picker (ARCHITECTURE.md §7).
enum HealthCategory: String, Codable, CaseIterable, Sendable {
    case activityFitness = "Activity & Fitness"
    case bodyMeasurements = "Body Measurements"
    case vitals = "Vitals"
    case sleepMindfulness = "Sleep & Mindfulness"
    case heartEvents = "Heart Events"
    case workouts = "Workouts"
    case nutrition = "Nutrition"
}

/// A single supported HealthKit data type and everything Conduit needs to know
/// about it: its HK identifier, how to present it, how to read it, and which
/// stream its samples belong to.
struct HealthDataType: Identifiable, Hashable, Sendable {
    /// HealthKit identifier string, e.g. `HKQuantityTypeIdentifierHeartRate`.
    /// This is the value carried as `SampleBatch.hk_type_id` on the wire.
    let identifier: String
    /// Human-readable name for the UI.
    let displayName: String
    /// UI grouping.
    let category: HealthCategory
    /// Canonical HK unit string for quantity types (e.g. `count/min`, `kg`).
    /// `nil` for non-quantity streams.
    let defaultUnit: String?
    /// Value shape / destination stream.
    let stream: HealthStream

    var id: String { identifier }

    /// The concrete `HKSampleType` for this entry, or `nil` if the identifier is
    /// not available on the running OS. Used for **querying** (the anchored read
    /// in `AnchoredReader`). For blood pressure this is the correlation type,
    /// which is correct to query but must NOT be used for authorization — see
    /// `authorizationTypes`.
    var sampleType: HKSampleType? {
        switch stream {
        case .quantity:
            return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier))
        case .category:
            return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier))
        case .correlation:
            return HKObjectType.correlationType(forIdentifier: HKCorrelationTypeIdentifier(rawValue: identifier))
        case .workout:
            return HKObjectType.workoutType()
        case .route:
            return HKSeriesType.workoutRoute()
        }
    }

    /// The `HKObjectType`s to request **read authorization** for.
    ///
    /// For most types this is just `sampleType`. Correlation types are the
    /// exception: HealthKit does not permit requesting authorization for a
    /// correlation type directly (e.g. blood pressure) — doing so throws an
    /// NSException that crashes the whole permission flow. A correlation is
    /// authorized via its *constituent quantity types* instead, so blood
    /// pressure contributes `bloodPressureSystolic` + `bloodPressureDiastolic`.
    /// Entries whose identifier isn't available on the current OS contribute
    /// nothing. Querying still uses `sampleType` (the correlation type).
    var authorizationTypes: [HKObjectType] {
        switch stream {
        case .correlation:
            return Self.correlationComponentTypes(forIdentifier: identifier)
        case .quantity, .category, .workout, .route:
            // A route authorizes as its series type (`HKSeriesType.workoutRoute()`)
            // and NOTHING else. Reading a *stored* route needs no CoreLocation
            // permission, no `NSLocation*UsageDescription`, and no new
            // entitlement — the existing HealthKit entitlement covers it. Never
            // add the route type to a `toShare` set: Conduit never writes HealthKit.
            return sampleType.map { [$0 as HKObjectType] } ?? []
        }
    }

    /// The constituent quantity types that back a correlation type, which are
    /// what HealthKit actually authorizes. v1 supports only blood pressure
    /// (systolic + diastolic).
    private static func correlationComponentTypes(forIdentifier identifier: String) -> [HKObjectType] {
        switch identifier {
        case HKCorrelationTypeIdentifier.bloodPressure.rawValue:
            return [
                HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic),
                HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic),
            ].compactMap { $0 as HKObjectType? }
        default:
            return []
        }
    }
}

/// Static registry of the supported data types. `docs/ARCHITECTURE.md` §7 is the
/// authoritative list and count — the v1 types plus every group added since.
///
/// Adding a type post-v1 is a single entry here (+ optionally an ingester
/// correlation flattener) — no schema change.
struct HealthTypeRegistry: Sendable {
    static let shared = HealthTypeRegistry()

    /// Every supported type.
    let all: [HealthDataType]

    init() {
        self.all =
            HealthDataType.activityFitness +
            HealthDataType.bodyMeasurements +
            HealthDataType.vitals +
            HealthDataType.sleepMindfulness +
            HealthDataType.heartEvents +
            HealthDataType.workouts +
            HealthDataType.nutrition
    }

    /// Look up a type by its HK identifier string.
    func type(forIdentifier identifier: String) -> HealthDataType? {
        all.first { $0.identifier == identifier }
    }

    /// Types in a given UI category.
    func types(in category: HealthCategory) -> [HealthDataType] {
        all.filter { $0.category == category }
    }

    /// The set of `HKObjectType`s to request read authorization for. Blood
    /// pressure contributes its constituent quantity types rather than the
    /// correlation type (see `HealthDataType.authorizationTypes`). Entries whose
    /// identifier isn't available on the current OS are skipped.
    var readTypes: Set<HKObjectType> {
        Set(all.flatMap { $0.authorizationTypes })
    }
}

// MARK: - The v1 type table

extension HealthDataType {
    // Activity & Fitness → conduit-quantity
    static let heartRate = HealthDataType(identifier: HKQuantityTypeIdentifier.heartRate.rawValue, displayName: "Heart Rate", category: .activityFitness, defaultUnit: "count/min", stream: .quantity)
    static let restingHeartRate = HealthDataType(identifier: HKQuantityTypeIdentifier.restingHeartRate.rawValue, displayName: "Resting Heart Rate", category: .activityFitness, defaultUnit: "count/min", stream: .quantity)
    static let heartRateVariabilitySDNN = HealthDataType(identifier: HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue, displayName: "Heart Rate Variability (SDNN)", category: .activityFitness, defaultUnit: "ms", stream: .quantity)
    static let walkingHeartRateAverage = HealthDataType(identifier: HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue, displayName: "Walking Heart Rate Average", category: .activityFitness, defaultUnit: "count/min", stream: .quantity)
    static let stepCount = HealthDataType(identifier: HKQuantityTypeIdentifier.stepCount.rawValue, displayName: "Steps", category: .activityFitness, defaultUnit: "count", stream: .quantity)
    static let distanceWalkingRunning = HealthDataType(identifier: HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue, displayName: "Walking + Running Distance", category: .activityFitness, defaultUnit: "m", stream: .quantity)
    static let distanceCycling = HealthDataType(identifier: HKQuantityTypeIdentifier.distanceCycling.rawValue, displayName: "Cycling Distance", category: .activityFitness, defaultUnit: "m", stream: .quantity)
    static let distanceSwimming = HealthDataType(identifier: HKQuantityTypeIdentifier.distanceSwimming.rawValue, displayName: "Swimming Distance", category: .activityFitness, defaultUnit: "m", stream: .quantity)
    static let flightsClimbed = HealthDataType(identifier: HKQuantityTypeIdentifier.flightsClimbed.rawValue, displayName: "Flights Climbed", category: .activityFitness, defaultUnit: "count", stream: .quantity)
    static let activeEnergyBurned = HealthDataType(identifier: HKQuantityTypeIdentifier.activeEnergyBurned.rawValue, displayName: "Active Energy Burned", category: .activityFitness, defaultUnit: "kcal", stream: .quantity)
    static let basalEnergyBurned = HealthDataType(identifier: HKQuantityTypeIdentifier.basalEnergyBurned.rawValue, displayName: "Basal Energy Burned", category: .activityFitness, defaultUnit: "kcal", stream: .quantity)
    static let appleExerciseTime = HealthDataType(identifier: HKQuantityTypeIdentifier.appleExerciseTime.rawValue, displayName: "Exercise Time", category: .activityFitness, defaultUnit: "min", stream: .quantity)
    static let appleStandTime = HealthDataType(identifier: HKQuantityTypeIdentifier.appleStandTime.rawValue, displayName: "Stand Time", category: .activityFitness, defaultUnit: "min", stream: .quantity)
    // Apple's "Stand" activity ring counts STAND HOURS — the distinct hours in
    // which the user stood and moved ≥1 min — sourced from this CATEGORY type
    // (value .stood == 0 / .idle == 1), NOT from appleStandTime minutes. The
    // server counts today's `.stood` samples (goal 12). See AGENTS.md.
    static let appleStandHour = HealthDataType(identifier: HKCategoryTypeIdentifier.appleStandHour.rawValue, displayName: "Stand Hours", category: .activityFitness, defaultUnit: nil, stream: .category)
    static let vo2Max = HealthDataType(identifier: HKQuantityTypeIdentifier.vo2Max.rawValue, displayName: "VO₂ Max", category: .activityFitness, defaultUnit: "ml/kg*min", stream: .quantity)

    // Running Dynamics → conduit-quantity. Plain quantities, same as everything
    // else in this category — the pipeline routes by value shape, not by metric.
    // Recorded by Apple Watch SE (2nd generation), Series 6 or later, or Ultra
    // (watchOS 9+) during OUTDOOR running workouts only; other users/workouts
    // see an empty series, same as dietaryWater — expected, not a bug.
    // HealthKit has no standalone "running cadence" type — Apple derives it
    // from stride length + speed, so it isn't (and can't be) registered here.
    static let runningPower = HealthDataType(identifier: HKQuantityTypeIdentifier.runningPower.rawValue, displayName: "Running Power", category: .activityFitness, defaultUnit: "W", stream: .quantity)
    static let runningSpeed = HealthDataType(identifier: HKQuantityTypeIdentifier.runningSpeed.rawValue, displayName: "Running Speed", category: .activityFitness, defaultUnit: "m/s", stream: .quantity)
    static let runningStrideLength = HealthDataType(identifier: HKQuantityTypeIdentifier.runningStrideLength.rawValue, displayName: "Running Stride Length", category: .activityFitness, defaultUnit: "m", stream: .quantity)
    static let runningVerticalOscillation = HealthDataType(identifier: HKQuantityTypeIdentifier.runningVerticalOscillation.rawValue, displayName: "Running Vertical Oscillation", category: .activityFitness, defaultUnit: "cm", stream: .quantity)
    static let runningGroundContactTime = HealthDataType(identifier: HKQuantityTypeIdentifier.runningGroundContactTime.rawValue, displayName: "Running Ground Contact Time", category: .activityFitness, defaultUnit: "ms", stream: .quantity)

    static let activityFitness: [HealthDataType] = [
        .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .walkingHeartRateAverage,
        .stepCount, .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
        .flightsClimbed, .activeEnergyBurned, .basalEnergyBurned,
        .appleExerciseTime, .appleStandTime, .appleStandHour, .vo2Max,
        .runningPower, .runningSpeed, .runningStrideLength,
        .runningVerticalOscillation, .runningGroundContactTime,
    ]

    // Body Measurements → conduit-quantity
    static let bodyMass = HealthDataType(identifier: HKQuantityTypeIdentifier.bodyMass.rawValue, displayName: "Body Mass (Weight)", category: .bodyMeasurements, defaultUnit: "kg", stream: .quantity)
    static let bodyFatPercentage = HealthDataType(identifier: HKQuantityTypeIdentifier.bodyFatPercentage.rawValue, displayName: "Body Fat Percentage", category: .bodyMeasurements, defaultUnit: "%", stream: .quantity)
    static let leanBodyMass = HealthDataType(identifier: HKQuantityTypeIdentifier.leanBodyMass.rawValue, displayName: "Lean Body Mass", category: .bodyMeasurements, defaultUnit: "kg", stream: .quantity)
    static let bodyMassIndex = HealthDataType(identifier: HKQuantityTypeIdentifier.bodyMassIndex.rawValue, displayName: "Body Mass Index", category: .bodyMeasurements, defaultUnit: "count", stream: .quantity)
    static let height = HealthDataType(identifier: HKQuantityTypeIdentifier.height.rawValue, displayName: "Height", category: .bodyMeasurements, defaultUnit: "m", stream: .quantity)
    static let waistCircumference = HealthDataType(identifier: HKQuantityTypeIdentifier.waistCircumference.rawValue, displayName: "Waist Circumference", category: .bodyMeasurements, defaultUnit: "m", stream: .quantity)

    static let bodyMeasurements: [HealthDataType] = [
        .bodyMass, .bodyFatPercentage, .leanBodyMass, .bodyMassIndex, .height, .waistCircumference,
    ]

    // Vitals → conduit-quantity (+ blood pressure → conduit-correlation)
    static let respiratoryRate = HealthDataType(identifier: HKQuantityTypeIdentifier.respiratoryRate.rawValue, displayName: "Respiratory Rate", category: .vitals, defaultUnit: "count/min", stream: .quantity)
    static let oxygenSaturation = HealthDataType(identifier: HKQuantityTypeIdentifier.oxygenSaturation.rawValue, displayName: "Blood Oxygen (SpO₂)", category: .vitals, defaultUnit: "%", stream: .quantity)
    static let bodyTemperature = HealthDataType(identifier: HKQuantityTypeIdentifier.bodyTemperature.rawValue, displayName: "Body Temperature", category: .vitals, defaultUnit: "degC", stream: .quantity)
    static let bloodGlucose = HealthDataType(identifier: HKQuantityTypeIdentifier.bloodGlucose.rawValue, displayName: "Blood Glucose", category: .vitals, defaultUnit: "mg/dL", stream: .quantity)
    static let bloodPressure = HealthDataType(identifier: HKCorrelationTypeIdentifier.bloodPressure.rawValue, displayName: "Blood Pressure", category: .vitals, defaultUnit: nil, stream: .correlation)

    static let vitals: [HealthDataType] = [
        .respiratoryRate, .oxygenSaturation, .bodyTemperature, .bloodGlucose, .bloodPressure,
    ]

    // Sleep & Mindfulness → conduit-category
    static let sleepAnalysis = HealthDataType(identifier: HKCategoryTypeIdentifier.sleepAnalysis.rawValue, displayName: "Sleep Analysis", category: .sleepMindfulness, defaultUnit: nil, stream: .category)
    static let mindfulSession = HealthDataType(identifier: HKCategoryTypeIdentifier.mindfulSession.rawValue, displayName: "Mindful Session", category: .sleepMindfulness, defaultUnit: nil, stream: .category)

    static let sleepMindfulness: [HealthDataType] = [.sleepAnalysis, .mindfulSession]

    // Heart Events → conduit-category
    static let highHeartRateEvent = HealthDataType(identifier: HKCategoryTypeIdentifier.highHeartRateEvent.rawValue, displayName: "High Heart Rate Event", category: .heartEvents, defaultUnit: nil, stream: .category)
    static let lowHeartRateEvent = HealthDataType(identifier: HKCategoryTypeIdentifier.lowHeartRateEvent.rawValue, displayName: "Low Heart Rate Event", category: .heartEvents, defaultUnit: nil, stream: .category)
    static let irregularHeartRhythmEvent = HealthDataType(identifier: HKCategoryTypeIdentifier.irregularHeartRhythmEvent.rawValue, displayName: "Irregular Heart Rhythm Event", category: .heartEvents, defaultUnit: nil, stream: .category)

    static let heartEvents: [HealthDataType] = [.highHeartRateEvent, .lowHeartRateEvent, .irregularHeartRhythmEvent]

    // Workouts → conduit-workout
    static let workout = HealthDataType(identifier: "HKWorkoutTypeIdentifier", displayName: "Workouts", category: .workouts, defaultUnit: nil, stream: .workout)

    // Workouts → conduit-route (GPS). Captured by `WorkoutRouteReader` via
    // `HKWorkoutRouteQuery`, NOT the generic anchored read — the route is found
    // *from* its workout, so capture is workout-driven. Registering it here is
    // what earns the auth re-request, the default-ON config row, and the
    // Data Types toggle (routes are the most sensitive data Conduit captures, so
    // a workouts-without-routes opt-out matters).
    static let workoutRoute = HealthDataType(identifier: "HKWorkoutRouteTypeIdentifier", displayName: "Workout Routes (GPS)", category: .workouts, defaultUnit: nil, stream: .route)

    static let workouts: [HealthDataType] = [.workout, .workoutRoute]

    // Nutrition → conduit-quantity. Dietary samples are plain quantities, so they
    // ride the existing quantity stream with no proto/ingester/mapping change: the
    // pipeline routes by value *shape*, not by metric. Written to Health by the
    // user's food-logging app (e.g. LoseIt).
    static let dietaryEnergyConsumed = HealthDataType(identifier: HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue, displayName: "Dietary Energy", category: .nutrition, defaultUnit: "kcal", stream: .quantity)
    static let dietaryProtein = HealthDataType(identifier: HKQuantityTypeIdentifier.dietaryProtein.rawValue, displayName: "Protein", category: .nutrition, defaultUnit: "g", stream: .quantity)
    static let dietaryCarbohydrates = HealthDataType(identifier: HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue, displayName: "Carbohydrates", category: .nutrition, defaultUnit: "g", stream: .quantity)
    static let dietaryFatTotal = HealthDataType(identifier: HKQuantityTypeIdentifier.dietaryFatTotal.rawValue, displayName: "Total Fat", category: .nutrition, defaultUnit: "g", stream: .quantity)
    static let dietaryFatSaturated = HealthDataType(identifier: HKQuantityTypeIdentifier.dietaryFatSaturated.rawValue, displayName: "Saturated Fat", category: .nutrition, defaultUnit: "g", stream: .quantity)
    static let dietaryFiber = HealthDataType(identifier: HKQuantityTypeIdentifier.dietaryFiber.rawValue, displayName: "Fiber", category: .nutrition, defaultUnit: "g", stream: .quantity)
    static let dietarySugar = HealthDataType(identifier: HKQuantityTypeIdentifier.dietarySugar.rawValue, displayName: "Sugar", category: .nutrition, defaultUnit: "g", stream: .quantity)
    static let dietarySodium = HealthDataType(identifier: HKQuantityTypeIdentifier.dietarySodium.rawValue, displayName: "Sodium", category: .nutrition, defaultUnit: "mg", stream: .quantity)
    static let dietaryCholesterol = HealthDataType(identifier: HKQuantityTypeIdentifier.dietaryCholesterol.rawValue, displayName: "Cholesterol", category: .nutrition, defaultUnit: "mg", stream: .quantity)
    // Water is registered even though the common food loggers (LoseIt) don't write
    // it — it costs one entry and another source may fill it later. An empty water
    // series is expected, not a bug.
    static let dietaryWater = HealthDataType(identifier: HKQuantityTypeIdentifier.dietaryWater.rawValue, displayName: "Water", category: .nutrition, defaultUnit: "mL", stream: .quantity)

    static let nutrition: [HealthDataType] = [
        .dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates,
        .dietaryFatTotal, .dietaryFatSaturated, .dietaryFiber, .dietarySugar,
        .dietarySodium, .dietaryCholesterol, .dietaryWater,
    ]
}
