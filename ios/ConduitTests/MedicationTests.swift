import XCTest
import HealthKit
import SwiftUI
@testable import Conduit

/// Medication doses (iOS 26+) as a `medicationDose` sample: the medication's
/// name and general form, the schedule, and every log status.
///
/// `HKMedicationDoseEvent` and `HKUserAnnotatedMedication` have no public
/// initializer, so nothing here is a real dose: the mapping is tested through
/// the pure `AnchoredReader.makeMedicationDoseValue` core, and the wire test
/// proves the shape a receiver gets, not that the Health app produced it. The
/// per-medication sheet, delete-and-recreate on a status change, background
/// delivery and un-sharing are device checks. Expectations are literals, so a
/// wrong identifier or name fails here instead of comparing the code against
/// itself.
enum MedicationReadings {
    static let identifier = "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent"

    /// Gate on the OS version, never on `sampleType == nil` (see
    /// `testEveryIdentifierResolvesToAnHKSampleType`).
    static var isAvailableOnThisOS: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    @available(iOS 26.0, *)
    static var logStatusNames: [(HKMedicationDoseEvent.LogStatus, String)] {
        [
            (.notInteracted, "notInteracted"),
            (.notificationNotSent, "notificationNotSent"),
            (.snoozed, "snoozed"),
            (.taken, "taken"),
            (.skipped, "skipped"),
            (.notLogged, "notLogged"),
        ]
    }

    @available(iOS 26.0, *)
    static var scheduleTypeNames: [(HKMedicationDoseEvent.ScheduleType, String)] {
        [(.asNeeded, "asNeeded"), (.schedule, "schedule")]
    }

    @available(iOS 26.0, *)
    static var generalFormNames: [(HKMedicationGeneralForm, String)] {
        [
            (.capsule, "capsule"), (.cream, "cream"), (.device, "device"), (.drops, "drops"),
            (.foam, "foam"), (.gel, "gel"), (.inhaler, "inhaler"), (.injection, "injection"),
            (.liquid, "liquid"), (.lotion, "lotion"), (.ointment, "ointment"), (.patch, "patch"),
            (.powder, "powder"), (.spray, "spray"), (.suppository, "suppository"), (.tablet, "tablet"),
            (.topical, "topical"), (.unknown, "unknown"),
        ]
    }

    static func skipUnlessAvailable() throws {
        try XCTSkipUnless(isAvailableOnThisOS, "The Medications API needs iOS 26 or later")
    }
}

final class MedicationRegistryTests: XCTestCase {
    private let registry = HealthTypeRegistry.shared

    func testRegisteredInItsOwnSensitiveGroupAndDefaultOff() throws {
        let type = try XCTUnwrap(registry.type(forIdentifier: MedicationReadings.identifier))
        XCTAssertEqual(type.stream, .medicationDose)
        XCTAssertNil(type.defaultUnit)
        XCTAssertEqual(type.category, .medications)
        XCTAssertEqual(registry.types(in: .medications).map(\.identifier), [MedicationReadings.identifier])
        XCTAssertEqual(registry.medicationDose?.identifier, MedicationReadings.identifier)
        XCTAssertTrue(type.isSensitive)
        XCTAssertFalse(type.defaultEnabled, "medications stay off until the user picks some")
        XCTAssertTrue(HealthCategory.medications.isSensitive)
        XCTAssertEqual(HealthCategory.allCases.last, .medications)
    }

