# Farside Anywhere: sandbox end-to-end test plan — 30 September 2026

Preparation only. Nothing was created, signed, deployed, built or changed in App Store Connect, Cloudflare or Xcode while writing this. App Store Connect (ASC) was read in the already signed-in Chrome session, read-only, around 30 Sep 2026. No Xcode build ran because `/tmp/farside-quiet` exists.

Branch `pocketdesk-remote-chat`, HEAD `6d83703`. Installed phone: `20260929.12`, built with `xcodebuild … -configuration Debug … FARSIDE_SERVICE_BASE_URL=https://signal-staging.getfarside.com FARSIDE_SERVICE_READY=NO build` (`work/acceptance-20260930/phone-build.log:2,11`) and installed with devicectl (`work/acceptance-20260930/phone-install.out`).

## 1. Why the paywall says "Couldn't reach the App Store"

The paywall shows two separate messages, and they have two separate causes. Either one alone disables Subscribe.

### 1a. "Couldn't reach the App Store. Check your connection, then try again."

This is the product fetch coming back empty. The wording is misleading: it has nothing to do with connectivity.

- `AnywhereStore.loadProducts()` (`RemotePhone/Anywhere/AnywhereStore.swift:80-91`) calls `Product.products(for:)` and sets `load = loaded.isEmpty ? .failed : .loaded` (line 86). An empty array is treated the same as a thrown error.
- `AnywherePaywallView.plans` shows that text whenever `offers.isEmpty && store.load == .failed` (`RemotePhone/Anywhere/AnywherePaywallView.swift:97-103`).
- Apple's `products(for:)` documentation says: "If any identifiers are invalid or the App Store can't find them, the App Store excludes them from the return value." It does not throw for missing products.
- This build was installed from the command line (`xcodebuild build` + devicectl), not by Xcode's Run action. The scheme's `storeKitConfiguration: StoreKitTesting/FarsideAnywhere.storekit` (`project.yml:125`) applies only to Xcode Run, so the app asked Apple's real **sandbox** App Store. Development-signed apps use the sandbox (Apple, *Testing In-App Purchases with sandbox*).

ASC state, read in the browser just now:

| Item | Observed | Effect |
|---|---|---|
| App `6817532560` › Monetization › Subscriptions | **No subscription group exists** (only the "Create" empty state). Streamlined Purchasing: On. Billing Grace Period: not set up. | Both product IDs are unknown to the App Store, so `products(for:)` returns `[]`. **This is the direct cause.** |
| Business › Agreements | Free Apps Agreement **Active** (28 Sep 2026 – 30 May 2027). **Paid Apps Agreement status "New"** (not signed). Banner: "you must update your legal entity information prior to signing the Paid Apps Agreement" with an **Edit Legal Entity** link. A second banner asks for the EU Digital Services Act trader declaration. | Apple lists a signed Paid Applications Agreement as a sandbox prerequisite. Apple's agreement help says new in-app purchases cannot be created until the latest Paid Apps Agreement is signed. **This blocks the fix for the direct cause.** |
| Users and Access › Sandbox › Test Accounts | **None.** | No account to buy with. |
| Users and Access › Integrations › In-App Purchase keys | **Active (0).** | Not needed for verification (see §3). Only needed for the admin test-notification endpoint. |
| App Information › App Store Server Notifications | Production and Sandbox URLs **not set**. | Renewals, expiries and refunds are not pushed to staging. The phone re-verifies instead. |

Ruled out:

- **Bundle and product IDs match.** The phone uses `com.roshan.PocketDesk.remote.yearly` and `…remote.monthly` (`RemotePhone/Anywhere/AnywhereEntitlement.swift:6-9`). The backend `ALLOWED_PRODUCT_IDS` (`Backend/wrangler.jsonc`, staging vars) and the `.storekit` file use the same IDs. The bundle ID `com.roshan.PocketDesk.Remote` (`project.yml:90`) matches the ASC record, and `APP_BUNDLE_ID` matches too. Nothing can mismatch while the products don't exist.
- **The app-ID fix is not the cause.** Commit `8a942e7` changed only backend policy, and it only affects Production transactions and notifications. Staging still runs `8dca833` (Worker `ae445b1b…`), where `APP_APPLE_ID` is empty. That older check applied only to `environment === "Production"`, so sandbox transactions pass policy on the deployed staging as well as on HEAD.

