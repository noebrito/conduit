import XCTest
import HealthKit
@testable import Conduit

/// The two registry identifiers HealthKit only vends on iOS 18+, while this
/// project's deployment target is iOS 17.0 — the only entries in the whole
/// registry whose `sampleType` is legitimately nil on a supported OS.
///
/// Spelled here as literals, deliberately duplicating `HealthTypeRegistry`'s own
/// literals rather than reading `HealthDataType.workoutEffortScore.identifier`.
/// Those two registry entries are the only ones the compiler cannot check (the
/// SDK marks `HKQuantityTypeIdentifier.workoutEffortScore` /
/// `.estimatedWorkoutEffortScore` `@available(iOS 18.0, *)`, so the enum cases
/// cannot be referenced at a 17.0 deployment target), so an expectation derived
/// from the registry would compare the registry against itself and pass green on
/// a misspelling. Keep these as literals.
///
/// Declared once here and reused across the ConduitTests target — do not
/// redeclare it per file.
enum EffortScoreIdentifiers {
    static let workout = "HKQuantityTypeIdentifierWorkoutEffortScore"
    static let estimated = "HKQuantityTypeIdentifierEstimatedWorkoutEffortScore"
    static let all: Set<String> = [workout, estimated]

    /// Whether the RUNNING OS is new enough to know these identifiers.
    ///
    /// Keyed on the OS version, never on `HKObjectType.quantityType(forIdentifier:)
    /// != nil` — a misspelled identifier also resolves to nil, so a
    /// resolution-based gate would silently skip the very assertions that exist to
    /// catch the typo.
    static var isAvailableOnThisOS: Bool {
        if #available(iOS 18, *) {
            return true
        }
        return false
    }
}

final class HealthTypeRegistryTests: XCTestCase {
    private let registry = HealthTypeRegistry.shared

    func testHasAllV1Types() {
        // ARCHITECTURE.md §7 specifies ~30 types across four streams.
        XCTAssertGreaterThanOrEqual(registry.all.count, 30)
    }

    func testIdentifiersAreUnique() {
        let identifiers = registry.all.map(\.identifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count, "Duplicate HK identifiers in registry")
    }

    func testQuantityTypesHaveUnitsAndOthersDoNot() {
        for type in registry.all {
            switch type.stream {
            case .quantity:
                XCTAssertNotNil(type.defaultUnit, "Quantity type missing unit: \(type.identifier)")
            case .category, .workout, .correlation, .route:
                XCTAssertNil(type.defaultUnit, "Non-quantity type should not carry a unit: \(type.identifier)")
            }
        }
    }

    /// This is the only test that can catch a typo in the two effort-score
    /// identifiers, which are hand-written string literals in the registry that no
    /// compiler checks. So the skip below is deliberately narrow: it is keyed on
    /// the OS version via `EffortScoreIdentifiers.isAvailableOnThisOS`, NOT on
    /// `sampleType == nil`. A blanket nil-skip would swallow a misspelling on every
    /// runner; this way an iOS 18+ runner still proves both spellings resolve, and
    /// an iOS 17.x runner (a supported deployment target) does not fail on a
    /// genuine, expected unavailability.
    func testEveryIdentifierResolvesToAnHKSampleType() {
        for type in registry.all {
            if EffortScoreIdentifiers.all.contains(type.identifier), !EffortScoreIdentifiers.isAvailableOnThisOS {
                continue
            }
            XCTAssertNotNil(type.sampleType, "Unresolvable HK identifier: \(type.identifier)")
        }
    }

    func testLookupRoundTrips() {
        for type in registry.all {
            XCTAssertEqual(registry.type(forIdentifier: type.identifier)?.identifier, type.identifier)
        }
        XCTAssertNil(registry.type(forIdentifier: "HKQuantityTypeIdentifierNotARealType"))
    }

    func testStreamAssignments() {
        XCTAssertEqual(
            registry.type(forIdentifier: HKCorrelationTypeIdentifier.bloodPressure.rawValue)?.stream,
            .correlation
        )
        XCTAssertEqual(
            registry.type(forIdentifier: HKCategoryTypeIdentifier.sleepAnalysis.rawValue)?.stream,
            .category
        )
        XCTAssertEqual(HealthDataType.workout.stream, .workout)
        XCTAssertEqual(HealthDataType.heartRate.stream, .quantity)
    }

