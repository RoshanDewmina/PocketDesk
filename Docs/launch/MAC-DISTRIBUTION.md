# Farside for Mac: how to distribute the companion

Prepared 28 September 2026. Research only; no certificates, records or accounts were created and no source file was touched.

**Naming:** the product is now called **Farside** (renamed from PocketDesk on 28 Sep 2026). Bundle IDs stay `com.roshan.PocketDesk.*`; target names, paths and plist keys still say PocketDesk until engineering renames them and are quoted verbatim. The Mac app will be presented to users as "Farside" (working name "Farside for Mac").

Labels: **[V]** verified from a primary source today; **[R]** verified in this repository; **[I]** inference or unverified; **[O]** owner action; **[E]** engineering.

## 1. Recommendation

Ship the Mac companion **outside the Mac App Store: Developer ID signed, hardened runtime, notarized, stapled, delivered as a DMG from the Farside website, updated with Sparkle 2.** Keep the iPhone/iPad app on the App Store and point users to the Mac download from the listing and from first-run onboarding.

Why, in one paragraph: the companion needs three privileged capabilities (screen capture, posting input events, and Accessibility inspection). Sandboxed apps can use the first and, according to Apple's DTS, the second, but cannot use the Accessibility APIs the host relies on today, the Mac App Store forbids the update mechanism (Sparkle) a fast-moving host needs, App Review has been rejecting event-posting apps under 2.4.5 in 2026, and every comparable product (Astropad Workbench, Jump Desktop Connect, Remote Mac Desktop Control) ships its host directly. Nobody in this category has shown the App Store route working for a capture-and-inject host.

Do not build a Mac App Store variant for 1.0. Revisit only if distribution data later shows users cannot install outside the store.

## 2. What the host does today, mapped to macOS privileges

| Capability | Code [R] | macOS privilege | Sandbox status [V unless marked] |
|---|---|---|---|
| Capture the selected display | `RemoteHost/RemoteCapture.swift`: `SCStream`, `showsCursor = true`, `capturesAudio = false`; gate `CGPreflightScreenCaptureAccess()` and `CGRequestScreenCaptureAccess()` in `HostModel.swift` lines 199 and 213 | Screen and System Audio Recording (TCC) | Works in a sandboxed app with the user's TCC approval. There is no dedicated entitlement: DTS states `com.apple.security.screen-capture` is not a real entitlement and the Mac App Store rejects it (forum thread 778616, Mar 2025). |
| Inject pointer and keyboard input | `RemoteHost/RemoteInputDriver.swift` lines 96 to 160: `CGEvent.post(tap: .cghidEventTap)` | PostEvent (shown under Accessibility in System Settings) | DTS says PostEvent is sandbox-compatible (threads 708652, Jun 2022, and 820594, Mar 2026). |
| Gate control on "trusted" and probe text focus | `HostModel.swift` lines 200, 216, 582, 745: `AXIsProcessTrusted`, `AXIsProcessTrustedWithOptions`; `HostTextFocusProbe.swift`: `AXUIElementCreateSystemWide`, focused element role and editable attributes | Accessibility privilege | **Not compatible with App Sandbox** (DTS, threads 707680 and 820594). In a sandbox `AXIsProcessTrusted` stays false and the prompt never appears. |
| Optional login item | `HostModel.swift` line 377: `SMAppService.mainApp.register()` | User consent in Login Items | Allowed in both worlds; Mac App Store rule 2.4.5(iii) requires consent. |
| Keep Mac awake while sharing | `RemoteHost/HostKeepAwake.swift`: `IOPMAssertionCreateWithName` | none | Allowed. |
| Self-relaunch | `HostModel.swift` line 230: spawns `/bin/sh` via `Process` | none | Not viable in a sandbox. |
| Networking: WSS to signaling, WebRTC UDP to peers | `RemoteShared/SignalingClient.swift`, `PeerMedia.swift` | Local Network prompt on recent macOS [I] | A sandbox would need both client and server network entitlements. |
| Bundle facts | `project.yml` target `PocketDeskRemoteHost`: `LSUIElement`, `ENABLE_HARDENED_RUNTIME: YES`, `CODE_SIGN_IDENTITY: Apple Development`, team `39HM2X8GS6`, min macOS 26.0, no entitlements file; built Debug app carries `get-task-allow` | n/a | Not Developer ID today. |

