# Farside: App Review risk register and go/no-go list

**Historical research notice — refreshed 29 September 2026:** The missing-StoreKit, missing-icons/manifests and private-service-only source claims below describe the 28 September snapshot. StoreKit, backend route enforcement, privacy manifests and dependency notices are now implemented. Production readiness, the original forced-expiry discrepancy, real sandbox purchases/expiry, APNs, physical removal/input and distribution acceptance remain gates. Use [CURRENT-REVIEW-PACKET.md](CURRENT-REVIEW-PACKET.md) for current evidence; the historical legal/review analysis is not a current sign-off.

**Commerce and review refresh, 30 September 2026** (branch `farside-commerce-review`; sources in section 11):
- Pricing (PRODUCT D41): Farside Anywhere at CA$7.99 a month or CA$59.99 a year, each with a 7-day free trial. "Farside Remote" is retired in the review notes.
- 4.2.7 re-read. The guidelines still say "Last Updated: June 8, 2026", and clause (e) is intact. The section 4 analysis stands.
- Row 4.5.4 is rewritten: push exists, and its copy is now fixed and generic.
- Added:
  - multiseat (3.1.2, B15);
  - age assurance for Texas SB 2420, Utah and Louisiana (section 5a, B16);
  - agreements, including EU Attachment 14 (B17);
  - the age-rating questionnaire, including the social-media questions (B18);
  - the privacy-manifest file-timestamp note (section 8).

Prepared 28 September 2026 for the 3 November 2026 submission target. Documentation and research only; nothing was submitted, created in App Store Connect, or changed in source.

**Naming:** the product is now called **Farside** (renamed from PocketDesk on 28 Sep 2026). Bundle IDs stay `com.roshan.PocketDesk.*`, and code identifiers, target names, file paths and Info.plist keys (`PocketDeskRemote`, `PocketDeskServiceURL`, `PocketDeskStreamStats`) still say PocketDesk until engineering renames them; they are quoted verbatim.

Evidence labels used throughout: **[V]** verified from a primary source on 28 Sep 2026 (URL in Sources); **[R]** verified in this repository (file named); **[I]** inference or unverified, needs a check before relying on it; **[O]** owner action; **[E]** engineering work.

## 1. Verdict

Guideline-wise, the product is submittable. The generic-mirror remote desktop category is well established and the "free locally, paid remote" structure has a live precedent. The real risk is not policy, it is readiness: several things App Review will check do not exist yet.

Top blockers (details in section 9):

1. **No StoreKit code exists** (grep of `RemotePhone/`, `RemoteShared/` finds none). The first auto-renewable subscription must ship inside the first app version, with a working paywall, restore button and legal links. [R][V]
2. **No production backend.** `Server/` is a bounded private prototype: manual per-Mac room approval, one phone per Mac, 30-minute room cap, TURN credentials issued with no entitlement check. Guideline 2.1(a) requires the backend live during review. [R][V] A parallel workstream has since added Cloudflare relay readiness tooling and a deployment runbook (commit `cbafcea`; `Server/src/relay-config.ts`, `Server/scripts/deploy-cloudflare.sh`, `Docs/research/2026-09-28-round2/RELAY-DEPLOYMENT-RUNBOOK.md`). It is explicitly a single-owner relay run from the owner's Mac (launchd agents, Quick or named tunnel), with manual room approval, `MAX_PEERS=4`, `ROOM_LIFETIME_SECONDS=1800` and no entitlement gate, so it is an acceptance-test rig, not the public launch service. The gaps below stand. [R]
3. **The Mac companion is not distributable.** It is signed with an Apple Development certificate, and first run asks the user to type a "private service address". A notarized Developer ID build with a baked-in service URL is required before review notes can point at a download. [R]
4. **Store-upload prerequisites are missing:** no app icon asset (no `.xcassets` or `.icon` in any target), no `PrivacyInfo.xcprivacy` for the app target although the code uses `UserDefaults` and `ProcessInfo.systemUptime`, no `ITSAppUsesNonExemptEncryption`. [R][V]
5. **Name and trademark.** The product is now named Farside. The exact App Store name "Farside" is already used by a space-sandbox game (Tim Lange, released 15 Sep 2026) and an older "FarSide" app, so the store title needs a suffix (for example "Farside: Mac Remote"). "Farside" also sounds identical to "The Far Side", a live US-registered mark of FarWorks, Inc. (Gary Larson). Get a trademark opinion before creating the app record. [V] (STORE-LISTING.md section 1)
6. **Release-build hygiene:** a "Relay-only test" toggle and a hidden stream-stats switch ship in Release (2.3.1(a) hidden features), and the planned "Before you leave" readiness check, as PRODUCT.md writes it (F08), would ask people to turn off Wi-Fi, which is Guideline 2.4.4's own example. [R][V]

## 2. Basis and method

- App Review Guidelines page carries "Last Updated: June 8, 2026". I fetched the raw HTML and read the clause text directly rather than relying on a summarizer, because the summarizer dropped 4.2.7(e). [V]
- Where an Apple page was JavaScript-only, I used Apple's `tutorials/data/documentation/*.json` endpoint or App Store Connect help HTML. Apple staff (DTS) statements come from Developer Forums threads and are labelled as DTS, not App Review.
- Competitor facts come from live App Store listings (iTunes lookup API) and vendor pages checked the same day. Their review notes and rejection history are not public; anything about "how they passed" is inference from what is live.

## 3. Guideline-by-guideline applicability

Risk scale: Low (design already fits), Medium (needs a deliberate fix or note), High (will fail review as things stand).

