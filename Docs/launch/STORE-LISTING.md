# Farside App Store listing — iPhone-only 1.0 draft

Updated **3 October 2026** for Roshan's D62 decision: **1.0 is iPhone-only; iPad is dropped from this launch.** D62 supersedes D57. This is an editable local draft for review, not saved App Store Connect metadata or an approved release.

The older listing at `d84a24f` contained iPad, unavailable Anywhere, unlimited-use and November-launch claims. This document replaces that active copy. Its original research is preserved in Git and in the handoff's source snapshot. Product authority is [PRODUCT.md](../../PRODUCT.md), including the exact D62 record from `f1537e46`.

**Candidate boundary:** accepted build `20261002.5` is the existing universal iPhone/iPad artifact from `129d4b3`; it has not become iPhone-only through this edit. The separate engineering lane recorded device-family source changes at `ae484d8`, followed by D62 at `f1537e46`. A new candidate's archive, device-family metadata, compatibility and App Store presentation still need verification by the testing/release owner. No build, test, upload, submission or portal edit occurs here. Both publication holds and the testing-owner split remain in force.

## Metadata to review

English (U.S.) is the recorded primary locale. English at launch; US and Canada remain the nomination's recorded regions, subject to the owner's actual availability settings. Do not create extra locales or infer new countries from this draft.

