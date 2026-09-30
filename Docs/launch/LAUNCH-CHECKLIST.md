# Farside: launch checklist, 28 September to 17 November 2026

Prepared Monday 28 September 2026. Targets from the owner: **submit for App Review Tuesday 3 November, launch Tuesday 17 November.** PRODUCT.md proposes a go/no-go on Monday 2 November. Documentation only; nothing here has been executed.

**Naming:** the product is **Farside** (renamed from PocketDesk on 28 Sep 2026). Bundle IDs stay `com.roshan.PocketDesk.*`; code identifiers, target names and plist keys still say PocketDesk until engineering renames them.

Legend: **[O]** the owner must do it himself (account holder actions, legal, money, identity, anything that needs his login or signature); **[E]** engineering; **[B]** both. **[V]** verified from a primary source today; **[I]** planning estimate or unverified. Effort figures are scheduling estimates, not commitments; the repo's own ranges are quoted where they exist (`Docs/research/2026-09-28/BUILD-PRIORITIES.md`).

Sibling documents: APP-REVIEW-RISKS.md, MAC-DISTRIBUTION.md, PRIVACY-POLICY.md, STORE-LISTING.md, SUBSCRIPTION-SETUP.md, and, from other workstreams, ASO-STRATEGY.md and APPLE-PORTAL-SETUP-2026-09-28.md.

## 1. Critical path in one table

| Date | Milestone | Depends on |
|---|---|---|
| Fri 2 Oct | Name and trademark decision; Apple business setup started; app icon, privacy manifest and encryption key in the build | Owner decisions, engineering |
| Thu 8 Oct | First **internal** TestFlight build | App record, icon, manifest, compliance |
| Tue 13 Oct | First **external** TestFlight build submitted (Beta App Review) | Privacy policy URL, test information, staging backend |
| Fri 16 Oct | **Scope freeze**: staging backend with entitlement gate; StoreKit paywall in app; first Developer ID Mac beta | Server work, StoreKit work, Developer ID certificate |
| Fri 23 Oct | Production backend deployed and load-tested; network matrix (cellular, forced relay, NAT64) passed; assets captured | Deployed service |
| Thu 29 Oct | **Release candidate** uploaded | Bug bash complete |
| Fri 30 Oct | Code freeze; metadata, privacy answers, review notes and video complete | Legal review |
| Mon 2 Nov | **Go/no-go** (criteria in APP-REVIEW-RISKS.md section 9) | All above |
| Tue 3 Nov | **Submit** app version, subscription group and both products together | Go decision |
| Fri 6 Nov | Last day to resubmit after a first-round rejection and still land by about 10 Nov | Prepared responses |
| Tue 10 to Fri 13 Nov | Approval window (Apple reports about 90% of reviews finish in under 24 hours [V]); Mac DMG and site staged | Approval |
| Mon 16 Nov | Final smoke test on the release build; hold or go | Approval |
| **Tue 17 Nov** | **Release**; publish Mac DMG, appcast and website; monitor 72 hours | |
| Mon 1 Feb 2027 | US annual encryption self-classification report due if counsel says it applies [V date] | Counsel |

Calendar notes: Canadian Thanksgiving is Mon 12 Oct; Remembrance and Veterans Day fall on Wed 11 Nov; US Thanksgiving is Thu 26 Nov, after launch.

## 2. Decisions to make this week