| Guideline | What it requires (paraphrased) | Farside position | Risk | Action |
|---|---|---|---|---|
| 1.5 Developer information | Easy contact route in the app and on the Support URL; failing this can breach local law. ASC also says the Support URL must lead to real contact information (legal address, email, phone). | No support site, email or in-app contact yet. An individual account would publish a personal address. | Medium | [O] Business address or PO box, support email, phone on the support page. Link Support from Settings. |
| 1.6 Data security | Appropriate security for user information. | AES-256-GCM signaling, DTLS-SRTP media, Keychain (`WhenUnlockedThisDeviceOnly`), input-safety tests. No external security review yet (PRODUCT section 8 calls for one). | Low | [E] Schedule an independent review of `Server/` and pairing before public release. |
| 2.1(a) App completeness | Final build, working URLs, no placeholders, on-device tested, backend turned on for review. | Backend is a private prototype. Mac needs a public download. | High | See B1, B3. Keep production live 24/7 from upload to release. |
| 2.1(b) In-app purchases | IAP must be complete, visible to the reviewer and functional. | Nothing implemented. | High | See B2. Paywall reachable without a paired Mac (Settings row). |
| 2.2 Beta testing | Betas and trials belong in TestFlight, not the store. | Fine if the store build is labelled 1.0. | Low | Do not call the release a "beta" in metadata. |
| 2.3.1(a) Hidden or dormant features | No hidden, dormant or undocumented features; new functionality must be described specifically in Notes for Review. | Release build contains: "Relay-only test" toggle (`RemotePhone/HomeView.swift`, Connection Details), hidden `PocketDeskStreamStats` defaults switch (`RemoteShared/StreamStatistics.swift`), and, on the Mac companion (not itself reviewed, but the same product), a hidden browser-viewer path (`RemoteHost/BrowserMediaSession.swift`, default endpoint `127.0.0.1:8788`). | Medium | [E] Compile out the iOS items with `#if DEBUG` or list them in the review notes; disable or remove the Mac browser path in the release build so the privacy policy stays true. |
| 2.3.2 IAP disclosure in metadata | Description, screenshots and previews must say which features need an additional purchase. | Remote access needs the subscription. | Medium if omitted | Description, one screenshot and the preview must state that remote access is a subscription. |
| 2.3.3 / 2.3.4 Screenshots and previews | Show the app in use; previews may only be screen captures of the app; overlays and narration allowed. | Streamed Mac desktop is app content. | Low | Keep third-party logos off the streamed desktop (see STORE-LISTING.md). |
| 2.3.7 Names, keywords, subtitle | Unique name, at most 30 characters, keywords that describe the app; no trademarked terms, popular app names or prices; subtitles must not reference other apps or make unverifiable claims. | Marketing docs name Astropad, Jump, Screens and AI vendors. The bare name "Farside" is taken, so the store title needs a suffix. | Medium | Never use competitor or AI-vendor names in metadata. Avoid "fastest" or "lowest latency" claims. Use a suffixed title such as "Farside: Mac Remote" (19 characters). |
| 2.3.8 Age-appropriate metadata | Icons, screenshots and previews must suit 4+. | Depends on what is on the streamed desktop. | Low | Use a curated demo Mac account. |
| 2.3.10 Platform focus | No names or imagery of other mobile platforms or marketplaces. | Windows/Android are deferred ideas. | Low | Do not mention Windows, Linux or Android in metadata. |
| 2.4.1 iPhone apps run on iPad | iPhone apps should run on iPad. | `TARGETED_DEVICE_FAMILY: '1,2'`. | Low | Screenshots required for iPad 13". |
| 2.4.2 Power efficiency | No rapid battery drain or excess heat. | 60 fps H.264 decode with a visible always-on desktop; hardware paths only. | Low to Medium | [E] Measure thermals and battery over a 30-minute session; offer a reduced-frame-rate quality option. |
| 2.4.4 System settings | Never suggest or require changes to system settings unrelated to core function; the example given is telling people to turn off Wi-Fi. | The proposed "Before you leave" readiness check asks the user to turn off phone Wi-Fi for a real test (PRODUCT F08 and section 7); it is not in the app today, and `Docs/DEVICE-TEST-CHECKLIST.md` uses the same step for testers only. The shipped "Relay-only test" toggle is a test control. | Low today; Medium if F08 ships as written | [E] Detect the network path automatically and report route ("Local", "Direct", "Relay"); do not instruct anyone to change Wi-Fi. Local Network permission help is core-related and acceptable. |
| 2.4.5 Mac App Store rules | Sandbox, MAS-only updates, no downloaded code, no license screens. | Only relevant if the Mac app were on the Mac App Store; the recommendation is that it is not. | N/A | See MAC-DISTRIBUTION.md. |
| 2.5.1 Public APIs | Public APIs for intended purposes. | Phone: WebRTC (BSD), Speech, AVCapture, StoreKit. Mac: ScreenCaptureKit, CGEvent, Accessibility (public). Private virtual-display APIs were explicitly rejected in research. | Low | [E] Run App Store validation and `nm` check for private symbols on the archive. |
| 2.5.2 No downloaded code | Apps self-contained; no downloading or executing code that changes features. | iOS app downloads no code. Sparkle applies only to the Mac companion, which is outside the App Store. | Low | Keep Sparkle out of the iOS target. |
| 2.5.4 Background services | Background modes only for their intended purposes. | No `UIBackgroundModes`; full backgrounding ends the session and conceals content (`ConcealedRemoteView`). | Low | Do not add audio or VoIP modes to keep the socket alive (rejected in `Docs/research/2026-09-28/NETWORK-AND-SESSION.md`). |
| 2.5.5 IPv6-only networks | Must work on IPv6-only (NAT64) networks. | Signaling is `wss://` by hostname; ICE servers come from Cloudflare hostnames. Cloudflare TURN accepts IPv6 clients but issues IPv4 relay addresses. [V] | Medium | [E] Test on a NAT64/DNS64 network before submission; no IP literals in ICE or signaling URLs. |
| 2.5.9 Native UI integrity | Do not block standard behaviours. | Session view uses custom multi-touch and edge follow; Control Center recovery is designed. | Low | Test edge swipes, Control Center and app switcher from inside a session. |
| 2.5.14 Consent and indication when recording | Explicit consent and a clear indication when recording or logging activity, including screen recording, camera, microphone. | Mac capture is behind macOS Screen Recording consent plus a persistent menu-bar state and Stop Sharing. Voice input has an explicit mic button and listening UI. No keystroke or screen logging in code. [R] | Low | Keep a persistent Mac indicator and a visible "listening" state on the phone. |
| 3.1.1 In-app purchase | Unlock features with IAP; own license keys, QR codes and similar mechanisms not allowed; restore mechanism required. | No purchase code yet. The pairing QR must never unlock anything paid. | High until built | See SUBSCRIPTION-SETUP.md. Restore Purchases button (`AppStore.sync()`) in paywall and Settings. |
| 3.1.2(a) Subscriptions | Ongoing value, at least 7 days, works on all the user's devices, no extra tasks (social posts, check-ins). Cloud/SaaS support is an example. Free trials via ASC are allowed. | Relay and NAT-traversal service is genuine ongoing value. Monthly and yearly satisfy the minimum. Same Apple ID unlocks iPhone and iPad. | Low | Explain the value concretely in the paywall. |
| 3.1.2 Multiseat (new 16 Sep 2026) | Apple: "Starting today, multiseat purchases are enabled by default" for auto-renewable subscriptions. An organization or group buys seats and assigns them. The seat's transaction has `inAppOwnershipType` `ASSIGNED`. Taking a seat back sends `revocationType` `ASSIGNMENT_REVOKE`. Turning it off later ("No, don't allow multiseat purchases" under "Can a customer purchase multiple seats for this subscription?") stops new seat purchases. Existing group subscriptions "continue to renew until the group purchaser cancels", so any seat sold before then stays a paying customer that Farside refuses. The research note's "cancels at renewal" is wrong. [V] | Anywhere is a personal plan (3 devices, one Apple Account). The backend accepts only `PURCHASED` transactions. An assigned or family-shared seat gets 401 `not_purchased`, logged by ownership kind only. Seat notifications, including `ASSIGNMENT_REVOKE`, are recorded and never change a purchaser's subscription (`Backend/src/entitlement/verify.ts`, `notifications.ts`). [R] | Medium until ASC is set | [O] Set Multiseat to No on both Anywhere products **before the first approval** (B15, LAUNCH-CHECKLIST). |
| 3.1.2(b)/(c) Upgrade paths and disclosure | Single group so users cannot buy two variants; describe what they get before asking; Schedule 2 terms. | One group, monthly and yearly at one level. | Medium | Paywall needs price, period, renewal and cancel text, and Terms and Privacy links. `SubscriptionStoreView` shows the ASC-supplied ones. |
| 3.1.3(b) Multiplatform | Users may access features bought elsewhere if also purchasable in-app. | Mac companion sells nothing. | N/A | Website and Mac app must not sell the subscription. |
| 3.1.1(a) External purchase links | Steering to non-IAP purchase is barred outside the US storefront and entitlement cases. | Canada-priced product. | Low | No web checkout, no "cheaper on our site" language. |
| 4.1 / 4.3 Copycat and spam | Original apps; no indistinguishable variants of crowded categories. | Remote desktop is crowded but not on the named list. | Low | Lead with the differentiators (no account, trackpad-first, voice, haptics). |
| 4.2 Minimum functionality | More than a repackaged website. | Native streaming and input app. | Low | None. |
| **4.2.3(i)** | The app should work on its own without installing another app. | Needs the Mac companion. | Medium | Precedent below; explain in notes; make the on-phone onboarding excellent. |
| **4.2.7** | Extra rules for remote desktop apps that mirror specific software or services rather than a generic host mirror. | Farside is a generic host mirror. Re-read 30 Sep 2026: unchanged. | Low if positioned generically | Section 4. Alerts no longer name agents, which keeps them generic too. |
| 4.5.4 Push notifications | Push "must not be required for the app to function, and should not be used to send sensitive personal or confidential information"; no promotions without explicit opt-in and an in-app opt-out (text re-read 30 Sep 2026). 4.5.3 was clarified on 8 Jun 2026 to name Live Activities. [V] | **Implemented** (refreshed 30 Sep 2026): agent alerts (opt-in beta, off by default, iOS permission asked only when turned on) and an end-only session Live Activity. The payload is fixed keys only: `title-loc-key` `AGENT_NEEDS_YOU_TITLE` = "A task on your Mac needs you", `loc-key` body, generic categories `AGENT_HELP`/`AGENT_HELP_REMINDER`, an opaque id and pairing hash. It has no `title-loc-args`, no agent or product name (the "Show agent name" option was removed), and no prompt, file name or screen content. Details load in the app. No feature is gated on push; no marketing pushes. (`Backend/src/push.ts`, `RemotePhone/SystemIntegrations/AgentAlertPayload.swift`, `Localizable.strings`) [R] | Low | Keep the title fixed (Shortcuts recipes match it, `SHORTCUTS-RECIPES.md`). Declare the push token in the privacy answers and policy. Real APNs delivery is still an acceptance gate. |
| 4.8 Login services | Equivalent option if using third-party or social login as the primary account method. | No accounts at all. | N/A | Keep it that way; avoid adding Google or Apple login for v1. |
| 5.1.1(i) Privacy policy | Link in ASC metadata and inside the app; states data, uses, retention, deletion and consent withdrawal, and that partners match the policy. | No policy or in-app link exists. | High | PRIVACY-POLICY.md draft; [O] host it; [E] Settings link. |
| 5.1.1(ii)-(iv) Consent and minimization | Consent for collection; paid features must not depend on data consent; respect permission choices, offer alternatives. | Camera denied gives paste code; microphone denied gives typing; Local Network denied needs help text. | Low | Verify each denial path on device. |
| 5.1.1(v) Account sign-in and deletion | Let people use the app without login unless account features exist; account deletion required if accounts exist. | No accounts. Server-side records still need a deletion path for the policy. | Low | [E] "Remove this Mac and delete server data" action. |
| 5.1.2(i) Sharing and tracking | Disclose third-party sharing; ATT for tracking. | No tracking, no ads, no analytics SDK. Cloudflare is a processor. | Low | Do not add `NSUserTrackingUsageDescription`. |
| 5.2.1 / 5.2.5 IP and Apple products | No third-party trademarks, misleading names or confusing imitation of Apple products. Apple lets a trademark owner file a claim against an app name (ASC). | "Farside" versus THE FAR SIDE (FarWorks, Inc., US Reg. 6255846, Class 41 entertainment services, live; other FarWorks marks reported for prints, books, cards and calendars [V for 6255846; I for the rest]) and two apps already named Farside or FarSide. Apple device art in screenshots. | Medium | Trademark opinion before submission; keep the name one word, never "Far Side" or "The Far Side"; no cartoon imagery; use Apple marketing-resource device frames only if licensed, or none. |

