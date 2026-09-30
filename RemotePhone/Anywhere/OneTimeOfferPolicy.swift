import Foundation

enum AnywhereEntitlementKind: String, Equatable { case subscription, lifetime, founder }

/// Build-owned catalog. Recognizing a previously purchased benefit is independent of selling it.
/// No app preferences, QR fields or restored transactions can create an approved product entry.
struct OneTimeOfferPolicy: Equatable {
    struct Entry: Equatable {
        let kind: AnywhereEntitlementKind
        let productID: String?
        var saleEnabled = false
        var approvedPrice: Decimal?
        var currencyCode: String?
        var pricingApproval: String?
        var relayEconomicsApproval: String?
        var founderCohortApproval: String?
        var recognized: Bool {
            kind != .subscription && productID.map { id in
                !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy {
                    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
                }
            } == true
        }
        var maySell: Bool {
            guard recognized, saleEnabled, let price = approvedPrice, price > 0,
                  NSDecimalNumber(decimal: price).doubleValue.isFinite,
                  let currencyCode, currencyCode.utf8.count == 3,
                  currencyCode.utf8.allSatisfy({ (65...90).contains($0) }),
                  pricingApproval?.isEmpty == false, relayEconomicsApproval?.isEmpty == false else { return false }
            return kind != .founder || founderCohortApproval?.isEmpty == false
        }
    }
    let entries: [Entry]
    /// Both requested offers retained; all sales/product/price/cohort/economics fields unset.
    static let disabled = Self(entries: [Entry(kind: .lifetime, productID: nil), Entry(kind: .founder, productID: nil)])
    var recognizedProductIDs: [String] { validEntries.compactMap(\.productID) }
    private var validEntries: [Entry] {
        entries.filter { entry in
            entry.recognized && entries.filter { $0.productID == entry.productID }.count == 1
                && !AnywherePlan.productIDs.contains(entry.productID ?? "")
        }
    }
    func entry(for id: String) -> Entry? { validEntries.first { $0.productID == id } }
    func permitsPurchase(id: String, price: Decimal, currencyCode: String, isNonConsumable: Bool) -> Bool {
        guard let entry = entry(for: id), entry.maySell, isNonConsumable else { return false }
        return entry.approvedPrice == price && entry.currencyCode == currencyCode
    }
}

struct OneTimeEntitlementSnapshot: Equatable {
    let productID: String
    let verified: Bool
    let isNonConsumable: Bool
    let purchasedByOwner: Bool
    let revocationDate: Date?
    let signedTransaction: String?
    var purchaseDate: Date = .distantPast
}

extension AnywhereEntitlement {
    static func bestCombined(subscriptions: [SubscriptionSnapshot], oneTime: [OneTimeEntitlementSnapshot],
                             policy: OneTimeOfferPolicy, now: Date = Date()) -> (entitlement: Self, signedTransaction: String?) {
        let subscription = best(subscriptions, now: now)
        let latest = Dictionary(grouping: oneTime.filter { $0.verified && $0.isNonConsumable && $0.purchasedByOwner }, by: \.productID).values.compactMap { versions in
            versions.max { lhs, rhs in
                if lhs.purchaseDate != rhs.purchaseDate { return lhs.purchaseDate < rhs.purchaseDate }
                return lhs.revocationDate == nil && rhs.revocationDate != nil
            }
        }.sorted { $0.productID < $1.productID }
        let recognized = latest.compactMap { snapshot -> (Self, String?)? in
            guard snapshot.verified, snapshot.isNonConsumable, snapshot.purchasedByOwner,
                  let entry = policy.entry(for: snapshot.productID) else { return nil }
            return (Self(phase: snapshot.revocationDate == nil ? .active : .revoked,
                         productID: snapshot.productID, kind: entry.kind), snapshot.signedTransaction)
        }
        // A revoked one-time purchase cannot erase a surviving subscription or other one-time benefit.
        if let active = recognized.first(where: { $0.0.phase == .active }) { return active }
        if subscription.entitlement.phase != .notSubscribed { return (subscription.entitlement, subscription.snapshot?.signedTransaction) }
        if let revoked = recognized.first { return revoked }
        return (.notSubscribed, nil)
    }
}