    /// HealthKit exports no constant for the identifier usable at the iOS 17
    /// target, so the registry spells it as a literal; it must be exactly the
    /// SDK type's identifier, and resolve only on iOS 26+.
    func testSampleTypeResolvesOnlyOnIOS26AndLater() throws {
        let type = try XCTUnwrap(registry.type(forIdentifier: MedicationReadings.identifier))
        if #available(iOS 26.0, *) {
            XCTAssertTrue(MedicationReadings.isAvailableOnThisOS)
            XCTAssertEqual(HKObjectType.medicationDoseEventType().identifier, MedicationReadings.identifier)
            XCTAssertEqual(type.sampleType, HKObjectType.medicationDoseEventType())
            XCTAssertTrue(type.isAvailableOnThisOS)
        } else {
            XCTAssertNil(type.sampleType)
            XCTAssertFalse(type.isAvailableOnThisOS)
        }
    }

    /// The normal permission request must never carry it (it would raise and
    /// kill onboarding), and adding the entry must not change what the
    /// launch-time re-prompt covers.
    func testNeverPartOfTheNormalPermissionRequest() throws {
        let type = try XCTUnwrap(registry.type(forIdentifier: MedicationReadings.identifier))
        XCTAssertEqual(type.authorizationTypes, [])
        let withoutMedication = registry.all.filter { $0.identifier != MedicationReadings.identifier }
        XCTAssertEqual(registry.readTypes, Set(withoutMedication.flatMap(\.authorizationTypes)))
        XCTAssertFalse(registry.defaultReadTypes.map(\.identifier).contains(MedicationReadings.identifier))
        XCTAssertFalse(AppState.authorizedTypesSignature().split(separator: ",").contains(Substring(MedicationReadings.identifier)))
    }

    /// The iOS 27 limited-history probe asks about the dose-event sample type,
    /// so a limited grant is not hidden behind the empty `authorizationTypes`.
    func testHistoryProbeAsksAboutTheDoseEventType() throws {
        try MedicationReadings.skipUnlessAvailable()
        guard #available(iOS 26.0, *) else { return }
        let doseType: HKObjectType = HKObjectType.medicationDoseEventType()
        XCTAssertEqual(HealthDataType.medicationDose.probeTypes, [doseType])
        XCTAssertEqual(HealthDataType.bloodPressure.probeTypes, HealthDataType.bloodPressure.authorizationTypes)
        let floor = Date(timeIntervalSince1970: 1_790_000_000)
        let floors = HealthKitHistoryAccessProbe.floors(for: [.medicationDose], from: [doseType: floor])
        XCTAssertEqual(floors[MedicationReadings.identifier], floor)
    }

    func testHeldBackFromTheDemoReceiver() {
        XCTAssertTrue(DemoReceiver.blockedTypeIDs(forURL: "https://health.noebrito.dev/webhook-test").contains(MedicationReadings.identifier))
        XCTAssertFalse(DemoReceiver.blockedTypeIDs(forURL: "https://example.com/hook").contains(MedicationReadings.identifier))
        XCTAssertTrue(DemoReceiver.refusalMessage.contains("Medications"))
    }

    func testConsentFooterOnlyForSensitiveGroups() throws {
        for category in HealthCategory.allCases {
            XCTAssertEqual(DemoReceiver.consentFooter(for: category) != nil, category.isSensitive, category.rawValue)
        }
        let footer = try XCTUnwrap(DemoReceiver.consentFooter(for: .medications))
        XCTAssertTrue(footer.contains("choose medications to share"))
        // It names everything a dose carries: every log status, the schedule
        // type and due time, and the amount (`MedicationDoseValue`).
        for detail in ["name and form", "scheduled or as-needed", "when it was due", "the amount",
                       "took, skipped, or snoozed", "left the reminder unanswered"] {
            XCTAssertTrue(footer.contains(detail), detail)
        }
        XCTAssertFalse(footer.contains("nickname"))
        XCTAssertTrue(footer.hasSuffix("never to the public demo receiver."))
    }
}

final class MedicationMappingTests: XCTestCase {
    override func setUpWithError() throws {
        try MedicationReadings.skipUnlessAvailable()
    }

    func testEveryLogStatusName() throws {
        guard #available(iOS 26.0, *) else { return }
        for (status, name) in MedicationReadings.logStatusNames {
            XCTAssertEqual(map(logStatus: status).logStatus, name)
        }
    }

    func testEveryScheduleTypeName() throws {
        guard #available(iOS 26.0, *) else { return }
        for (scheduleType, name) in MedicationReadings.scheduleTypeNames {
            XCTAssertEqual(map(scheduleType: scheduleType).scheduleType, name)
        }
    }

    func testEveryGeneralFormName() throws {
        guard #available(iOS 26.0, *) else { return }
        for (form, name) in MedicationReadings.generalFormNames {
            XCTAssertEqual(AnchoredReader.medicationGeneralFormName(form), name)
        }
        XCTAssertEqual(AnchoredReader.medicationGeneralFormName(HKMedicationGeneralForm(rawValue: "sachet")), "sachet")
    }