### 1b. "Farside Anywhere is temporarily unavailable… Restore Purchases remains available."

This is `FARSIDE_SERVICE_READY=NO`, and it is working as designed.

- `AnywhereService.canSell` is `ready && configured https URL` (`AnywhereEntitlement.swift:259-261`). `isReady` reads the Info key `FarsideServiceReady` and accepts only `YES` or `true` (`:279-282`). The build passed `NO`.
- The paywall shows the notice when `!subscribed && !canSell` (`AnywherePaywallView.swift:192-194`). It disables Subscribe (`:278`) and Redeem Code (`:241`). `purchase()` also refuses (`AnywhereStore.swift:117-120`).

**Bottom line:** even with `READY=YES`, Subscribe would stay disabled, because there are no offers until ASC has the products. And ASC can't have the products until the Paid Apps Agreement is signed.

## 2. What staging needs for purchase verification (already mostly in place)

`POST /v1/entitlements/verify` (`Backend/src/entitlement/verify.ts:94-…`) needs:

| Requirement | Staging status |
|---|---|
| `APPLE_ROOT_CERTS` (the verify route returns 503 without it, `verify.ts:109-112`) | Secret present (name inventory, `work/staging-transition-20260929/cloudflare-app-setup-inventory.md`) |
| `ENTITLEMENT_HASH_KEY`, `ENTITLEMENT_TOKEN_KEY` | Present |
| `ACCEPT_SANDBOX=1` | Set (`wrangler.jsonc:74`) |
| `APP_BUNDLE_ID=com.roshan.PocketDesk.Remote`, `ALLOWED_PRODUCT_IDS` | Set |
| `ALLOW_XCODE_TRANSACTIONS=0` | Correct. `config.ts:37` refuses `1` outside dev/test. |
| `CLOUDFLARE_TURN_KEY_ID` / `_API_TOKEN` (TURN for entitled rooms) | Present |
| App Store Server API key (`APPLE_IAP_ISSUER_ID`, `APPLE_IAP_KEY_ID`, `APPLE_IAP_PRIVATE_KEY`) | **Absent, and not needed to verify.** It is used only by `/v1/admin/appstore/test-notification` (`Backend/src/admin.ts`). Verification is local JWS chain validation against the pinned Apple roots. |
| ASN v2 sandbox URL `https://signal-staging.getfarside.com/v1/appstore/notifications` | Not set in ASC. Optional for the first test. Useful for renewal, expiry and refund propagation. |

**No staging deploy or secret change is required for a first sandbox purchase test.**

Sandbox specifics in code:

- One device per sandbox entitlement (`verify.ts:150`). A second phone gets `device_limit`.
- `RL_API_SANDBOX` allows 3 sandbox verifies per device per minute.

## 3. Can Xcode StoreKit-configuration testing exercise the server path?

No, not against staging:

- When the app is run from Xcode with the `.storekit` file (this works on a physical device too), purchases are `Xcode`-environment transactions. Xcode signs them with a local test certificate. Apple: "You can't validate receipts from the test environment… because the App Store doesn't sign these receipts."
- Staging rejects them (`ALLOW_XCODE_TRANSACTIONS=0`, which gives `environment_not_accepted`). The config refuses to enable that flag on any shared deployment (`config.ts:37`).

Do not relax this. It would be the same kind of hole as `ALLOW_UNENTITLED_RELAY`, which was closed on 09-29.

Xcode StoreKit testing remains useful for:

- the paywall UI, disclosure and trial wording on device
- `wrangler dev` locally (environment `dev`, which accepts unverified Xcode JWS by design)

