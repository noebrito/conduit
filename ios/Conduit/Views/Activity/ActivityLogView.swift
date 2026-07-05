import SwiftUI

/// Activity Log: reverse-chrono list of recent batches with filter chips.
struct ActivityLogView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: ActivityLogViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    ActivityLogContent(viewModel: vm)
                } else {
                    ProgressView()
                        .onAppear {
                            let vm = ActivityLogViewModel(appState: appState)
                            vm.start()
                            viewModel = vm
                        }
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct ActivityLogContent: View {
    @Bindable var viewModel: ActivityLogViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ActivityLogViewModel.Filter.allCases, id: \.self) { f in
                        FilterChip(
                            label: f.rawValue,
                            isSelected: viewModel.filter == f,
                            onTap: { viewModel.filter = f }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Divider()

            if viewModel.filteredEntries.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "list.bullet.rectangle",
                    description: Text(
                        viewModel.filter == .all
                            ? "Batches will appear here after your first sync."
                            : "No \(viewModel.filter.rawValue.lowercased()) batches found."
                    )
                )
            } else {
                List {
                    ForEach(viewModel.filteredEntries) { entry in
                        NavigationLink(destination: ActivityBatchDetailView(
                            entry: entry,
                            viewModel: viewModel
                        )) {
                            ActivityEntryRow(entry: entry)
                        }
                        .accessibilityLabel(
                            "\(entry.isSuccess ? "Successful" : "Failed") batch, \(entry.sampleCount) samples, \(RelativeDateTimeFormatter().localizedString(for: entry.sentAt, relativeTo: Date()))"
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.subheadline.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color(.systemGray5))
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter by \(label)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct ActivityEntryRow: View {
    let entry: DeliveryLogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(entry.isSuccess ? .green : .red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.sampleCount) sample\(entry.sampleCount == 1 ? "" : "s")")
                    .font(.subheadline.bold())

                if let outcome = entry.writeOutcomeLabel {
                    Text(outcome)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(entry.isAllDeduped ? .orange : .secondary)
                }

                HStack(spacing: 4) {
                    Text(Self.dateFormatter.string(from: entry.sentAt))
                    Text("·")
                    Text(Self.timeFormatter.string(from: entry.sentAt))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(entry.statusLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(entry.isSuccess ? .green : .red)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill((entry.isSuccess ? Color.green : Color.red).opacity(0.12))
                )
        }
        .padding(.vertical, 2)
    }
}