| # | Decision | By | Notes |
|---|---|---|---|
| D1 | **Name clearance: Farside versus The Far Side.** The exact store name "Farside" is taken (a space-sandbox game released 15 Sep 2026 and an older "FarSide" app), so the store title needs a suffix, working default "Farside: Mac Remote". "The Far Side" is a live US-registered mark of FarWorks, Inc. (Reg. 6255846, Class 41, Sections 8 and 15 accepted 4 May 2026 [V]). Commission a written trademark opinion (Canada and US) before creating the app record; keep the name one word; no cartoon imagery; have a fallback name. See STORE-LISTING.md section 1. | Fri 2 Oct | [O] Do not reserve the name in App Store Connect until this is answered. |
| D2 | Legal owner: individual or company. Drives trader status, published address, tax forms, D-U-N-S, copyright line, trademark filer. | Fri 2 Oct | **Decided 29 Sep (PRODUCT D37):** Roshan as an individual, under his own name. |
| D3 | Domain: register getfarside.com (no registry match 28 Sep, plus tryfarside.com defensively). farside.com, .app, .io, .co, .dev and .ca are taken. | After D1 | [O] Register only after the trademark opinion. |
| D4 | "Free on your network" boundary (SUBSCRIPTION-SETUP.md D1): block free direct WAN or allow it. | Fri 9 Oct | [B] |
| D5 | macOS deployment floor: 26.0 today; competitors accept 14 to 15. | Fri 9 Oct | [B] Cutting the floor is engineering work. |
| D6 | Clipboard in 1.0: cut, or explicit user-initiated text only. | Fri 9 Oct | [B] Cut if not ready by 16 Oct. |
| D7 | Persistent Content Capture request: submit now. A draft justification exists in APPLE-PORTAL-SETUP-2026-09-28.md; the run stopped at Apple sign-in. | Fri 2 Oct | [O] Verify every claim in the draft against the shipping build. |
| D8 | Push notifications and Associated Domains: are they in 1.0? Another workstream is preparing an APNs key. If yes, add the capabilities to the App ID, the `aps-environment` entitlement, privacy answers and policy text; keep push optional (Guideline 4.5.4). | Fri 9 Oct | [B] |
| D9 | Export compliance: France included or excluded in 1.0; who files any BIS report. | Fri 9 Oct | [O] with counsel |

## 3. Week by week

Checkboxes are for you to tick. "Done when" is an observable check.

### Week 1: Mon 28 Sep to Fri 2 Oct

| ID | Task | Who | Done when |
|---|---|---|---|
| 1.1 | Decisions D1, D2, D7 made; trademark agent engaged | O | Written opinion requested; owner type recorded |
| 1.2 | Confirm Apple Developer Program: account type, Account Holder identity, team `39HM2X8GS6`, membership renewal date, two-factor, roles for anyone helping | O | Screenshot of Membership page saved privately |
| 1.3 | Sign the **Paid Apps Agreement** (Account Holder only), enter bank account, submit tax forms (non-US developers: W-8BEN or W-8BEN-E as directed) | O | Agreement Active; bank and tax "Processing" or "Active" (verification takes days, so start today) [V] |
| 1.4 | Enroll in the **App Store Small Business Program** | O | Enrollment confirmed [V] |
| 1.5 | Declare **EU DSA trader status**; choose a publishable address, phone and email (a PO box or business address if you do not want a home address shown). Decided (D37): trader status declared; a P.O. Box or UPS Store mailbox address, a phone Roshan is willing to publish, support@getfarside.com; never the home address. The same details go on the website’s support, privacy and terms pages | O | Trader status set [V] |
| 1.6 | Submit the **Persistent Content Capture** request form (needs Apple sign-in) | O | Confirmation email saved |
| 1.7 | Create the **Developer ID Application** certificate (Account Holder) and an app-specific password or API key for `notarytool` | O | `security find-identity` shows the certificate on the release Mac |
| 1.8 | App icon (1024 px master, plus Mac icon and menu-bar template glyphs); add asset catalogs to iOS and Mac targets | E | Archive validates with an icon; menu bar shows the glyph |
| 1.9 | Add `PrivacyInfo.xcprivacy` (PRIVACY-POLICY.md section 6) and `ITSAppUsesNonExemptEncryption = YES` to the iOS target; set `MARKETING_VERSION` 1.0 | E | Xcode Privacy Report shows no missing reasons; no compliance prompt loop |
| 1.10 | Remove or `#if DEBUG` the Relay-only toggle, hidden stream-stats switch and the hidden browser path in Release; design the readiness check without any "turn off Wi-Fi" instruction | E | Release build grep shows none; UI text reviewed |
| 1.11 | Register the domain after D1; set up mail (support@, privacy@, security@) | O | Test emails delivered |
| 1.12 | Start the trademark search list: CIPO, USPTO, EUIPO for FARSIDE in classes 9 and 42; record results | O | Search log saved |

### Week 2: Mon 5 Oct to Fri 9 Oct

