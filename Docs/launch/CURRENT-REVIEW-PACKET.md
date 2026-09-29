# Farside launch review packet — 29 September 2026

This is the current engineering preparation record. Older launch research remains useful background, but its statements that subscriptions, clipboard, push adapters, privacy manifests, or dependency notices are absent are superseded by the current source. This packet is not a submission or an acceptance receipt.

## Product and identifiers

- Farside phone app: `com.roshan.PocketDesk.Remote`, iPhone and iPad, iOS/iPadOS 26 or later.
- Mac companion: `com.roshan.PocketDesk.RemoteHost`, Apple silicon and macOS 26 or later. Keep the installed development filename `PocketDesk Host.app` to preserve its permission identity.
- Marketing version 1.0. The wider Settings build installed on this Mac is host `20260929.9`, from integrated `a4f9420`; the paired physical phone remains `.8` during isolated input repairs. Subsequent route/notification changes are not installed acceptance builds.
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

- Read-only account inventory confirms staging D1 and staging health. A fresh remote migration inventory shows `0002_purchase_order.sql` and `0003_agent_push.sql` are both unapplied; health does not establish current billing/push readiness. The staging bundle passes a local dry run, with no deployment. Production D1, numeric Apple app ID, production verification settings and a compatible `route.1` deployment remain to be prepared and approved. The old private development service is not proof of public route enforcement.
- The owner confirmed domain/DNS ownership and active paid Apple Developer membership. Capability/profile/key inventory still needs the signed-in portal. Do not create or submit those changes without the historical action-time confirmation.
- Existing local signing inventory has Apple Development, not Developer ID Application or a verified Apple Distribution archive. A Developer ID transition must be tested separately from the installed permission-preserving development update.
- APNs provider credentials, matching App ID capabilities, AASA hosting, signed environments and real suspended delivery remain unverified. Do not claim push is live from unit tests.
- Support/privacy/terms pages must actually load at the submitted URLs. Confirm effective date and public seller/contact fields before publishing the privacy draft.
- Complete exact-build phone/iPad input, dictation, clipboard, background recovery, restart and release-input checks. The reported two-finger-scroll and keyboard-toolbar defects are being fixed in the coordinated phone branch.
- Complete free LAN / denied free WAN and VPN / paid direct and relay / IPv6 and NAT64 / expiry and revocation / renewal-boundary tests. Unsupported local-proof cases remain blocked.
- Record quiet and loaded machine performance; do not claim 120 fps without measured delivery from a suitable source.
- Complete real sandbox expiry, clean install, pairing, update, removal, archive validation, notarization/stapling and signed-update checks. Only then approve deployment, store submission or publication for the exact artifacts.

Local preparation commands and fail-closed configuration checks are in `script/release/README.md`. Source/test/install receipts are under `work/launch-preparation/`; physical input receipts are maintained by the coordinated Farside chat until integrated into this ledger.
