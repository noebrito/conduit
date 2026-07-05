import XCTest
import HealthKit
@testable import Conduit

/// Runtime regression coverage for the blood-pressure authorization crash.
///
/// Passing a `HKCorrelationType` (blood pressure) into
/// `HKHealthStore.requestAuthorization(toShare:read:)` makes HealthKit raise an
/// uncaught `NSException` — "Authorization to read the following types is
/// disallowed: HKCorrelationTypeIdentifierBloodPressure" — which aborts the
/// process and crashes the onboarding permission flow. These tests exercise the
/// real `HKHealthStore` on the simulator to prove the request now validates
/// cleanly (blood pressure is authorized via its constituent quantity types).
final class HealthKitAuthorizerTests: XCTestCase {
    /// Requesting authorization for the full registry (which includes blood
    /// pressure) must not abort the process. With the pre-fix correlation-type
    /// read set this call raised synchronously and killed the test host; with
    /// the fix it validates and presents the system sheet.
    ///
    /// The hold duration is 1s by default (long enough to prove there was no
    /// synchronous crash) and overridable via `CONDUIT_HK_SHEET_HOLD_SECONDS`
    /// so the presented sheet can be captured during manual verification.
    func testRequestAllDoesNotRaiseDisallowedTypesException() async throws {
        let authorizer = HealthKitAuthorizer()
        try XCTSkipUnless(authorizer.isHealthDataAvailable, "HealthKit unavailable on this device")

        // Runs the exact crashing path. If the disallowed-types NSException were
        // still raised it would abort here before any suspension point.
        let task = Task { try? await authorizer.requestAll() }

        let hold = ProcessInfo.processInfo.environment["CONDUIT_HK_SHEET_HOLD_SECONDS"]
            .flatMap(Double.init) ?? 1.0
        try await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        task.cancel()

        // Reaching this line means requestAuthorization did not raise — the fix
        // holds. (iOS never reveals the user's decision, so there is nothing
        // further to assert about the outcome.)
    }

    /// The read set the authorizer actually sends must never contain a
    /// correlation type — that is the specific input HealthKit rejects.
    func testAuthorizationReadSetContainsNoCorrelationType() {
        let readTypes = Set(HealthTypeRegistry.shared.all.flatMap { $0.authorizationTypes })
        XCTAssertFalse(readTypes.isEmpty)
        for objectType in readTypes {
            XCTAssertFalse(
                objectType is HKCorrelationType,
                "Authorization read set must not contain a correlation type: \(objectType.identifier)"
            )
        }
        // And blood pressure's two quantity components must be present.
        let ids = Set(readTypes.map { $0.identifier })
        XCTAssertTrue(ids.contains(HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue))
        XCTAssertTrue(ids.contains(HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue))
    }
}
