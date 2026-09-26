import XCTest
import GRDB
@testable import Conduit

final class ReviewReadinessTests: XCTestCase {
    private var database: AppDatabase!
    private var config: WebhookConfig!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        config = WebhookConfig.makeDefault(url: "https://example.invalid/webhook", bearerTokenKeychainRef: "fixture", now: now.addingTimeInterval(-172800))
        try WebhookConfigDAO(database).save(&config, now: config.updatedAt)
    }

    private func delivery(at: Date? = nil, count: Int = 5, status: Int = 200,
                          accepted: Int? = nil, deduped: Int? = nil, error: String? = nil) throws {
        try database.dbWriter.write { db in
            var entry = DeliveryLogEntry(batchId: UUID().uuidString, sentAt: at ?? now,
                httpStatus: status, sampleCount: count, errorMessage: error, accepted: accepted, deduped: deduped)
            try entry.insert(db)
            if entry.isSuccess { try SyncStateDAO.setLastSyncedAt(db, entry.sentAt) }
        }
    }

    private func readiness(hasToken: Bool = true) throws -> ReviewReadiness {
        try database.dbWriter.read { try ReviewReadiness.fetch($0, now: now, hasToken: hasToken) }
    }

    func testEmptyFlushAndProbeAreNotDelivery() throws {
        try SyncStateDAO(database).setLastSyncedAt(now)
        XCTAssertFalse(try readiness().isReady)
        try delivery(count: 0)
        XCTAssertFalse(try readiness().isReady)
    }

    func testAllDedupedAndGeneric2xxQualify() throws {
        try delivery(accepted: 0, deduped: 5)
        XCTAssertTrue(try readiness().isReady)
        try database.dbWriter.write { try DeliveryLogEntry.deleteAll($0) }
        try delivery(status: 204)
        XCTAssertTrue(try readiness().isReady)
    }

    func testDeliveryMustBeFreshNotFutureAndAfterConfiguration() throws {
        try delivery(at: now.addingTimeInterval(-86401))
        XCTAssertFalse(try readiness().isReady)
        try delivery(at: now.addingTimeInterval(-86400))
        XCTAssertTrue(try readiness().isReady)
        try WebhookConfigDAO(database).save(&config, now: now.addingTimeInterval(-60))
        XCTAssertFalse(try readiness().isReady)
        try delivery(at: now.addingTimeInterval(-60))
        XCTAssertTrue(try readiness().isReady)
        try delivery(at: now.addingTimeInterval(1))
        XCTAssertFalse(try readiness().isReady)
    }

    func testConfiguredDestinationAndTokenRequired() throws {
        try delivery()
        XCTAssertFalse(try readiness(hasToken: false).isReady)
        config.url = ""
        try WebhookConfigDAO(database).save(&config, now: now)
        XCTAssertFalse(try readiness().isReady)
    }

    func testPendingInflightAndFailedRowsBlockEvenWithFreshSync() throws {
        try delivery()
        for state in ["pending", "inflight", "failed"] {
            try database.dbWriter.write { db in
                try db.execute(sql: """
                    INSERT INTO outbox (webhook_id, hk_sample_uuid, hk_type_id, payload_blob,
                        created_at, state, attempt_count) VALUES (?, ?, 'fixture', ?, ?, ?, 0)
                    """, arguments: [config.id, UUID().uuidString, Data(), now, state])
            }
            XCTAssertFalse(try readiness().isReady, state)
            try OutboxDAO(database).deleteAll()
        }
        XCTAssertTrue(try readiness().isReady)
    }

    func testPastErrorDoesNotPermanentlyExcludeAndCurrentErrorBlocks() throws {
        try delivery(at: now.addingTimeInterval(-10), status: 500, error: "fixture")
        try delivery()
        XCTAssertTrue(try readiness().isReady)
        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM sync_state")
            try db.execute(sql: "DELETE FROM delivery_log WHERE http_status = 200")
        }
        XCTAssertFalse(try readiness().isReady)
    }

    func testPersistentRunningAndAutoResumeBlockButOldFailedImportDoesNot() throws {
        try delivery()
        var run = try ImportProgressDAO(database).beginRun(runId: "fixture", rangeId: "allTime", rangeStart: nil, typesTotal: 1, now: now)
        XCTAssertTrue(try readiness().importIsActive)
        run.status = .interrupted; run.autoResume = true
        try database.dbWriter.write { try run.save($0) }
        XCTAssertTrue(try readiness().importIsActive)
        run.status = .failed; run.autoResume = false; run.failureReason = "old fixture"
        try database.dbWriter.write { try run.save($0) }
        XCTAssertTrue(try readiness().isReady)
    }

    func testCompletedImportCountsWithoutDeliveryNeverQualify() throws {
        var run = try ImportProgressDAO(database).beginRun(runId: "fixture", rangeId: "allTime", rangeStart: nil, typesTotal: 1, now: now)
        run.status = .completed; run.stagedCount = 100_000
        try database.dbWriter.write { try run.save($0) }
        try SyncStateDAO(database).setLastSyncedAt(now)
        XCTAssertFalse(try readiness().isReady)
    }
}

// Executable URL contracts: public destinations, no automatic attachments or credentials.
final class ReviewLinkTests: XCTestCase {
    @MainActor
    func testPublicReviewAndHelpDestinations() throws {
        let review = try XCTUnwrap(URLComponents(url: ReviewHelpLinks.reviewURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(review.scheme, "https")
        XCTAssertEqual(review.host, "apps.apple.com")
        XCTAssertEqual(review.path, "/app/id6786544769")
        XCTAssertEqual(review.queryItems, [URLQueryItem(name: "action", value: "write-review")])
        let help = try XCTUnwrap(URLComponents(url: ReviewHelpLinks.helpURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(help.scheme, "https")
        XCTAssertEqual(help.host, "github.com")
        XCTAssertEqual(help.path, "/noebrito/conduit/issues")
        XCTAssertNil(help.query)
        XCTAssertNil(help.user)
        XCTAssertNil(help.password)
    }
}
