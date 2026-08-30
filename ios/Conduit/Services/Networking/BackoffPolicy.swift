import Foundation

/// Exponential backoff schedule for upload retries (ARCHITECTURE.md §4.5).
///
/// Schedule (before jitter): 30s → 2m → 8m → 30m → 2h → 6h → 24h (capped).
/// Each step applies ±20% random jitter to spread retry storms.
/// A 429 response with a `Retry-After` header overrides the schedule.
struct BackoffPolicy {
    /// Base delays in seconds, indexed by attempt number (0-based).
    /// Attempt ≥ schedule.count uses the last entry (24h cap).
    private static let schedule: [TimeInterval] = [30, 120, 480, 1800, 7200, 21600, 86400]

    /// Compute the next retry delay for a given attempt count.
    ///
    /// - Parameters:
    ///   - attemptCount: number of attempts already made (0 = first failure).
    ///   - retryAfter: seconds from a `Retry-After` header on a 429 response.
    ///     When non-nil, this overrides the exponential schedule entirely.
    /// - Returns: a `TimeInterval` (seconds) until the next attempt should be made.
    static func delay(attemptCount: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter {
            return max(0, retryAfter)
        }
        let index = min(attemptCount, schedule.count - 1)
        let base = schedule[index]
        return jittered(base)
    }

    /// The `Date` at which the next retry attempt should be made.
    static func nextAttemptDate(
        attemptCount: Int,
        retryAfter: TimeInterval? = nil,
        now: Date = Date()
    ) -> Date {
        now.addingTimeInterval(delay(attemptCount: attemptCount, retryAfter: retryAfter))
    }

    /// ±20% uniform jitter bounds, applied as a multiplier to the base delay.
    private static let jitterRange: ClosedRange<Double> = 0.8...1.2

    private static func jittered(_ base: TimeInterval) -> TimeInterval {
        let factor = Double.random(in: jitterRange)
        return base * factor
    }
}
