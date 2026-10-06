# Farside privacy policy and App Privacy preparation

Clipboard, metadata, opt-out, purchase-retention and local-trust wording reconciled 5 October 2026 against main `4524689`; image clipboard, local text recognition, shared folders and workspace preferences were additionally reconciled against combined `84dc0a5` on 5 October. Other engineering material retains its 29 September review date. This is an **unpublished draft**, not a live privacy-policy receipt or final legal classification. Purchases are disabled; real APNs delivery, production configuration and distribution acceptance remain open. Complete public contact/effective-date fields, verify provider logging/retention and obtain the owner's final review before publication or App Store entry. The older legal/export/age-rating research in sections 4–6 is dated 28 September and requires action-time verification; it does not authorize portal submissions or changes in availability.

The product is Farside; existing `com.roshan.PocketDesk.*` bundle identifiers remain. Engineering source anchors below describe prepared behavior, not a claim every provider feature is live.

## 1. Current engineering data inventory

| Data | Destination, storage and limits | Source |
|---|---|---|
| Screen and input | Encrypted WebRTC media/data between paired devices, directly or through TURN. No persistent stream recording or readable content upload to the connection service. Explicit text recognition temporarily copies a displayed frame locally, as described below. | `RemoteHost/RemoteCapture.swift`, `RemoteHost/RemoteInputDriver.swift`, `RemoteShared/PeerMedia.swift` |
| Voice and camera | Speech recognition requires on-device support; only explicitly accepted text is sent to the Mac. Camera scans pairing QR locally. | `RemotePhone/VoiceInputController.swift`, `RemotePhone/ScannerView.swift` |
| Text-field detection | Mac returns a boolean; no field content, title or label is requested. | `RemoteHost/HostTextFocusProbe.swift` |
| Text clipboard | Explicit text actions plus default-enabled, negotiated automatic Mac-to-phone text sync during an admitted control session. Internal `clipboardAutoSyncDisabled` removes that option; no user-facing toggle is claimed. Phone text reads for transfer use the chosen system Paste action; metadata polling alone does not read text. No clipboard history; 256 KB cap; concealed/transient Mac items refused. Incoming Mac text requests local-only phone storage and five-minute expiry; Mac clipboard contents can remain until replaced/cleared. | `RemoteHost/HostModel.swift:3349`, `RemoteHost/HostClipboard.swift`, `RemotePhone/PhoneClipboard.swift:337` |
| Image clipboard | Explicit system Paste to Mac or Get Mac image; PNG normalized in memory, capped at 8 MiB encoded and 16 million pixels. Separate bounded transfer/authority checks; no automatic image sync or paste into another app. Phone image writes request local-only storage but no timed expiry. Mac image entries can remain until replaced/cleared. | `RemotePhone/RichClipboardView.swift`, `RemotePhone/RemotePhoneApp.swift:2156`, `RemoteHost/HostClipboard.swift:275`, `RemoteShared/RichClipboardProtocol.swift:6` |
| Local text recognition | User-selected displayed-frame crop and recognized/editable text stay in local memory. Closing clears the displayed copy/text; an in-flight Vision job can retain its working image until it finishes. Explicit Copy reviewed text writes the ordinary phone clipboard without requesting local-only storage or expiry. | `RemotePhone/FrozenTextController.swift:20`, `RemotePhone/OwnedVideo/FrozenTextSnapshot.swift:7` |
| Shared folders and downloads | Mac stores explicitly chosen folder bookmarks and filesystem identities in local preferences. An admitted paired phone can receive names, kinds, sizes/modification times and chosen file contents over encrypted transport; absolute paths are not sent by the browser protocol. Phone downloads persist in app Documents. Revoke removes the Mac grant, not already downloaded copies. | `RemoteHost/HostFileBrowserFolders.swift`, `RemoteHost/HostFileBrowserService.swift`, `RemoteShared/FileBrowserProtocol.swift`, `RemotePhone/PhoneFileTransfer.swift:12` |
| Workspace and saved views | Requested app/window catalogs send app names/window titles and view geometry to the paired phone. Named views persist labels, trusted-host association, display hints and viewport numbers in phone preferences; shortcut profiles persist app associations, labels, ordering and chosen key/modifier combinations. No screenshot is stored in a named view. | `RemoteHost/HostWindowWorkspace.swift`, `RemotePhone/TaskViewWorkspace.swift`, `RemotePhone/ShortcutWorkspaceStore.swift` |
| Pairing trust and preferences | Pairing credentials/screen key in local Keychain; preferences in UserDefaults. iOS uses WhenUnlockedThisDeviceOnly. Existing macOS queries use the file-based Keychain; do not describe that Mac path as documented device-only Data Protection storage. | `RemoteShared/Pairing.swift`, `RemoteHost/HostReadiness.swift` |
| Signaling and admission | TLS service receives random room identity, authentication proof, role and network metadata; encrypted signaling is forwarded. Workers/Durable Objects store room/authentication hashes, bounded policy state and relay credential/revocation metadata. D1 stores room status and entitlement associations. Screen-encryption key is not sent to the service. | `Backend/src/room.ts`, `Backend/src/entitlement/store.ts` |
| Purchases | Service receives signed Apple transaction for verification; stores a keyed hash of original transaction ID, product/environment, access/grace/revocation dates and device associations. Apple notification identifiers/types are retained for deduplication. No card or Apple ID login credentials. | `Backend/src/entitlement/store.ts`, `Backend/src/apple/` |
| Agent alerts | Opt-in pairing-bound APNs token/preferences plus generic event ID, agent kind and timing. Action reports are fixed choices, not prompt/chat/file/screen text. Event lifetime 15 minutes; expiry cleanup runs in the retention job. | `Backend/src/push.ts`, `RemotePhone/SystemIntegrations/AgentNotifications.swift`, `AgentAlertCenter.swift` |
| Session Live Activity | Separate APNs activity token, activity ID and session epoch for end-only delivery; bounded retry after the session ends. Agent-alert opt-out does not delete an unrelated session-ending address. | `Backend/src/activity.ts`, `Backend/src/room.ts` |
| Diagnostics | User-requested Copy Diagnostics and optional local stream statistics; no automatic content upload. Backend stores fixed security audit events/fingerprints. Final infrastructure logs and support retention still require review. | `RemoteHost/HostDiagnostics.swift`, `RemoteShared/StreamStatistics.swift`, `Backend/src/entitlement/store.ts` |
| Updates and dependencies | Release Mac update checks use Sparkle only with configured public key/feed. Automatic checks/downloads are disabled in current configuration. WebRTC, Sparkle and bundled fonts have in-app notices. | `RemoteHost/HostUpdateController.swift`, `project.yml`, `RemoteShared/ThirdPartyNotices.txt`, `RemoteShared/LegalNoticesView.swift` |

