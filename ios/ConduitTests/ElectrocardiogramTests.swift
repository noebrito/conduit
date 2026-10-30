import XCTest
import HealthKit
import SwiftUI
@testable import Conduit

/// Apple Watch ECG recordings as an `electrocardiogram` summary: classification,
/// average heart rate, symptoms status, sampling details. Never the waveform.
///
/// `HKElectrocardiogram` has no public initializer, so nothing here is a real
/// recording: the mapping is tested through the pure
/// `AnchoredReader.makeElectrocardiogramValue` core, and the wire test proves the
/// shape a receiver gets, not that a Watch produced it. Expectations are
/// literals, so a wrong identifier or name fails here instead of comparing the
/// code against itself.
enum ElectrocardiogramReadings {
    static let identifier = "HKDataTypeIdentifierElectrocardiogram"

    static let classificationNames: [(HKElectrocardiogram.Classification, String)] = [
        (.notSet, "notSet"),
        (.sinusRhythm, "sinusRhythm"),
        (.atrialFibrillation, "atrialFibrillation"),
        (.inconclusiveLowHeartRate, "inconclusiveLowHeartRate"),
        (.inconclusiveHighHeartRate, "inconclusiveHighHeartRate"),
        (.inconclusivePoorReading, "inconclusivePoorReading"),
        (.inconclusiveOther, "inconclusiveOther"),
        (.unrecognized, "unrecognized"),
    ]

    static let symptomsStatusNames: [(HKElectrocardiogram.SymptomsStatus, String)] = [
        (.notSet, "notSet"),
        (.none, "none"),
        (.present, "present"),
    ]
}

final class ElectrocardiogramRegistryTests: XCTestCase {
    private let registry = HealthTypeRegistry.shared

    func testRegisteredInHeartEventsAsItsOwnStream() throws {
        let type = try XCTUnwrap(registry.type(forIdentifier: ElectrocardiogramReadings.identifier))
        XCTAssertEqual(type.stream, .electrocardiogram)
        XCTAssertNil(type.defaultUnit)
        XCTAssertEqual(type.category, .heartEvents)
        XCTAssertEqual(registry.types(in: .heartEvents).last?.identifier, ElectrocardiogramReadings.identifier)
        XCTAssertFalse(type.isSensitive)
        XCTAssertTrue(type.defaultEnabled, "ECG is on by default")
    }

    /// HealthKit exports no constant for the ECG identifier, so the registry
    /// spells it as a literal; it must be exactly the SDK type's identifier.
    func testIdentifierResolvesToTheElectrocardiogramType() throws {
        let type = try XCTUnwrap(registry.type(forIdentifier: ElectrocardiogramReadings.identifier))
        XCTAssertEqual(HKObjectType.electrocardiogramType().identifier, ElectrocardiogramReadings.identifier)
        XCTAssertEqual(type.sampleType, HKObjectType.electrocardiogramType())
        XCTAssertEqual(type.authorizationTypes, [HKObjectType.electrocardiogramType()])
    }

    func testInBothReadSets() {
        let ecg: HKObjectType = HKObjectType.electrocardiogramType()
        XCTAssertTrue(registry.readTypes.contains(ecg))
        XCTAssertTrue(registry.defaultReadTypes.contains(ecg), "default on, so it rides the launch-time signature")
        XCTAssertTrue(AppState.authorizedTypesSignature().split(separator: ",").contains(Substring(ElectrocardiogramReadings.identifier)))
    }
}

final class ElectrocardiogramMappingTests: XCTestCase {
    private let bpm = HKUnit(from: "count/min")

    func testEveryClassificationName() {
        for (classification, name) in ElectrocardiogramReadings.classificationNames {
            XCTAssertEqual(map(classification: classification).classification, name)
        }
    }

    func testEverySymptomsStatusName() {
        for (status, name) in ElectrocardiogramReadings.symptomsStatusNames {
            XCTAssertEqual(map(symptomsStatus: status).symptomsStatus, name)
        }
    }

    /// A case a future OS adds keeps a stable, unambiguous value.
    func testUnknownClassificationAndSymptomsStatusFallBackToTheRawValue() throws {
        let classification = try XCTUnwrap(HKElectrocardiogram.Classification(rawValue: 42))
        let status = try XCTUnwrap(HKElectrocardiogram.SymptomsStatus(rawValue: 9))
        let value = map(classification: classification, symptomsStatus: status)
        XCTAssertEqual(value.classification, "classification42")
        XCTAssertEqual(value.symptomsStatus, "symptomsStatus9")
    }

