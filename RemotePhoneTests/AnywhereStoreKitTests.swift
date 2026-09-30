import StoreKit
import StoreKitTest
import SwiftUI
import XCTest
@testable import PocketDeskRemote

/// The store against Xcode's local StoreKit test environment (StoreKitTesting/FarsideAnywhere.storekit):
/// real products, purchases, renewals, expiry, refunds, grace period, billing retry and restore.
@MainActor
final class AnywhereStoreKitTests: XCTestCase {
    private var session: SKTestSession!
    private var store: AnywhereStore!
    private let accountToken = UUID(uuidString: "6B1F2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
    private var syncCalls = 0

    override func setUp() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "FarsideAnywhere", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        let token = accountToken
        store = AnywhereStore(accountToken: { token }, serviceAvailable: { true },
                              sync: { [unowned self] in self.syncCalls += 1 })
        // The test environment can answer the very first request before the session is ready.
        for _ in 0..<10 where store.load != .loaded {
            await store.loadProducts()
            if store.load != .loaded { try await Task.sleep(for: .milliseconds(300)) }
        }
        XCTAssertEqual(store.load, .loaded, "The StoreKit test configuration did not load")
    }

    override func tearDown() async throws {
        store.stop()
        session.clearTransactions()
        session.resetToDefaultState()
    }

    private var yearly: Product { get throws { try XCTUnwrap(store.product(for: AnywherePlan.yearlyID)) } }
    private var monthly: Product { get throws { try XCTUnwrap(store.product(for: AnywherePlan.monthlyID)) } }

    /// StoreKit's test environment settles asynchronously; re-read until the condition holds.
    private func eventually(_ what: String, timeout: TimeInterval = 8, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await store.refresh()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Timed out waiting for \(what); entitlement is \(store.entitlement)")
    }

    func testProductsLoadInOrderWithPricesAndTrial() async throws {
        XCTAssertEqual(store.products.map(\.id), [AnywherePlan.yearlyID, AnywherePlan.monthlyID])
        for product in [try yearly, try monthly] {
            let subscription = try XCTUnwrap(product.subscription)
            XCTAssertEqual(subscription.subscriptionGroupID, store.groupID, "Both plans share one group")
            let intro = try XCTUnwrap(subscription.introductoryOffer, "\(product.id) has a free trial configured")
            XCTAssertEqual(intro.paymentMode, .freeTrial)
            XCTAssertEqual(intro.period, .weekly)
            XCTAssertEqual(PlanOffer(product: product, trialEligible: true)?.trialPhrase, "7-day")
            XCTAssertNil(PlanOffer(product: product, trialEligible: false)?.trialPhrase, "No trial wording without eligibility")
        }
        XCTAssertEqual(try yearly.subscription?.subscriptionPeriod, .yearly)
        XCTAssertEqual(try monthly.subscription?.subscriptionPeriod, .monthly)
        let offers = store.offers
        XCTAssertEqual(offers.map(\.period), [.year, .month])
        XCTAssertTrue(offers[0].displayPrice.contains("59.99"), offers[0].displayPrice)
        XCTAssertTrue(offers[1].displayPrice.contains("7.99"), offers[1].displayPrice)
        XCTAssertEqual(offers.map(\.currencyCode), ["CAD", "CAD"])
        XCTAssertEqual(PlanOffer.yearlySaving(yearly: offers[0], monthly: offers[1]), 37)
        XCTAssertEqual(store.entitlement.phase, .unknown, "Nothing read yet")
    }

    /// Named to run first: StoreKit caches introductory-offer eligibility for the process, and
    /// `SKTestSession.clearTransactions()` does not reset that cache after an earlier test's trial.
    func testAFreshCustomerIsOfferedTheTrial() async {
        await store.refresh()
        XCTAssertEqual(store.entitlement.phase, .notSubscribed)
        XCTAssertTrue(store.trialEligible)
        XCTAssertEqual(store.offers.map(\.trialPhrase), ["7-day", "7-day"])
        let yearlyOffer = store.offers[0]
        XCTAssertEqual(AnywhereCopy.primaryTitle(yearlyOffer), "Start 7-day free trial")
        XCTAssertTrue(AnywhereCopy.summary(yearlyOffer).hasPrefix("7-day free trial, then "), AnywhereCopy.summary(yearlyOffer))
    }

    func testPurchaseStartsTheTrialWithTheInstallToken() async throws {
        await store.refresh()
        XCTAssertEqual(store.entitlement.phase, .notSubscribed)
        await store.purchase(try yearly)
        XCTAssertEqual(store.purchaseState, .purchased)
        XCTAssertEqual(store.entitlement.phase, .trial)
        XCTAssertTrue(store.entitlement.hasAccess)
        XCTAssertEqual(store.entitlement.productID, AnywherePlan.yearlyID)
        let signed = await store.signedTransaction()
        XCTAssertEqual(signed?.split(separator: ".").count, 3, "A compact JWS for the service")
        guard case .verified(let transaction)? = await Transaction.latest(for: AnywherePlan.yearlyID) else { return XCTFail("no transaction") }
        XCTAssertEqual(transaction.appAccountToken, accountToken)
        XCTAssertEqual(transaction.offer?.paymentMode, .freeTrial)
        XCTAssertFalse(store.trialEligible, "One introductory offer per subscription group")
        XCTAssertFalse(store.offers.contains(where: \.hasTrial), "The paywall stops promising a trial")
    }

