import Foundation
import Observation

/// The three optional tips. Each is a consumable that unlocks nothing: no state
/// persists after a tip, and no feature anywhere checks for one.
enum TipProduct: String, CaseIterable {
    case small = "dev.noebrito.Conduit.tip.small"
    case nice = "dev.noebrito.Conduit.tip.nice"
    case generous = "dev.noebrito.Conduit.tip.generous"

    static var ids: [String] { allCases.map(\.rawValue) }
}

/// What the Support screen shows for one tip. `displayPrice` is Apple's localized
/// string, never a price formatted by the app.
struct TipOption: Equatable, Identifiable {
    let id: String
    let displayName: String
    let displayPrice: String
}

enum TipPurchaseResult: Equatable {
    /// Verified and finished.
    case thanked
    /// Ask to Buy or an interrupted payment; `TipTransactionObserver` finishes it if it later completes.
    case pending
    case cancelled
    /// StoreKit could not verify the signed transaction. It is still finished.
    case unverified
}

/// The StoreKit seam. `StoreKitTipClient` is the only real implementation; tests use fakes.
protocol TipStoreClient {
    func loadTips(ids: [String]) async throws -> [TipOption]
    func purchase(id: String) async throws -> TipPurchaseResult
}

enum TipCatalog {
    /// Tips in the order the screen lists them (smallest first), whatever order the
    /// App Store returns them in. IDs that are not one of the three tips, and
    /// duplicates, are dropped.
    static func ordered(_ options: [TipOption]) -> [TipOption] {
        TipProduct.allCases.compactMap { product in options.first { $0.id == product.rawValue } }
    }
}

/// State for the Support screen. Holds nothing beyond the visit: a tip leaves no
/// trace in the app once the thank-you alert is dismissed.
@MainActor
@Observable
final class TipJarModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([TipOption])
        case unavailable
    }

    enum Notice: Equatable, Identifiable {
        case thanks
        case pending
        case failed

        var id: Self { self }
    }

    private(set) var loadState: LoadState = .idle
    private(set) var purchasingID: String?
    var notice: Notice?

    private let client: TipStoreClient

    init(client: TipStoreClient) {
        self.client = client
    }

    var tips: [TipOption] {
        if case .loaded(let tips) = loadState { return tips }
        return []
    }

    /// Loads product metadata from the App Store. Only ever called because the user
    /// opened the Support screen; nothing fetches it at launch or in the background.
    func load() async {
        switch loadState {
        case .loading, .loaded: return
        case .idle, .unavailable: break
        }
        loadState = .loading
        do {
            let tips = TipCatalog.ordered(try await client.loadTips(ids: TipProduct.ids))
            loadState = tips.isEmpty ? .unavailable : .loaded(tips)
        } catch {
            loadState = .unavailable
        }
    }

    /// One purchase at a time; a second tap while the App Store sheet is up is ignored.
    func tip(_ option: TipOption) async {
        guard purchasingID == nil, tips.contains(option) else { return }
        purchasingID = option.id
        defer { purchasingID = nil }
        do {
            switch try await client.purchase(id: option.id) {
            case .thanked: notice = .thanks
            case .pending: notice = .pending
            case .cancelled: break
            case .unverified: notice = .failed
            }
        } catch {
            notice = .failed
        }
    }
}
