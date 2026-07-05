import SwiftUI

/// Step 1 — Webhook URL + masked bearer token + Test Connection.
///
/// Proceeding to the next step is blocked until Test Connection succeeds.
struct WebhookSetupStepView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Set Up Your Webhook")
                        .font(.title2.bold())
                    Text("Enter the URL and bearer token for the server that will receive your health data.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Webhook URL")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("https://your-server.example.com/webhook", text: $viewModel.webhookURL)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(.systemBackground))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Color(.separator))
                                    )
                            )
                            .accessibilityLabel("Webhook URL")
                            .accessibilityHint("Enter the HTTPS URL your health data will be posted to")
                    }

                    MaskedTokenField(
                        label: "Bearer Token",
                        hasStoredToken: false,
                        input: $viewModel.tokenInput
                    )
                }

                WebhookTestView(
                    isTesting: viewModel.isTesting,
                    result: viewModel.testResult,
                    onTest: {
                        Task { await viewModel.testConnection() }
                    }
                )

                if viewModel.testResult?.isSuccess == false {
                    Text("Connection must succeed before continuing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: { viewModel.advance() }) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canAdvanceFromWebhookSetup || viewModel.webhookURL.isEmpty || viewModel.tokenInput.isEmpty)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.regularMaterial)
            .accessibilityLabel("Continue to data type selection")
            .accessibilityHint(
                viewModel.canAdvanceFromWebhookSetup
                    ? "Tap to continue"
                    : "Test Connection must succeed first"
            )
        }
        .navigationTitle("Webhook")
    }
}