It cannot prove Apple signature verification, the staging D1 entitlement, or staging Cloudflare TURN. Only the Apple sandbox proves those.

## 4. Relay/TURN path for a paid entitlement

No backend change is needed.

- An entitled room gets STUN plus Cloudflare TURN (`Backend/src/room.ts` `issueServers`/`checkEntitlement`). An unentitled room gets no TURN.
- The phone's diagnostics sheet has a **"Relay-only test"** toggle (`RemotePhone/HomeView.swift:674-683`). It sets `iceTransportPolicy = .relay` (`RemoteShared/PeerMedia.swift:246`), and the Route line reports `Relay`, `p2p` or `lan` (`PeerMedia.swift:39-58`).
- If the room is unentitled and the toggle is on, the phone reports relay-required-unavailable (`PeerMedia.swift:33-35`). That is itself a useful negative check.
- `TEST_FORCE_RELAY` is allowed on staging, but it would need a config deploy. It only adds a `policy:"relay"` hint and grants no TURN. It isn't needed because the phone toggle does the same job.

## 5. Checklist

### (a) An agent can do these locally, no approval needed

1. Keep this plan and the evidence above current. Don't commit unless asked.
2. Once the quiet window ends (`/tmp/farside-quiet` removed), prepare the exact test build command below. **Do not run it without the owner's go-ahead**, because it replaces the installed `.12`:
   `xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -configuration Debug -destination generic/platform=iOS -derivedDataPath <fresh dir> CODE_SIGN_STYLE=Automatic "CODE_SIGN_IDENTITY=Apple Development" DEVELOPMENT_TEAM=39HM2X8GS6 FARSIDE_SERVICE_BASE_URL=https://signal-staging.getfarside.com FARSIDE_SERVICE_READY=YES FARSIDE_ENABLE_PUSH=NO build`
   - This is a development-signed, staging-only test build. It is **not** a release artifact and never goes to `archive-phone.sh` or `validate_archive.py --service-ready yes`.
   - `READY=YES` only lets the phone *start* a sandbox checkout. The server still verifies every Apple-signed JWS, so this is not a bypass.
   - Bump `CURRENT_PROJECT_VERSION` (e.g. `20260930.1`) so the receipt identifies the build.
3. Optional code fix, pending the owner's decision because the coding rules say ask first: split `Load.failed` into `empty` versus `error`. Then an empty product list says "Plans aren't available yet" instead of "Couldn't reach the App Store", and the `StoreKitError` is logged. This would have made today's failure obvious.
4. Read-only checks once the purchase happens:
   - `curl https://signal-staging.getfarside.com/health`
   - `bunx wrangler tail farside-backend-staging --format pretty` to watch the `verify_rejected` or success events. This reads the log stream and changes nothing.
5. Plan the negative checks too: unpaid phone off-LAN is denied, a relay-only toggle while unpaid is refused, and a second phone on the same sandbox purchase gets `device_limit`.

### (b) Needs the owner's explicit approval at the time

6. **Create the subscription group and products in ASC**, after step 12 below is Active or at least signed:
   - Group reference and display name "Farside Anywhere" (matches the app and the `.storekit` file).
   - `com.roshan.PocketDesk.remote.yearly`: 1 year, level 1, CA$49.99, 1-week free-trial introductory offer, display name "Farside Anywhere - Yearly".
   - `com.roshan.PocketDesk.remote.monthly`: 1 month, level 2, CA$5.99, 1-week free trial, "Farside Anywhere - Monthly".
   - English localization, description "Reach your Mac from anywhere."
   - Family Sharing **off** (permanent once on).
   - Apple's sandbox minimum is reference name, product ID, localized name and price. The review screenshot and notes can come later, before submission.
   - Base currency is D6, still open. CAD matches the local config.
