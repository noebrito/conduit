import XCTest
import SwiftUI
import StoreKitTest
@testable import Conduit

/// Opt-in captures (set `CONDUIT_EVIDENCE_DIR`) of the Settings About section and the
/// Support screen, rendered by the real simulator with `Tips.storekit` loaded.
/// No purchase is made and nothing touches HealthKit or the network.
@MainActor
final class TipSupportEvidenceTests: XCTestCase {
    private let styles: [(String, UIUserInterfaceStyle)] = [("light", .light), ("dark", .dark)]

    func testSettingsAboutShowsSupportRow() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUIT_EVIDENCE_DIR"] != nil)
        let app = makeSnapshotAppState()
        for (name, style) in styles {
            let (window, host) = try present(SettingsView().environment(app), style: style)
            defer { window.isHidden = true }
            let collection = try XCTUnwrap(scrollViews(host.view)
                .max(by: { $0.contentSize.height < $1.contentSize.height }) as? UICollectionView)
            let about = collection.numberOfSections - 1
            collection.scrollToItem(at: IndexPath(item: 0, section: about), at: .top, animated: false)
            settle()
            try writeArtifact(capture(window), named: "settings-about-support-\(name).png")
        }
    }

    func testSupportScreenWithTipsLoaded() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUIT_EVIDENCE_DIR"] != nil)
        let session = try SKTestSession(configurationFileNamed: "Tips")
        session.resetToDefaultState()
        session.disableDialogs = true
        for (name, style) in styles {
            let model = TipJarModel(client: StoreKitTipClient())
            await model.load()
            XCTAssertEqual(model.tips.count, 3)
            let (window, _) = try present(NavigationStack { SupportView(model: model) }, style: style)
            defer { window.isHidden = true }
            try writeArtifact(capture(window), named: "support-screen-\(name).png")
        }
    }

    private func present<V: View>(_ view: V, style: UIUserInterfaceStyle) throws -> (UIWindow, UIViewController) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        host.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        settle()
        host.view.layoutIfNeeded()
        return (window, host)
    }

    private func capture(_ window: UIWindow) throws -> Data {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try XCTUnwrap(image.pngData())
    }

    private func settle() {
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func scrollViews(_ view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
