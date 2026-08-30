import SwiftUI

/// Home screen: sync status, sample counts, Sync Now button.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: HomeViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    HomeContent(viewModel: vm)
                } else {
                    ProgressView()
                        .onAppear {
                            viewModel = HomeViewModel(appState: appState)
                        }
                }
            }
            .navigationTitle("Conduit")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct HomeContent: View {
    let viewModel: HomeViewModel

    var body: some View {
        List {
            // Status
            Section {
                HStack(spacing: 12) {
                    statusIcon
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 2) {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(viewModel.syncStatusLabel)
                                .font(.subheadline.bold())
                                .foregroundStyle(viewModel.statusIsError ? .red : .primary)
                        }
                        if viewModel.isSyncing {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .padding(.top, 2)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Sync status: \(viewModel.syncStatusLabel)")
            } header: {
                Text("Status")
            }

            // Counts
            Section {
                CountRow(
                    icon: "checkmark.circle",
                    color: .green,
                    label: "Staged today",
                    value: viewModel.stagedTodayCount
                )
                CountRow(
                    icon: "clock.arrow.circlepath",
                    color: .orange,
                    label: "Pending / In-flight",
                    value: viewModel.pendingCount
                )
                CountRow(
                    icon: "exclamationmark.triangle",
                    color: .red,
                    label: "Failed",
                    value: viewModel.failedCount
                )
            } header: {
                Text("Outbox")
            }

            // Actions
            Section {
                Button(action: {
                    Task { await viewModel.syncNow() }
                }) {
                    HStack {
                        if viewModel.isSyncing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.trianglehead.2.clockwise")
                        }
                        Text(viewModel.isSyncing ? "Syncing…" : "Sync Now")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.isSyncing)
                .accessibilityLabel("Sync now")
                .accessibilityHint("Forces an immediate upload of all pending samples, bypassing the time interval gate")
            }
        }
        .listStyle(.insetGrouped)
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var statusIcon: some View {
        Group {
            if viewModel.isSyncing {
                ProgressView()
                    .progressViewStyle(.circular)
            } else if viewModel.statusIsError {
                Image(systemName: "exclamationmark.wifi")
                    .foregroundStyle(.red)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

private struct CountRow: View {
    let icon: String
    let color: Color
    let label: String
    let value: Int

    var body: some View {
        HStack {
            Label(label, systemImage: icon)
                .foregroundStyle(color)
            Spacer()
            Text(value.formatted())
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

#Preview {
    NavigationStack {
        Text("Home preview requires AppState environment")
    }
}
