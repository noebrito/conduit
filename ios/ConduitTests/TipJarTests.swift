import XCTest
@testable import Conduit

/// Pure-logic coverage for the tip jar: ordering and screen state, with a fake
/// StoreKit client. `TipStoreKitTests` covers the real wrapper against `Tips.storekit`.
@MainActor
final class TipJarTests: XCTestCase {
    private final class FakeClient: TipStoreClient {
        var loadResult: Result<[TipOption], Error> = .success([])
        var purchaseResult: Result<TipPurchaseResult, Error> = .success(.thanked)
        var loadCalls = 0
        var purchases: [String] = []
        var onPurchase: (() async -> Void)?

        func loadTips(ids: [String]) async throws -> [TipOption] {
            loadCalls += 1
            return try loadResult.get()
        }

        func purchase(id: String) async throws -> TipPurchaseResult {
            purchases.append(id)
            await onPurchase?()
            return try purchaseResult.get()
        }
    }

    private struct Failure: Error {}

    private let small = TipOption(id: TipProduct.small.rawValue, displayName: "Small Tip", displayPrice: "$0.99")
    private let nice = TipOption(id: TipProduct.nice.rawValue, displayName: "Nice Tip", displayPrice: "$2.99")
    private let generous = TipOption(id: TipProduct.generous.rawValue, displayName: "Generous Tip", displayPrice: "$6.99")

    func testProductIDsUseTheAppBundlePrefixInTierOrder() {
        XCTAssertEqual(TipProduct.ids, [
            "dev.noebrito.Conduit.tip.small",
            "dev.noebrito.Conduit.tip.nice",
            "dev.noebrito.Conduit.tip.generous",
        ])
    }

    func testCatalogOrdersSmallestFirstWhateverTheStoreReturns() {
        XCTAssertEqual(TipCatalog.ordered([generous, small, nice]), [small, nice, generous])
    }

    func testCatalogDropsUnknownAndDuplicateProducts() {
        let stray = TipOption(id: "dev.noebrito.Conduit.pro", displayName: "Pro", displayPrice: "$9.99")
        XCTAssertEqual(TipCatalog.ordered([nice, stray, nice, small]), [small, nice])
    }

    func testLoadShowsOrderedTips() async {
        let client = FakeClient()
        client.loadResult = .success([nice, generous, small])
        let model = TipJarModel(client: client)
        XCTAssertEqual(model.loadState, .idle)
        await model.load()
        XCTAssertEqual(model.loadState, .loaded([small, nice, generous]))
        XCTAssertEqual(model.tips.map(\.displayPrice), ["$0.99", "$2.99", "$6.99"])
    }

    func testLoadOnlyFetchesOnceWhileLoaded() async {
        let client = FakeClient()
        client.loadResult = .success([small])
        let model = TipJarModel(client: client)
        await model.load()
        await model.load()
        XCTAssertEqual(client.loadCalls, 1)
    }

    func testEmptyOrFailedLoadIsUnavailableAndRetryable() async {
        let client = FakeClient()
        client.loadResult = .failure(Failure())
        let model = TipJarModel(client: client)
        await model.load()
        XCTAssertEqual(model.loadState, .unavailable)

        client.loadResult = .success([])
        await model.load()
        XCTAssertEqual(model.loadState, .unavailable)

        client.loadResult = .success([generous])
        await model.load()
        XCTAssertEqual(model.loadState, .loaded([generous]))
        XCTAssertEqual(client.loadCalls, 3)
    }

    func testPurchaseOutcomesMapToNotices() async {
        let cases: [(Result<TipPurchaseResult, Error>, TipJarModel.Notice?)] = [
            (.success(.thanked), .thanks),
            (.success(.pending), .pending),
            (.success(.cancelled), nil),
            (.success(.unverified), .failed),
            (.failure(Failure()), .failed),
        ]
        for (result, expected) in cases {
            let client = FakeClient()
            client.loadResult = .success([small])
            client.purchaseResult = result
            let model = TipJarModel(client: client)
            await model.load()
            await model.tip(small)
            XCTAssertEqual(model.notice, expected, "\(result)")
            XCTAssertNil(model.purchasingID)
            XCTAssertEqual(client.purchases, [small.id])
        }
    }

    func testOnlyOnePurchaseAtATime() async {
        let client = FakeClient()
        client.loadResult = .success([small, nice])
        let model = TipJarModel(client: client)
        await model.load()
        var second: Task<Void, Never>?
        client.onPurchase = { [model, nice] in
            XCTAssertEqual(model.purchasingID, TipProduct.small.rawValue)
            second = Task { await model.tip(nice) }
            await second?.value
        }
        await model.tip(small)
        XCTAssertEqual(client.purchases, [small.id])
        XCTAssertEqual(model.notice, .thanks)
    }

    func testCannotPurchaseATipThatIsNotListed() async {
        let client = FakeClient()
        client.loadResult = .success([small])
        let model = TipJarModel(client: client)
        await model.tip(small) // not loaded yet
        await model.load()
        await model.tip(generous) // not in the loaded list
        XCTAssertEqual(client.purchases, [])
        XCTAssertNil(model.notice)
    }
}