## 4. Guideline 4.2.7 in detail

**Re-checked 30 September 2026.** The raw guidelines HTML still carries "Last Updated: June 8, 2026", and the 4.2.7 text below, clause (e) included, is unchanged. Nothing in this section's analysis changes. The alert change (row 4.5.4) removes the one place the app named third-party products outside the Mac's own screen.

**Text [V, raw guidelines HTML].** If a remote desktop app acts as a mirror of specific software or services rather than a generic mirror of the host device, it must satisfy (a) connect only to a user-owned personal computer or dedicated game console, with host and client on the same local, LAN-based network; (b) all software runs and renders on the host and the client may not use APIs or platform features beyond streaming the remote desktop; (c) all account creation and management is initiated from the host; (d) the client UI must not resemble an iOS or App Store view, offer a store-like interface, or let the user browse, select or purchase software they do not already own; and (e) thin clients for cloud-based apps are not appropriate for the App Store. (The first web summary I obtained dropped clause (e); the raw page text has it.)

**Does it apply?** The gate is the first clause: it applies only if the app is a mirror of specific software or services. Farside streams the whole selected display of the user's own Mac and injects generic pointer and keyboard input. That is the generic host mirror. Jump Desktop, Screens 5 and Astropad Workbench all offer remote-over-internet access to arbitrary desktops and are live, which is consistent with 4.2.7(a)'s LAN restriction not being applied to generic mirrors. [V that they are live and connect over the internet; I that this is why they are permitted]

