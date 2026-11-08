import XCTest
import StoreKit
import StoreKitTest
@testable import Conduit

/// The real StoreKit 2 wrapper against the local `Tips.storekit` configuration,
/// with no App Store connection: products load, a tip verifies and is finished,
/// and a purchase completed outside the purchase call, delivered later through
/// `Transaction.updates`, is finished by the launch-time observer.
@MainActor
final class TipStoreKitTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "Tips")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() async throws {
        session.clearTransactions()
        session = nil
    }

    func testLoadsTheThreeTipsWithApplesDisplayPrices() async throws {
        let tips = TipCatalog.ordered(try await StoreKitTipClient().loadTips(ids: TipProduct.ids))
        XCTAssertEqual(tips.map(\.id), TipProduct.ids)
        XCTAssertEqual(tips.map(\.displayName), ["Small Tip", "Nice Tip", "Generous Tip"])
        XCTAssertEqual(tips.map(\.displayPrice), ["$0.99", "$2.99", "$6.99"])
    }

    func testPurchaseVerifiesAndFinishesTheTransaction() async throws {
        let result = try await StoreKitTipClient().purchase(id: TipProduct.nice.rawValue)
        XCTAssertEqual(result, .thanked)
        for await verification in Transaction.unfinished {
            XCTFail("tip left unfinished: \(verification.unsafePayloadValue.productID)")
        }
    }

    func testPurchaseCompletedOutsideTheAppIsFinishedByTheUpdatesListener() async throws {
        TipTransactionObserver.shared.start()
        // A purchase that did not come back through `purchase()` (Ask to Buy approval,
        // an interrupted payment completed later) reaches the app only through
        // `Transaction.updates`; `buyProduct` delivers one the same way.
        _ = try await session.buyProduct(identifier: TipProduct.small.rawValue, options: [])

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline,
              !TipTransactionObserver.shared.finishedProductIDs.contains(TipProduct.small.rawValue) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(TipTransactionObserver.shared.finishedProductIDs.contains(TipProduct.small.rawValue),
                      "a tip completed outside the app was not finished by Transaction.updates")
        for await verification in Transaction.unfinished {
            XCTFail("tip left unfinished: \(verification.unsafePayloadValue.productID)")
        }
    }
}