    func testFullRecordingCarriesEveryField() {
        let value = AnchoredReader.makeElectrocardiogramValue(
            classification: .sinusRhythm,
            averageHeartRate: HKQuantity(unit: bpm, doubleValue: 68),
            symptomsStatus: .none,
            samplingFrequency: HKQuantity(unit: .hertz(), doubleValue: 512),
            numberOfVoltageMeasurements: 15_360,
            metadata: [HKMetadataKeyAppleECGAlgorithmVersion: 2]
        )
        XCTAssertEqual(value.classification, "sinusRhythm")
        XCTAssertTrue(value.hasAverageHeartRateBpm)
        XCTAssertEqual(value.averageHeartRateBpm, 68, accuracy: 0.0001)
        XCTAssertEqual(value.symptomsStatus, "none")
        XCTAssertTrue(value.hasSamplingFrequencyHz)
        XCTAssertEqual(value.samplingFrequencyHz, 512, accuracy: 0.0001)
        XCTAssertEqual(value.numberOfVoltageMeasurements, 15_360)
        XCTAssertTrue(value.hasAppleEcgAlgorithmVersion)
        XCTAssertEqual(value.appleEcgAlgorithmVersion, 2)
    }

    /// An inconclusive reading often has no average heart rate: it must be
    /// absent, never a fabricated 0. Same for the other optional fields.
    func testAbsentAverageHeartRateStaysAbsent() {
        let value = map(classification: .inconclusivePoorReading)
        XCTAssertFalse(value.hasAverageHeartRateBpm)
        XCTAssertFalse(value.hasSamplingFrequencyHz)
        XCTAssertFalse(value.hasAppleEcgAlgorithmVersion)
    }

    func testAverageHeartRateIsConvertedToBeatsPerMinute() {
        let value = map(averageHeartRate: HKQuantity(unit: HKUnit.count().unitDivided(by: .second()), doubleValue: 1.2))
        XCTAssertEqual(value.averageHeartRateBpm, 72, accuracy: 0.0001)
    }

    func testIncompatibleQuantitiesAreDroppedRatherThanTrapping() {
        let value = map(
            averageHeartRate: HKQuantity(unit: .meter(), doubleValue: 68),
            samplingFrequency: HKQuantity(unit: .meter(), doubleValue: 512)
        )
        XCTAssertFalse(value.hasAverageHeartRateBpm)
        XCTAssertFalse(value.hasSamplingFrequencyHz)
    }

    func testAlgorithmVersionIgnoresAWrongTypedValue() {
        XCTAssertFalse(map(metadata: [HKMetadataKeyAppleECGAlgorithmVersion: "2"]).hasAppleEcgAlgorithmVersion)
    }

    private func map(
        classification: HKElectrocardiogram.Classification = .sinusRhythm,
        averageHeartRate: HKQuantity? = nil,
        symptomsStatus: HKElectrocardiogram.SymptomsStatus = .notSet,
        samplingFrequency: HKQuantity? = nil,
        metadata: [String: Any]? = nil
    ) -> Conduit_V1_ElectrocardiogramValue {
        AnchoredReader.makeElectrocardiogramValue(
            classification: classification,
            averageHeartRate: averageHeartRate,
            symptomsStatus: symptomsStatus,
            samplingFrequency: samplingFrequency,
            numberOfVoltageMeasurements: 15_360,
            metadata: metadata
        )
    }
}

