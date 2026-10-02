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
    var kind: AnywhereEntitlementKind = .subscription

    static let unknown = AnywhereEntitlement(phase: .unknown)
    static let notSubscribed = AnywhereEntitlement(phase: .notSubscribed)

    /// Trial, paid, or a billing problem still inside Apple's grace period.
    var hasAccess: Bool {
        guard phase == .trial || phase == .active || phase == .gracePeriod else { return false }
        // A cached status cannot extend access past the end StoreKit already reported.
        return periodEnd.map { $0 > Date() } ?? true
    }
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

    var title: String { period == .year ? CommerceLocalization.text("PLAN_YEARLY", "Yearly") : CommerceLocalization.text("PLAN_MONTHLY", "Monthly") }
    var periodNoun: String { period == .year ? CommerceLocalization.text("PERIOD_YEAR", "year") : CommerceLocalization.text("PERIOD_MONTH", "month") }
    var hasTrial: Bool { trialPhrase != nil }
    var validPrice: Bool { price > 0 && NSDecimalNumber(decimal: price).doubleValue.isFinite && currencyCode.utf8.count == 3 && currencyCode.utf8.allSatisfy { (65...90).contains($0) } }
    var pricePhrase: String {
        period == .year ? CommerceLocalization.text("PRICE_YEAR", "%@ a year", displayPrice)
            : CommerceLocalization.text("PRICE_MONTH", "%@ a month", displayPrice)
    }
    var freeTrialPhrase: String? { trialPhrase.map { CommerceLocalization.text("FREE_TRIAL", "%@ free trial", $0) } }
    var monthlyEquivalent: String? {
        guard period == .year, validPrice else { return nil }
        return CommerceLocalization.text("PRICE_MONTH", "%@ a month", (price / 12).formatted(.currency(code: currencyCode)))
    }
    static func yearlySaving(yearly: PlanOffer?, monthly: PlanOffer?) -> Int? {
        guard let yearly, let monthly, yearly.period == .year, monthly.period == .month,
              yearly.validPrice, monthly.validPrice, yearly.currencyCode == monthly.currencyCode else { return nil }
        let full = monthly.price * 12
        let saving = NSDecimalNumber(decimal: (full - yearly.price) / full * 100).doubleValue
        return saving.isFinite && saving >= 1 && saving < 100 ? Int(saving.rounded(.down)) : nil
    }
    static func trialPhrase(unit: Calendar.Component, value: Int) -> String? {
        guard value > 0, value <= 36500 else { return nil }
        switch unit {
        case .day: return CommerceLocalization.text(value == 1 ? "TRIAL_DAY" : "TRIAL_DAYS", "%ld-day", value)
        case .weekOfYear: return CommerceLocalization.text("TRIAL_DAYS", "%ld-day", value * 7)
        case .month: return CommerceLocalization.text(value == 1 ? "TRIAL_MONTH" : "TRIAL_MONTHS", "%ld-month", value)
        case .year: return CommerceLocalization.text(value == 1 ? "TRIAL_YEAR" : "TRIAL_YEARS", "%ld-year", value)
        default: return nil
        }
    }
}

/// Words for the paywall and Home. Price, period, trial and renewal terms always appear together
/// (App Review Guideline 3.1.2(c)); nothing here is shown without the price beside it.
enum AnywhereCopy {
    static let name = "Farside Anywhere"

