# Farside Remote: subscription setup

**Historical research notice — refreshed 29 September 2026:** The no-StoreKit/source-enforcement statements below are superseded by implemented native StoreKit and Backend `route.1` policy. Current UI calls the plan Farside Anywhere; existing product identifiers stay unchanged. Free access requires proven directly attached Wi-Fi/Ethernet; VPN, routed and unverifiable paths require Anywhere. Purchases remain disabled pending intended-service acceptance; sandbox expiry and production Apple app configuration remain open. Use [CURRENT-REVIEW-PACKET.md](CURRENT-REVIEW-PACKET.md) for current gates rather than this earlier proposed setup.

Prepared 28 September 2026. Design and research only: no App Store Connect records, keys or servers were created.

**Naming:** the product is **Farside** (renamed from PocketDesk on 28 Sep 2026). Bundle IDs stay `com.roshan.PocketDesk.*`, and so do the proposed product IDs below, so App Store Connect identifiers stay consistent. Code identifiers still say PocketDesk until engineering renames them.

Labels: **[V]** verified today from a primary source; **[R]** verified in the repo; **[I]** inference or unverified; **[O]** owner action; **[E]** engineering. The subscription is called **Farside Remote**.

## 1. Summary

- **Free:** everything on the same network, unlimited, no account.
- **Farside Remote:** one auto-renewable subscription group, monthly CA$5.99 and yearly CA$49.99, 7-day free trial, that lets the phone reach the Mac from anywhere through relay and network-traversal servers.
- **Enforcement** is server-side and costs-first: TURN credentials are issued only to rooms whose phone has proved an active subscription. There are no accounts; identity is Apple's own transaction identity.
- **Current state:** no StoreKit code exists in the app, and `Server/` issues TURN credentials to any approved room with no entitlement check. Both are launch blockers (APP-REVIEW-RISKS.md B1 and B2). [R] A parallel workstream (commit `cbafcea`, `Docs/research/2026-09-28-round2/RELAY-DEPLOYMENT-RUNBOOK.md`) has added Cloudflare relay readiness and deployment scripts for a single-owner relay run from the owner's Mac; it keeps manual room approval, four peers and 30-minute rooms, so it does not change this section. Its `policy` field on the `ice` message and `POCKETDESK_TEST_FORCE_RELAY` switch are test-only and must be off in production. [R]

Decisions needed from the owner:

| # | Decision | Recommendation |
|---|---|---|
| D1 | Does "free on your network" also block free users from connecting peer-to-peer over the internet when NAT traversal happens to work? | Yes, block it (option A in section 2). |
| D2 | Fair-use limit on relayed hours | No advertised "unlimited" for remote. Adaptive relay bitrate cap plus monitoring at launch; introduce a soft limit only if the cost data demands it, and disclose it if you do. |
| D3 | Lifetime purchase | Not at launch: relay costs recur (Screens and Remote Mac Desktop Control sell one [V]; that is their risk model, not yours). |
| D4 | Family Sharing | Off at launch (cannot be turned off once on). |
| D5 | Accept sandbox transactions on the production server | Yes, flagged and rate-limited: App Review and TestFlight purchases are sandbox. |
| D6 | Base price currency and country | Decide whether CAD or USD is the base, and inspect Apple's auto-equalized prices before confirming. |
| D7 | Billing grace period | 16 days, paid-to-paid renewals only. |

## 2. What "free on the same network" means technically

Today the app cannot pair without the signaling service: the QR invitation must carry a `wss://…/signal` URL (`PairInvitation.validServer` rejects anything else except localhost) and the Mac asks for a service address if none is baked in (`RemoteHost/HostSetupView.swift`). [R] So free local use still touches our server. That is cheap (signaling is a few small encrypted messages) but it has three consequences:

1. The free tier depends on service uptime. A signaling outage blocks even same-Wi-Fi users; the "Setup service outage" state in PRODUCT section 7 already covers the message.
2. The privacy policy must say the service sees connection metadata for every user, subscribed or not (PRIVACY-POLICY.md handles this).
3. A "local direct" mode (Bonjour discovery plus authenticated local WebSocket using the QR key, no internet needed) would remove the dependency. PRODUCT section 10 lists service-independent LAN access as a candidate with real cost. Not required for launch; keep it on the roadmap.

**D1 options**

| Option | What free users get | Enforcement | Pros | Cons |
|---|---|---|---|---|
| **A. Local only (recommended)** | Connection only when the selected ICE candidate pair is local (host candidates on private, link-local or ULA addresses) | Server issues no STUN and no TURN to free rooms; phone drops non-local candidates; the Mac checks the selected pair after ICE connects and tears down non-local sessions for rooms without a remote grant, showing "Remote needs Farside Remote" | Matches the pricing sentence exactly; clean upgrade moment | Client-side enforcement is soft (a modified client could get free direct WAN paths, which cost us nothing) |
| B. Free direct, paid relay | Anything that connects peer-to-peer, including over the internet | Only TURN is gated | Least code | Marketing becomes "free when devices connect directly"; inconsistent behaviour is a support burden and weakens conversion |

Implementation sketch for A: the server returns a signed "remote grant" (short-lived, Ed25519, public key baked into the Mac app) inside the `registered` or `peer` message for entitled rooms; the Mac accepts a non-local candidate pair only with a valid grant. The costly resource (TURN) stays strictly server-enforced.

## 3. StoreKit 2 product design

| Item | Value |
|---|---|
| Subscription group reference name | Farside Remote |
| Group display name (localized) | Farside Remote |
| Products | Two, in one group (one group is best practice so customers cannot buy two variants at once [V]) |
| Monthly | Product ID `com.roshan.PocketDesk.remote.monthly`; duration 1 month; price CA$5.99 (verify in ASC); display name "Farside Remote - Monthly" (24 characters; limit 35); description "Reach your Mac from anywhere." (29; limit 55) |
| Yearly | Product ID `com.roshan.PocketDesk.remote.yearly`; duration 1 year; price CA$49.99 (verify in ASC); display name "Farside Remote - Yearly" (23) |
| Levels | Yearly at level 1, monthly at level 2. Monthly to yearly is then an immediate upgrade (prorated refund of the unused month); yearly to monthly is a downgrade effective at the next renewal. Same-level products with different durations only cross-grade at the next renewal. [V, ASC subscription information page] |
| Introductory offer | Free trial, 1 week, on both products. One introductory offer per person per subscription group, chosen at purchase, cannot be edited after creation (delete and recreate) [V]. Check `Product.SubscriptionInfo.isEligibleForIntroOffer` and only show trial wording if `introductoryOffer` is non-nil, because the flag can be true even when no offer is configured [V]. |
| Family Sharing | Off (see section 6). |
| Multiseat purchases | On by default for all auto-renewable subscriptions and required for Apple Business and School Manager sales [V]. Turn off and make the product available from the App Store only, unless you want organization seat sales. Exact controls live under "Manage purchase options"; verify in App Store Connect. [I] |
| Billing Grace Period | App-level setting, options 3, 16 or 28 days for monthly and yearly (weekly is capped at 6). Choose 16 days, "Only Paid to Paid Renewals", enable in Sandbox first, test, then Production. [V] |
| Availability | Follows app availability; consider countries after the tax and support review. |
| Localizations | English first; subscription and group localizations are reviewed independently. [V] |
| Review information | Notes for the reviewer plus a paywall screenshot (ASC asks for a review image for in-app purchases [I]). |
| First submission | The first auto-renewable subscription and its group must be submitted together with a new app version; later products can be added without one. [V] |
| Tax category | Default software category unless the accountant advises otherwise. |
| Price changes | A price decrease cannot be reversed once effective; an increase triggers notice, or required consent when it exceeds 50% and roughly US$5 per month or US$50 per year, or in some regions. Launch at the price you can hold. [V] |
| Commission | 15% if enrolled in the App Store Small Business Program (proceeds up to US$1 million); otherwise 30% in a subscriber's first year and 15% after one year of paid service. [V] |