## 3. Can a sandboxed Mac App Store app do Farside's job?

**Capture: yes.** ScreenCaptureKit plus the user's Screen Recording approval, no special entitlement. [V via DTS, indirect]

**Input injection: technically yes, practically risky.** DTS confirms `CGEvent.post` runs under the PostEvent privilege and that this is allowed in the App Sandbox since macOS 10.15. But in March 2026 a developer reported a sandboxed clipboard manager rejected twice under Guideline 2.4.5 because the reviewer said Accessibility features must not be used for non-accessibility purposes; two more developers reported the same in June 2026 and the thread has no resolution. DTS also said they cannot speak for App Review. [V, forum thread 820594] A remote-control host is a far heavier user of that privilege than a paste helper.

**Accessibility inspection: no.** Farside uses it for two things. (a) `AXIsProcessTrusted()` is the current "control allowed" test. This would have to become `CGPreflightPostEventAccess()`. (b) The auto-keyboard feature asks whether the clicked element is an editable text control (`HostTextFocusProbe.swift`). That cannot work in a sandbox, so the feature (phone keyboard opens when you click a Mac text field) would be lost.

**Other Mac App Store rules that bite (Guideline 2.4.5, raw text [V]):** must be sandboxed; no downloading or installing additional code or resources that add functionality; no auto-launch without consent; **updates only through the Mac App Store, no other mechanism** (so no Sparkle); no license screens or keys; must run on the currently shipping OS; single self-contained bundle.

**Persistent Content Capture** (`com.apple.developer.persistent-content-capture`, macOS 14.4+) is a managed capability. Apple's page says it enables VNC apps to view and record the screen and that you must request permission through a form first. Farside is not a VNC app, so eligibility is unknown. [V page; I eligibility]

Net: partially feasible, product-degrading, review-risky, no precedent. Rejected for 1.0.

## 4. What the competitors do

| Product | Client on App Store | Mac host | Evidence [V] |
|---|---|---|---|
| Astropad Workbench | Yes (iOS 26+) | Direct download from `downloads.astropad.com/workbench/mac/latest`; macOS 15+; Apple silicon preferred | astropad.com product page |
| Jump Desktop | Yes (iOS, and a Mac client at US$34.99) | "Jump Desktop Connect" downloaded from the vendor site through a disk image, not the Mac App Store; needs Screen Recording, Accessibility, and on macOS 14+ a "Remote Desktop" permission for unattended access | docs.jumpdesktop.com/connect/install and /macos-permissions |
| Screens 5 | Yes (iPhone, iPad, Mac, Vision; Edovia says App Store only) | Standalone "Screens Connect" is a separate download (Macs on 10.13+, Windows 10+). Since 5.8.9 (20 Jun 2026) remote access is also built into the Mac app. Whether that built-in piece runs sandboxed is not established. | listing text, release notes, Edovia pricing page |
| Remote Mac Desktop Control | Yes | Notarized, open-source helper downloaded separately | App Store listing |

Every host that does its own capture and input is distributed directly.

## 5. Mac App Store versus Developer ID for Farside

