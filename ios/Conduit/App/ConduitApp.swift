import SwiftUI

@main
struct ConduitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }
}

/// Routes to onboarding or the main tab view based on whether setup is complete.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.isOnboardingComplete {
            MainTabView()
        } else {
            OnboardingView()
        }
    }
}

private struct MainTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .accessibilityLabel("Home tab")

            ActivityLogView()
                .tabItem {
                    Label("Activity", systemImage: "list.bullet.rectangle")
                }
                .accessibilityLabel("Activity log tab")

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .accessibilityLabel("Settings tab")
        }
    }
}
