import XCTest
import HealthKit
@testable import Conduit

/// Tests for the forward-only capture floor seeded on the first (anchor-less)
/// read. The floor is START-OF-TODAY (device-local midnight), not `now`, so a
/// freshly set-up or just-reset device captures today's samples from midnight
/// onward and shows a COMPLETE Move/Exercise ring for the current day — while
/// staying strictly one-day-bounded (never the old unbounded history backfill).
final class ForwardCaptureFloorTests: XCTestCase {

    func testFloorIsStartOfLocalToday() {
        let cal = Calendar.current
        // A mid-afternoon instant so `now` is clearly not midnight.
        let now = cal.date(bySettingHour: 14, minute: 37, second: 12, of: Date())!

        let floor = SyncEngine.forwardCaptureFloor(now: now, calendar: cal)

        XCTAssertEqual(floor, cal.startOfDay(for: now),
                       "Seeded floor must be the start of the current local day")
    }

    func testFloorIsNotNow() {
        let cal = Calendar.current
        // Any instant that is not exactly midnight.
        let now = cal.date(bySettingHour: 9, minute: 5, second: 0, of: Date())!

        let floor = SyncEngine.forwardCaptureFloor(now: now, calendar: cal)

        XCTAssertNotEqual(floor, now,
                          "Floor must be start-of-today, not the exact `now` instant")
        XCTAssertLessThan(floor, now, "Start-of-today precedes a non-midnight `now`")
    }

    func testFloorIsDeviceLocalMidnight() {
        // Regardless of the time component of `now`, the floor must have zero
        // hour/minute/second in the device-local calendar.
        let cal = Calendar.current
        let now = cal.date(bySettingHour: 23, minute: 59, second: 59, of: Date())!

        let floor = SyncEngine.forwardCaptureFloor(now: now, calendar: cal)

        let parts = cal.dateComponents([.hour, .minute, .second], from: floor)
        XCTAssertEqual(parts.hour, 0)
        XCTAssertEqual(parts.minute, 0)
        XCTAssertEqual(parts.second, 0)
        // Same calendar day as `now`.
        XCTAssertTrue(cal.isDate(floor, inSameDayAs: now))
    }

    func testFloorFlowsIntoStartOfTodayPredicate() {
        // The seeded floor must actually become the read's date-floor predicate
        // (start-of-today), the same predicate machinery the import path uses.
        let cal = Calendar.current
        let now = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let floor = SyncEngine.forwardCaptureFloor(now: now, calendar: cal)

        let predicate = try! XCTUnwrap(AnchoredReader.importPredicate(since: floor))
        let referenceSeconds = Int(cal.startOfDay(for: now).timeIntervalSinceReferenceDate)
        XCTAssertTrue(predicate.predicateFormat.contains("\(referenceSeconds)"),
                      "The read floor must be start-of-today expressed in the predicate")
    }
}