| Dimension | Mac App Store (sandboxed) | Developer ID plus notarization (recommended) |
|---|---|---|
| Screen capture | Works with TCC approval | Works with TCC approval |
| Input injection | PostEvent works technically; review risk under 2.4.5 | Works; no review |
| Accessibility inspection (auto-keyboard) | Impossible | Works |
| Auto-update | Store only | Sparkle 2 |
| Iteration speed | Review per update | Ship when ready; notarization typically under an hour [V] |
| Discoverability | Store search and featuring | Website and the iPhone app |
| Install friction | One click in the store | Download, drag to Applications, one Gatekeeper prompt |
| Sandbox and file access | Container restrictions, self-relaunch not allowed | None |
| Persistent capture entitlement | Unclear if store apps can carry it | Possible with a Developer ID profile after Apple approval [I] |
| Beta program | TestFlight for Mac | DMG plus Sparkle beta channel (TestFlight does not distribute Developer ID builds [I]) |
| Cost and control | 15% or 30% only if it charged (it will be free) | Own hosting, own update infrastructure |
| Precedent | None found | Workbench, Jump Connect, Remote Mac Desktop Control |

## 6. Entitlements, Info.plist and hardening for the Developer ID build

**Hardened runtime: on** (already `ENABLE_HARDENED_RUNTIME: YES`). Notarization requires: Developer ID Application certificate (not Apple Development, Mac Distribution or ad hoc), Hardened Runtime, a secure timestamp, no `com.apple.security.get-task-allow`, valid signatures on every executable, and a macOS 10.9+ SDK link. [V, Apple notarization page]

**App Sandbox: off.** No `com.apple.security.app-sandbox`.

**Entitlements needed for capture, input and AX: none.** These are TCC-gated, not entitlement-gated. Do not add `com.apple.security.screen-capture`; it is not an Apple entitlement. [V]

**Optional, later:** `com.apple.developer.persistent-content-capture`, only after Apple approves the request form (`https://developer.apple.com/contact/request/persistent-content-capture/`, requires developer sign-in) and only with a matching provisioning profile in the exported build. Validate the exact signed build before making any claim about fewer re-approval prompts. [V that the form exists and what the page says; I on eligibility]

**Hardened-runtime exceptions:** none expected. WebRTC and Sparkle are re-signed by Xcode with your team identity on embed; confirm with `codesign --verify --deep --strict` and by launching under hardened runtime. If library validation fails, fix the signing, not by adding `disable-library-validation`. [I]

**Info.plist additions and checks:**

- `NSScreenCaptureUsageDescription` (present, "Share a selected display with your paired phone."). Consider "Stream the display you choose to your paired iPhone or iPad."
- `NSLocalNetworkUsageDescription` is set on the legacy host target but **missing from `PocketDeskRemoteHost`** in `project.yml`. Add it and test the LAN path on a clean Mac; recent macOS applies Local Network privacy to Mac apps too. [I on exact behaviour; R on the gap]
- `PocketDeskServiceURL` (custom key read by `HostModel.swift` line 69 via `Bundle.main.object(forInfoDictionaryKey:)`): set to the production `wss://…/signal` so first run never shows the "enter the private service address" screen (`RemoteHost/HostSetupView.swift`, `.needsService`). [R]
- `SUFeedURL`, `SUPublicEDKey` (Sparkle, section 8).
- Architecture: **Apple silicon only (D35, 29 Sep 2026).** The host and `FarsideWatchdog` build `ARCHS = arm64` in every configuration (`project.yml`), so the DMG carries no Intel slice. State the requirement everywhere as "macOS 26 or later on a Mac with Apple silicon (M1 or later)".
- `LSMinimumSystemVersion`: currently 26.0. Workbench requires macOS 15, Screens 14.0, Remote Mac Desktop Control 14.6 (listings). A 26.0 floor is a real market cut; decide deliberately whether ScreenCaptureKit features you use need 26. [V competitor floors; O decision]
- `ITSAppUsesNonExemptEncryption` is an App Store Connect upload key and is not needed for a Developer ID app, but US export rules still apply to a website download of software containing encryption; see PRIVACY-POLICY.md section 4.
- `NSAppleEventsUsageDescription`, camera and microphone strings: not needed (no audio capture, no Apple events). Keep `capturesAudio = false`.

