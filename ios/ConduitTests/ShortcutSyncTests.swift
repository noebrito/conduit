import XCTest
import HealthKit
import AppIntents
@testable import Conduit

final class ShortcutSyncTests: XCTestCase {
    func testCaptureThenFlushCountsAndHonestResult() async {
        var events: [String] = []
        let result = await ShortcutSync.run(identifiers: ["enabled-a", "enabled-b"], shouldStop: { false }, capture: { id in
            events.append(id)
            return ShortcutSync.Capture(captured: 5, queued: 3, deletions: 1)
        }, flush: { events.append("flush"); return 4 })
        XCTAssertEqual(events, ["enabled-a", "enabled-b", "flush"])
        XCTAssertEqual(result.capture.captured, 10)
        XCTAssertEqual(result.capture.queued, 6)
        XCTAssertEqual(result.capture.deletions, 2)
        XCTAssertEqual(result.submitted, 4)
        XCTAssertTrue(result.message.contains("not awaited or confirmed"))
        XCTAssertTrue(result.message.contains("may include earlier data"))
    }

    func testLockedReadPreservesEarlierProgressAndFlushesQueue() async {
        let result = await ShortcutSync.run(identifiers: ["first", "locked", "never"], shouldStop: { false }, capture: { id in
            if id == "first" { return ShortcutSync.Capture(captured: 2, queued: 2) }
            XCTAssertEqual(id, "locked")
            throw NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue)
        }, flush: { 2 })
        XCTAssertEqual(result.capture.queued, 2)
        XCTAssertEqual(result.submitted, 2)
        XCTAssertTrue(result.message.contains("device is locked"))
    }

    func testBudgetStopsFurtherReadsAndStillFlushes() async {
        var reads = 0
        let result = await ShortcutSync.run(identifiers: ["a", "b"], shouldStop: { reads == 1 }, capture: { _ in
            reads += 1
            return ShortcutSync.Capture(captured: 200, queued: 0, limited: true)
        }, flush: { 7 })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(result.capture.captured, 200)
        XCTAssertEqual(result.submitted, 7)
        XCTAssertTrue(result.message.contains("more data may remain"))
    }

    func testPartialRouteFailureRetainsCountsAndDoesNotReadNextType() async {
        var reads = 0
        let result = await ShortcutSync.run(identifiers: ["route", "next"], shouldStop: { false }, capture: { _ in
            reads += 1
            return ShortcutSync.Capture(captured: 3, queued: 2, notice: "Read failed.")
        }, flush: { 0 })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(result.capture.queued, 2)
        XCTAssertTrue(result.message.contains("Read failed."))
    }

    func testFlushFailureDoesNotClaimSubmission() async {
        let result = await ShortcutSync.run(identifiers: ["a"], shouldStop: { false }, capture: { _ in
            ShortcutSync.Capture(captured: 1, queued: 1)
        }, flush: { throw NSError(domain: "test", code: 1) })
        XCTAssertEqual(result.submitted, 0)
        XCTAssertTrue(result.message.contains("Queued data is retained for retry"))
    }

    func testCancelledTaskDoesNotFlush() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ShortcutSync.run(identifiers: ["a"], shouldStop: { Task.isCancelled }, capture: { _ in
                XCTFail("Cancelled action must not read"); return ShortcutSync.Capture()
            }, flush: { XCTFail("Cancelled action must not submit"); return 1 })
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.submitted, 0)
        XCTAssertTrue(result.capture.limited)
    }

    func testNoDestinationDoesNotReadHealth() async throws {
        let database = try AppDatabase.makeInMemory()
        let engine = SyncEngine(database: database)
        let message = await engine.syncFromShortcut()
        XCTAssertTrue(message.contains("configure your destination"))
        XCTAssertEqual(try OutboxDAO(database).totalCount(), 0)
    }

    @MainActor
    func testLockedPreflightNeverOpensConfigurationOrSyncs() async {
        let result = await SyncHealthIntent.execute(protectedDataAvailable: false,
            isConfigured: { XCTFail("Locked preflight must not open the database"); return true },
            sync: { XCTFail("Locked preflight must not capture or upload"); return "" })
        XCTAssertTrue(result.contains("Unlock your iPhone"))
    }

    @MainActor
    func testSetupPreflightAndReadyDispatch() async {
        let setup = await SyncHealthIntent.execute(protectedDataAvailable: true,
            isConfigured: { false }, sync: { XCTFail("Must not sync before setup"); return "" })
        XCTAssertTrue(setup.contains("finish setup"))
        let ready = await SyncHealthIntent.execute(protectedDataAvailable: true,
            isConfigured: { true }, sync: { "bounded result" })
        XCTAssertEqual(ready, "bounded result")
    }

    func testEmptyReadAndRegistrationAreHonest() {
        XCTAssertTrue(ShortcutSync.Summary().message.contains("does not prove Health is empty"))
        XCTAssertEqual(SyncHealthIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        XCTAssertFalse(SyncHealthIntent.openAppWhenRun)
        XCTAssertEqual(ConduitShortcuts.appShortcuts.count, 1)
    }
}
