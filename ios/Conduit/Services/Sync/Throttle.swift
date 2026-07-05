import Foundation

/// Guards upload flushes so we don't hit the webhook on every single
/// HealthKit observer wake (ARCHITECTURE.md §4.4).
///
/// Two conditions independently trigger a flush:
/// - **Time gate**: at least `minInterval` seconds have passed since the last flush.
/// - **Size gate**: the pending outbox count has hit `forceFlushThreshold`.
///
/// Either gate being true means `shouldFlush` returns `true`.
struct Throttle {
    private(set) var minInterval: TimeInterval
    private(set) var forceFlushThreshold: Int

    /// When the last successful flush was dispatched, or `nil` if never.
    private var lastFlushAt: Date?

    init(minInterval: TimeInterval, forceFlushThreshold: Int) {
        self.minInterval = minInterval
        self.forceFlushThreshold = forceFlushThreshold
    }

    /// Update the gate parameters **in place**, preserving `lastFlushAt`.
    ///
    /// Callers refresh these from the stored webhook config on every observer
    /// wake so settings changes take effect without a restart. This MUST NOT be
    /// done by recreating the struct: a fresh `Throttle` has `lastFlushAt == nil`,
    /// which makes `shouldFlush` return `true` on every wake and silently defeats
    /// the whole min-interval time gate (each wake would flush regardless of how
    /// recently the last one fired). Updating in place keeps the time gate honest.
    mutating func updateParameters(minInterval: TimeInterval, forceFlushThreshold: Int) {
        self.minInterval = minInterval
        self.forceFlushThreshold = forceFlushThreshold
    }

    /// Returns `true` when a flush should be dispatched now.
    ///
    /// `flush_now = (now − last_flush_at ≥ min_interval) OR (pending_count ≥ force_flush_threshold)`
    func shouldFlush(pendingCount: Int, now: Date = Date()) -> Bool {
        let timeSinceLastFlush = lastFlushAt.map { now.timeIntervalSince($0) } ?? .infinity
        return timeSinceLastFlush >= minInterval || pendingCount >= forceFlushThreshold
    }

    /// Record that a flush was dispatched at `date`. Call this immediately
    /// before dispatching the batch so the time gate resets.
    mutating func recordFlush(at date: Date = Date()) {
        lastFlushAt = date
    }
}