Removal is not cancellation. Local trust retirement, authenticated server deletion and Apple subscription cancellation are separate actions. The `.11` physical `delete:-25244` result is historical, not a current-build verdict. Current Mac source deletes and verifies the exact Keychain item, or on an ownership error replaces and verifies the saved pairing with a removal marker that contains no usable pairing credentials; that fallback does not remove the Keychain row (`RemoteShared/Pairing.swift:524–582`). Source implementation does not establish physical cleanup acceptance, successful server deletion or provider erasure.

## 2. Privacy policy draft for publication

**Effective date:** [TO FILL] · **Last updated:** [TO FILL]

**Operator:** [TO FILL: confirmed legal seller name], individual seller under the recorded decision. **Public mailing address/telephone:** [TO FILL: confirmed business/mailbox details, never infer a home address]. **Privacy contact:** support@getfarside.com. **Policy URL:** https://getfarside.com/privacy (must actually serve this final reviewed policy).

### Your screen, control and local features

Farside lets you view and control your own paired Mac from an iPhone. There is no Farside account registration. Your Mac screen and control messages travel encrypted between your devices, directly or through a relay. Farside does not save a recording of your screen, keystrokes or audio. If you choose text recognition, it temporarily copies a displayed frame on your phone as described below. Our connection service does not receive the screen-encryption key. Technical connection metadata remains visible to the service and relay provider.

