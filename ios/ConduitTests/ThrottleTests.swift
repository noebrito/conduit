import XCTest
@testable import Conduit

final class ThrottleTests: XCTestCase {

    // MARK: - Time gate

    func test_shouldFlush_whenNeverFlushed_returnsTrue() {
        let t = Throttle(minInterval: 900, forceFlushThreshold: 200)
        XCTAssertTrue(t.shouldFlush(pendingCount: 0))
    }

    func test_shouldFlush_beforeIntervalElapses_returnsFalse() {
        var t = Throttle(minInterval: 900, forceFlushThreshold: 200)
        let base = Date()
        t.recordFlush(at: base)
        // 800s later — still inside the 900s window
        let soon = base.addingTimeInterval(800)
        XCTAssertFalse(t.shouldFlush(pendingCount: 0, now: soon))
    }

    func test_shouldFlush_exactlyAtInterval_returnsTrue() {
        var t = Throttle(minInterval: 900, forceFlushThreshold: 200)
        let base = Date()
        t.recordFlush(at: base)
        let atEdge = base.addingTimeInterval(900)
        XCTAssertTrue(t.shouldFlush(pendingCount: 0, now: atEdge))
    }

    func test_shouldFlush_afterIntervalElapses_returnsTrue() {
        var t = Throttle(minInterval: 900, forceFlushThreshold: 200)
        let base = Date()
        t.recordFlush(at: base)
        let later = base.addingTimeInterval(1800)
        XCTAssertTrue(t.shouldFlush(pendingCount: 0, now: later))
    }

    // MARK: - Count (force-flush) gate

    func test_shouldFlush_atThreshold_returnsTrue() {
        var t = Throttle(minInterval: 900, forceFlushThreshold: 200)
        let base = Date()
        t.recordFlush(at: base)
        // Only 10s since last flush — time gate is closed; count gate should open it
        let soon = base.addingTimeInterval(10)
        XCTAssertTrue(t.shouldFlush(pendingCount: 200, now: soon))
    }

    func test_shouldFlush_belowThreshold_returnsFalse() {
        var t = Throttle(minInterval: 900, forceFlushThreshold: 200)
        let base = Date()
        t.recordFlush(at: base)
        let soon = base.addingTimeInterval(10)
        XCTAssertFalse(t.shouldFlush(pendingCount: 199, now: soon))
    }

    // MARK: - Both gates open simultaneously

    func test_shouldFlush_bothGatesOpen_returnsTrue() {
        var t = Throttle(minInterval: 900, forceFlushThreshold: 200)
        let base = Date()
        t.recordFlush(at: base)
        let later = base.addingTimeInterval(1000)
        XCTAssertTrue(t.shouldFlush(pendingCount: 300, now: later))
    }

    // MARK: - updateParameters preserves lastFlushAt (the wake-recreation bug)

    /// Refreshing the throttle params on an observer wake must NOT reset the time
    /// gate. The bug: `SyncEngine` recreated the struct each wake, which set
    /// `lastFlushAt` back to nil and made `shouldFlush` return true every time.
    func test_updateParameters_preservesLastFlushAt() {
        var t = Throttle(minInterval: 900, forceFlushThreshold: 200)
        let base = Date()
        t.recordFlush(at: base)
        // Simulate a wake refreshing params from the stored webhook config.
        t.updateParameters(minInterval: 900, forceFlushThreshold: 200)
        // Still inside the window — the time gate must remain closed.
        let soon = base.addingTimeInterval(100)
        XCTAssertFalse(t.shouldFlush(pendingCount: 0, now: soon))
    }

    func test_updateParameters_appliesNewGateValues() {
        var t = Throttle(minInterval: 900, forceFlushThreshold: 200)
        let base = Date()
        t.recordFlush(at: base)
        // Shrink the interval; a time that was inside the old window is now past
        // the new one, so the gate should open.
        t.updateParameters(minInterval: 60, forceFlushThreshold: 200)
        let soon = base.addingTimeInterval(100)
        XCTAssertTrue(t.shouldFlush(pendingCount: 0, now: soon))
        XCTAssertEqual(t.minInterval, 60)
        XCTAssertEqual(t.forceFlushThreshold, 200)
    }

    // MARK: - recordFlush resets the time gate

    func test_recordFlush_resetsTimeGate() {
        var t = Throttle(minInterval: 900, forceFlushThreshold: 200)
        let base = Date()
        // First flush at base
        t.recordFlush(at: base)
        // 1000s later — gate would be open; flush again
        let mid = base.addingTimeInterval(1000)
        t.recordFlush(at: mid)
        // 100s after the SECOND flush — gate should be closed again
        let afterSecond = mid.addingTimeInterval(100)
        XCTAssertFalse(t.shouldFlush(pendingCount: 0, now: afterSecond))
    }
}