| ID | Task | Who | Done when |
|---|---|---|---|
| 2.1 | Create the **App Store Connect app record** (only after D1): suffixed title, bundle ID `com.roshan.PocketDesk.Remote`, SKU, primary language. Opt out of "iPhone and iPad apps on Apple silicon Macs" [V] | O | Record status "Prepare for Submission" |
| 2.2 | First **internal TestFlight** build uploaded; answer export-compliance questions; add up to 100 internal testers (App Store Connect users) [V] | B | Build shows "Ready to Test" on the owner's phone |
| 2.3 | Staging backend: automatic room enrollment (no operator CLI), higher room lifetime and peer limits, per-user rate limits, Cloudflare production and test TURN keys separate | E | Two phones and two Macs pair and connect through staging |
| 2.4 | StoreKit spike: paywall reachable without a paired Mac, Restore Purchases, `Transaction.updates` listener | E | Local StoreKit configuration purchase works |
| 2.5 | Developer ID pipeline: Release configuration, export options, sign, DMG, `notarytool`, `stapler`, clean-machine test (MAC-DISTRIBUTION.md section 7) | E | Fresh macOS user installs DMG, first-run passes Gatekeeper |
| 2.6 | Bake the production service URL into the Mac release Info.plist (`PocketDeskServiceURL`) | E | First run no longer asks for a service address |
| 2.7 | Draft policy reviewed by counsel; retention numbers filled | O | Counsel comments received |
| 2.8 | Decisions D4 to D6, D8, D9 recorded | B | Log updated |
| 2.9 | Website skeleton on the new domain: home, download, privacy, terms, support with contact details | O | Pages resolve over HTTPS |

### Week 3: Mon 12 Oct (Thanksgiving) to Fri 16 Oct

| ID | Task | Who | Done when |
|---|---|---|---|
| 3.1 | **External TestFlight beta 1**: create external group; enter test information (beta description, feedback email, and contact details); first build in a group is reviewed by App Review [V]; up to 10,000 external testers, public link supported | B | Build approved; 10 to 30 named testers invited |
| 3.2 | Mac beta 1 to the same testers as a notarized DMG plus a Sparkle `beta` channel (TestFlight does not carry Developer ID builds [I]); note the one-time permission re-grant for testers coming from the Apple Development build | E | Testers install and update in place |
| 3.3 | Entitlement service and ASN v2 endpoint on staging; sandbox purchase gates TURN issuance | E | Sandbox purchase enables relay; expiry disables it |
| 3.4 | Create the subscription group and both products in App Store Connect (Ready to Submit); billing grace period in sandbox | O | Products load in the app's sandbox build |
| 3.5 | In-app Settings links: Privacy, Terms, Support, Legal (WebRTC BSD-3-Clause notices) | E | Links open |
| 3.6 | Clipboard decision executed: ship explicit text-only or remove from build and copy | E | UI and copy match reality |
| 3.7 | **Scope freeze** Friday: only fixes after this | B | Freeze announced |

### Week 4: Mon 19 Oct to Fri 23 Oct

| ID | Task | Who | Done when |
|---|---|---|---|
| 4.1 | **Production backend** deployed: monitoring, alerting, rollback, secrets in a manager, logging and retention as the policy says, budget alerts (informational only per Cloudflare [V]) | E | 72-hour soak begins |
| 4.2 | Network matrix: same Wi-Fi; cellular; forced relay on two different networks; **IPv6-only NAT64**; captive or firewalled UDP with TURN over TLS 443; Wi-Fi to cellular handover | E | Log of each with route shown as Local, Direct or Relay |
| 4.3 | Acceptance tasks on hardware: 50 connection cycles, 30-minute session, background and Control Center recovery, interrupted drag release, keyboard and rotation (PRODUCT section 9) | E | Results written |
| 4.4 | Battery and thermal check over a 30-minute session on iPhone and iPad | E | Numbers recorded; quality option ready if needed |
| 4.5 | **External beta 2** with subscription flow in TestFlight (accelerated renewals: daily, up to six times in a week [V]) | B | Testers complete purchase, renewal, cancel |
| 4.6 | Accessibility pass: VoiceOver for app controls, Larger Text, Reduce Motion, contrast; decide which Nutrition Labels to claim | E | Findings fixed or labels left unclaimed |
| 4.7 | Capture screenshots (iPhone 6.9", iPad 13") and the preview video from real devices (STORE-LISTING.md sections 3 and 4) | B | Files at exact pixel sizes, no alpha |
| 4.8 | Fresh-user dry run with someone who has never seen the app (install Mac app, pair, control, buy) | O | Observation notes; blockers filed |
| 4.9 | Start the 35-day Screen Recording soak on a spare Mac (cannot finish before launch; do not promise unattended reliability in copy) | E | Soak log running |

