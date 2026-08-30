import XCTest
import SwiftUI
import UIKit
import HealthKit
import GRDB
@testable import Conduit

/// End-to-end evidence for the running-dynamics batch (running power, speed,
/// stride length, vertical oscillation, ground contact time).
///
/// The registry-only pattern means these five types add no pipeline code — so the
/// thing worth proving is not "the struct literal exists" (the unit tests in
/// `HealthTypeRegistryTests` cover that) but that a real `HKQuantitySample` of
/// each type travels the app's ACTUAL capture path and lands on the wire in the
/// exact JSON body the user's webhook receives, and that the five types appear in
/// the real Data Types picker the user taps through.
///
/// Two halves, both always asserted:
///
///  1. `testRunningDynamicsSamplesReachTheWebhookPayload` — builds genuine
///     `HKQuantitySample`s (no HealthKit authorization needed to construct one),
///     runs them through `AnchoredReader.makeSample` → `OutboxDAO.ingest` →
///     `Batcher.buildBatch`, and asserts on the decoded envelope. This is the
///     same code path a real Apple Watch outdoor run drives; only the sample's
///     origin differs.
///  2. `testDataTypePickerListsRunningDynamics` — hosts the real
///     `DataTypePickerStepView` (the onboarding screen where a user chooses data
///     types) in a key window, captures it, and asserts the two inputs that
///     screen renders from: the five types are in the Activity & Fitness section
///     and are selected by default (so their toggles draw ON).
///
/// Both write reviewer-facing artifacts (the webhook JSON body; a PNG of the
/// picker) when `CONDUIT_EVIDENCE_DIR` names a writable directory. Without it
/// they still run and still assert — the artifacts are optional output, never the
/// test's reason to exist. Under `xcodebuild` the variable needs the
/// `TEST_RUNNER_` prefix to reach the test process (see AGENTS.md).
@MainActor
final class RunningDynamicsEvidenceTests: XCTestCase {

    /// The five types, with a realistic mid-run reading for each so the emitted
    /// payload reads like real data to a human reviewer. Values are typical for a
    /// ~7:00/mile effort.
    ///
    /// Identified by HK identifier + display name rather than by the
    /// `HealthDataType` static members, so this file also compiles against a
    /// registry that has not registered them yet — which is how the "before" half
    /// of the picker screenshot is captured.
    static let readings: [(identifier: HKQuantityTypeIdentifier, displayName: String, value: Double, unit: HKUnit)] = [
        (.runningPower, "Running Power", 287, HKUnit.watt()),
        (.runningSpeed, "Running Speed", 3.84, HKUnit.meter().unitDivided(by: .second())),
        (.runningStrideLength, "Running Stride Length", 1.21, HKUnit.meter()),
        (.runningVerticalOscillation, "Running Vertical Oscillation", 8.6, HKUnit.meterUnit(with: .centi)),
        (.runningGroundContactTime, "Running Ground Contact Time", 238, HKUnit.secondUnit(with: .milli)),
    ]

    // MARK: - 1. Capture → outbox → webhook body

    func testRunningDynamicsSamplesReachTheWebhookPayload() throws {
        let db = try AppDatabase.makeInMemory()
        var webhook = WebhookConfig.makeDefault(
            url: "https://health.noebrito.dev/webhook",
            bearerTokenKeychainRef: "webhook_bearer_token"
        )
        try WebhookConfigDAO(db).save(&webhook)
        let webhookID = try XCTUnwrap(webhook.id)
        let outbox = OutboxDAO(db)

        // A fixed mid-run minute so the artifact is byte-stable across runs.
        let start = Date(timeIntervalSince1970: 1_788_000_000)

        for (identifier, _, value, unit) in Self.readings {
            // The registry entry is what the whole feature is — look it up the
            // same way the capture loop does rather than via a compile-time
            // symbol, so an unregistered type fails here with a clear message.
            let type = try XCTUnwrap(
                HealthTypeRegistry.shared.type(forIdentifier: identifier.rawValue),
                "\(identifier.rawValue) is not registered"
            )
            let hkType = try XCTUnwrap(
                HKObjectType.quantityType(forIdentifier: identifier),
                "\(identifier.rawValue) is not a quantity type on this OS"
            )
            let hkSample = HKQuantitySample(
                type: hkType,
                quantity: HKQuantity(unit: unit, doubleValue: value),
                start: start,
                end: start.addingTimeInterval(1)
            )

            // The app's real HK → wire mapping. Returns nil if the registry unit
            // is incompatible with the quantity type, which is exactly the
            // failure this asserts against.
            let sample = try XCTUnwrap(
                AnchoredReader.makeSample(from: hkSample, type: type),
                "\(type.identifier) did not map to a wire sample"
            )
            XCTAssertEqual(
                sample.quantity.value, value, accuracy: 0.0001,
                "\(type.identifier) round-tripped through HKUnit(from: \"\(type.defaultUnit ?? "")\") with a converted value — the registry unit does not match the recorded unit"
            )

            _ = try outbox.ingest(
                samples: [sample],
                hkTypeId: type.identifier,
                webhookId: webhookID,
                anchorBlob: Data("anchor-\(type.identifier)".utf8)
            )
        }

        // The real batcher builds the body the background URLSession POSTs.
        let batch = try XCTUnwrap(
            Batcher(database: db).buildBatch(
                webhookID: webhookID,
                limit: 500,
                deviceID: "evidence-device",
                now: start.addingTimeInterval(60)
            ),
            "no batch was built from the staged running-dynamics samples"
        )

        let envelope = try Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON)
        XCTAssertEqual(envelope.schemaVersion, "v1")