Screen Recording and Accessibility permissions enable the chosen Mac display and allowed controls. Pairing requires a short-lived code and approval on the Mac. Camera frames are used locally to scan that code. Voice recognition runs on the phone; Farside refuses recognition that cannot run on device. Only the text you accept with Done goes to the Mac.

Clipboard text travels encrypted between your paired devices. When both devices support it, automatic Mac-to-phone text sync is enabled by default: Farside watches for changes to the Mac clipboard during an active, authorized control session. It does not send clipboard contents already present when sync starts. Automatic sync is unavailable while the session is paused, locked, concealed, View-only or in Low Data Mode. The phone checks clipboard metadata to offer Paste; it reads clipboard text for transfer to the Mac only when you choose the system Paste action.

Farside keeps no clipboard history. For text transfers, incoming Mac text replaces the phone's system clipboard with a local-only entry and a requested five-minute expiry. Text pasted into another app has that app's retention; text sent to the Mac can remain in its system clipboard until replaced or cleared. Farside refuses marked concealed/transient Mac clipboard items and limits each text transfer to 256 KB.

Image clipboard transfer is separate from automatic text sync. Choose the system Paste control to send one image to your Mac, or Get Mac image to fetch the Mac's clipboard image. Farside checks current session authority and marked-private clipboard metadata, normalizes the image to PNG and limits it to 8 MiB encoded and 16 million pixels. The image travels encrypted between your paired devices. It is copied to the receiving clipboard; Farside does not automatically paste it into another app. Incoming images on the phone request local-only storage but no timed expiry. Mac image clipboard entries can remain until replaced or cleared. Copies pasted or saved elsewhere follow that app's retention.

Select text from picture temporarily copies the visible part of a displayed frame and uses Apple's Vision framework to recognize text on your phone. You can review and edit the result before choosing Copy reviewed text. Farside does not send the frame or recognized text to a recognition server. Closing the tool clears its displayed image and text; an already-running recognition job may retain its working image until it finishes. Copy reviewed text writes the ordinary system clipboard without requesting local-only storage or an expiry, so the system's clipboard behavior applies. Closing the tool does not erase a copied result or text pasted elsewhere.

Shared folders are read-only folders you explicitly choose in Mac Settings. Farside stores bookmarks and filesystem identities on that Mac so the choices can survive restarts. During an allowed control session, the paired phone can browse names, file kinds, sizes and modification times, and request downloads. Browser metadata and chosen files travel encrypted between the devices; the browser protocol uses opaque entry identifiers rather than sending absolute Mac paths. Revoke a folder in Mac Settings to remove its grant. Ending a session does not delete the saved grant. Completed downloads remain in Farside's Documents on the phone and can be managed in Files; revocation or disconnect does not erase those copies or copies saved elsewhere.

Workspace lists can show names of running Mac apps and window titles on the paired phone. Saved task views store your label, a Mac association, display hint and viewing-position numbers in the phone's preferences, rather than a screen image or document contents. Personalized shortcuts also store app associations, labels, ordering and chosen key combinations there. These preferences survive ending a session; you can delete a saved view or restore an app's default shortcuts. Do not put private information in labels you do not want retained on that phone.

Pairing credentials and encryption keys are stored in each device's Keychain. Preferences remain on the device. Keep your phone locked: anyone using an unlocked paired phone may exercise the controls you enabled while the Mac is sharing. The Mac's physical display may still be visible to people nearby.

### Connection service and relays

Our Cloudflare-hosted service receives authentication proof, random pairing/room identity, connection timing and network information needed to connect and secure your devices. It forwards encrypted setup messages and stores room/authentication hashes, session-policy state, entitlement links and relay revocation state. This is not an in-memory-only service.

Free access requires a verified directly attached local Wi-Fi/Ethernet path. Internet, VPN, routed or unverifiable access requires Farside Anywhere. When a relay is used, Cloudflare forwards encrypted media and control traffic and can observe IP addresses, timing and traffic volume. It does not receive the paired-device encryption key. [CONFIRM before publication: final Cloudflare logging, analytics, backup and provider retention settings.]

