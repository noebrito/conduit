import XCTest
import SwiftUI
import AppIntents
import HealthKit
@testable import Conduit

/// Loopback upload evidence and simulator-rendered result fixtures. The rendered
/// fixtures are not screenshots of Siri or Shortcuts UI.
@MainActor
final class ShortcutEvidenceTests: XCTestCase {
    /// Opt-in integration check with a loopback receiver. HealthKit's page is
    /// injected; configuration, staging, batching, background upload and the
    /// persisted delivery result use the production path.
    func testEnabledTypeSyncReachesExistingDestination() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["CONDUIT_EVIDENCE_DIR"] != nil && environment["CONDUIT_TEST_WEBHOOK_URL"] != nil)
        let endpoint = try XCTUnwrap(environment["CONDUIT_TEST_WEBHOOK_URL"])
        guard URL(string: endpoint)?.host == "127.0.0.1" else {
            XCTFail("Evidence must stay on the local test receiver")
            return
        }
        let database = try AppDatabase.makeInMemory()
        var destination = WebhookConfig.makeDefault(url: endpoint, bearerTokenKeychainRef: "test-only")
        try WebhookConfigDAO(database).save(&destination)
        let storedDestination = try XCTUnwrap(WebhookConfigDAO(database).first())
        let initialAnchor = try AnchoredReader.archiveAnchor(HKQueryAnchor(fromValue: 1))
        let nextAnchor = HKQueryAnchor(fromValue: 2)
        for (type, enabled) in [(HealthDataType.stepCount, true), (.heartRate, false)] {
            try DataTypeConfigDAO(database).upsert(DataTypeConfig(hkTypeId: type.identifier, enabled: enabled,
                minIntervalSeconds: nil, anchorBlob: initialAnchor, lastSyncAt: nil, lastAttemptAt: nil))
        }
        let now = Date()
        let healthSample = HKQuantitySample(type: HKQuantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: 42), start: now, end: now)
        let sample = try XCTUnwrap(AnchoredReader.makeSample(from: healthSample, type: .stepCount))
        let uploader = Uploader.shared
        let previousDatabase = uploader.database
        let previousCallback = uploader.onDeliveryCommitted
        uploader.database = database
        uploader.onDeliveryCommitted = nil
        defer {
            uploader.database = previousDatabase
            uploader.onDeliveryCommitted = previousCallback
        }
        var reads: [String] = []
        let engine = SyncEngine(database: database, readAnchored: { type, anchor, since, limit, _ in
            reads.append(type.identifier)
            XCTAssertEqual(type.identifier, HealthDataType.stepCount.identifier)
            XCTAssertNotNil(anchor)
            XCTAssertNil(since)
            XCTAssertEqual(limit, ShortcutSync.pageSize)
            return AnchoredReader.Result(samples: [sample], deletedUuids: [], newAnchor: nextAnchor)
        }, bearerToken: { "shortcut-evidence-token" })
        let message = await SyncHealthIntent.execute(protectedDataAvailable: true,
            isConfigured: { true }, sync: { await engine.syncFromShortcut() })
        XCTAssertEqual(reads, [HealthDataType.stepCount.identifier])
        XCTAssertTrue(message.contains("Captured 1 samples; queued 1 new samples"))
        XCTAssertTrue(message.contains("Submitted 1 queued items"))
        XCTAssertTrue(message.contains("not awaited or confirmed"))
        XCTAssertEqual(try WebhookConfigDAO(database).first(), storedDestination)
        XCTAssertEqual(try DataTypeConfigDAO(database).find(hkTypeId: HealthDataType.heartRate.identifier)?.enabled, false)
        XCTAssertEqual(try DataTypeConfigDAO(database).find(hkTypeId: HealthDataType.stepCount.identifier)?.anchorBlob,
            try AnchoredReader.archiveAnchor(nextAnchor))
        let deadline = Date().addingTimeInterval(20)
        while try DeliveryLogDAO(database).latest() == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let delivery = try XCTUnwrap(DeliveryLogDAO(database).latest(), "Background upload did not complete")
        XCTAssertEqual(delivery.httpStatus, 200)
        XCTAssertEqual(delivery.sampleCount, 1)
        XCTAssertEqual(delivery.accepted, 1)
        XCTAssertTrue(delivery.isSuccess, delivery.errorMessage ?? "Upload failed")
        XCTAssertEqual(try OutboxDAO(database).totalCount(), 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try writeArtifact(encoder.encode(delivery), named: "shortcut-delivery-log.json")
        try writeArtifact(Data(message.utf8), named: "shortcut-upload-result.txt")
    }

    func testActionResultStates() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUIT_EVIDENCE_DIR"] != nil)
        let completed = await ShortcutSync.run(identifiers: ["enabled"], shouldStop: { false },
            capture: { _ in ShortcutSync.Capture(captured: 8, queued: 8) }, flush: { 8 })
        let pending = await ShortcutSync.run(identifiers: ["enabled"], shouldStop: { false },
            capture: { _ in ShortcutSync.Capture(captured: 200, queued: 12, limited: true) }, flush: { 0 })
        let locked = await SyncHealthIntent.execute(protectedDataAvailable: false,
            isConfigured: { XCTFail("Locked fixture must not open configuration"); return true }, sync: { "" })
        let denied = await ShortcutSync.run(identifiers: ["enabled"], shouldStop: { false },
            capture: { _ in ShortcutSync.Capture() }, flush: { 0 })
        for (name, message) in [("capture-completed", completed.message), ("queued-not-delivered", pending.message),
                                ("locked", locked), ("empty-or-denied", denied.message)] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            XCTAssertEqual(scene.activationState, .foregroundActive, "Evidence requires the app to be foreground")
            let host = UIHostingController(rootView: NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Label("Sync Health Data", systemImage: "arrow.triangle.2.circlepath").font(.title2.bold())
                        Text("Conduit • simulator result fixture").foregroundStyle(.secondary)
                        Text(name).font(.headline)
                        Text(message).font(.body)
                        Text("Injected capture/upload results; no real Health data or endpoint. Device behavior and native Shortcuts presentation remain separate checks.").font(.footnote).foregroundStyle(.secondary)
                    }.padding(24)
                }.navigationTitle("Action result")
            })
            let window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            settle()
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let png = try XCTUnwrap(image.pngData())
            try writeArtifact(png, named: "shortcut-\(name).png")
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
    private func settle() {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

}
