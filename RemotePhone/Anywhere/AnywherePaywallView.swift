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
    @State private var selectedID: String = AnywherePlan.yearlyID
    @State private var showManage = false
    @State private var showRedeem = false
    @State private var restoring = false

    private var offers: [PlanOffer] { store.offers }
    private var selected: PlanOffer? { offers.first { $0.id == selectedID } ?? offers.first }
    private var subscribed: Bool { store.entitlement.hasAccess || store.entitlement.phase == .billingRetry }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                FarsideHalftone(style: HalftoneStyle(cell: 5, dust: 0.04), scene: FarsideArt.anywhere)
                    .frame(height: verticalSizeClass == .compact ? 120 : 190)
                    .padding(.horizontal, -Farside.Space.l)
                    .accessibilityHidden(true)
                FarsideHeading("Reach your Mac from anywhere.", accent: "anywhere", size: 32)
                    .padding(.top, Farside.Space.xs)
                Text("Farside is free when your iPhone and Mac share a Wi-Fi network. \(AnywhereCopy.name) connects them from any other network too.")
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
                notices.padding(.top, Farside.Space.m)
                links.padding(.top, Farside.Space.m)
            }
            .padding(.horizontal, Farside.Space.l)
            .padding(.bottom, Farside.Space.m)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { actionBar }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(FarsideRoundButtonStyle())
                .accessibilityLabel("Close")
                .accessibilityIdentifier("anywhere.close")
                .padding(.trailing, Farside.Space.s)
                .padding(.top, Farside.Space.xs)
        }
        .background(FarsideBackground())
        .manageSubscriptions(isPresented: $showManage, groupID: store.groupID)
        .offerCodeRedemption(isPresented: $showRedeem) { _ in Task { await store.refresh() } }
        .task {
            store.resetPurchaseState()
            if store.products.isEmpty { await store.loadProducts() }
            await store.refresh()
            if let first = store.offers.first, !store.offers.contains(where: { $0.id == selectedID }) { selectedID = first.id }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("anywhere.paywall")
    }

    // MARK: Sections

    private var benefits: some View {
        VStack(alignment: .leading, spacing: Farside.Space.s) {
            benefit("antenna.radiowaves.left.and.right", "On cellular or any Wi-Fi, away from home")
            benefit("lock", "Encrypted between your iPhone and your Mac, even through our relay")
            benefit("slider.horizontal.3", "No VPN, no port forwarding, nothing to set up")
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
                if store.load == .failed {
                    Text("Couldn’t reach the App Store. Check your connection, then try again.")
                        .font(.subheadline).foregroundStyle(Farside.Palette.bone)
                    Button("Try again") { Task { await store.loadProducts() } }
                        .buttonStyle(FarsideLinkButtonStyle())
                } else {
                    HStack(spacing: Farside.Space.s) {
                        ProgressView().tint(Farside.Palette.bone)
                        Text("Asking the App Store for prices…").font(.subheadline).foregroundStyle(Farside.Palette.ash)
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
                            Text("Save \(saving)%")
                                .farsideCaption(Farside.Palette.ink)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Farside.Palette.bone, in: .capsule)
                        }
                    }
                    Text("\(offer.displayPrice) a \(offer.periodNoun)")
                        .font(.subheadline).foregroundStyle(Farside.Palette.bone)
                    if let detail = [offer.trialPhrase.map { "\($0) free trial" }, offer.monthlyEquivalent]
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
                    FarsideNotice(message: "Farside’s service couldn’t be reached to confirm your plan. Same Wi-Fi still works; we’ll try again.", tone: .caution)
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
                Button(restoring ? "Restoring…" : "Restore Purchases") {
                    restoring = true
                    Task {
                        await store.restore()
                        if store.entitlement.hasAccess { await access.refresh(force: true) }
                        restoring = false
                    }
                }
                .disabled(restoring)
                .accessibilityIdentifier("anywhere.restore")
                if subscribed {
                    Button("Manage Subscription") { showManage = true }
                        .accessibilityIdentifier("anywhere.manage")
                } else {
                    Button("Redeem Code") { showRedeem = true }
                        .accessibilityIdentifier("anywhere.redeem")
                }
            }
            HStack(spacing: Farside.Space.l) {
                Button("Terms of Use") { openURL(AnywherePlan.termsURL) }
                    .accessibilityIdentifier("anywhere.terms")
                Button("Privacy Policy") { openURL(AnywherePlan.privacyURL) }
                    .accessibilityIdentifier("anywhere.privacy")
            }
        }
        .buttonStyle(FarsideLinkButtonStyle())
    }

    private var actionBar: some View {
        VStack(spacing: Farside.Space.xs) {
            if subscribed {
                Button("Done") { dismiss() }
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
                .disabled(selected == nil || store.purchaseState == .purchasing)
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

private extension View {
    @ViewBuilder func manageSubscriptions(isPresented: Binding<Bool>, groupID: String?) -> some View {
        if let groupID { manageSubscriptionsSheet(isPresented: isPresented, subscriptionGroupID: groupID) }
        else { manageSubscriptionsSheet(isPresented: isPresented) }
    }
}