### Purchases

Apple processes Farside Anywhere payments. We do not receive your payment-card details or Apple ID password. The app sends Apple's signed purchase transaction to our service to verify access. Our subscription record keeps a keyed hash derived from the original transaction ID, subscription product/environment, access/grace/revocation dates and device associations. Apple server notifications let access reflect renewal, refund and revocation. Subscription records and their device associations are eligible for cleanup 90 days after the verified expiry or grace-period deadline, whichever is later; notification deduplication records after 90 days. These thresholds depend on scheduled cleanup and do not certify deletion from provider logs or backups.

Unlinking a device or deleting Farside server data does not cancel an Apple subscription. Manage cancellation or refund requests through Apple. Current preparation builds have new purchases disabled until the intended service has passed acceptance.

### Optional alerts and Live Activities

Agent alerts are an opt-in beta for blocking Claude Code/Codex permission events. We store a pairing-bound Apple push token and preferences to deliver generic alerts, plus short-lived event identifiers and fixed action reports for deduplication. We do not include prompts, chat text, file names, typed text or screen content. Tapping asks you to Connect; it never silently connects or approves an agent action.

Turning agent alerts off in Farside requests removal of their registration, events and reports; cleanup retries if the service is unavailable. Disabling notifications in iOS stops their presentation but does not itself guarantee server deletion. Session Live Activities use a separate token/session identity so the service can end an activity while the phone is suspended. Their ending addresses may remain briefly for bounded end-delivery retries. [CONFIRM before publication: exact signed APNs/AASA configuration and real delivery receipts.]

### Updates, diagnostics and support

Mac Release builds can check the configured signed-update feed using Sparkle. Automatic checks/downloads are currently disabled. A user-requested feed/download request exposes connection metadata to the hosting provider. Confirm the final archive's profiling and request fields before publication; do not promise an unmeasured provider request shape.

Copy Diagnostics creates a local report with fixed app/permission/connection status and excludes screen content, typed text, clipboard contents, pairing codes, tokens and network addresses. Optional stream statistics stay local unless you choose to share them. Backend security audit records contain fixed event metadata/fingerprints, not screen content. No advertising or tracking SDK is included. [CONFIRM: any final provider logs and support-email retention.]

### Retention and deletion

The current application cleanup rules are listed below. These are eligibility thresholds serviced by scheduled cleanup, not promises of deletion at an exact wall-clock instant. Provider backups/logs and applicable legal obligations must be reviewed separately.

| Information | Current application rule |
|---|---|
| Room/authentication state | Authenticated server removal clears ordinary room state and room/device links. Unused active D1 room entries are eligible after 365 days. Security blocks and pending relay revocations can remain to enforce abuse prevention/revocation. |
| Subscription records and device associations | Eligible 90 days after the verified expiry/grace deadline, whichever is later; unlinking removes the requested device association separately. |
| Apple notification deduplication | Eligible after 90 days. |
| Security audit | Eligible after 30 days. |
| Agent alert events/reports | Events expire after 15 minutes; expired events/reports are removed by retention cleanup. |
| Agent alert registration | Removed on successful app opt-out/unpairing/server removal or invalid-token handling; stale registrations eligible after 365 days or inactive-room cleanup. |
| Activity-ending addresses | Stale active addresses eligible after 24 hours; ended addresses eligible 15 minutes after end. End retries are bounded. |
| Local trust/preferences/clipboard | Local usable trust retirement must be confirmed; a verified Mac removal marker may leave a Keychain row without pairing credentials. Preferences and system clipboard entries have separate lifetimes, including the phone's requested five-minute expiry for incoming text, not images or reviewed OCR copies. Unlinking does not guarantee removal of text pasted elsewhere or of provider records. |
| Shared-folder grants and downloads | Mac folder grants persist until revoked. Completed phone downloads remain in app Documents after a session or grant ends; already saved/shared copies have independent retention. |
| Saved task views and shortcuts | Stored in phone preferences across sessions; Delete removes a named view and restoring shortcuts removes that app's custom profile. Do not equate server deletion with all local preference/file cleanup. |
| Temporary recognition data | Displayed image/text clear when the tool closes; in-flight recognition retains its working copy until completion. Explicit clipboard copies have separate system/receiving-app lifetimes. |
| Provider logs/backups and support | [TO FILL: reviewed effective settings and confirmed retention.] |

