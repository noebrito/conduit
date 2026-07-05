import SwiftUI

/// Step 0 — Welcome introduction screen.
struct WelcomeStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(spacing: 12) {
                    Text("Welcome to Conduit")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)

                    Text("Stream your HealthKit data to any webhook you control — privately, with no cloud accounts required.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 16) {
                    FeatureRow(icon: "lock.shield.fill", title: "Your data, your server",
                               description: "Conduit sends your health data only to the webhook you configure.")
                    FeatureRow(icon: "arrow.trianglehead.2.clockwise", title: "Reliable delivery",
                               description: "Samples are staged locally and delivered at-least-once with automatic retries.")
                    FeatureRow(icon: "bell.badge.fill", title: "Background sync",
                               description: "New health samples trigger quiet background uploads — no manual intervention.")
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 32)

            Spacer()

            Button(action: onContinue) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
            .accessibilityLabel("Get started with Conduit setup")
        }
        .navigationTitle("Conduit")
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        WelcomeStepView(onContinue: {})
    }
}