    /// A case a future OS adds keeps a stable, unambiguous value.
    func testUnknownLogStatusAndScheduleTypeFallBackToTheRawValue() throws {
        guard #available(iOS 26.0, *) else { return }
        let status = try XCTUnwrap(HKMedicationDoseEvent.LogStatus(rawValue: 42))
        let scheduleType = try XCTUnwrap(HKMedicationDoseEvent.ScheduleType(rawValue: 9))
        let value = map(scheduleType: scheduleType, logStatus: status)
        XCTAssertEqual(value.logStatus, "logStatus42")
        XCTAssertEqual(value.scheduleType, "scheduleType9")
    }

    func testScheduledDoseTakenCarriesEveryField() throws {
        guard #available(iOS 26.0, *) else { return }
        let scheduled = Date(timeIntervalSince1970: 1_756_656_000)
        let value = AnchoredReader.makeMedicationDoseValue(
            medication: MedicationIdentity(name: "Lisinopril 10 mg", generalForm: "tablet"),
            scheduleType: .schedule,
            logStatus: .taken,
            scheduledDate: scheduled,
            scheduledDoseQuantity: 1,
            doseQuantity: 1,
            unit: .count()
        )
        XCTAssertEqual(value.medicationName, "Lisinopril 10 mg")
        XCTAssertEqual(value.generalForm, "tablet")
        XCTAssertEqual(value.scheduleType, "schedule")
        XCTAssertEqual(value.logStatus, "taken")
        XCTAssertTrue(value.hasScheduledUnixMs)
        XCTAssertEqual(value.scheduledUnixMs, 1_756_656_000_000)
        XCTAssertTrue(value.hasScheduledDoseQuantity)
        XCTAssertEqual(value.scheduledDoseQuantity, 1)
        XCTAssertTrue(value.hasDoseQuantity)
        XCTAssertEqual(value.doseQuantity, 1)
        XCTAssertEqual(value.unit, "count")
    }

    /// A skipped dose logs `0`: a real answer, kept distinct from absent.
    func testSkippedDoseKeepsAZeroDoseQuantity() throws {
        guard #available(iOS 26.0, *) else { return }
        let value = map(logStatus: .skipped, doseQuantity: 0)
        XCTAssertTrue(value.hasDoseQuantity)
        XCTAssertEqual(value.doseQuantity, 0)
    }

    /// An as-needed dose has no schedule: those fields are absent, never a
    /// fabricated 0 or epoch.
    func testAsNeededDoseLeavesScheduledFieldsAbsent() throws {
        guard #available(iOS 26.0, *) else { return }
        let value = map(scheduleType: .asNeeded, doseQuantity: 2, unit: HKUnit.gramUnit(with: .milli))
        XCTAssertEqual(value.scheduleType, "asNeeded")
        XCTAssertFalse(value.hasScheduledUnixMs)
        XCTAssertFalse(value.hasScheduledDoseQuantity)
        XCTAssertEqual(value.doseQuantity, 2)
        XCTAssertEqual(value.unit, "mg")
    }

    func testAbsentDoseQuantityStaysAbsent() throws {
        guard #available(iOS 26.0, *) else { return }
        XCTAssertFalse(map(logStatus: .notInteracted).hasDoseQuantity)
    }

    /// A dose whose medication is not in the shared list keeps empty name and
    /// form rather than a guess.
    func testUnresolvedMedicationLeavesNameAndFormEmpty() throws {
        guard #available(iOS 26.0, *) else { return }
        let value = map(medication: nil)
        XCTAssertEqual(value.medicationName, "")
        XCTAssertEqual(value.generalForm, "")
    }

    /// The join matches concept identifiers with `isEqual`, not identity.
    func testDirectoryMatchesConceptsByEquality() {
        let directory = MedicationDirectory([
            (concept: NSString(string: "concept-a"), identity: MedicationIdentity(name: "A", generalForm: "tablet")),
            (concept: NSString(string: "concept-b"), identity: MedicationIdentity(name: "B", generalForm: "capsule")),
        ])
        XCTAssertEqual(directory.identity(for: NSString(string: "concept-b")), MedicationIdentity(name: "B", generalForm: "capsule"))
        XCTAssertNil(directory.identity(for: NSString(string: "concept-c")))
        XCTAssertNil(MedicationDirectory().identity(for: NSString(string: "concept-a")))
    }

