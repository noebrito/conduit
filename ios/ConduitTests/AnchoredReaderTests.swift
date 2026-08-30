import XCTest
import GRDB
@testable import Conduit

/// Tests for the HealthKit-deletion honoring path at the seam we can exercise
/// without a live `HKHealthStore`.
///
/// The one piece that genuinely needs HealthKit — mapping the anchored query's
/// `[HKDeletedObject]` into `Result.deletedUuids` — is untestable in a unit test
/// (`HKDeletedObject` has no public initializer, and ConduitTests never touch
/// live HealthKit). So these tests pin the observable contract instead: a
/// `Result` carries deleted uuids, and those uuids flow end-to-end through
/// `OutboxDAO.ingest` → `Batcher` into the envelope's `deleted_uuids`, which is
/// what actually reaches the ingester.
final class AnchoredReaderTests: XCTestCase {
    private var db: AppDatabase!
    private var webhookID: Int64!
    private let heartRateID = HealthDataType.heartRate.identifier

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        var wh = WebhookConfig.makeDefault(url: "https://example.com/hook", bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(db).save(&wh)
        webhookID = try XCTUnwrap(wh.id)
    }

    private func makeSample(uuid: String) -> Conduit_V1_Sample {
        var s = Conduit_V1_Sample()
        s.uuid = uuid
        s.startUnixMs = 1_000
        s.endUnixMs = 2_000
        var q = Conduit_V1_QuantityValue(); q.value = 60; q.unit = "count/min"
        s.quantity = q
        return s
    }

    /// A `Result` surfaces deleted uuids alongside its samples — the field the
    /// anchored query now populates from `deletedObjects`.
    func testResultCarriesDeletedUuids() {
        let result = AnchoredReader.Result(
            samples: [makeSample(uuid: "live")],
            deletedUuids: ["ghost-a", "ghost-b"],
            newAnchor: nil
        )
        XCTAssertEqual(result.deletedUuids, ["ghost-a", "ghost-b"])
        XCTAssertEqual(result.samples.map(\.uuid), ["live"])
    }

    /// The deletion surfaces end-to-end: staging a `Result`'s deletedUuids via
    /// `ingest`, then batching, yields an envelope whose `deleted_uuids` carries
    /// the ghost — exactly what the ingester turns into a bulk delete.
    func testDeletionFlowsThroughIngestAndBatchIntoEnvelope() throws {
        let result = AnchoredReader.Result(
            samples: [makeSample(uuid: "fat-new")],
            deletedUuids: ["fat-ghost"],
            newAnchor: nil
        )

        let outbox = OutboxDAO(db)
        _ = try outbox.ingest(
            samples: result.samples,
            hkTypeId: heartRateID,
            webhookId: webhookID,
            anchorBlob: Data([0x01]),
            deletedUuids: result.deletedUuids
        )

        let batch = try XCTUnwrap(
            Batcher(database: db).buildBatch(webhookID: webhookID, limit: 100, deviceID: "dev-1")
        )
        let envelope = try Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON)
        let typeBatch = try XCTUnwrap(envelope.batches.first { $0.hkTypeID == heartRateID })
        XCTAssertEqual(typeBatch.samples.map(\.uuid), ["fat-new"])
        XCTAssertEqual(typeBatch.deletedUuids, ["fat-ghost"])
    }

    /// No deletions ⇒ an empty `deletedUuids`, and the staged/batched output is
    /// exactly what it was before the feature existed (no tombstone rows, empty
    /// deleted_uuids). Guards the additive contract at the iOS seam.
    func testNoDeletionsLeavesEnvelopeUnchanged() throws {
        let outbox = OutboxDAO(db)
        _ = try outbox.ingest(
            samples: [makeSample(uuid: "s1")],
            hkTypeId: heartRateID,
            webhookId: webhookID,
            anchorBlob: Data([0x01]),
            deletedUuids: []
        )
        XCTAssertEqual(try outbox.totalCount(), 1, "no tombstone rows when there are no deletions")

        let batch = try XCTUnwrap(
            Batcher(database: db).buildBatch(webhookID: webhookID, limit: 100, deviceID: "dev-1")
        )
        let envelope = try Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON)
        XCTAssertTrue(envelope.batches.allSatisfy { $0.deletedUuids.isEmpty })
    }
}
