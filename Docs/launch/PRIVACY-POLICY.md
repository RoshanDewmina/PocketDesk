# Farside: privacy policy draft, App Privacy answers, export compliance and age rating

Prepared 28 September 2026 from the code in this repository and Apple's current documentation. This is a working draft for the owner and a lawyer, not legal advice.

**Naming:** the product is now called **Farside** (renamed from PocketDesk on 28 Sep 2026). Bundle IDs stay `com.roshan.PocketDesk.*`; code identifiers and plist keys still say PocketDesk until engineering renames them and are quoted verbatim.

Labels: **[R]** verified in the repo (file named); **[V]** verified from a primary source today; **[I]** inference or unverified; **[O]** owner action; **[E]** engineering. Anything that needs the owner's legal or business details is marked **[TO FILL]**. Anything that depends on backend behaviour that does not exist yet is marked **[CONFIRM]**.

Contents: 1 data-flow inventory (what the app really does) · 2 the policy draft · 3 App Privacy "nutrition label" answers · 4 export compliance · 5 age rating · 6 other App Store Connect declarations and the privacy manifest · 7 open items.

---

## 1. What the code actually collects, logs and sends

| Data | Where it goes | Stored? | Evidence [R] |
|---|---|---|---|
| Screen video of the selected Mac display | Mac to phone over WebRTC with DTLS-SRTP, direct or via a TURN relay | Not saved. Frames go to the encoder only. | `RemoteHost/RemoteCapture.swift` (`SCStream`, `capturesAudio = false`); only file write in the app is the opt-in stats log below |
| Pointer, keyboard and text input | Phone to Mac over the WebRTC data channel; Mac injects with `CGEvent` | Not logged | `RemoteShared/ControlProtocol.swift`, `RemoteHost/RemoteInputDriver.swift`; grep for `Logger`, `print`, `NSLog` finds only the stats logger |
| Voice | Recognized on the iPhone. Only the resulting text is sent to the Mac when the user taps Done. Audio never leaves the phone. | Not stored | `RemotePhone/VoiceInputController.swift`: requires `supportsOnDeviceRecognition`, sets `requiresOnDeviceRecognition = true`, otherwise refuses |
| "Is the clicked element an editable text field?" | Mac answers yes or no to the phone | No | `RemoteHost/HostTextFocusProbe.swift`: role, enabled, editable and value-settable attributes only; contents and labels are not requested |
| Camera frames | Scanned locally for the pairing QR | No | `RemotePhone/ScannerView.swift` (`AVCaptureMetadataOutput`) |
| Pairing invitation (QR or pasted text) | Shown on the Mac, read by the phone. Contains signaling URL, room ID, one-time token, 32-byte key, expiry, Mac name. | Mac and phone keep trust in Keychain | `RemoteShared/Pairing.swift` (`HostPair.create` expires in 120 s; `validate` rejects more than 180 s) |
| Connection setup messages | Phone and Mac to our signaling service, which forwards them. They are AES-256-GCM encrypted with the key from the QR; the service never has that key. | Not stored | `RemoteShared/Pairing.swift` (`SignalCipher`), `Server/src/server.ts` (forwards only base64 `payload`) |
| Registration to signaling | Room ID (SHA-256 of a random host token), bearer tokens, role, client IP address as seen by the service | Rooms and rate-limit counters are in memory; approved room IDs persist in a file; pending approvals hold room ID, fingerprint and time | `Server/src/server.ts`, `Server/src/rooms.ts`, `Server/README.md` |
| TURN relay traffic (subscribers, or as designed) | Encrypted media and input pass through Cloudflare TURN | Cloudflare keeps aggregate analytics per credential (bytes, connections, location of data centre); retention is not stated in its docs [V] | `Server/src/turn.ts`, Cloudflare TURN FAQ and analytics pages |
| Trust material | iPhone and Mac Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (not synced) | On device | `RemoteShared/Pairing.swift` line 145 |
| Preferences | Phone: click haptics, pointer sensitivity, viewport mode. Mac: allow control, keep awake, sharing enabled, accessibility step skipped, service URL. | On device (`UserDefaults`) | `RemotePhone/RemotePhoneApp.swift`, `NativeSessionView.swift`, `RemoteHost/HostReadiness.swift` |
| Push notification token (only if push ships) | Phone registers with Apple Push Notification service; the token would be sent to our server so it can notify you | Server-side, until you remove the Mac or turn notifications off | Not in code today. `Docs/launch/APPLE-PORTAL-SETUP-2026-09-28.md` task 2 shows APNs key preparation is planned. Counts as Identifiers: Device ID (already declared). |
| Diagnostics | A hidden switch (`PocketDeskStreamStats`) writes stream statistics (codec, fps, bitrate, route type, loss) to `Caches/PocketDeskStreamStats.jsonl` and the system log; nothing uploads it | On device, opt-in, capped near 32 MB | `RemoteShared/StreamStatistics.swift` lines 341 to 370 |
| Analytics, ads, crash SDK, tracking | None. The only package dependency is WebRTC. | n/a | `project.yml` packages; grep for Firebase, Sentry, Mixpanel, Amplitude, MetricKit, Analytics returns nothing |
| Login item and keep-awake | Opt-in, local | On device | `RemoteHost/HostModel.swift` lines 147 and 377; `HostKeepAwake.swift` |
| Clipboard | No sync exists today. The Mac only copies the pairing code to the pasteboard when the user presses Copy. | n/a | `RemoteHost/HostModel.swift` line 291; clipboard sync is "in progress" per the owner |
| Browser viewer path (hidden in Mac UI, unmounted MCP routes) | Would involve browser keys and the `Server/src/browser/` routes | n/a | PRODUCT section 12; disable in release or extend this policy |

