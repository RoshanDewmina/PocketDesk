# Farside current review packet — iPhone-only next-candidate draft

Updated **3 October 2026**. Roshan's **D62** makes 1.0 iPhone-only, superseding D57; iPad is dropped from this launch. This is a local review/submission draft, not App Store Connect reviewer notes already saved or submitted.

The September29 packet at `d84a24f:Docs/launch/CURRENT-REVIEW-PACKET.md` is historical preparation. Its installed .11/.12, missing certificate/APNs/app-record and unavailable-domain statements are not the current release state. The earlier packet is preserved in Git and the handoff source snapshot.

## Product and identities

- App: **Farside: Remote Desktop**, existing App Store Connect ID **6817532560**, marketing version 1.0.
- Next launch scope: native **iPhone** client, iOS 26 or later; Apple-silicon Mac companion on macOS 26 or later. The Mac must be awake/unlocked and the companion running for the supported baseline.
- Bundle identities remain `com.roshan.PocketDesk.Remote` and `com.roshan.PocketDesk.RemoteHost`, including their existing extension identities. The installed Mac filename remains `PocketDesk Host.app` for permission continuity.
- D62 is recorded verbatim from Claude's PRODUCT-only commit `f1537e46`, following engineering device-family source change `ae484d8`. This packet performs no engineering change, build or compatibility verification. Do not advertise a dedicated iPad/Workspace experience.

## Accepted .5 facts — retained, not relabeled iPhone-only

| Item | Existing evidence / boundary |
|---|---|
| Executable source | `129d4b35cda31100f688e016f36c8ba4381b9933`; docs-only batch tip `d84a24f` |
| Existing iOS artifact | **Universal iPhone/iPad** 1.0 (`20261002.5`); emitted iPad orientations checked in the accepted export. It is superseded as the platform-scope candidate for D62, not modified by this document. |
| iOS export | Apple Distribution export/signing/extension/privacy checks accepted; IPA SHA256 `48104aacbd8f9d2bcae1f59e2b3c5f43fbc963f36ef7f9d44370468aa736f608` |
| Mac package | Developer ID Release app; Apple notarization accepted; app/DMG staples and Gatekeeper checks accepted. DMG SHA256 `2c027b3e74779f1aee8444090c664a619ace26f28711972b3f4a06e0220ea5cd` |
| Owner quick checks | iPhone/Mac .5 installed 17:49 on 2 October; owner reported four grouped quick checks work well at 17:50. This is bounded smoke evidence. |
| Publication | **HOLD BOTH**: no .5 App Store Connect upload and no production Mac download replacement. Public download remains .3 in the last verified receipt. Beta App Review also unsubmitted. |

Source: the handoff outputs `FARSIDE-20261002.5-RELEASE-PACKET.md`, acceptance receipt and `TESTING-HANDOFF.md`. Preserve those sealed artifacts/recipes and checksums. Their acceptance does not transfer automatically to a later iPhone-only archive or changed app/extension family metadata. New candidate build/version and compatibility are **not yet verified in this docs lane**.

## Reviewer-description draft — service unavailable

```text
Farside lets a person view and control their own paired Mac from an iPhone. It requires the free Farside Mac companion on an awake, unlocked Mac with Apple silicon and macOS 26 or later; the iPhone requires iOS 26 or later.

Pairing starts with a code from the Mac companion. The person compares the short number shown on both devices and explicitly approves the phone on the Mac. Screen Recording permission is required to share the screen; Accessibility permission is required for control. The Mac offers Stop Sharing.

Free use is available on the same Wi-Fi. Farside Anywhere is the optional subscription for use away from home. It remains unavailable while the production service and commerce prerequisites are incomplete; the submitted build must show that same status and prevent purchase of an unavailable service.
```

This block deliberately omits a dedicated iPad layout, Workspace, wake/unlock, speed/fps, unlimited-use and blanket privacy guarantees. Replace the final paragraph only if the exact submitted candidate's paid offer, restore/expiry and production routes have been accepted. Reviewer notes must explain the actual service state, not a future launch plan.

Optional alerts, Live Activities, clipboard/files, dictation, Listen and Couch should be documented separately only if included in the submission and needed to review it. Historical source or mocked/provider adapters are not proof of APNs, background delivery, purchase or physical behavior. Keep on-screen terminology aligned with the candidate.

## Review-access setup — owner completes for the exact candidate

- Provide the actual downloadable Mac companion that matches the intended review workflow; a held .5 URL is not a live public link. Keep bundle/permission identity stable.
- Explain scan, number comparison and Mac Allow using the submitted candidate's actual screens. Do not invent test credentials or a prepared review account; Farside pairing needs no Farside account.
- Verify support/privacy/terms URLs and submitted seller/contact fields. Owner enters sensitive/legal information.
- Record the actual archive/build number, signed app/extension device families, entitlements and portal supported-device presentation. D62 source alone does not close these inputs.
- If Anywhere is enabled, provide actual sandbox offer/restore/expiry, paid direct/relay and revocation evidence plus truthful review instructions. Do not use a staging developer pass as production purchase proof.

## Open release and account boundaries

The owner and separate Claude Code testing chat own all device/manual/A-B checks and testing-found fixes/builds. This chat remains paused for that work. No quiet request or test is initiated by this packet.

The last testing-side report (2 October 19:29–19:30) says staging version `4ba7147d`, with second-device admission `ee78070`, resolved fresh iPad pairing with owner confirmation. That is attributed testing-side evidence, not independent verification or Workspace acceptance. Production version `a1f4300d` was reported to lack the matching admission change; push/preferences 401 retries were still open. Production/backend state must be rechecked by the owner at release time; this packet authorizes no investigation, fix or deploy.

Paid Apps/tax and legal-address/DSA case handling stay with the owner. Actual TURN/IAP/provider readiness, production route acceptance, purchase/restore/expiry and exact-build physical acceptance remain release dependencies. The free-only five-device fallback is a conditional owner decision, not activated here. Mac automatic updates remain disabled in the accepted .5 beta; no signed update/feed readiness is claimed for the next candidate.

.5 deliberately has no hardcoded `ITSAppUsesNonExemptEncryption`. Upload may require the Apple questionnaire. Do not copy the obsolete hardcoded-YES instruction or infer a new legal classification from this packet. Review the next archive's actual crypto changes and owner/Apple compliance decision before submission.

App Privacy, consent, retention, dependency notices/manifests, age rating and accessibility labels must match the submitted build and public policy. Old source-only compliance descriptions are not current legal/provider acceptance. No declaration, legal conclusion or portal setting is changed here.

## Copy / nomination alignment

[STORE-LISTING.md](STORE-LISTING.md) and [ASO-STRATEGY.md](ASO-STRATEGY.md) now use iPhone-only launch copy and conditional Anywhere wording. Existing Apple App Launch nomination **c118885e-229f-41f4-b785-292f536b4f5d** still needs an owner-approved Apple-side edit: remove iPad from platforms and remove iPad promises, retain the 27 October target and reconcile saved description/helpful details with the new draft. Editing the local nomination file does not edit Apple. Do not archive or create a duplicate nomination.

App Store screenshots remain **ON HOLD**. Any future required device sets depend on the actual iPhone-only candidate and portal requirements. No iPad screenshot/preview work is authorized. Upload, beta review, store submission, production website/server changes and public posts remain separate approvals.
