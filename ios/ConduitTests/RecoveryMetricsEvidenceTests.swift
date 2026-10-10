import XCTest
import HealthKit
import SwiftUI
import UIKit
@testable import Conduit

/// Independent expectations: raw literals catch registry misspellings even for
/// SDK symbols that cannot be referenced at the app's iOS 17 deployment target.
enum RecoveryMetricReadings {
    struct Reading {
        let identifier: String
        let name: String
        let category: HealthCategory
        let wireUnit: String
        let recordedValue: Double
        let recordedUnit: HKUnit
        let wireValue: Double
    }

    static let minimumIOS: [String: Int] = [
        "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD": 27,
        "HKQuantityTypeIdentifierAppleSleepingWristTemperature": 16,
        "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances": 18,
        "HKQuantityTypeIdentifierTimeInDaylight": 17,
    ]

    static func isAvailable(_ identifier: String) -> Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= minimumIOS[identifier]!
    }

    static let all: [Reading] = [
        Reading(identifier: "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD", name: "Heart Rate Variability (RMSSD)", category: .activityFitness, wireUnit: "ms", recordedValue: 0.042, recordedUnit: .second(), wireValue: 42),
        Reading(identifier: "HKQuantityTypeIdentifierAppleSleepingWristTemperature", name: "Sleeping Wrist Temperature", category: .sleepMindfulness, wireUnit: "degC", recordedValue: 94.28, recordedUnit: .degreeFahrenheit(), wireValue: 34.6),
        Reading(identifier: "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances", name: "Sleeping Breathing Disturbances", category: .sleepMindfulness, wireUnit: "count", recordedValue: 4.2, recordedUnit: .count(), wireValue: 4.2),
        Reading(identifier: "HKQuantityTypeIdentifierTimeInDaylight", name: "Time in Daylight", category: .activityFitness, wireUnit: "min", recordedValue: 5400, recordedUnit: .second(), wireValue: 90),
    ]
}

/// Constructed HK samples → production mapper → persisted outbox → production
/// batcher → decoded webhook JSON. Payload checks need no HealthKit permission
/// or network; the optional local-receiver case also exercises background upload.
/// This proves conversion and wire preservation, not physical Watch recording.
@MainActor
final class RecoveryMetricsEvidenceTests: XCTestCase {
    func testRecoveryMetricsAreSelectedInTheRenderedPicker() throws {
        let appState = makeSnapshotAppState()
        let viewModel = OnboardingViewModel(appState: appState)
        for reading in RecoveryMetricReadings.all {
            XCTAssertTrue(viewModel.enabledTypeIDs.contains(reading.identifier))
            viewModel.toggle(typeID: reading.identifier)
            XCTAssertFalse(viewModel.enabledTypeIDs.contains(reading.identifier))
            viewModel.toggle(typeID: reading.identifier)
        }

        let canvas = CGSize(width: 393, height: 852)
        let controller = UIHostingController(rootView: NavigationStack {
            DataTypePickerStepView(viewModel: viewModel)
        })
        let window = UIWindow(frame: CGRect(origin: .zero, size: canvas))
        window.overrideUserInterfaceStyle = .light
        controller.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        settle()

        try capture(controller, named: "recovery-picker-activity.png")
        let list = try XCTUnwrap(collectionView(in: controller.view))
        let sleepSection = try XCTUnwrap(HealthCategory.allCases.firstIndex(of: .sleepMindfulness)) + 1
        XCTAssertGreaterThan(list.numberOfSections, sleepSection)
        list.scrollToItem(at: IndexPath(item: 0, section: sleepSection), at: .top, animated: false)
        settle()
        try capture(controller, named: "recovery-picker-sleep.png")
    }