    func testLockedInstallIdentityCannotStartPurchaseButRestoreStillWorks() async throws {
        var restoreCalls = 0
        var purchaseCalled = false
        let blocked = AnywhereStore(accountToken: { nil }, serviceAvailable: { true }, sync: { restoreCalls += 1 })
        await blocked.purchase(try yearly, using: { _, _ in
            purchaseCalled = true
            throw URLError(.badURL)
        })
        XCTAssertFalse(purchaseCalled, "Never charge without a stable install account token")
        if case .failed(let message) = blocked.purchaseState {
            XCTAssertTrue(message.contains("secure purchase"), message)
        } else {
            XCTFail("The purchase should explain why it could not start")
        }
        await blocked.restore()
        XCTAssertEqual(restoreCalls, 1, "An existing purchase remains restorable without a new purchase identity")
    }

    func testUnconfiguredServiceCannotStartPurchaseButRestoreStillWorks() async throws {
        var restoreCalls = 0
        var purchaseCalled = false
        let blocked = AnywhereStore(accountToken: { self.accountToken }, serviceAvailable: { false },
                                    sync: { restoreCalls += 1 })
        await blocked.purchase(try yearly, using: { _, _ in
            purchaseCalled = true
            throw URLError(.badURL)
        })
        XCTAssertFalse(purchaseCalled, "No service means no charge even if a caller bypasses the paywall")
        if case .failed(let message) = blocked.purchaseState {
            XCTAssertTrue(message.contains("temporarily unavailable"), message)
        } else {
            XCTFail("The purchase should explain why it could not start")
        }
        await blocked.restore()
        XCTAssertEqual(restoreCalls, 1)
    }

    func testRenewalAfterTheTrialIsPaid() async throws {
        await store.purchase(try monthly)
        XCTAssertEqual(store.entitlement.phase, .trial)
        try session.forceRenewalOfSubscription(productIdentifier: AnywherePlan.monthlyID)
        await eventually("a paid renewal") { store.entitlement.phase == .active }
        XCTAssertTrue(store.entitlement.willRenew)
    }

    func testExpiryEndsAccessAndTheSignedTransaction() async throws {
        // Match the app's transaction/status listener lifecycle while exercising StoreKitTest.
        store.start()
        session.timeRate = .oneRenewalEveryTwoSeconds
        await store.purchase(try monthly)
        guard case .verified(let transaction)? = await Transaction.latest(for: AnywherePlan.monthlyID) else { return XCTFail("no transaction") }
        try session.disableAutoRenewForTransaction(identifier: UInt(transaction.id))
        await eventually("expiry", timeout: 15) { store.entitlement.phase == .expired }
        XCTAssertFalse(store.entitlement.hasAccess)
        let signed = await store.signedTransaction()
        XCTAssertNil(signed, "Nothing is sent to the service without access")
    }