### Week 5: Mon 26 Oct to Fri 30 Oct

| ID | Task | Who | Done when |
|---|---|---|---|
| 5.1 | **Release candidate** built with the final Xcode (Xcode 27.0 27A266a is the released build; the store requires Xcode 26 or later [V]) and uploaded Thu 29 Oct | E | Processing complete; compliance answered |
| 5.2 | Enter **App Privacy** answers and publish; enter the privacy manifest to match (PRIVACY-POLICY.md section 3) | O | Label previews correctly |
| 5.3 | Answer the **age rating** questionnaire (expected 4+); set copyright, categories, URLs, keywords (from ASO-STRATEGY.md) | O | All required fields green |
| 5.4 | Export compliance: finish ASC questions; upload French declaration or exclude France; if counsel says so, prepare the BIS report data | O | No "Missing Compliance" |
| 5.5 | **Review notes and demo video** finished (APP-REVIEW-RISKS.md section 7); reviewer test plan dry-run by someone else | B | Notes under 4000 bytes; video link works |
| 5.6 | Add the subscription group and both products to the draft submission for the first version; add the review screenshot | O | Submission draft holds app version plus subscriptions |
| 5.7 | Legal final: policy published at its final URL; Terms; Support page shows address, email, phone [V requirement] | O | URLs return 200 |
| 5.8 | **Code freeze** Friday | E | Tag created |
| 5.9 | Mac 1.0 release build notarized; appcast and download page staged (not public) | E | Clean-machine install passes on a macOS 26 machine |
| 5.10 | Production server run 72 hours without a restart-worthy incident | E | Uptime log |

### Week 6: Mon 2 Nov to Fri 6 Nov

| ID | Task | Who | Done when |
|---|---|---|---|
| 6.1 | **Go/no-go (Mon 2 Nov)** against APP-REVIEW-RISKS.md section 9; if B1 or B2 is red, invoke the fallback in section 9 below | B | Decision recorded |
| 6.2 | **Submit for review (Tue 3 Nov)**: choose the RC build, confirm the subscription group and products are in the submission, set release to Manual (or no earlier than 17 Nov), add contact details and reviewer notes | O | Status "Waiting for Review" |
| 6.3 | Keep the backend, download link and site up; watch the Resolution Center twice daily; keep a phone reachable | B | Any message answered same day |
| 6.4 | If rejected: fix, respond, resubmit by Fri 6 Nov (prepared responses in APP-REVIEW-RISKS.md section 10); one App Review Board appeal per rejection is available [V] | B | Resubmitted |
| 6.5 | Continue external beta on the submitted build; collect crash and feedback | E | Triage list |

### Week 7: Mon 9 Nov to Fri 13 Nov

| ID | Task | Who | Done when |
|---|---|---|---|
| 7.1 | Approval: status becomes Pending Developer Release; do not release yet | O | Status recorded |
| 7.2 | Rehearse launch: publish DMG and appcast to a staging URL, update an older beta build via Sparkle, install from the website on a clean Mac | E | Update works |
| 7.3 | Support ready: inbox monitored, macros for the top 10 issues (permissions, Local Network, firewall, cellular, monthly re-approval prompt, refunds via Apple), status page for signaling outages | O | Test tickets answered |
| 7.4 | Press and launch copy from STORE-LISTING.md and ASO-STRATEGY.md; no claims beyond the claim checklist | O | Copy approved |
| 7.5 | Backups, secrets rotation, on-call plan, rollback plan, spend caps and alert thresholds reviewed | E | Runbook signed |

### Week 8: Mon 16 Nov to Fri 20 Nov

