# Farside Anywhere: StoreKit implementation (launch blocker B2, app side)

29 September 2026, branch `storekit/b2-2026-09-29`. The phone app's half of B2: StoreKit 2 subscriptions, the paywall, and the entitlement handshake with the service. The service half (verification, token issuance, relay gating, App Store Server Notifications) was recovered from `backend/workers-2026-09-29` and merged to main at `82f8042`; this code follows `Backend/ENTITLEMENT-CONTRACT.md` v1.2 and the "Remote access" paragraph of `Docs/REMOTE-PROTOCOL.md`.

Evidence levels: **[T]** covered by an automated test that passed on the iOS 27 simulator; **[S]** seen on simulator screenshots; **[C]** compiles only, not exercised; **[O]** owner action in App Store Connect. Nothing here has run against the real App Store sandbox, TestFlight, a physical device or the deployed backend.

**Recovery status, 29 September:** The inherited build and 35 selected unit tests passed. A fresh one-runner UI baseline reproduced one failure in three tests: XCTest tapped the fixed purchase bar while the monthly plan was below the visible scroll area. After fixing that hit target, a one-runner build, 40 selected units (one optional screenshot skipped), all three UI tests, and the separate screenshot test passed; the five synthetic PNGs are in `/tmp/farside-storekit-recovery-20260929/final/shots`. The later security pass added origin-bound tokens, strict wire expiry, a no-redirect verification POST, stale-result guards, and purchase-readiness gates. That historical build, 47 selected unit tests excluding the one expiry case (one optional screenshot skipped), and all three paywall UI tests passed. Receipts: `/tmp/farside-storekit-recovery-20260929/final-guard-build/build.log`, `final-guard-unit.log`, and `final-guard-ui/ui.log` in the same recovery directory. B2 is not closed. Empty ICE alone does not prevent direct WAN candidates. The later integrated `route.1` policy and physical local proof now implement the strict boundary; real network acceptance remains required before release. See the current implementation ledger for that package.

**Preserved StoreKitTest discrepancy:** The original forced-expiry fixture failed in this simulator. In the preserved probe `/tmp/farside-storekit-recovery-20260929/expiry-freshsim.log`, `SKTestSession.expireSubscription` changes its transaction expiration from 6 October to 29 September, but StoreKit 2's `Product.SubscriptionInfo.status(for:)`, `Transaction.latest(for:)`, and `Transaction.currentEntitlements` all continue to report the old 6 October free trial after eight seconds. This persists after booting the dedicated simulator and starting the app's real transaction/status listeners. The app reflects the stale StoreKit 2 result. That forced-expiry discrepancy remains unresolved and its probe is preserved. The current fixture disables auto-renewal and uses accelerated natural expiry, retaining strict assertions for expired state, no access and no signed transaction. A separate test verifies the application end-date timer without transaction listeners or a caller refresh. Both pass in the integrated 55-test selection (54 passed, one optional screenshot skip, zero failures; `work/launch-preparation/removal-expiry-final-tests.log`). This corrects the test fixture without claiming that the documented immediate-expiry API behaves correctly here. Real sandbox and physical expiry remain acceptance gates.

## 1. What was built