    @available(iOS 26.0, *)
    private func map(
        medication: MedicationIdentity? = MedicationIdentity(name: "Lisinopril 10 mg", generalForm: "tablet"),
        scheduleType: HKMedicationDoseEvent.ScheduleType = .schedule,
        logStatus: HKMedicationDoseEvent.LogStatus = .taken,
        doseQuantity: Double? = nil,
        unit: HKUnit = .count()
    ) -> Conduit_V1_MedicationDoseValue {
        let scheduled = scheduleType == .schedule ? Date(timeIntervalSince1970: 1_756_656_000) : nil
        return AnchoredReader.makeMedicationDoseValue(
            medication: medication,
            scheduleType: scheduleType,
            logStatus: logStatus,
            scheduledDate: scheduled,
            scheduledDoseQuantity: scheduled == nil ? nil : 1,
            doseQuantity: doseQuantity,
            unit: unit
        )
    }
}

/// The two places the per-medication sheet is offered, and the upgrade path.
final class MedicationSettingsTests: XCTestCase {
    private var appDB: AppDatabase!
    private let medicationID = MedicationReadings.identifier

    override func setUpWithError() throws {
        appDB = try AppDatabase.makeInMemory()
        try AppState.enableNewlyRegisteredTypes(dao: DataTypeConfigDAO(appDB))
        var config = WebhookConfig.makeDefault(url: "https://example.com/hook", bearerTokenKeychainRef: "test")
        try WebhookConfigDAO(appDB).save(&config)
    }

    /// The button shows the sheet, then turns Medications on and saves that
    /// one toggle by itself; a later tap shows the sheet again and changes
    /// nothing else.
    @MainActor
    func testChooseMedicationsShowsTheSheetThenEnablesAndStartsCaptureOnce() async throws {
        var sheets = 0
        var started: [[String]] = []
        let viewModel = SettingsViewModel(
            appState: AppState(database: appDB),
            startNewlyEnabledTypes: { started.append($0.map(\.identifier)) },
            requestMedicationAccess: { sheets += 1 }
        )
        viewModel.load()
        XCTAssertFalse(viewModel.enabledTypeIDs.contains(medicationID), "default off")
        viewModel.toggleType(HealthDataType.stepCount.identifier) // an unsaved edit elsewhere

        await viewModel.chooseMedicationsToShare()
        await viewModel.enableTask?.value
        XCTAssertEqual(sheets, 1)
        XCTAssertEqual(started, [[medicationID]])
        XCTAssertTrue(viewModel.enabledTypeIDs.contains(medicationID))
        let dao = DataTypeConfigDAO(appDB)
        XCTAssertEqual(try dao.find(hkTypeId: medicationID)?.enabled, true)
        XCTAssertEqual(try dao.find(hkTypeId: HealthDataType.stepCount.identifier)?.enabled, true, "other unsaved edits stay unsaved")

        await viewModel.chooseMedicationsToShare()
        await viewModel.enableTask?.value
        XCTAssertEqual(sheets, 2, "the sheet appears on every tap")
        XCTAssertEqual(started.count, 1, "already on: capture is not restarted")
    }

    @MainActor
    func testFailedSheetLeavesMedicationsOff() async throws {
        struct SheetFailed: Error {}
        var started = 0
        let viewModel = SettingsViewModel(
            appState: AppState(database: appDB),
            startNewlyEnabledTypes: { _ in started += 1 },
            requestMedicationAccess: { throw SheetFailed() }
        )
        viewModel.load()
        await viewModel.chooseMedicationsToShare()
        XCTAssertFalse(viewModel.enabledTypeIDs.contains(medicationID))
        XCTAssertEqual(try DataTypeConfigDAO(appDB).find(hkTypeId: medicationID)?.enabled, false)
        XCTAssertEqual(started, 0)
    }

    /// Saving never shows the sheet, not even when the toggle turned
    /// Medications on: only "Choose Medications to Share…" does.
    @MainActor
    func testSavingTheToggleNeverShowsTheSheet() async throws {
        var events: [String] = []
        let viewModel = SettingsViewModel(
            appState: AppState(database: appDB),
            startNewlyEnabledTypes: { types in events.append("start:" + types.map(\.identifier).joined(separator: ",")) },
            requestMedicationAccess: { events.append("sheet") }
        )
        viewModel.load()

        viewModel.toggleType(HealthDataType.menstrualFlow.identifier)
        try viewModel.save()
        await viewModel.enableTask?.value
        XCTAssertEqual(events, ["start:" + HealthDataType.menstrualFlow.identifier])

        viewModel.toggleType(medicationID)
        try viewModel.save()
        await viewModel.enableTask?.value
        XCTAssertEqual(events.last, "start:" + medicationID)
        XCTAssertFalse(events.contains("sheet"))
    }