Stop Sharing ends remote access. Local Remove Phone retires the Mac's usable pairing trust after local cleanup is confirmed; it does not by itself confirm server deletion. If macOS refuses deletion because of Keychain ownership, Farside can replace and verify the saved pairing with a removal marker; the Keychain row may remain without usable pairing credentials. The phone unlink and Mac Server Data controls use authenticated service endpoints; they preserve required proof while server deletion is pending and expose progress/retry. Completion means the requested server response and local cleanup have been confirmed, not that every provider record has been erased. Security blocks, audit/purchase retention and pending relay revocations may remain as described above. Deleting server data does not cancel Apple billing.

### Providers and choices

Cloudflare provides connection, relay and backend infrastructure. Apple provides distribution, purchases and push delivery. [TO FILL: confirmed website/support/email providers and any relevant international-transfer details.] We do not sell data or use it for advertising/tracking.

You can stop sharing, unlink devices, request authenticated server deletion, change device permissions, disable alerts and manage your subscription with Apple. Contact support@getfarside.com for privacy questions; ownership proof may be required for a deletion request. [TO FILL: applicable legal rights, complaint routes, legal bases, children's/minimum-age terms and jurisdiction reviewed for the actual distribution regions.]

We will update the published policy when practices change. [TO FILL: confirmed notice procedure and final operator contact details.]

## 3. App Privacy answer preparation

Apple requires accurate declarations covering developer and integrated partners' collection, including data retained for app functionality. Its definition distinguishes real-time handling from readable retained data. Rechecked 29 September 2026: [Apple App Privacy details](https://developer.apple.com/app-store/app-privacy-details/).

Current phone/host manifests declare Device ID and Purchase History, linked for app functionality with no tracking. Required-reason manifests exist for phone, Mac and widget; the exact signed archive and Xcode privacy report still need inspection.

| Proposed declaration | Engineering basis / open final review |
|---|---|
| Purchase History, linked, functionality | Backend verifies and retains subscription records and device links. |
| Device ID, linked, functionality | Pairing/install identities and APNs addresses persist for access and optional delivery. |
| User ID | Review whether keyed subscription identity needs a distinct User ID declaration; do not treat hashing as proof it is unlinked. |
| Product Interaction / other applicable event type, linked, functionality | Generic agent events and fixed action reports are retained beyond a single request. Final declaration/manifests must cover this beta behavior. |
| Diagnostic / network metadata | Resolve from actual security records and provider log/analytics retention. Do not assume all metadata is unlinked or transient. |
| Content and support | Screen/input, chosen images and files stay encrypted between devices; voice/camera/OCR processing is local. Account for local frame copies, system clipboard entries, saved downloads and workspace preferences described above when reconciling the exact archive and declarations. Separately review any support information voluntarily submitted and any provider-accessible retained content. |

Current source includes no ATT integration or advertising/data-broker tracking. Confirm the final partners' practices before submitting a no-tracking answer. Finalize the declarations from the configured release service and provider settings, then make the archive manifests, in-app policy and App Store answers agree. These are preparation notes, not submitted answers.

---

## 4. Export compliance

**What Apple requires [V].** If an app uses, contains or incorporates encryption, uploading it to App Store Connect or TestFlight is an export. Distribution outside the US or Canada is subject to US export law regardless of where the developer is based. App Store Connect asks a questionnaire per build unless `ITSAppUsesNonExemptEncryption` is set. Apple says to set it to NO if the app, including third-party libraries, uses no encryption or only forms exempt from documentation, and otherwise YES. If documents are required, Apple reviews them (about two business days when complete), then supplies a code for `ITSEncryptionExportComplianceCode`.

**Apple's table [V].**

| Encryption used | Documentation in App Store Connect |
|---|---|
| Limited to Apple's operating system | None |
| Industry-standard algorithm not provided by the operating system | French encryption declaration, only if distributed in France |
| Proprietary or non-standard algorithm | US CCATS and French declaration |

**Farside's cryptography inventory.**

| Use | Implementation | OS-provided? |
|---|---|---|
| Connection-setup payload | AES-256-GCM, SHA-256, secure random via CryptoKit and Security (`RemoteShared/Pairing.swift`) [R] | Yes |
| `wss://` to signaling | TLS via `URLSessionWebSocketTask` [R] | Yes |
| Keychain storage | Security framework [R] | Yes |
| Media and control channel | WebRTC 153.0.0 (`stasel/WebRTC`, pinned in `project.yml`): DTLS, SRTP, ICE/STUN/TURN integrity, X.509 certificates, all IETF-standard algorithms [R]; exact cipher suites [I], confirm from `getStats()` | **No. The library carries its own implementation.** |
| Proprietary crypto | None | n/a |

**Conclusion and answers.** The bundled WebRTC crypto is standard, not proprietary, and not limited to the OS. Therefore:

1. Set `ITSAppUsesNonExemptEncryption = YES` in the iOS app's Info.plist (`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = YES` in `project.yml` when engineering edits it). [I on classification; the Apple table supports this reading.]
2. In App Store Connect answer that the app uses encryption, that it is standard algorithms in addition to the OS (dialog wording varies; follow the questions), that it is not proprietary.
3. **France:** either exclude France in App Store availability for 1.0 (no declaration needed) or upload a French encryption declaration [O, decision]. Excluding France is the fastest path.
4. Add `ITSEncryptionExportComplianceCode` only if Apple issues one after review.
5. **US annual self-classification report.** BIS says the report is required for items exported under License Exception ENC 740.17(b)(1) unless a CCATS was obtained; it covers 1 Jan to 31 Dec and must be received by 1 Feb of the next year as a CSV emailed to BIS and the ENC Encryption Request Coordinator, with these 12 columns: product name, model number, manufacturer, ECCN, authorization type (ENC or MMKT), item type, submitter name, phone, email, mailing address, non-US components, non-US manufacturing locations; no report is due for a year with no applicable exports. Apple's own page also warns of a possible year-end self-classification report. [V] Whether a consumer WebRTC app is reported as ENC, treated as mass market (MMKT, commonly ECCN 5D992.c), or needs nothing, is a legal classification: [O] ask export counsel or BIS before 1 Feb 2027. The Mac download from your website is also an export.
6. TestFlight: each new build shows "Missing Compliance" until the questions are answered or the plist key and code are present. [V]

---

## 5. Age rating answers

Apple's current scheme has 4+, 9+, 13+, 16+ and 18+ (Unrated cannot be published). [V]

| Questionnaire item | Answer |
|---|---|
| Parental Controls | No |
| Age Assurance | No |
| Unrestricted Web Access | No. The app contains no browser; it shows the user's own Mac. Competitors listed at 4+ (Workbench, Jump Desktop, Screens 5) [V]. Apple may still disagree at review; the consequence would be a higher age band, not a rejection. |
| User-Generated Content | No |
| Social Media | No |
| Messaging and Chat | No |
| Advertising | No |
| Profanity or Crude Humor; Horror or Fear Themes; Alcohol, Tobacco or Drug Use or References | None |
| Medical or Treatment Information; Health or Wellness Topics | None |
| Mature or Suggestive Themes; Sexual Content or Nudity; Graphic Sexual Content and Nudity | None |
| Cartoon or Fantasy Violence; Realistic Violence; Prolonged Graphic or Sadistic Realistic Violence; Guns or Other Weapons | None |
| Gambling; Simulated Gambling; Contests; Loot Boxes | None |
| Made for Kids; Override to higher age | Not applicable. Do not override unless your Terms set a higher minimum age; a EULA minimum age above the calculated rating forces an override. [V] [TO FILL] |

Expected result: **4+**. Region-specific ratings (Australia, Brazil, Korea, Vietnam) trigger only for content this app does not have. Screenshots and previews must be suitable for 4+ regardless (Guideline 2.3.8), so stage the demo Mac carefully. Optionally set an Age Suitability URL.

---

## 6. Other App Store Connect declarations and the privacy manifest

| Item | Answer or action |
|---|---|
| Privacy Policy URL | Required (iOS). Privacy Choices URL optional; can point to a "delete my data" page. [V] |
| App Store Server Notifications URL (production and sandbox) | The entitlement service; see SUBSCRIPTION-SETUP.md. |
| Content rights | The streamed desktop is the user's own content; answer per the on-screen question. [I] |
| Advertising Identifier (IDFA) | Not used. |
| Sign-in required for review | No. |
| EU DSA trader status | Required even if you do not distribute in the EU; a trader's address, phone and email are published on the EU product page. Individuals supply address or PO box; organizations use the D-U-N-S address. Use a business address or PO box if you do not want a home address public. [V] |
| Tax and banking | Paid Apps Agreement first, then bank account, then tax forms (non-US developers: W-8BEN, W-8BEN-E or W-8ECI, as directed). [V] |
| Accessibility Nutrition Labels | Voluntary now, expected to become mandatory over time. Do not claim VoiceOver for the streamed session canvas (PRODUCT does not promise it). Evaluate Dark Interface, Larger Text, Reduced Motion and the rest against Apple's criteria before claiming any. [V] |
| iPhone and iPad apps on Apple silicon Macs | Opt out in Pricing and Availability. [V] |

**Privacy manifests now exist.** `RemotePhone/PrivacyInfo.xcprivacy`, `RemoteHost/PrivacyInfo.xcprivacy` and `FarsideWidgets/PrivacyInfo.xcprivacy` replace the old proposed skeleton. Validate the archive's required reasons and collected-data declarations against the current flows in sections 1–3 and generate Xcode's Privacy Report. Existing library manifests and dependency notices do not replace this review. No export-compliance classification or portal answer is inferred from the presence of these files.

**In-app requirements:** Settings must link to the Privacy Policy, Terms, Support and a Legal screen containing the WebRTC BSD-3-Clause and Google WebRTC copyright and disclaimer text (`Docs/WebRTC-distribution-license.md`), since binary redistribution must reproduce them. [R]

---

## 7. Publication and submission gates

- Confirm legal seller/contact/mailbox details, effective date, distribution jurisdictions and minimum-age terms; keep personal home address out of public material.
- Review applicable privacy/export obligations and action-time Apple questionnaires. Earlier research is a dated reference, not approval or final classification.
- Verify effective production provider logging, backups, retention jobs, support retention, STUN/TURN and update request/profiling settings.
- Finalize App Privacy/manifest categories for retained generic agent events/action reports and security metadata; hashing alone does not make linked records anonymous.
- Verify removal, purchase/expiry, APNs/suspended-activity ending and exact archives physically. Current exact-build physical acceptance of local trust retirement and authenticated server deletion remains pending. The `.11` safe local Keychain removal failure is historical, not a current-build result.
- Publish the final policy only after these fields/reviews are complete and URLs work; no publication or App Store submission occurred in this preparation.

## Sources (all checked 2026-09-28)

- App privacy details: https://developer.apple.com/app-store/app-privacy-details/
- Manage app privacy: https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/
- Age ratings values and definitions: https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/ ; Set an age rating: https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/
- Complying with encryption export regulations: https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations ; Overview of export compliance: https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/ ; Determine and upload documentation: https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/ ; Export compliance documentation table: https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/ ; beta builds: https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds/
- BIS annual self-classification report: https://www.bis.gov/learn-support/encryption-controls/annual-self-classification
- Required reason API and manifest keys: https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api , https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype , https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype
- DSA trader requirements: https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/
- Tax forms and Paid Apps Agreement: https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information/ , https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/
- Accessibility Nutrition Labels: https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels/
- Cloudflare TURN FAQ (14 Jul 2026) and analytics: https://developers.cloudflare.com/realtime/turn/faq/ , https://developers.cloudflare.com/realtime/turn/analytics/
- Guidelines 5.1.1, 5.1.2, 2.3.8: https://developer.apple.com/app-store/review/guidelines/
- Repo evidence as cited in section 1.