Non-App-Store channels: none. The Mac app and website must not sell the subscription (Guideline 3.1.1(a) and 3.1.3). [V]

## 4. Paywall placement and states

Principle: users experience the product before they are asked to pay, and there is always an honest free path.

1. **First launch:** onboarding is install-on-Mac, scan, approve. No paywall.
2. **Home:** below the Mac card, a quiet "Farside Remote: use your Mac from anywhere" row opens the paywall sheet. Also available as Settings > Farside Remote, reachable with **no Mac paired**, so App Review can find it (Guideline 2.1(b)). [V]
3. **Contextual:** when a connection attempt needs a route the free tier does not include, show a calm state: "Your Mac isn't on this network. Farside Remote connects you from anywhere." with "Try free for 7 days" and "Not now".
4. **Never:** at launch, before pairing, mid-session, or as a blocker for local use.
5. **Paywall sheet** uses `SubscriptionStoreView` for the group. It draws localized names and prices, shows Terms and Privacy buttons taken from App Store Connect, and includes a Close button. Add marketing content: title, three lines (reach your Mac on cellular or any Wi-Fi; no VPN or port forwarding; cancel anytime), a visible **Restore Purchases** control (`AppStore.sync()` must be called only from an explicit tap because it prompts for App Store sign-in [V]), and a Manage Subscription link. Price, period, renewal and cancellation text must be visible before the purchase button (Guideline 3.1.2(c)). [V]

State table:

| State | What the app shows | Behaviour |
|---|---|---|
| Not subscribed, on the same network | Normal session, route chip "Local" | Free |
| Not subscribed, off network | Contextual card (item 3) | No relay |
| In free trial | "Trial ends [date]" in Settings | Full remote |
| Subscribed | "Farside Remote active until [date]" | Full remote |
| Billing retry, in grace | Quiet notice "There is a payment problem. Update it in Apple Account settings." | Remote continues until grace ends |
| Expired | Contextual card and paywall | Local only |
| Refunded or revoked | Same as expired | TURN credentials revoked immediately |
| Cannot verify (offline, Apple unreachable) | "Could not check your subscription" with Retry | Use the last verified expiry, never longer than a short offline allowance [E to define] |

Sessions in progress at natural expiry continue until the session ends; refunds and revocations end them at once.

## 5. Entitlement check that gates relay access

### Client (phone)

- Start a `Transaction.updates` listener at launch so renewals, Ask to Buy and purchases on other devices are seen; iterate `Transaction.currentEntitlements` to get the latest verified transaction for the group. Refunded or revoked products do not appear. [V]
- Set an `appAccountToken` UUID when purchasing (a random per-install value kept in the Keychain) so transactions carry a stable, non-personal tag. It is optional and does not replace server verification. [V]
- To enable remote for a paired Mac, send the transaction's `jwsRepresentation` to the server together with proof of room ownership. Re-send on foreground and after `Transaction.updates`.

### Server

Add an entitlement service beside the signaling service:

1. `POST /v1/entitlement` with `{ jws, room, roomProof }`. `roomProof` is an HMAC over a server nonce using the room's client token, proving the caller owns that pairing (`Server/src/server.ts` already treats the client token as the room bearer secret). [R]
2. Verify `jws` with Apple's open-source App Store Server Library (Node.js v3.1.0, 6 May 2026): `SignedDataVerifier(rootCAs, enableOnlineChecks, environment, bundleId, appAppleId)` then `verifyAndDecodeTransaction`. `appAppleId` is required for Production; root certificates come from Apple PKI. Confirm the library runs under Bun, otherwise run this one endpoint on Node. [V library; I on Bun]
3. Accept only: `bundleId = com.roshan.PocketDesk.Remote`, `productId` in the two IDs, subscription group matches, `revocationDate` absent, `expiresDate` in the future. Reject `Xcode` environment in production; accept `Sandbox` only from TestFlight and App Review and flag it.
4. Store one record: HMAC of `originalTransactionId` (keyed with a server secret), product, `expiresDate`, status, environment, up to three enabled room IDs, timestamps. No name, email or Apple ID.
5. Mark the room `remote = true` until the earlier of `expiresDate` plus grace and a re-verification deadline (24 hours). Issue TURN credentials and STUN only for `remote` rooms. Push an updated ICE configuration to the Mac when a room becomes remote (today `ice` is sent once at registration; add a refresh message). [R]
6. Cap enabled rooms per subscription (start at 3) and rate-limit claims.
7. **App Store Server Notifications v2** endpoint over TLS 1.2 or later, set for production and sandbox URLs in App Store Connect. Apple provides a test-notification endpoint and a notification-history endpoint (history reaches back 180 days, 30 in sandbox) for checking delivery. [V] Handling:

| Notification | Action |
|---|---|
| `SUBSCRIBED`, `DID_RENEW` | Update `expiresDate`, mark active |
| `DID_FAIL_TO_RENEW` with subtype `GRACE_PERIOD` | Keep active through grace |
| `DID_FAIL_TO_RENEW` without subtype, `GRACE_PERIOD_EXPIRED`, `EXPIRED` | Mark inactive; revoke TURN credentials at next reconnect |
| `REFUND`, `REVOKE` | Mark inactive now; revoke live TURN credentials and terminate the room |
| `REFUND_REVERSED` | Reactivate |
| `REFUND_DECLINED` | No change |
| `CONSUMPTION_REQUEST` | Reply through the "Send Consumption Information" endpoint with what you can honestly report (sessions delivered) within Apple's response window [I on the exact window] |
| `DID_CHANGE_RENEWAL_STATUS`, `DID_CHANGE_RENEWAL_PREF`, `PRICE_INCREASE`, `RENEWAL_EXTENDED`, `OFFER_REDEEMED` | Update the record; no access change |
| `TEST` | Use to verify the endpoint |

8. **Authenticate outbound calls** with an In-App Purchase key (Users and Access, Integrations, In-App Purchase). It downloads once; store it server-side only and never in the app. [V]
9. Keep production and test TURN keys separate so sandbox traffic never mixes into cost accounting. [I; Cloudflare recommends separate keys, per `Docs/STANDALONE-NETWORK-READINESS.md`]

### Failure behaviour and abuse

- Apple unreachable: trust the last verified `expiresDate` for at most the re-verification window, never indefinitely.
- A copied JWS could be replayed: bind to a room via `roomProof`, cap rooms per subscription, and watch for one subscription appearing across many unrelated rooms.
- Changes needed in the current server: room approval must be automatic instead of the operator CLI, `ROOM_LIFETIME_SECONDS` (1800) and `MAX_PEERS` (4 in the standalone example) must be raised, and `TURN_CREDENTIAL_ISSUES_PER_MINUTE` (8 to 12) is far too low for launch. [R]

### Testing plan

| Stage | How |
|---|---|
| Local | Xcode StoreKit configuration file; the server accepts `Xcode` only on a development configuration |
| Sandbox and TestFlight | Builds from TestFlight use the sandbox automatically; subscriptions renew daily up to 6 times in a week; use a Sandbox Apple Account for billing-retry and grace scenarios [V] |
| Server | Request a test notification through the App Store Server API, then pull notification history to check gaps [V] |
| App Review | Reviewers purchase in the sandbox; the production server must accept it (D5) |

## 6. Family Sharing

Recommendation: leave it **off** at launch. Turning it on is permanent; once on, up to six family members can share one subscription, and each can use relay at your cost. [V] If you enable it later, handle `inAppOwnershipType = FAMILY_SHARED` on transactions and the `REVOKE` notification, and update the policy and paywall copy.

## 7. Refund handling

