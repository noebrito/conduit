import XCTest
import HealthKit
import GRDB
@testable import Conduit

/// The cycle-tracking core set, the heart-rate event threshold, and the
/// sensitive-type rules that ride with them: default off, lazy authorization,
/// and never sent to the public demo receiver.
///
/// Expectations are spelled as literals rather than read back from the
/// registry, so a wrong identifier, unit or value name fails here instead of
/// comparing the registry against itself.
enum CycleTrackingReadings {
    /// The core set, in picker order: identifier, stream, wire unit.
    static let all: [(identifier: String, stream: HealthStream, unit: String?)] = [
        ("HKCategoryTypeIdentifierMenstrualFlow", .category, nil),
        ("HKCategoryTypeIdentifierIntermenstrualBleeding", .category, nil),
        ("HKCategoryTypeIdentifierInfrequentMenstrualCycles", .category, nil),
        ("HKCategoryTypeIdentifierIrregularMenstrualCycles", .category, nil),
        ("HKCategoryTypeIdentifierPersistentIntermenstrualBleeding", .category, nil),
        ("HKCategoryTypeIdentifierProlongedMenstrualPeriods", .category, nil),
        ("HKCategoryTypeIdentifierCervicalMucusQuality", .category, nil),
        ("HKCategoryTypeIdentifierOvulationTestResult", .category, nil),
        ("HKQuantityTypeIdentifierBasalBodyTemperature", .quantity, "degC"),
    ]

    static let identifiers: Set<String> = Set(all.map(\.identifier))

    /// The higher-sensitivity reproductive types the captain kept out of scope.
    static let excluded: [String] = [
        "HKCategoryTypeIdentifierSexualActivity",
        "HKCategoryTypeIdentifierContraceptive",
        "HKCategoryTypeIdentifierPregnancy",
        "HKCategoryTypeIdentifierPregnancyTestResult",
        "HKCategoryTypeIdentifierProgesteroneTestResult",
        "HKCategoryTypeIdentifierLactation",
        "HKCategoryTypeIdentifierBleedingDuringPregnancy",
        "HKCategoryTypeIdentifierBleedingAfterPregnancy",
        "HKCategoryTypeIdentifierMenopausalState",
        "HKCategoryTypeIdentifierBleedingAfterMenopause",
    ]
}

final class CycleTrackingRegistryTests: XCTestCase {
    private let registry = HealthTypeRegistry.shared

    func testCoreSetIsRegisteredInPickerOrderAsSensitiveAndDefaultOff() throws {
        let cycleTypes = registry.types(in: .cycleTracking)
        XCTAssertEqual(cycleTypes.map(\.identifier), CycleTrackingReadings.all.map(\.identifier))
        for reading in CycleTrackingReadings.all {
            let type = try XCTUnwrap(registry.type(forIdentifier: reading.identifier), reading.identifier)
            XCTAssertEqual(type.stream, reading.stream, reading.identifier)
            XCTAssertEqual(type.defaultUnit, reading.unit, reading.identifier)
            XCTAssertEqual(type.category, .cycleTracking, reading.identifier)
            XCTAssertTrue(type.isSensitive, reading.identifier)
            XCTAssertFalse(type.defaultEnabled, reading.identifier)
            // Every core type exists at the iOS 17 deployment target.
            XCTAssertNotNil(type.sampleType, "Unresolvable HK identifier: \(reading.identifier)")
        }
        XCTAssertTrue(HealthCategory.cycleTracking.isSensitive)
    }

    func testOnlyCycleTrackingIsSensitive() {
        let sensitive = Set(registry.all.filter(\.isSensitive).map(\.identifier))
        XCTAssertEqual(sensitive, CycleTrackingReadings.identifiers)
        for category in HealthCategory.allCases where category != .cycleTracking {
            XCTAssertFalse(category.isSensitive, category.rawValue)
        }
    }

    func testHigherSensitivityReproductiveTypesAreNotRegistered() {
        for identifier in CycleTrackingReadings.excluded {
            XCTAssertNil(registry.type(forIdentifier: identifier), "\(identifier) is outside the core set")
        }
    }

