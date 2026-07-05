import SwiftUI

/// Settings screen: webhook, sync intervals, data types, about.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: SettingsViewModel?
    @State private var saveError: String? = nil
    @State private var showAdvanced = false
    @State private var showExportSheet = false
    @State private var exportText = ""
    @State private var showResetAlert = false
    @State private var showResetSyncAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    SettingsContent(
                        viewModel: vm,
                        saveError: $saveError,
                        showAdvanced: $showAdvanced,
                        showExportSheet: $showExportSheet,
                        exportText: $exportText,
                        showResetAlert: $showResetAlert,
                        showResetSyncAlert: $showResetSyncAlert,
                        appState: appState
                    )
                } else {
                    ProgressView()
                        .onAppear {
                            let vm = SettingsViewModel(appState: appState)
                            vm.load()
                            viewModel = vm
                        }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
        .sheet(isPresented: $showExportSheet) {
            ActivityView(text: exportText)
        }
        .alert("Reset Onboarding", isPresented: $showResetAlert) {
            Button("Reset", role: .destructive) {
                appState.resetOnboarding()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will restart the onboarding wizard. Your webhook configuration and sync history will be preserved.")
        }
        .alert("Reset Sync & Clear Queue", isPresented: $showResetSyncAlert) {
            Button("Clear Queue", role: .destructive) {
                appState.resetSyncQueue()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every sample waiting to upload and resets sync so Conduit captures only new data going forward. Already-delivered data on your server is unaffected. Use this once if a full history backfill was queued.")
        }
    }
}

private struct SettingsContent: View {
    @Bindable var viewModel: SettingsViewModel
    @Binding var saveError: String?
    @Binding var showAdvanced: Bool
    @Binding var showExportSheet: Bool
    @Binding var exportText: String
    @Binding var showResetAlert: Bool
    @Binding var showResetSyncAlert: Bool
    let appState: AppState

    var body: some View {
        List {
            // MARK: Webhook
            Section("Webhook") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("URL")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("https://your-server.example.com/webhook", text: $viewModel.webhookURL)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Webhook URL")
                    }

                    MaskedTokenField(
                        label: "Bearer Token",
                        hasStoredToken: viewModel.hasToken,
                        input: $viewModel.tokenInput
                    )

                    WebhookTestView(
                        isTesting: viewModel.isTesting,
                        result: viewModel.testResult,
                        onTest: { Task { await viewModel.testConnection() } }
                    )
                }
                .padding(.vertical, 4)
            }

            // MARK: Save
            if let error = saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }

            Section {
                Button(action: {
                    do {
                        try viewModel.save()
                        saveError = nil
                    } catch {
                        saveError = error.localizedDescription
                    }
                }) {
                    Text("Save Changes")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Save settings changes")
            }

            // MARK: Sync
            Section("Sync") {
                Picker("Minimum Interval", selection: $viewModel.minIntervalSeconds) {
                    ForEach(SettingsViewModel.minIntervalOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
                .accessibilityLabel("Minimum sync interval")
                .accessibilityHint("How often Conduit will upload new health samples")

                DisclosureGroup(isExpanded: $showAdvanced) {
                    Stepper("Batch size: \(viewModel.batchMaxSize)",
                            value: $viewModel.batchMaxSize,
                            in: 10...2000, step: 50)
                    .accessibilityLabel("Maximum batch size: \(viewModel.batchMaxSize) samples")

                    Stepper("Force flush at \(viewModel.forceFlushThreshold) pending",
                            value: $viewModel.forceFlushThreshold,
                            in: 10...1000, step: 10)
                    .accessibilityLabel("Force flush threshold: \(viewModel.forceFlushThreshold) samples")

                    Stepper("Outbox cap: \(viewModel.outboxCap.formatted())",
                            value: $viewModel.outboxCap,
                            in: 1000...500_000, step: 5000)
                    .accessibilityLabel("Outbox cap: \(viewModel.outboxCap.formatted()) samples")
                } label: {
                    Text("Advanced")
                        .accessibilityLabel("Advanced sync settings")
                }
            }

            // MARK: Data Types
            Section("Data Types") {
                ForEach(HealthCategory.allCases, id: \.self) { category in
                    let types = HealthTypeRegistry.shared.types(in: category)
                    if !types.isEmpty {
                        NavigationLink(destination: DataTypesCategoryView(
                            category: category,
                            viewModel: viewModel
                        )) {
                            HStack {
                                Text(category.rawValue)
                                Spacer()
                                let enabledCount = types.filter { viewModel.enabledTypeIDs.contains($0.identifier) }.count
                                Text("\(enabledCount)/\(types.count)")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        }
                        .accessibilityLabel("\(category.rawValue): \(types.filter { viewModel.enabledTypeIDs.contains($0.identifier) }.count) of \(types.count) enabled")
                    }
                }

                NavigationLink(destination: HKPermissionsDetailView(viewModel: viewModel)) {
                    Label("Health Permissions", systemImage: "heart.fill")
                }
                .accessibilityLabel("View Health permissions information")
            }

            // MARK: Import History
            Section {
                NavigationLink(destination: ImportHistoryView(viewModel: viewModel)) {
                    Label("Import History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Import past Health history")
                .accessibilityHint("Deliberately upload past Apple Health data for a time range you choose")
            } header: {
                Text("History")
            } footer: {
                Text("Conduit captures only new data going forward. Use this to deliberately upload PAST Health data — you choose how far back.")
            }

            // MARK: About
            Section("About") {
                LabeledContent("Version", value: viewModel.appVersion)
                    .accessibilityLabel("App version: \(viewModel.appVersion)")

                Link(destination: URL(string: "https://health.noebrito.dev/privacy")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                .accessibilityLabel("Open privacy policy in browser")

                NavigationLink("Open Source Licenses") {
                    LicensesView()
                }

                Button(action: {
                    viewModel.buildExportJSON()
                    exportText = viewModel.exportConfigJSON ?? "{}"
                    showExportSheet = true
                }) {
                    Label("Export Configuration", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Export configuration as JSON")
                .accessibilityHint("Share your Conduit configuration for backup or transfer")

                Button(role: .destructive, action: { showResetSyncAlert = true }) {
                    Label("Reset Sync & Clear Queue", systemImage: "trash.circle")
                }
                .accessibilityLabel("Reset sync and clear pending queue")
                .accessibilityHint("Deletes all pending uploads and resumes capturing only new data going forward")

                Button(role: .destructive, action: { showResetAlert = true }) {
                    Label("Reset & Re-run Onboarding", systemImage: "arrow.counterclockwise")
                }
                .accessibilityLabel("Reset onboarding")
                .accessibilityHint("Restarts the setup flow; webhook configuration is preserved")
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Per-category type toggle list

private struct DataTypesCategoryView: View {
    let category: HealthCategory
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        let enabledIDs = viewModel.enabledTypeIDs
        List {
            ForEach(HealthTypeRegistry.shared.types(in: category)) { type in
                let isEnabled = enabledIDs.contains(type.identifier)
                Toggle(isOn: Binding(
                    get: { viewModel.enabledTypeIDs.contains(type.identifier) },
                    set: { _ in viewModel.toggleType(type.identifier) }
                )) {
                    Text(type.displayName)
                }
                .accessibilityLabel(type.displayName)
                .accessibilityHint(isEnabled ? "Enabled. Tap to disable." : "Disabled. Tap to enable.")
            }
        }
        .navigationTitle(category.rawValue)
    }
}

// MARK: - Import History

/// Deliberate, user-triggered import of PAST Health data over a chosen range.
///
/// This is the opt-in counterpart to Conduit's forward-only default. The import
/// is paged and outbox-cap-bounded (see `SyncEngine.importHistory`) and never
/// touches the live forward-capture anchors, so ongoing capture is unaffected.
private struct ImportHistoryView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var showConfirm = false

    var body: some View {
        List {
            Section {
                Picker("Time range", selection: $viewModel.importRange) {
                    ForEach(ImportRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .accessibilityLabel("Import time range")

                if viewModel.importRange == .custom {
                    DatePicker(
                        "Start date",
                        selection: $viewModel.customImportStart,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .accessibilityLabel("Custom import start date")
                }
            } header: {
                Text("How far back")
            } footer: {
                Text("Only the data types you've enabled will be imported. Duplicate samples already captured are skipped automatically.")
            }

            Section {
                if viewModel.isImporting {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.importProgressText)
                                .font(.subheadline)
                            Text("\(viewModel.importStagedCount.formatted()) staged so far (newest first)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)

                    Button(role: .cancel) {
                        viewModel.cancelImport()
                    } label: {
                        Label("Cancel Import", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("Cancel import")
                    .accessibilityHint("Stops the import; anything already queued still uploads")
                } else {
                    Button {
                        showConfirm = true
                    } label: {
                        Label("Import History", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Start import")
                    .accessibilityHint("Imports \(viewModel.importRange.label) of past Health data, most recent first")
                }

                if viewModel.importFinished, !viewModel.isImporting {
                    let warned = viewModel.importHitCap || viewModel.importCancelled
                    Label(viewModel.importProgressText, systemImage: warned ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(warned ? .orange : .green)
                }

                if let error = viewModel.importError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Import History")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Import \(viewModel.importRange.label)?", isPresented: $showConfirm) {
            Button("Import", role: viewModel.importNeedsVolumeWarning ? .destructive : nil) {
                viewModel.startImport()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        if viewModel.importNeedsVolumeWarning {
            return "This can stage a large amount of data — potentially hundreds of thousands to millions of samples for a multi-year range. It's paged and capped so it won't overwhelm the queue, but it may take a while and use significant network to upload. Continue?"
        }
        return "Conduit will read past Health data for the selected range and queue it for upload. Continue?"
    }
}

// MARK: - Licenses

private struct LicensesView: View {
    var body: some View {
        List {
            Section("GRDB.swift") {
                Text("Copyright (c) Gwendal Roué\nMIT License")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Swift Protobuf") {
                Text("Copyright (c) Apple Inc.\nApache 2.0 License")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Licenses")
    }
}

// MARK: - Activity share sheet

private struct ActivityView: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
