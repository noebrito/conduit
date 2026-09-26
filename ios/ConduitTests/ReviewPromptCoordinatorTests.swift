import XCTest
@testable import Conduit

@MainActor
final class ReviewPromptCoordinatorTests: XCTestCase {
    @MainActor
    private final class Harness {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        var uptime: TimeInterval = 100
        var stored = ReviewPreferences()
        var requests = 0
        var reads = 0
        var presentable = true
        var readiness: ReviewReadiness!
        let imports = ImportRunCoordinator()
        var pending: CheckedContinuation<ReviewReadiness, Error>?
        var deferRead = false
        var failSave = false
        var version: String? = "1.0"
        lazy var coordinator = makeCoordinator()

        init(eligible: Bool = true) {
            readiness = ReviewReadiness(isReady: true, deliveryAt: now)
            if eligible {
                for offset in [16.0, 15.0, 14.0] {
                    let date = now.addingTimeInterval(-offset * 86400)
                    stored = ReviewEligibility.qualifying(stored, deliveryAt: date, now: date,
                                                         timeZone: TimeZone(secondsFromGMT: 0)!)!
                }
            }
        }

        func makeCoordinator() -> ReviewPromptCoordinator {
            let result = ReviewPromptCoordinator(load: { self.stored }, save: {
                if self.failSave { throw CocoaError(.fileWriteUnknown) }
                self.stored = $0
            }, now: { self.now }, uptime: { self.uptime },
                timeZone: { TimeZone(secondsFromGMT: 0)! }, version: { self.version },
                importActivity: { self.imports.reviewActivity }, read: {
                    self.reads += 1
                    if self.deferRead {
                        return try await withCheckedThrowingContinuation { self.pending = $0 }
                    }
                    return self.readiness
                }, automaticallySchedule: false)
            result.setPresentation(request: {
                XCTAssertNotNil(self.stored.lastAttemptAt, "Persisted before invocation")
                self.requests += 1
            }, canPresent: { self.presentable })
            return result
        }

        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds); uptime += seconds }
        func show() { coordinator.sceneChanged(.active); coordinator.setHomeVisible(true) }
        func startQuietPause() async {
            show()
            await coordinator.tick()
            advance(30)
            await coordinator.tick()
        }
    }

    func testTenUninterruptedSecondsCountsFirstUseProspectively() async {
        let h = Harness(eligible: false)
        h.show(); await h.coordinator.tick()
        h.advance(9); await h.coordinator.tick()
        XCTAssertNil(h.stored.firstQualifiedAt)
        h.advance(1); await h.coordinator.tick()
        XCTAssertEqual(h.stored.firstQualifiedAt, h.now)
        XCTAssertEqual(h.stored.days.count, 1)
        XCTAssertEqual(h.requests, 0)
    }

    func testThirtyForegroundSecondsThenTwoQuietSecondsAndSilentAttemptConsumed() async {
        let h = Harness()
        await h.startQuietPause()
        XCTAssertEqual(h.requests, 0)
        h.advance(1); await h.coordinator.tick(); XCTAssertEqual(h.requests, 0)
        h.advance(1); await h.coordinator.tick(); XCTAssertEqual(h.requests, 1)
        XCTAssertEqual(h.stored.requestedVersions, ["1.0"])
        XCTAssertTrue(h.stored.days.isEmpty)
        h.advance(60); await h.coordinator.tick(); XCTAssertEqual(h.requests, 1)
        let relaunched = h.makeCoordinator()
        relaunched.sceneChanged(.active); relaunched.setHomeVisible(true)
        await relaunched.tick(); h.advance(32); await relaunched.tick()
        h.advance(2); await relaunched.tick()
        XCTAssertEqual(h.requests, 1)
    }

    func testBackgroundAndHiddenHomeCannotCountOrRead() async {
        let h = Harness(eligible: false)
        await h.coordinator.tick()
        h.coordinator.sceneChanged(.active)
        h.advance(100); await h.coordinator.tick()
        XCTAssertEqual(h.reads, 0)
        h.show(); await h.coordinator.tick()
        h.advance(9); h.coordinator.setHomeVisible(false)
        h.advance(40); await h.coordinator.tick()
        XCTAssertNil(h.stored.firstQualifiedAt)
        h.coordinator.setHomeVisible(true); await h.coordinator.tick()
        h.advance(9); h.coordinator.sceneChanged(.background)
        h.advance(40); await h.coordinator.tick()
        XCTAssertNil(h.stored.firstQualifiedAt)
    }

    func testGestureWorkAndModalCancellationConsumeNothing() async {
        for cancellation in 0..<3 {
            let h = Harness()
            await h.startQuietPause()
            if cancellation == 0 { h.coordinator.invalidate() }
            if cancellation == 1 { h.readiness = ReviewReadiness(isReady: false) }
            if cancellation == 2 { h.presentable = false }
            h.advance(2); await h.coordinator.tick()
            XCTAssertEqual(h.requests, 0)
            XCTAssertNil(h.stored.lastAttemptAt)
        }
    }

    func testInactiveResetsContinuousForegroundButDoesNotClearSuppression() async {
        let h = Harness()
        await h.startQuietPause()
        h.coordinator.suppressSession() // permission/config/import/support session
        h.coordinator.sceneChanged(.inactive); h.coordinator.sceneChanged(.active)
        h.advance(100); await h.coordinator.tick()
        XCTAssertTrue(h.coordinator.sessionSuppressed)
        XCTAssertEqual(h.requests, 0)
        h.coordinator.sceneChanged(.background); h.coordinator.sceneChanged(.active)
        XCTAssertFalse(h.coordinator.sessionSuppressed)
        await h.coordinator.tick(); h.advance(30); await h.coordinator.tick()
        h.advance(2); await h.coordinator.tick()
        XCTAssertEqual(h.requests, 1)
    }

    func testInactiveCancelsAndRequiresNewThirtySeconds() async {
        let h = Harness(); await h.startQuietPause()
        h.coordinator.sceneChanged(.inactive); h.coordinator.sceneChanged(.active)
        await h.coordinator.tick(); h.advance(29); await h.coordinator.tick()
        XCTAssertEqual(h.requests, 0)
        h.advance(1); await h.coordinator.tick(); h.advance(2); await h.coordinator.tick()
        XCTAssertEqual(h.requests, 1)
    }

    func testProcessImportOwnerAndCompletedBetweenTicksSuppressWholeSession() async {
        for release in [false, true] {
            let h = Harness(); await h.startQuietPause()
            XCTAssertTrue(h.imports.claim("onboarding-owned"))
            if release { h.imports.release("onboarding-owned") }
            h.advance(2); await h.coordinator.tick()
            XCTAssertTrue(h.coordinator.sessionSuppressed)
            XCTAssertEqual(h.requests, 0)
        }
    }

    func testPersistedImportSuppressesWithoutLocalOwner() async {
        let h = Harness()
        h.readiness = ReviewReadiness(isReady: false, importIsActive: true)
        h.show(); await h.coordinator.tick()
        XCTAssertTrue(h.coordinator.sessionSuppressed)
    }

    func testStaleFinalReadCannotReserveAfterTabChangeOrDuplicateTick() async {
        let h = Harness(); await h.startQuietPause()
        h.deferRead = true; h.advance(2)
        let finalRead = Task { await h.coordinator.tick() }
        while h.pending == nil { await Task.yield() }
        await h.coordinator.tick() // Cannot launch a competing reservation.
        h.coordinator.setHomeVisible(false)
        h.pending?.resume(returning: h.readiness); h.pending = nil
        await finalRead.value
        XCTAssertEqual(h.requests, 0)
        XCTAssertNil(h.stored.lastAttemptAt)
    }

    func testFinalReadDoesNotRequireAnUncountedDelivery() async {
        let h = Harness()
        h.stored.lastDeliveryAt = h.now
        h.stored.lastQualifiedAt = h.now
        h.stored.lastRecordedAt = h.now
        h.stored.lastQualifiedDay = ReviewEligibility.dayKey(h.now, timeZone: TimeZone(secondsFromGMT: 0)!)
        h.stored.days[2] = h.stored.lastQualifiedDay!
        await h.startQuietPause(); h.advance(2); await h.coordinator.tick()
        XCTAssertEqual(h.requests, 1)
    }

    func testPersistenceFailureMissingVersionAndClockJumpsDefer() async {
        for mode in 0..<4 {
            let h = Harness(); await h.startQuietPause()
            if mode == 0 { h.failSave = true }
            if mode == 1 { h.version = nil }
            if mode == 2 { h.now.addTimeInterval(-60) }
            if mode == 3 { h.now.addTimeInterval(86400) }
            h.advance(2); await h.coordinator.tick()
            XCTAssertEqual(h.requests, 0)
            XCTAssertNil(h.stored.lastAttemptAt)
        }
    }

    func testSensitiveWorkStillRunningAfterBackgroundAndManualSyncBlock() async {
        let h = Harness()
        h.coordinator.beginSensitiveActivity()
        h.coordinator.sceneChanged(.background)
        h.show(); await h.coordinator.tick()
        XCTAssertTrue(h.coordinator.sessionSuppressed)
        h.coordinator.endSensitiveActivity()
        h.coordinator.sceneChanged(.background); h.show()
        h.coordinator.setManualSyncActive(true)
        await h.coordinator.tick(); h.advance(60); await h.coordinator.tick()
        XCTAssertEqual(h.requests, 0)
        h.coordinator.setManualSyncActive(false)
        await h.coordinator.tick(); h.advance(10); await h.coordinator.tick()
        h.advance(2); await h.coordinator.tick()
        XCTAssertEqual(h.requests, 1)
    }

    func testAppOnboardingAndQueueResetsPreserveReviewRecord() async throws {
        let h = Harness()
        await h.startQuietPause(); h.advance(2); await h.coordinator.tick()
        let before = h.stored
        let app = AppState(database: try AppDatabase.makeInMemory(), reloadTimelines: {})
        app.reviewPrompt = h.coordinator
        let wasComplete = UserDefaults.standard.bool(forKey: "conduit.onboardingComplete")
        defer { UserDefaults.standard.set(wasComplete, forKey: "conduit.onboardingComplete") }
        app.resetOnboarding()
        app.completeOnboarding()
        app.resetSyncQueue()
        XCTAssertEqual(h.stored, before)
        XCTAssertTrue(app.reviewPrompt.sessionSuppressed)
    }

    func testUnsafeDatabaseWaitsForObservationInsteadOfPolling() async {
        let h = Harness()
        h.readiness = ReviewReadiness(isReady: false)
        h.show(); await h.coordinator.tick()
        h.advance(60); await h.coordinator.tick()
        XCTAssertEqual(h.reads, 1)
        h.readiness = ReviewReadiness(isReady: true, deliveryAt: h.now)
        h.coordinator.invalidate() // shared status observation reports a commit
        await h.coordinator.tick()
        XCTAssertEqual(h.reads, 2)
    }

    func testCorruptPreferencesAreNotOverwritten() async {
        let h = Harness(); h.stored.schema = 500
        h.show(); await h.coordinator.tick(); h.advance(60); await h.coordinator.tick()
        XCTAssertEqual(h.requests, 0); XCTAssertEqual(h.stored.schema, 500)
    }
}