    /// Sensitive types are in the full read set (so enabling one can request
    /// them) but never in the default set the launch-time re-prompt covers.
    func testDefaultReadTypesExcludeSensitiveTypes() {
        let all = Set(registry.readTypes.map(\.identifier))
        let defaults = Set(registry.defaultReadTypes.map(\.identifier))
        XCTAssertTrue(CycleTrackingReadings.identifiers.isSubset(of: all))
        XCTAssertTrue(CycleTrackingReadings.identifiers.isDisjoint(with: defaults))
        XCTAssertEqual(all.subtracting(defaults), CycleTrackingReadings.identifiers)
    }
}

// MARK: - Category value names and metadata

final class CategoryMetadataTests: XCTestCase {
    private func name(_ type: HealthDataType, _ rawValue: Int) -> String {
        AnchoredReader.categoryValueName(type: type, rawValue: rawValue)
    }

    func testCycleValueNames() {
        let table: [(HealthDataType, [Int: String])] = [
            (.menstrualFlow, [1: "unspecified", 2: "light", 3: "medium", 4: "heavy", 5: "none", 9: "value9"]),
            (.cervicalMucusQuality, [1: "dry", 2: "sticky", 3: "creamy", 4: "watery", 5: "eggWhite", 6: "value6"]),
            (.ovulationTestResult, [1: "negative", 2: "luteinizingHormoneSurge", 3: "indeterminate", 4: "estrogenSurge", 7: "value7"]),
        ]
        for (type, names) in table {
            for (rawValue, expected) in names {
                XCTAssertEqual(name(type, rawValue), expected, "\(type.identifier) \(rawValue)")
            }
        }
        for type in [HealthDataType.intermenstrualBleeding, .infrequentMenstrualCycles, .irregularMenstrualCycles,
                     .persistentIntermenstrualBleeding, .prolongedMenstrualPeriods] {
            XCTAssertEqual(name(type, 0), "notApplicable", type.identifier)
            XCTAssertEqual(name(type, 3), "value3", type.identifier)
        }
    }

    func testHeartRateEventThresholdIsCarriedForHighAndLowEventsOnly() {
        let metadata: [String: Any] = [
            HKMetadataKeyHeartRateEventThreshold: HKQuantity(unit: HKUnit(from: "count/min"), doubleValue: 120),
        ]
        for type in [HealthDataType.highHeartRateEvent, .lowHeartRateEvent] {
            let value = AnchoredReader.makeCategoryValue(type: type, rawValue: 0, metadata: metadata)
            XCTAssertTrue(value.hasHeartRateEventThresholdBpm, type.identifier)
            XCTAssertEqual(value.heartRateEventThresholdBpm, 120, accuracy: 1e-9)
            XCTAssertFalse(value.hasMenstrualCycleStart)
        }
        // Irregular rhythm events carry no threshold, even if a writer set one.
        let irregular = AnchoredReader.makeCategoryValue(type: .irregularHeartRhythmEvent, rawValue: 0, metadata: metadata)
        XCTAssertFalse(irregular.hasHeartRateEventThresholdBpm)
        XCTAssertEqual(irregular.valueName, "irregularHeartRhythmEvent")
    }

    func testHeartRateEventThresholdAbsentWhenMissingOrIncompatible() {
        let missing = AnchoredReader.makeCategoryValue(type: .highHeartRateEvent, rawValue: 0, metadata: nil)
        XCTAssertFalse(missing.hasHeartRateEventThresholdBpm)
        let wrongUnit = AnchoredReader.makeCategoryValue(
            type: .highHeartRateEvent, rawValue: 0,
            metadata: [HKMetadataKeyHeartRateEventThreshold: HKQuantity(unit: .meter(), doubleValue: 3)]
        )
        XCTAssertFalse(wrongUnit.hasHeartRateEventThresholdBpm)
        let notAQuantity = AnchoredReader.makeCategoryValue(
            type: .lowHeartRateEvent, rawValue: 0,
            metadata: [HKMetadataKeyHeartRateEventThreshold: 40]
        )
        XCTAssertFalse(notAQuantity.hasHeartRateEventThresholdBpm)
    }