    static func primaryTitle(_ offer: PlanOffer?) -> String {
        guard let offer, offer.validPrice else { return CommerceLocalization.text("SUBSCRIBE", "Subscribe") }
        if let trial = offer.trialPhrase { return CommerceLocalization.text("START_TRIAL", "Start %@ free trial", trial) }
        return offer.period == .year ? CommerceLocalization.text("SUBSCRIBE_YEAR", "Subscribe for %@ a year", offer.displayPrice)
            : CommerceLocalization.text("SUBSCRIBE_MONTH", "Subscribe for %@ a month", offer.displayPrice)
    }
    static func summary(_ offer: PlanOffer) -> String {
        guard offer.validPrice else { return CommerceLocalization.text("PRICE_UNAVAILABLE", "The App Store price is unavailable. Try again before subscribing.") }
        if let trial = offer.trialPhrase {
            return offer.period == .year ? CommerceLocalization.text("SUMMARY_TRIAL_YEAR", "%@ free trial, then %@ a year. Renews automatically; cancel anytime.", trial.capitalizedFirst, offer.displayPrice)
                : CommerceLocalization.text("SUMMARY_TRIAL_MONTH", "%@ free trial, then %@ a month. Renews automatically; cancel anytime.", trial.capitalizedFirst, offer.displayPrice)
        }
        return offer.period == .year ? CommerceLocalization.text("SUMMARY_YEAR", "%@ a year. Renews automatically; cancel anytime.", offer.displayPrice)
            : CommerceLocalization.text("SUMMARY_MONTH", "%@ a month. Renews automatically; cancel anytime.", offer.displayPrice)
    }
    static func disclosure(_ offer: PlanOffer) -> String {
        guard offer.validPrice else { return summary(offer) }
        let period = offer.period == .year ? "YEAR" : "MONTH"
        let noun = offer.period == .year ? "year" : "month"
        if let trial = offer.trialPhrase {
            return CommerceLocalization.text("DISCLOSURE_TRIAL_" + period,
                "After the %@ free trial, Farside Anywhere costs %@ a " + noun + " and renews automatically until you cancel. Your Apple Account is charged when the trial ends, and again at the start of each renewal. Cancel at least 24 hours before the end of the trial in Settings › Apple Account › Subscriptions. One subscription covers up to five of your iPhones and iPads. Farside on a verified local network stays free, with or without a plan.", trial, offer.displayPrice)
        }
        return CommerceLocalization.text("DISCLOSURE_" + period,
            "Farside Anywhere costs %@ a " + noun + " and renews automatically until you cancel. Your Apple Account is charged when you confirm the purchase, and again at the start of each renewal. Cancel at least 24 hours before the end of each period in Settings › Apple Account › Subscriptions. One subscription covers up to five of your iPhones and iPads. Farside on a verified local network stays free, with or without a plan.", offer.displayPrice)
    }

    /// The service's per-subscription device cap (Backend/ENTITLEMENT-CONTRACT.md §2, check 8).
    static let deviceLimitWord = "five"