    @MainActor
    func testImportConfirmationNamesEnabledSensitiveGroups() {
        let viewModel = SettingsViewModel(appState: AppState(database: appDB), startNewlyEnabledTypes: { _ in })
        viewModel.enabledTypeIDs = [HealthDataType.heartRate.identifier]
        XCTAssertEqual(viewModel.enabledSensitiveCategories, [])
        XCTAssertFalse(viewModel.hasSensitiveTypesEnabled)
        viewModel.enabledTypeIDs.insert(medicationID)
        XCTAssertEqual(viewModel.enabledSensitiveCategories, [.medications])
        viewModel.enabledTypeIDs.insert(HealthDataType.menstrualFlow.identifier)
        XCTAssertEqual(viewModel.enabledSensitiveCategories, [.cycleTracking, .medications])
    }

    func testOnboardingDefaultsMedicationsOff() {
        let viewModel = OnboardingViewModel(appState: AppState(database: appDB))
        XCTAssertFalse(viewModel.enabledTypeIDs.contains(medicationID))
        XCTAssertFalse(viewModel.medicationsEnabled)
        XCTAssertEqual(viewModel.canChooseMedications, MedicationReadings.isAvailableOnThisOS)
    }

    /// In onboarding the sheet opens only from "Choose Medications to
    /// Share…": Allow Health Access never shows it, whether Medications was
    /// turned on with the step-2 toggle or by the button.
    @MainActor
    func testOnboardingShowsTheMedicationSheetOnlyFromTheButton() async {
        var sheets = 0
        let toggled = OnboardingViewModel(appState: AppState(database: appDB), requestMedicationAccess: { sheets += 1 })
        toggled.enabledTypeIDs = [medicationID]
        await toggled.requestHealthKitPermission()
        XCTAssertEqual(sheets, 0, "toggle plus Allow does not show the sheet")
        XCTAssertNil(toggled.hkAuthError)

        let chosen = OnboardingViewModel(appState: AppState(database: appDB), requestMedicationAccess: { sheets += 1 })
        chosen.enabledTypeIDs = []
        await chosen.chooseMedicationsToShare()
        XCTAssertEqual(sheets, 1, "the button shows it")
        XCTAssertTrue(chosen.medicationsEnabled)
        await chosen.requestHealthKitPermission()
        XCTAssertEqual(sheets, 1, "Allow after Choose does not show it again")
        XCTAssertNil(chosen.hkAuthError)
        XCTAssertTrue(chosen.hkAuthCompleted)
    }

    /// No doses after 24h usually means no medication was picked (an unshared
    /// read is empty, not an error), so the hint points at the sheet.
    @MainActor
    func testNoDataHintPointsMedicationsAtTheSheet() {
        XCTAssertTrue(HKPermissionsDetailView.noDataHint(for: .medicationDose).contains("Choose medications to share"))
        XCTAssertTrue(HKPermissionsDetailView.noDataHint(for: .heartRate).contains("Check Health permissions"))
    }

    /// A user who onboarded before medications shipped gets a disabled row and
    /// no permission sheet: the entry leaves the launch-time signature alone.
    @MainActor
    func testUpgradeWritesADisabledRowAndDoesNotRePrompt() async throws {
        let upgradeDB = try AppDatabase.makeInMemory()
        let dao = DataTypeConfigDAO(upgradeDB)
        for type in HealthTypeRegistry.shared.all where type.identifier != medicationID {
            try dao.setEnabled(type.defaultEnabled, hkTypeId: type.identifier)
        }
        let suite = "conduit.medication.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let priorSignature = HealthTypeRegistry.shared.all
            .filter { $0.identifier != medicationID && $0.defaultEnabled }
            .flatMap(\.authorizationTypes)
            .map(\.identifier)
        defaults.set(Set(priorSignature).sorted().joined(separator: ","), forKey: AppState.authorizedSignatureKey)
        XCTAssertEqual(defaults.string(forKey: AppState.authorizedSignatureKey), AppState.authorizedTypesSignature(),
                       "registering medications must NOT grow the signature")

        var authorizeCalls = 0
        await AppState(database: upgradeDB).reconcileRegistry(registry: .shared, defaults: defaults, authorize: { _ in authorizeCalls += 1 })

        XCTAssertEqual(try XCTUnwrap(dao.find(hkTypeId: medicationID), "no config row written for medications").enabled, false)
        XCTAssertEqual(authorizeCalls, 0)
    }
}

