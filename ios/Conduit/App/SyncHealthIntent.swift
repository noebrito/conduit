import AppIntents
import UIKit

struct SyncHealthIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Health Data"
    static var description = IntentDescription("Capture a bounded page of fresh data for your enabled Health types and start uploading to your existing Conduit destination. Unlock your device first. Receiver acceptance is reported later in Activity Log.")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = await Self.execute(
            protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
            isConfigured: { AppState.shared.isOnboardingComplete },
            sync: {
                let state = AppState.shared
                let message = await state.syncEngine.syncFromShortcut()
                await state.flushStatusSnapshot()
                return message
            }
        )
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }

    /// Injected preflight keeps locked-device tests off the real database/HealthKit.
    @MainActor
    static func execute(
        protectedDataAvailable: Bool,
        isConfigured: () -> Bool,
        sync: () async -> String
    ) async -> String {
        guard protectedDataAvailable else {
            return "Health data is unavailable while the device is locked. Unlock your device and run again. Nothing was captured or queued by this action."
        }
        guard isConfigured() else {
            return "Open Conduit and finish setup before syncing. Nothing was captured or queued by this action."
        }
        return await sync()
    }
}

struct ConduitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncHealthIntent(), phrases: ["Sync Health with \(.applicationName)"],
                    shortTitle: "Sync Health Data", systemImageName: "arrow.triangle.2.circlepath")
    }
}