- Refunds are decided and paid by Apple, not by you; customers request them through Apple (reportaproblem.apple.com), and StoreKit can start a refund request from inside the app (`Transaction` documentation lists beginning a refund request). [V]
- Server actions: `REFUND` or `REVOKE` end access immediately; `REFUND_REVERSED` restores it; `CONSUMPTION_REQUEST` needs a reply (table above). [V]
- Support macro: point people to Apple for refunds, offer help with pairing problems first, and never promise a refund yourself.
- Client: refunded or revoked products disappear from `currentEntitlements`. [V]

## 8. Pricing sanity check

### Competitor prices (28 Sep 2026)

| Product | Price | Source |
|---|---|---|
| Astropad Workbench | Free 20 min/day (product page; the App Store text says 30); Unlimited US$14.99/month or US$79.99/year | astropad.com product page [V] |
| Screens 5 | US$3.99/month, US$29.99/year, US$179.99 lifetime (App Store also lists a US$29.49 yearly variant) | Edovia pricing page and App Store listing [V]. The earlier repo figures (US$2.99, US$24.99, US$99) in `Docs/COMPETITOR-LANDSCAPE-2026-09-28.md` are out of date. |
| Remote Mac Desktop Control | US$7.99/month, US$47.99/year, US$99.99 lifetime; free tier for local use with optional relay | App Store listing [V] |
| Jump Desktop | iOS app US$14.99, Mac client US$34.99 (App Store); Jump Desktop Connect about US$4 per computer per month | App Store [V]; Connect price from secondary sources only [I] |

