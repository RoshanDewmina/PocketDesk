# Farside launch review packet — 29 September 2026

This is the current engineering preparation record. Older launch research remains useful background, but its statements that subscriptions, clipboard, push adapters, privacy manifests, or dependency notices are absent are superseded by the current source. This packet is not a submission or an acceptance receipt.

Latest app-only continuation: the human-approved **Farside: Remote Desktop** App Store Connect record is created and verified, numeric app ID `6817532560`, existing phone bundle, SKU `farside-ios`, primary English (U.S.), Limited Access, version 1.0 Prepare for Submission. Local configured-ID transaction verification now follows Apple's transaction schema while preserving outer production notification app-ID validation. Fresh independent review passes 129 backend tests and typecheck. Integrated notification parsing passes 17 XCTest checks; all 22 release fixture methods pass, including malformed app/widget manifest rejection. W6 HEVC probe preparation is integrated and compiles for Mac and generic iOS device/simulator targets, signing disabled; four Mac probes skip without explicit opt-in. No actual HEVC measurements or codec-default change occurred. Installed `.11`, uninstalled `.12` and the human's physical-testing deferral remain unchanged. No upload, deployment, installation or submission occurred in this continuation.

## Commerce and App Review refresh — 30 September 2026

Branch `farside-commerce-review`. Source, tests and documents only. There was no deployment, no App Store Connect change and no install. Details and sources: APP-REVIEW-RISKS.md (header, rows 3.1.2 Multiseat and 4.5.4, sections 4, 5a, 5b, 8, go/no-go B15–B18).

- **Multiseat.** Server verification accepts only `inAppOwnershipType` `PURCHASED`. Assigned multiseat seats (and family-shared or unmarked ones) get 401 `not_purchased`, logged by ownership kind with no identifiers. Seat notifications, including `ASSIGNMENT_REVOKE`, never touch a purchaser's subscription. **Owner:** set Multiseat = No on both products before the first approval (LAUNCH-CHECKLIST §4 item 8).
- **Consent revocation (Texas SB 2420, Utah, Louisiana).** A verified `RESCIND_CONSENT` notification stops Anywhere for every subscription verified under that app transaction. It ends live rooms, and later verification answers `consent_revoked`. It needs migration `0004_consent_stop.sql`.
  - The phone records `AgeRangeService.requiredRegulatoryFeatures` (iOS 26.4+, guarded). It blocks no one and adds no UI.
  - The decision is written in APP-REVIEW-RISKS section 5a.
- **Generic alerts (4.5.4).** APNs and local alerts carry only `title-loc-key`/`loc-key`, with no `title-loc-args`. The "Show agent name" setting is gone, and the in-app sheet and banner use the same fixed words. The service ignores an older phone's `showAgentName`.
- **Offer codes.** On iOS 27 the paywall uses `offerCodeRedemption(options:isPresented:onCompletion:)`. The returned verified transaction is finished and sent for server verification at once. iOS 26 keeps the earlier overload.
- **Shortcuts.** SHORTCUTS-RECIPES.md: the Notification automation trigger is iOS 27+, and the stable title to filter on is "A task on your Mac needs you".
- **4.2.7** was re-read on 30 Sep: "Last Updated: June 8, 2026", clause (e) intact, analysis unchanged.
- **Age rating.** Answer every questionnaire item "No", including the social-media questions (required for submissions since September 2026). Expected rating 4+.
- **Agreements.** The Account Holder accepts the updated Developer Program License Agreement, whose Attachment 14 (EU terms) takes effect 1 Oct 2026.
- **Privacy manifests.**
  - The phone reads no file timestamps in Release on this branch.
  - The Mac companion's login-item fingerprint already reads a modification date, and its manifest lacks FileTimestamp.
  - File transfer (`farside-transfer`, `4450ecf`) adds FileTimestamp `C617.1` and `3B52.1` to all its manifests. Keep `C617.1` wherever timestamps are read.
- **Needed deploy (not done; needs approval):**
  1. `wrangler d1 migrations apply` for `0004_consent_stop.sql` on staging, then deploy the Worker to staging.
  2. Run the sandbox plan, adding an `ASSIGNED` sandbox transaction and a sandbox `RESCIND_CONSENT` where Apple's sandbox can produce them.
  3. After acceptance, apply the same migration and deploy to production.

  The migration only adds columns and a table, so the currently deployed Worker keeps working after it is applied.

