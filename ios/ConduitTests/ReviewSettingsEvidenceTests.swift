import XCTest
import SwiftUI
@testable import Conduit

/// Opt-in capture from the real simulator renderer with an empty, local-only fixture.
/// No requestReview call, real review submission, account, webhook, or HealthKit reads.
@MainActor
final class ReviewSettingsEvidenceTests: XCTestCase {
    func testSettingsAboutLinks() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUIT_EVIDENCE_DIR"] != nil)
        let app = makeSnapshotAppState()
        for (name, style, size) in SnapshotEnv.variants {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let host = UIHostingController(rootView: SettingsView().environment(app))
            let window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = style
            window.traitOverrides.preferredContentSizeCategory = size
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            settle()
            host.view.layoutIfNeeded()
            let list = try XCTUnwrap(scrollViews(host.view).max(by: { $0.contentSize.height < $1.contentSize.height }))
            let collection = try XCTUnwrap(list as? UICollectionView)
            let about = collection.numberOfSections - 1
            XCTAssertGreaterThan(collection.numberOfItems(inSection: about), 3)
            collection.scrollToItem(at: IndexPath(item: 2, section: about), at: .top, animated: false)
            settle()
            XCTAssertNotNil(host.view.window)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try writeArtifact(try XCTUnwrap(image.pngData()), named: "settings-about-\(name).png")
            if size.isAccessibilityCategory {
                collection.scrollToItem(at: IndexPath(item: 3, section: about), at: .top, animated: false)
                settle()
                let help = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try writeArtifact(try XCTUnwrap(help.pngData()), named: "settings-help-\(name).png")
            }
        }
    }

    private func settle() {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func scrollViews(_ view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
