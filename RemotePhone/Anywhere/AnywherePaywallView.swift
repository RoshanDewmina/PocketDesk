import StoreKit
import SwiftUI

/// The Farside Anywhere sheet. Reachable from Home with or without a paired Mac (App Review 2.1(b)),
/// and when the service says a connection needs Anywhere. One honest free path is always stated.
struct AnywherePaywallView: View {
    @ObservedObject var store: AnywhereStore
    @ObservedObject var access: AnywhereAccess
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchaseAction
    @Environment(\.openURL) private var openURL
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedID: String = AnywherePlan.yearlyID
    @State private var showManage = false
    @State private var showRedeem = false
    @State private var restoring = false
    /// Anywhere turned on while this sheet was open (D38): the reach lengthens once. Nil otherwise.
    @State private var unlock: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var offers: [PlanOffer] { store.offers }
    private var selected: PlanOffer? { offers.first { $0.id == selectedID } ?? offers.first }
    private var subscribed: Bool { store.entitlement.hasAccess || store.entitlement.phase == .billingRetry }
    private var canSell: Bool { store.canSell }
    private var adaptiveLayout: Bool { dynamicTypeSize.isAccessibilitySize && FarsideAccessibilityLayout.enabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let unlock {
                        AnywhereUnlockArt(progress: unlock)
                    } else {
                        FarsideHalftone(style: HalftoneStyle(cell: 5, dust: 0.04), scene: FarsideArt.anywhere)
                    }
                }
                    .frame(height: verticalSizeClass == .compact ? 120 : 190)
                    .padding(.horizontal, -Farside.Space.l)
                    .accessibilityHidden(true)
                FarsideHeading(CommerceLocalization.text("PAYWALL_HEADING", "Reach your Mac from anywhere."), size: 32)
                    .padding(.top, Farside.Space.xs)
                Text(CommerceLocalization.text("PAYWALL_ROUTE", "Farside is free on a verified local network. Farside Anywhere reaches your Mac from other networks. Restoring a purchase does not pair a Mac or grant control."))
                    .font(.body)
                    .foregroundStyle(Farside.Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Farside.Space.s)
                benefits.padding(.top, Farside.Space.l)
                if subscribed {
                    statusPlate.padding(.top, Farside.Space.l)
                } else {
                    plans.padding(.top, Farside.Space.l)
                }
                if store.entitlement.kind == .subscription { oneTimeOffers.padding(.top, Farside.Space.m) }
                notices.padding(.top, Farside.Space.m)
                links.padding(.top, Farside.Space.m)
                if adaptiveLayout { actionBar.padding(.horizontal, -Farside.Space.l) }
            }
            .padding(.horizontal, Farside.Space.l)
            .padding(.bottom, Farside.Space.m)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            if !adaptiveLayout { actionBar }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(FarsideRoundButtonStyle())
                .accessibilityLabel("Close")
                .frame(minHeight: 44)
                .accessibilityIdentifier("anywhere.close")
                .padding(.trailing, Farside.Space.s)
                .padding(.top, Farside.Space.xs)
        }
        .background(FarsideBackground())
        .manageSubscriptions(isPresented: $showManage, groupID: store.groupID)
        .modifier(OfferCodeRedemption(isPresented: $showRedeem, store: store, access: access))
        .task {
            store.resetPurchaseState()
            if store.products.isEmpty { await store.loadProducts() }
            await store.refresh()
            if let first = store.offers.first, !store.offers.contains(where: { $0.id == selectedID }) { selectedID = first.id }
        }
        // Only real access celebrates; Ask to Buy (pending) and failures never do.
        .onChange(of: store.entitlement.hasAccess) { had, has in
            guard !had, has, unlock == nil else { return }
            if reduceMotion { unlock = 1; return }
            unlock = 0
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 1.1)) { unlock = 1 }
        }
        .sensoryFeedback(.success, trigger: unlock != nil) { _, unlocked in unlocked }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("anywhere.paywall")
    }

    // MARK: Sections

    private var benefits: some View {
        VStack(alignment: .leading, spacing: Farside.Space.s) {
            benefit("antenna.radiowaves.left.and.right", CommerceLocalization.text("BENEFIT_ROUTE", "On cellular or any Wi-Fi, away from home"))
            benefit("lock", DeviceWord.copy(CommerceLocalization.text("BENEFIT_ENCRYPTION", "Encrypted between your iPhone and your Mac, even through our relay")))
            benefit("slider.horizontal.3", CommerceLocalization.text("BENEFIT_SETUP", "No VPN, no port forwarding, nothing to set up"))
        }
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Farside.Space.s) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Farside.Palette.bone)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(Farside.Palette.bone)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var plans: some View {
        if offers.isEmpty {
            VStack(alignment: .leading, spacing: Farside.Space.s) {
                if store.load == .unavailable {
                    Text(CommerceLocalization.text("ANYWHERE_UNAVAILABLE", "Anywhere isn’t available yet."))
                        .font(.subheadline).foregroundStyle(Farside.Palette.bone)
                    Button("Try again") { Task { await store.loadProducts() } }
                        .buttonStyle(FarsideLinkButtonStyle())
                } else if store.load == .failed {
                    Text(CommerceLocalization.text("APP_STORE_OFFLINE", "Couldn’t reach the App Store. Check your connection, then try again."))
                        .font(.subheadline).foregroundStyle(Farside.Palette.bone)
                    Button("Try again") { Task { await store.loadProducts() } }
                        .buttonStyle(FarsideLinkButtonStyle())
                } else {
                    HStack(spacing: Farside.Space.s) {
                        ProgressView().tint(Farside.Palette.bone)
                        Text(CommerceLocalization.text("PRICES_LOADING", "Asking the App Store for prices…")).font(.subheadline).foregroundStyle(Farside.Palette.ash)
                    }
                }
            }
            .padding(Farside.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .farsidePlate()
        } else {
            VStack(alignment: .leading, spacing: Farside.Space.s) {
                ForEach(offers) { offer in planRow(offer) }
                if let selected {
                    Text(AnywhereCopy.disclosure(selected))
                        .font(.footnote)
                        .foregroundStyle(Farside.Palette.ash)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Farside.Space.xs)
                        .accessibilityIdentifier("anywhere.disclosure")
                }
            }
        }
    }

    private func planRow(_ offer: PlanOffer) -> some View {
        let isSelected = offer.id == selected?.id
        let saving = offer.period == .year
            ? PlanOffer.yearlySaving(yearly: offer, monthly: offers.first { $0.period == .month }) : nil
        return Button { selectedID = offer.id } label: {
            HStack(alignment: .center, spacing: Farside.Space.s) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Farside.Space.xs) {
                        Text(offer.title).font(.headline).foregroundStyle(Farside.Palette.bone)
                        if let saving {
                            Text(CommerceLocalization.text("YEAR_SAVING", "Save %ld%%", saving))
                                .farsideCaption(Farside.Palette.ink)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Farside.Palette.bone, in: .capsule)
                        }
                    }
                    Text(offer.pricePhrase)
                        .font(.subheadline).foregroundStyle(Farside.Palette.bone)
                    if let detail = [offer.freeTrialPhrase, offer.monthlyEquivalent]
                        .compactMap({ $0 }).joined(separator: " · ").nonEmpty {
                        Text(detail).farsideCaption()
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Farside.Palette.bone : Farside.Palette.ash)
                    .accessibilityHidden(true)
            }
            .padding(Farside.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .farsidePlate(Farside.Radius.card, fill: isSelected ? Farside.Palette.panel2 : Farside.Palette.panel,
                          stroke: isSelected ? Farside.Palette.bone : Farside.Palette.line)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("anywhere.plan.\(offer.period == .year ? "yearly" : "monthly")")
    }

    @ViewBuilder private var oneTimeOffers: some View {
        ForEach(store.oneTimeProducts, id: \.id) { product in
            if let entry = store.oneTimePolicy.entry(for: product.id) {
                VStack(alignment: .leading, spacing: Farside.Space.s) {
                    Text(entry.kind == .founder
                         ? CommerceLocalization.text("ONE_TIME_FOUNDER", "Founder lifetime")
                         : CommerceLocalization.text("ONE_TIME_LIFETIME", "Lifetime"))
                        .font(.headline)
                    Text(CommerceLocalization.text("ONE_TIME_TERMS", "%@ once. No subscription renewals. Full Anywhere access; current service verification and Mac pairing are required. Refunded or revoked purchases lose this benefit. This does not cancel an existing subscription.", product.displayPrice))
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Button(CommerceLocalization.text("ONE_TIME_BUY", "Buy for %@ once", product.displayPrice)) {
                        Task {
                            await store.purchase(product) { product, options in try await purchaseAction(product, options: options) }
                            if store.entitlement.hasAccess { await access.refresh(force: true) }
                        }
                    }
                    .buttonStyle(FarsidePrimaryButtonStyle(height: 56))
                    .disabled(!canSell || store.purchaseState == .purchasing)
                    .accessibilityIdentifier("anywhere.oneTime." + entry.kind.rawValue)
                }
                .padding(Farside.Space.m).farsidePlate()
            }
        }
    }

    private var statusPlate: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Farside.Space.xs) {
                Image(systemName: store.entitlement.hasBillingProblem ? "exclamationmark.circle" : "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Farside.Palette.bone)
                    .accessibilityHidden(true)
                Text(AnywhereCopy.statusTitle(store.entitlement)).font(.headline).foregroundStyle(Farside.Palette.bone)
            }
            Text(AnywhereCopy.statusDetail(store.entitlement))
                .font(.subheadline).foregroundStyle(Farside.Palette.ash)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Farside.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .farsidePlate()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("anywhere.status")
    }

    @ViewBuilder private var notices: some View {
        VStack(alignment: .leading, spacing: Farside.Space.s) {
            if !subscribed && !canSell {
                FarsideNotice(message: CommerceLocalization.text("PURCHASE_UNAVAILABLE", "Farside Anywhere is temporarily unavailable. We can’t confirm a new purchase right now. Verified local access stays free, and Restore Purchases remains available."), tone: .caution)
                    .accessibilityIdentifier("anywhere.purchaseUnavailable")
            }
            switch store.purchaseState {
            case .pending:
                FarsideNotice(message: "Waiting for approval. Anywhere turns on by itself once the purchase is approved.")
            case .failed(let message):
                FarsideNotice(message: message, tone: .caution)
            default:
                EmptyView()
            }
            if !subscribed, store.entitlement.phase == .expired || store.entitlement.phase == .revoked {
                FarsideNotice(message: AnywhereCopy.statusDetail(store.entitlement))
            }
            if store.entitlement.hasAccess {
                switch access.verification {
                case .unreachable:
                    FarsideNotice(message: CommerceLocalization.text("SERVICE_OFFLINE", "Farside’s service couldn’t confirm your plan. Verified local access still works; we’ll try again."), tone: .caution)
                case .refused(let reason):
                    FarsideNotice(message: AnywhereCopy.refusal(reason), tone: .caution)
                default:
                    EmptyView()
                }
            }
            if let message = store.restoreMessage {
                FarsideNotice(message: message, tone: store.entitlement.hasAccess ? .success : .info)
            }
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Farside.Space.l) {
                Button(restoring ? CommerceLocalization.text("RESTORING", "Restoring…") : CommerceLocalization.text("RESTORE", "Restore Purchases")) {
                    restoring = true
                    Task {
                        await store.restore()
                        if store.entitlement.hasAccess { await access.refresh(force: true) }
                        restoring = false
                    }
                }
                .disabled(restoring)
                .frame(minHeight: 44)
                .accessibilityIdentifier("anywhere.restore")
                if subscribed {
                    Button(CommerceLocalization.text("MANAGE", "Manage Subscription")) { showManage = true }
                        .frame(minHeight: 44)
                .accessibilityIdentifier("anywhere.manage")
                } else {
                    Button(CommerceLocalization.text("REDEEM", "Redeem Code")) { showRedeem = true }
                        .disabled(!canSell)
                        .frame(minHeight: 44)
                .accessibilityIdentifier("anywhere.redeem")
                }
            }
            HStack(spacing: Farside.Space.l) {
                Button(CommerceLocalization.text("TERMS", "Terms of Use")) { openURL(AnywherePlan.termsURL) }
                    .frame(minHeight: 44)
                .accessibilityIdentifier("anywhere.terms")
                Button(CommerceLocalization.text("PRIVACY", "Privacy Policy")) { openURL(AnywherePlan.privacyURL) }
                    .frame(minHeight: 44)
                .accessibilityIdentifier("anywhere.privacy")
            }
        }
        .buttonStyle(FarsideLinkButtonStyle())
    }

    private var actionBar: some View {
        VStack(spacing: Farside.Space.xs) {
            if subscribed {
                Button(CommerceLocalization.text("DONE", "Done")) { dismiss() }
                    .buttonStyle(FarsidePrimaryButtonStyle(height: 56))
                    .accessibilityIdentifier("anywhere.done")
            } else {
                if let selected {
                    Text(AnywhereCopy.summary(selected))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Farside.Palette.bone)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("anywhere.summary")
                }
                Button(store.purchaseState == .purchasing ? "Opening the App Store…" : AnywhereCopy.primaryTitle(selected)) {
                    guard let selected, let product = store.product(for: selected.id) else { return }
                    Task {
                        await store.purchase(product) { product, options in try await purchaseAction(product, options: options) }
                        if store.entitlement.hasAccess { await access.refresh(force: true) }
                    }
                }
                .buttonStyle(FarsidePrimaryButtonStyle(height: 56))
                .disabled(selected == nil || store.purchaseState == .purchasing || !canSell)
                .accessibilityIdentifier("anywhere.subscribe")
                Button("Not now") { dismiss() }
                    .buttonStyle(FarsideLinkButtonStyle())
                    .accessibilityIdentifier("anywhere.notNow")
            }
        }
        .padding(.horizontal, Farside.Space.l)
        .padding(.top, Farside.Space.s)
        .padding(.bottom, Farside.Space.xs)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(Farside.Palette.void)
    }
}

