import SwiftUI

/// Settings → About → Support Conduit. The only place the tip jar appears.
/// Reads no HealthKit data and stores nothing; product metadata is fetched from
/// the App Store only while this screen is open.
struct SupportView: View {
    static let privacyPolicyURL = URL(string: "https://health.noebrito.dev/privacy")!

    @State private var model: TipJarModel

    @MainActor
    init(model: TipJarModel? = nil) {
        _model = State(initialValue: model ?? TipJarModel(client: StoreKitTipClient()))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Conduit is free and open source, and every feature stays free for everyone. Nothing here unlocks anything.")
                    Text("If Conduit saves you time and you'd like to say thanks, you can leave a tip. Tips help cover the Apple developer membership, the website and the public demo receiver, and the hours that go into new data types.")
                }
                .padding(.vertical, 4)
            }

            Section {
                tipRows
            } header: {
                Text("Leave a Tip")
            } footer: {
                Text("Payment is handled by Apple through in-app purchase. Conduit never sees your payment details, and nothing about you is sent to the developer.")
            }

            Section {
                Link(destination: Self.privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                .accessibilityLabel("Open privacy policy in browser")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Support Conduit")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .alert(item: $model.notice) { notice in
            switch notice {
            case .thanks:
                Alert(title: Text("Thank you"), message: Text("That genuinely helps."))
            case .pending:
                Alert(title: Text("Tip Pending"),
                      message: Text("Your tip is waiting for approval. There's nothing else you need to do here."))
            case .failed:
                Alert(title: Text("Tip Didn't Go Through"),
                      message: Text("The App Store couldn't complete this tip. Please try again later."))
            }
        }
    }

    @ViewBuilder
    private var tipRows: some View {
        switch model.loadState {
        case .idle, .loading:
            HStack {
                Text("Loading tips…")
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView()
            }
        case .unavailable:
            VStack(alignment: .leading, spacing: 8) {
                Text("Tips aren't available right now.")
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await model.load() }
                }
            }
        case .loaded(let tips):
            ForEach(tips) { tip in
                Button {
                    Task { await model.tip(tip) }
                } label: {
                    HStack {
                        Text(tip.displayName)
                            .foregroundStyle(Color.primary)
                        Spacer()
                        if model.purchasingID == tip.id {
                            ProgressView()
                        } else {
                            Text(tip.displayPrice)
                                .fontWeight(.semibold)
                        }
                    }
                }
                .disabled(model.purchasingID != nil)
                .accessibilityLabel("\(tip.displayName), \(tip.displayPrice)")
                .accessibilityHint("Leaves a one-time tip through the App Store. It unlocks nothing.")
            }
        }
    }
}