    func testEveryEntryBelongsToExactlyOneCategoryGroup() {
        let grouped = HealthCategory.allCases.flatMap { registry.types(in: $0) }
        XCTAssertEqual(grouped.count, registry.all.count, "Some types are missing from category grouping")
    }

    func testReadTypesIsNonEmpty() {
        XCTAssertFalse(registry.readTypes.isEmpty)
    }

    // MARK: - Authorization set (blood-pressure correlation crash regression)

    func testBloodPressureAuthorizesConstituentQuantityTypesNotCorrelation() {
        guard let bloodPressure = registry.type(forIdentifier: HKCorrelationTypeIdentifier.bloodPressure.rawValue) else {
            return XCTFail("Blood pressure missing from registry")
        }
        let authIDs = Set(bloodPressure.authorizationTypes.map { $0.identifier })

        // The two mmHg quantity types HealthKit actually authorizes.
        XCTAssertTrue(authIDs.contains(HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue))
        XCTAssertTrue(authIDs.contains(HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue))
        XCTAssertEqual(bloodPressure.authorizationTypes.count, 2)

        // The correlation type itself must NOT be in the auth set — requesting
        // read authorization for it throws an NSException that crashes onboarding.
        XCTAssertFalse(authIDs.contains(HKCorrelationTypeIdentifier.bloodPressure.rawValue))
    }

    func testBloodPressureStillQueriesAsCorrelation() {
        // Querying is unchanged: the anchored read keys off `sampleType`, which
        // stays the blood-pressure correlation type.
        let bloodPressure = registry.type(forIdentifier: HKCorrelationTypeIdentifier.bloodPressure.rawValue)
        XCTAssertEqual(bloodPressure?.sampleType?.identifier, HKCorrelationTypeIdentifier.bloodPressure.rawValue)
        XCTAssertTrue(bloodPressure?.sampleType is HKCorrelationType)
    }

    func testNonCorrelationTypesAuthorizeTheirSampleType() {
        for type in registry.all where type.stream != .correlation {
            XCTAssertEqual(
                type.authorizationTypes.map { $0.identifier },
                [type.sampleType].compactMap { $0?.identifier },
                "Non-correlation type should authorize exactly its sample type: \(type.identifier)"
            )
        }
    }

    func testReadTypesNeverContainsACorrelationType() {
        for objectType in registry.readTypes {
            XCTAssertFalse(
                objectType is HKCorrelationType,
                "readTypes must not contain a correlation type: \(objectType.identifier)"
            )
        }
    }

    // MARK: - Stand Hours (Apple Stand ring source)

    func testAppleStandHourIsRegisteredAsCategoryAndAuthorized() {
        guard let standHour = registry.type(forIdentifier: HKCategoryTypeIdentifier.appleStandHour.rawValue) else {
            return XCTFail("appleStandHour missing from registry — the Stand ring source")
        }
        // Apple's Stand ring counts stand HOURS from this category type, not
        // appleStandTime minutes; it must ride the category stream so its .stood
        // vs .idle value reaches the server.
        XCTAssertEqual(standHour.stream, .category)
        XCTAssertNil(standHour.defaultUnit)
        XCTAssertTrue(standHour.sampleType is HKCategoryType)
        // Authorized (read) via its own category sample type.
        XCTAssertEqual(
            standHour.authorizationTypes.map { $0.identifier },
            [HKCategoryTypeIdentifier.appleStandHour.rawValue]
        )
        XCTAssertTrue(registry.readTypes.contains { $0.identifier == HKCategoryTypeIdentifier.appleStandHour.rawValue })
    }

    // MARK: - Nutrition (v1.1)

    /// The ten dietary types LoseIt (and any other food logger) writes into Health.
    /// They ride the plain quantity stream — the pipeline routes by value *shape*,
    /// not by metric — so registering them here is the whole feature on the wire.
    func testNutritionTypesAreRegisteredAsQuantitiesWithCanonicalUnits() {
        let expected: [HKQuantityTypeIdentifier: String] = [
            .dietaryEnergyConsumed: "kcal",
            .dietaryProtein: "g",
            .dietaryCarbohydrates: "g",
            .dietaryFatTotal: "g",
            .dietaryFatSaturated: "g",
            .dietaryFiber: "g",
            .dietarySugar: "g",
            .dietarySodium: "mg",
            .dietaryCholesterol: "mg",
            .dietaryWater: "mL",
        ]

        for (identifier, unit) in expected {
            guard let type = registry.type(forIdentifier: identifier.rawValue) else {
                return XCTFail("Nutrition type missing from registry: \(identifier.rawValue)")
            }
            XCTAssertEqual(type.stream, .quantity, "\(identifier.rawValue) must ride the quantity stream")
            XCTAssertEqual(type.category, .nutrition, "\(identifier.rawValue) belongs in the Nutrition picker group")
            XCTAssertEqual(type.defaultUnit, unit, "\(identifier.rawValue) unit")
            XCTAssertTrue(
                registry.readTypes.contains { $0.identifier == identifier.rawValue },
                "\(identifier.rawValue) must be in the HealthKit read-authorization set"
            )
        }

        XCTAssertEqual(registry.types(in: .nutrition).count, expected.count)
    }

