import XCTest
import GRDB
@testable import Conduit

final class OutboxDAOTests: XCTestCase {
    private var appDB: AppDatabase!
    private var webhookId: Int64!
    private var outbox: OutboxDAO!

    private let heartRateID = HealthDataType.heartRate.identifier

    override func setUpWithError() throws {
        appDB = try AppDatabase.makeInMemory()
        let webhookDAO = WebhookConfigDAO(appDB)
        var config = WebhookConfig.makeDefault(
            url: "https://example.com/hook",
            bearerTokenKeychainRef: "webhook_bearer_token"
        )
        try webhookDAO.save(&config)
        webhookId = try XCTUnwrap(config.id)
        outbox = OutboxDAO(appDB)
    }

    private func makeSample(uuid: String) -> Conduit_V1_Sample {
        var sample = Conduit_V1_Sample()
        sample.uuid = uuid
        sample.startUnixMs = 1_000
        sample.endUnixMs = 2_000
        var quantity = Conduit_V1_QuantityValue()
        quantity.value = 60
        quantity.unit = "count/min"
        sample.quantity = quantity
        return sample
    }

    func testEnqueueDedupesOnSampleUUID() throws {
        let sample = makeSample(uuid: "11111111-1111-1111-1111-111111111111")

        let firstInsert = try outbox.enqueue(sample: sample, hkTypeId: heartRateID, webhookId: webhookId)
        let secondInsert = try outbox.enqueue(sample: sample, hkTypeId: heartRateID, webhookId: webhookId)

        XCTAssertTrue(firstInsert, "First enqueue should insert a new row")
        XCTAssertFalse(secondInsert, "Duplicate enqueue should be ignored")
        XCTAssertEqual(try outbox.totalCount(), 1, "Duplicate sample must not create a second row")
    }

    func testIngestEnqueuesSamplesAndAdvancesAnchorAtomically() throws {
        let samples = [makeSample(uuid: "A"), makeSample(uuid: "B")]
        let anchorBlob = Data([0x01, 0x02, 0x03])

        let inserted = try outbox.ingest(
            samples: samples,
            hkTypeId: heartRateID,
            webhookId: webhookId,
            anchorBlob: anchorBlob
        )

        XCTAssertEqual(inserted, 2)
        XCTAssertEqual(try outbox.totalCount(), 2)

        let config = try DataTypeConfigDAO(appDB).find(hkTypeId: heartRateID)
        XCTAssertEqual(config?.anchorBlob, anchorBlob, "Anchor must be persisted in the same transaction")
        XCTAssertNotNil(config?.lastSyncAt)
    }

    func testIngestReRunOnlyInsertsNewSamples() throws {
        _ = try outbox.ingest(
            samples: [makeSample(uuid: "A"), makeSample(uuid: "B")],
            hkTypeId: heartRateID,
            webhookId: webhookId,
            anchorBlob: Data([0x01])
        )

        let insertedSecondPass = try outbox.ingest(
            samples: [makeSample(uuid: "A"), makeSample(uuid: "B"), makeSample(uuid: "C")],
            hkTypeId: heartRateID,
            webhookId: webhookId,
            anchorBlob: Data([0x02])
        )

        XCTAssertEqual(insertedSecondPass, 1, "Only the new sample C should be inserted")
        XCTAssertEqual(try outbox.totalCount(), 3)

        let config = try DataTypeConfigDAO(appDB).find(hkTypeId: heartRateID)
        XCTAssertEqual(config?.anchorBlob, Data([0x02]), "Anchor should advance on re-run")
    }

    func testReadyToSendReturnsPendingRows() throws {
        _ = try outbox.enqueue(sample: makeSample(uuid: "A"), hkTypeId: heartRateID, webhookId: webhookId)
        _ = try outbox.enqueue(sample: makeSample(uuid: "B"), hkTypeId: heartRateID, webhookId: webhookId)

        XCTAssertEqual(try outbox.count(state: .pending), 2)
        XCTAssertEqual(try outbox.readyToSend(limit: 10).count, 2)
    }

    // MARK: - outboxCap enforcement

    func testIngestStopsStagingAtCap() throws {
        let samples = (0..<5).map { makeSample(uuid: "cap-\($0)") }

        // Cap of 3: only the first 3 stage, the rest are dropped as back-pressure.
        let inserted = try outbox.ingest(
            samples: samples,
            hkTypeId: heartRateID,
            webhookId: webhookId,
            anchorBlob: Data([0xFF]),
            cap: 3
        )

        XCTAssertEqual(inserted, 3, "ingest must stop staging once the cap is reached")
        XCTAssertEqual(try outbox.totalCount(), 3)
    }