/// Synthetic ECG samples → persisted outbox → production batcher → decoded
/// webhook JSON. Proves the wire shape a receiver sees, not a Watch recording.
final class ElectrocardiogramEvidenceTests: XCTestCase {
    func testElectrocardiogramSamplesReachTheWebhookPayload() throws {
        let db = try AppDatabase.makeInMemory()
        var webhook = WebhookConfig.makeDefault(url: "https://example.com/webhook", bearerTokenKeychainRef: "evidence-token")
        try WebhookConfigDAO(db).save(&webhook)
        let webhookID = try XCTUnwrap(webhook.id)
        let start = Date(timeIntervalSince1970: 1_788_100_000)

        let sinus = makeSample(start: start, value: AnchoredReader.makeElectrocardiogramValue(
            classification: .sinusRhythm,
            averageHeartRate: HKQuantity(unit: HKUnit(from: "count/min"), doubleValue: 68),
            symptomsStatus: .none,
            samplingFrequency: HKQuantity(unit: .hertz(), doubleValue: 512),
            numberOfVoltageMeasurements: 15_360,
            metadata: [HKMetadataKeyAppleECGAlgorithmVersion: 2]
        ))
        let inconclusive = makeSample(start: start.addingTimeInterval(600), value: AnchoredReader.makeElectrocardiogramValue(
            classification: .inconclusivePoorReading,
            averageHeartRate: nil,
            symptomsStatus: .notSet,
            samplingFrequency: HKQuantity(unit: .hertz(), doubleValue: 512),
            numberOfVoltageMeasurements: 15_360,
            metadata: [HKMetadataKeyAppleECGAlgorithmVersion: 2]
        ))
        _ = try OutboxDAO(db).ingest(samples: [sinus, inconclusive], hkTypeId: ElectrocardiogramReadings.identifier, webhookId: webhookID, anchorBlob: Data("anchor".utf8), expectedAnchorBlob: nil, expectedIngestRevision: 0)

        let batch = try XCTUnwrap(Batcher(database: db).buildBatch(webhookID: webhookID, limit: 500, deviceID: "ecg-evidence-device", now: start.addingTimeInterval(1_200)))
        let envelope = try Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON)
        XCTAssertEqual(envelope.batches.map(\.hkTypeID), [ElectrocardiogramReadings.identifier])

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: batch.encodedJSON) as? [String: Any])
        let typeBatch = try XCTUnwrap((json["batches"] as? [[String: Any]])?.first)
        let samples = try XCTUnwrap(typeBatch["samples"] as? [[String: Any]])
        let byUUID = Dictionary(uniqueKeysWithValues: samples.map { ($0["uuid"] as? String ?? "", $0) })

        let sinusWire = try XCTUnwrap(byUUID[sinus.uuid])
        XCTAssertEqual(sinusWire["startUnixMs"] as? String, String(sinus.startUnixMs))
        XCTAssertEqual(sinusWire["endUnixMs"] as? String, String(sinus.endUnixMs))
        let sinusECG = try XCTUnwrap(sinusWire["electrocardiogram"] as? [String: Any])
        XCTAssertEqual(sinusECG["classification"] as? String, "sinusRhythm")
        XCTAssertEqual(sinusECG["averageHeartRateBpm"] as? Double, 68)
        XCTAssertEqual(sinusECG["symptomsStatus"] as? String, "none")
        XCTAssertEqual(sinusECG["samplingFrequencyHz"] as? Double, 512)
        XCTAssertEqual(sinusECG["numberOfVoltageMeasurements"] as? Int, 15_360)
        XCTAssertEqual(sinusECG["appleEcgAlgorithmVersion"] as? Int, 2)
        for other in ["quantity", "category", "workout", "correlation", "route", "medicationDose"] {
            XCTAssertNil(sinusWire[other], "exactly one value shape per sample")
        }

        let inconclusiveECG = try XCTUnwrap(byUUID[inconclusive.uuid]?["electrocardiogram"] as? [String: Any])
        XCTAssertEqual(inconclusiveECG["classification"] as? String, "inconclusivePoorReading")
        XCTAssertNil(inconclusiveECG["averageHeartRateBpm"], "absent, not 0, when HealthKit has none")

        try writeArtifact(prettyPrint(batch.encodedJSON), named: "webhook-payload-electrocardiogram.json")
    }

    private func makeSample(start: Date, value: Conduit_V1_ElectrocardiogramValue) -> Conduit_V1_Sample {
        var sample = Conduit_V1_Sample()
        sample.uuid = UUID().uuidString
        sample.startUnixMs = AnchoredReader.unixMillis(start)
        sample.endUnixMs = AnchoredReader.unixMillis(start.addingTimeInterval(30))
        sample.source.name = "Apple Watch"
        sample.source.bundleID = "com.apple.health"
        sample.source.productType = "Watch7,1"
        sample.electrocardiogram = value
        return sample
    }
}

/// Opt-in capture (`CONDUIT_EVIDENCE_DIR`) of the Settings Heart Events picker
/// with the ECG row, light and dark, over an in-memory fixture.
@MainActor
final class ElectrocardiogramScreenEvidenceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUIT_EVIDENCE_DIR"] != nil)
    }

    func testSettingsHeartEventsPicker() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let viewModel = SettingsViewModel(appState: makeSnapshotAppState(), startNewlyEnabledTypes: { _ in })
            viewModel.enabledTypeIDs = Set(HealthTypeRegistry.shared.all.filter(\.defaultEnabled).map(\.identifier))
            let view = NavigationStack { DataTypesCategoryView(category: .heartEvents, viewModel: viewModel) }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let host = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = style
            host.overrideUserInterfaceStyle = style
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let name = style == .dark ? "dark" : "light"
            try writeArtifact(try XCTUnwrap(image.pngData()), named: "settings-heart-events-ecg-\(name).png")
        }
    }
}