    func testMenstrualCycleStartPresentAsTrueOrFalseAndAbsentOtherwise() {
        let start = AnchoredReader.makeCategoryValue(
            type: .menstrualFlow, rawValue: 3, metadata: [HKMetadataKeyMenstrualCycleStart: true]
        )
        XCTAssertTrue(start.hasMenstrualCycleStart)
        XCTAssertTrue(start.menstrualCycleStart)
        XCTAssertEqual(start.valueName, "medium")

        let notStart = AnchoredReader.makeCategoryValue(
            type: .menstrualFlow, rawValue: 2, metadata: [HKMetadataKeyMenstrualCycleStart: false]
        )
        XCTAssertTrue(notStart.hasMenstrualCycleStart, "false must be sent, not dropped")
        XCTAssertFalse(notStart.menstrualCycleStart)

        let unreported = AnchoredReader.makeCategoryValue(type: .menstrualFlow, rawValue: 2, metadata: nil)
        XCTAssertFalse(unreported.hasMenstrualCycleStart)

        // Only menstrual flow carries the key.
        let spotting = AnchoredReader.makeCategoryValue(
            type: .intermenstrualBleeding, rawValue: 0, metadata: [HKMetadataKeyMenstrualCycleStart: true]
        )
        XCTAssertFalse(spotting.hasMenstrualCycleStart)
    }

    /// End to end through a real `HKCategorySample` and the canonical JSON the
    /// receiver sees: both optional fields survive the omitted-zero rule.
    func testWireJSONCarriesBothOptionalFields() throws {
        let start = Date(timeIntervalSince1970: 1_761_000_000)
        let flow = HKCategorySample(
            type: try XCTUnwrap(HKObjectType.categoryType(forIdentifier: .menstrualFlow)),
            value: 2, start: start, end: start.addingTimeInterval(86_400),
            metadata: [HKMetadataKeyMenstrualCycleStart: false]
        )
        let event = HKCategorySample(
            type: try XCTUnwrap(HKObjectType.categoryType(forIdentifier: .highHeartRateEvent)),
            value: HKCategoryValue.notApplicable.rawValue, start: start, end: start.addingTimeInterval(600),
            metadata: [HKMetadataKeyHeartRateEventThreshold: HKQuantity(unit: HKUnit(from: "count/min"), doubleValue: 120)]
        )

        let flowJSON = try jsonObject(AnchoredReader.makeSample(from: flow, type: .menstrualFlow))
        let flowCategory = try XCTUnwrap(flowJSON["category"] as? [String: Any])
        XCTAssertEqual(flowCategory["valueName"] as? String, "light")
        XCTAssertEqual(flowCategory["menstrualCycleStart"] as? Bool, false)
        XCTAssertNil(flowCategory["heartRateEventThresholdBpm"])

        let eventJSON = try jsonObject(AnchoredReader.makeSample(from: event, type: .highHeartRateEvent))
        let eventCategory = try XCTUnwrap(eventJSON["category"] as? [String: Any])
        XCTAssertEqual(eventCategory["valueName"] as? String, "highHeartRateEvent")
        XCTAssertEqual(eventCategory["heartRateEventThresholdBpm"] as? Double, 120)
        XCTAssertNil(eventCategory["value"], "value 0 is omitted on the wire")
        XCTAssertNil(eventCategory["menstrualCycleStart"])

        try writeArtifact(
            JSONSerialization.data(withJSONObject: ["menstrualFlow": flowJSON, "highHeartRateEvent": eventJSON],
                                   options: [.prettyPrinted, .sortedKeys]),
            named: "cycle-and-heart-event-samples.json"
        )
    }

