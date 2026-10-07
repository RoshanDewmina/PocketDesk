# Apple platform opportunities for Farside

30 September 2026. Advisory research only. No code changes, builds, commits or browsers on the Mac.

**Method.** Six Sonnet research lanes, then one Opus synthesis. The lanes covered video, input, networking, phone system surfaces, the Mac companion, and security/commerce/review. They used primary Apple sources: developer.apple.com docs (often the `tutorials/data/documentation/…json` form), WWDC25/26 session pages, the iOS/macOS 27 release notes, and **installed Xcode 27.0 (27A266a) SDK headers and `.swiftinterface` files**, which were the main availability evidence. The apple-docs MCP was down.

Each lane was told to dedupe against:
- PRODUCT.md
- the 77-item Codex ranking
- the 29 Sep Accessibility review
- APPLE-API-REFERENCE.md
- REMOTE-UNLOCK-AND-FILE-TRANSFER.md
- EFFICIENCY-AUDIT-2026-09-30.md (branch `farside-efficiency-audit`)
- SYSTEM-INTEGRATIONS.md
- APP-REVIEW-RISKS.md
- the in-progress list (Connection Health, Resume Capsule, Connect widget, motion redesign, file transfer and Send to Mac, keyboard-aware focused field, Precision Tap, drag auto-pan, Smooth motion, efficiency)

**Evidence tags:**
- **[V]** re-verified by the synthesiser today against the SDK header, repo source or Apple page.
- **[D]** confirmed by a lane from an Apple doc or SDK header.
- **[3P]** press or community source only.
- **[I]** inference; needs a test.

"Upgrade" means an Apple-API improvement to something that already exists or is in progress, not a new catalog item.

---

## 1. Review and launch blockers

None of these is a new *feature*. Each one can stop submission or break the paid promise in week one.

