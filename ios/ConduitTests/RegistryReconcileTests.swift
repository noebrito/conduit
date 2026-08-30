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

    // MARK: - Nutrition upgrade path (v1.0 → v1.1)

    /// The end-to-end v1.1 upgrade: a user who onboarded on v1.0 (rows + stored
    /// signature for every type EXCEPT the ten dietary ones) launches the new
    /// build. Both gates must fire off the same reconcile — nutrition lands
    /// enabled by default, and the grown read set re-prompts exactly once with the
    /// nutrition types in the sheet.
    @MainActor
    func testNutritionIsAutoEnabledAndRePromptedOnceOnUpgrade() async throws {
        let appState = AppState(database: appDB)
        let dao = DataTypeConfigDAO(appDB)
        let defaults = try makeCleanDefaults()
        let nutritionIDs = HealthTypeRegistry.shared.types(in: .nutrition).map(\.identifier)
        XCTAssertEqual(nutritionIDs.count, 10, "precondition: the ten dietary types")

        // Seed a v1.0 install: every pre-nutrition type configured, and the stored
        // signature is the pre-nutrition read set.
        for type in HealthTypeRegistry.shared.all where type.category != .nutrition {
            try dao.setEnabled(true, hkTypeId: type.identifier)
        }
        let v1Signature = HealthTypeRegistry.shared.readTypes
            .map(\.identifier)
            .filter { !nutritionIDs.contains($0) }
            .sorted()
            .joined(separator: ",")
        defaults.set(v1Signature, forKey: AppState.authorizedSignatureKey)
        XCTAssertNotEqual(v1Signature, AppState.authorizedTypesSignature(),
                          "registering nutrition must GROW the signature — that growth is what triggers the re-prompt")

        var authorizeCalls = 0
        var lastRequested: [HealthDataType] = []
        let authorize: (_ types: [HealthDataType]) async throws -> Void = { types in
            authorizeCalls += 1
            lastRequested = types
        }

        await appState.reconcileRegistry(registry: .shared, defaults: defaults, authorize: authorize)

        // Gate 1: nutrition is on by default — no manual toggling on upgrade.
        for id in nutritionIDs {
            let row = try XCTUnwrap(try dao.find(hkTypeId: id), "no config row written for \(id)")
            XCTAssertTrue(row.enabled, "\(id) must be enabled by default after upgrade")
        }

        // Gate 2: exactly one authorization request, and the sheet lists nutrition.
        XCTAssertEqual(authorizeCalls, 1, "the grown read set must re-prompt exactly once")
        let requestedIDs = Set(lastRequested.map(\.identifier))
        for id in nutritionIDs {
            XCTAssertTrue(requestedIDs.contains(id), "authorization request must include \(id)")
        }

        // A second launch does not re-prompt.
        await appState.reconcileRegistry(registry: .shared, defaults: defaults, authorize: authorize)
        XCTAssertEqual(authorizeCalls, 1, "the persisted signature must suppress a second prompt")
    }

    // MARK: - Running dynamics upgrade path

    /// The end-to-end upgrade for a user who onboarded before the running-dynamics
    /// batch shipped: rows + stored signature for every type EXCEPT these five.
    /// Both gates must fire off the same reconcile — running dynamics lands
    /// enabled by default, and the grown read set re-prompts exactly once with the
    /// five new types in the sheet. Unlike nutrition (its own new category), these
    /// land inside the pre-existing Activity & Fitness category, so the seed here
    /// filters by identifier rather than by category.
    @MainActor
    func testRunningDynamicsIsAutoEnabledAndRePromptedOnceOnUpgrade() async throws {
        let appState = AppState(database: appDB)
        let dao = DataTypeConfigDAO(appDB)
        let defaults = try makeCleanDefaults()
        let runningDynamicsIDs = [
            HealthDataType.runningPower.identifier,
            HealthDataType.runningSpeed.identifier,
            HealthDataType.runningStrideLength.identifier,
            HealthDataType.runningVerticalOscillation.identifier,
            HealthDataType.runningGroundContactTime.identifier,
        ]

        // Seed a pre-upgrade install: every other type configured, and the stored
        // signature is the pre-upgrade read set.
        for type in HealthTypeRegistry.shared.all where !runningDynamicsIDs.contains(type.identifier) {
            try dao.setEnabled(true, hkTypeId: type.identifier)
        }
        let priorSignature = HealthTypeRegistry.shared.readTypes
            .map(\.identifier)
            .filter { !runningDynamicsIDs.contains($0) }
            .sorted()
            .joined(separator: ",")
        defaults.set(priorSignature, forKey: AppState.authorizedSignatureKey)
        XCTAssertNotEqual(priorSignature, AppState.authorizedTypesSignature(),
                          "registering running dynamics must GROW the signature — that growth is what triggers the re-prompt")

        var authorizeCalls = 0
        var lastRequested: [HealthDataType] = []
        let authorize: (_ types: [HealthDataType]) async throws -> Void = { types in
            authorizeCalls += 1
            lastRequested = types
        }

        await appState.reconcileRegistry(registry: .shared, defaults: defaults, authorize: authorize)

        // Gate 1: running dynamics is on by default — no manual toggling on upgrade.
        for id in runningDynamicsIDs {
            let row = try XCTUnwrap(try dao.find(hkTypeId: id), "no config row written for \(id)")
            XCTAssertTrue(row.enabled, "\(id) must be enabled by default after upgrade")
        }

        // Gate 2: exactly one authorization request, and the sheet lists running dynamics.
        XCTAssertEqual(authorizeCalls, 1, "the grown read set must re-prompt exactly once")
        let requestedIDs = Set(lastRequested.map(\.identifier))
        for id in runningDynamicsIDs {
            XCTAssertTrue(requestedIDs.contains(id), "authorization request must include \(id)")
        }

        // A second launch does not re-prompt.
        await appState.reconcileRegistry(registry: .shared, defaults: defaults, authorize: authorize)
        XCTAssertEqual(authorizeCalls, 1, "the persisted signature must suppress a second prompt")
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
