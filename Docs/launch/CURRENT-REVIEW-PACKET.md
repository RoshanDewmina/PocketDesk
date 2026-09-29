# Farside launch review packet — 29 September 2026

This is the current engineering preparation record. Older launch research remains useful background, but its statements that subscriptions, clipboard, push adapters, privacy manifests, or dependency notices are absent are superseded by the current source. This packet is not a submission or an acceptance receipt.

## Product and identifiers

- Farside phone app: `com.roshan.PocketDesk.Remote`, iPhone and iPad, iOS/iPadOS 26 or later.
- Mac companion: `com.roshan.PocketDesk.RemoteHost`, Apple silicon and macOS 26 or later. Keep the installed development filename `PocketDesk Host.app` to preserve its permission identity.
- Marketing version 1.0. Both host and actual iPhone 17 now have signed `20260929.11` from integrated `d50c8da`. The host update preserved its designated requirement and both runtime grants. Native removal now persists sharing off on failure, confirms authoritative absence before success, and exposes a safe retry footer/status diagnostic; explicit new pairing honors the selected service. Physical `.11` removal safely retained the pair and kept sharing Off after `delete:-25244`; successful local deletion remains open. Explicit replacement and human scanning completed; actual host diagnostics confirm staging/Ready/paired and both grants. Delivered video/input acceptance remains with the coordinated chat. A reviewed exact-reference deletion candidate is source-integrated, passes 694 integrated core checks (three optional skips, no failures) and signed .12 development builds; physical removal verification is deferred by the human. It has not replaced installed .11.
- Preserve the recorded individual-seller decision and existing subscription product identifiers. Never infer or enter missing legal/contact details from these engineering notes.

## Review description draft

Farside lets a person view and control their own paired Mac from an iPhone or iPad. Pairing requires a short-lived invitation and approval on the Mac. The Mac asks for Screen Recording and Accessibility permission; the owner can stop sharing or remove pairing. Screen and input content travel encrypted between the paired devices. The signaling service does not receive the screen-encryption key.

Free access is limited to a verified directly attached Wi-Fi or Ethernet path. Internet, VPN, routed, and unverifiable paths require Farside Anywhere. Server policy bounds each session by its verified access deadline. Purchases remain disabled until the intended production service is explicitly marked ready. Restore and server verification must be demonstrated with the review build and sandbox account before submission.

Agent alerts are an optional beta for blocking Claude Code and Codex permission events. Payloads contain generic alert metadata rather than prompts, file names, screen content, or chat text. Tapping an alert opens a prompt to Connect; it does not silently control the Mac or approve an agent action. Session Live Activities have an end-only server adapter so a suspended phone can remove an ended session. These source paths still require real APNs acceptance.

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

- Read-only account inventory confirms staging D1 and staging health. The human-approved staging transition applied `0002_purchase_order.sql` and `0003_agent_push.sql` and deployed backend source `8dca833` as Worker version `ae445b1b-8b93-409d-9bc3-ff719d72e283`; schema and health pass. Independent disposable-room protocol acceptance passed 53/53 assertions and normal fixture cleanup returned 204. Exact-build physical native acceptance remains separate. Production D1, numeric Apple app ID and production verification settings remain to be prepared and approved. The old private development service is not proof of public route enforcement.
- The owner confirmed domain/DNS ownership and active paid Apple Developer membership. Signed-in capability/profile/key inventory is preserved in `work/staging-transition-20260929/apple-release-inventory.md`; no Farside App Store Connect app record or Developer ID certificate was observed. Do not create or submit those changes without the historical action-time confirmation.
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