| # | Blocker | Evidence | What must be true before 2026-11-03 |
|---|---|---|---|
| R1 | **Multiseat purchases are now ON by default** for subscriptions. Apple: "Starting today, multiseat purchases are enabled by default". | [V] [news, 16 Sep 2026 "Get your subscriptions ready for iOS 27"](https://developer.apple.com/news/?id=likeohx4); [ASC purchase options](https://developer.apple.com/help/app-store-connect/manage-subscriptions/manage-purchase-options-for-auto-renewable-subscriptions). SDK has `Transaction.OwnershipType.assigned` (iOS 26.4, back-deployed) [D]. `SUBSCRIPTION-SETUP.md:59` already says "turn off" [V], but `Backend/src` has no ownership-type handling [V]. | Set "don't allow multiseat" on the Anywhere product **before it goes live**. Disabling it later cancels group subscriptions at renewal [D]. Backend logs/denies any transaction whose ownership isn't `PURCHASED` (or `FAMILY_SHARED` if ever enabled). |
| R2 | **Persistent Content Capture request is still unfiled.** macOS keeps the recurring "still capturing your screen" re-consent for ScreenCaptureKit apps [3P, 9to5Mac/MacRumors]. The macOS 27 headers add no opt-out [D]. The only documented escape is `com.apple.developer.persistent-content-capture`, "for VNC apps" [D]. Without it, an unattended paid "Anywhere" Mac can silently stop capturing. | [V] `Docs/launch/APPLE-PORTAL-SETUP-2026-09-28.md:12` "Status: NOT submitted"; APP-REVIEW-RISKS B14 due 2 Oct. [Entitlement doc](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture); [request form](https://developer.apple.com/contact/request/persistent-content-capture/). | File it now (owner task). Whether it removes the prompt is **unproven** [I]. Ship O2 (below) regardless, so a stopped capture reads as "Approve on your Mac", not a dead connection. Don't promise unattended reliability in launch copy. |
| R3 | **Texas SB 2420 age assurance.** New Texas Apple Accounts are covered since early June. Apple points developers to Declared Age Range, the PermissionKit Significant Change API and a consent-revocation server notification. It adds: "it's the developer's responsibility to determine when there's a significant change". | [V] [news, 3 Jun 2026](https://developer.apple.com/news/?id=sg176nne). The notification type name `RESCIND_CONSENT` is lane-reported [D], not in the post text I fetched. Nothing in the repo mentions it [D]. | Write down a decision. Cheapest defensible path: check `AgeRangeService.requiredRegulatoryFeatures` (iOS 26.4) and treat consent revocation as an entitlement stop in `notifications.ts`. Or record counsel's view that it is out of scope. Needs an entitlement plus a privacy-label update if adopted. |
| R4 | **Push/Live Activity content (4.5.4; 4.5.3 clarified 8 Jun 2026 to name Live Activities).** APP-REVIEW-RISKS still marks 4.5.4 "Not implemented", which is stale. `AgentAlertPayload.swift` passes an agent product name in `title-loc-args` [D]. | [Guidelines](https://developer.apple.com/app-store/review/guidelines/) "Last Updated: June 8, 2026", re-fetched today [D] | Generic payloads only ("A task on your Mac needs attention"); details load in-app over the session; opt-out in the app. Naming third-party products in alerts also nudges toward 4.2.7 "specific software" and 5.2 trademark; drop it for 1.0. |
| R5 | **App Store Connect gates:** updated agreements (EU Attachment 14, effective 1 Oct 2026) and the full age-rating questionnaire including the 2026 questions. | [D] [news](https://developer.apple.com/news/?id=0cgo95n6); [upcoming requirements](https://developer.apple.com/news/upcoming-requirements/) (age-rating deadline 31 Jan 2026 already passed [V]) | Account holder accepts all agreements; complete the questionnaire (answer "No" to social features). Add both to LAUNCH-CHECKLIST. |
| R6 | **OS-27-only symbols in a 26+ app.** Several items below exist only in the 27 SDK: `ConstantQualityFactor`, the `SCClipBufferingOutput` APIs, `SCContentSharingPicker.isAvailable`, the interpolation scale queries, `grammarCheckingType`, `allowedExecutionTargets`, and the new offer-code API. | [V] header `API_AVAILABLE(macos(27.0), ios(27.0))` on each | `#available` guards. An unguarded call crashes on 26, and a crash is a 2.1 rejection. |

**4.2.7 still holds.** The text is unchanged since 8 June 2026 and clause (e) is intact [D]. The APP-REVIEW-RISKS analysis stands: Farside is a generic host mirror, so the LAN-only clause (a) does not apply. Keep it that way:
- no named third-party apps in metadata or alerts;
- no app launchers;
- any Mac-menu mirroring (O14) must stay generic across all apps.

**Checked, not blockers:**
- Privacy manifests: WebRTC is not on Apple's signed-SDK list. If file transfer reads file timestamps, add required-reason `C617.1` to both app manifests [D].
- Accessibility Nutrition Labels: still voluntary [D].
- US link-out: permitted without an entitlement, but the commission is unresolved, so don't build web checkout [D].

---

## 2. Top 8

Ranked by user value × feasibility. The ranking favours 1.0-safe, S-effort upgrades to things already on the critical path.

| Rank | Opportunity | Tier | Effort | Why it's here |
|---|---|---|---|---|
| 1 | **O2 · Capture-stopped / approval-pending state** (with R2 filing) | 1.0 | S | Turns the biggest reliability hole in paid Anywhere into an actionable message. Feeds Connection Health. |
| 2 | **O1 · Local Network prompt priming** for the free-tier LAN proof | 1.0 | S | The free tier's first run can silently fail if the prompt fires in the background. |
| 3 | **O3 · Colour-correct stream** (pin SCK colour space and matrix) | 1.0 | S | Likely hue/saturation error on every frame today. A two-line host fix, verified with a colour chart. |
| 4 | **O4 · Exact Text trait hardening** | 1.0 | S | Smart quotes, dashes, prediction, Writing Tools and grammar checks can silently corrupt code. That defeats the coder use case. |
| 5 | **O5 · Secure-field awareness** | 1.0 | S | sudo/password prompts get a lock state, and no draft is persisted. Rides on the in-progress focused-field probe. |
| 6 | **O6 · Link quality into Connection Health** | 1.0 | S | "Weak Wi-Fi" before frames stall, from a new iOS/macOS 26 `NWPath` property. |
| 7 | **O7 · Native momentum scroll injection** | 1.0 stretch / 1.1 | M | The phone already validates a `"momentum"` phase, and the host silently drops it. Native inertia is core to D22. |
| 8 | **O8 · Face ID gate before connecting** (opt-in) | 1.0 stretch / 1.1 | S | Closes the documented "unlocked paired phone" gap cheaply. A strong trust story for a tool that controls your Mac. |

### O1 · Local Network privacy priming — 1.0, S
- **API:** `NSLocalNetworkUsageDescription`, [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) [D].
- **OS:** iOS 14+; macOS 15+.
- **Benefit:** The `LocalLinkProof` UDP probe and ICE host candidates are local-network operations. TN3179 says an undetermined operation from the background is **silently denied**, and the prompt appears on the next foreground attempt [D]. The fix: prime with an explanation screen before the first probe, and never probe while backgrounded. Then the free tier works on first use.
- **Repo:** all four targets already carry the usage string [D].
- **Risks:** none. QA only.
- **Verification:** doc confirmed [D]; flow is [I].

### O2 · Capture-stopped / approval-pending state — 1.0, S (upgrade to the permission center and Connection Health)
- **API:**
  - `SCStreamErrorSystemStoppedStream` (-3821, macOS 15+) and `SCStreamErrorUserDeclined` (-3801) in `ScreenCaptureKit/SCError.h` [D].
  - `SCContentSharingPicker.isAvailable` ("supported and allowed on this device", macOS 27, `SCContentSharingPicker.h:101`) [V].
  - `SCStream.isCapturing` (macOS 27) [D].
- **Benefit:** When the system stops capture or re-consent is pending, the menu bar and phone say "Approve screen recording on your Mac" instead of a generic failure.
- **Risks:** none. That -3821 is what the recurring prompt raises is [I]; test by revoking the grant in System Settings.
- **Pair with R2.**

### O3 · Colour-correct stream — 1.0, S
- **API:** `SCStreamConfiguration.colorSpaceName` and `.colorMatrix` (`SCStream.h:304/310`, macOS 12.3+) [V]. The header says that when `colorSpaceName` is unset, the output uses the display's own colour space [V].
- **Finding:**
  - `RemoteCapture.swift:496` sets 420v but neither property [V]. (The older `PocketDesktopHost/HostStream.swift:48` does set sRGB.)
  - The shipped WebRTC NV12 Metal shader hard-codes BT.601 coefficients, per `strings` on the binary [D, lane 1].
  - So a BT.709/Display-P3 source is probably shown with the wrong matrix and gamut [I].
- **Benefit:** Syntax highlighting and UI colours match the Mac.
- **Risks:** Encoder VUI tags and the browser client change too. Verify host vs phone with a colour chart before and after.

### O4 · Exact Text trait hardening — 1.0, S (upgrade to Exact Text #26)
- **API:** `UITextInputTraits`: `smartQuotesType`, `smartDashesType`, `smartInsertDeleteType`, `spellCheckingType`, `inlinePredictionType` (iOS 17), `writingToolsBehavior` (iOS 18, `:282`), `grammarCheckingType` (**iOS 27**, `:264`) [V].
- **Finding:** `RemotePhone/CommittedTextField.swift` sets only `autocorrectionType = .no` [V].
- **Benefit:** No curly quotes in shell commands, no em-dashes in `--flags`, no predictive insertions in paths.
- **Risks:** Keep smart typing in prose mode. Gate `grammarCheckingType` on iOS 27.

### O5 · Secure-field awareness — 1.0, S (upgrade to the in-progress keyboard-aware focused field)
- **API:** `kAXSecureTextFieldSubrole` (`AXRoleConstants.h:408`) [V]; Carbon `IsSecureEventInputEnabled` (exported in the SDK; header not located) [D].
- **Finding:** `HostTextFocusProbe` treats any `AXTextField` as editable, and nothing reads the secure subrole [V].
- **Benefit:** The phone shows "Password field" and stops persisting or echoing drafts (Outbox, Resume Capsule). It can warn when Terminal's Secure Keyboard Entry is on.
- **Risks:** metadata only, no new TCC. Whether secure input drops synthetic keys is [I]; test on device.

### O6 · Link quality into Connection Health — 1.0, S (upgrade to `NetworkPathWatcher`)
- **API:** `NWPath.linkQuality` (`unknown/minimal/moderate/good`) and `isUltraConstrained`, iOS/macOS 26 (`Network.swiftinterface:841/855`) [V]. [NWPath docs](https://developer.apple.com/documentation/network/nwpath).
- **Finding:** `RemoteShared/NetworkPathWatcher.swift` reads `isExpensive`/`isConstrained` but not these [D].
- **Benefit:** A "Weak Wi-Fi" or "Satellite link" state and an early bitrate cap, before stalls.
- **Risks:** Coarse and undocumented semantics, so treat it as a hint, never a gate.

### O7 · Native momentum scroll — 1.0 stretch / 1.1, M (upgrade to two-finger scroll)
- **API:** `CGMomentumScrollPhase` and `kCGScrollWheelEventMomentumPhase = 123` (`CGEventTypes.h:52–56, 242`) [V].
- **Finding:**
  - `RemoteShared/NativeInteraction.swift:18` accepts `"momentum"`.
  - `RemoteHost/RemoteInputDriver.swift:150–157` maps it to 0 and posts no phase [V].
- **Benefit:** Xcode, Safari and Terminal get real inertia and rubber-banding instead of a dead stop or phone-synthesised deltas.
- **Risks:** Cancel momentum on new touch, stale state and disconnect. Per-app handling of synthetic momentum is [I].

### O8 · Biometric gate before a session — 1.0 stretch / 1.1, S
- **API:** `LAContext` / `LARight` (iOS 16+) [D]. [LocalAuthentication](https://developer.apple.com/documentation/localauthentication).
- **Benefit:** Optional "Require Face ID to connect / to Forget this Mac". A borrowed unlocked phone can't take over the Mac. That scenario is currently listed as out of scope.
- **Risks:** Needs a passcode fallback. Don't re-prompt on view rebuilds mid-session. Default off.

---

## 3. Everything else, by tier

Deduped against the catalog and the in-progress work. "Cat #n" is the Codex 77-item ranking.

### 1.0 (small, safe, if capacity allows)

| Item | API (source) | Benefit | Effort / risk |
|---|---|---|---|
| O9 · Hidden-menu-bar guard | `MenuBarExtra(isInserted:)` ([doc](https://developer.apple.com/documentation/swiftui/menubarextra), swiftinterface `:2093`) [V] | Apple terminates a menu-bar-*only* app when its extra is removed [V]. Farside also has Setup and Settings scenes (`RemoteHostApp.swift:27/35`) [V], so it probably survives [I], but the user loses the way back. Bind `isInserted` and reopen Settings on relaunch. | S / none. Test on 26 and 27. |
| O10 · PostEvent as the "can control" truth | `CGPreflightPostEventAccess` / `CGRequestPostEventAccess` (`CGEvent.h:405–408`) [D] | Pairs with efficiency proposal P3: a cheap cached check instead of `AXIsProcessTrusted` per event. Never ask for Input Monitoring. | S / low |
| O11 · Notification settings deep link | `UNAuthorizationOptions.providesAppNotificationSettings` ([doc](https://developer.apple.com/documentation/usernotifications/unauthorizationoptions/providesappnotificationsettings)) [D] | "Farside notification settings" in iOS Settings opens Agent alerts with Send test alert. 0 repo hits [V]. | S / none |
| O12 · iPad mouse back/forward | `GCMouseInput.auxiliaryButtons` (`GCMouseInput.h:46`) [D] | Mouse buttons 4/5 become browser/Finder/Xcode back and forward. Only `middleButton` is wired today (`HardwareInput.swift:223`) [D]. | S / none |
| O13 · Shortcuts recipes for agent alerts | Shortcuts **Notification automation** ([WWDC26 "What's new in Shortcuts"](https://developer.apple.com/videos/play/wwdc2026/310/)) [V] | "When Farside says a task needs me → set Focus / flash lights" with no server work. Docs and website only. | S. Keep alert titles stable. The transcript says "In iOS 26" while a lane cited iOS 27 press, so confirm on device. |

### 1.1

| Item | API (source) | Benefit | Effort / risk |
|---|---|---|---|
| O14 · Mac menus in the iPad menu bar | `UIMenuBuilder` + `UIDeferredMenuElement`, iPadOS 26 `providerForDeferredMenuElement:` (`UIResponder.h:135`); Mac `kAXMenuBarAttribute`, `kAXMenuItemCmdCharAttribute`, AXPress [D] | Reach any app's commands with real shortcut glyphs. On iPhone, a searchable sheet. Overlaps cat #21/#29. | L. AX traversal timeouts; menu titles are content (opt-in). Must stay generic for 4.2.7. |
| O15 · iPad pointer lock with raw deltas | `prefersPointerLocked` (`UIViewController.h:703`) [V] + `GCMouseInput.mouseMovedHandler` [D] | A Magic Keyboard trackpad drives the Mac pointer past the screen edge with no double acceleration. Falls back to hover when the lock is denied. | M. Denied in Split View/windowed [I]. Never mix deltas and hover. |
| O16 · Apple Pencil squeeze/tap = click or Precision Tap | `UIPencilInteraction` squeeze/tap and `UIPencilHoverPose` (iOS 17.5+, `UIPencilInteraction.h:95–182`) [D] | Stylus-native precise clicks. Pencil hover currently dropped (`zOffset != 0`) [D]. | M. Honour `preferredSqueezeAction`; hardware-dependent. |
| O17 · 2x spatial scale in Smooth motion | `VTLowLatencyFrameInterpolationConfiguration …spatialScaleFactor:` (26); max-dimension queries **27** (`…FrameInterpolation.h:113/121`) [V]; macOS 27 notes say interpolation up to 1080p, super-res adds 1.5x [D] | Encode ~1080p on the Mac, upscale 2x plus interpolate on the phone. 120 Hz output at about half the encode, network and battery cost [I]. | M, phone-only. Glyph distortion must pass the legibility harness. Model-load latency. Conflicts with full-res reading mode. |
| O18 · Settle-sharpen on static frames | `kVTCompressionPropertyKey_ConstantQualityFactor` + `kVTCompressionPreset_ConsistentQuality` (**macOS 27**, `VTCompressionProperties.h:1602/1675`) [V] | Idle re-push frames jump to high quality, so text "settles" crisp. Upgrade to efficiency P5/P7. Free probe: read `SupportedPresetDictionaries`. | M once a custom `VTCompressionSession` wrapper exists, L alone. Hardware H.264 support is [I]. |
| O19 · `AVSampleBufferDisplayLayer` renderer A/B | AVSampleBufferDisplayLayer / VideoRenderer; iOS 27 enqueue-result model [D] | The system compositor honours colour tags and may cost less power than the Metal draw loop. | M. A frame of latency either way [I]; rework the 120 Hz probe. Do it before any custom Metal/MetalFX renderer. |
| O20 · Region OCR on modern Vision + Live Text | `RecognizeTextRequest` (15/18+) with `customWords`, `RecognizeDocumentsRequest` (26+), VisionKit `ImageAnalysisInteraction` [D] | Upgrade to cat #32: select, copy and Look Up on a frozen frame, on-device. Also migrate `LegibilityScore`'s legacy `VNRecognizeTextRequest`. | M. Code punctuation is unreliable, so verify before paste. |
| O21 · Background completion for Send to Mac | `BGContinuedProcessingTask` (iOS 26, `BGTask.h:127`) [D] | A user-started transfer finishes after the app is backgrounded, with a system progress UI. **Pull into 1.0 if phone→Mac transfer ships in 1.0.** | M. Finite, user-initiated work only; never for the live stream. |
| O22 · Interactive Mac-status card | `SnippetIntent` / `ShowsSnippetView` (26+) [D] | Siri/Spotlight "Is my Mac awake?" returns a card with Connect (later Keep awake). Upgrade to `MacStatusIntent`. | S–M. `perform()` must be idempotent and fast. |
| O23 · Pause-agent-alerts control | `ControlWidgetToggle` + `SetValueIntent` + `ControlPushHandler` [D] | Control Center / Lock Screen / Action button "Pause alerts 1h". A system surface for planned N3. | S after C1. State server-side; show pending/failed. |
| O24 · Pin intent execution target | `AppIntent.allowedExecutionTargets` (**iOS 27**, `AppIntents.swiftinterface:3112/3571`) [D] | Status/End/mute intents run in the main app, which holds pairing state, not in an extension. | S. iOS 27 gate. |
| O25 · Mac-side App Intents / Spotlight actions | App Intents on macOS 26 ([WWDC25 260](https://developer.apple.com/videos/play/wwdc2025/260/)) [D/3P] | "Start sharing", "Curtain on", "Keep awake", and "Notify my iPhone" from Shortcuts, Raycast or Keyboard Maestro via the `farside-notify` bridge. | S–M. Fixed localized keys only (4.5.4). Never expose unlock/wake. LSUIElement hosting is [I]. |
| O26 · Mac Control Center toggle | `ControlWidget` (macOS 26, WidgetKit swiftinterface `:910`) [D] | Sharing on/off or curtain without opening the popover. | M. Needs a widget extension, IPC and notarized extension signing. |
| O27 · App Attest on relay credentials | `DCAppAttestService` (iOS 14+) [D] | Binds the Anywhere token to a genuine install. Stops relay abuse from forged clients or shared JWS. | M. Needs the entitlement and Worker validation; degrade gracefully. Unsupported for iOS apps on Mac [D]. |
| O28 · Private event source | `CGEventSource(.privateState)`, `CGEventSourceSetLocalEventsSuppressionInterval` (`CGEventSource.h`) [D] | Injected modifiers stop mixing with a physical keyboard. Less fighting with a local mouse. Today every event uses `source: nil` [D]. | S–M. `RemoteInputTag` must still work; test. |
| O29 · Offer codes on the new API; win-back offers | `offerCodeRedemption(options:…)` (**iOS 27**; old overload deprecated) [D]; `SubscriptionInfo.winBackOffers` (iOS 18+) [D] | A redeemed code returns a verified transaction immediately. `AnywherePaywallView.swift:63` discards the result [D]. Win-back is mostly ASC config for lapsed trials. | S each. Gate on iOS 27. |
| O30 · Route pre-check hints | `NWPath.usesInterfaceType`, `gateways` [V/D] | "Your phone is on cellular / a VPN, so free local mode isn't available" before probing. UX only; `route.1` stays the authority. | S. Never grant free tier from path type. |

### Later

| Item | API | Note |
|---|---|---|
| O31 · "Rewind 15 s" clip | `SCClipBufferingOutput` `exportClipToURL:duration:` (**macOS 27 only**) [V] | "What just scrolled by?" for build logs. Opt-in, continuous encode cost, new privacy disclosure. |
| O32 · LTR loss recovery | `kVTCompressionPropertyKey_EnableLTR` + acked tokens [D] | Faster recovery than full IDRs on relay. L: custom encoder, decoder awareness and an ack channel; hardware support [I]. |
| O33 · On-device "what does it need?" summary | Foundation Models `LanguageModelSession` + image `Attachment` (iOS/macOS 27) [D] | Summarise the screen behind an agent alert, rendered as inert text. Docs conflict on on-device vision support, so spike `capabilities.contains(.vision)`. Prompt-injection risk; never let output pick an action. |
| O34 · Handoff back to Mac (cat #49) | `NSUserActivity` [D] | Whether a Developer-ID Mac app receives Handoff from the same-team iOS app is unverified; hardware test first. |
| O35 · Hybrid PQ + Secure Enclave device keys | CryptoKit `SecureEnclave.MLDSA65/MLKEM768`, X-Wing HPKE (iOS/macOS 26) [D] | Device-bound pairing and PQ-sealed signaling. Video DTLS-SRTP stays classical. Needs protocol versioning. |
| O36 · Retention Messaging | [Retention Messaging API](https://developer.apple.com/documentation/retentionmessaging) (pre-release) [D] | Tailored cancel-screen message. Don't depend on it for launch. |
| O37 · Custom Metal renderer + MetalFX zoom | `CAMetalDisplayLink`, `MTLFXSpatialScaler` [D] | Pointer and video in one vsync-paced pass, sharper >1:1 zoom. L, you own colour. Only after O19. |
| O38 · Team seats | Group/Volume Purchasing (iOS 27) [D] | Contradicts the solo licence (cat #41); revisit only with demand. |

---

## 4. Dead ends (checked, no path)

- **Public virtual display.** No public API in the macOS 27 SDK. CGVirtualDisplay stays private (Debug spike only) [D].
- **ROI / region-QP encoding.** No such VT key [D].
- **HDR/EDR streaming.** No value for text, and the phone path can't present it [D].
- **`captureResolution .nominal`.** Blurrier than the explicit sizes already set [D].
- **Other VTFrameProcessor effects** (motion blur, noise filter, optical flow) **and MetalFX temporal/interpolator.** Video/game-oriented [D].
- **Wi-Fi Aware to the Mac.** Every symbol is `@available(macOS, unavailable)` in the macOS 27 SDK [D].
- **Multipath for media.** libwebrtc owns its sockets, and the entitlement is iOS-only [D].
- **NEHotspotNetwork SSID labels.** A location prompt for a label; spoofable [D].
- **CoreHID `HIDVirtualDevice`.** A true trackpad HID, but a restricted entitlement [D].
- **Camera Control / volume buttons as input.** Capture-only, a review risk [D].
- **GCController as Mac input.** No value for coders.
- **AlarmKit to bypass Focus.** Misuse; local-only [D].
- **Private Cloud Compute model.** Managed entitlement, and it would send screen content off-device [D].
- **Passkeys for pairing.** Farside has no accounts [D].
- **Advanced Commerce, Bundles/Suites, 12-month-commitment billing.** Not applicable [D].
- **Apple-native updater for Developer ID.** None; keep Sparkle [D/3P].
- **Endpoint Security; Stage Manager/Spaces control APIs.** Not relevant, or none public [D].
- **Reading TCC.db.** Removed in macOS 27 [D].
- **Live Activity on the controlled Mac.** Already covered in SYSTEM-INTEGRATIONS §5.3 [V].

---

## 5. Corrections to existing docs

- **SYSTEM-INTEGRATIONS §3.3:**
  - iOS 27 known issue 166068090: `Duration`-based shortcuts can fail. Keep the `AppEnum` for keep-awake [D].
  - §2.1: transient Live Activities are local-start only, with no push key [D].
  - §3.1/§5: "App Shortcuts unsupported on macOS" is too absolute. `AppShortcutsProvider` is declared for macOS, and Spotlight actions run App Intents on 26 [D/3P].
  - Foundation Models is not covered at all.
- **APP-REVIEW-RISKS:**
  - Row 4.5.4 "Not implemented" is stale (push and Live Activities exist).
  - Add R1 (multiseat default, 16 Sep 2026), R3 (Texas) and R5 (agreements/age rating).
  - B14 remains open.
- **Efficiency audit P3:** use `CGPreflightPostEventAccess` (O10) as the cached check.

## 6. Caveats

- Lane 1 took symbol URLs from Apple's naming convention without fetching most of them. Availability rests on the installed headers, which were re-checked for the items marked [V].
- Lane 3 did not read WWDC session transcripts. Its findings rest on SDK interfaces and TN3179.
- Some Apple pages came through a summarising fetcher. Quotes marked [V] were re-fetched by the synthesiser today.
- Nothing here was run on a device. Every "benefit" is a hypothesis until measured. That matters most for O3 (colour), O7 (momentum), O17 (upscaling), O18 (settle-sharpen) and O19 (renderer).
