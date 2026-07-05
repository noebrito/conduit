import SwiftUI

/// Sub-screen showing honest information about HealthKit read permissions.
///
/// iOS does not expose whether a user granted read access for a specific type;
/// this screen is honest about that and provides actionable guidance.
struct HKPermissionsDetailView: View {
    let viewModel: SettingsViewModel
    @Environment(\.openURL) private var openURL

    private var typesWithWarning: [HealthDataType] {
        let cutoff = Date().addingTimeInterval(-86400)
        return HealthTypeRegistry.shared.all.filter { type in
            guard viewModel.enabledTypeIDs.contains(type.identifier) else { return false }
            guard let enabledAt = viewModel.typeEnabledDate(type.identifier) else { return false }
            guard enabledAt < cutoff else { return false }
            guard let lastSyncAt = viewModel.typeLastSyncDate(type.identifier) else { return true }
            return lastSyncAt < enabledAt
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("How iOS Health Permissions Work", systemImage: "info.circle")
                        .font(.headline)
                    Text("iOS doesn't tell apps whether you granted read access to a specific health type. This is an intentional privacy protection.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("To verify or change which types Conduit can read, use the Health app → Sharing → Apps → Conduit.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                Button(action: {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }) {
                    Label("Open Health Settings", systemImage: "heart.fill")
                }
                .accessibilityLabel("Open iOS Settings to view Health permissions")
            } header: {
                Text("Permissions")
            }

            if !typesWithWarning.isEmpty {
                Section {
                    ForEach(typesWithWarning) { type in
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.displayName)
                                    .font(.subheadline.bold())
                                Text("Enabled over 24h ago — no samples received yet. Check Health permissions.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(type.displayName): no samples received in 24 hours. Check Health permissions.")
                    }
                } header: {
                    Text("No Data Received")
                } footer: {
                    Text("These types have been enabled for over 24 hours but Conduit hasn't received any samples. You may need to grant read access in the Health app.")
                }
            } else {
                Section {
                    Label("All enabled types are receiving data or were recently configured.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }

            Section("Enabled Types") {
                ForEach(HealthTypeRegistry.shared.all.filter { viewModel.enabledTypeIDs.contains($0.identifier) }) { type in
                    Text(type.displayName)
                        .font(.subheadline)
                }
            }
        }
        .navigationTitle("Health Permissions")
        .listStyle(.insetGrouped)
    }
}