**What could tip it into scope.** The product plan (PRODUCT sections 2, 4 and 12; `Docs/research/2026-09-28/AGENT-INTEGRATION.md`) positions Farside around "your existing Mac workspace from the AI chat you already use", chat links, an MCP viewer, agent takeover and possible app launchers or macros. If any of that shipped in v1 as a way to open or drive a particular product, App Review could reasonably say the app mirrors specific software or services and then hold it to (a), which would forbid off-LAN use. Rules for launch:

1. Reconcile the exact submission’s source disposition. Generic owner-bound agent notifications and the ID-only help route are mounted in the current app; the route now preserves an unknown origin and cannot invent the selected Mac as its producer. This does not establish that an embedded product-specific viewer, MCP transport, agent takeover or app launcher is exposed. Review and document every enabled entry point in the exact submitted artifact; do not reuse the older “routes unmounted” assertion. Expanded feature preparation does not itself resolve App Review acceptance.
2. Metadata describes a generic tool: "your Mac", "your desktop", "check on long-running builds, renders and AI tasks". No named third-party services or their logos.
3. No app launcher, app-aware shortcut strips or macros in v1 (PRODUCT section 11 already defers them).
4. The client UI is a viewer and controller, not a store-like surface; there is no software catalogue.
5. Account creation: there is none, so (c) is met by construction.

If a future release adds workflow features tied to specific products, re-read 4.2.7(a) and (b) first and consider asking App Review for pre-clearance through the Resolution Center.

## 5. "Free on the same network, paid to reach it from anywhere" under 3.1.x

**Permitted structure.** Guideline 3.1.2(a) allows auto-renewable subscriptions in any category if they provide ongoing value, list "software as a service" and "cloud support" among examples, and explicitly allow free trials configured in App Store Connect. Nothing in 3.1 prohibits a free tier plus a subscription for extra functionality; the constraint is that unlocking must go through IAP (no keys, QR codes or own mechanisms) and be restorable. [V]

**Live precedent.** "Remote Mac Desktop Control" is on the US App Store as a free app with in-app purchases (Premium Monthly US$7.99, Annual US$47.99, Lifetime US$99.99), describes automatic connection over local networks with optional secure relay for remote access, uses QR pairing with no account, ships a notarized open-source Mac helper, and reports "does not collect any data from this app". That is nearly the same structure as Farside. [V listing, 28 Sep 2026]

**Conditions Farside must meet.**

- Be honest that "free" means free on the local network. Say so in the description and screenshot (2.3.2, 2.3.1(a) on misleading marketing).
- The subscription must add real service, which it does: relay servers, NAT traversal help and signaling that cost money per byte. The pitch is not "we removed a feature".
- Do not gate the free tier behind data consent (5.1.1(ii)) or behind a purchase of something unrelated.
- The paywall must show price, period, renewal and cancellation terms with working Terms and Privacy links (3.1.2(c)).
- Provide Restore Purchases. Purchases must work on iPhone and iPad with the same Apple ID (3.1.2(a)).
- Trial: 7-day free trial configured in ASC, not a self-made counter. The Guideline text about "XX-day Trial" non-consumables applies only to non-subscription apps. [V]
- No steering to web checkout from a Canada-priced app.
- The reviewer must be able to reach the paywall and complete a sandbox purchase without a paired Mac.

**Design consequence to decide now (decision D1).** A free user on cellular whose Mac is behind a friendly NAT can often connect peer-to-peer using STUN alone, at no cost to us. If "remote is paid", decide whether that direct path is allowed. See SUBSCRIPTION-SETUP.md section 2; the recommended answer is to hard-gate only what costs money (TURN credentials) and enforce "same network" for free users at the candidate level on the Mac. Whatever is chosen, the metadata must match the behaviour.

## 5a. Age assurance: Texas SB 2420, Utah, Louisiana (decision, 30 Sep 2026)

