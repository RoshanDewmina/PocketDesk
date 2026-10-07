# Farside website billing eligibility — 30 September 2026

Status: **Checks in progress; neither Apple classification nor Stripe account eligibility is confirmed.** No billing migration, products, prices, purchases, contract acceptance or app-review submission performed.

## Verified findings

| Check | Result | Evidence / remaining gate |
|---|---|---|
| Apple free-companion rule | Possible route, not a confirmed exemption for Farside | Guideline 3.1.3(f) covers free companions to paid web-based tools with no in-app purchasing or purchase steering. The paid Mac/internet service's classification needs clarification. |
| Existing iOS implementation | Requires migration | `RemotePhone/Anywhere/AnywherePaywallView.swift` and `AnywhereStore.swift` provide StoreKit purchasing. Current design is not the proposed purchase-free companion. |
| Existing server authorization | Requires migration | `Backend/ENTITLEMENT-CONTRACT.md` verifies Apple signed transactions and binds entitlements to device IDs. Website payment alone cannot replace this trust path. |
| Stripe seller geography | Canada supported | Published Managed Payments eligibility lists CA. This does not establish eligibility for a particular individual account. |
| Stripe product category | Appears compatible, pending provider review | Software and automated digital services are supported. Farside offers software for owner-controlled remote access, rather than human-operated support. Correct product tax code remains to be confirmed. |
| Stripe account access | Needs user | Browser opened Stripe Dashboard; it shows sign-in. No account access, verification, activation, or Managed Payments approval established. |
| Stripe tax coverage | Covered markets only | Managed Payments handles transaction taxes in covered countries; seller remains responsible for uncovered transactions. Do not assume worldwide tax relief. |

## Decision boundary

Keep current StoreKit and server verification code intact until the business model is resolved. Do not create Apple subscriptions while this alternative is being checked. Do not represent an informational Apple support response as approval of a submitted binary.

If Apple requires IAP for this model, website-only payments cannot substitute worldwide. If the companion route is acceptable and Stripe approves the seller/product, a bounded implementation can follow: website checkout and subscription management; secure customer-to-device binding; signed webhook processing with replay protection; server subscription state and short-lived access tokens; purchase-free iOS UI; expiry, refund, cancellation and device-removal checks. Preserve free local access and explicit owner pairing.

## Apple inquiry prepared in browser — NOT SENT

Route: App Review > Other App Review questions > Email.

Fields: App name **Farside: Remote Desktop**; app identifier **6817532560**; Platform **iOS**; Related Apps blank. The signed-in account's contact fields are autofilled; they are intentionally omitted from this file.

Exact message:

> I am requesting pre-submission business-model guidance for Farside: Remote Desktop, App Apple ID 6817532560, iOS bundle com.roshan.PocketDesk.Remote, Team 39HM2X8GS6. Version 1.0 is in Prepare for Submission; this is not a request to submit the app for review.
>
> Farside is a generic remote-desktop viewer/controller for the user's own Mac, with explicit device pairing and macOS Screen Recording/Accessibility consent. The Mac companion (com.roshan.PocketDesk.RemoteHost) is planned for distribution outside the Mac App Store using Developer ID signing and notarization. It streams the owner's own Mac screen, rather than hosting specific third-party software or cloud desktops.
>
> The current implementation has a StoreKit subscription paywall and server subscription checks. Before launch, we are evaluating a different model: the iOS/iPadOS app would be a free companion with no purchases, prices, upgrade buttons, or calls to purchase elsewhere. Same-local-network access would stay free. Users would purchase Farside Anywhere through our website or Mac setup; that paid Mac/internet-access service would enable remote connections through our servers for paired devices. A browser viewer exists in development and is not a launched paid web product.
>
> Would this proposed model qualify for guideline 3.1.3(f), or would guideline 3.1.3(b) still require offering the subscription through IAP? In particular, does a paid Mac and internet-access service qualify as the paid web-based tool, and would offering a functional web viewer change the classification? Please identify any requirements for a compliant free companion available worldwide. We will retain the current billing implementation until the appropriate model is clarified.

## Stripe questions for account review — NOT SENT

Can a Canada-based individual/sole proprietor selling Farside Anywhere use Managed Payments through a direct Stripe account? Farside is automated remote-desktop software that connects customers to their own paired Macs; it does not supply human technical-support sessions or cloud desktops. Which eligible product tax code applies to a subscription combining downloadable clients and hosted internet connectivity? What identity, tax and payout information is required for this seller type? Which buyer countries should be enabled to stay entirely within Managed Payments' indirect-tax coverage? Please confirm account/product eligibility before activation or live sales.

## Sources checked live

- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), especially 3.1.1, 3.1.3(b), 3.1.3(f), and 4.2.7.
- [Apple inquiry form](https://developer.apple.com/contact/topic/SC1103/subtopic/30023/solution/CONTACT.EML.GEN/details).
- [Managed Payments eligibility](https://docs.stripe.com/payments/managed-payments/eligibility).
- [Managed Payments flow and coverage limits](https://docs.stripe.com/payments/managed-payments/how-it-works).
- [Managed Payments tax compliance](https://docs.stripe.com/payments/managed-payments/tax-compliance).

This file contains no personal contact details, bank numbers, tax identifiers, or identity-document data.
