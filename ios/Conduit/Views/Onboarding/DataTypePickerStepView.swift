import SwiftUI

/// Step 2 — Data type selection grouped by HealthCategory.
struct DataTypePickerStepView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        let enabledIDs = viewModel.enabledTypeIDs
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose Data Types")
                        .font(.title2.bold())
                    Text("Select which health data types Conduit should stream to your webhook. You can change this later in Settings.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            ForEach(HealthCategory.allCases, id: \.self) { category in
                let types = HealthTypeRegistry.shared.types(in: category)
                if !types.isEmpty {
                    Section(category.rawValue) {
                        ForEach(types) { type in
                            let isEnabled = enabledIDs.contains(type.identifier)
                            Toggle(isOn: Binding(
                                get: { viewModel.enabledTypeIDs.contains(type.identifier) },
                                set: { _ in viewModel.toggle(typeID: type.identifier) }
                            )) {
                                Text(type.displayName)
                                    .font(.body)
                            }
                            .accessibilityLabel(type.displayName)
                            .accessibilityHint(isEnabled ? "Enabled. Tap to disable." : "Disabled. Tap to enable.")
                        }
                    }
                }
            }

            Section {
                Toggle("Import existing history", isOn: $viewModel.importExistingHistory)
                    .accessibilityHint("Off by default. Conduit normally captures only new data going forward.")

                if viewModel.importExistingHistory {
                    Picker("How far back", selection: $viewModel.importRange) {
                        ForEach(ImportRange.allCases) { range in
                            Text(range.label).tag(range)
                        }
                    }
                    .accessibilityLabel("History import range")

                    if viewModel.importRange == .custom {
                        DatePicker(
                            "Start date",
                            selection: $viewModel.customImportStart,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                    }
                }
            } footer: {
                Text("Off by default: Conduit captures only new data going forward. Turn this on to also upload PAST Health data for a range you choose. You can always do this later in Settings.")
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Button(action: { viewModel.advance() }) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.regularMaterial)
            .accessibilityLabel("Continue to HealthKit permissions")
        }
        .navigationTitle("Data Types")
    }
}
