import XCTest
@testable import PocketDeskRemote

final class OneTimeOfferTests: XCTestCase {
    private let lifetime = "test.farside.one-time.lifetime", founder = "test.farside.one-time.founder"
    private var policy: OneTimeOfferPolicy { .init(entries: [.init(kind: .lifetime, productID: lifetime), .init(kind: .founder, productID: founder)]) }
    private func snapshot(_ id: String, revoked: Bool = false, verified: Bool = true, purchased: Bool = true) -> OneTimeEntitlementSnapshot {
        .init(productID: id, verified: verified, isNonConsumable: true, purchasedByOwner: purchased,
              revocationDate: revoked ? Date() : nil, signedTransaction: "fixture-" + id)
    }
    func testBothAbsentEconomicsAndProductsCannotSellOrRecognizeUnknownPurchase() {
        XCTAssertEqual(OneTimeOfferPolicy.disabled.entries.map(\.kind), [.lifetime, .founder])
        XCTAssertTrue(OneTimeOfferPolicy.disabled.recognizedProductIDs.isEmpty)
        XCTAssertFalse(policy.entries[0].maySell)
        XCTAssertEqual(AnywhereEntitlement.bestCombined(subscriptions: [], oneTime: [snapshot(lifetime)], policy: .disabled).entitlement.phase, .notSubscribed)
        XCTAssertFalse(policy.permitsPurchase(id: lifetime, price: 1, currencyCode: "CAD", isNonConsumable: true))
    }
    func testEconomicPriceTypeAndFounderCohortAllRequiredForPurchase() {
        var entry = OneTimeOfferPolicy.Entry(kind: .founder, productID: founder, saleEnabled: true,
            approvedPrice: 1, currencyCode: "CAD", pricingApproval: "TEST ONLY", relayEconomicsApproval: "TEST ONLY")
        XCTAssertFalse(entry.maySell)
        entry.founderCohortApproval = "TEST ONLY cohort"; XCTAssertTrue(entry.maySell)
        let selling = OneTimeOfferPolicy(entries: [entry])
        XCTAssertTrue(selling.permitsPurchase(id: founder, price: 1, currencyCode: "CAD", isNonConsumable: true))
        XCTAssertFalse(selling.permitsPurchase(id: founder, price: 2, currencyCode: "CAD", isNonConsumable: true))
        XCTAssertFalse(selling.permitsPurchase(id: founder, price: 1, currencyCode: "USD", isNonConsumable: true))
        XCTAssertFalse(selling.permitsPurchase(id: founder, price: 1, currencyCode: "CAD", isNonConsumable: false))
        XCTAssertTrue(OneTimeOfferPolicy(entries: [entry, entry]).recognizedProductIDs.isEmpty)
    }
    func testDisabledSaleDoesNotRevokeAlreadyVerifiedLifetimeOrFounderRights() {
        for (id, kind) in [(lifetime, AnywhereEntitlementKind.lifetime), (founder, .founder)] {
            let value = AnywhereEntitlement.bestCombined(subscriptions: [], oneTime: [snapshot(id)], policy: policy)
            XCTAssertEqual(value.entitlement.kind, kind); XCTAssertTrue(value.entitlement.hasAccess)
            XCTAssertNil(value.entitlement.periodEnd); XCTAssertFalse(value.entitlement.willRenew)
            XCTAssertEqual(value.signedTransaction, "fixture-" + id)
        }
    }
    func testRefundKeepsSurvivingSubscriptionOrOtherOneTimeBenefit() {
        let sub = SubscriptionSnapshot(renewal: .subscribed, productID: AnywherePlan.monthlyID,
            expirationDate: .distantFuture, signedTransaction: "subscription")
        let mixed = AnywhereEntitlement.bestCombined(subscriptions: [sub], oneTime: [snapshot(lifetime, revoked: true)], policy: policy)
        XCTAssertEqual(mixed.entitlement.kind, .subscription); XCTAssertTrue(mixed.entitlement.hasAccess)
        XCTAssertEqual(mixed.signedTransaction, "subscription")
        let other = AnywhereEntitlement.bestCombined(subscriptions: [], oneTime: [snapshot(lifetime, revoked: true), snapshot(founder)], policy: policy)
        XCTAssertEqual(other.entitlement.kind, .founder); XCTAssertTrue(other.entitlement.hasAccess)
        let refunded = AnywhereEntitlement.bestCombined(subscriptions: [], oneTime: [snapshot(lifetime), snapshot(lifetime, revoked: true)], policy: policy)
        XCTAssertEqual(refunded.entitlement.phase, .revoked); XCTAssertFalse(refunded.entitlement.hasAccess)
    }
    func testUnverifiedForeignAssignedAndWrongTypeNeverRestoreBenefit() {
        var wrongType = snapshot(lifetime); wrongType = .init(productID: lifetime, verified: true, isNonConsumable: false, purchasedByOwner: true, revocationDate: nil, signedTransaction: "wrong")
        for value in [snapshot(lifetime, verified: false), snapshot(lifetime, purchased: false), snapshot("unknown"), wrongType] {
            XCTAssertEqual(AnywhereEntitlement.bestCombined(subscriptions: [], oneTime: [value], policy: policy).entitlement.phase, .notSubscribed)
        }
    }
}
