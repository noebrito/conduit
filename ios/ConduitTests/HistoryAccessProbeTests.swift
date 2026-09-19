import XCTest
import HealthKit
@testable import Conduit

/// The pure `floors(for:from:)` mapping — no live `HKHealthStore`, no device,
/// no iOS 27 needed. This is what makes the iOS 27 "limited history" detection
/// unit-testable at all: everything HealthKit-touching lives behind the
/// `HistoryAccessProbing` seam these tests never call.
final class HistoryAccessProbeTests: XCTestCase {
    private func date(_ daysAgo: Double) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400)
    }

    func testSingleQuantityTypeWithNoRestrictionHasNoFloor() {
        let floors = HealthKitHistoryAccessProbe.floors(for: [.stepCount], from: [:])
        XCTAssertNil(floors[HealthDataType.stepCount.identifier])
    }

    func testSingleQuantityTypeWithARestrictionReportsItVerbatim() throws {
        let floor = date(30)
        let stepType = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .stepCount))
        let floors = HealthKitHistoryAccessProbe.floors(for: [.stepCount], from: [stepType: floor])
        XCTAssertEqual(floors[HealthDataType.stepCount.identifier], floor)
    }

    func testTypeAbsentFromEnabledListIsNeverReported() throws {
        let floor = date(30)
        let stepType = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .stepCount))
        // Only heartRate was ASKED about; stepCount's raw floor must not leak in.
        let floors = HealthKitHistoryAccessProbe.floors(for: [.heartRate], from: [stepType: floor])
        XCTAssertNil(floors[HealthDataType.stepCount.identifier])
        XCTAssertNil(floors[HealthDataType.heartRate.identifier])
    }

    /// Blood pressure = systolic + diastolic. Readable in full only where
    /// BOTH constituents are, so an asymmetric grant must report the LATEST
    /// (most restrictive) of the two — the true point below which the
    /// composite sample stops being fully readable.
    func testCompositeTypeTakesTheLatestOfItsConstituentFloors() throws {
        let systolic = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic))
        let diastolic = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic))
        let olderFloor = date(90)
        let newerFloor = date(30)

        let floors = HealthKitHistoryAccessProbe.floors(
            for: [.bloodPressure],
            from: [systolic: olderFloor, diastolic: newerFloor]
        )
        XCTAssertEqual(
            floors[HealthDataType.bloodPressure.identifier],
            newerFloor,
            "The composite's floor must be the MOST restrictive constituent, not the least"
        )
    }

    /// A composite with only ONE constituent restricted still has a floor —
    /// the correlation as a whole is only as permissive as its worst part.
    func testCompositeTypeWithOnlyOneRestrictedConstituentStillHasAFloor() throws {
        let systolic = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic))
        let floor = date(30)

        let floors = HealthKitHistoryAccessProbe.floors(for: [.bloodPressure], from: [systolic: floor])
        XCTAssertEqual(floors[HealthDataType.bloodPressure.identifier], floor)
    }

    func testCompositeTypeWithNeitherConstituentRestrictedHasNoFloor() {
        let floors = HealthKitHistoryAccessProbe.floors(for: [.bloodPressure], from: [:])
        XCTAssertNil(floors[HealthDataType.bloodPressure.identifier])
    }

    /// A mixed grant — one type limited, one not — must report ONLY the
    /// limited type. This is the case the whole design exists to get right:
    /// a single app-wide flag would be wrong here.
    func testMixedGrantReportsOnlyTheRestrictedType() throws {
        let stepType = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .stepCount))
        let floor = date(30)
        let floors = HealthKitHistoryAccessProbe.floors(
            for: [.stepCount, .heartRate],
            from: [stepType: floor]
        )
        XCTAssertEqual(floors[HealthDataType.stepCount.identifier], floor)
        XCTAssertNil(floors[HealthDataType.heartRate.identifier])
    }

    // MARK: - Resolved vs unresolved

    /// The distinction the import's completion decision rests on: "no floor" is
    /// an answer, "we couldn't ask" is not, and it is scoped to the individual
    /// type — an unanswerable type must not make its neighbours unknown too.
    func testUnresolvedIsScopedPerTypeAndIsNotConfirmedFullAccess() {
        let unanswerable = HealthDataType.bloodPressure
        let confirmed = HealthDataType.stepCount
        let result = HistoryAccessFloors(unresolvedTypeIDs: [unanswerable.identifier])

        XCTAssertFalse(result.isResolved(unanswerable))
        XCTAssertTrue(result.isResolved(confirmed),
                      "One unanswerable type must not turn every other type unknown")
        XCTAssertTrue(result.floors.isEmpty, "Unknown is not a floor")
        XCTAssertNotEqual(result, HistoryAccessFloors(),
                          "An unanswered type must never compare equal to confirmed full access")
        XCTAssertTrue(HistoryAccessFloors().isResolved(confirmed))
    }

    // MARK: - Live probe: below iOS 27 it must RESOLVE to no floors (the
    // regression that must never happen — a full-access or pre-27 user must see
    // IDENTICAL behavior to before this feature existed, which means a real
    // "full access" answer, not an unresolved one that blocks completion).

    func testLiveProbeResolvesToNoFloorsBelowIOS27() async throws {
        guard #unavailable(iOS 27.0) else {
            throw XCTSkip("This device is iOS 27+; this test only proves the pre-27 fallback path.")
        }
        let probe = HealthKitHistoryAccessProbe()
        let result = await probe.limitedHistoryFloors(for: [.stepCount, .heartRate])
        XCTAssertEqual(result, HistoryAccessFloors())
    }

    func testLiveProbeResolvesToNoFloorsForNoTypes() async {
        let probe = HealthKitHistoryAccessProbe()
        let result = await probe.limitedHistoryFloors(for: [])
        XCTAssertEqual(result, HistoryAccessFloors())
    }
}