    func testKnownEndRefreshesWithoutAStoreKitListenerOrCallerPolling() async throws {
        session.timeRate = .oneRenewalEveryTwoSeconds
        var boundaryCallbacks = 0
        store.onTransactionUpdate = { boundaryCallbacks += 1 }
        try await session.buyProduct(identifier: AnywherePlan.monthlyID)
        await eventually("initial external purchase") { store.entitlement.hasAccess }
        XCTAssertTrue(store.entitlement.hasAccess)
        guard case .verified(let transaction)? = await Transaction.latest(for: AnywherePlan.monthlyID) else { return XCTFail("no transaction") }
        try session.disableAutoRenewForTransaction(identifier: UInt(transaction.id))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, store.entitlement.phase != .expired {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(store.entitlement.phase, .expired, "The end-date timer reconciles status without a listener or caller refresh")
        XCTAssertFalse(store.entitlement.hasAccess)
        let signed = await store.signedTransaction()
        XCTAssertNil(signed)
        XCTAssertEqual(boundaryCallbacks, 1, "The boundary produces one service refresh without a timer loop")
    }

    func testRefundRevokesAccess() async throws {
        await store.purchase(try yearly)
        guard case .verified(let transaction)? = await Transaction.latest(for: AnywherePlan.yearlyID) else { return XCTFail("no transaction") }
        try session.refundTransaction(identifier: UInt(transaction.id))
        await eventually("revocation") { !store.entitlement.hasAccess }
        XCTAssertTrue([.revoked, .notSubscribed].contains(store.entitlement.phase), "\(store.entitlement.phase)")
    }

    func testGracePeriodKeepsAccessWithAPaymentNotice() async throws {
        session.billingGracePeriodIsEnabled = true
        session.shouldEnterBillingRetryOnRenewal = true
        await store.purchase(try monthly)
        try session.forceRenewalOfSubscription(productIdentifier: AnywherePlan.monthlyID)
        await eventually("grace period") { store.entitlement.phase == .gracePeriod }
        XCTAssertTrue(store.entitlement.hasAccess)
        XCTAssertTrue(store.entitlement.hasBillingProblem)
        XCTAssertEqual(AnywhereCopy.homeCaption(store.entitlement), "Payment problem · still on")
    }

    func testBillingRetryWithoutGraceEndsAccess() async throws {
        session.billingGracePeriodIsEnabled = false
        session.shouldEnterBillingRetryOnRenewal = true
        await store.purchase(try monthly)
        try session.forceRenewalOfSubscription(productIdentifier: AnywherePlan.monthlyID)
        await eventually("billing retry") { store.entitlement.phase == .billingRetry }
        XCTAssertFalse(store.entitlement.hasAccess)
    }

    func testRestoreFindsAPurchaseMadeOnAnotherDevice() async throws {
        try await session.buyProduct(identifier: AnywherePlan.yearlyID)
        await store.restore()
        XCTAssertEqual(syncCalls, 1, "Restore asks the App Store to sync")
        await eventually("restored access") { store.entitlement.hasAccess }
        XCTAssertEqual(store.restoreMessage, "Purchase restored. Farside’s service will confirm your plan next. Restoring does not pair a Mac or grant control.")
    }

    func testRestoreWithNothingToRestoreSaysSo() async {
        await store.restore()
        XCTAssertEqual(store.restoreMessage, "Couldn’t confirm an active Farside Anywhere subscription yet. Check your Apple Account and try Restore Purchases again.")
    }

    /// Stands in for the iOS 27 offer-code sheet, which hands back the same `VerificationResult<Transaction>`.
    func testARedeemedTransactionIsFinishedAndReadyForTheServiceAtOnce() async throws {
        await store.refresh()
        XCTAssertFalse(store.entitlement.hasAccess)
        guard case .success(let verification) = try await monthly.purchase() else { return XCTFail("no transaction") }
        await store.redeemed(verification)
        XCTAssertTrue(store.entitlement.hasAccess)
        XCTAssertEqual(store.entitlement.productID, AnywherePlan.monthlyID)
        let signed = await store.signedTransaction()
        XCTAssertEqual(signed?.split(separator: ".").count, 3, "A compact JWS for the service")
        var unfinished = 0
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result, transaction.productID == AnywherePlan.monthlyID { unfinished += 1 }
        }
        XCTAssertEqual(unfinished, 0, "The redeemed transaction is finished")
    }

    func testListenerSeesPurchasesMadeOutsideTheApp() async throws {
        var updates = 0
        store.onTransactionUpdate = { updates += 1 }
        store.start()
        try await session.buyProduct(identifier: AnywherePlan.monthlyID)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !(store.entitlement.hasAccess && updates > 0) { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertTrue(store.entitlement.hasAccess, "Transaction.updates refreshed the entitlement by itself")
        XCTAssertGreaterThan(updates, 0)
    }

    // MARK: Screenshots

    /// Renders the paywall states from real StoreKit test products. Skipped unless the runner is
    /// started with `TEST_RUNNER_FARSIDE_SNAPSHOT_DIR=<dir>`.
    func testCapturePaywallScreens() async throws {
        guard let path = ProcessInfo.processInfo.environment["FARSIDE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_FARSIDE_SNAPSHOT_DIR to capture the paywall screens")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let access = AnywhereAccess(source: store, persistence: MemoryStore(), removalPersistence: MemoryStore())
        await store.refresh()
        try await capture(AnywherePaywallView(store: store, access: access), "paywall", to: directory)
        try await capture(FriendlyErrorView(error: .needsPlan, primaryTitle: "See the 7-day free trial", primary: {}, close: {}),
                          "needs-plan", to: directory)
        let model = PhoneRemoteModel()
        try await capture(HomeView(model: model, connection: model.connection, onboarding: OnboardingFlow()), "home-row", to: directory)
        await store.purchase(try yearly)
        try await capture(AnywherePaywallView(store: store, access: access), "trial-on", to: directory)
        session.billingGracePeriodIsEnabled = true
        session.shouldEnterBillingRetryOnRenewal = true
        try session.forceRenewalOfSubscription(productIdentifier: AnywherePlan.yearlyID)
        await eventually("grace period") { store.entitlement.phase == .gracePeriod }
        try await capture(AnywherePaywallView(store: store, access: access), "payment-problem", to: directory)
    }

    private func capture(_ view: some View, _ name: String, to directory: URL) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: view.tint(Farside.Palette.bone).preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(2))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: directory.appendingPathComponent("farside-paywall-\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