    func testIngestDoesNotAdvanceAnchorWhenCapForcesDrop() throws {
        // Pre-seed an anchor so we can prove it is NOT clobbered when the cap hits.
        try appDB.dbWriter.write { db in
            try DataTypeConfigDAO.advanceAnchor(db, hkTypeId: heartRateID, anchorBlob: Data([0x01]), syncedAt: Date())
        }

        let samples = (0..<5).map { makeSample(uuid: "drop-\($0)") }
        _ = try outbox.ingest(
            samples: samples,
            hkTypeId: heartRateID,
            webhookId: webhookId,
            anchorBlob: Data([0x02]),
            cap: 3
        )

        // Anchor must stay at the pre-seed value: dropped samples are NOT lost,
        // they will be re-delivered on a later read once the outbox drains.
        let config = try DataTypeConfigDAO(appDB).find(hkTypeId: heartRateID)
        XCTAssertEqual(config?.anchorBlob, Data([0x01]), "Anchor must not advance past dropped samples")
    }

    func testIngestAdvancesAnchorWhenUnderCap() throws {
        let samples = [makeSample(uuid: "x"), makeSample(uuid: "y")]
        _ = try outbox.ingest(
            samples: samples,
            hkTypeId: heartRateID,
            webhookId: webhookId,
            anchorBlob: Data([0xAA]),
            cap: 100
        )

        let config = try DataTypeConfigDAO(appDB).find(hkTypeId: heartRateID)
        XCTAssertEqual(config?.anchorBlob, Data([0xAA]), "Anchor advances when the whole batch fits under the cap")
    }

    // MARK: - Import staging (enqueue-only, forward anchor untouched)

    func testStageImportEnqueuesWithoutAdvancingForwardAnchor() throws {
        // Seed a live forward-capture anchor, then import history and prove the
        // anchor is NOT touched (the whole point of the enqueue-only path).
        try appDB.dbWriter.write { db in
            try DataTypeConfigDAO.advanceAnchor(db, hkTypeId: heartRateID, anchorBlob: Data([0x42]), syncedAt: Date())
        }

        let result = try outbox.stageImport(
            samples: [makeSample(uuid: "hist-1"), makeSample(uuid: "hist-2")],
            hkTypeId: heartRateID,
            webhookId: webhookId
        )

        XCTAssertEqual(result.inserted, 2)
        XCTAssertFalse(result.hitCap)
        XCTAssertEqual(try outbox.totalCount(), 2, "Imported samples must be staged")

        let config = try DataTypeConfigDAO(appDB).find(hkTypeId: heartRateID)
        XCTAssertEqual(config?.anchorBlob, Data([0x42]), "Import must NOT advance the live forward anchor")
    }

    func testStageImportDedupesAgainstAlreadyStagedSamples() throws {
        // A sample the forward stream already staged must not be double-staged
        // by the import (UUID dedupe).
        _ = try outbox.enqueue(sample: makeSample(uuid: "shared"), hkTypeId: heartRateID, webhookId: webhookId)

        let result = try outbox.stageImport(
            samples: [makeSample(uuid: "shared"), makeSample(uuid: "new")],
            hkTypeId: heartRateID,
            webhookId: webhookId
        )

        XCTAssertEqual(result.inserted, 1, "Only the genuinely new sample is inserted")
        XCTAssertEqual(try outbox.totalCount(), 2)
    }

    func testStageImportStopsAndReportsCap() throws {
        let samples = (0..<10).map { makeSample(uuid: "imp-\($0)") }

        let result = try outbox.stageImport(
            samples: samples,
            hkTypeId: heartRateID,
            webhookId: webhookId,
            cap: 4
        )

        XCTAssertEqual(result.inserted, 4, "Import must stop staging at the cap")
        XCTAssertTrue(result.hitCap, "hitCap must signal the caller to stop paging")
        XCTAssertEqual(try outbox.totalCount(), 4)
    }

    // MARK: - Cap frees up as delivered rows leave the outbox

