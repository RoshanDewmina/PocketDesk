import Foundation
import StoreKit

/// StoreKit 2 for Farside Anywhere: products, purchase, restore, the transaction listener and the
/// entitlement the rest of the app observes. Started once at launch so renewals, refunds, Ask to Buy
/// approvals and purchases made on other devices are seen.
@MainActor
final class AnywhereStore: ObservableObject {
    enum Load: Equatable { case idle, loading, loaded, failed }
    enum PurchaseState: Equatable { case idle, purchasing, pending, purchased, failed(String) }

    static let shared = AnywhereStore()

    @Published private(set) var products: [Product] = []
    @Published private(set) var load: Load = .idle
    @Published private(set) var entitlement: AnywhereEntitlement = .unknown
    @Published private(set) var trialEligible = false
    @Published private(set) var purchaseState: PurchaseState = .idle
    @Published var restoreMessage: String?
    private(set) var groupID: String?
    /// Called after the listener sees a transaction, so the service hears about renewals and refunds.
    var onTransactionUpdate: (() -> Void)?

    private let productIDs: [String]
    private let accountToken: () -> UUID?
    private let serviceAvailable: () -> Bool
    private let sync: () async throws -> Void
    private var signedTransactionValue: String?
    private var listeners: [Task<Void, Never>] = []
    private var expiryRefresh: Task<Void, Never>?

    init(productIDs: [String] = AnywherePlan.productIDs,
         accountToken: @escaping () -> UUID? = { InstallIdentity.current()?.accountToken },
         serviceAvailable: @escaping () -> Bool = { AnywhereService.canSell(configured: AnywhereService.configured) },
         sync: @escaping () async throws -> Void = { try await AppStore.sync() }) {
        self.productIDs = productIDs
        self.accountToken = accountToken
        self.serviceAvailable = serviceAvailable
        self.sync = sync
    }

    func start() {
        guard listeners.isEmpty else { return }
        listeners.append(Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                guard let self else { return }
                await self.refresh()
                self.onTransactionUpdate?()
            }
        })
        listeners.append(Task { [weak self] in
            // Grace period and billing retry can change without a new transaction.
            for await _ in Product.SubscriptionInfo.Status.updates {
                guard let self else { return }
                await self.refresh()
            }
        })
        Task {
            for await result in Transaction.unfinished {
                if case .verified(let transaction) = result, productIDs.contains(transaction.productID) { await transaction.finish() }
            }
            await loadProducts()
            await refresh()
        }
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        expiryRefresh?.cancel()
        expiryRefresh = nil
    }

    var offers: [PlanOffer] { products.compactMap { PlanOffer(product: $0, trialEligible: trialEligible) } }
    var canSell: Bool { serviceAvailable() }

    func product(for id: String) -> Product? { products.first { $0.id == id } }

    func loadProducts() async {
        load = .loading
        do {
            let loaded = try await Product.products(for: productIDs)
            products = loaded.sorted { (productIDs.firstIndex(of: $0.id) ?? 0) < (productIDs.firstIndex(of: $1.id) ?? 0) }
            if let group = loaded.compactMap(\.subscription?.subscriptionGroupID).first { groupID = group }
            load = loaded.isEmpty ? .failed : .loaded
            await updateTrialEligibility()
        } catch {
            load = .failed
        }
    }

    /// Re-reads the subscription group's status from StoreKit.
    func refresh() async {
        if groupID == nil { groupID = await groupIDFromHistory() }
        var snapshots: [SubscriptionSnapshot] = []
        if let groupID, let statuses = try? await Product.SubscriptionInfo.status(for: groupID) {
            snapshots = statuses.map(SubscriptionSnapshot.init)
        }
        let best = AnywhereEntitlement.best(snapshots)
        signedTransactionValue = best.entitlement.hasAccess ? best.snapshot?.signedTransaction : nil
        if entitlement != best.entitlement { entitlement = best.entitlement }
        scheduleExpiryRefresh()
        await updateTrialEligibility()
    }

    /// The signed transaction the service verifies, only while this phone believes there is access.
    func signedTransaction() async -> String? {
        if signedTransactionValue == nil && entitlement.hasAccess { await refresh() }
        return entitlement.hasAccess ? signedTransactionValue : nil
    }

    typealias PurchaseAction = (Product, Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult

    /// Buys through SwiftUI's purchase action when the paywall provides one (it knows the scene).
    func purchase(_ product: Product, using action: PurchaseAction? = nil) async {
        guard canSell else {
            purchaseState = .failed("Farside Anywhere is temporarily unavailable. We can’t confirm a new purchase right now. Restore Purchases remains available.")
            return
        }
        // Verification links the Apple transaction to this install. A locked Keychain must not
        // initiate a charge that this phone could not subsequently prove to the service.
        guard let token = accountToken() else {
            purchaseState = .failed("This iPhone couldn’t prepare a secure purchase. Unlock it and try again, or restore an existing plan.")
            return
        }
        purchaseState = .purchasing
        let options: Set<Product.PurchaseOption> = [.appAccountToken(token)]
        do {
            let result: Product.PurchaseResult
            if let action { result = try await action(product, options) }
            else { result = try await product.purchase(options: options) }
            switch result {
            case .success(.verified(let transaction)):
                await transaction.finish()
                await refresh()
                purchaseState = .purchased
            case .success(.unverified):
                purchaseState = .failed("The App Store couldn’t verify this purchase. You weren’t given Anywhere; try Restore Purchases.")
            case .pending:
                purchaseState = .pending
            case .userCancelled:
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch StoreKitError.userCancelled {
            purchaseState = .idle
        } catch {
            purchaseState = .failed("The purchase didn’t go through. Nothing was charged. Try again in a moment.")
        }
    }

    /// Only from an explicit tap: `AppStore.sync()` can ask the person to sign in.
    func restore() async {
        restoreMessage = nil
        do {
            try await sync()
            // A StoreKit Test purchase made outside the app can reach subscription status just
            // after sync returns. Give that same eventual propagation a short chance on device,
            // so Restore does not claim "no subscription" while one is arriving.
            for attempt in 0..<10 {
                await refresh()
                if entitlement.hasAccess || Task.isCancelled { break }
                if attempt < 9 { try? await Task.sleep(for: .milliseconds(200)) }
            }
            restoreMessage = entitlement.hasAccess
                ? "Farside Anywhere is back on."
                : "No Farside Anywhere subscription was found for this Apple Account."
        } catch StoreKitError.userCancelled {
            return
        } catch {
            restoreMessage = "Couldn’t reach the App Store. Check your connection and try again."
        }
    }

    func resetPurchaseState() { purchaseState = .idle }

    private func scheduleExpiryRefresh() {
        expiryRefresh?.cancel()
        expiryRefresh = nil
        guard entitlement.hasAccess, let end = entitlement.periodEnd else { return }
        // Reconcile again at the known boundary even if StoreKit emits no update. Long periods
        // are checked daily so a sleeping app does not rely on a single week-long timer.
        let delay = min(max(end.timeIntervalSinceNow + 0.1, 0.1), 86_400)
        expiryRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.expiryRefresh = nil
            await self.refresh()
            self.onTransactionUpdate?()
        }
    }

    private func updateTrialEligibility() async {
        guard let groupID else { trialEligible = false; return }
        trialEligible = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: groupID)
    }

    private func groupIDFromHistory() async -> String? {
        for id in productIDs {
            if case .verified(let transaction)? = await Transaction.latest(for: id), let group = transaction.subscriptionGroupID {
                return group
            }
        }
        return nil
    }
}