    // MARK: - Running Dynamics

    /// The five Apple Watch running-dynamics types added in response to real App
    /// Store feedback. Like nutrition, they ride the plain quantity stream — the
    /// pipeline routes by value shape, not by metric — so registering them here is
    /// the whole feature on the wire. HealthKit has no standalone "running cadence"
    /// type (only cycling cadence exists); Apple derives running cadence from
    /// stride length + speed, so it is deliberately not registered.
    func testRunningDynamicsTypesAreRegisteredAsQuantitiesWithCanonicalUnits() {
        let expected: [HKQuantityTypeIdentifier: String] = [
            .runningPower: "W",
            .runningSpeed: "m/s",
            .runningStrideLength: "m",
            .runningVerticalOscillation: "cm",
            .runningGroundContactTime: "ms",
        ]

        for (identifier, unit) in expected {
            guard let type = registry.type(forIdentifier: identifier.rawValue) else {
                return XCTFail("Running dynamics type missing from registry: \(identifier.rawValue)")
            }
            XCTAssertEqual(type.stream, .quantity, "\(identifier.rawValue) must ride the quantity stream")
            XCTAssertEqual(type.category, .activityFitness, "\(identifier.rawValue) belongs in the Activity & Fitness picker group")
            XCTAssertEqual(type.defaultUnit, unit, "\(identifier.rawValue) unit")
            XCTAssertTrue(
                registry.readTypes.contains { $0.identifier == identifier.rawValue },
                "\(identifier.rawValue) must be in the HealthKit read-authorization set"
            )
        }
    }

    /// HealthKit does not expose a standalone running-cadence quantity type —
    /// confirm we haven't accidentally invented an identifier for it.
    func testNoRunningCadenceTypeExists() {
        XCTAssertNil(
            registry.all.first { $0.displayName.localizedCaseInsensitiveContains("cadence") && $0.identifier.contains("Running") },
            "HealthKit has no HKQuantityTypeIdentifierRunningCadence — only CyclingCadence exists"
        )
    }

    /// `AnchoredReader.makeSample` converts every quantity with
    /// `HKUnit(from: type.defaultUnit)`, and `doubleValue(for:)` traps on a unit
    /// that is incompatible with the quantity type. So an incompatible unit is a
    /// crash at read time, not a bad number — assert every registered unit is
    /// compatible with its HK type.
    ///
    /// `sampleType` returns nil for an identifier the running OS doesn't know
    /// (e.g. the iOS-18-only effort-score types on an iOS 17.x runner) — that is
    /// a genuine, expected unavailability, not a unit bug, so it must `continue`
    /// rather than fail the whole loop (which would mask every type after it).
    /// Only a *registered quantity type with a nil unit* is a real failure.
    func testEveryQuantityUnitIsCompatibleWithItsHealthKitType() {
        for type in registry.all where type.stream == .quantity {
            guard let quantityType = type.sampleType as? HKQuantityType else {
                continue // Unavailable on this OS — not a unit-compatibility bug.
            }
            guard let unitString = type.defaultUnit else {
                XCTFail("Quantity type without a unit: \(type.identifier)")
                continue
            }
            XCTAssertTrue(
                quantityType.is(compatibleWith: HKUnit(from: unitString)),
                "\(type.identifier) is not compatible with unit '\(unitString)' — makeSample would trap"
            )
        }
    }

