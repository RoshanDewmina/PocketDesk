import StoreKit
import StoreKitTest
import XCTest
@testable import PocketDeskRemote

/// Local-only namespace and 1.00 harness amount are NOT a proposed live price/product/cohort.
@MainActor final class OneTimeStoreKitTests: XCTestCase {
    func testBothLocalNonConsumablesRestoreWhileSalesDisabledAndRefundKeepsOtherBenefit() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "FarsideOneTimeTestOnly", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState(); session.disableDialogs = true; session.clearTransactions()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        let ids = ["test.farside.one-time.lifetime", "test.farside.one-time.founder"]
        let policy = OneTimeOfferPolicy(entries: [.init(kind: .lifetime, productID: ids[0]), .init(kind: .founder, productID: ids[1])])
        var syncCalls = 0
        let store = AnywhereStore(oneTimePolicy: policy, accountToken: { UUID() }, serviceAvailable: { true }, sync: { syncCalls += 1 })
        defer { store.stop() }
        await store.loadProducts()
        XCTAssertTrue(store.oneTimeProducts.isEmpty, "Catalog recognition never enables either sale")
        for id in ids {
            let product = try XCTUnwrap(store.product(for: id)); XCTAssertEqual(product.type, .nonConsumable)
            var attempted = false
            await store.purchase(product, using: { _, _ in attempted = true; throw URLError(.badURL) })
            XCTAssertFalse(attempted)
            // Test harness simulates an already approved purchase, bypassing NO production policy.
            try await session.buyProduct(identifier: id)
        }
        await store.restore(); XCTAssertEqual(syncCalls, 1)
        XCTAssertTrue(store.entitlement.hasAccess); XCTAssertNil(store.entitlement.periodEnd)
        let transactions = session.allTransactions()
        let first = try XCTUnwrap(transactions.first { $0.productIdentifier == ids[0] })
        try session.refundTransaction(identifier: first.identifier)
        for _ in 0..<20 {
            await store.refresh()
            if store.entitlement.kind == .founder { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.entitlement.kind, .founder); XCTAssertTrue(store.entitlement.hasAccess)
    }
}