extension SubscriptionSnapshot {
    init(_ status: Product.SubscriptionInfo.Status) {
        let transaction: Transaction
        let verified: Bool
        switch status.transaction {
        case .verified(let value): transaction = value; verified = true
        case .unverified(let value, _): transaction = value; verified = false
        }
        var renewalInfo: Product.SubscriptionInfo.RenewalInfo?
        if case .verified(let value) = status.renewalInfo { renewalInfo = value }
        let renewal: Renewal
        switch status.state {
        case .subscribed: renewal = .subscribed
        case .inGracePeriod: renewal = .gracePeriod
        case .inBillingRetryPeriod: renewal = .billingRetry
        case .expired: renewal = .expired
        case .revoked: renewal = .revoked
        default: renewal = .unknown
        }
        self.init(renewal: renewal, productID: transaction.productID, expirationDate: transaction.expirationDate,
                  revocationDate: transaction.revocationDate, isFreeTrial: transaction.offer?.paymentMode == .freeTrial,
                  willAutoRenew: renewalInfo?.willAutoRenew ?? false,
                  gracePeriodExpirationDate: renewalInfo?.gracePeriodExpirationDate,
                  verified: verified, signedTransaction: status.transaction.jwsRepresentation)
    }
}

extension PlanOffer {
    init?(product: Product, trialEligible: Bool) {
        guard let subscription = product.subscription else { return nil }
        let unit = subscription.subscriptionPeriod.unit
        guard unit == .year || unit == .month else { return nil }
        var trial: String?
        if trialEligible, let intro = subscription.introductoryOffer, intro.paymentMode == .freeTrial {
            let component: Calendar.Component
            switch intro.period.unit {
            case .day: component = .day
            case .week: component = .weekOfYear
            case .month: component = .month
            case .year: component = .year
            @unknown default: component = .day
            }
            trial = PlanOffer.trialPhrase(unit: component, value: intro.period.value * max(1, intro.periodCount))
        }
        self.init(id: product.id, period: unit == .year ? .year : .month, displayPrice: product.displayPrice,
                  price: product.price, currencyCode: product.priceFormatStyle.currencyCode, trialPhrase: trial)
    }
}
