import SwiftUI

/// Reusable Test Connection button + result display.
///
/// Used in both onboarding (WebhookSetupStepView) and Settings.
struct WebhookTestView: View {
    let isTesting: Bool
    let result: WebhookTester.Result?
    let onTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onTest) {
                HStack(spacing: 8) {
                    if isTesting {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "bolt.horizontal")
                    }
                    Text(isTesting ? "Testing…" : "Test Connection")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isTesting)
            .accessibilityLabel("Test webhook connection")
            .accessibilityHint("Sends a test payload to verify the webhook URL and token are correct")

            if let result {
                HStack(spacing: 6) {
                    Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.isSuccess ? .green : .red)
                    Text(result.summary)
                        .font(.subheadline)
                        .foregroundStyle(result.isSuccess ? Color.primary : Color.red)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    result.isSuccess
                        ? "Connection successful. \(result.summary)"
                        : "Connection failed. \(result.summary)"
                )
            }
        }
    }
}