Farside at CA$5.99 is roughly US$4.31 and CA$49.99 roughly US$35.99 at an assumed 0.72 USD per CAD (replace with the day's rate) [I]. That sits between Screens and Remote Mac Desktop Control and well below Workbench. Yearly is a 30% discount on twelve monthly payments (5.99 x 12 = 71.88). Workbench discounts its annual plan by about 55%.

### Relay cost versus revenue

Cloudflare TURN bills US$0.05 per GB of data sent from the edge to clients, after the first 1,000 GB per month; STUN is free. [V, page dated 14 Jul 2026] Video dominates, and it flows toward the phone. At 8 Mb/s that is 3.6 GB per hour, or about 3.96 GB per hour with 10% overhead, about US$0.20 per relayed hour. The repo's planning model (20 hours of use a month, 30% relayed) gives about 23.8 GB, about US$1.19 per user per month. [R, `Docs/research/2026-09-28/NETWORK-AND-SESSION.md`]

| Plan | Gross per month (USD, before tax) | Net after 15% commission | Relayed hours per month before relay cost equals net, at 8 Mb/s | At a 4 Mb/s relay cap |
|---|---|---|---|---|
| Monthly CA$5.99 | 4.31 | 3.67 | about 18 h | about 37 h |
| Yearly CA$49.99 (per month) | 3.00 | 2.55 | about 13 h | about 26 h |
| Yearly, if not in the Small Business Program (70% in year one) | 3.00 | 2.10 | about 11 h | about 21 h |

Assumptions: 0.72 USD per CAD, 15% commission, tax handled by Apple, relay cost only (no signaling hosting, support, or Apple's FX). The free 1,000 GB per month covers roughly 250 relayed hours a month across all users at 8 Mb/s. [I on FX; V on commission and Cloudflare prices]

Conclusions:

1. The prices are workable for typical use (a few relayed hours a month) and negative only for heavy relay users on the yearly plan. That risk is controllable.
2. **Enroll in the Small Business Program** on day one [O] so the 15% rate applies from the start. [V]
3. Cap relay quality (about 4 to 6 Mb/s, adaptive; this halves cost for heavy users) and monitor per-credential usage through Cloudflare analytics. Note Cloudflare budget alerts are informational and do not stop usage. [V, `Docs/STANDALONE-NETWORK-READINESS.md`]
4. Do not advertise unlimited remote hours. If a limit is ever introduced, disclose it in the paywall (Guideline 3.1.2(c)). [V]
5. Revisit price after 60 days of real relay-hours data. A price increase is easy to schedule under Apple's thresholds; a decrease is irreversible. [V]

## 9. Setup steps

Owner in App Store Connect [O]:

1. Sign the Paid Apps Agreement (Account Holder only), enter banking, submit tax forms (non-US developers complete a US form such as W-8BEN or W-8BEN-E plus any local forms). [V]
2. Enroll in the App Store Small Business Program. [V]
3. Create the app record after the name and trademark decision (STORE-LISTING.md), then Monetization, Subscriptions: create group "Farside Remote", the two products, prices, the 1-week free trial, localizations, review screenshot and notes. Leave them "Ready to Submit".
4. Turn on the Billing Grace Period in sandbox, then production. Leave Family Sharing off.
5. Enter the App Store Server Notifications URLs (production and sandbox).
6. Generate the In-App Purchase key; give it to engineering through a secure channel (never chat or email). It downloads once.
7. Create a Sandbox Apple Account for testing (Users and Access).
8. Submit the subscription group and both products together with the first app version on 3 Nov. [V]

Engineering [E]: StoreKit paywall and listener, entitlement service and ASN endpoint, server changes in section 5, Restore Purchases, manage-subscription link, Terms and Privacy links, tests in section 5.

## Sources (all checked 2026-09-28)

- Offer auto-renewable subscriptions: https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions/
- Auto-renewable subscription information (levels, durations, multiseat): https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/auto-renewable-subscription-information/
- Introductory offers: https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-introductory-offers-for-auto-renewable-subscriptions/
- Manage pricing for auto-renewable subscriptions (price points, price changes, consent thresholds): https://developer.apple.com/help/app-store-connect/manage-subscriptions/manage-pricing-for-auto-renewable-subscriptions/
- Billing Grace Period: https://developer.apple.com/help/app-store-connect/manage-subscriptions/enable-billing-grace-period-for-auto-renewable-subscriptions/
- Family Sharing for In-App Purchases: https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/turn-on-family-sharing-for-in-app-purchases/
- Server notification URLs and In-App Purchase keys: https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/enter-server-urls-for-app-store-server-notifications/ , https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/generate-keys-for-in-app-purchases/
- Submit an In-App Purchase (first subscription ships with an app version): https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/
- Testing subscriptions in TestFlight: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight/
- StoreKit: https://developer.apple.com/documentation/storekit/in-app-purchase , `Transaction`, `Transaction.currentEntitlements`, `Transaction.updates`, `AppStore.sync()`, `isEligibleForIntroOffer`, `VerificationResult`, `SubscriptionStoreView` documentation pages under https://developer.apple.com/documentation/storekit/
- App Store Server API and Notifications v2 (notification types): https://developer.apple.com/documentation/appstoreserverapi , https://developer.apple.com/documentation/appstoreservernotifications , https://developer.apple.com/documentation/appstoreservernotifications/notificationtype
- App Store Server Library for Node.js v3.1.0: https://github.com/apple/app-store-server-library-node
- Small Business Program: https://developer.apple.com/app-store/small-business-program/
- Paid Apps Agreement and tax: https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/ , https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information/
- Guidelines 2.1(b), 3.1.1, 3.1.2, 3.1.3: https://developer.apple.com/app-store/review/guidelines/
- Cloudflare TURN FAQ (14 Jul 2026): https://developers.cloudflare.com/realtime/turn/faq/
- Competitor prices: https://astropad.com/product/workbench/ , https://help.edovia.com/en/screens-5/faq/s5-pricing , App Store listings for Screens 5, Remote Mac Desktop Control and Jump Desktop
- Repo: `Server/src/server.ts`, `Server/.env.*.example`, `Docs/research/2026-09-28/NETWORK-AND-SESSION.md`, `Docs/STANDALONE-NETWORK-READINESS.md`, `RemoteShared/Pairing.swift`