    /// Runs only against a local evidence receiver supplied by the test driver.
    /// This exercises the production background upload and its durable receipt.
    /// On iOS 26, use CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- so the
    /// simulator's nsurlsessiond can identify the test host's app bundle.
    func testRecoverySamplesAreDeliveredToWebhook() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["CONDUIT_EVIDENCE_WEBHOOK_URL"] else {
            throw XCTSkip("Set CONDUIT_EVIDENCE_WEBHOOK_URL to a local evidence receiver to exercise background delivery")
        }
        let (database, batch) = try makeRecoveryBatch()
        let uploader = Uploader.shared
        let previousDatabase = uploader.database
        let previousCallback = uploader.onDeliveryCommitted
        uploader.database = database
        let committed = expectation(description: "Recovery webhook delivery committed")
        uploader.onDeliveryCommitted = { committed.fulfill() }
        defer {
            uploader.database = previousDatabase
            uploader.onDeliveryCommitted = previousCallback
        }
        uploader.upload(batch: batch, webhookURL: endpoint, bearerToken: "local-recovery-evidence")
        await fulfillment(of: [committed], timeout: 30)
        let delivery = try XCTUnwrap(DeliveryLogDAO(database).latest())
        XCTAssertEqual(delivery.httpStatus, 200)
        XCTAssertEqual(delivery.accepted, batch.rowIDs.count)
        XCTAssertEqual(delivery.deduped, 0)
        XCTAssertEqual(try OutboxDAO(database).totalCount(), 0)
        XCTAssertNotNil(try SyncStateDAO(database).lastSyncedAt())
        let receipt: [String: Any] = [
            "batch_id": delivery.batchId,
            "http_status": try XCTUnwrap(delivery.httpStatus),
            "accepted": try XCTUnwrap(delivery.accepted),
            "deduped": try XCTUnwrap(delivery.deduped),
            "activity_label": try XCTUnwrap(delivery.writeOutcomeLabel),
            "outbox_remaining": try OutboxDAO(database).totalCount(),
            "last_synced_at": try XCTUnwrap(SyncStateDAO(database).lastSyncedAt()).timeIntervalSince1970,
        ]
        try writeArtifact(JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]),
                          named: "persisted-recovery-delivery.json")
    }

    func testRecoverySamplesReachTheWebhookPayload() throws {
        let (_, batch) = try makeRecoveryBatch()
        try writeArtifact(prettyPrint(batch.encodedJSON), named: "webhook-payload-recovery-metrics.json")
    }

    private func makeRecoveryBatch() throws -> (AppDatabase, Batcher.BatchResult) {
        let db = try AppDatabase.makeInMemory()
        var webhook = WebhookConfig.makeDefault(url: "https://example.com/webhook", bearerTokenKeychainRef: "evidence-token")
        try WebhookConfigDAO(db).save(&webhook)
        let webhookID = try XCTUnwrap(webhook.id)
        let outbox = OutboxDAO(db)
        let start = Date(timeIntervalSince1970: 1_788_100_000)
        let readings = RecoveryMetricReadings.all.filter { RecoveryMetricReadings.isAvailable($0.identifier) }
        XCTAssertFalse(readings.isEmpty)

        for reading in readings {
            let type = try XCTUnwrap(HealthTypeRegistry.shared.type(forIdentifier: reading.identifier))
            let hkType = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: reading.identifier)))
            XCTAssertTrue(hkType.is(compatibleWith: HKUnit(from: reading.wireUnit)), "SDK unit compatibility: \(reading.identifier)")
            let hkSample = HKQuantitySample(type: hkType, quantity: HKQuantity(unit: reading.recordedUnit, doubleValue: reading.recordedValue), start: start, end: start.addingTimeInterval(60))
            let sample = try XCTUnwrap(AnchoredReader.makeSample(from: hkSample, type: type))
            XCTAssertEqual(sample.quantity.value, reading.wireValue, accuracy: 0.0001)
            _ = try outbox.ingest(samples: [sample], hkTypeId: reading.identifier, webhookId: webhookID, anchorBlob: Data("anchor".utf8), expectedAnchorBlob: nil)
        }

        let batch = try XCTUnwrap(Batcher(database: db).buildBatch(webhookID: webhookID, limit: 500, deviceID: "recovery-evidence-device", now: start.addingTimeInterval(120)))
        let envelope = try Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON)
        XCTAssertEqual(envelope.schemaVersion, "v1")
        XCTAssertEqual(envelope.batches.count, readings.count)
        for reading in readings {
            let typeBatch = try XCTUnwrap(envelope.batches.first { $0.hkTypeID == reading.identifier })
            XCTAssertEqual(typeBatch.samples.count, 1)
            let wire = try XCTUnwrap(typeBatch.samples.first)
            XCTAssertEqual(wire.quantity.value, reading.wireValue, accuracy: 0.0001)
            XCTAssertEqual(wire.quantity.unit, reading.wireUnit)
            XCTAssertEqual(wire.startUnixMs, Int64(start.timeIntervalSince1970 * 1000))
            XCTAssertEqual(wire.endUnixMs, Int64(start.addingTimeInterval(60).timeIntervalSince1970 * 1000))
        }
        return (db, batch)
    }

    private func settle() {
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func collectionView(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        return view.subviews.compactMap { collectionView(in: $0) }.first
    }

    private func capture(_ controller: UIViewController, named name: String) throws {
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size, format: format).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        try writeArtifact(XCTUnwrap(image.pngData()), named: name)
    }
}
