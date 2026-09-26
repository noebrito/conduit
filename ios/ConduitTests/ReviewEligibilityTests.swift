import XCTest
@testable import Conduit

final class ReviewEligibilityTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
    private let zone = TimeZone(secondsFromGMT: 0)!

    func qualified(days: Int = 3) -> ReviewPreferences {
        var state = ReviewPreferences()
        for index in 0..<days {
            let date = start.addingTimeInterval(Double(index) * ReviewEligibility.day)
            state = ReviewEligibility.qualifying(state, deliveryAt: date, now: date, timeZone: zone)!
        }
        return state
    }

    func testProspectiveClockAndFourteenElapsedDays() {
        let state = qualified()
        XCTAssertEqual(state.firstQualifiedAt, start)
        XCTAssertFalse(ReviewEligibility.canRequest(state, now: start.addingTimeInterval(14 * 86400 - 1), version: "1"))
        XCTAssertTrue(ReviewEligibility.canRequest(state, now: start.addingTimeInterval(14 * 86400), version: "1"))
        XCTAssertFalse(ReviewEligibility.canRequest(qualified(days: 2), now: start.addingTimeInterval(30 * 86400), version: "1"))
    }

    func testMidnightDoesNotBypassTwentyHoursOrReuseDelivery() {
        let first = start.addingTimeInterval(23 * 3600)
        let state = ReviewEligibility.qualifying(.init(), deliveryAt: first, now: first, timeZone: zone)!
        let early = first.addingTimeInterval(20 * 3600 - 1)
        XCTAssertNil(ReviewEligibility.qualifying(state, deliveryAt: early, now: early, timeZone: zone))
        let next = first.addingTimeInterval(20 * 3600)
        XCTAssertNotNil(ReviewEligibility.qualifying(state, deliveryAt: next, now: next, timeZone: zone))
        XCTAssertNil(ReviewEligibility.qualifying(state, deliveryAt: first, now: next, timeZone: zone))
    }

    func testLocalGregorianDaysTimezoneTravelAndBoundedCycle() {
        let first = ReviewEligibility.qualifying(.init(), deliveryAt: start, now: start, timeZone: zone)!
        // Crossing the date line changes the key, but cannot create elapsed time.
        XCTAssertNil(ReviewEligibility.qualifying(first, deliveryAt: start.addingTimeInterval(1),
            now: start.addingTimeInterval(1), timeZone: TimeZone(secondsFromGMT: -12 * 3600)!))
        let full = qualified()
        XCTAssertEqual(full.days.count, 3)
        XCTAssertNil(ReviewEligibility.qualifying(full, deliveryAt: start.addingTimeInterval(3 * 86400),
            now: start.addingTimeInterval(3 * 86400), timeZone: zone))
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let beforeDST = ISO8601DateFormatter().date(from: "2026-03-08T09:30:00Z")!
        XCTAssertEqual(ReviewEligibility.dayKey(beforeDST, timeZone: la), "2026-03-08")
        XCTAssertEqual(ReviewEligibility.dayKey(beforeDST.addingTimeInterval(3600), timeZone: la), "2026-03-08")
    }

    func testDeliveryFreshnessAndFutureClockBoundaries() {
        XCTAssertNotNil(ReviewEligibility.qualifying(.init(), deliveryAt: start.addingTimeInterval(-86400), now: start, timeZone: zone))
        XCTAssertNil(ReviewEligibility.qualifying(.init(), deliveryAt: start.addingTimeInterval(-86401), now: start, timeZone: zone))
        XCTAssertNil(ReviewEligibility.qualifying(.init(), deliveryAt: start.addingTimeInterval(1), now: start, timeZone: zone))
        XCTAssertFalse(ReviewEligibility.valid(qualified(), now: start))
    }

    func testCooldownNewDaysAndMarketingVersionAreAllRequired() {
        let attempt = start.addingTimeInterval(14 * 86400)
        var state = ReviewEligibility.reserving(qualified(), now: attempt, version: "1.2")!
        XCTAssertTrue(state.days.isEmpty)
        XCTAssertFalse(ReviewEligibility.canRequest(state, now: attempt.addingTimeInterval(180 * 86400), version: "1.3"))
        for day in 1...3 {
            let date = attempt.addingTimeInterval(Double(day) * 86400)
            state = ReviewEligibility.qualifying(state, deliveryAt: date, now: date, timeZone: zone)!
        }
        XCTAssertFalse(ReviewEligibility.canRequest(state, now: attempt.addingTimeInterval(180 * 86400 - 1), version: "1.3"))
        XCTAssertFalse(ReviewEligibility.canRequest(state, now: attempt.addingTimeInterval(180 * 86400), version: "1.2"))
        XCTAssertTrue(ReviewEligibility.canRequest(state, now: attempt.addingTimeInterval(180 * 86400), version: "1.3"))
        XCTAssertFalse(ReviewEligibility.canRequest(state, now: attempt.addingTimeInterval(180 * 86400), version: nil))
        XCTAssertFalse(ReviewEligibility.canRequest(state, now: attempt.addingTimeInterval(180 * 86400), version: " "))
    }

    func testPreferencesRoundTripAndUnrelatedResetsPreserveHistory() throws {
        let name = "ReviewTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ReviewPreferencesStore(defaults: defaults)
        XCTAssertEqual(try store.load(), ReviewPreferences())
        let state = ReviewEligibility.reserving(qualified(), now: start.addingTimeInterval(14 * 86400), version: "2")!
        try store.save(state)
        defaults.set(false, forKey: "conduit.onboardingComplete")
        defaults.removeObject(forKey: AppState.authorizedSignatureKey)
        XCTAssertEqual(try ReviewPreferencesStore(defaults: defaults).load(), state)
        defaults.set(Data("broken".utf8), forKey: ReviewPreferencesStore.key)
        XCTAssertThrowsError(try store.load())
        defaults.set("wrong type", forKey: ReviewPreferencesStore.key)
        XCTAssertThrowsError(try store.load())
    }

    func testMalformedRecordsDefer() {
        var state = qualified()
        state.schema = 99
        XCTAssertFalse(ReviewEligibility.valid(state, now: start.addingTimeInterval(20 * 86400)))
        state = qualified(); state.days = ["2026-99-99"]
        XCTAssertFalse(ReviewEligibility.valid(state, now: start.addingTimeInterval(20 * 86400)))
        state = qualified(); state.lastQualifiedAt = nil
        XCTAssertFalse(ReviewEligibility.valid(state, now: start.addingTimeInterval(20 * 86400)))
    }
}
