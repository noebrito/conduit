import XCTest
import GRDB
@testable import Conduit

/// `HomeViewModel.fetchStatus(_:reusingCountsFrom:)` — the off-screen probe the
/// status observation runs instead of recounting the outbox on every delivery.
final class HomeStatusFetchTests: XCTestCase {
    private var db: AppDatabase!
    private var webhookID: Int64!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        var wh = WebhookConfig.makeDefault(url: "https://example.com", bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(db).save(&wh)
        webhookID = wh.id
    }

    private func enqueue(_ count: Int) throws {
        for index in 0..<count {
            var sample = Conduit_V1_Sample()
            sample.uuid = "hr-\(index)"
            sample.startUnixMs = 1_700_000_000_000
            sample.endUnixMs = 1_700_000_060_000
            var quantity = Conduit_V1_QuantityValue()
            quantity.value = 72
            quantity.unit = "count/min"
            sample.quantity = quantity
            try OutboxDAO(db).enqueue(sample: sample, hkTypeId: "HKQuantityTypeIdentifierHeartRate", webhookId: webhookID)
        }
    }

    private func markAllFailed() throws {
        try db.dbWriter.write { db in
            try db.execute(sql: "UPDATE outbox SET state = ?", arguments: [OutboxState.failed.rawValue])
        }
    }

    private func fetch(reusingCountsFrom cached: HomeViewModel.StatusSnapshot? = nil) throws -> HomeViewModel.StatusSnapshot {
        try db.dbWriter.read { try HomeViewModel.fetchStatus($0, reusingCountsFrom: cached) }
    }

    func test_fullFetch_countsTheOutbox() throws {
        try enqueue(3)
        let status = try fetch()
        XCTAssertEqual(status.pending, 3)
        XCTAssertEqual(status.failed, 0)
    }

    func test_probe_carriesPendingOverWithoutRecounting() throws {
        let cached = try fetch()
        try enqueue(3)
        let probe = try fetch(reusingCountsFrom: cached)
        XCTAssertEqual(probe.pending, 0)
        XCTAssertEqual(probe.today, 3, "the staged tally is still read fresh")
    }

    /// The failed count crossing zero is a state-class change, so the probe
    /// must see it even though it skips the count itself.
    func test_probe_seesFailuresAppear() throws {
        let cached = try fetch()
        try enqueue(2)
        try markAllFailed()
        XCTAssertEqual(try fetch(reusingCountsFrom: cached).failed, 1)
    }

    func test_probe_seesFailuresClear() throws {
        try enqueue(2)
        try markAllFailed()
        let cached = try fetch()
        XCTAssertEqual(cached.failed, 2)
        _ = try OutboxDAO(db).deleteAll()
        XCTAssertEqual(try fetch(reusingCountsFrom: cached).failed, 0)
    }
}