Facts the policy must not overstate: the service can see connection metadata; DTLS-SRTP protects media contents but not who connects when; the Mac's physical screen is visible to anyone in the room; whoever holds a paired, unlocked phone can control the Mac while sharing is on.

---

## 2. Privacy policy (draft for publication)

> Publish at a stable HTTPS URL (for example `https://[TO FILL domain]/privacy`) and link it in App Store Connect, from inside the iOS app (Settings), from the Mac app menu and from the website footer. Guideline 5.1.1(i) requires the in-app link and the ASC field. [V]

# Farside Privacy Policy

**Effective date:** [TO FILL]  **Last updated:** [TO FILL]

**Who we are:** Roshan [TO FILL: legal name as on the Apple Developer account], an individual (PRODUCT D37); mailing address [TO FILL: P.O. Box or UPS Store mailbox, never the home address], [TO FILL: country]; phone [TO FILL: published number]. Contact for privacy questions: support@getfarside.com. [TO FILL: EU/UK representative or data protection officer, only if counsel says one is required.]

## The short version

- Farside lets you see and control your own Mac from your iPhone or iPad. There is no Farside account. We do not ask for your name, email address or phone number.
- What is on your Mac's screen, what you type and what you say travel between your own devices, encrypted. We do not record, store or look at your screen, keystrokes, clipboard or voice.
- Our servers introduce your devices to each other and, if you subscribe to Farside Remote, pass encrypted traffic along when your devices cannot connect directly. To do that they see technical details such as IP addresses, timing and data volume, and a random identifier for each paired Mac.
- We check your subscription with Apple. Apple handles your payment; we never see your card or Apple ID details.
- No ads. No tracking. No analytics or advertising SDKs. We do not sell your data.

## What Farside does with your information

### On your devices only