7. **Create a Sandbox Apple Account** in ASC (Users and Access › Sandbox), storefront Canada. It needs an email the owner controls that isn't already an Apple Account. The owner types the email and password; an agent must not.
8. Optional: **set the ASC Sandbox Server URL** to `https://signal-staging.getfarside.com/v1/appstore/notifications` for renewal, expiry and refund propagation. Leave Production empty until the production Worker exists.
9. Optional: **enable Billing Grace Period** in sandbox (16 days, paid-to-paid), per SUBSCRIPTION-SETUP D7.
10. **Install the `READY=YES` staging test build** on the iPhone (replaces `.12`), and later restore a `READY=NO` build if wanted.
11. Optional, not required for this test: redeploy staging from HEAD so `8a942e7`'s `APP_APPLE_ID` and the policy match the source. Also optional: generate an In-App Purchase key and put `APPLE_IAP_*` into staging secrets for the admin test-notification endpoint. Both are Cloudflare or ASC changes.

### (c) Only the owner can do these

12. **Business › Edit Legal Entity**, then **sign the Paid Apps Agreement** (Account Holder, 2FA). Complete **tax** (Canadian individual: W-8BEN plus any Canadian forms ASC asks for) and **banking**. Wait until the agreement shows **Active**.
    - Apple's help says legal-entity changes can take up to two weeks. This is the likely long pole.
    - Do the DSA trader declaration at the same time, per D37: individual, mailbox address, published phone, `support@getfarside.com`.
    - Consider enrolling in the Small Business Program.
13. On the iPhone: **Settings › Developer › Sandbox Apple Account › Sign In** with the sandbox account. For a development-signed app, this entry appears after the first purchase attempt. You can also sign in at the first purchase sheet, which shows "[Environment: Sandbox]". There's no need to sign out of the real Apple Account.
14. **Physical test run**:
    1. On home Wi-Fi, open the paywall. It should show both prices and the trial.
    2. Subscribe. The sheet should show "[Environment: Sandbox]".
    3. The status should read "Your free trial is on".
    4. Connect over **cellular with Wi-Fi off**, Mac on home Wi-Fi. It should connect, with Route showing `p2p` or `Relay`.
    5. Disconnect, turn on **Relay-only test**, and reconnect. Route must show `Relay`, which means Cloudflare TURN on staging.
    6. Let the sandbox trial and renewals run out, or Clear Purchase History in Settings › Developer. Confirm access ends and an off-LAN connect is denied again.
    7. Also try **Restore Purchases**, and then an unpaid second iPhone (or a cleared account) off-LAN, which must be denied.

## 6. Evidence and sources

- Code: `RemotePhone/Anywhere/AnywhereStore.swift:80-91,117-120`, `AnywherePaywallView.swift:97-103,192-194,241,278`, `AnywhereEntitlement.swift:6-9,259-282`, `project.yml:90,113-125`, `Backend/src/config.ts:37`, `Backend/src/entitlement/verify.ts:50-58,109-112,150`, `Backend/wrangler.jsonc` (staging vars), `Backend/src/apple/server-api.ts:19-28`, `RemotePhone/HomeView.swift:674-683`, `RemoteShared/PeerMedia.swift:20-58,246`.
- Receipts: `work/acceptance-20260930/phone-build.log`, `phone-install.out`; `Docs/launch/STAGING-TRANSITION.md`; `work/staging-transition-20260929/cloudflare-app-setup-inventory.md`.
- Apple, read 30 Sep 2026:
  - [Product.products(for:)](https://developer.apple.com/documentation/storekit/product/products(for:)) (missing IDs are excluded, not thrown)
  - [Testing In-App Purchases with sandbox](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox) (prerequisites: Paid Applications Agreement signed, products with reference name, ID, localized name and price, a Sandbox Apple Account; development-signed apps use the sandbox; Settings › Developer sign-in)
  - [Testing In-App Purchases in Xcode](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-in-xcode) (Xcode-environment receipts aren't App Store-signed)
  - [Sign and update agreements](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/) (Account Holder only; IAPs can't be created until the latest Paid Apps Agreement is signed; legal-entity updates up to two weeks). This one was read through a summarizing fetch, so recheck the wording in ASC.