    func testStandHourCategoryValueNamesStoodAndIdle() {
        guard let standHour = registry.type(forIdentifier: HKCategoryTypeIdentifier.appleStandHour.rawValue) else {
            return XCTFail("appleStandHour missing from registry")
        }
        XCTAssertEqual(
            AnchoredReader.categoryValueName(type: standHour, rawValue: HKCategoryValueAppleStandHour.stood.rawValue),
            "stood"
        )
        XCTAssertEqual(
            AnchoredReader.categoryValueName(type: standHour, rawValue: HKCategoryValueAppleStandHour.idle.rawValue),
            "idle"
        )
        // The server distinguishes stood from idle by the raw value: stood == 0.
        XCTAssertEqual(HKCategoryValueAppleStandHour.stood.rawValue, 0)
    }

    // MARK: - Athlete Metrics ("Batch 1")

    /// The nine athlete-focused types added on top of running dynamics: heart-rate
    /// recovery, physical effort, four cycling metrics, swimming stroke count, and
    /// the two workout effort scores. Like nutrition and running dynamics, they
    /// ride the plain quantity stream — registering them here is the whole
    /// feature on the wire.
    ///
    /// Two of the nine (the effort scores) are iOS 18+; the app's deployment
    /// target is iOS 17.0. On an iOS 17.x test runner `sampleType`/`readTypes`
    /// membership for those two is legitimately absent, so that half of the
    /// assertion is gated on the identifier actually being available on the
    /// running OS rather than asserted unconditionally.
    ///
    /// Keyed by raw identifier `String`, not `HKQuantityTypeIdentifier` — the
    /// SDK marks `.workoutEffortScore`/`.estimatedWorkoutEffortScore`
    /// `@available(iOS 18.0, *)`, so referencing those cases directly (even as
    /// a dictionary key) fails to compile at this target's 17.0 deployment
    /// target. `HKQuantityTypeIdentifier(rawValue:)` is not itself
    /// version-gated, so building a typed value from the string when one is
    /// needed (below) compiles fine and still resolves correctly at runtime.
    ///
    /// The two effort-score keys come from `EffortScoreIdentifiers`, i.e. from
    /// independent literals rather than from `HealthDataType.*.identifier` — the
    /// registry's own spelling of those two is unchecked by the compiler, so
    /// deriving the expectation from it would compare the registry against itself
    /// and pass green on a misspelling. Here a misspelled registry literal makes
    /// `type(forIdentifier:)` return nil and fails loudly on every runner.
    func testAthleteMetricTypesAreRegisteredAsQuantitiesWithCanonicalUnits() {
        let expected: [String: String] = [
            HealthDataType.heartRateRecoveryOneMinute.identifier: "count/min",
            HealthDataType.physicalEffort.identifier: "kcal/kg*hr",
            HealthDataType.cyclingPower.identifier: "W",
            HealthDataType.cyclingCadence.identifier: "count/min",
            HealthDataType.cyclingSpeed.identifier: "m/s",
            HealthDataType.cyclingFunctionalThresholdPower.identifier: "W",
            HealthDataType.swimmingStrokeCount.identifier: "count",
            EffortScoreIdentifiers.workout: "appleEffortScore",
            EffortScoreIdentifiers.estimated: "appleEffortScore",
        ]

        for (identifier, unit) in expected {
            guard let type = registry.type(forIdentifier: identifier) else {
                XCTFail("Athlete metric type missing from registry: \(identifier)")
                continue
            }
            XCTAssertEqual(type.stream, .quantity, "\(identifier) must ride the quantity stream")
            XCTAssertEqual(type.category, .activityFitness, "\(identifier) belongs in the Activity & Fitness picker group")
            XCTAssertEqual(type.defaultUnit, unit, "\(identifier) unit")

            if HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)) != nil {
                XCTAssertTrue(
                    registry.readTypes.contains { $0.identifier == identifier },
                    "\(identifier) is available on this OS and must be in the HealthKit read-authorization set"
                )
            }
        }
    }

    /// The single most guessable-wrong value in the batch: the effort-score unit
    /// is the literal string `appleEffortScore`, not `count` or any number-shaped
    /// unit. A wrong guess compiles fine and traps at read time
    /// (`doubleValue(for:)`), not a bad value — pin it explicitly.
    ///
    /// Uses the independent `EffortScoreIdentifiers` literals for the same
    /// not-self-referential reason as the table above.
    func testEffortScoreUsesTheAppleEffortScoreUnit() {
        for identifier in [EffortScoreIdentifiers.workout, EffortScoreIdentifiers.estimated] {
            guard let type = registry.type(forIdentifier: identifier) else {
                XCTFail("\(identifier) missing from registry")
                continue
            }
            XCTAssertEqual(type.defaultUnit, "appleEffortScore", "\(identifier) unit")
        }
    }
}