| ID | Task | Who | Done when |
|---|---|---|---|
| 8.1 | Mon 16 Nov: final smoke on the approved build (TestFlight or release candidate) on cellular, Wi-Fi, relay; purchase and restore in sandbox | E | Green |
| 8.2 | **Tue 17 Nov: release** in App Store Connect (it can take up to 24 hours to appear on the App Store [V]); switch the website and download link live; publish Mac 1.0 and appcast | O | App visible in the storefronts you selected |
| 8.3 | Watch 72 hours: crashes (Xcode Organizer), server health, Cloudflare relay bytes per credential, purchase and refund notifications, support inbox | B | Daily log |
| 8.4 | Hotfix window Wed 18 to Fri 20 Nov; expedited review is only for critical bug fixes [V] | E | |

## 4. Apple Developer Program and App Store Connect: steps only the owner can do

1. Confirm the membership, Account Holder, account type and renewal date (Membership details).
2. Business: sign the **Paid Apps Agreement**, and accept every updated agreement, including **Attachment 14** of the Developer Program License Agreement (EU terms, effective 1 Oct 2026; APP-REVIEW-RISKS B17). Add a **bank account** and submit **tax forms**. Non-US developers complete a US tax form (W-8BEN, W-8BEN-E or W-8ECI as directed) and any local forms. The tax forms must be in place before banking is processed. [V]
3. Enroll in the **Small Business Program** (15% instead of 30% first-year commission). [V]
4. Declare **DSA trader status** and publishable contact details. [V]
5. Certificates, Identifiers and Profiles: Developer ID Application certificate (Account Holder); App ID `com.roshan.PocketDesk.Remote` with capabilities (In-App Purchase; Push Notifications and Associated Domains only if D8 says yes); App ID `com.roshan.PocketDesk.RemoteHost` for the Mac; APNs key if push is in scope (see APPLE-PORTAL-SETUP-2026-09-28.md; move the `.p8` to a private folder and never share it).
6. **Persistent Content Capture** request form (Apple sign-in required). [V]
7. Create the app record; set name, subtitle, categories, age rating (answer every questionnaire item, including the social-media questions; all "No", expected 4+; APP-REVIEW-RISKS section 5b), privacy policy URL, copyright, Support and Marketing URLs; App Privacy; export compliance; DSA; availability including the Apple-silicon-Mac opt-out; pricing (free).
8. Monetization: subscription group, products, prices, free trial, Family Sharing off, billing grace, review screenshot; App Store Server Notifications URLs; In-App Purchase key download (one time). See SUBSCRIPTION-SETUP.md section 9.
   - [ ] **Anywhere subscription: Multiseat = No (set before first approval).** On both products, open Purchase Options and choose "No, don't allow multiseat purchases". It is on by default since 16 Sep 2026. Existing group seats keep renewing after a late switch-off, and the backend refuses `ASSIGNED` seats (APP-REVIEW-RISKS B15).
9. TestFlight: test information, internal and external groups, public link if wanted, export compliance per build.
10. Submission: attach build, IAP group and products; App Review information (contact, notes, demo video); version release option.
11. Later: reply to App Review messages; appeal if needed; release.

## 5. Required assets inventory

| Asset | Spec [V unless marked] | Owner | Due |
|---|---|---|---|
| App icon | 1024 x 1024 master; Mac icon set; Mac menu-bar template glyphs | E | Fri 2 Oct |
| iPhone screenshots | 6.9" 1320 x 2868, 1 to 10, no alpha | B | Fri 23 Oct |
| iPad 13" screenshots | 2064 x 2752 or 2752 x 2064 | B | Fri 23 Oct |
| App preview | 15 to 30 s, 886 x 1920, H.264, at most 30 fps, at most 500 MB; iPad 1200 x 1600 | B | Fri 23 Oct |
| Metadata | Title, subtitle, promotional text, description, keywords, What's New (STORE-LISTING.md; ASO-STRATEGY.md for keywords) | B | Fri 30 Oct |
| URLs | Support (with real contact information), Marketing, Privacy, Terms | O | Fri 9 Oct |
| Privacy policy | Published at its final URL | O | Fri 9 Oct |
| Legal screen in app | WebRTC notices | E | Fri 16 Oct |
| Review video and notes | APP-REVIEW-RISKS.md section 7 | B | Fri 30 Oct |
| Mac DMG | Notarized and stapled; SHA-256; appcast | E | Fri 30 Oct |
| Press kit | Icon, screenshots, one-paragraph description | O | Fri 13 Nov |

