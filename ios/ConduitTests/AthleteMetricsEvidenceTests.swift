import XCTest
import SwiftUI
import UIKit
import HealthKit
import GRDB
@testable import Conduit

/// End-to-end evidence for the "Batch 1" athlete metrics (heart-rate recovery,
/// physical effort, cycling power/cadence/speed/FTP, swimming stroke count, and
/// the two workout effort scores).
///
/// The registry-only pattern means these nine types add no pipeline code — so the
/// thing worth proving is not "the struct literal exists" (the unit tests in
/// `HealthTypeRegistryTests` cover that) but that a real `HKQuantitySample` of
/// each type travels the app's ACTUAL capture path and lands on the wire in the
/// exact JSON body the user's webhook receives, and that the nine types appear in
/// the real Data Types picker the user taps through. This is also the test that
/// proves `appleEffortScore` and `kcal/kg*hr` — the two most guessable-wrong
/// values in the batch — actually survive the real path rather than just typecheck.
///
/// Two halves, both always asserted:
///
///  1. `testAthleteMetricSamplesReachTheWebhookPayload` — builds genuine
///     `HKQuantitySample`s (no HealthKit authorization needed to construct one),
///     runs them through `AnchoredReader.makeSample` → `OutboxDAO.ingest` →
///     `Batcher.buildBatch`, and asserts on the decoded envelope. This is the
///     same code path a real Apple Watch workout drives; only the sample's
///     origin differs. The emitted JSON is reused verbatim by
///     `conduit/ingester/http/athlete_metrics_e2e_test.go`. Covers whichever of
///     the nine the running OS actually vends — the two effort scores are iOS 18+
///     and no `HKQuantitySample` of them can be built below that.
///  2. `testDataTypePickerListsAthleteMetrics` — hosts the real
///     `DataTypePickerStepView` (the onboarding screen where a user chooses data
///     types) in a key window, captures it, and asserts the two inputs that
///     screen renders from: the nine types are in the Activity & Fitness section
///     and are selected by default (so their toggles draw ON).
///
/// Both write reviewer-facing artifacts (the webhook JSON body; a PNG of the
/// picker) when `CONDUIT_EVIDENCE_DIR` names a writable directory. Without it
/// they still run and still assert — the artifacts are optional output, never the
/// test's reason to exist. Under `xcodebuild` the variable needs the
/// `TEST_RUNNER_` prefix to reach the test process (see AGENTS.md).
@MainActor
final class AthleteMetricsEvidenceTests: XCTestCase {

    /// A realistic reading per type so the emitted payload reads like real data to
    /// a human reviewer. All nine on an iOS 18+ runner; the seven always-available
    /// ones below that (see the gate note at the bottom of this comment).
    ///
    /// Identified by raw HK identifier `String` + display name rather than by
    /// the `HealthDataType` static members, so this file also compiles against
    /// a registry that has not registered them yet — which is how the
    /// "before" half of the picker screenshot is captured.
    ///
    /// A raw `String`, not `HKQuantityTypeIdentifier`, because the SDK marks
    /// `.workoutEffortScore`/`.estimatedWorkoutEffortScore`
    /// `@available(iOS 18.0, *)` — referencing either case directly in this
    /// array literal fails to compile at this target's iOS 17.0 deployment
    /// target. `HKQuantityTypeIdentifier(rawValue:)`, used below wherever a
    /// typed value is needed, is not itself version-gated.
    ///
    /// Same trap on the unit side: `HKUnit.appleEffortScore()` is likewise
    /// `@available(iOS 18.0, *)`. `HKUnit(from: "appleEffortScore")` — the
    /// general string-parsing constructor, not version-gated — produces the
    /// identical unit at runtime and is exactly what `AnchoredReader.makeSample`
    /// already builds from `type.defaultUnit` in production.
    ///
    /// ⚠️ Computed, not a `static let`, and the effort-score rows are built only
    /// under `EffortScoreIdentifiers.isAvailableOnThisOS`. `HKUnit(from:)` raises
    /// an ObjC `NSInvalidArgumentException` for a unit string the running OS does
    /// not know, which is uncatchable from Swift — evaluated eagerly in a stored
    /// static, that would tear down this whole test class (both tests) on an
    /// iOS 17.x runner rather than fail one assertion. Below iOS 18 this table
    /// degrades to the seven always-available types, which is also what keeps
    /// `HKObjectType.quantityType(forIdentifier:)` unwrappable for every row.
    typealias Reading = (identifier: String, displayName: String, value: Double, unit: HKUnit)