**What the laws and Apple require [V].**
- **Texas SB 2420.** It applies to new Texas Apple Accounts since 4 Jun 2026, after a court lifted the injunction. Minors under 18 need parent or guardian consent for downloads, In-App Purchases and "significant changes". A parent "can withdraw consent for any app, which will block launching of the app on the child or teen's device". Apple says "it's the developer's responsibility to determine when there's a significant change". Texas law treats an age-rating change as significant.
- **Utah and Louisiana.** Age categories are shared for new Apple Accounts in Utah from 6 May 2026 and in Louisiana from 1 Jul 2026. The same Declared Age Range, Significant Change and Significant Update tools apply.
- **Apple's tools:**
  - Declared Age Range (`AgeRangeService.requiredRegulatoryFeatures`, iOS 26.4, which reports `significantAppChangeRequiresParentalConsent`, `significantAppChangeRequiresAdultNotification` and `declaredAgeRangeRequired`);
  - PermissionKit's Significant Change API;
  - the App Store Server Notification `RESCIND_CONSENT`. It "indicates the parent or guardian has withdrawn consent for a child's app usage". Its payload carries `appData.signedAppTransactionInfo` instead of `data`.

**What Farside does.**
1. **Server: consent withdrawal stops Anywhere** (`Backend/src/entitlement/notifications.ts`, migration `0004_consent_stop.sql`).
   - On a verified `RESCIND_CONSENT`, the service stores an HMAC of the app transaction's `appTransactionId`. Every Anywhere subscription verified under it stops, and live rooms end at once.
   - Later verifications under that app transaction answer `consent_revoked`, even after a renewal or a new purchase.
   - This complements Apple's own launch block: it also ends a paid relay session that is already running.
   - Recovery after a parent re-consents is a manual support step. The stop row is deleted 365 days after it no longer refers to any subscription.
2. **Phone: record only.** `RegulatoryFeatureCheck` (`RemotePhone/Anywhere/AnywhereStore.swift`) asks `requiredRegulatoryFeatures` at launch on iOS 26.4 or later (`#available`-guarded). It stores the answer in this phone's UserDefaults and logs only a count.
   - It blocks no one, adults included, and shows no UI. Nothing in the API makes UI mandatory by itself: the features describe what *a significant change* needs.
   - Without the Declared Age Range entitlement, the call never returns on the iOS 27 simulator (seen 30 Sep 2026). A 10-second timer then records "unavailable", and nothing is stored. Enabling the capability is an owner decision, together with the privacy-label wording.
3. **No significant change is planned.** Farside's content does not vary with age, and the expected rating is 4+ (section 5b).
   - If a future release changes the age rating or adds a feature a parent would reasonably need to approve, that release must adopt PermissionKit's Significant Change flow for minors, and `showSignificantUpdateAcknowledgment` for adults where `significantAppChangeRequiresAdultNotification` is required, before shipping.
   - Add this to the release checklist for every version.

**Why this is enough for 1.0 [I; not legal advice].**
- Farside collects no age data and has no accounts.
- Its only purchasable feature is already gated by Apple's own parental purchase consent (Ask to Buy / SB 2420 purchase consent).
- Apple enforces download consent and the post-revocation launch block.
- The developer duties that remain are to react to revocation (done server-side) and to judge significant changes (none planned). Record counsel's view if one is obtained.

## 5b. App Store Connect gates added 30 Sep 2026