- **Screen.** After you allow Screen Recording in macOS, the Farside Mac app captures the display you choose and streams it to your paired phone using WebRTC with DTLS-SRTP encryption. The stream is not saved. It is not sent to us in readable form.
- **Control.** After you enable control and allow Accessibility in macOS, taps and keys on your phone become pointer and keyboard actions on your Mac. They are not logged.
- **Typing help.** When you click on your Mac, the Mac app can check whether the clicked item is a text field so your phone can open its keyboard. It checks only the type of item. It does not read what is in it.
- **Voice input.** When you tap the microphone, your iPhone converts speech to text using Apple's speech recognition on the device. Only the text is sent to your Mac when you tap Done. We never receive audio. If on-device recognition is not available for your language, Farside turns voice input off; it does not send audio to a server instead.
- **Camera.** Used only to scan the pairing QR code on your Mac. Pictures are not saved or sent.
- **Local network.** Used to connect your phone to your Mac when they are on the same network.
- **Clipboard.** [CONFIRM before launch: Farside 1.0 does not copy your clipboard between devices. If a send or paste action ships, it moves only the text you choose, directly between your devices, and is not stored.]
- **Settings and trust.** Your pairing trust is stored in the Keychain on your devices and is not synced to iCloud. Preferences such as pointer speed live on the device.

### To connect your devices

When you pair a phone with a Mac, the Mac shows a code that contains a random room identifier, a one-time token, an encryption key and an expiry of about two minutes. The key stays on your two devices. Our connection service forwards connection-setup messages between them; those messages are encrypted with that key, so we cannot read them.

Each time a device connects, our service receives its IP address (as any internet service does), the random room identifier, a random token and the time. It keeps live connection state in memory only while devices are connected. It keeps a list of approved room identifiers so that only paired Macs can use the service. [CONFIRM: exact logging and retention once the production stack is final. Recommended: no request logs beyond 7 days and none containing message bodies.]

If a direct connection is not possible and you have Farside Remote, your encrypted stream passes through a relay run by our provider Cloudflare. Cloudflare can see IP addresses, port numbers, timing and how much data passed. It cannot decrypt the stream. Relay credentials are short-lived and tied to a random room identifier, not to you. To find network addresses, connection setup may also contact a STUN server operated by Cloudflare. [CONFIRM: STUN configuration.]

### Notifications

[CONFIRM: only if push notifications ship. If they do: Farside asks permission before sending notifications. To deliver them, your phone's Apple push notification token is sent to our server and stored with the random room identifier of the Mac it belongs to. Notifications contain no screen contents. You can turn them off in iOS settings or in the app, which deletes the token.]

### Subscription information

Farside Remote is an auto-renewing subscription bought through Apple. Apple, not us, processes payment. To unlock relay access, the app sends the signed transaction that Apple provides to our server. Our server verifies it with Apple and stores: which subscription product it is, when it renews or expires, Apple's identifier for the subscription (Apple's original transaction ID) [CONFIRM: stored hashed], whether it is a live or test purchase, and which paired room identifiers it has enabled. We also receive notices from Apple about renewals, cancellations and refunds so that access matches your subscription. We keep this while your subscription is active and for [TO FILL: recommended 90 days] afterwards, then delete it.

### Support

If you email us we receive your email address and whatever you choose to send, and we use it to reply. We keep support emails for [TO FILL: recommended 24 months]. Please do not send passwords or screenshots of private content.

### Our website and downloads

Our website and download servers, run by [TO FILL: hosting provider], receive your IP address and the pages or files you request. We do not use advertising or analytics cookies. [CONFIRM] When the Mac app checks for updates it downloads a small update file from our server; the request includes your IP address, the app version and your macOS version. It does not send a system profile. [CONFIRM: Sparkle settings.]

### Diagnostics

Farside contains no crash-reporting or analytics service. If you choose to share analytics with app developers in iOS or macOS settings, Apple may give us anonymous, aggregated crash and usage reports; we cannot identify you from them. A hidden diagnostic setting can save technical connection statistics (frame rate, bitrate, connection type) to a file on your device. Nothing uploads that file; you can send it to us if you choose.

### What we do not collect

The contents of your screen, keystrokes, clipboard, voice or audio recordings, contacts, photos, location, advertising identifiers, browsing history, or health information.

## How we use information