    static var readings: [Reading] {
        alwaysAvailableReadings + effortScoreReadings
    }

    /// All nine, unconditionally — the picker half of this file asserts against the
    /// registry and the onboarding view model, both of which are static string
    /// tables with no HealthKit runtime dependency, so the OS gate on `readings`
    /// above must not shrink that coverage on an older runner.
    ///
    /// The effort-score identifiers are the independent `EffortScoreIdentifiers`
    /// literals, not `HealthDataType.*.identifier`, so a misspelled registry
    /// literal fails here instead of matching itself.
    static var pickerEntries: [(identifier: String, displayName: String)] {
        alwaysAvailableReadings.map { ($0.identifier, $0.displayName) } + [
            (EffortScoreIdentifiers.workout, "Workout Effort Score"),
            (EffortScoreIdentifiers.estimated, "Estimated Workout Effort Score"),
        ]
    }

    private static let alwaysAvailableReadings: [Reading] = [
        (HKQuantityTypeIdentifier.heartRateRecoveryOneMinute.rawValue, "Heart Rate Recovery (1 min)", 34, HKUnit.count().unitDivided(by: .minute())),
        (HKQuantityTypeIdentifier.physicalEffort.rawValue, "Physical Effort", 8.2, HKUnit.kilocalorie().unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))),
        (HKQuantityTypeIdentifier.cyclingPower.rawValue, "Cycling Power", 241, HKUnit.watt()),
        (HKQuantityTypeIdentifier.cyclingCadence.rawValue, "Cycling Cadence", 88, HKUnit.count().unitDivided(by: .minute())),
        (HKQuantityTypeIdentifier.cyclingSpeed.rawValue, "Cycling Speed", 8.4, HKUnit.meter().unitDivided(by: .second())),
        (HKQuantityTypeIdentifier.cyclingFunctionalThresholdPower.rawValue, "Cycling Functional Threshold Power (FTP)", 233, HKUnit.watt()),
        (HKQuantityTypeIdentifier.swimmingStrokeCount.rawValue, "Swimming Stroke Count", 620, HKUnit.count()),
    ]

    private static var effortScoreReadings: [Reading] {
        guard EffortScoreIdentifiers.isAvailableOnThisOS else { return [] }
        let unit = HKUnit(from: "appleEffortScore")
        return [
            (EffortScoreIdentifiers.workout, "Workout Effort Score", 7, unit),
            (EffortScoreIdentifiers.estimated, "Estimated Workout Effort Score", 6, unit),
        ]
    }

    // MARK: - 1. Capture → outbox → webhook body

    func testAthleteMetricSamplesReachTheWebhookPayload() throws {
        let db = try AppDatabase.makeInMemory()
        var webhook = WebhookConfig.makeDefault(
            url: "https://health.noebrito.dev/webhook",
            bearerTokenKeychainRef: "webhook_bearer_token"
        )
        try WebhookConfigDAO(db).save(&webhook)
        let webhookID = try XCTUnwrap(webhook.id)
        let outbox = OutboxDAO(db)

        // A fixed minute so the artifact is byte-stable across runs.
        let start = Date(timeIntervalSince1970: 1_788_100_000)

        for (identifier, _, value, unit) in Self.readings {
            // The registry entry is what the whole feature is — look it up the
            // same way the capture loop does rather than via a compile-time
            // symbol, so an unregistered type fails here with a clear message.
            let type = try XCTUnwrap(
                HealthTypeRegistry.shared.type(forIdentifier: identifier),
                "\(identifier) is not registered"
            )
            let hkType = try XCTUnwrap(
                HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)),
                "\(identifier) is not a quantity type on this OS"
            )
            let hkSample = HKQuantitySample(
                type: hkType,
                quantity: HKQuantity(unit: unit, doubleValue: value),
                start: start,
                end: start.addingTimeInterval(1)
            )

            // The app's real HK → wire mapping. Returns nil if the registry unit
            // is incompatible with the quantity type, which is exactly the
            // failure this asserts against — the trap `appleEffortScore` and
            // `kcal/kg*hr` exist to catch.
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
            "no batch was built from the staged athlete-metric samples"
        )

        let envelope = try Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON)
        XCTAssertEqual(envelope.schemaVersion, "v1")

        for (identifier, _, value, _) in Self.readings {
            let typeBatch = try XCTUnwrap(
                envelope.batches.first { $0.hkTypeID == identifier },
                "webhook body has no batch for \(identifier)"
            )
            XCTAssertEqual(typeBatch.samples.count, 1)
            let wire = try XCTUnwrap(typeBatch.samples.first)
            XCTAssertEqual(wire.quantity.value, value, accuracy: 0.0001)
            XCTAssertEqual(
                wire.quantity.unit,
                HealthTypeRegistry.shared.type(forIdentifier: identifier)?.defaultUnit
            )
        }

        try writeArtifact(prettyPrint(batch.encodedJSON), named: "webhook-payload-athlete-metrics.json")
    }

    // MARK: - 2. The real Data Types picker

    func testDataTypePickerListsAthleteMetrics() throws {
        let appState = makeSnapshotAppState()
        let viewModel = OnboardingViewModel(appState: appState)
        let view = NavigationStack { DataTypePickerStepView(viewModel: viewModel) }

        // A tall canvas so the whole grouped list lays out in one pass and the
        // Activity & Fitness section is fully on-screen (the picker is a `List`;
        // on a phone-height window the athlete-metrics rows sit below the fold).
        let canvas = CGSize(width: 440, height: 3200)
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
        // capture, the same split `RunningDynamicsEvidenceTests` uses.)
        let rendered = HealthTypeRegistry.shared.types(in: .activityFitness).map(\.displayName)
        for (identifier, displayName) in Self.pickerEntries {
            XCTAssertTrue(
                rendered.contains(displayName),
                "\"\(displayName)\" is not in the Activity & Fitness section the picker renders; got \(rendered)"
            )
            // The toggle renders ON only if the picker's own default selection
            // includes it — that is what makes these captured by default.
            XCTAssertTrue(
                viewModel.enabledTypeIDs.contains(identifier),
                "\(identifier) is not enabled by default in the Data Types picker"
            )
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        // `layer.render(in:)`, NOT `drawHierarchy(in:afterScreenUpdates: true)`.
        // The sibling `RunningDynamicsEvidenceTests` uses `drawHierarchy` and
        // renders fine at its 2600pt canvas, but this file needs a 3200pt one to
        // fit nine more rows — and `drawHierarchy` silently returns an all-black
        // image above ~2600pt @2x in this offscreen, scene-less harness (measured:
        // identical view, 2600pt → real capture, 3200pt → 100% black). It fails
        // silently, so the PNG still writes and the test still passes with a
        // useless artifact. `layer.render(in:)` walks the layer tree directly
        // instead of asking the render server to recomposite, and captures this
        // screen correctly at either height.
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            vc.view.layer.render(in: ctx.cgContext)
        }
        let name = ProcessInfo.processInfo.environment["CONDUIT_EVIDENCE_LABEL"] ?? "after"
        try writeArtifact(
            XCTUnwrap(image.pngData()),
            named: "data-types-picker-athlete-metrics-\(name).png"
        )
    }
}
