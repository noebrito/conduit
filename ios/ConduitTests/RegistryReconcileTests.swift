import XCTest
import GRDB
@testable import Conduit

/// Coverage for the launch-time registry reconcile that lets an existing
/// (already-onboarded) user pick up data types added in an app update — e.g.
/// `appleStandHour` from #502 — without re-running onboarding.
///
/// Two independent gates, both required and both exercised here:
/// 1. Auto-enable registry types that have no `data_type_config` row yet.
/// 2. Re-request HealthKit authorization only when the authorized-type
///    signature has grown (so an existing user gets exactly one prompt).
final class RegistryReconcileTests: XCTestCase {
    private var appDB: AppDatabase!

    override func setUpWithError() throws {
        appDB = try AppDatabase.makeInMemory()
    }

    // MARK: - (1) Auto-enable newly-registered types

    /// An existing user missing only the new `appleStandHour` type (simulating a
    /// pre-#502 config) gets a default-on row written for it; everything else is
    /// left exactly as it was.
    func testAutoEnableWritesRowForNewlyRegisteredType() throws {
        let dao = DataTypeConfigDAO(appDB)
        let newType = HealthDataType.appleStandHour.identifier

        // Seed the DB as a pre-#502 user: a row for every registry type EXCEPT
        // the newly-added one.
        for type in HealthTypeRegistry.shared.all where type.identifier != newType {
            try dao.setEnabled(true, hkTypeId: type.identifier)
        }
        XCTAssertNil(try dao.find(hkTypeId: newType), "precondition: new type has no row yet")

        try AppState.enableNewlyRegisteredTypes(dao: dao)

        let row = try XCTUnwrap(try dao.find(hkTypeId: newType), "reconcile must insert a row for the new type")
        XCTAssertTrue(row.enabled, "newly-registered types are enabled by default (registry convention)")
    }

    /// Existing rows — including a type the user deliberately DISABLED — are never
    /// touched by the reconcile. It only fills gaps, it doesn't re-enable opt-outs.
    func testAutoEnableLeavesExistingRowsUntouched() throws {
        let dao = DataTypeConfigDAO(appDB)
        let optedOut = HealthDataType.stepCount.identifier

        // Full config, but the user turned one type off.
        for type in HealthTypeRegistry.shared.all {
            try dao.setEnabled(type.identifier != optedOut, hkTypeId: type.identifier)
        }

        try AppState.enableNewlyRegisteredTypes(dao: dao)

        XCTAssertEqual(try dao.find(hkTypeId: optedOut)?.enabled, false,
                       "a user's deliberate opt-out must be preserved, not re-enabled")
    }

    /// Running the auto-enable twice is idempotent — no duplicate rows, no flips.
    func testAutoEnableIsIdempotent() throws {
        let dao = DataTypeConfigDAO(appDB)
        try AppState.enableNewlyRegisteredTypes(dao: dao)
        let afterFirst = try dao.all().count
        try AppState.enableNewlyRegisteredTypes(dao: dao)
        let afterSecond = try dao.all().count

        XCTAssertEqual(afterFirst, HealthTypeRegistry.shared.all.count,
                       "every registry type should have exactly one row")
        XCTAssertEqual(afterFirst, afterSecond, "second run must not add or duplicate rows")
    }

    // MARK: - (2) Gated authorization re-request

    /// The authorized-type signature is a stable, sorted, deterministic string —
    /// the thing whose growth triggers a re-request.
    func testAuthorizedTypesSignatureIsStableAndSorted() {
        let a = AppState.authorizedTypesSignature()
        let b = AppState.authorizedTypesSignature()
        XCTAssertEqual(a, b, "signature must be deterministic across calls")
        let parts = a.split(separator: ",").map(String.init)
        XCTAssertEqual(parts, parts.sorted(), "signature identifiers must be sorted")
        XCTAssertFalse(parts.isEmpty)
    }

    /// When the stored signature already matches the current registry, an
    /// existing user is NOT re-prompted (no authorization request fires).
    @MainActor
    func testAuthorizationNotRequestedWhenSignatureUnchanged() async throws {
        let appState = AppState(database: appDB)
        let defaults = try makeCleanDefaults()
        defaults.set(AppState.authorizedTypesSignature(), forKey: AppState.authorizedSignatureKey)

        var authorizeCalls = 0
        await appState.reconcileRegistry(
            registry: .shared,
            defaults: defaults,
            authorize: { _ in authorizeCalls += 1 }
        )

        XCTAssertEqual(authorizeCalls, 0, "unchanged signature must not re-request authorization")
    }

    /// An existing user whose stored signature is absent (first launch after the
    /// update) gets exactly ONE authorization request — with the enabled types —
    /// and the signature is persisted so a second launch does not re-prompt.
    @MainActor
    func testAuthorizationRequestedOnceWhenSignatureGrows() async throws {
        let appState = AppState(database: appDB)
        let defaults = try makeCleanDefaults()

        var authorizeCalls = 0
        var lastRequested: [HealthDataType] = []
        let authorize: (_ types: [HealthDataType]) async throws -> Void = { types in
            authorizeCalls += 1
            lastRequested = types
        }

        // First launch: signature absent → request fires once.
        await appState.reconcileRegistry(registry: .shared, defaults: defaults, authorize: authorize)
        XCTAssertEqual(authorizeCalls, 1, "a grown/absent signature must request authorization once")
        XCTAssertTrue(lastRequested.contains { $0.identifier == HealthDataType.appleStandHour.identifier },
                      "the request must include the newly auto-enabled type")
        XCTAssertEqual(defaults.string(forKey: AppState.authorizedSignatureKey),
                       AppState.authorizedTypesSignature(),
                       "signature must be persisted after a successful request")

        // Second launch: signature now matches → no re-prompt.
        await appState.reconcileRegistry(registry: .shared, defaults: defaults, authorize: authorize)
        XCTAssertEqual(authorizeCalls, 1, "a matching signature must not re-request on the next launch")
    }

    /// If the authorization request throws, the signature is NOT persisted, so
    /// the next launch retries the prompt (no silent permanent skip).
    @MainActor
    func testSignatureNotPersistedWhenAuthorizationFails() async throws {
        struct Boom: Error {}
        let appState = AppState(database: appDB)
        let defaults = try makeCleanDefaults()

        var authorizeCalls = 0
        await appState.reconcileRegistry(
            registry: .shared,
            defaults: defaults,
            authorize: { _ in authorizeCalls += 1; throw Boom() }
        )
        XCTAssertEqual(authorizeCalls, 1)
        XCTAssertNil(defaults.string(forKey: AppState.authorizedSignatureKey),
                     "a failed request must not persist the signature")

        // Next launch retries because the signature is still absent.
        await appState.reconcileRegistry(
            registry: .shared,
            defaults: defaults,
            authorize: { _ in authorizeCalls += 1 }
        )
        XCTAssertEqual(authorizeCalls, 2, "the prompt must be retried after a prior failure")
    }

    // MARK: - Helpers

    /// A private, empty `UserDefaults` suite so tests never read or mutate the
    /// host app's real defaults.
    private func makeCleanDefaults() throws -> UserDefaults {
        let suite = "conduit.reconcile.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