    /// The core of the import-stall fix: because delivered rows are DELETED from
    /// the outbox (not kept as `sent`), `fetchCount` reflects real backlog, so
    /// forward `ingest` resumes staging once the outbox drains below the cap.
    func testIngestResumesStagingAfterOutboxDrainsBelowCap() throws {
        // Fill the outbox to a cap of 3.
        let firstBatch = (0..<3).map { makeSample(uuid: "first-\($0)") }
        let inserted = try outbox.ingest(
            samples: firstBatch,
            hkTypeId: heartRateID,
            webhookId: webhookId,
            anchorBlob: Data([0x01]),
            cap: 3
        )
        XCTAssertEqual(inserted, 3)

        // A further ingest while full stages nothing (back-pressure).
        let blocked = try outbox.ingest(
            samples: [makeSample(uuid: "blocked")],
            hkTypeId: heartRateID,
            webhookId: webhookId,
            anchorBlob: Data([0x02]),
            cap: 3
        )
        XCTAssertEqual(blocked, 0, "While the outbox is at cap, nothing new stages")

        // Simulate a successful delivery draining 2 rows out of the outbox
        // (this is what Uploader.commitSent does on a 2xx).
        try appDB.dbWriter.write { db in
            let ids = try OutboxRow.limit(2).fetchAll(db).compactMap(\.id)
            _ = try OutboxRow.filter(ids.contains(Column("id"))).deleteAll(db)
        }
        XCTAssertEqual(try outbox.totalCount(), 1, "Outbox drained to 1 row below the cap")

        // Forward capture now resumes — the freed capacity lets today's samples stage.
        let resumed = try outbox.ingest(
            samples: [makeSample(uuid: "today-1"), makeSample(uuid: "today-2")],
            hkTypeId: heartRateID,
            webhookId: webhookId,
            anchorBlob: Data([0x03]),
            cap: 3
        )
        XCTAssertEqual(resumed, 2, "Once drained below cap, forward capture stages again")
        XCTAssertEqual(try outbox.totalCount(), 3)
    }

    /// The import-resume half of the same fix: a second `stageImport` after the
    /// outbox drains continues instead of immediately reporting `hitCap`.
    func testStageImportResumesAfterOutboxDrainsBelowCap() throws {
        // First import page fills the outbox to the cap of 4 and reports hitCap.
        let firstPage = (0..<6).map { makeSample(uuid: "imp-a-\($0)") }
        let first = try outbox.stageImport(
            samples: firstPage,
            hkTypeId: heartRateID,
            webhookId: webhookId,
            cap: 4
        )
        XCTAssertEqual(first.inserted, 4)
        XCTAssertTrue(first.hitCap, "First page fills the cap")

        // A retry while still full stages nothing and re-reports hitCap — this is
        // the wedge the fix addresses when delivered rows are NOT removed.
        let stillFull = try outbox.stageImport(
            samples: [makeSample(uuid: "imp-b-0")],
            hkTypeId: heartRateID,
            webhookId: webhookId,
            cap: 4
        )
        XCTAssertEqual(stillFull.inserted, 0)
        XCTAssertTrue(stillFull.hitCap, "While full, import re-hits the cap immediately")

        // Delivery drains the outbox (Uploader.commitSent deletes delivered rows).
        try appDB.dbWriter.write { db in
            let ids = try OutboxRow.limit(3).fetchAll(db).compactMap(\.id)
            _ = try OutboxRow.filter(ids.contains(Column("id"))).deleteAll(db)
        }
        XCTAssertEqual(try outbox.totalCount(), 1)

        // The next import page now continues instead of hitCap.
        let resumed = try outbox.stageImport(
            samples: [makeSample(uuid: "imp-b-1"), makeSample(uuid: "imp-b-2")],
            hkTypeId: heartRateID,
            webhookId: webhookId,
            cap: 4
        )
        XCTAssertEqual(resumed.inserted, 2, "Import resumes staging once the outbox drains below cap")
        XCTAssertFalse(resumed.hitCap, "Room under the cap means the page no longer trips back-pressure")
    }

    // MARK: - Purge (one-time remediation)

    func testDeleteAllPurgesEveryRowRegardlessOfState() throws {
        _ = try outbox.enqueue(sample: makeSample(uuid: "p"), hkTypeId: heartRateID, webhookId: webhookId)
        _ = try outbox.enqueue(sample: makeSample(uuid: "q"), hkTypeId: heartRateID, webhookId: webhookId)
        let row = try XCTUnwrap(outbox.find(hkSampleUuid: "q"))
        try outbox.updateState(ids: [try XCTUnwrap(row.id)], to: .inflight, batchId: "b1")

        let deleted = try outbox.deleteAll()

        XCTAssertEqual(deleted, 2, "deleteAll must remove every row across states")
        XCTAssertEqual(try outbox.totalCount(), 0)
    }