        for (identifier, _, value, _) in Self.readings {
            let typeBatch = try XCTUnwrap(
                envelope.batches.first { $0.hkTypeID == identifier.rawValue },
                "webhook body has no batch for \(identifier.rawValue)"
            )
            XCTAssertEqual(typeBatch.samples.count, 1)
            let wire = try XCTUnwrap(typeBatch.samples.first)
            XCTAssertEqual(wire.quantity.value, value, accuracy: 0.0001)
            XCTAssertEqual(
                wire.quantity.unit,
                HealthTypeRegistry.shared.type(forIdentifier: identifier.rawValue)?.defaultUnit
            )
        }

        try writeArtifact(prettyPrint(batch.encodedJSON), named: "webhook-payload-running-dynamics.json")
    }

    // MARK: - 2. The real Data Types picker

    func testDataTypePickerListsRunningDynamics() throws {
        let appState = makeSnapshotAppState()
        let viewModel = OnboardingViewModel(appState: appState)
        let view = NavigationStack { DataTypePickerStepView(viewModel: viewModel) }

        // A tall canvas so the whole grouped list lays out in one pass and the
        // Activity & Fitness section is fully on-screen (the picker is a `List`;
        // on a phone-height window the running-dynamics rows sit below the fold).
        let canvas = CGSize(width: 440, height: 2600)
        let vc = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: canvas))
        window.overrideUserInterfaceStyle = .light
        vc.overrideUserInterfaceStyle = .light
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc.view.frame = window.bounds
        vc.view.layoutIfNeeded()

        let deadline = Date().addingTimeInterval(1.6)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        vc.view.layoutIfNeeded()

        // Assert the exact inputs this screen renders from — the PNG below is the
        // human-reviewable half. (An assertion on the rendered accessibility tree
        // is not available: a SwiftUI `List` builds its cells' accessibility
        // elements lazily, on demand from the accessibility server, which is not
        // attached in a unit-test process — the hosted view vends only the
        // navigation title. So this pairs a contract assertion with an evidence
        // capture, the same split `RecipeDetailFitTests` + its snapshot file use
        // in the sibling grocery target.)
        let rendered = HealthTypeRegistry.shared.types(in: .activityFitness).map(\.displayName)
        for (identifier, displayName, _, _) in Self.readings {
            XCTAssertTrue(
                rendered.contains(displayName),
                "\"\(displayName)\" is not in the Activity & Fitness section the picker renders; got \(rendered)"
            )
            // The toggle renders ON only if the picker's own default selection
            // includes it — that is what makes these captured by default.
            XCTAssertTrue(
                viewModel.enabledTypeIDs.contains(identifier.rawValue),
                "\(identifier.rawValue) is not enabled by default in the Data Types picker"
            )
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            vc.view.drawHierarchy(in: vc.view.bounds, afterScreenUpdates: true)
        }
        let name = ProcessInfo.processInfo.environment["CONDUIT_EVIDENCE_LABEL"] ?? "after"
        try writeArtifact(
            XCTUnwrap(image.pngData()),
            named: "data-types-picker-\(name).png"
        )
    }

    // MARK: - Helpers

    private func prettyPrint(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Write a reviewer-facing artifact into `CONDUIT_EVIDENCE_DIR` when set.
    /// A missing variable is not a failure — the assertions above are the test.
    private func writeArtifact(_ data: Data, named name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["CONDUIT_EVIDENCE_DIR"], !dir.isEmpty else {
            return
        }
        let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        print("[RunningDynamicsEvidence] wrote \(url.path)")
    }
}