## Product and identifiers

- Farside phone app: `com.roshan.PocketDesk.Remote`, iPhone and iPad, iOS/iPadOS 26 or later.
- Mac companion: `com.roshan.PocketDesk.RemoteHost`, Apple silicon and macOS 26 or later. Keep the installed development filename `PocketDesk Host.app` to preserve its permission identity.
- Marketing version 1.0. Both host and actual iPhone 17 now have signed `20260929.11` from integrated `d50c8da`. The host update preserved its designated requirement and both runtime grants. Native removal now persists sharing off on failure, confirms authoritative absence before success, and exposes a safe retry footer/status diagnostic; explicit new pairing honors the selected service. Physical `.11` removal safely retained the pair and kept sharing Off after `delete:-25244`; successful local deletion remains open. Explicit replacement and human scanning completed; actual host diagnostics confirm staging/Ready/paired and both grants. Delivered video/input acceptance remains with the coordinated chat. A reviewed exact-reference deletion candidate is source-integrated, passes 694 integrated core checks (three optional skips, no failures) and signed .12 development builds; physical removal verification is deferred by the human. It has not replaced installed .11.
- Preserve the recorded individual-seller decision and existing subscription product identifiers. Never infer or enter missing legal/contact details from these engineering notes.

## Review description draft

Farside lets a person view and control their own paired Mac from an iPhone or iPad. Pairing requires a short-lived invitation and approval on the Mac. The Mac asks for Screen Recording and Accessibility permission; the owner can stop sharing or remove pairing. Screen and input content travel encrypted between the paired devices. The signaling service does not receive the screen-encryption key.

Free access is limited to a verified directly attached Wi-Fi or Ethernet path. Internet, VPN, routed, and unverifiable paths require Farside Anywhere. Server policy bounds each session by its verified access deadline. Purchases remain disabled until the intended production service is explicitly marked ready. Restore and server verification must be demonstrated with the review build and sandbox account before submission.

Agent alerts are an optional beta for a coding agent's blocking permission prompts on the user's own Mac. Every alert says the same fixed words, "A task on your Mac needs you". It names no agent or product and carries no prompt, file name, screen content or chat text. Tapping an alert opens a prompt to Connect; it does not silently control the Mac or approve an agent action. Session Live Activities have an end-only server adapter so a suspended phone can remove an ended session. These source paths still require real APNs acceptance.

## Current data-flow corrections for the privacy draft

| Data | Current implementation and boundary |
|---|---|
| Purchase verification | Signed Apple transaction verification and device-bound entitlement records in the backend. Purchase records are retained for up to 90 days after verified access/grace ends; unlinking does not cancel the Apple subscription. |
| Room and pairing metadata | Production Workers/Durable Objects/D1 replace the old in-memory-only description. The server keeps authentication hashes and routing metadata, never the screen key. Security blocks and outstanding relay revocations can survive removal. |
| Agent alerts | Opt-in APNs address and preferences are bound to pairing authentication. Generic events expire after 15 minutes; expired event/report records are purged by the configured retention job. APNs acceptance is not proof of delivery. |
| Session activity | Separate activity token, activity ID and authenticated session epoch. End delivery has bounded retries. Turning agent alerts off must not remove an unrelated session-activity ending address. |
| Clipboard | Explicit native clipboard actions exist. Check the final build's user-facing consent and limits; do not reuse the old claim that no clipboard feature exists. |
| Updates | Mac Release uses Sparkle only with a valid configured public signing key and feed. Update checks must be included in the published privacy disclosure. No feed or signed update is published by these changes. |
| Dependencies | WebRTC, Sparkle and bundled fonts have in-app notices. Phone/host privacy manifests are present and must be checked in the signed archives. |

## Exact remaining submission inputs and acceptance