## 6. TestFlight plan

| Stage | Who | Entry criteria | What to test | Exit criteria |
|---|---|---|---|---|
| Internal alpha (from Thu 8 Oct) | Up to 100 App Store Connect users [V] | Icon, manifest, encryption key, compliance answered | Install, pairing, control, permissions, crash-free launch | Owner completes the PRODUCT acceptance tasks on his own devices |
| External beta 1 (from Tue 13 Oct) | Named testers, optionally a public link (up to 10,000) [V] | Privacy policy URL, test information, staging backend; first build is reviewed [V] | Real networks, cellular, first-run clarity, Mac install | No data-loss or security bugs open |
| External beta 2 (from about 19 Oct) | Wider group | Subscription flow on staging | Purchase, trial, renewal (accelerated: daily, up to six times in a week [V]), cancel, restore, relay | Purchase and restore work on iPhone and iPad |
| RC (from Thu 29 Oct) | Same as beta 2 plus the review dry-run | Code freeze | Everything above on the exact build to be submitted | Go/no-go passed |

Builds expire after 90 days [V]. For the Mac companion use notarized DMGs plus a Sparkle `beta` channel; announce that testers moving from the Apple Development build must re-grant Screen Recording and Accessibility once.

## 7. Support email and site

- Mailboxes: support@, privacy@, security@ on the chosen domain, with a shared inbox tool; on-call rota for launch week.
- Apple requires the Support URL to lead to real contact information (legal address, email, phone) [V]; the same address is shown for EU traders, so choose it deliberately.
- Support content: install, permissions (Screen Recording, Accessibility, Local Network, Camera, Microphone), cellular and firewalls, monthly Screen Recording re-approval prompt, subscription management and refunds (Apple decides refunds), "Report a problem" instructions, status page.
- Publish Privacy, Terms and Security (vulnerability reporting) pages. No advertising or analytics scripts on the site in v1.

## 8. Analytics and crash reporting: recommendation

Use **no third-party analytics or crash SDK in 1.0.** PRODUCT section 8 already proposes none, it keeps the App Privacy label small (no Usage Data, no Crash or Performance Data), and the policy says so. Instead:

- App Store Connect analytics, and Xcode Organizer crash and hang reports (Apple shows these only for users who opted to share with developers). TestFlight crash reports and screenshot feedback for betas.
- Server-side: uptime probes, error rates, per-credential relay bytes from Cloudflare analytics, aggregate session counts. No per-user product analytics.
- A user-initiated "Report a problem" that packages version, OS, route type and the local stats file into a mail draft; nothing uploads automatically.
- MetricKit only for local viewing; if you ever upload its payloads, that is Diagnostics collection and changes the label and policy.
- If you later add a crash or analytics service, ask for consent (Guideline 5.1.1(ii)), update the App Privacy answers and the policy, and keep the Mac Sparkle system profiling off.

## 9. What is blocked by engineering, and fallbacks

| Item | Blocks | Depends on | Planning estimate [I] | Need by |
|---|---|---|---|---|
| Production signaling and relay: automatic enrollment, lifted room lifetime and peer caps, sane rate limits, monitoring, rollback | Everything remote; review; the "no time limit" claim | Cloudflare account and TURN keys, hosting decision | Repo estimate for owned internet access: 1 to 2 weeks after credentials and deployment approval; plan 5 to 8 working days for hardening on top | 23 Oct staging, 30 Oct prod |
| StoreKit paywall, restore, entitlement service, ASN v2 | Submission with subscription; relay gating | App record, products, server | 5 to 8 working days | 16 Oct staging |
| Developer ID release pipeline, Sparkle, first-run Move to Applications, service URL, Local Network string | Mac download, review notes | Developer ID certificate, domain | 4 to 6 working days | 16 Oct beta, 30 Oct final |
| Icon, privacy manifest, plist keys, version, legal screen, Settings links | TestFlight and submission | Decisions D1 to D3 | 1 to 2 working days | 2 Oct, 16 Oct |
| Remove hidden features; reword Wi-Fi-off flows; disable Mac browser path | 2.3.1(a), 2.4.4 | none | 1 to 2 working days | 16 Oct |
| "Remove this Mac and delete server data" and entitlement record deletion | Privacy policy claim | Server design | 2 to 3 working days | 23 Oct |
| Clipboard sync (explicit text only) | Copy claims | Product decision | Repo estimate 3 to 7 days for clipboard plus dictation | Cut by 16 Oct if late |
| IPv6-only and network matrix | 2.5.5 and the launch claim | Deployed staging | 1 to 2 working days | 23 Oct |
| Push notifications (if D8 yes) | Nothing else | APNs key, server | 3 to 5 working days | 16 Oct or cut |