| Piece | File | Notes |
|---|---|---|
| Plan constants, entitlement rules, paywall copy, service address | `RemotePhone/Anywhere/AnywhereEntitlement.swift` | Pure Swift, no StoreKit. `AnywhereEntitlement.resolve` turns subscription statuses into one of: not subscribed, trial, active, grace period, billing retry, expired, revoked. [T] |
| StoreKit 2 store | `RemotePhone/Anywhere/AnywhereStore.swift` | Loads both products; purchase requires a Keychain-backed `appAccountToken`; `Transaction.updates` and `Product.SubscriptionInfo.Status.updates` listeners started in `RemotePhoneApp.init`; finishes unfinished transactions at launch; `Product.SubscriptionInfo.status(for:)` for grace/billing-retry/revoked; `isEligibleForIntroOffer`; restore via `AppStore.sync()` (only from a tap). [T] |
| Verify client | `RemotePhone/Anywhere/EntitlementClient.swift` | `EntitlementVerifying` protocol + `HTTPEntitlementClient`; the wire format lives only in `EntitlementWire`. Install identity (64-hex `deviceId`, UUID `appAccountToken`) in the Keychain. A private ephemeral session rejects HTTP redirects so the signed transaction and device ID are never replayed to a redirect destination. [T] |
| Handshake | `RemotePhone/Anywhere/AnywhereAccess.swift` | Verifies, stores the token in the Keychain, refreshes on the contract's 12 h / 6 h rules, backs off on 429, keeps an unexpired token through outages, hands the token to signaling, handles `entitlement_required`. [T] |
| Paywall and Home row | `RemotePhone/Anywhere/AnywherePaywallView.swift` | Reach design system (void, panel plates, bone type, Doto heading with one serif accent, no ember). A new purchase and code redemption are disabled until a configured HTTPS verification service exists; prices and Restore remain visible. Manage Subscription and Redeem Code use Apple's sheets. [T][S] |
| Signaling (additive) | `RemoteShared/SignalingClient.swift`, `SessionRenewal.swift`, `RemoteCoordinator.swift` | Phone lists `remote.1`, sends `entitlement` in `register`, reads `registered.access`, treats `entitlement_required` as non-closing (error and in `renewed`). Nothing changes for the Mac or for coordinators without Anywhere attached. [T] |
| Entry points | `RemotePhone/HomeView.swift`, `RemotePhone/FriendlyErrors.swift` | Home row "Farside Anywhere" (with or without a paired Mac), help menu item, contextual "Your Mac isn't on this network" screen after a same-network-only attempt fails, "Couldn't confirm Anywhere" when a plan can't be verified. No entry points inside the live session. [T][S] |
| Local StoreKit configuration | `StoreKitTesting/FarsideAnywhere.storekit` | Group "Farside Anywhere", yearly (level 1, CA$49.99) and monthly (level 2, CA$5.99), 1-week free trial on both, storefront CAN. Attached to the `PocketDeskRemote` scheme and bundled into `RemotePhoneTests`. |
| Build settings | `project.yml`, `RemotePhone/Info.plist` | `FARSIDE_SERVICE_BASE_URL` (empty), `FARSIDE_TERMS_URL`, `FARSIDE_PRIVACY_URL` → Info.plist keys `FarsideServiceBaseURL`, `FarsideTermsURL`, `FarsidePrivacyURL`. |

Why a custom paywall rather than `SubscriptionStoreView` (which SUBSCRIPTION-SETUP.md §4 suggested): the Reach design system (dark void, Doto heading, bone pill button) cannot be reproduced inside `SubscriptionStoreView`'s control area, and building the disclosure from `Product` values lets tests pin the exact wording next to the button. Apple's own sheets are still used for purchase confirmation, managing, and code redemption.

## 2. Flow

1. **Launch.** `AnywhereStore.shared.start()` listens for transactions and reads the group status. `AnywhereAccess.attach` (on first appear) turns on `remote.1`, wires the token into `RemoteCoordinator.entitlementToken`, and verifies if there is access.
2. **Connect (person taps Connect).** `prepareForConnection()` waits for a token only if the phone has a plan and holds no valid token, and never longer than 4 s. A plan-less phone connects immediately.
3. **Register.** The phone sends `features: ["renew.1", "remote.1"]` and, if it holds one, `"entitlement": "fe1…"`.
4. **Service says `entitlement_required` (non-closing).** The session keeps going on the same network. With a plan, `AnywhereAccess` verifies again and, if that yields a token, reconnects once (at most once a minute). Without a plan nothing happens unless the local-only attempt fails; then Home shows "Your Mac isn't on this network" with **See Farside Anywhere** (or "See the 7-day free trial" when eligible) and **Try again**.
5. **Purchase or restore.** On success the paywall shows the plan's status and forces a verification, so the next connection carries a token.
6. **Renewals, refunds, Ask to Buy, other devices.** The transaction listener refreshes the entitlement and forces a verification. Losing access drops the token from memory and the Keychain at once.

Entitlement → what the phone shows:

| StoreKit state | Access | Home caption | Paywall |
|---|---|---|---|
| none | no | Free on the same Wi-Fi · Anywhere off | plans, trial if eligible |
| trial | yes | Trial · ends 6 Oct | "Your free trial is on", Manage Subscription |
| subscribed | yes | On · renews 29 Oct (or "ends" if auto-renew is off) | "Farside Anywhere is on" |
| grace period | yes | Payment problem · still on | payment notice, works until grace end |
| billing retry | no | Payment problem · paused | payment notice, Manage Subscription (no second purchase) |
| expired | no | Free on the same Wi-Fi · Anywhere off | plans + "It ended …" |
| refunded or revoked | no | same | plans + refund notice |
| service refused (`device_limit`, `expired`, `revoked`, invalid) | StoreKit yes, service no | unchanged | caution notice with the reason |
| service unreachable | keeps an unexpired token | unchanged | "couldn't be reached … same Wi-Fi still works" |

## 3. App Review Guideline 3.1.2 and related, as implemented

| Requirement | Where |
|---|---|
| Name of the subscription, length and price of each period, per-unit price where helpful | Plan rows: "Yearly · CA$49.99 a year · CA$4.17 a month", "Monthly · CA$5.99 a month"; the billed amount is the most prominent price; the monthly equivalent is a small caption. Prices, currency and trial come from StoreKit (`displayPrice`, `subscriptionPeriod`, `introductoryOffer`), never hard-coded. [T] |
| Free-trial terms and when payment starts | Line directly above the button: "7-day free trial, then CA$49.99 a year. Renews automatically; cancel anytime." Full disclosure under the plans: charged when the trial ends, renews until cancelled, cancel at least 24 hours before the end of the trial/period in Settings › Apple Account › Subscriptions. The UI test checks that this line is on screen and above the button. [T] |
| Trial wording only when real | Trial text appears only when `isEligibleForIntroOffer` is true **and** the product has a free-trial `introductoryOffer` (SUBSCRIPTION-SETUP §3). After a purchase the trial wording disappears. [T] |
| Functional Terms of Use (EULA) and Privacy Policy links in the app | Paywall links "Terms of Use" and "Privacy Policy" (`FARSIDE_TERMS_URL`, `FARSIDE_PRIVACY_URL`). [T: present and tappable; the URLs do not resolve until the domain is live] |
| Restore Purchases | Paywall button, `AppStore.sync()` only on tap; tells the person what happened. [T] |
| IAP reachable by the reviewer without special setup (2.1(b)) | Home row and help-menu item work with no Mac paired. [T] |
| Manage and cancel | "Manage Subscription" opens Apple's sheet (`manageSubscriptionsSheet`). |
| Offer codes | "Redeem Code" opens Apple's sheet (`offerCodeRedemption`). |
| No dark patterns | Close button and "Not now" on every paywall; no timers, no pre-checked add-ons, no confirm-shaming; the free path (same Wi-Fi) is stated in the heading copy, the disclosure and Home; the contextual screen keeps "Try again" next to the offer; paywalls never appear at launch, before pairing, or during a session. |
| One group, upgrade path | Both products in one group; yearly level 1, monthly level 2 (monthly → yearly is an immediate upgrade). |
| Device cap disclosed | The disclosure says one subscription covers up to three iPhones and iPads (the service's cap, contract §2 check 8). |

## 4. Testing locally

**In Xcode.** The `PocketDeskRemote` scheme's Run action uses `StoreKitTesting/FarsideAnywhere.storekit`, so running on a simulator shows real test products. Use Debug › StoreKit › Manage Transactions to refund, expire, or enable billing retry and grace period. Launch argument `--ui-paywall` opens the paywall on start. Purchases in this environment produce `Xcode`-environment transactions, which the production service rejects (`environment_not_accepted`); only `wrangler dev` accepts them (contract §7).

**Everything at once:** `SIM=<simulator udid> script/verify-storekit.sh [build unit ui shots]` (one simulator runner; timestamped logs, result bundles and screenshots in `/tmp/farside-storekit-*`). Use a new `OUT` directory per run to preserve earlier failures.

**Unit tests** (`RemotePhoneTests`, one simulator, wrapped in the shared lock):

```sh
lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote \
  -destination "id=<simulator>" -derivedDataPath <dd> -parallel-testing-enabled NO test \
  -only-testing:RemotePhoneTests/AnywhereEntitlementTests -only-testing:RemotePhoneTests/EntitlementClientTests \
  -only-testing:RemotePhoneTests/AnywhereAccessTests -only-testing:RemotePhoneTests/AnywhereStoreKitTests
```

- `AnywhereStoreKitTests` drives `SKTestSession` against the `.storekit` file: products and trial, purchase (trial, `appAccountToken`, eligibility consumed), renewal to paid, expiry, refund, grace period, billing retry without grace, restore of a purchase made elsewhere, restore with nothing to restore, and the `Transaction.updates` listener.
- `EntitlementClientTests` runs the HTTP client against a `URLProtocol` stub with the contract's bodies and status codes.
- `AnywhereAccessTests` covers the handshake with a fake verifier and the signaling changes with a recording transport.
- The live store is not started inside unit tests (the app checks `XCTestConfigurationFilePath`) so the tests own the StoreKit test session.

**UI tests.** `RemotePhoneUITests/AnywherePaywallUITests` (paywall from Home with no Mac, terms above the button, plan switching, links, Not now; help-menu path; the contextual screen). Purchases are not driven through the system sheet in UI tests.

**Screenshots.** `TEST_RUNNER_FARSIDE_SNAPSHOT_DIR=<dir>` with `-only-testing:RemotePhoneTests/AnywhereStoreKitTests/testCapturePaywallScreens` renders the paywall from real test products in five states. The UI test also attaches screenshots.

**Against a service.** Debug builds derive the verify URL from the paired Mac's signaling address (`wss://host/signal` → `https://host`); `ws://127.0.0.1:port` becomes `http://127.0.0.1:port` for a local `wrangler dev`. Release builds use only `FARSIDE_SERVICE_BASE_URL` and never send a signed transaction to an address that arrived in a pairing code.

**Sandbox / TestFlight** (not done yet): TestFlight uses the sandbox automatically; renewals happen every few minutes up to the sandbox limit. Needs the ASC records below and a Sandbox Apple Account.

## 5. App Store Connect steps (Roshan; nothing was done in ASC)

1. **Agreements, tax, banking.** Account Holder signs the Paid Apps Agreement; add banking; complete tax forms (W-8BEN for an individual, or the entity form); wait until the agreement shows Active. Enroll in the App Store Small Business Program.
2. **App record** for bundle `com.roshan.PocketDesk.Remote` once the name is settled (STORE-LISTING.md).
3. **Subscription group.** Monetization › Subscriptions › Create group. Reference name and localized display name: decide between **Farside Anywhere** (what the app and website say) and **Farside Remote** (what the launch docs say) — see open question 1. Add the en-CA (and en-US) group localization.
4. **Products** in that group:
   - `com.roshan.PocketDesk.remote.yearly` — duration 1 year, **level 1**, reference name "Farside Anywhere Yearly", display name "Farside Anywhere - Yearly", description "Reach your Mac from anywhere."
   - `com.roshan.PocketDesk.remote.monthly` — duration 1 month, **level 2**, reference name "Farside Anywhere Monthly", display name "Farside Anywhere - Monthly", same description.
   - Product ids must match exactly; the app and the service (contract §2 check 4) both look for them.
5. **Prices.** Base country Canada (or decide D6): CA$49.99 yearly, CA$5.99 monthly; review Apple's equalized prices for other storefronts before saving.
6. **Introductory offer** on each product: Free, 1 week, all eligible customers, all territories. (It can't be edited later, only deleted and recreated.)
7. **Localizations** for each product (English at least); keep names ASCII.
8. **Review information** for each product: a screenshot of the paywall (use `~/Downloads/farside-paywall-paywall.png` or a fresh device capture) and the review note from APP-REVIEW-RISKS.md §8, updated to "Home › Farside Anywhere (no Mac needed)" and the new names.
9. **Family Sharing off** (permanent once on). Consider turning off multiseat/"available to organizations" if offered.
10. **Billing Grace Period**: 16 days, paid-to-paid renewals, sandbox first then production.
11. **App Store Server Notifications V2**: production and sandbox URLs both `https://<production service>/v1/appstore/notifications` (contract §6).
12. **In-App Purchase key** (Users and Access › Integrations): download once, hand to the backend through a secure channel.
13. **Sandbox Apple Account** (Users and Access › Sandbox) for TestFlight testing of trial, renewal, billing retry and refund.
14. **Build settings before the first TestFlight build**: set `FARSIDE_SERVICE_BASE_URL` to the staging host for TestFlight builds and the production host for the App Store build (contract: same host as the `/signal` address baked into the Mac); confirm `FARSIDE_TERMS_URL` and `FARSIDE_PRIVACY_URL` resolve.
15. **Submit** the group and both products with the first app version (the first subscription can't be submitted alone). Add the Terms of Use link to the App Store description (or use Apple's standard EULA field) and the Privacy Policy URL in App Information.

## 6. Open questions

1. **Name.** App UI, website and this build say **Farside Anywhere**; SUBSCRIPTION-SETUP, STORE-LISTING, APP-REVIEW-RISKS and PRIVACY-POLICY say **Farside Remote**. The ASC display names show in Apple's purchase sheet, so they should match the app. Product ids are unaffected.
2. **Device cap and deletion.** The service allows three devices per subscription (one for sandbox purchases, so a tester's second device is refused with `device_limit`) and the paywall says three. If the cap changes, update `AnywhereCopy.deviceLimitWord`. There is no in-app way yet to free a slot or honor the privacy policy's promised “Remove this Mac and delete server data” action (`/v1/entitlements/forget`, contract §5, is not wired to any UI). This is a launch blocker, not a completed deletion path.
3. **Privacy policy.** It should mention the random install identifier sent with verifications (`deviceId`) and set as `appAccountToken`; App Privacy "Identifiers" answers may need it.
4. **Terms URL.** `https://getfarside.com/terms` is a draft page on a domain not yet live. Alternatively point `FARSIDE_TERMS_URL` at Apple's standard EULA.
5. **Refund request in app** (`refundRequestSheet`) is not offered; Apple handles refunds at reportaproblem.apple.com. Add if support wants it.
6. **Free-trial copy for returning subscribers**: people who already used the trial see plain prices (tested); confirm that is the wanted wording.
7. **Time to the Anywhere card.** A plan-less phone on another network is told about Anywhere only after the ordinary reconnect attempts give up (each attempt registers again and gets `entitlement_required`). Failing fast when `registered.access` is `local` and ICE finds no route would show the card sooner; that is a change to the connection/retry logic and was left for its owners.
8. **Contract v1.2 details the phone relies on.** Tokens are bound to the deployment (a staging token fails on production, so TestFlight and App Store builds need their own `FARSIDE_SERVICE_BASE_URL`), to a live device link (a refund or `forget` stops a token at once; the phone then sees `entitlement_required` and re-verifies), and to one live room per device. Keepalive `ice` repeats and bare 1013 closes need nothing new on the phone.
9. **Contract vs. brief.** The brief's first sketch (`entitlementToken` in any field, any `deviceId`) was replaced by the frozen contract: `remote.1` feature, `entitlement` field in `register`, non-closing `entitlement_required`, 64-hex `deviceId`, `tokenExpiresAt`, Keychain-stored token, 12 h / 6 h refresh rule, 429 back-off. The verify URL follows the contract (same host as `/signal`) in debug builds; release builds require `FARSIDE_SERVICE_BASE_URL`, deliberately stricter than the contract so a pairing code can't redirect a signed transaction.
10. **Paid internet enforcement.** Issuing no TURN servers to an unentitled room does not keep encrypted peers from exchanging direct WAN candidates. The service cannot read their SDP to filter those candidates. A separate network/protocol gate and a cross-network unpaid regression are required to satisfy PRODUCT D28. Until then, do not describe free mode as technically confined to the same Wi-Fi.