## 7. Signing and notarization steps

Owner prerequisites: [O] Apple Developer Program membership active (team `39HM2X8GS6` appears in `project.yml`); Developer ID Application certificate created by the Account Holder (Apple's notarization page says the Account Holder signs with Developer ID); an app-specific password or App Store Connect API key for `notarytool`.

Templates (do not commit credentials; run from a clean checkout; adapt names):

```sh
# one time, stores credentials in the Keychain under a profile name
xcrun notarytool store-credentials "farside-notary" \
  --apple-id "<apple-id>" --team-id "39HM2X8GS6" --password "<app-specific-password>"

# 1. archive and export with Developer ID signing (file names below are templates; use the final PRODUCT_NAME)
xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemoteHost \
  -configuration Release -archivePath build/FarsideHost.xcarchive archive
xcodebuild -exportArchive -archivePath build/FarsideHost.xcarchive \
  -exportOptionsPlist ExportOptions-DeveloperID.plist -exportPath build/export
# ExportOptions-DeveloperID.plist: method=developer-id, teamID=39HM2X8GS6

# 2. verify before uploading
codesign --verify --deep --strict --verbose=2 "build/export/Farside.app"
codesign -dv --entitlements - "build/export/Farside.app"     # expect no get-task-allow
spctl -a -vvv -t exec "build/export/Farside.app"             # not yet notarized: rejected is expected

# 3. make and sign the DMG, then notarize and staple it
hdiutil create -volname "Farside" -srcfolder build/export -ov -format UDZO build/Farside-1.0.dmg
codesign --sign "Developer ID Application: <legal name> (39HM2X8GS6)" --timestamp build/Farside-1.0.dmg
xcrun notarytool submit build/Farside-1.0.dmg --keychain-profile "farside-notary" --wait
xcrun notarytool log <submission-id> --keychain-profile "farside-notary"   # read warnings
xcrun stapler staple build/Farside-1.0.dmg
spctl -a -vvv -t install build/Farside-1.0.dmg                # expect: accepted, source=Notarized Developer ID
```

Notarization is not App Review; it is an automated scan and normally finishes in under an hour. `altool` is no longer accepted; use `notarytool`. [V]

Automate this in CI so every Sparkle release goes through the same path. Run a clean-machine check each release: fresh macOS user or VM, download the DMG through a browser (so it is quarantined), drag to Applications, first-run, grant permissions, pair, control. `script/build_and_run.sh` remains the developer install path; do not repurpose it for releases.

## 8. Auto-update with Sparkle 2

Current release: **Sparkle 2.10.0, 13 Sep 2026; requires macOS 12 or later.** [V, GitHub release notes]

1. Add the Swift package `https://github.com/sparkle-project/Sparkle` to the host target only.
2. Generate EdDSA keys once with Sparkle's `generate_keys`. The private key goes in the Keychain of the release Mac; export an offline backup. Put the public key in `SUPublicEDKey`. Losing the private key means existing installs cannot trust future updates. [V per Sparkle documentation]
3. `SUFeedURL` must be HTTPS (for example `https://updates.<domain>/appcast.xml`). Serve the DMGs from the same host or a CDN.
4. Release flow: build, sign, notarize, staple the DMG, drop it in a `releases/` folder, run `generate_appcast releases/` (produces the signed feed and delta updates), upload feed and DMG, then update an older build in place to prove it works.
5. Add "Check for Updates…" to the menu-bar menu (`RemoteHost/HostMenuContent.swift`). The app is `LSUIElement`; make sure the update window activates the app (`HostAppActivation`).
6. Do **not** enable Sparkle system profiling; keep the update check to feed URL, app version and OS version. State this in the privacy policy. [I on defaults; verify]
7. Channels: use a `beta` channel for external Mac testers; stable users never see it.
8. Compatibility: host and phone are versioned separately (the app store lags host updates and the reverse). Set `minimumSystemVersion` in each appcast item, add a minimum-supported-peer-version check to the pairing handshake, and show the existing "update required" state (PRODUCT section 7) rather than failing silently.
9. Do not relaunch into an update during a live session. Sparkle exposes delegate hooks to postpone relaunch; use them so a session is never dropped by an update. [I on exact method names]
10. First run from a mounted DMG or Downloads runs the app from a translocated or read-only location where in-place updates fail. Add a first-launch "Move to Applications" step. [I]
11. Never ship a Sparkle-updating build inside the iOS app or a Mac App Store bundle (2.4.5(vii), 2.5.2).

## 9. Permission identity and re-approval

- **Identity change:** the current installed host is signed with an Apple Development certificate. A Developer ID build has a different designated requirement, so every existing tester must re-grant Screen Recording and Accessibility once. Announce it in the beta notes. After that, in-place Sparkle updates keep the same requirement and grants persist. This matches the stance in `Docs/MAC-PERMISSION-IDENTITY.md`. [R]
- **Bundle ID is part of that identity.** Decision recorded 28 Sep 2026: bundle IDs stay `com.roshan.PocketDesk.RemoteHost` (Mac) and `com.roshan.PocketDesk.Remote` (iOS) even though the product is now Farside. The bundle ID is not shown to users, but it is visible in App Store Connect, cannot be changed once an iOS app record exists, and is part of the Mac TCC and Keychain identity, so it must not change after the first external Mac beta. Renaming the display name and the `.app` file name does not change the designated requirement [I; verify with `codesign -d -r-` before and after]. Note `script/build_and_run.sh` hardcodes `/Applications/PocketDesk Host.app`, so a file rename needs a matching script change. [O decision made; R]
- **Recurring Screen Recording prompts are the biggest Mac-side product risk for "away" use.** Since macOS Sequoia, apps using screen recording APIs are re-prompted periodically ("Allow For One Month"), and Apple documented Persistent Content Capture for VNC apps as the escape hatch. Reports show remote-support tools still being re-prompted on Tahoe. If the prompt fires while nobody is at the Mac, capture stops and the phone cannot fix it. [V that the entitlement exists and its stated audience; secondary sources for the prompt cadence on Sequoia and Tahoe; I for exact behaviour on 26.7 and 27 with Farside]
  - [O] File the entitlement request now.
  - [E] Run a soak: leave a signed build running for 35+ days on a spare Mac and record every capture prompt. This cannot finish before 17 Nov, so launch copy must not promise unattended reliability. Product scope already limits support to an awake, unlocked Mac (PRODUCT D04).
  - [E] Host UX: when capture is revoked or awaiting approval, show it in the menu bar and on the phone ("Approve on your Mac").

## 10. How the iOS listing points users to the Mac download

- **App Store description, first paragraph:** "Requires the free Farside companion for your Mac (macOS 26 or later on a Mac with Apple silicon (M1 or later)): get it at [short URL]." Plain URL text; do not depend on it being tappable.
- **Marketing URL field:** the site home page, whose primary button is "Download for Mac".
- **First-run onboarding on the phone:** screen 1 "Install Farside on your Mac" with the URL, a Copy button and a Share button (system share sheet: AirDrop, Messages, Mail). Screen 2 "Scan the code on your Mac".
- **Site logic:** the download page shows a Mac download button on Mac browsers, and an App Store button plus a smart app banner (`apple-itunes-app` meta tag) on iPhone Safari.
- **Mac first-run window:** step 1 shows a QR that opens the App Store page for the phone app; step 2 permissions; step 3 the pairing QR.
- **Review angle:** linking to a free Mac download is not an external purchase (3.1.x) and matches how Jump and Remote Mac Desktop Control describe their hosts. The only guideline in play is 4.2.3(i); see APP-REVIEW-RISKS.md. Keep the Mac companion free and the website free of subscription checkout.

## 11. Hosting the download and a Mac beta

- One HTTPS host for `/mac` (landing), `/download/mac/latest` (302 to the current DMG), versioned DMGs with SHA-256, `appcast.xml`, release notes and system requirements. A static site with object storage is enough.
- Serve nothing that requires a login. Do not add analytics scripts to the download page in v1, so the privacy policy can say the site sets no tracking cookies.
- Mac beta (Oct): notarized DMG to named testers plus a Sparkle `beta` channel. Keep a "Report a problem" menu item that opens a mail draft with app version, macOS version and route type, and lets the user attach the local stats file; nothing auto-uploads.

## 12. Gaps to close before 30 Oct

| # | Gap | Evidence | Size [I] |
|---|---|---|---|
| G1 | Release configuration with Developer ID identity, export options, no `get-task-allow` | `project.yml` | S |
| G2 | Present the Mac app as Farside: display name, menu-bar text, DMG and app file names, website copy (bundle IDs unchanged). Update `script/build_and_run.sh`, which hardcodes the installed path `/Applications/PocketDesk Host.app`, and the host name shown in Settings ("PocketDesk Host" today) | `project.yml`, `script/build_and_run.sh` | S |
| G3 | Bake `PocketDeskServiceURL` into the release Info.plist | `HostModel.swift` line 69 | S |
| G4 | Add `NSLocalNetworkUsageDescription` to the host and test | `project.yml` | S |
| G5 | Sparkle integration, menu item, appcast, EdDSA keys | none | M |
| G6 | First-run Move to Applications, uninstall guidance and a "Remove all Farside data" action (Keychain trust, defaults) | Pairing and preferences code | M |
| G7 | Disable or remove the browser-viewer path in Release | `BrowserMediaSession.swift` | S |
| G8 | App icon and template menu-bar glyphs | no asset catalogs | S to M |
| G9 | Clean-machine install test on a fresh macOS user or VM | none | S |
| G10 | Persistent Content Capture request; 35-day soak | n/a | O then E |
| G11 | Decide the macOS deployment target (26.0 versus 15.x) | competitor floors | M if lowered |
| G12 | Notarization in CI and a signed release checklist | none | M |

## Sources (all checked 2026-09-28)

- App Review Guidelines, 2.4.5, 2.5.2, 4.2.3 (page "Last Updated: June 8, 2026"): https://developer.apple.com/app-store/review/guidelines/
- Notarizing macOS software before distribution: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Customizing the notarization workflow (`notarytool`, stapling): https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
- Configuring the macOS App Sandbox: https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox
- Persistent Content Capture entitlement (request form linked from the page): https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture
- DTS threads: Accessibility in sandboxed app https://developer.apple.com/forums/thread/707680 ; keys from a sandboxed app https://developer.apple.com/forums/thread/708652 ; Guideline 2.4.5 rejection for `CGEvent.post` https://developer.apple.com/forums/thread/820594 ; screen-capture entitlement https://developer.apple.com/forums/thread/778616
- Sparkle 2.10.0 release (13 Sep 2026): https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0 ; documentation https://sparkle-project.org/documentation/
- Sequoia re-prompt and entitlement discussion (secondary): https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/ , https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/
- Astropad Workbench product page and download: https://astropad.com/product/workbench/
- Jump Desktop Connect docs: https://docs.jumpdesktop.com/connect/install/ , https://docs.jumpdesktop.com/connect/macos-permissions/
- Screens release notes: https://help.edovia.com/en/screens-5/faq/release-notes ; listing https://apps.apple.com/us/app/screens-5-vnc-remote-desktop/id1663047912
- Remote Mac Desktop Control listing: https://apps.apple.com/us/app/remote-mac-desktop-control/id6790186904
- Repo: `project.yml`, `RemoteHost/*.swift` as cited, `Docs/MAC-PERMISSION-IDENTITY.md`, `script/build_and_run.sh`