    func testFindAndUpdateStateTransitions() throws {
        _ = try outbox.enqueue(sample: makeSample(uuid: "A"), hkTypeId: heartRateID, webhookId: webhookId)
        let row = try XCTUnwrap(outbox.find(hkSampleUuid: "A"))

        try outbox.updateState(ids: [try XCTUnwrap(row.id)], to: .sent, batchId: "batch-1")

        XCTAssertEqual(try outbox.count(state: .sent), 1)
        XCTAssertEqual(try outbox.count(state: .pending), 0)
    }

    // MARK: - "Staged today" persisted tally (staged_daily_count)

    /// Deleting some staged rows (as a successful upload does since #505) must
    /// leave the "Staged today" tally at N — it counts what was staged, not what
    /// is still in the outbox. The live pending count still reflects real rows.
    func testStagedTodayTallySurvivesRowDeletion() throws {
        let staged = StagedDailyCountDAO(appDB)
        let samples = (0..<5).map { makeSample(uuid: "staged-\($0)") }

        _ = try outbox.ingest(
            samples: samples,
            hkTypeId: heartRateID,
            webhookId: webhookId,
            anchorBlob: Data([0x01])
        )
        XCTAssertEqual(try staged.count(), 5, "Tally should equal the number of samples staged today")
        XCTAssertEqual(try outbox.count(state: .pending), 5)

        // Simulate two rows being delivered and their outbox rows deleted (#505).
        let toDelete = try appDB.dbWriter.read { db in
            try OutboxRow.order(Column("id").asc).limit(2).fetchAll(db).map(\.id)
        }.compactMap { $0 }
        try appDB.dbWriter.write { db in
            _ = try OutboxRow.filter(toDelete.contains(Column("id"))).deleteAll(db)
        }

        XCTAssertEqual(try outbox.totalCount(), 3, "Outbox drains as rows are deleted")
        XCTAssertEqual(try outbox.count(state: .pending), 3, "Pending reflects live rows")
        XCTAssertEqual(try staged.count(), 5, "Staged today does NOT shrink as the queue drains")
    }

    /// Re-observed (duplicate UUID) samples are ignored and must not be tallied.
    func testStagedTodayTallyDoesNotDoubleCountDuplicates() throws {
        let staged = StagedDailyCountDAO(appDB)
        let sample = makeSample(uuid: "dupe")

        _ = try outbox.enqueue(sample: sample, hkTypeId: heartRateID, webhookId: webhookId)
        _ = try outbox.enqueue(sample: sample, hkTypeId: heartRateID, webhookId: webhookId)

        XCTAssertEqual(try outbox.totalCount(), 1, "Duplicate must not create a second row")
        XCTAssertEqual(try staged.count(), 1, "Duplicate must not be tallied twice")
    }

    /// The tally is bucketed by the enqueue instant's local day, so a new day
    /// starts back at 0 (yesterday's stages don't leak into today).
    func testStagedTodayTallyResetsAtDayBoundary() throws {
        let staged = StagedDailyCountDAO(appDB)
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!

        // Stage 3 with yesterday's enqueue time and 2 with today's.
        _ = try outbox.enqueue(
            sample: makeSample(uuid: "y1"), hkTypeId: heartRateID, webhookId: webhookId, createdAt: yesterday)
        _ = try outbox.enqueue(
            sample: makeSample(uuid: "y2"), hkTypeId: heartRateID, webhookId: webhookId, createdAt: yesterday)
        _ = try outbox.enqueue(
            sample: makeSample(uuid: "y3"), hkTypeId: heartRateID, webhookId: webhookId, createdAt: yesterday)
        _ = try outbox.enqueue(
            sample: makeSample(uuid: "t1"), hkTypeId: heartRateID, webhookId: webhookId, createdAt: now)
        _ = try outbox.enqueue(
            sample: makeSample(uuid: "t2"), hkTypeId: heartRateID, webhookId: webhookId, createdAt: now)

        XCTAssertEqual(try staged.count(on: now), 2, "Today's bucket counts only today's stages")
        XCTAssertEqual(try staged.count(on: yesterday), 3, "Yesterday's bucket is separate")
    }

    /// The destructive reset clears the tally alongside the emptied outbox.
    func testStagedTodayTallyDeleteAllResetsCounter() throws {
        let staged = StagedDailyCountDAO(appDB)
        _ = try outbox.enqueue(sample: makeSample(uuid: "r1"), hkTypeId: heartRateID, webhookId: webhookId)
        XCTAssertEqual(try staged.count(), 1)

        _ = try staged.deleteAll()

        XCTAssertEqual(try staged.count(), 0, "deleteAll wipes the tally")
    }
}
