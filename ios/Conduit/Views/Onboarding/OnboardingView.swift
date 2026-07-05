import SwiftUI

/// Container for the 4-step onboarding flow.
///
/// Manages the step transition animation and wires up `OnboardingViewModel`.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: OnboardingViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                onboardingContent(vm: vm)
            } else {
                ProgressView()
                    .onAppear {
                        viewModel = OnboardingViewModel(appState: appState)
                    }
            }
        }
    }

    @ViewBuilder
    private func onboardingContent(vm: OnboardingViewModel) -> some View {
        NavigationStack {
            Group {
                switch vm.currentStep {
                case .welcome:
                    WelcomeStepView(onContinue: { vm.advance() })

                case .webhookSetup:
                    WebhookSetupStepView(viewModel: vm)

                case .dataTypes:
                    DataTypePickerStepView(viewModel: vm)

                case .hkPermission:
                    HKPermissionStepView(viewModel: vm)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: vm.currentStep)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