- Read-only account inventory confirms staging D1 and staging health. The human-approved staging transition applied `0002_purchase_order.sql` and `0003_agent_push.sql` and deployed backend source `8dca833` as Worker version `ae445b1b-8b93-409d-9bc3-ff719d72e283`; schema and health pass. Independent disposable-room protocol acceptance passed 53/53 assertions and normal fixture cleanup returned 204. Exact-build physical native acceptance remains separate. The approved Farside App Store Connect record now exists with numeric app ID `6817532560`; production D1 and actual production verification deployment/acceptance remain to be prepared and approved. The old private development service is not proof of public route enforcement.
- The owner confirmed domain/DNS ownership and active paid Apple Developer membership. Signed-in capability/profile/key inventory is preserved in `work/staging-transition-20260929/apple-release-inventory.md`; the earlier inventory found no Farside App Store Connect record or Developer ID certificate. The human subsequently approved creating the Farside app record; App Information now verifies ID `6817532560` and the existing phone bundle identity. Developer ID remains outstanding. Do not create or submit those changes without the historical action-time confirmation.
- Existing local signing inventory has Apple Development, not Developer ID Application or a verified Apple Distribution archive. A Developer ID transition must be tested separately from the installed permission-preserving development update.
- A fresh staging secret-name inventory confirms APNs provider credentials are absent. Signed-in portal inspection confirms the main phone App ID has push/associated-domain/time-sensitive capabilities and existing topic-specific Sandbox/Production APNs keys. Their downloaded private files remain missing; the current Debug phone uses a wildcard profile with push disabled and no associated-domain entitlement. Apex DNS has no A/AAAA answers, so AASA is not live. Real signed push and suspended delivery remain unverified. Do not claim push is live from unit tests.
- Support/privacy/terms pages must actually load at the submitted URLs. Confirm effective date and public seller/contact fields before publishing the privacy draft.
- Complete exact-build phone/iPad input, dictation, clipboard, background recovery, restart and release-input checks. The gesture and keyboard-toolbar fixes are integrated and have automated receipts; the new build still needs physical acceptance. Four targeted iPad simulator shortcut checks now pass. Direct Command-M required an explicit Return after Session ended; this is not same-session recovery. Physical iPad acceptance remains open.
- Complete free LAN / denied free WAN and VPN / paid direct and relay / IPv6 and NAT64 / expiry and revocation / renewal-boundary tests. Unsupported local-proof cases remain blocked.
- Record quiet and loaded machine performance; do not claim 120 fps without measured delivery from a suitable source.
- Complete real sandbox expiry, clean install, pairing, update, removal, archive validation, notarization/stapling and signed-update checks. Only then approve deployment, store submission or publication for the exact artifacts.

Local preparation commands and fail-closed configuration checks are in `script/release/README.md`. Source/test/install receipts are under `work/launch-preparation/`; physical input receipts are maintained by the coordinated Farside chat until integrated into this ledger.

Prior integrated local checks: backend 127/127, core 682 executed with three skips and no failures, phone components 297/297, StoreKit 14 passed plus one optional screenshot skip, both keyboard UI checks and all four targeted iPad shortcut checks passed, and the final Mac host build passed. These do not replace exact installed-build acceptance. See [the approved staging transition](STAGING-TRANSITION.md) for the staging receipt and remaining gates.

Later preparation checks: the .11 removal repair ran 687 core checks with three optional skips/no failures, plus final focused privacy/removal and canonical-service checks. The new exact-reference candidate passes 11 isolated and 694 integrated core checks (three optional skips, no failures); signed .12 development builds/identity preflight pass. The human deferred hands-on testing, so the candidate remains uninstalled and physical deletion proof is pending. The hardened release validator passes nine integrated fixture methods. Privacy/listing drafts describe current source but retain explicit publication fields and provider/declaration gates.

The current .12 artifact readiness receipt is `work/staging-transition-20260929/keychain-reference-removal/build12-readiness-receipt.json` (source `fdaff65`). Neither installed device changed. Generic development signing and fixture passes are not production purchase/APNs/distribution receipts.

Universal-link source hosting and strict release-preflight input gates are integrated as `7f46a3d`/`abff111`, independently reviewed before integration. Main-source website build/static and local AASA GET/HEAD checks pass; all 19 combined release-gate fixture methods pass. Eleven fabricated-input Claude Code/Codex hook checks pass with zero curl invocations; no live discovery, global hook setup or actual event/APNs delivery is involved. These source-only changes preserve the .12 native artifacts. Receipt: `work/staging-transition-20260929/source-preparation-integrated-receipt.json`. Website launch/contact placeholders, live domain association, provider credentials, signed profiles, distribution artifacts and human-deferred physical acceptance remain open.
