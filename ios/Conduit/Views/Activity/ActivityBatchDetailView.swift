import SwiftUI

/// Detail view for a single delivery log batch.
///
/// Shows per-type sample counts, batch ID, HTTP status, error message,
/// and a Retry button for failed batches.
struct ActivityBatchDetailView: View {
    let entry: DeliveryLogEntry
    let viewModel: ActivityLogViewModel

    @State private var isRetrying = false
    @State private var retryDone = false

    private var perTypeCounts: [(String, Int)] {
        let counts = viewModel.outboxRowsByType(batchId: entry.batchId)
        return counts.sorted(by: { $0.key < $1.key })
    }

    var body: some View {
        List {
            // Status summary
            Section {
                HStack {
                    Image(systemName: entry.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(entry.isSuccess ? .green : .red)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.isSuccess ? "Delivered" : "Failed")
                            .font(.headline)
                        Text(entry.sentAt, style: .date) + Text(" at ") + Text(entry.sentAt, style: .time)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(entry.isSuccess ? "Delivered" : "Failed") on \(entry.sentAt.formatted(date: .abbreviated, time: .shortened))"
                )
            }

            // Batch metadata
            Section("Details") {
                LabeledContent("Batch ID") {
                    Text(entry.batchId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityLabel("Batch ID: \(entry.batchId)")

                if let status = entry.httpStatus {
                    LabeledContent("HTTP Status", value: "\(status)")
                        .accessibilityLabel("HTTP status: \(status)")
                }

                LabeledContent("Total Samples", value: "\(entry.sampleCount)")
                    .accessibilityLabel("Total samples: \(entry.sampleCount)")

                if let accepted = entry.accepted {
                    LabeledContent("New Documents") {
                        Text("\(accepted)")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(accepted == 0 ? .orange : .primary)
                    }
                    .accessibilityLabel("New documents written: \(accepted)")
                }

                if let deduped = entry.deduped {
                    LabeledContent("Duplicates", value: "\(deduped)")
                        .accessibilityLabel("Duplicates skipped: \(deduped)")
                }

                if entry.isAllDeduped {
                    Text("This batch wrote no new data — every sample was already indexed on the server.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("This batch wrote no new data; every sample was already indexed")
                }

                if let error = entry.errorMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Error")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Error: \(error)")
                }
            }

            // Per-type breakdown
            if !perTypeCounts.isEmpty {
                Section("Samples by Type") {
                    ForEach(perTypeCounts, id: \.0) { (typeId, count) in
                        let displayName = HealthTypeRegistry.shared.type(forIdentifier: typeId)?.displayName ?? typeId
                        HStack {
                            Text(displayName)
                                .font(.subheadline)
                            Spacer()
                            Text("\(count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(displayName): \(count) samples")
                    }
                }
            }

            // Retry action (failed batches only)
            if !entry.isSuccess {
                Section {
                    if retryDone {
                        Label("Re-enqueued for retry", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Batch re-enqueued successfully")
                    } else {
                        Button(action: {
                            isRetrying = true
                            Task {
                                await viewModel.retryBatch(entry)
                                isRetrying = false
                                retryDone = true
                            }
                        }) {
                            HStack {
                                if isRetrying {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                Text(isRetrying ? "Re-enqueueing…" : "Retry This Batch")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isRetrying)
                        .accessibilityLabel("Retry this failed batch")
                        .accessibilityHint("Re-enqueues the failed samples and triggers an immediate sync attempt")
                    }
                }
            }
        }
        .navigationTitle("Batch Detail")
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
    }
}
