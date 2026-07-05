import SwiftUI

/// A secure text field for bearer tokens that:
/// - Never displays the previously stored value
/// - Shows "Token saved" placeholder when a token is already configured
/// - Supports paste via the secure text field
/// - Masks input with bullet characters
struct MaskedTokenField: View {
    let label: String
    /// Whether a token is already stored (shows "Token saved" placeholder).
    let hasStoredToken: Bool
    @Binding var input: String

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SecureField(
                hasStoredToken ? "Token saved (paste to replace)" : "Paste bearer token",
                text: $input
            )
            .textContentType(.password)
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
            .accessibilityLabel(label)
            .accessibilityHint(
                hasStoredToken
                    ? "Token is saved. Paste a new value to replace it."
                    : "Paste your webhook bearer token here."
            )

            if hasStoredToken && input.isEmpty {
                Label("Token saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("A bearer token is already configured")
            }
        }
    }
}