    private func jsonObject(_ sample: Conduit_V1_Sample?) throws -> [String: Any] {
        let data = try XCTUnwrap(sample).jsonUTF8Data()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - Default off, lazy authorization

final class CycleTrackingConsentTests: XCTestCase {
    private var appDB: AppDatabase!

    override func setUpWithError() throws {
        appDB = try AppDatabase.makeInMemory()
    }

    /// An existing user upgrading gets a DISABLED row for every cycle type and
    /// no permission sheet: the default signature does not grow.
    @MainActor
    func testUpgradeWritesDisabledCycleRowsAndDoesNotRePrompt() async throws {
        let appState = AppState(database: appDB)
        let dao = DataTypeConfigDAO(appDB)
        let defaults = try makeCleanDefaults()

        for type in HealthTypeRegistry.shared.all where !CycleTrackingReadings.identifiers.contains(type.identifier) {
            try dao.setEnabled(true, hkTypeId: type.identifier)
        }
        // The pre-upgrade build's signature: its whole read set, which had no
        // cycle types.
        let priorSignature = HealthTypeRegistry.shared.readTypes
            .map(\.identifier)
            .filter { !CycleTrackingReadings.identifiers.contains($0) }
            .sorted()
            .joined(separator: ",")
        defaults.set(priorSignature, forKey: AppState.authorizedSignatureKey)
        XCTAssertEqual(priorSignature, AppState.authorizedTypesSignature(),
                       "registering cycle tracking must NOT grow the re-prompt signature")

        var authorizeCalls = 0
        await appState.reconcileRegistry(registry: .shared, defaults: defaults, authorize: { _ in authorizeCalls += 1 })

        XCTAssertEqual(authorizeCalls, 0, "an update must not show a Reproductive Health sheet")
        for id in CycleTrackingReadings.identifiers {
            let row = try XCTUnwrap(try dao.find(hkTypeId: id), "no config row written for \(id)")
            XCTAssertFalse(row.enabled, "\(id) must stay off after upgrade")
        }
        XCTAssertTrue(try XCTUnwrap(dao.find(hkTypeId: HealthDataType.heartRate.identifier)).enabled)

        // A user who turned one on keeps it on across later reconciles.
        try dao.setEnabled(true, hkTypeId: HealthDataType.menstrualFlow.identifier)
        await appState.reconcileRegistry(registry: .shared, defaults: defaults, authorize: { _ in authorizeCalls += 1 })
        XCTAssertTrue(try XCTUnwrap(dao.find(hkTypeId: HealthDataType.menstrualFlow.identifier)).enabled)
        XCTAssertEqual(authorizeCalls, 0)
    }

    @MainActor
    func testOnboardingStartsWithCycleTrackingOff() {
        let viewModel = OnboardingViewModel(appState: AppState(database: appDB))
        XCTAssertTrue(viewModel.enabledTypeIDs.isDisjoint(with: CycleTrackingReadings.identifiers))
        XCTAssertTrue(viewModel.enabledTypeIDs.contains(HealthDataType.heartRate.identifier))
    }

    /// Turning a cycle type on in Settings is what asks HealthKit for it, and
    /// only the newly enabled types are requested.
    @MainActor
    func testSavingAnEnabledCycleTypeRequestsItLazily() async throws {
        let appState = AppState(database: appDB)
        try AppState.enableNewlyRegisteredTypes(dao: DataTypeConfigDAO(appDB))
        var config = WebhookConfig.makeDefault(url: "https://example.com/hook", bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(appDB).save(&config)

        var requested: [[String]] = []
        let viewModel = SettingsViewModel(appState: appState, startNewlyEnabledTypes: { types in
            requested.append(types.map(\.identifier))
        })
        viewModel.load()

        // Saving with nothing newly enabled requests nothing.
        try viewModel.save()
        XCTAssertNil(viewModel.enableTask)

        viewModel.toggleType(HealthDataType.menstrualFlow.identifier)
        viewModel.toggleType(HealthDataType.basalBodyTemperature.identifier)
        try viewModel.save()
        await viewModel.enableTask?.value
        XCTAssertEqual(requested, [[HealthDataType.menstrualFlow.identifier, HealthDataType.basalBodyTemperature.identifier]])
        XCTAssertTrue(try XCTUnwrap(DataTypeConfigDAO(appDB).find(hkTypeId: HealthDataType.menstrualFlow.identifier)).enabled)

        // Already enabled: a later save does not ask again.
        let firstTask = viewModel.enableTask
        try viewModel.save()
        XCTAssertTrue(viewModel.enableTask == firstTask)
        XCTAssertEqual(requested.count, 1)
    }

    private func makeCleanDefaults() throws -> UserDefaults {
        let suite = "conduit.cycle.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}

// MARK: - Public demo receiver

final class DemoReceiverTests: XCTestCase {
    private var db: AppDatabase!

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
    }

    func testMatchesTheDemoReceiverOnly() {
        for url in [
            "https://health.noebrito.dev/webhook-test",
            "https://health.noebrito.dev/webhook-test/",
            "https://HEALTH.noebrito.dev/webhook-test?x=1",
            "https://health.noebrito.dev./webhook-test",
            "  https://health.noebrito.dev/webhook-test#top ",
            "http://health.noebrito.dev/webhook-test/abc",
            "https://health.noebrito.dev:443/Webhook-Test",
        ] {
            XCTAssertTrue(DemoReceiver.matches(url), url)
        }
        for url in [
            "https://health.noebrito.dev/webhook",
            "https://health.noebrito.dev/webhook-tests",
            "https://example.com/webhook-test",
            "https://health.noebrito.dev.example.com/webhook-test",
            "https://example.com/?next=https://health.noebrito.dev/webhook-test",
            "",
            "not a url",
        ] {
            XCTAssertFalse(DemoReceiver.matches(url), url)
        }
    }

    func testBlockedTypesAreTheSensitiveSetForTheDemoReceiverOnly() {
        XCTAssertEqual(DemoReceiver.blockedTypeIDs(forURL: "https://health.noebrito.dev/webhook-test"),
                       CycleTrackingReadings.identifiers)
        XCTAssertTrue(DemoReceiver.blockedTypeIDs(forURL: "https://example.com/hook").isEmpty)
    }

    /// Rows already staged for the user's own receiver are held, not sent and
    /// not dropped, while the destination is the demo receiver.
    func testBatcherHoldsExcludedTypesPending() throws {
        var webhook = WebhookConfig.makeDefault(url: "https://example.com/hook", bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(db).save(&webhook)
        let webhookID = try XCTUnwrap(webhook.id)
        try OutboxDAO(db).enqueue(sample: categorySample(uuid: "flow-1"), hkTypeId: HealthDataType.menstrualFlow.identifier, webhookId: webhookID)
        try OutboxDAO(db).enqueue(sample: categorySample(uuid: "sleep-1"), hkTypeId: HealthDataType.sleepAnalysis.identifier, webhookId: webhookID)

        let batcher = Batcher(database: db)
        let first = try XCTUnwrap(batcher.buildBatch(
            webhookID: webhookID, limit: 100, deviceID: "dev",
            excludingTypeIDs: DemoReceiver.blockedTypeIDs(forURL: "https://health.noebrito.dev/webhook-test")
        ))
        let firstEnvelope = try Conduit_V1_Envelope(jsonUTF8Data: first.encodedJSON)
        XCTAssertEqual(firstEnvelope.batches.map(\.hkTypeID), [HealthDataType.sleepAnalysis.identifier])
        XCTAssertNil(try batcher.buildBatch(
            webhookID: webhookID, limit: 100, deviceID: "dev",
            excludingTypeIDs: DemoReceiver.blockedTypeIDs(forURL: "https://health.noebrito.dev/webhook-test")
        ), "the held row must not leak into a later batch")
        XCTAssertEqual(try OutboxDAO(db).count(state: .pending), 1)

        // Once the destination is the user's own receiver, it drains.
        let second = try XCTUnwrap(batcher.buildBatch(webhookID: webhookID, limit: 100, deviceID: "dev"))
        let secondEnvelope = try Conduit_V1_Envelope(jsonUTF8Data: second.encodedJSON)
        XCTAssertEqual(secondEnvelope.batches.map(\.hkTypeID), [HealthDataType.menstrualFlow.identifier])
    }

    /// An enabled cycle type is never even read (so nothing is staged and its
    /// anchor stays put) while the destination is the demo receiver.
    func testObserverWakeDoesNotReadSensitiveTypesForTheDemoReceiver() async throws {
        let reads = ReadLog()
        let engine = try makeEngine(url: "https://health.noebrito.dev/webhook-test", reads: reads)
        await engine.handleObserverWake(typeIdentifier: HealthDataType.menstrualFlow.identifier)
        await engine.handleObserverWake(typeIdentifier: HealthDataType.sleepAnalysis.identifier)
        XCTAssertEqual(reads.identifiers, [HealthDataType.sleepAnalysis.identifier])
        XCTAssertNil(try XCTUnwrap(DataTypeConfigDAO(db).find(hkTypeId: HealthDataType.menstrualFlow.identifier)).captureStartedAt,
                     "a refused type must not seed its capture floor")
    }

    func testObserverWakeReadsSensitiveTypesForTheUsersOwnReceiver() async throws {
        let reads = ReadLog()
        let engine = try makeEngine(url: "https://example.com/hook", reads: reads)
        await engine.handleObserverWake(typeIdentifier: HealthDataType.menstrualFlow.identifier)
        XCTAssertEqual(reads.identifiers, [HealthDataType.menstrualFlow.identifier])
    }

    func testImportFailsInsteadOfClaimingSensitiveHistoryForTheDemoReceiver() async throws {
        let engine = try makeEngine(url: "https://health.noebrito.dev/webhook-test", reads: ReadLog())
        do {
            _ = try await engine.importHistory(typeIdentifier: HealthDataType.menstrualFlow.identifier, since: nil)
            XCTFail("importing a sensitive type to the demo receiver must throw")
        } catch ImportError.sensitiveTypeBlockedForDemoReceiver {
            XCTAssertEqual(ImportError.sensitiveTypeBlockedForDemoReceiver.errorDescription, DemoReceiver.refusalMessage)
        }
    }

    @MainActor
    func testSettingsExplainsTheRefusalOnlyWhenItApplies() throws {
        let viewModel = SettingsViewModel(appState: AppState(database: db), startNewlyEnabledTypes: { _ in })
        viewModel.webhookURL = "https://health.noebrito.dev/webhook-test"
        viewModel.enabledTypeIDs = [HealthDataType.heartRate.identifier]
        XCTAssertFalse(viewModel.sensitiveTypesBlockedByDemoReceiver)
        XCTAssertFalse(viewModel.hasSensitiveTypesEnabled)
        viewModel.enabledTypeIDs.insert(HealthDataType.ovulationTestResult.identifier)
        XCTAssertTrue(viewModel.sensitiveTypesBlockedByDemoReceiver)
        XCTAssertTrue(viewModel.hasSensitiveTypesEnabled)
        viewModel.webhookURL = "https://example.com/hook"
        XCTAssertFalse(viewModel.sensitiveTypesBlockedByDemoReceiver)
    }

    // MARK: - Helpers

    private final class ReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _identifiers: [String] = []
        var identifiers: [String] { lock.withLock { _identifiers } }
        func record(_ identifier: String) { lock.withLock { _identifiers.append(identifier) } }
    }

    private func makeEngine(url: String, reads: ReadLog) throws -> SyncEngine {
        var webhook = WebhookConfig.makeDefault(url: url, bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(db).save(&webhook)
        try DataTypeConfigDAO(db).setEnabled(true, hkTypeId: HealthDataType.menstrualFlow.identifier)
        try DataTypeConfigDAO(db).setEnabled(true, hkTypeId: HealthDataType.sleepAnalysis.identifier)
        return SyncEngine(
            database: db,
            readAnchored: { type, anchor, _, _, _ in
                reads.record(type.identifier)
                return AnchoredReader.Result(samples: [], deletedUuids: [], newAnchor: anchor)
            },
            bearerToken: { nil },
            submitUpload: { _, _, _ in XCTFail("nothing should upload"); return false }
        )
    }

    private func categorySample(uuid: String) -> Conduit_V1_Sample {
        var sample = Conduit_V1_Sample()
        sample.uuid = uuid
        sample.startUnixMs = 1_000
        sample.endUnixMs = 2_000
        var value = Conduit_V1_CategoryValue()
        value.value = 2
        value.valueName = "light"
        sample.category = value
        return sample
    }
}