**Fallback if the backend or subscription is red on Fri 23 Oct:** ship 1.0 on 17 Nov as free, local-network only, with no in-app purchase, and add Farside Anywhere in 1.1. This removes B1 and B2 from the 3 Nov submission, and because the first subscription must ride on a new app version anyway [V], it fits Apple's process. Copy must then drop every reference to remote access (description, screenshots 6, preview 19 to 24 s, promotional text). Note that local-only still depends on the signaling service unless local direct mode ships.

**Scope cuts, in order, if the schedule slips:** clipboard; push notifications; iPad-specific polish beyond a working layout; HEVC and codec experiments (engine parity work in `BUILD-PRIORITIES.md`); mini map and picture-in-picture (already research-only).

## 10. Trademark checklist item (Farside versus The Far Side)

- [ ] Written opinion from a Canadian and US trademark agent covering FARSIDE for software (classes 9 and 42) and its relationship to THE FAR SIDE (FarWorks, Inc., US Reg. 6255846, Class 41, live; other FarWorks marks reported for prints, books, cards and calendars). [O] by Fri 2 Oct.
- [ ] Search CIPO, USPTO and EUIPO for FARSIDE and variants; record results and dates.
- [ ] Decide the store title: suffixed (working default "Farside: Mac Remote"); confirm it is unavailable as bare "Farside" [V] and not confusingly close to other live "Farside" or "FarSide" apps.
- [ ] Keep the name one word everywhere; no "Far Side" or "The Far Side" in copy, keywords or URLs; no cartoon, cow or comic imagery.
- [ ] Have a fallback name and domain ready (decision by 2 Oct); after the opinion, consider filing an application for FARSIDE in the owner's name.
- [ ] Know the risk: Apple's process lets a trademark owner file a claim against an app name (App Store Connect add-a-new-app FAQ), which can remove an app after launch. [V process; I likelihood]

## Sources (all checked 2026-09-28)

- TestFlight overview (90-day builds, 100 internal and 10,000 external testers, first-build review): https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/ ; external testers: https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/ ; internal testers: https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/ ; subscriptions in TestFlight: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight/
- App Review overview (about 90% under 24 hours, expedite and appeal rules): https://developer.apple.com/distribute/app-review/
- Sign and update agreements; banking; tax: https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/ , https://developer.apple.com/help/app-store-connect/manage-banking-information/enter-banking-information/ , https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information/
- DSA trader: https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/
- Small Business Program: https://developer.apple.com/app-store/small-business-program/
- Release options: https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/
- Upcoming requirements (Xcode 26 SDK rule): https://developer.apple.com/news/upcoming-requirements/ ; Xcode 27.0 27A266a released 14 Sep 2026 per https://xcodereleases.com/data.json and `xcodebuild -version` on the build Mac
- Persistent Content Capture entitlement page and request form link: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture
- BIS annual self-classification report: https://www.bis.gov/learn-support/encryption-controls/annual-self-classification
- Add a new app FAQ (name claims): https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/
- USPTO TSDR THE FAR SIDE, Reg. 6255846: https://tsdr.uspto.gov/statusview/sn90016156
- Repo: `Docs/research/2026-09-28/BUILD-PRIORITIES.md`, `Docs/DEVICE-TEST-CHECKLIST.md`, `PRODUCT.md` sections 8 to 10, `Docs/launch/*.md`