/// Synthetic dose samples → persisted outbox → production batcher → decoded
/// webhook JSON. Proves the wire shape a receiver sees, not a Health app dose.
final class MedicationEvidenceTests: XCTestCase {
    func testMedicationDoseSamplesReachTheWebhookPayload() throws {
        try MedicationReadings.skipUnlessAvailable()
        guard #available(iOS 26.0, *) else { return }
        let db = try AppDatabase.makeInMemory()
        var webhook = WebhookConfig.makeDefault(url: "https://example.com/webhook", bearerTokenKeychainRef: "evidence-token")
        try WebhookConfigDAO(db).save(&webhook)
        let webhookID = try XCTUnwrap(webhook.id)
        let lisinopril = MedicationIdentity(name: "Lisinopril 10 mg", generalForm: "tablet")
        let morning = Date(timeIntervalSince1970: 1_756_656_000)
        let evening = Date(timeIntervalSince1970: 1_756_699_200)

        let taken = makeSample(at: morning.addingTimeInterval(300), value: AnchoredReader.makeMedicationDoseValue(
            medication: lisinopril, scheduleType: .schedule, logStatus: .taken,
            scheduledDate: morning, scheduledDoseQuantity: 1, doseQuantity: 1, unit: .count()
        ))
        let skipped = makeSample(at: evening, value: AnchoredReader.makeMedicationDoseValue(
            medication: lisinopril, scheduleType: .schedule, logStatus: .skipped,
            scheduledDate: evening, scheduledDoseQuantity: 1, doseQuantity: 0, unit: .count()
        ))
        let asNeeded = makeSample(at: morning.addingTimeInterval(14_400), value: AnchoredReader.makeMedicationDoseValue(
            medication: MedicationIdentity(name: "Ibuprofen 200 mg", generalForm: "capsule"), scheduleType: .asNeeded, logStatus: .taken,
            scheduledDate: nil, scheduledDoseQuantity: nil, doseQuantity: 2, unit: .count()
        ))
        _ = try OutboxDAO(db).ingest(samples: [taken, skipped, asNeeded], hkTypeId: MedicationReadings.identifier, webhookId: webhookID, anchorBlob: Data("anchor".utf8), expectedAnchorBlob: nil, expectedIngestRevision: 0)

        let batch = try XCTUnwrap(Batcher(database: db).buildBatch(webhookID: webhookID, limit: 500, deviceID: "medication-evidence-device", now: evening.addingTimeInterval(60)))
        let envelope = try Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON)
        XCTAssertEqual(envelope.batches.map(\.hkTypeID), [MedicationReadings.identifier])

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: batch.encodedJSON) as? [String: Any])
        let typeBatch = try XCTUnwrap((json["batches"] as? [[String: Any]])?.first)
        let samples = try XCTUnwrap(typeBatch["samples"] as? [[String: Any]])
        let byUUID = Dictionary(uniqueKeysWithValues: samples.map { ($0["uuid"] as? String ?? "", $0) })

        let takenWire = try XCTUnwrap(byUUID[taken.uuid])
        let takenDose = try XCTUnwrap(takenWire["medicationDose"] as? [String: Any])
        XCTAssertEqual(takenDose["medicationName"] as? String, "Lisinopril 10 mg")
        XCTAssertEqual(takenDose["generalForm"] as? String, "tablet")
        XCTAssertEqual(takenDose["scheduleType"] as? String, "schedule")
        XCTAssertEqual(takenDose["logStatus"] as? String, "taken")
        XCTAssertEqual(takenDose["scheduledUnixMs"] as? String, "1756656000000")
        XCTAssertEqual(takenDose["scheduledDoseQuantity"] as? Double, 1)
        XCTAssertEqual(takenDose["doseQuantity"] as? Double, 1)
        XCTAssertEqual(takenDose["unit"] as? String, "count")
        XCTAssertEqual(Set(takenDose.keys), ["medicationName", "generalForm", "scheduleType", "logStatus", "scheduledUnixMs", "scheduledDoseQuantity", "doseQuantity", "unit"],
                       "name and form only: no nickname or clinical codes")
        for other in ["quantity", "category", "workout", "correlation", "route", "electrocardiogram"] {
            XCTAssertNil(takenWire[other], "exactly one value shape per sample")
        }

        let skippedDose = try XCTUnwrap(byUUID[skipped.uuid]?["medicationDose"] as? [String: Any])
        XCTAssertEqual(skippedDose["logStatus"] as? String, "skipped")
        XCTAssertEqual(skippedDose["doseQuantity"] as? Double, 0, "a skipped dose's 0 is sent, not dropped")

        let asNeededDose = try XCTUnwrap(byUUID[asNeeded.uuid]?["medicationDose"] as? [String: Any])
        XCTAssertEqual(asNeededDose["scheduleType"] as? String, "asNeeded")
        XCTAssertNil(asNeededDose["scheduledUnixMs"])
        XCTAssertNil(asNeededDose["scheduledDoseQuantity"])

        try writeArtifact(prettyPrint(batch.encodedJSON), named: "webhook-payload-medication-dose.json")
    }

    private func makeSample(at date: Date, value: Conduit_V1_MedicationDoseValue) -> Conduit_V1_Sample {
        var sample = Conduit_V1_Sample()
        sample.uuid = UUID().uuidString
        sample.startUnixMs = AnchoredReader.unixMillis(date)
        sample.endUnixMs = AnchoredReader.unixMillis(date)
        sample.source.name = "iPhone"
        sample.source.bundleID = "com.apple.Health"
        sample.source.productType = "iPhone17,1"
        sample.medicationDose = value
        return sample
    }
}