- **Agreements.** Apple added Attachment 14 to the Apple Developer Program License Agreement, covering updated EU terms (alternative distribution, alternative payments, business terms), "effective October 1, 2026". The Account Holder must "sign in to your account to accept the updated terms". Unaccepted agreements block submission and paid-app changes [V] (B17).
- **Age-rating questionnaire, all answers "No".** Answer every question in App Store Connect, including the social-media questions added 9 Jul 2026 and required for submissions from September 2026 [V] (B18).
  - In-App Controls: Parental Controls No, Age Assurance No.
  - Capabilities: Unrestricted Web Access No, User-Generated Content No, **Social Media No** (no feed or discovery of user content; Apple's definition is "redistribute, amplify, or interact with user-generated content through a social feed or similar discovery method"), Messaging and Chat No, Advertising No.
  - Mature Themes, Medical or Wellness, Sexuality or Nudity, Violence, and Chance-Based Activities: all No.
  - Expected result: 4+, matching Jump Desktop, Screens 5 and Astropad Workbench.
  - **Web access judgement [I].** Farside shows the owner's own Mac, which may include a browser the owner runs there. The app has no browser, fetches no web content and has no URL field, so "Unrestricted Web Access" is answered No, as the approved remote-desktop precedents are rated. If App Review disagrees, the fallback is to answer Yes (the rating becomes 18+) rather than argue.

## 6. How competitors got through (evidence only)

| App | Store facts [V, live 28 Sep 2026] | Mac side | What it suggests |
|---|---|---|---|
| Astropad Workbench (Astro HQ LLC) | Utilities, Business; 4+; free with subscription; iOS 26+; version 1.3.1 released 17 Sep 2026; 182 ratings, 4.82. Privacy label: Data Linked to You (Contact Info, User Content, Identifiers), Data Not Linked (Usage Data, Diagnostics). Requires an account. | Direct download from downloads.astropad.com; macOS 15+. Product page says free 20 min/day; App Store text says 30 min/day. | Remote-over-internet generic mirror is approved. Host is outside the store. |
| Jump Desktop (PhaseFive) | Business, Utilities; 4+; paid app US$14.99 on iOS; version 10.15.31 released 26 Sep 2026. Label: Data Not Linked (Email, Name, Crash, Performance, Other Diagnostic). | "Jump Desktop Connect" host is downloaded from the vendor site, not the Mac App Store. Its docs list Screen Recording and Accessibility, plus a Remote Desktop permission on macOS 14+ for unattended access. | Client can be on the store; host is direct. |
| Screens 5 (Edovia) | Utilities, Productivity; 4+; free with IAP Monthly US$3.99, Yearly US$29.99, Lifetime US$179.99. Label: Data Not Linked (Identifiers, Usage, Diagnostics). iPhone, iPad, Mac, Vision. Release notes of 20 Jun 2026 say remote access is now built in. | Standalone "Screens Connect" for older Macs and Windows is a separate download; whether the built-in host is sandboxed is not established. | Subscription plus lifetime on the store is fine. |
| Remote Mac Desktop Control | Utilities; free with IAP US$7.99 / 47.99 / 99.99; no data collected; local network with optional relay. | Notarized open-source helper, separate download. | Closest structural precedent. |

Not knowable from public data: review notes they supplied, rejections they hit, or whether any needed an appeal. Treat the above as "what is approved and live", not "what App Review told them".

## 7. What App Review will need from us

Apple states that over 40% of unresolved issues fall under 2.1 and advises demo accounts, detailed notes for special setup, and demo videos for hard-to-replicate environments. [V]

**No demo Mac is provided by Apple.** Farside needs a Mac running the companion. Plan for a reviewer with an ordinary current Mac and a phone on the same Wi-Fi. There is no login, so there is no demo account. Do not ship a fake "demo desktop" as the reviewer's path unless it is clearly labelled sample content (2.3.1); the DEBUG-only layout preview in `RemotePhone/DesktopPreview.swift` must stay DEBUG-only.

Provide all of the following:

1. **Notes for Review (up to 4000 bytes):** template below.
2. **Public, notarized Mac download link** that works without an account, with the stated requirement: macOS 26 or later on a Mac with Apple silicon (M1 or later) (D35).
3. **Demo video** (two to three minutes, unlisted link and, if ASC allows, an attachment) showing: first launch, Mac install, permissions, QR pairing, approval on the Mac, live view, click, scroll, keyboard, voice, Stop Sharing, paywall, sandbox purchase, relay connection.
4. **Backend live** and monitored for the whole review window. Rate limits must not lock out a reviewer who reconnects a dozen times; the current 12 credential issues per minute and 30-connection-per-minute limits in `Server/.env.private.example` are too tight for a shared review window and for a public launch.
5. **Sandbox purchase support on the server.** App Review and TestFlight transactions are sandbox transactions; the entitlement service must accept sandbox-signed transactions from those builds (see SUBSCRIPTION-SETUP.md).
6. **Reachable contact** (phone and email in ASC) during the review window; check the Resolution Center twice a day.
7. **Network expectations:** review may run on IPv6-only or firewalled networks. TURN over TLS on 443 must work and signaling must be IPv6-compatible.

Notes for Review template (fill the brackets; keep under 4000 bytes):

```
Farside lets you see and control your own Mac from your iPhone or iPad.
It is a generic remote desktop for the user's own computer. It does not mirror
or launch any particular app or service, and there are no accounts.

REQUIREMENTS: a Mac with Apple silicon (M1 or later) on macOS [26.0] or later
running the free Farside companion: [https://<download URL>] (notarized; open the DMG, drag to
Applications). Phone and Mac on the same Wi-Fi for the free path.

TEST STEPS (about 5 minutes)
1. Install and open Farside on the Mac. Grant Screen Recording and
   Accessibility when asked (System Settings). The menu-bar icon shows status.
2. Mac window shows a pairing QR. On the iPhone: Add Mac, allow Camera, scan.
   (Camera denied? "Paste a pairing code" on Home works too.)
3. Approve the phone on the Mac. The Mac screen appears; drag to move the
   pointer, tap to click, two-finger drag scrolls. Microphone button dictates
   text using on-device speech recognition; nothing is sent to us.
4. Stop Sharing in the Mac menu bar ends access at any time. Sending the app
   to the background ends the session by design (no background modes).

IN-APP PURCHASE: "Farside Anywhere" (auto-renewable, group "Farside
Anywhere", com.roshan.PocketDesk.remote.monthly CA$7.99 and
com.roshan.PocketDesk.remote.yearly CA$59.99, 7-day free trial). Remote access
= relay + NAT traversal servers, needed when the phone is not on the Mac's
network. On Home, tap Farside Anywhere (or ? > Farside Anywhere); no Mac is
required to reach the paywall; Restore Purchases is on the same screen.
Sandbox purchases are accepted
by our server. Same-network use is free and needs no purchase.

PERMISSIONS: Camera (scan pairing code), Local Network (find the paired Mac on
Wi-Fi), Microphone and Speech Recognition (optional dictation, on-device).
No tracking, no ads, no analytics SDK. Privacy policy: [URL].

BACKEND: [signaling/relay URL] is live and monitored for the review period.
Contact: [name, +country code phone, email], reachable [hours].
Demo video: [link].
```

## 8. Permissions, privacy and hidden-feature checks App Review will notice

Current purpose strings (`project.yml`, `PocketDeskRemote`): camera "Scan the pairing code shown on your Mac."; local network "Discover and connect securely to your paired Mac."; microphone "Use your microphone to dictate text for your Mac."; speech "Turn your speech into text for the active field on your Mac." These are clear and accurate; add "on this device" to the speech string once the on-device requirement (`requiresOnDeviceRecognition = true`, `VoiceInputController.swift`) is final, because it is a privacy selling point.

Add before submission: `PrivacyInfo.xcprivacy` (required-reason APIs: UserDefaults `CA92.1`, system boot time `35F9.1`), `ITSAppUsesNonExemptEncryption`, an app icon, a "Legal and licenses" screen containing the WebRTC BSD-3-Clause and Google WebRTC notices (`Docs/WebRTC-distribution-license.md` shows the required text), a Support link and a Privacy link. See PRIVACY-POLICY.md.

Also check: the iPad orientation set. `project.yml` lists only portrait and both landscapes for the shared target; historically iPad multitasking apps had to list all four orientations or opt out of multitasking (ITMS-90474). This may be obsolete on iPadOS 26 windowing. [I] Verify at the first TestFlight upload rather than assume.

**File timestamps (checked 30 Sep 2026).** Any read of file creation or modification dates is a required-reason API (`NSPrivacyAccessedAPICategoryFileTimestamp`). WebRTC is not on Apple's list of SDKs that need their own signed manifest.
- **Phone target.** This branch reads no file timestamps in Release. `RemoteShared/E2ESupport.swift` reads one, but it is `#if DEBUG`.
- **Mac companion.** `RemoteHost/HostLoginItem.swift` already reads the bundled helper's modification date, and `RemoteHost/PrivacyInfo.xcprivacy` does not declare FileTimestamp yet.
- **File transfer** (branch `farside-transfer`, commit `4450ecf`, not yet on `pocketdesk-remote-chat`) declares FileTimestamp with `C617.1` (files in the app or app-group container) and `3B52.1` (files the person picked) in the phone, Mac and share-extension manifests. That covers both.
- **Rule.** When file transfer integrates, keep `C617.1` in every manifest whose target reads timestamps. If file transfer slips, add `C617.1` to the Mac manifest on its own. Re-check the phone's Xcode Privacy Report on the archive.

Opt out of "iPhone and iPad apps on Apple silicon Macs" in ASC (Pricing and Availability). A phone app that controls a Mac makes no sense running on a Mac, and ASC makes availability opt-out, not opt-in. [V]

## 9. Go/no-go list

Severity: **BLOCKER** stops submission, **HIGH** likely rejection or bad first week, **MEDIUM** fix but not fatal.

| ID | Item | Evidence | Fix | Owner | Needed by |
|---|---|---|---|---|---|
| B1 | Production signaling and relay live, no manual approval, no 30-minute cap, more than one phone per Mac, sane rate limits, monitoring | `Server/README.md`, `Server/src/server.ts` (`isRoomApproved`, `maxRoomLifetimeMs`), `.env.*.example` (`ROOM_LIFETIME_SECONDS=1800`, `MAX_PEERS=4`) | Deploy hosted service; automate device enrollment; raise lifetime toward the 48-hour Cloudflare credential ceiling and add mid-session refresh (lease renewal and credential refresh landed 29 Sep, see `Docs/research/2026-09-28-round2/SESSION-LENGTH-FIX.md`; the device check is still open) | E | 23 Oct (staging), 30 Oct (prod) |
| B2 | StoreKit 2 paywall, restore, entitlement gate on TURN issuance, App Store Server Notifications v2 endpoint | No StoreKit code; `Server/` issues TURN to any approved room | SUBSCRIPTION-SETUP.md | E | 23 Oct |
| B3 | Developer ID + notarized Mac companion with baked-in production `PocketDeskServiceURL`, public download page | `project.yml` uses `Apple Development`; `HostSetupView` `.needsService` asks the user for a URL | MAC-DISTRIBUTION.md | E + O | 16 Oct (first beta), 30 Oct (final) |
| B4 | App icon, launch screen sanity, privacy manifest, encryption key, version 1.0 | No assets folder; `MARKETING_VERSION: '0.1'` | Add assets and plist keys | E | 2 Oct (needed for first TestFlight) |
| B5 | Privacy policy, Support URL with contact info, Marketing URL, Terms | None exist | PRIVACY-POLICY.md, STORE-LISTING.md outline | O | 12 Oct (needed for external TestFlight) |
| B6 | Name and trademark cleared | STORE-LISTING.md section 1: "Farside" exact name taken on the App Store; THE FAR SIDE registration live | Trademark opinion (Canada, US); decide the suffixed store title; then create the app record | O | 2 Oct |
| B7 | Apple business setup: Paid Apps Agreement, banking, tax forms, DSA trader status | Required before IAP submission; bank verification takes time | Owner steps in LAUNCH-CHECKLIST.md | O | 9 Oct |
| B8 | Remove or document hidden features (Relay-only toggle, stats switch, browser viewer path) | See 2.3.1(a) row | `#if DEBUG` or list in notes | E | 16 Oct |
| B9 | Design the readiness check (F08) without asking users to change Wi-Fi (2.4.4) | PRODUCT F08, sections 7 and 9 | Automatic route detection | E | 16 Oct |
| B10 | IPv6-only (NAT64) pass | 2.5.5 | Test matrix run | E | 23 Oct |
| B11 | Clipboard: if shipped, explicit user-initiated text only; if not ready, absent from UI and copy | "In progress" per owner; `Docs/research/2026-09-28/BUILD-PRIORITIES.md` P1 | Decide by 16 Oct; cut if slipping | E | 16 Oct |
| B12 | Export compliance decision and, if needed, France declaration or exclusion; annual BIS report plan | PRIVACY-POLICY.md section 4 | Owner and counsel | O | 9 Oct |
| B13 | Fresh-user test: someone who has never seen the app completes install, pair, control, purchase | PRODUCT section 9 acceptance | Two dry runs | O | 28 Oct |
| B14 | Persistent Content Capture request filed (affects Mac re-approval prompts, not iOS review) | Apple form exists; approval time unknown | [O] Submit now | O | 2 Oct |
| B15 | Anywhere products: Multiseat = No | Multiseat on by default since 16 Sep 2026. Disabling it after approval leaves existing group subscriptions renewing, and the backend refuses those `ASSIGNED` seats. | [O] Set before the first approval (LAUNCH-CHECKLIST) | O | Before submission |
| B16 | Age-assurance handling deployed | `RESCIND_CONSENT` handling and migration `0004_consent_stop.sql` are in source (`farside-commerce-review`), not deployed | [E] Apply migration 0004 and deploy to staging, then production, after approval | E | 23 Oct (staging), 30 Oct (prod) |
| B17 | Updated agreements accepted (EU Attachment 14, effective 1 Oct 2026) | Apple news 18 Aug 2026 | [O] Account Holder accepts in the developer account | O | 1 Oct |
| B18 | Age-rating questionnaire complete, social-media questions included | Required for submissions from Sep 2026 | [O] Answer all "No" (section 5b) | O | 30 Oct |

**Gate on 2 November (go/no-go):** all BLOCKER rows closed; sandbox purchase and restore verified on TestFlight; a cellular session and a forced-relay session pass on two different real networks; NAT64 pass; 50 connection cycles and a 30-minute session (PRODUCT section 9); privacy answers entered; review notes and video finished; production backend has run 72 hours without a restart-worthy incident. If B1 or B2 is red on 23 October, use the fallback in LAUNCH-CHECKLIST.md (ship 1.0 as free local-network only and add Farside Anywhere in 1.1).

## 10. Likely rejection messages and prepared responses

| Likely message | Guideline | Prepared response |
|---|---|---|
| "We could not test without a Mac / could not complete pairing" | 2.1(a) | Point to the notarized download, the five-step notes, the video; offer a live call; check the backend logs for the reviewer's attempt. |
| "App requires installation of another app" | 4.2.3(i) | Explain it is a remote desktop client for the user's own computer, the same architecture as approved remote desktop apps, and cite 4.2.7 recognizing host-side software. Provide the video. |
| "Paywall or IAP not found or not functional" | 2.1(b) | Give the exact tap path (Home › Farside Anywhere), the sandbox behaviour, product IDs; confirm the subscription was submitted with this version. |
| "Subscription information missing" | 3.1.2(c) | Add price, period, renewal and cancellation text, Terms and Privacy links. |
| "Metadata does not indicate features requiring purchase" | 2.3.2 | Add wording to the description, a screenshot caption and preview text. |
| "App suggests changing Wi-Fi settings" | 2.4.4 | Explain it is a test diagnostic, remove the instruction. |
| "Hidden or undocumented features" | 2.3.1(a) | List the diagnostic switches or remove them. |
| "Privacy policy incomplete or link broken" | 5.1.1(i) | Fix; the policy must list retention, deletion and consent withdrawal and third-party processors. |
| "Mirror of specific software" | 4.2.7 | Show the metadata is generic, no launcher, no named services. If they still classify it as specific, ask before conceding (a): the LAN-only condition would end remote access. |

Appeals: one appeal to the App Review Board per rejection, after responding to any information request. Expedited review is only for critical bug fixes or event-tied apps, not launch dates. [V] Timeline reference: Apple states about 90% of submissions are reviewed in under 24 hours, so a 3 Nov submission leaves room for about two rejection cycles before 17 Nov if each fix is resubmitted the same day (this is my planning estimate, not an Apple commitment). [V for the statistic]

## 11. Sources for the 30 September 2026 refresh

- App Review Guidelines, raw HTML re-read 30 Sep 2026 ("Last Updated: June 8, 2026"; 4.2.7 and 4.5.4 text): https://developer.apple.com/app-store/review/guidelines/
- Multiseat on by default (16 Sep 2026): https://developer.apple.com/news/?id=likeohx4 ; purchase options: https://developer.apple.com/help/app-store-connect/manage-subscriptions/manage-purchase-options-for-auto-renewable-subscriptions
- `inAppOwnershipType` (`ASSIGNED`): https://developer.apple.com/documentation/appstoreserverapi/inappownershiptype ; `revocationType` (`ASSIGNMENT_REVOKE`): https://developer.apple.com/documentation/appstoreserverapi/revocationtype ; notifications changelog: https://developer.apple.com/documentation/appstoreservernotifications/app-store-server-notifications-changelog
- `RESCIND_CONSENT`: https://developer.apple.com/documentation/appstoreservernotifications/notificationtype ; `appData`: https://developer.apple.com/documentation/appstoreservernotifications/appdata ; `responseBodyV2DecodedPayload`: https://developer.apple.com/documentation/appstoreservernotifications/responsebodyv2decodedpayload
- Texas: https://developer.apple.com/news/?id=sg176nne (3 Jun 2026), https://developer.apple.com/news/?id=2ezb6jhj ; Utah and Louisiana: https://developer.apple.com/news/?id=f5zj08ey ; `requiredRegulatoryFeatures`: https://developer.apple.com/documentation/declaredagerange/agerangeservice/requiredregulatoryfeatures (also the Xcode 27.0 27A266a `DeclaredAgeRange.swiftinterface`)
- Agreements / Attachment 14: https://developer.apple.com/news/?id=0cgo95n6 ; social-media age-rating questions: https://developer.apple.com/news/?id=tlur8uvi ; age-rating values: https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/

## Sources (all checked 2026-09-28)

- App Review Guidelines, "Last Updated: June 8, 2026": https://developer.apple.com/app-store/review/guidelines/
- App Review overview (turnaround, 2.1 statistic, appeals, expedite): https://developer.apple.com/distribute/app-review/
- Platform version information (field limits, Support URL contact requirement, App Review information notes limit): https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/
- Manage availability of iPhone and iPad apps on Macs with Apple silicon: https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-of-iphone-and-ipad-apps-on-macs-with-apple-silicon/
- Upcoming requirements (Xcode 26 SDK rule effective 28 Apr 2026, age rating update): https://developer.apple.com/news/upcoming-requirements/
- Required-reason API documentation and manifest requirement: https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api and https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype
- Cloudflare TURN FAQ, page dated 14 Jul 2026 (IPv6, TLS ports, pricing): https://developers.cloudflare.com/realtime/turn/faq/
- Live listings: https://apps.apple.com/us/app/astropad-workbench/id6758788573 , https://apps.apple.com/us/app/jump-desktop-rdp-vnc-fluid/id364876095 , https://apps.apple.com/us/app/screens-5-vnc-remote-desktop/id1663047912 , https://apps.apple.com/us/app/remote-mac-desktop-control/id6790186904 (data pulled through https://itunes.apple.com/lookup)
- Workbench product page (direct Mac download, pricing): https://astropad.com/product/workbench/
- Jump Desktop Connect install and permissions docs: https://docs.jumpdesktop.com/connect/install/ , https://docs.jumpdesktop.com/connect/macos-permissions/
- Screens release notes (5.8.9, 20 Jun 2026): https://help.edovia.com/en/screens-5/faq/release-notes
- Repository evidence: `project.yml`, `RemotePhone/HomeView.swift`, `RemoteShared/StreamStatistics.swift`, `RemoteHost/HostSetupView.swift`, `RemoteHost/BrowserMediaSession.swift`, `Server/README.md`, `Server/src/server.ts`, `Docs/research/2026-09-28/*.md`