To connect your devices; to verify your subscription and give you relay access; to keep the service secure and limit abuse; to answer your questions; and to meet legal obligations. We do not use it for advertising, profiling or sale.

[TO FILL, if you serve people in the EU or UK: legal bases (for example performance of a contract and legitimate interests in security), and a statement about international transfers.]

## Who receives information

- **Cloudflare** (relay, and [CONFIRM: network, DNS and hosting services]).
- **Apple** (App Store, purchases and server notifications; Apple's own privacy policy applies to its services).
- **[TO FILL: hosting provider, email provider, support tool]**
- Professional advisers or authorities when legally required.

Each provider is bound to protect information at least as strongly as this policy states. We do not sell your information or share it for advertising.

## How long we keep information

| Information | Retention |
|---|---|
| Live connection state | Only while devices are connected (memory) |
| Approved room identifiers | Until you remove the Mac or ask us to delete it [CONFIRM] |
| Subscription record | Active term plus [TO FILL: 90 days] |
| Server request logs, if any | [TO FILL: 7 days] |
| Support emails | [TO FILL: 24 months] |
| Data on your devices | Until you remove the pairing or delete the app |

## Security

Media is encrypted between your devices with DTLS-SRTP. Connection setup messages use AES-256-GCM with a key that never reaches our servers. Connections to our servers use TLS. Trust is kept in the Keychain. Pairing codes expire quickly and the Mac must approve each phone. Stop Sharing on the Mac ends access immediately. No system is perfectly secure. Keep your phone locked and your Mac updated; anyone holding your paired, unlocked phone can use what you have allowed.

## Your choices and rights

- Stop sharing at any time from the Mac menu bar. Remove a paired phone from Farside on your Mac. Remove a Mac from the phone.
- Delete your server-side record: use "Remove this Mac and delete server data" in Settings [E: to be built], or email privacy@[TO FILL domain]. With no account, we may ask you to prove ownership from the device.
- Change permissions (camera, microphone, speech, local network, screen recording, accessibility) in your device settings.
- Cancel your subscription in your Apple ID subscription settings. Refunds are handled by Apple.
- You can ask what we hold about you, ask for correction or deletion, and object to processing. [TO FILL: rights and complaint routes under the laws that apply to you, for example Canada's PIPEDA and Quebec's Law 25, the EU and UK GDPR, and California law. Have counsel confirm which apply.]

## Children

Farside is not directed to children under [TO FILL: 13 or 16, per counsel]. We do not knowingly collect personal information from children, and there is no account.

## Changes

We will post changes here and, for significant changes, tell you in the app. The date at the top shows the current version.

## Contact

[TO FILL: name, postal address, email]

---

## 3. App Privacy ("nutrition label") answers for the iOS app

Apple's definitions [V, app-privacy-details page]: data is **collected** only when it is sent off the device and can be accessed by you or your partners for longer than needed to serve the request in real time; data is **linked** to identity when tied to an account, device or other details unless de-identified before and after collection; **tracking** means linking with third-party data for advertising or sharing with a data broker. Apple also says: if you collect and store IP addresses, declare the relevant data types by how you use them. Answers can be edited any time without a new app version, and must cover all platforms. [V]

**Tracking:** No. No third-party advertising, no data broker, no ATT prompt.

Recommended launch answers, assuming the backend is built as SUBSCRIPTION-SETUP.md proposes:

| Data type | Collected | Linked to identity | Tracking | Purpose | Why |
|---|---|---|---|---|---|
| Purchases: Purchase History | Yes | Yes | No | App Functionality | Server records subscription status and expiry to gate relay. If the server verifies and stores nothing, answer No, but then relay gating and refund handling cannot work. |
| Identifiers: User ID | Yes | Yes | No | App Functionality | Apple's original transaction ID (or its hash) identifies a subscriber. Skip if only a per-room "remote enabled until" flag is stored. |
| Identifiers: Device ID | Yes | Yes | No | App Functionality | Persistent room or pairing identifier for the paired Mac is stored in the approved-rooms list. |
| Diagnostics: Other Diagnostic Data | Only if IP addresses or logs are retained beyond real-time | No (rate-limit and abuse use only) | No | App Functionality | Conservative. Delete this row if logs with IPs are not kept (in-memory rate limiting in `server.ts` is per minute and not retained; proxy and CDN logs are the question). |
| Everything else: Contact Info, Health and Fitness, Financial Info, Location, Sensitive Info, Contacts, User Content (including Audio Data, Photos or Videos, Other User Content), Browsing and Search History, Usage Data, Surroundings, Body, Other Data | No | n/a | n/a | n/a | Voice is processed on device; camera only scans a QR; screen and input are relayed encrypted and not retained; support email happens outside the app. |

Third-party partners: WebRTC is a compiled library that collects nothing; no SDK collects data. Cloudflare is a service provider for infrastructure, and its retention of connection metadata is covered by the Device ID and Diagnostics rows.

Because the answers tie to what the backend stores, finalize them only after the entitlement service and logging are frozen; recheck on every release that changes networking.

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

**iOS `PrivacyInfo.xcprivacy` (app target).** Apple stopped accepting uploads that use required-reason APIs without a manifest on 1 May 2024. The app uses `UserDefaults` in many places and `ProcessInfo.systemUptime` throughout the input and session code, which falls in the system boot time category [R; I on the exact API list, so run Xcode's Privacy Report on the archive to confirm]. Skeleton to give engineering:

```xml
<dict>
  <key>NSPrivacyTracking</key><false/>
  <key>NSPrivacyTrackingDomains</key><array/>
  <key>NSPrivacyCollectedDataTypes</key>
  <array>
    <dict><key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypePurchaseHistory</string>
      <key>NSPrivacyCollectedDataTypeLinked</key><true/><key>NSPrivacyCollectedDataTypeTracking</key><false/>
      <key>NSPrivacyCollectedDataTypePurposes</key><array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array></dict>
    <dict><key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeUserID</string> ... same shape ...</dict>
    <dict><key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeDeviceID</string> ... same shape ...</dict>
  </array>
  <key>NSPrivacyAccessedAPITypes</key>
  <array>
    <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryUserDefaults</string>
      <key>NSPrivacyAccessedAPITypeReasons</key><array><string>CA92.1</string></array></dict>
    <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategorySystemBootTime</string>
      <key>NSPrivacyAccessedAPITypeReasons</key><array><string>35F9.1</string></array></dict>
  </array>
</dict>
```

Reason `CA92.1` covers reading and writing information only the app itself can access; `35F9.1` covers measuring elapsed time between in-app events, with the derived information not sent off the device except elapsed-time intervals. [V] The manifest's collected data types must match the App Privacy answers. The WebRTC framework already ships its own manifest declaring system boot time and file timestamp reasons and no collected data. [R]

**In-app requirements:** Settings must link to the Privacy Policy, Terms, Support and a Legal screen containing the WebRTC BSD-3-Clause and Google WebRTC copyright and disclaimer text (`Docs/WebRTC-distribution-license.md`), since binary redistribution must reproduce them. [R]

---

## 7. Open items

| # | Item | Owner |
|---|---|---|
| 1 | Legal name, address, contact, jurisdiction, effective date | O |
| 2 | Lawyer review for Canada (PIPEDA, Quebec Law 25), EU or UK GDPR if distributing there, California | O |
| 3 | Fix logging and retention on the production stack; fill retention table | E + O |
| 4 | Decide whether IP-bearing logs exist, then finalize the Diagnostics row | E |
| 5 | Build "Remove this Mac and delete server data" and an entitlement-record deletion path | E |
| 6 | Confirm STUN use and Sparkle profiling settings | E |
| 7 | Decide clipboard scope before launch; update the policy line | E |
| 8 | Export classification, France decision, BIS report plan | O |
| 9 | Decide whether Terms set a minimum age | O |
| 10 | Disable the hidden browser path or extend this policy to cover it | E |

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
