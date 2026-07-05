import SwiftUI

/// Step 3 — Trigger the HealthKit authorization sheet, then finish onboarding.
struct HKPermissionStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @State private var finishError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.pink)
                    .accessibilityHidden(true)

                VStack(spacing: 12) {
                    Text("Grant Health Access")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    Text("Conduit needs read access to the data types you selected. Your health data never leaves your device except to your webhook.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = viewModel.hkAuthError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Error: \(error)")
                }

                if let error = finishError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Setup error: \(error)")
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                if !viewModel.hkAuthCompleted {
                    Button(action: {
                        Task { await viewModel.requestHealthKitPermission() }
                    }) {
                        Text("Allow Health Access")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityLabel("Request HealthKit permission")
                    .accessibilityHint("Opens the system Health permission sheet")
                } else {
                    Button(action: {
                        do {
                            try viewModel.finishOnboarding()
                        } catch {
                            finishError = error.localizedDescription
                        }
                    }) {
                        Text("Start Syncing")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityLabel("Finish setup and start syncing")
                }

                Text("iOS controls which types are actually readable. You can review and change permissions in the Health app at any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .navigationTitle("Permissions")
    }
}
