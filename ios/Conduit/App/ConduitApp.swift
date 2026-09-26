import SwiftUI

@main
struct ConduitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: appState.statusSurfaceDidBecomeActive()
            case .inactive: appState.statusSurfaceDidBecomeInactive()
            case .background: appState.statusSurfaceDidEnterBackground()
            default: break
            }
        }
    }
}

/// Routes to onboarding or the main tab view based on whether setup is complete.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if appState.isOnboardingComplete {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: appState.reviewPrompt.sceneChanged(.active)
            case .background: appState.reviewPrompt.sceneChanged(.background)
            default: appState.reviewPrompt.sceneChanged(.inactive)
            }
            if !appState.isOnboardingComplete { appState.reviewPrompt.suppressSession() }
        }
        .onChange(of: appState.isOnboardingComplete, initial: true) { _, complete in
            if !complete { appState.reviewPrompt.suppressSession() }
        }
    }
}

private struct MainTabView: View {
    @State private var selectedTab = 0
    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(isSelected: selectedTab == 0)
                .tag(0)
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .accessibilityLabel("Home tab")

            ActivityLogView()
                .tag(1)
                .tabItem {
                    Label("Activity", systemImage: "list.bullet.rectangle")
                }
                .accessibilityLabel("Activity log tab")

            SettingsView()
                .tag(2)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .accessibilityLabel("Settings tab")
        }
    }
}
