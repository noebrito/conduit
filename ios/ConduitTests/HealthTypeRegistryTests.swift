import XCTest
import HealthKit
@testable import Conduit

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
            case .category, .workout, .correlation:
                XCTAssertNil(type.defaultUnit, "Non-quantity type should not carry a unit: \(type.identifier)")
            }
        }
    }

    func testEveryIdentifierResolvesToAnHKSampleType() {
        for type in registry.all {
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
}
