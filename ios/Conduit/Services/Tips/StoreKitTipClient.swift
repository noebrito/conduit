import Foundation
import StoreKit
import os

private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "Tips")

/// Thin StoreKit 2 wrapper behind `TipStoreClient`.
///
/// Privacy rules this file must keep (see the README's "Tips" section): verification
/// happens on device through StoreKit's `VerificationResult`, never on a server; no
/// `appAccountToken` is set, so Apple's receipt carries no developer-side identifier;
/// nothing about a purchase is stored, logged with private data, or sent anywhere.
struct StoreKitTipClient: TipStoreClient {
    func loadTips(ids: [String]) async throws -> [TipOption] {
        try await Product.products(for: ids).map {
            TipOption(id: $0.id, displayName: $0.displayName, displayPrice: $0.displayPrice)
        }
    }

    func purchase(id: String) async throws -> TipPurchaseResult {
        guard let product = try await Product.products(for: [id]).first else {
            throw StoreKitError.notAvailableInStorefront
        }
        switch try await product.purchase() {
        case .success(let verification):
            return await TipTransactions.finish(verification) ? .thanked : .unverified
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }
}

enum TipTransactions {
    /// Finishes every transaction, verified or not, and reports whether it verified.
    /// A tip grants nothing, so there is nothing to withhold from an unverified one,
    /// and an unfinished consumable would be redelivered on every launch.
    @discardableResult
    static func finish(_ verification: VerificationResult<Transaction>) async -> Bool {
        let transaction: Transaction
        let verified: Bool
        switch verification {
        case .verified(let value):
            transaction = value
            verified = true
        case .unverified(let value, let error):
            transaction = value
            verified = false
            logger.error("Unverified tip transaction: \(error.localizedDescription, privacy: .public)")
        }
        await transaction.finish()
        return verified
    }
}

/// Listens to `Transaction.updates` for the life of the process, so a tip that
/// completes outside the purchase call (Ask to Buy approval, an interrupted payment,
/// a purchase finished on a previous launch) is still finished. Started once at launch.
@MainActor
final class TipTransactionObserver {
    static let shared = TipTransactionObserver()

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .background) {
            for await verification in Transaction.updates {
                await TipTransactions.finish(verification)
            }
        }
    }
}