/// Opt-in capture (`CONDUIT_EVIDENCE_DIR`) of the Medications row and button
/// in Settings and onboarding, light and dark, over an in-memory fixture.
@MainActor
final class MedicationScreenEvidenceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUIT_EVIDENCE_DIR"] != nil)
    }

    func testSettingsMedicationsPicker() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let viewModel = SettingsViewModel(appState: makeSnapshotAppState(), startNewlyEnabledTypes: { _ in })
            viewModel.webhookURL = "https://example.com/hook"
            viewModel.enabledTypeIDs = Set(HealthTypeRegistry.shared.all.filter(\.defaultEnabled).map(\.identifier))
            try capture(NavigationStack { DataTypesCategoryView(category: .medications, viewModel: viewModel) },
                        style: style, named: "settings-medications")
        }
    }

    func testOnboardingPermissionStep() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let viewModel = OnboardingViewModel(appState: makeSnapshotAppState())
            try capture(NavigationStack { HKPermissionStepView(viewModel: viewModel) },
                        style: style, named: "onboarding-permission-medications")
        }
    }

    func testOnboardingPickerMedicationsSection() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let viewModel = OnboardingViewModel(appState: makeSnapshotAppState())
            let section = 1 + HealthCategory.allCases
                .filter { !HealthTypeRegistry.shared.types(in: $0).isEmpty }
                .firstIndex(of: .medications)!
            try capture(NavigationStack { DataTypePickerStepView(viewModel: viewModel) },
                        style: style, named: "onboarding-picker-medications") { collection in
                collection.scrollToItem(at: IndexPath(item: 0, section: section), at: .top, animated: false)
            }
        }
    }

    private func capture<V: View>(_ view: V, style: UIUserInterfaceStyle, named name: String, scroll: ((UICollectionView) -> Void)? = nil) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        host.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        settle()
        host.view.layoutIfNeeded()
        if let scroll, let collection = collections(host.view).max(by: { $0.contentSize.height < $1.contentSize.height }) {
            scroll(collection)
            settle()
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try writeArtifact(try XCTUnwrap(image.pngData()), named: "\(name)-\(style == .dark ? "dark" : "light").png")
    }

    private func settle() {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func collections(_ view: UIView) -> [UICollectionView] {
        (view as? UICollectionView).map { [$0] } ?? view.subviews.flatMap(collections)
    }
}