| Field | Draft | Count / status |
|---|---|---|
| App name | `Farside: Remote Desktop` | 23/30 characters; existing app name preserved |
| Subtitle | `Control your Mac from iPhone` | 28/30 characters; existing ASO wording retained |
| Keywords | `trackpad,mouse,keyboard,screen,viewer,phone,access,home,file,laptop,share,work,touch,computer` | 93/100 UTF-8 bytes; iPad and agent-specific tokens removed |
| Primary / secondary category | Utilities / Productivity | Existing strategy retained; confirm current portal values |
| Promotional text | Block A | 147/170 characters |
| Description | Block B | Under 4,000 characters; count recorded in the change receipt |
| What's New | Block C | 156/4,000 characters |
| Copyright | 2026 [OWNER'S CONFIRMED SELLER NAME] | Owner supplies the exact legal text |
| Support URL | https://getfarside.com/support | Verify submitted page and contact information |
| Marketing URL | https://getfarside.com/ | Align public copy before publishing |
| Privacy Policy URL | https://getfarside.com/privacy | Verify current published policy |
| Terms URL | https://getfarside.com/terms | Verify current terms before paid copy is used |
| Release date | Target 27 October 2026 | Manual / scheduled setting requires owner action |
| Age rating / accessibility labels | Use the completed questionnaires and exact-build audit | No declaration is approved by this draft |

### A. Promotional text — current service-unavailable draft

```text
See and control your Mac from your iPhone. Free on the same Wi-Fi. Pair with the free Mac companion by scanning its code and approving on your Mac.
```

### B. Description — current service-unavailable draft

```text
Your Mac, from your iPhone.

Farside shows your Mac's screen on your iPhone so you can finish a document, check something on your desktop or make a quick change without walking back to your desk.

A TRACKPAD IN YOUR HAND
Slide a finger to move the pointer, tap to click and use two fingers to scroll. Pinch to look more closely. Use the iPhone keyboard to type on your Mac, with familiar Mac shortcut keys.

PAIR WITH YOUR MAC
Install the free Farside companion on your Mac, scan its code and approve your phone on the Mac. Compare the short number shown on both devices. There is no Farside account to create. Your Mac needs Screen Recording and Accessibility permission for screen sharing and control.

FREE ON THE SAME WI-FI
Use Farside for free when your iPhone and Mac are on the same Wi-Fi. Keep the Mac awake and unlocked, with the Farside companion running.

AWAY FROM HOME
Farside Anywhere is an optional subscription for use away from home. It is coming soon.

REQUIREMENTS
iPhone with iOS 26 or later. A Mac with Apple silicon (M1 or later) on macOS 26 or later. Download the free Mac companion at getfarside.com/mac.

Terms of Use: https://getfarside.com/terms
Privacy Policy: https://getfarside.com/privacy
```

### C. What's New

```text
Welcome to Farside. See and control your Mac from your iPhone, free on the same Wi-Fi. Install the free Mac companion, scan its code and approve your phone.
```

## Anywhere-ready replacement — gated, not the current paste block

If the exact submitted candidate supports purchasable, accepted production Anywhere, replace promotional Block A with:

```text
Free on the same Wi-Fi. Optional Farside Anywhere adds access away from home. Pair with the free Mac companion and approve your phone on your Mac.
```

Replace only the AWAY FROM HOME paragraph in Block B with:

```text
Farside Anywhere is an optional auto-renewing monthly or yearly subscription for use away from home. The price, any trial eligibility and renewal terms are shown before you subscribe. Manage or cancel your subscription in your Apple Account settings.
```

Keep the supported, awake/unlocked Mac requirement. Do not promise waking, remote unlocking or use from every network. The D41 internal offer remains CA$7.99/month or CA$59.99/year with a 7-day trial; public store copy has no hardcoded prices or unconditional trial eligibility. Keep existing product IDs and subscription group. Draft display names remain `Farside Anywhere - Monthly` and `Farside Anywhere - Yearly`; description: `Access your Mac away from home.` Actual storefront terms must come from the configured products.

If Paid Apps/tax remains blocked, Roshan's fallback is free same-Wi-Fi 1.0 with a five-device cap and Anywhere in a later update. That is a conditional release decision; this draft does not activate the fallback or assert a working paid service.

## Claim checks for the next candidate

| Claim | Evidence boundary / required handoff |
|---|---|
| iPhone-only 1.0 | D62 owner decision and engineering source commit exist. Verify the new built app and extensions plus portal device presentation; universal .5 is prior evidence. |
| Same-Wi-Fi free use, pairing, pointer, scroll, pinch and keyboard | Source and historical checks exist; exact next-candidate physical acceptance belongs to Roshan/Claude Code. The ordinary .5 quick check does not close all of them. |
| Compare the number / approve on Mac | D60 and current pairing source. Verify the actual next-candidate first pairing and recovery flow. |
| Awake, unlocked Mac / running companion | Prepared-Mac product boundary retained. Away/lock feasibility is a separate owner-run gate. |
| Anywhere / trial | Requires cleared commerce prerequisites, actual sandbox offer/restore/expiry and production direct/relay acceptance. Until then use the coming-soon block. |
| No Farside account | Describes pairing without a Farside sign-up; it is not a claim that the app or service collects no data. |
| Extra features | Add dictation, Files/Clipboard, Listen, Couch, alerts or accessibility claims only if included and accepted in the submitted candidate. No Workspace promise. |

No competitor names, prices, measured speed/fps, unlimited-use, setup-time, blanket privacy/encryption or "nothing to set up" claims appear in the paste blocks. This scope does not change App Privacy answers, export compliance, legal contact details or privacy policy text.

## Screenshots and preview — ON HOLD

Roshan has held App Store screenshot work. This document only updates the future brief; it authorizes no capture, design or upload. The launch brief is iPhone-only, with no iPad set or Workspace scene. Actual Apple upload requirements must be checked against the new candidate before producing assets.

When the hold is lifted, keep the first frames understandable at a glance:

| Order | Proposed caption | Evidence to show |
|---|---|---|
| 1 | Your Mac, from your iPhone | Actual iPhone app showing a neutral Mac document |
| 2 | A trackpad in your hand | Actual pointer and touch interaction |
| 3 | Scan. Compare. Approve. | Actual next-candidate phone and Mac pairing flow |
| Later | Type on your Mac / Look more closely / Free on the same Wi-Fi | Only accepted keyboard, pinch and route behavior |

Use actual screenshots and devices. No fabricated touch result, speed badge, setup timer, generated hand/device or unavailable Anywhere route. A paid-access frame is included only when the paid service is accepted, with its requirement clearly stated. [ASO strategy](ASO-STRATEGY.md) gives the matching message plan.

## Source boundary

Fully read frozen listing: `d84a24f:Docs/launch/STORE-LISTING.md` (last listing change `080e2b9`, 29 September). Fully read ASO strategy: `d84a24f:Docs/launch/ASO-STRATEGY.md` (last change `437cc40`, 30 September). Older platform dimensions, ranking and legal/trademark research are dated background, not newly verified rules. Current owner decisions, [review packet](CURRENT-REVIEW-PACKET.md), exact candidate receipts and owner-entered portal values take priority. App record: Farside: Remote Desktop, `6817532560`; bundle identities remain `com.roshan.PocketDesk.*`.
