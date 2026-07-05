import XCTest
@testable import Conduit

final class BackoffPolicyTests: XCTestCase {

    // MARK: - Schedule

    private let schedule: [TimeInterval] = [30, 120, 480, 1800, 7200, 21600, 86400]

    func test_delay_followsExponentialSchedule() {
        for (attempt, base) in schedule.enumerated() {
            let low  = base * 0.8
            let high = base * 1.2
            let d = BackoffPolicy.delay(attemptCount: attempt)
            XCTAssertGreaterThanOrEqual(d, low,  "attempt \(attempt): \(d) < \(low)")
            XCTAssertLessThanOrEqual(   d, high, "attempt \(attempt): \(d) > \(high)")
        }
    }

    func test_delay_cappedat24h() {
        // Any attempt beyond the table cap should stay at 24h ± jitter
        let d = BackoffPolicy.delay(attemptCount: 100)
        XCTAssertGreaterThanOrEqual(d, 86400 * 0.8)
        XCTAssertLessThanOrEqual(   d, 86400 * 1.2)
    }

    // MARK: - Jitter bounds (statistical)

    func test_delay_jitterWithin20Percent() {
        // Run many samples; all should fall within ±20% of the base.
        let base: TimeInterval = 30   // attempt 0
        for _ in 0..<100 {
            let d = BackoffPolicy.delay(attemptCount: 0)
            XCTAssertGreaterThanOrEqual(d, base * 0.8)
            XCTAssertLessThanOrEqual(   d, base * 1.2)
        }
    }

    func test_delay_jitterIsNotConstant() {
        // Very unlikely all 20 samples are identical if jitter is truly random.
        let samples = (0..<20).map { _ in BackoffPolicy.delay(attemptCount: 0) }
        let unique = Set(samples)
        XCTAssertGreaterThan(unique.count, 1, "All jittered delays were identical — jitter may be broken")
    }

    // MARK: - Retry-After override

    func test_delay_retryAfterOverridesSchedule() {
        // Attempt 0 base is 30s; Retry-After says 300s
        let d = BackoffPolicy.delay(attemptCount: 0, retryAfter: 300)
        XCTAssertEqual(d, 300, accuracy: 0.001)
    }

    func test_delay_retryAfterZero() {
        let d = BackoffPolicy.delay(attemptCount: 0, retryAfter: 0)
        XCTAssertEqual(d, 0, accuracy: 0.001)
    }

    func test_delay_retryAfterNegativeClampedToZero() {
        let d = BackoffPolicy.delay(attemptCount: 0, retryAfter: -5)
        XCTAssertGreaterThanOrEqual(d, 0)
    }

    // MARK: - nextAttemptDate

    func test_nextAttemptDate_isInFuture() {
        let now = Date()
        let next = BackoffPolicy.nextAttemptDate(attemptCount: 0, now: now)
        XCTAssertGreaterThan(next, now)
    }

    func test_nextAttemptDate_withRetryAfter() {
        let now = Date()
        let next = BackoffPolicy.nextAttemptDate(attemptCount: 0, retryAfter: 60, now: now)
        XCTAssertEqual(next.timeIntervalSince(now), 60, accuracy: 0.001)
    }
}