    /// Restoration recovers billing only; pairing and current route authority remain separate.
    static func refusal(_ reason: String?) -> String {
        switch reason {
        case "device_limit": return CommerceLocalization.text("REFUSAL_DEVICES", "This subscription is already in use on five devices, the most one plan covers. Verified local access still works here.")
        case "expired", "revoked": return CommerceLocalization.text("REFUSAL_ENDED", "Farside’s service says this plan is no longer active. If you just renewed, try Restore Purchases.")
        case "not_purchased": return CommerceLocalization.text("REFUSAL_OWNER", "Farside Anywhere needs a plan bought with your own Apple Account. Plans assigned by an organization or group aren’t supported. Verified local access still works.")
        case "consent_revoked": return CommerceLocalization.text("REFUSAL_CONSENT", "Permission to use Farside was withdrawn for this Apple Account, so Farside Anywhere is off.")
        default: return CommerceLocalization.text("REFUSAL_DEFAULT", "Farside’s service couldn’t confirm this plan. Try Restore Purchases; verified local access still works.")
        }
    }
    static func statusTitle(_ value: AnywhereEntitlement) -> String {
        switch value.phase {
        case .trial: CommerceLocalization.text("STATUS_TRIAL", "Your free trial is on")
        case .active: CommerceLocalization.text("STATUS_ON", "Farside Anywhere is on")
        case .gracePeriod, .billingRetry: CommerceLocalization.text("STATUS_PAYMENT", "There’s a payment problem")
        case .expired: CommerceLocalization.text("STATUS_ENDED", "Farside Anywhere has ended")
        case .revoked: CommerceLocalization.text("STATUS_REVOKED", "Farside Anywhere was refunded")
        case .unknown, .notSubscribed: name
        }
    }
    static func statusDetail(_ value: AnywhereEntitlement) -> String {
        if value.phase == .active, value.kind != .subscription {
            return CommerceLocalization.text("ONE_TIME_ACTIVE", "Your lifetime purchase has no subscription renewal. Farside’s service still verifies access; pairing and current route approval remain separate.")
        }
        let date = value.periodEnd.map(short)
        switch value.phase {
        case .trial:
            guard let date else { return CommerceLocalization.text("STATUS_REACH", "You can reach your Mac from anywhere.") }
            return value.willRenew ? CommerceLocalization.text("TRIAL_END_RENEW", "Trial ends %@. Then your plan starts unless you cancel.", date) : CommerceLocalization.text("TRIAL_END_STOP", "Trial ends %@. It won’t renew.", date)
        case .active:
            guard let date else { return CommerceLocalization.text("STATUS_REACH", "You can reach your Mac from anywhere.") }
            return value.willRenew ? CommerceLocalization.text("PLAN_RENEWS", "Renews %@.", date) : CommerceLocalization.text("PLAN_ENDS", "Ends %@. It won’t renew.", date)
        case .gracePeriod:
            return date.map { CommerceLocalization.text("GRACE_UNTIL", "Apple couldn’t renew your plan. It keeps working until %@; update your payment method in Settings › Apple Account.", $0) } ?? CommerceLocalization.text("GRACE", "Apple couldn’t renew your plan. It keeps working during the grace period; update your payment method in Settings › Apple Account.")
        case .billingRetry: return CommerceLocalization.text("BILLING_RETRY", "Apple couldn’t renew your plan, so Anywhere is paused. Update your payment method in Settings › Apple Account.")
        case .expired: return date.map { CommerceLocalization.text("EXPIRED_DATE", "It ended %@. Verified local access is still free.", $0) } ?? CommerceLocalization.text("LOCAL_FREE", "Verified local access is still free.")
        case .revoked: return CommerceLocalization.text("REVOKED_DETAIL", "Apple refunded or revoked this purchase, so Anywhere is off. Verified local access is still free.")
        case .unknown, .notSubscribed: return CommerceLocalization.text("LOCAL_AND_REMOTE", "Verified local access is free. Anywhere reaches your Mac from other networks.")
        }
    }
    static func homeCaption(_ value: AnywhereEntitlement) -> String {
        let date = value.periodEnd.map(short)
        switch value.phase {
        case .trial: return date.map { CommerceLocalization.text("CAPTION_TRIAL_END", "Trial · ends %@", $0) } ?? CommerceLocalization.text("CAPTION_TRIAL", "Trial · on")
        case .active: return date.map { value.willRenew ? CommerceLocalization.text("CAPTION_RENEW", "On · renews %@", $0) : CommerceLocalization.text("CAPTION_END", "On · ends %@", $0) } ?? CommerceLocalization.text("CAPTION_ON", "On")
        case .gracePeriod: return CommerceLocalization.text("CAPTION_GRACE", "Payment problem · still on")
        case .billingRetry: return CommerceLocalization.text("CAPTION_RETRY", "Payment problem · paused")
        case .unknown, .notSubscribed, .expired, .revoked: return CommerceLocalization.text("CAPTION_LOCAL", "Verified local access free · Anywhere off")
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
    static func canSell(configured: String?, ready: Bool = false) -> Bool {
        ready && baseURL(configured: configured, pairingServer: nil, allowDerived: false) != nil
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

    /// Set only in a build whose verification service has passed acceptance.
    static var isReady: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "FarsideServiceReady")
        return (value as? Bool) == true || (value as? String) == "YES"
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
