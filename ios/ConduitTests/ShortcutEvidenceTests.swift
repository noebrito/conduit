import XCTest
import SwiftUI
import AppIntents
@testable import Conduit

/// Simulator-rendered result fixtures, not screenshots of Siri or Shortcuts UI.
@MainActor
final class ShortcutEvidenceTests: XCTestCase {
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