/// Home's Farside Anywhere row: plan state in one line, opens the sheet.
struct AnywherePlanRow: View {
    @ObservedObject var store: AnywhereStore
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AnywhereCopy.name).font(.body).foregroundStyle(Farside.Palette.bone)
                    Text(AnywhereCopy.homeCaption(store.entitlement)).farsideCaption()
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Farside.Palette.ash)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 60)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .farsidePlate(Farside.Radius.card, fill: .clear)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plans for reaching your Mac from any network")
        .accessibilityIdentifier("home.anywhere")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Redeem Code. On iOS 27 the sheet returns the redeemed transaction, which goes to the service at once;
/// earlier systems only say the sheet closed, so the status is re-read and verified as after a purchase.
private struct OfferCodeRedemption: ViewModifier {
    @Binding var isPresented: Bool
    let store: AnywhereStore
    let access: AnywhereAccess

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.offerCodeRedemption(options: [], isPresented: $isPresented) { result in
                Task {
                    if case .success(let verification) = result { await store.redeemed(verification) } else { await store.refresh() }
                    await verifyIfEntitled()
                }
            }
        } else {
            content.offerCodeRedemption(isPresented: $isPresented) { _ in
                Task {
                    await store.refresh()
                    await verifyIfEntitled()
                }
            }
        }
    }

    @MainActor private func verifyIfEntitled() async {
        if store.entitlement.hasAccess { await access.refresh(force: true) }
    }
}

private extension View {
    @ViewBuilder func manageSubscriptions(isPresented: Binding<Bool>, groupID: String?) -> some View {
        if let groupID { manageSubscriptionsSheet(isPresented: isPresented, subscriptionGroupID: groupID) }
        else { manageSubscriptionsSheet(isPresented: isPresented) }
    }
}
