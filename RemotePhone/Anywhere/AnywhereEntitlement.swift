import Foundation

/// Farside Anywhere: the paid plan that reaches the Mac from another network (PRODUCT D28).
/// Product ids follow Docs/launch/SUBSCRIPTION-SETUP.md; the display names live in App Store Connect.
enum AnywherePlan {
    static let yearlyID = "com.roshan.PocketDesk.remote.yearly"
    static let monthlyID = "com.roshan.PocketDesk.remote.monthly"
    /// Display order: yearly first, the default choice.
    static let productIDs = [yearlyID, monthlyID]

    static var termsURL: URL { infoURL("FarsideTermsURL") ?? URL(string: "https://getfarside.com/terms")! }
    static var privacyURL: URL { infoURL("FarsidePrivacyURL") ?? URL(string: "https://getfarside.com/privacy")! }

    static func infoURL(_ key: String, bundle: Bundle = .main) -> URL? {
        guard let text = bundle.object(forInfoDictionaryKey: key) as? String, !text.isEmpty,
              let url = URL(string: text), url.scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// One subscription status as StoreKit reported it, reduced to what access depends on.
struct SubscriptionSnapshot: Equatable {
    enum Renewal: Equatable { case subscribed, expired, billingRetry, gracePeriod, revoked, unknown }

    var renewal: Renewal
    var productID: String
    var expirationDate: Date?
    var revocationDate: Date?
    var isFreeTrial = false
    var willAutoRenew = false
    var gracePeriodExpirationDate: Date?
    /// StoreKit's own signature check. An unverified status never grants anything on this phone.
    var verified = true
    /// `jwsRepresentation` of the status's transaction, which the service verifies.
    var signedTransaction: String?
}

/// What the phone believes about Farside Anywhere. The service has the final word (it issues relay
/// credentials only after verifying the signed transaction); this drives the app's UI and decides
/// whether asking the service is worth it.
struct AnywhereEntitlement: Equatable {
    enum Phase: Equatable { case unknown, notSubscribed, trial, active, gracePeriod, billingRetry, expired, revoked }

    var phase: Phase
    var productID: String?
    /// Trial end, renewal or expiry date, or the end of the billing grace period.
    var periodEnd: Date?
    var willRenew = false

    static let unknown = AnywhereEntitlement(phase: .unknown)
    static let notSubscribed = AnywhereEntitlement(phase: .notSubscribed)

    /// Trial, paid, or a billing problem still inside Apple's grace period.
    var hasAccess: Bool { phase == .trial || phase == .active || phase == .gracePeriod }
    var hasBillingProblem: Bool { phase == .gracePeriod || phase == .billingRetry }

    static func resolve(_ snapshots: [SubscriptionSnapshot], now: Date = Date()) -> AnywhereEntitlement {
        best(snapshots, now: now).entitlement
    }

    /// The strongest status in the group, and the snapshot it came from (for its signed transaction).
    static func best(_ snapshots: [SubscriptionSnapshot], now: Date = Date()) -> (entitlement: AnywhereEntitlement, snapshot: SubscriptionSnapshot?) {
        let ranked = snapshots
            .filter { $0.verified && AnywherePlan.productIDs.contains($0.productID) }
            .map { (entitlement: entitlement(for: $0, now: now), snapshot: $0) }
        guard let top = ranked.max(by: { rank($0.entitlement) < rank($1.entitlement) }) else { return (.notSubscribed, nil) }
        return (top.entitlement, top.snapshot)
    }

    private static func entitlement(for status: SubscriptionSnapshot, now: Date) -> AnywhereEntitlement {
        let product = status.productID
        if status.revocationDate != nil { return AnywhereEntitlement(phase: .revoked, productID: product) }
        switch status.renewal {
        case .subscribed:
            guard let end = status.expirationDate, end > now else {
                return AnywhereEntitlement(phase: .expired, productID: product, periodEnd: status.expirationDate)
            }
            return AnywhereEntitlement(phase: status.isFreeTrial ? .trial : .active, productID: product,
                                       periodEnd: end, willRenew: status.willAutoRenew)
        case .gracePeriod:
            guard let end = status.gracePeriodExpirationDate, end > now else {
                return AnywhereEntitlement(phase: .billingRetry, productID: product)
            }
            return AnywhereEntitlement(phase: .gracePeriod, productID: product,
                                       periodEnd: end, willRenew: status.willAutoRenew)
        case .billingRetry:
            return AnywhereEntitlement(phase: .billingRetry, productID: product)
        case .revoked:
            return AnywhereEntitlement(phase: .revoked, productID: product)
        case .expired, .unknown:
            return AnywhereEntitlement(phase: .expired, productID: product, periodEnd: status.expirationDate)
        }
    }

    private static func rank(_ value: AnywhereEntitlement) -> (Int, Date) {
        let order: Int
        switch value.phase {
        case .active, .trial: order = 5
        case .gracePeriod: order = 4
        case .billingRetry: order = 3
        case .expired: order = 2
        case .revoked: order = 1
        case .unknown, .notSubscribed: order = 0
        }
        return (order, value.periodEnd ?? .distantPast)
    }
}

/// A plan as the paywall shows it, built from a StoreKit product (or fixed values in tests).
struct PlanOffer: Identifiable, Equatable {
    enum Period: Equatable { case month, year }

    let id: String
    let period: Period
    let displayPrice: String
    let price: Decimal
    let currencyCode: String
    /// "7-day" or "1-month", only when this person is eligible for a configured free trial.
    var trialPhrase: String?

    var title: String { period == .year ? "Yearly" : "Monthly" }
    var periodNoun: String { period == .year ? "year" : "month" }
    var hasTrial: Bool { trialPhrase != nil }

    /// "CA$4.17 a month" for the yearly plan.
    var monthlyEquivalent: String? {
        guard period == .year else { return nil }
        let perMonth = price / 12
        return perMonth.formatted(.currency(code: currencyCode)) + " a month"
    }

    /// Whole-percent saving of yearly over twelve monthly payments, if it is real.
    static func yearlySaving(yearly: PlanOffer?, monthly: PlanOffer?) -> Int? {
        guard let yearly, let monthly, monthly.price > 0 else { return nil }
        let full = monthly.price * 12
        let saving = NSDecimalNumber(decimal: (full - yearly.price) / full * 100).doubleValue
        return saving >= 1 ? Int(saving.rounded(.down)) : nil
    }

    /// A free trial described the way people say it: 7 days reads as "7-day", 1 month as "1-month".
    static func trialPhrase(unit: Calendar.Component, value: Int) -> String? {
        guard value > 0 else { return nil }
        switch unit {
        case .day: return "\(value)-day"
        case .weekOfYear: return "\(value * 7)-day"
        case .month: return "\(value)-month"
        case .year: return "\(value)-year"
        default: return nil
        }
    }
}

/// Words for the paywall and Home. Price, period, trial and renewal terms always appear together
/// (App Review Guideline 3.1.2(c)); nothing here is shown without the price beside it.
enum AnywhereCopy {
    static let name = "Farside Anywhere"

    static func primaryTitle(_ offer: PlanOffer?) -> String {
        guard let offer else { return "Subscribe" }
        if let trial = offer.trialPhrase { return "Start \(trial) free trial" }
        return "Subscribe for \(offer.displayPrice) a \(offer.periodNoun)"
    }

    /// The line kept next to the button: what you pay and when.
    static func summary(_ offer: PlanOffer) -> String {
        if let trial = offer.trialPhrase {
            return "\(trial.capitalizedFirst) free trial, then \(offer.displayPrice) a \(offer.periodNoun). Renews automatically; cancel anytime."
        }
        return "\(offer.displayPrice) a \(offer.periodNoun). Renews automatically; cancel anytime."
    }

    static func disclosure(_ offer: PlanOffer) -> String {
        let start = offer.trialPhrase.map { "After the \($0) free trial, \(name) costs " } ?? "\(name) costs "
        let charged = offer.hasTrial
            ? "Your Apple Account is charged when the trial ends"
            : "Your Apple Account is charged when you confirm the purchase"
        let window = offer.hasTrial ? "the trial" : "each period"
        return start + "\(offer.displayPrice) a \(offer.periodNoun) and renews automatically until you cancel. "
            + "\(charged), and again at the start of each renewal. "
            + "Cancel at least 24 hours before the end of \(window) in Settings › Apple Account › Subscriptions. "
            + "One subscription covers up to \(deviceLimitWord) of your iPhones and iPads. "
            + "Farside on the same Wi-Fi stays free, with or without a plan."
    }

    /// The service's per-subscription device cap (Backend/ENTITLEMENT-CONTRACT.md §2, check 8).
    static let deviceLimitWord = "three"

    /// Why the service would not confirm a plan this phone believes in.
    static func refusal(_ reason: String?) -> String {
        switch reason {
        case "device_limit":
            return "This subscription is already in use on \(deviceLimitWord) devices, the most one plan covers. Same Wi-Fi still works here."
        case "expired", "revoked":
            return "Farside’s service says this plan is no longer active. If you just renewed, try Restore Purchases."
        default:
            return "Farside’s service couldn’t confirm this plan. Try Restore Purchases; same Wi-Fi still works."
        }
    }

    static func statusTitle(_ value: AnywhereEntitlement) -> String {
        switch value.phase {
        case .trial: "Your free trial is on"
        case .active: "\(name) is on"
        case .gracePeriod, .billingRetry: "There’s a payment problem"
        case .expired: "\(name) has ended"
        case .revoked: "\(name) was refunded"
        case .unknown, .notSubscribed: name
        }
    }

    static func statusDetail(_ value: AnywhereEntitlement) -> String {
        let date = value.periodEnd.map(short)
        switch value.phase {
        case .trial:
            guard let date else { return "You can reach your Mac from anywhere." }
            return value.willRenew ? "Trial ends \(date). Then your plan starts unless you cancel." : "Trial ends \(date). It won’t renew."
        case .active:
            guard let date else { return "You can reach your Mac from anywhere." }
            return value.willRenew ? "Renews \(date)." : "Ends \(date). It won’t renew."
        case .gracePeriod:
            let until = date.map { " until \($0)" } ?? ""
            return "Apple couldn’t renew your plan. It keeps working\(until); update your payment method in Settings › Apple Account."
        case .billingRetry:
            return "Apple couldn’t renew your plan, so Anywhere is paused. Update your payment method in Settings › Apple Account."
        case .expired:
            return date.map { "It ended \($0). Farside on the same Wi-Fi is still free." } ?? "Farside on the same Wi-Fi is still free."
        case .revoked:
            return "Apple refunded or revoked this purchase, so Anywhere is off. Farside on the same Wi-Fi is still free."
        case .unknown, .notSubscribed:
            return "Free on the same Wi-Fi. Anywhere reaches your Mac from any network."
        }
    }

    /// The caption under "Farside Anywhere" on Home.
    static func homeCaption(_ value: AnywhereEntitlement) -> String {
        let date = value.periodEnd.map(short)
        switch value.phase {
        case .trial: return date.map { "Trial · ends \($0)" } ?? "Trial · on"
        case .active: return date.map { value.willRenew ? "On · renews \($0)" : "On · ends \($0)" } ?? "On"
        case .gracePeriod: return "Payment problem · still on"
        case .billingRetry: return "Payment problem · paused"
        case .unknown, .notSubscribed, .expired, .revoked: return "Free on the same Wi-Fi · Anywhere off"
        }
    }

    static func short(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Where the phone asks the service about a subscription.
enum AnywhereService {
    /// Never start a paid checkout unless the build names the service that can verify it.
    /// A debug pairing-derived endpoint is useful for development, but is not a purchase target.
    static func canSell(configured: String?) -> Bool {
        baseURL(configured: configured, pairingServer: nil, allowDerived: false) != nil
    }

    /// The configured production address wins. Without one, debug builds use the paired Mac's own
    /// signaling service (wss → https); release builds never send a signed transaction to an address
    /// that arrived in a pairing code.
    static func baseURL(configured: String?, pairingServer: String?, allowDerived: Bool) -> URL? {
        if let configured, let url = URL(string: configured.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))),
           url.scheme == "https", url.host?.isEmpty == false {
            return url
        }
        guard allowDerived, let pairingServer, PairInvitation.validServer(pairingServer),
              var components = URLComponents(string: pairingServer) else { return nil }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = ""
        return components.url
    }

    static var configured: String? { Bundle.main.object(forInfoDictionaryKey: "FarsideServiceBaseURL") as? String }

    static var allowsDerived: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
