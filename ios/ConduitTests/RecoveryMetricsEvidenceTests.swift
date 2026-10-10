import XCTest
import HealthKit
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

/// Genuine HK samples → production mapper → persisted outbox → production
/// batcher → decoded webhook JSON. No HealthKit permission or network needed.
/// This proves conversion and wire preservation, not physical Watch recording.
@MainActor
final class RecoveryMetricsEvidenceTests: XCTestCase {
    func testRecoverySamplesReachTheWebhookPayload() throws {
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
            _ = try outbox.ingest(samples: [sample], hkTypeId: reading.identifier, webhookId: webhookID, anchorBlob: Data("anchor".utf8))
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
        try writeArtifact(prettyPrint(batch.encodedJSON), named: "webhook-payload-recovery-metrics.json")
    }
}
