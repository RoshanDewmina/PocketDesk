# Phone-side and agent gaps versus Astropad Workbench (round 2)

Checked 28 September 2026 (all fetches dated the same day). Research only: no product code and no existing file was modified. [PRODUCT.md](../../../PRODUCT.md) remains the scope authority; this file feeds it, it does not compete with it.

**Evidence labels.** **[Apple]** primary Apple documentation, read from developer.apple.com (rendered JSON of the docs pages, because the pages themselves are JS-rendered). **[Vendor]** primary page of Astropad, Anthropic, OpenAI or the MCP project. **[Repo]** PocketDesk source or docs read locally. **[3P]** third-party article, forum thread or open-source issue: lower confidence, cited for datapoints only. **[Inference]** my conclusion from the above. **[Unverified]** needs a device or account test before anyone relies on it.

**Known evidence limits.** Reddit is blocked to the crawler in this environment, so no Reddit evidence exists here; user sentiment below comes from the public App Store customer-review feed (US storefront, 24 reviews, versions 1.0.1 to 1.3), MacStories, and vendor/press pages. Nothing about Workbench was hands-on tested. Workbench's PiP implementation is not publicly documented. Small-model page summaries were cross-checked against raw Apple/Anthropic markdown wherever a spec detail below depends on them.

---

## 0. Bottom line

### 0.1 Decisions

| # | Gap | Recommendation | 17 Nov launch | Effort (engineer-days, planning range) |
|---|---|---|---|---|
| 1a | Multitasking survival (background grace + instant resume) | Add first; connection drops when leaving the app are a leading Workbench complaint (section 4) and far cheaper to fix than PiP | **GO** | 3-5 |
| 1b | Picture-in-Picture of the live Mac | AVSampleBufferDisplayLayer content source, view-only, user-initiated. Keep-alive and App Review are unproven for a no-audio, non-call app; gate on a 3-day device spike | **NO-GO unless spike passes by 12 Oct**; otherwise 1.1 (Dec) | 4-7 (+3 spike); +5-10 if Mac audio forwarding is used as the legitimate reason for the `audio` background mode |
| 2a | iPad live-resize layout, Stage Manager, hardware keyboard/pointer passthrough | Standard UIKit paths; several documented platform limits (section 2) | **GO** (subset) | 8-12 |
| 2b | iPad mini map | Small; parity item | **GO if time** | 3-4 |
| 2c | Scribble and Pencil | Scribble into the existing local draft field is free; verify only. Indirect Scribble over remote fields and Pencil pressure are later | **GO (verify)** / later | 1 / 8-15 |
| 2d | Middle click, shortcut remap | Middle click only via `GCMouse`; remap mirrors Workbench | stretch | 3-5 |
| 2e | iPhone Duo / foldables | Build with Xcode 27.1 and stay size-class based; no custom fold UI | **GO (no-break only)** | 2-3 |
| 3a | "Agent needs you" alert to phone (APNs) | Server-side APNs, generic notification text, deep link straight into the app | **GO, conditional beta** | see section 5 |
| 3b | Open Mac from a Claude/ChatGPT chat | Universal link in tool result plus web fallback; no embedded viewer yet | **GO (link only)** | 3-5 |
| 3c | Take over and hand back | Agent-initiated `request_human_help` plus PreToolUse gate hook for Claude Code/Cowork/Codex; best-effort, never advertised as guaranteed | **GO, conditional beta** | see section 5 |
| 3d | Embedded live viewer (MCP App) in Claude; ChatGPT | Spike only | **NO-GO** | 8-15 later |
| 3e | Live Activity / Dynamic Island | Fits HIG rules; extra extension target and review surface | **1.1** | 8-12 |

Conditional GO for 3a and 3c means: public HTTPS endpoint live by about 19 Oct, APNs auth key and Associated Domains capability provisioned by about 12 Oct (both are human steps in the Apple Developer portal), and the P0 engine/relay work is not starved. Cut order if time runs out: Codex hook, chat link, Live Activity, then everything except push plus open-app plus view/take over.

### 0.2 Seven findings that change earlier assumptions

1. **First-party phone monitoring for agents already exists, so an alert alone is not a moat.** Claude Code has Remote Control from the Claude iOS app with push when "actions required" (introduced in v2.1.110, April 2026, per community write-ups; the docs page shows the two `/config` toggles), Dispatch, and Channels; OpenAI shipped Codex control inside the ChatGPT mobile apps on 14 May 2026 (approve commands, review diffs, screenshots). PocketDesk's defensible wedge is **the part vendors' text-level apps cannot do: the blocker is a GUI on the Mac** (a native macOS dialog, a login, a browser step, a visual check), across vendors, with take-over and hand-back. See section 3.1.
2. **Workbench's "monitor agents" is positioning, not a feature.** Vendor and press pages describe remote desktop plus dictation, a headless-Mac virtual display, PiP and an app watchdog. No push notification, agent detection or agent integration is documented anywhere I could read. See 3.8.
3. **PiP is public API but not "just an API".** Apple documents the audio background-mode requirement; whether the app keeps running (WebRTC receive and decode) while PiP shows, without real audio, is not documented by Apple. Community evidence conflicts (Moonlight died in PiP; a Mac-display receiver reports streaming continued with audio mode on). See section 1.
4. **App Review guideline 4.2.7 (remote desktop clients) is a live constraint to design around.** As updated 8 June 2026 it restricts apps that mirror *specific software or services* to LAN connections and "APIs or platform features beyond what is required to stream." PocketDesk is a generic mirror of the host, so it should not apply, but agent-branded marketing could invite the argument. Workbench shipped PiP (1.3, 19 Aug 2026), which is precedent, not permission. See 1.4.
5. **The repo's MCP backend is further from an embedded viewer than the docs imply.** The MCP app is mounted by `Server/src/browser/service.ts` when an exact origin and `POCKETDESK_MCP_PRIVATE_DIR` are configured (the doc statement that `server.ts` has no MCP route is true of the native signaling server only). But no tool declares `_meta.ui.resourceUri`, the viewer resource is a placeholder string, no `ui.domain` is set, there is no push, no AASA file, and no tool for the agent to ask for help. See 3.2.
6. **A held MCP tool call is not a reliable pause in Claude Code.** Since v2.1.212 a main-conversation MCP call still running after two minutes is moved to a background task and Claude "keeps working." The dependable enforcement point is a `PreToolUse` hook, which also has a documented fail-open on timeout. See 3.7.
7. **Workbench users validate two PocketDesk differentiators and one must-fix.** Three of 24 sampled App Store reviews complain about sign-in or email-verification churn (no account is a win); two ask for a trackpad-style cursor mode (relative trackpad is a win); the clearest 2-star review says the connection drops when they leave the app for 15 seconds (must fix; Workbench answered with PiP in 1.3). Connection/stability (5 of 24) and keyboard/shortcut defects (4 of 24) are the largest complaint groups. See section 4.

---

## 1. Picture-in-Picture of the live Mac (gap 1)

### 1.1 What the public APIs are

| Need | API (all public) | Availability | Source |
|---|---|---|---|
| PiP for custom-pipeline video | `AVPictureInPictureController(contentSource:)` with `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)` | iOS/iPadOS 15.0+ | [Apple ContentSource](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class) |
| Playback controls and live semantics | `AVPictureInPictureSampleBufferPlaybackDelegate`: `setPlaying(_:)`, `pictureInPictureControllerTimeRangeForPlayback(_:)`, `pictureInPictureControllerIsPlaybackPaused(_:)`, `didTransitionToRenderSize`, `skipByInterval`, optional `shouldProhibitBackgroundAudioPlayback` | 15.0+ | [Apple delegate](https://developer.apple.com/documentation/avkit/avpictureinpicturesamplebufferplaybackdelegate) |
| Live content | return `CMTimeRange` with `duration: .positiveInfinity` | 15.0+ | [Apple timeRange](https://developer.apple.com/documentation/avkit/avpictureinpicturesamplebufferplaybackdelegate/pictureinpicturecontrollertimerangeforplayback(_:)) |
| Auto-start on backgrounding | `canStartPictureInPictureAutomaticallyFromInline`; Apple: set true only for the user's primary-focus content | 14.2+ | [Apple](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/canstartpictureinpictureautomaticallyfrominline) |
| Support and state | `isPictureInPictureSupported()`, `isPictureInPicturePossible` (false while FaceTime PiP is up), `isPictureInPictureActive`, `startPictureInPicture()` | iOS 9+ | [Apple controller](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller) |
| Call-style variant | `ContentSource(activeVideoCallSourceView:contentViewController:)` with `AVPictureInPictureVideoCallViewController`; iOS 18+ also allows an `MTKView` source; the PiP window does **not** receive touch events | 15.0+ | [Apple video calls](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls) |
| Background audio requirement | Background Modes "Audio, AirPlay, and Picture in Picture" plus `AVAudioSession` `.playback` | n/a | [Apple media playback](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback), [controller overview](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller) |
| WWDC context | AVSampleBufferDisplayLayer PiP with ContentSource; infinite time range means live | 2021 | [WWDC21 10290](https://developer.apple.com/videos/play/wwdc2021/10290/) |

**Repo fit [Repo].** The phone renders through `RTCMTLVideoView` (`RemoteVideoSurface`, `RemotePhone/RemotePhoneApp.swift`) fed by WebRTC 153.0.0 (`stasel/WebRTC`). `RTCVideoFrame` exposes `buffer`, `rotation`, `timeStampNs`; `RTCCVPixelBuffer` (with `pixelBuffer` and crop fields, confirmed in the framework headers in the repo's build products) is the buffer type WebRTC's VideoToolbox decoder normally delivers **[Inference; confirm in the spike]**. So a second `RTCVideoRenderer` that wraps each `CVPixelBuffer` into a `CMSampleBuffer` and enqueues it on an `AVSampleBufferDisplayLayer` is a small additive piece; nothing in the receive path changes.

### 1.2 Rules and hard limits

- **Only start PiP from a user action** (button), "never programmatically"; Apple's custom-player guide says App Review rejects apps that do not follow this. Auto-start when leaving the app is the documented exception via `canStartPictureInPictureAutomaticallyFromInline`, for primary-focus content. **[Apple](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player)** Recommendation: a visible PiP button plus an opt-in setting "Keep my Mac visible when I leave the app".
- **Interaction limits.** With the sample-buffer source the PiP window offers only system controls: play/pause, close, and restore-to-app; skip buttons are governed by `requiresLinearPlayback`, so set it to true (exact PiP chrome for an infinite-duration live range is **[Unverified]**, check on device). No touch pass-through to the Mac is possible; with the call variant the window "doesn't receive touch events." So PiP is **view-only**; control resumes after restore. [Apple]
- **Camera/audio.** We use neither camera nor mic in PiP, so the multitasking-camera entitlement is irrelevant. [Apple]
- **Hold a strong reference** to the controller and implement `restoreUserInterfaceForPictureInPictureStop` (Apple sample pattern). [Apple]
- **No GPU work in the background.** `RTCMTLVideoView` (Metal) must not be the thing drawing while PiP is the only visible surface; the PiP layer is composited by the system. [3P: iOSSH #39 quotes the same constraint] [Inference]

### 1.3 Keeping the WebRTC session alive while PiP shows (the real risk)

| Datapoint | What it says | Confidence |
|---|---|---|
| Apple controller doc | Configure background audio playback to use PiP | High [Apple] |
| Apple call guide | Says nothing about VoIP or CallKit for the call variant | High [Apple] |
| Zoom Video SDK guide | Uses the **call** variant with "Audio, AirPlay, PiP" and "Voice over IP" modes; PiP only during active CallKit calls | Medium [3P](https://godevelopers.zoom.us/blog/video-sdk-ios-picture-in-picture/) |
| Fora Soft WebRTC PiP guide | Needs audio session (`.playAndRecord`/`.videoChat` for calls), `audio`+`voip` modes; declaring `voip` without call functionality is an "automatic reject"; check `isReadyForMoreMediaData` before enqueue or memory grows | Low-medium, a vendor blog [3P](https://www.forasoft.com/blog/article/picture-in-picture-mode-on-ios-implementation-and-peculiarities-1662) |
| Mac-display receiver PR (meowdisplay #15) | Sample-buffer PiP, `audio` mode, `.playback` + `.mixWithOthers`; **streaming continues while PiP is up**; device lock still ends the session | Low, single open-source project [3P](https://github.com/raiseCatError/meowdisplay/pull/15) |
| Moonlight iOS #686 | PiP window appeared but showed only a handful of frames; the control stream timed out because iOS suspended network threads | Low, exploration branch [3P](https://github.com/moonlight-stream/moonlight-ios/issues/686) |
| iOSSH #39 | "A terminal claiming the audio background mode is the kind of thing review asks about" | Low [3P](https://github.com/m96-chan/iOSSH/issues/39) |
| Apple forum 739333 | WebRTC PiP with `AVPictureInPictureVideoCallViewController` rendering nothing, unresolved for a year | Low [3P](https://developer.apple.com/forums/thread/739333) |

**Conclusion [Inference].** Apple documents the audio-mode prerequisite but does **not** document that a process without active audio playback keeps running while PiP shows. Known-good WebRTC PiP implementations are call apps with live audio and VoIP semantics. A remote-desktop receiver with no audio is in between; treat keep-alive as an experiment with a pass/fail spike (1.6), not an engineering task.

### 1.4 App Review risk

| Risk | Basis | Level | Mitigation |
|---|---|---|---|
| `audio` background mode with no audio | Guideline 2.5.4: background services only for "VoIP, audio playback, location, task completion, local notifications, etc." [Apple guidelines, updated 8 Jun 2026](https://developer.apple.com/app-store/review/guidelines/) | **Medium-High** | Ship real Mac audio forwarding (ScreenCaptureKit can capture system audio; host work) so `audio` playback is genuine; explain in review notes. Never use a silent-audio loop. |
| Video-call variant without calls | Not spelled out by Apple; 3P says reject | Medium (semantic misuse) | Do not use `voip`/CallKit/PushKit. PushKit requires CallKit for VoIP pushes since the iOS 13 SDK ([Apple](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit)). |
| Programmatic PiP start | Apple custom-player guide | Medium | Button plus explicit opt-in for auto-start |
| Guideline 4.2.7 (remote desktop) | (a) LAN-only and (b) "may not use APIs or platform features beyond what is required to stream" apply only to apps that mirror *specific software or services rather than a generic mirror of the host device* | Low if we stay generic | Keep positioning generic ("your Mac"); do not brand as a Claude/ChatGPT remote. Workbench 1.3 shipped PiP under the same guideline. |
| Privacy: content visible over other apps | Our own rule F37 (conceal captured content in background) | Product | PiP is an explicit, revocable exception: opt-in, view-only, `releaseAll` on start, banner "Mac visible in PiP", conceal remains in the app switcher |

### 1.5 How Workbench 1.3 does it

**Known [Vendor].** 1.3 (19 Aug 2026) added "Picture-in-Picture" that "keeps your remote session running in a floating window while using other apps"; connect, switch apps and the session is not disconnected ([release notes](https://astropad.com/blog/workbench-1-3/), [App Store version history](https://apps.apple.com/us/app/astropad-workbench/id6758788573), [9to5Mac](https://9to5mac.com/2026/08/19/astropad-workbench-1-3-adds-faster-streaming-privacy-curtain-and-more/)). A v1.2.2 App Store review complains the session drops after about 15 s in another app; the 1.2 release list mentions preventing connections from ending in the background.
**Unknown.** Which API, whether it forwards audio, whether it is view-only, behaviour on device lock, battery. **[Unverified]**

**Teardown protocol (1 day, free tier, real iPhone + iPad):** T1 entry (button vs auto on Home swipe); T2 PiP after 30 s, 5 min, 30 min (stream alive?); T3 lock the device; T4 is there any audio setting or audio; T5 tap inside PiP; T6 restore behaviour and time-to-first-frame; T7 battery/thermal over 10 min PiP; T8 does the Mac cursor/keyboard keep working after restore. Record before we claim parity.

### 1.6 Recommended approach (if the spike passes)

1. **New view-only renderer** (`PiPSampleBufferRenderer: RTCVideoRenderer`): read `frame.buffer as? RTCCVPixelBuffer`; honour crop (`requiresCropping`) and `frame.rotation`; build a format description from the image buffer; timing = host clock or `timeStampNs` (spike compares); mark for immediate display for live frames [3P convention; verify]; enqueue only when the layer reports ready (Apple layer API) and flush on `status == .failed`. Register it on the same `RTCVideoTrack` next to `RTCMTLVideoView`.
2. **Controller**: create only if `isPictureInPictureSupported()`; delegate returns infinite live range; `setPlaying(false)` means "freeze video and release input", true means resume; `skipByInterval` completes immediately; `didTransitionToRenderSize` drives the crop scale.
3. **Lifecycle**: on PiP start call `releaseAll`, set view-only, keep peer connection alive, drop full-rate Metal drawing; on restore re-enable control only after an explicit tap; if PiP is dismissed while backgrounded, tear the session down after a short grace (matches F37).
4. **Audio session**: `.playback` (+ `.mixWithOthers` so music is not killed), activated only when PiP or audio actually starts. Only with real audio.
5. **Fallback if PiP fails or is disallowed**: 1a below still covers short trips to another app.

**1a Multitasking survival (do this regardless).** `beginBackgroundTask(withName:expirationHandler:)` gives short system-determined extra time (read `backgroundTimeRemaining`; Apple gives no figure) ([Apple](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)). Use it to keep the peer connection up in view-only, input released, content concealed; on return within N seconds resume instantly; beyond that, fast reconnect with the paired trust (no re-auth, ICE restart). This directly answers the review "if I switch to Notes for 15 seconds I have to reconnect" and costs a few days. It respects F37 because control and content are concealed at once.

**Spike (3 days, real iPhone, before 12 Oct):** S-PiP-1 sample-buffer PiP with `.playback`, audio mode on, **no audio**: does the WebRTC receive/decode loop run for 10 min with Home screen, another app foreground, and device locked? S-PiP-2 same with real Mac audio forwarded. S-PiP-3 the video-call variant without `voip` (only to learn `isPictureInPicturePossible`; not shippable). S-PiP-4 VideoToolbox decode in background: does WebRTC's decoder survive (`kVTInvalidSessionErr` recovery)? Pass = S-PiP-1 or -2 stable for 10 min and a written App Review rationale we would defend; otherwise ship 1a only.

### 1.7 How we beat Workbench

- **Crop-to-region PiP.** A whole 16:10 desktop in a thumbnail is unreadable. Because we control the buffers we enqueue, PiP can show a chosen region (the terminal window, the agent window) at readable size via a crop before enqueue, with the region set from the phone or from the host's window list. Workbench's PiP is described only as "the remote session."
- **PiP that knows agent state.** Pause frame updates when idle (battery), and tint or badge when a help request is pending (section 5).
- **No account** to keep the session alive, versus repeated sign-outs in Workbench reviews.

**Effort:** renderer + controller + lifecycle + tests 4-7 days; +5-10 days for Mac audio forwarding (custom audio source on the host; WebRTC 153 audio-device customisation must be confirmed). **Go/no-go:** NO-GO for 17 Nov unless S-PiP-1/2 pass by 12 Oct; then GO behind an opt-in switch. Otherwise 1.1.

---
## 2. iPad-first layout, peripherals, Pencil and foldables (gap 2)

Current state [Repo]: the remote phone target (`PocketDeskRemote`) ships to iPhone and iPad (`TARGETED_DEVICE_FAMILY '1,2'`), deployment target 26.0, built with SDK 27, no explicit multi-scene or scene-manifest keys in `project.yml` for this target (SwiftUI `WindowGroup`), and only the iPhone orientation key set. The session view uses `statusBarHidden`, `persistentSystemOverlays(.hidden)`, `defersSystemGestures(on: .vertical)`, a relative-trackpad `NativeTrackpadSurface` (UIKit gestures) and a viewport model (`ViewportTransform`). There is no hardware-pointer, `GCMouse`, `pressesBegan`, Scribble, Pencil, mini-map or external-display code, and the PRODUCT docs say iPad has not been tested (borrowed iPad only). **Borrow or buy an iPad plus keyboard and mouse by mid-October; the simulator cannot validate Pencil, hover, or feel.**

### 2.1 Stage Manager, live resize, external display

| Fact | Source |
|---|---|
| Interactive windows can appear on an external display on M1+ iPads with Stage Manager, an external keyboard and a pointing device (role `windowApplication`); the same scene code serves both | [Apple connected display](https://developer.apple.com/documentation/uikit/presenting-content-on-a-connected-display) |
| iOS 27: `windowExternalDisplayNonInteractive` scenes are no longer created automatically; use `UIViewController.registerSceneAccessory(_:)` with `UISceneAccessory.externalNonInteractive(sceneConfiguration:)`; content spans the full screen; design so the app works without the display | same, and [iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) |
| iOS 27 SDK: supported orientations are no longer a condition for continuous resizability; `UIRequiresFullScreen` apps receive discrete resizes | iOS 27 release notes (UIKit "Resolved Issues") |
| iOS 27 SDK builds must include a launch screen key (`UILaunchScreen` etc.) or are rejected when the store starts accepting 27.0 SDK builds. Our target already sets `UILaunchScreen_Generation` | iOS 27 release notes; [Repo] `project.yml` |
| Xcode 27 (27A266a) stable 14 Sep 2026; Xcode 27.1 beta (27A9269) 18 Sep; iOS 27.0.1 stable 28 Sep | [Apple releases](https://developer.apple.com/news/releases/) |

**Recommended.** Treat every window size as valid: derive the viewport from the container (GeometryReader or scene geometry, never `UIScreen.main.bounds`), keep the focal anchor across resize (the model already does this for rotation and keyboard), and remove chrome that assumes a phone (bottom dock becomes a floating toolbar on regular width). Keep one session per Mac (B13): do not enable multiple scenes yet. Add the iPad orientation key for consistency even though SDK 27 no longer needs it. **Beat Workbench (later, iOS 27 only):** a `UISceneAccessory.externalNonInteractive` scene that shows the Mac full-screen on a TV or monitor while the phone acts as the trackpad; PocketDesk's controller is already relative, so this is a video-only second renderer on the same `RTCVideoTrack`. Gate with `#available(iOS 27, *)`.

### 2.2 iPad mini map

Workbench's mini map is **iPad-only**; iPhone uses gestures instead because "gestures are a better fit" [Vendor](https://support.astropad.com/en/articles/14022295-workbench-mini-map). It is a box in the lower right showing the whole Mac screen and your position, a draggable viewport rectangle, a zoom slider, and it is not available in Fullscreen mode; zoom persists after closing.

**Spec for PocketDesk (3-4 days).** A second renderer on the same track drawing at most 10 fps into a small layer (cheap); the viewport rectangle is derived from `ViewportTransform`; drag or tap-to-jump writes back through the same transform (manual pan wins, matching the PHONE-UX rule); a slider maps to the zoom scale; hidden in Fit; iPhone keeps the noninteractive zoom indicator only. Because our whole-desktop model is a pannable viewport, this is a navigator, not a second control surface. **Beat Workbench:** a **window strip** instead of a bare thumbnail, tap a window to fit it (needs the host's window geometry, which the host can already obtain with Screen Recording rights), and optional caret-follow from the planned Accessibility rect.

### 2.3 Hardware pointer: mouse, trackpad, pointer lock, middle click

Three lanes, never mixed for one event (the repo's own rule in `APPLE-INTERACTION-RESEARCH`):

| Mode | Use | APIs | Limits |
|---|---|---|---|
| **A. Touch relative trackpad** (default, exists) | fingers | UIKit gestures | none new |
| **B. Pointer "Follow"** (recommended default for hardware mouse/trackpad) | 1:1 absolute mapping while the pointer is over the video | `UIPointerInteraction` delegate returning `UIPointerStyle.hidden()` over the video region so only the Mac cursor is visible ([Apple](https://developer.apple.com/documentation/uikit/uipointerstyle/hidden())); `UIHoverGestureRecognizer` for position ([Apple](https://developer.apple.com/documentation/uikit/uihovergesturerecognizer)); secondary click from `UIEvent.buttonMask` (`.secondary`); scroll from `UIPanGestureRecognizer.allowedScrollTypesMask` ([Apple](https://developer.apple.com/documentation/uikit/uipangesturerecognizer/allowedscrolltypesmask)) | `UIHoverGestureRecognizer` "doesn't recognize gestures" on iOS (iPhone), so absolute follow is **iPadOS-only**; positions go through the inverse viewport transform |
| **C. Captured relative** (CAD, 3D, games) | raw deltas | `prefersPointerLocked` + `GCMouse.current?.mouseInput?.mouseMovedHandler` ([Apple](https://developer.apple.com/documentation/gamecontroller/gcmouseinput)) | Lock is a preference: scene must be **full screen, not Split View or Slide Over, in `foregroundActive`**; the system drops it when conditions fail; observe `UIPointerLockState.isLocked` and fall back to B ([Apple](https://developer.apple.com/documentation/uikit/uiviewcontroller/preferspointerlocked)). Behaviour in a windowed Stage Manager scene is not documented: **[Unverified]** |

**Middle click.** `GCMouseInput.middleButton` and `auxiliaryButtons` are documented; `UIEvent.ButtonMask.button(_:)` documents only 1 (primary) and 2 (secondary) ([Apple](https://developer.apple.com/documentation/uikit/uievent/buttonmask-swift.struct)). Use `GCMouse` for the middle button and only when the pointer is inside our view. Host side needs a CGEvent other-mouse button number 2 path: small. Workbench advertises middle mouse support for 3D and CAD [Vendor](https://astropad.com/product/workbench/) but documents no gesture for right/middle click.

### 2.4 Hardware keyboard, reserved shortcuts, Esc

- Forward physical keys with `pressesBegan/Ended` (`UIPress.key`: key code, characters, modifier flags) as raw key events, distinct from committed text (the repo's existing separation), and de-duplicate text versus raw-key paths. `GCKeyboard` (`coalesced`, connect/disconnect notifications) is the alternative raw path ([Apple](https://developer.apple.com/documentation/gamecontroller/gckeyboard)).
- `UIKeyCommand.wantsPriorityOverSystemBehavior = true` (iOS 15+) makes key commands see events before the text-input and focus systems; it does **not** capture OS-reserved shortcuts ([Apple](https://developer.apple.com/documentation/uikit/uikeycommand/wantspriorityoversystembehavior)). Workbench states Cmd-Tab, Cmd-H and Cmd-Shift-3 are intercepted by iOS before it can forward them [Vendor](https://support.astropad.com/en/articles/14025802-mouse-keyboard-and-input-in-workbench).
- **Workbench's answer (1.3, physical keyboards only):** a remap table where you assign a different chord (for example Option-Tab) that the app sends to the Mac as the reserved one; covers window management (Close/Minimize/Hide), Spotlight, App Switcher, Quit, Hide/Show Dock, Esc, screenshots [Vendor](https://support.astropad.com/en/articles/16448910-ipad-shortcut-mapping). PocketDesk should copy the idea (a default table of about 10 remaps) **and** add on-screen shortcut chips so it also works on the software keyboard, which Workbench's mapping does not.
- **Esc must reach the Mac.** Two App Store reviews say Workbench's hardware Esc exits or disrupts the connection ("Shortcuts and esc key does not work", "would love an option to disable the esc key … closing the connection"). Provide an explicit End control and never bind Esc to leaving. One review reports the on-screen delete key sending "a" (v1.3): test delete, repeat and dead keys.
- Release all held modifiers on `GCKeyboardDidDisconnect`, scene deactivation and disconnect (existing lease semantics).

### 2.5 Apple Pencil and Scribble to text

- **Free win.** By default Scribble lets people write into any editable view that implements `UITextInput` ([Apple UIScribbleInteraction](https://developer.apple.com/documentation/uikit/uiscribbleinteraction)). PocketDesk's local draft field (`CommittedTextField`) therefore should accept handwriting with no code; **verify on hardware and make sure nothing suppresses Scribble** (1 day). Workbench 1.2.6 shipped "Scribble mode" fixes [Vendor](https://apps.apple.com/us/app/astropad-workbench/id6758788573).
- **Write directly over the remote field (differentiator, later).** `UIIndirectScribbleInteraction` makes a view act as a container of virtual text-input elements the user can write into without tapping first ([Apple](https://developer.apple.com/documentation/uikit/uiindirectscribbleinteraction-1nfjm), sample [Customizing Scribble with Interactions](https://developer.apple.com/documentation/pencilkit/customizing-scribble-with-interactions)). Feed it the focused-field rectangle from the planned host Accessibility query (PHONE-UX doc); handwriting becomes committed text sent through the existing text path. Depends on that AX rect being reliable and a hardware Pencil to test. Estimate 6-10 days after the AX work.
- **Pressure and tilt.** Workbench sends Pencil input as pressure/tilt for Photoshop, Krita, Blender, coexisting with a Wacom [Vendor](https://support.astropad.com/en/articles/14011069-apple-pencil-input-with-workbench). That is a creative-tablet lane (host tablet events, `UITouch` force/altitude), 8-15 days, out of launch scope and off-brand for coding. Squeeze/double-tap via `UIPencilInteraction` ([Apple](https://developer.apple.com/documentation/uikit/uipencilinteraction)) can map to right-click or undo cheaply.
- Pencil hover and accessory gestures are model-dependent; do not infer support from the device family [Apple].

### 2.6 iPhone Duo and foldables (documented by Apple)

Facts [Apple]: iPhone Duo pre-order 16 Oct, available 23 Oct 2026; 7.6 inch inner and 5.4 inch outer display ([apple.com/iphone-duo](https://www.apple.com/iphone-duo/)). Build with the newest Xcode to use all screen space: with Xcode 26 and earlier the app does not extend under the status bar and camera; the Duo tech talk says the **27.1 SDK** is needed for the full-screen experience that reaches the inner display's edges (how a 27.0-SDK build is laid out is described ambiguously, so test it); `ReservedRegion` (SwiftUI) / `UIViewReservedRegion` (UIKit) arrived in 27.1 ([Preparing your app](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), [talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/), [HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)). Inner display has regular width and height size classes; outer is compact width; toolbars move to a vertical edge; a fold region divides the inner display when partly open; Live Activities expand into the outer Dynamic Island area. `ArrangementView` / `UIArrangementViewController` offers split and overlay arrangements for a primary and secondary view.

**Recommended.** Ship the 17 Nov build with the Xcode 27.1 release (or the GM that exists by then) and keep everything size-class and scene-bounds based; verify in Device Hub poses before 23 Oct and on a physical Duo after. **Later idea that fits the hinge naturally:** an `ArrangementView` with the Mac video primary and keyboard/controls secondary, so half-folded "laptop pose" gives a real keyboard half. No custom fold layout for launch.

### 2.7 Gap 2 summary

| Item | Approach | App Review risk | Effort | Beat Workbench | Nov 17 |
|---|---|---|---|---|---|
| Live-resize/Stage Manager layout | container-derived viewport | none | 3-4 | no account, relative trackpad | GO |
| Hardware keyboard raw keys, Esc, modifier release | `pressesBegan/Ended` | none | 2-3 | Esc never exits | GO |
| Shortcut remap + on-screen chips | remap table + chips | none | 2-3 | works on software keyboard too | stretch |
| Hardware pointer Follow, right click, scroll | hidden system pointer + hover | none | 3-4 | both relative and absolute | GO |
| Captured pointer, middle click | `prefersPointerLocked`, `GCMouse` | none | 3-5 | CAD/3D | stretch |
| Mini map | second renderer + `ViewportTransform` | none | 3-4 | window strip | GO if time |
| Scribble into draft | verify only | none | 1 | write over remote field later | GO |
| External display scene | `registerSceneAccessory` (iOS 27) | low | 4-6 | Mac on TV, phone as trackpad | later |
| Duo | 27.1 build, size classes | none | 2-3 | ArrangementView keyboard half | GO (no-break) |

---
## 3. Agent integration: the differentiator (gap 3)

### 3.1 The landscape today, and where PocketDesk can still win

| Product | What it gives a phone user about agents on their Mac | Source |
|---|---|---|
| Claude Code + Claude iOS/Android app | Remote Control drives a session running on your machine; push when a task finishes or when "actions required" (permission prompts and questions); skips push while you are typing at the terminal; Dispatch and Channels (Telegram/Discord/iMessage) | [mobile](https://code.claude.com/docs/en/mobile), [remote control](https://code.claude.com/docs/en/remote-control), [channels](https://code.claude.com/docs/en/channels) |
| Claude Cowork Dispatch | Message the desktop app from the phone; push "when a task is done or when Claude needs your go-ahead"; needs Claude Desktop running and the computer awake | [Vendor](https://support.claude.com/en/articles/13947068-assign-tasks-from-anywhere-in-claude-cowork) |
| Codex in ChatGPT mobile (14 May 2026) | Scan a QR from the Codex Mac app; work across threads, review diffs, approve commands, screenshots and terminal output stream back over a relay | [9to5Mac](https://9to5mac.com/2026/05/14/openai-brings-codex-control-to-chatgpt-for-iphone-and-android/) |
| Astropad Workbench | Remote desktop, unified/virtual display, dictation, PiP, app watchdog. No documented push or agent integration | 3.8 |

**Reading [Inference].** Text-level agent supervision (approve a command, read a diff, get pinged) is now built into each vendor's own mobile app, so shipping "we notify you" as the pitch would be weak. Two gaps remain that only a screen-level tool can fill:

1. **GUI-only blockers.** A native macOS permission dialog, an OS or app login, a captcha, an installer, a visual check. A GitHub request (anthropics/claude-code #42693, opened 2 Apr 2026, closed as duplicate) describes exactly this for Cowork: `request_access` triggers a native macOS dialog that must be approved on the Mac within 60 s, so an away user's computer-use task fails silently. The request predates today's Dispatch push wording, so **recheck before quoting it** [3P](https://github.com/anthropics/claude-code/issues/42693).
2. **Cross-vendor and exclusive hand-over.** One inbox for Claude Code, Cowork and Codex, with a human-in-control state that pauses cooperating agents and hands back with a context note.

**Positioning rule.** "When your agent gets stuck on something only your Mac's screen can solve, PocketDesk gets you there in one tap." Stay a generic Mac mirror (guideline 4.2.7).

### 3.2 MCP Apps and connector reality (Claude and ChatGPT)

**MCP Apps** (spec 2026-01-26, SEP-1865): tools declare `_meta.ui.resourceUri` pointing at a `ui://` resource; the host renders it in a sandboxed iframe; display modes `inline | fullscreen | pip`; host context includes `platform: web|desktop|mobile`, `deviceCapabilities {touch, hover}`, `safeAreaInsets`; the app can call tools, `ui/open-link`, `ui/message`, `ui/update-model-context`, `ui/request-display-mode`; tool `visibility: ["model","app"]` lets app-only tools be hidden from the model ([spec](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx), [overview](https://modelcontextprotocol.io/extensions/apps/overview), [client matrix](https://modelcontextprotocol.io/extensions/client-matrix): Claude web and desktop, ChatGPT, Cursor, VS Code Copilot, others).

| Surface | Status | Consequence for PocketDesk |
|---|---|---|
| **Claude web/desktop/iOS/Android** | Interactive connectors "available for all users on Claude, Cowork, Claude Desktop, and Claude for iOS/Android" ([support](https://support.claude.com/en/articles/13454812-use-interactive-connectors-in-claude)). Custom and directory connectors run the same runtime; differences are review, discovery and link handling ([directory vs custom](https://claude.com/docs/connectors/building/directory-vs-custom)). A custom connector can be shared as a prefilled install link `claude.ai/customize/connectors?modal=add-custom-connector&connectorName=…&connectorUrl=…` | Real path to "Connect PocketDesk to Claude" without listing review |
| **Claude iOS specifics** | Renders MCP Apps in a native `WKWebView` (inspectable with Safari Web Inspector); **no camera, microphone or location**; users must add the connector on web or desktop first; inline apps do not receive vertical pans (the conversation scrolls), so anything with its own gestures needs `fullscreen`; `frameDomains` restricted pending security review; iOS omits `Referer` on cross-origin subresources so gate on `Origin` (`{hash}.claudemcpcontent.com`); tool calls are proxied through Claude's backend (Anthropic egress IPs, not the phone) ([design](https://claude.com/docs/connectors/building/mcp-apps/design-guidelines), [troubleshooting](https://claude.com/docs/connectors/building/mcp-apps/troubleshooting)) | An embedded live view would be WebRTC in a `WKWebView` (iOS 14.3+ exposes RTCPeerConnection [3P]); media path, WebRTC permission policy, fullscreen touch, and keyboard focus inside Claude's shell are all **[Unverified]** |
| **Claude `ui.domain`** | For Claude set `_meta.ui.domain` to the first 32 hex chars of SHA-256 of the exact connector URL plus `.claudemcpcontent.com` | Not set in the repo |
| **Claude limits** | No MCP sampling or resource subscriptions; ~150,000-char tool result cap; 240 s per tool call on claude.ai and Desktop | Do not depend on long waits or push |
| **ChatGPT** | Custom (developer-mode) MCP apps: **web only**; plans Pro/Plus/Business/Enterprise/Edu; write tools need confirmation unless `readOnlyHint` ([developer mode](https://developers.openai.com/api/docs/guides/developer-mode)). Published plugins use `_meta.ui.resourceUri` (with an `openai/outputTemplate` alias) and support inline, fullscreen and PiP display modes on mobile ([UI](https://developers.openai.com/plugins/build/chatgpt-ui), [UI guidelines](https://developers.openai.com/plugins/concepts/ui-guidelines)); apps were renamed plugins in July 2026 and mobile widget rendering had an outage 3-5 Aug 2026 that OpenAI resolved ([community thread](https://community.openai.com/t/widgets-are-not-loading-in-the-chatgpt-mobile-apps-for-launched-apps-plugins/1388831)). Public availability needs the plugin submission flow | Private ChatGPT phone embedding is not possible today; a public plugin is a later, separate review |

**Repo gap list [Repo]** (`Server/src/mcp/tools.ts`, `app.ts`): (1) tools are registered with plain `registerTool`, none carries `_meta.ui.resourceUri`, so the viewer resource can never render; (2) `viewerShellHtml` is a placeholder; (3) no `ui.domain`, `permissions`, or `prefersBorder`; (4) no app-only tools (`visibility: ["app"]`) for take-over/hand-back buttons; (5) no `request_human_help` or push. Use the SDK's `registerAppTool` / `registerAppResource` helpers (Context7: `/modelcontextprotocol/ext-apps`) when this is built.

**Decision.** Keep T1 (external browser and native app) as the baseline. Do a 2-day spike for an embedded **view-only** card (status, agent label, "Open on iPhone" button) in Claude, not the live WebRTC stream. Live stream embedding waits until the WKWebView WebRTC and fullscreen-gesture behaviour is measured (section 7).

### 3.3 Deep links and universal links: open PocketDesk from a chat

| Path | How | Friction | Notes |
|---|---|---|---|
| **Link in the tool result** (`viewerURL`, already returned by `request_desktop_access`) | `https://<origin>/open/<intentID>` as a universal link | User taps a link in the chat | Apple: users open your app when they click a universal link inside a browser app **and `WKWebView`**; a tap on a link in a *different* domain opens the app; a same-domain tap stays in Safari ([Apple](https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content)). Programmatic navigation is not a user tap **[3P]**. How Claude or ChatGPT iOS opens a tapped chat link is **[Unverified]** |
| **`ui/open-link` from a widget** | MCP App button | Claude shows an "Open external link" confirmation modal for **custom** connectors, always; directory connectors can allowlist an HTTPS origin or a **custom URI scheme** so it opens without the modal, only after a real user gesture ([Claude](https://claude.com/docs/connectors/building/mcp-apps/external-links)) | Custom scheme is a directory-only perk; universal link is the portable choice |
| **Push notification tap** | default action of the notification | none | Best path; needs no chat |
| **Web fallback** | same URL opens the existing browser viewer if the app is absent | none | The repo already serves `/?intent=`; keep it distinct from the app-first path so users can force web |

**Requirements.** Associated Domains capability on the app (`applinks:<origin host>`) and an `apple-app-site-association` file served over HTTPS at `/.well-known/` on the same host (Apple: each subdomain needs its own file; `components` can match path, query and fragment) ([Apple](https://developer.apple.com/documentation/xcode/supporting-associated-domains)). Draft using the values in `project.yml`: appID `39HM2X8GS6.com.roshan.PocketDesk.Remote`, component `{"/": "/open/*"}`; the bundle id may change before the store build. The Bun service serves an exact whitelist of static paths, so this route needs an explicit handler. A link opens nothing by itself; the app must treat it as navigation only (repo rule: an intent grants nothing).

### 3.4 Push: "agent needs you" through APNs

**Architecture [Apple].** The phone registers with APNs; the token goes to our server; the server sends over HTTP/2 with a provider token (ES256 JWT from a `.p8` auth key; refresh no more often than every 20 minutes and at least every 60; APNs rejects tokens older than 1 hour) ([token](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)). Headers: `apns-push-type: alert`, `apns-topic: <bundleID>`, `apns-priority: 10` for immediate action (5 otherwise), `apns-expiration` (0 = one attempt, no storage), `apns-collapse-id` (max 64 bytes); payload at most 4 KB ([send](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns), [payload](https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification)). `interruption-level`: `passive | active | time-sensitive | critical`; time-sensitive breaks through Focus and needs the Time Sensitive Notifications capability (`com.apple.developer.usernotifications.time-sensitive` [3P confirmation]); users can turn it off ([Apple](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive)). Critical alerts need an Apple-granted entitlement: not for us.

**Registration without an account [Repo].** Native pairing already gives the server a room id and a client token hash. Register the APNs token over the authenticated `/signal` socket after `registered` (`{type:"push",…}`) and store it per room in a 0600 file (same pattern as `McpStore`/rooms). The Mac host sends `agent_event` on its already-open host socket; the server fans out to that room's tokens. Nothing needs a user account. Disclose APNs token and alert metadata in the App Privacy details.

**Content rules.**
- App Review 4.5.4: push must not be required for the app to function and "should not be used to send sensitive personal or confidential information"; 5.1.2(i): no requiring notifications for functionality. Notification text is generic: title "PocketDesk", body "Claude Code needs you on your Mac". **No prompt text, file names or screen content in the payload.** The reason string is fetched inside the app after unlock. [Apple guidelines]
- Ask permission **in context** (when the user turns on "Agent alerts"), not at launch; provisional authorisation can trial quiet delivery but is wrong for time-critical alerts ([Apple](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)).
- Default action (tap on the body) opens the app; use `UNNotificationAction` with `.foreground` only for extra buttons and `.authenticationRequired` for anything acting on the device ([Apple](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types)). Suggested actions: Not now (background, no launch), Mute this agent 1 h.
- Collapse by request id, expire after 15 min, rate-limit per room (for example 6 per hour), dedupe repeated permission prompts from one session.
- **Do not use PushKit/VoIP pushes** to wake the app. **[Apple]**
- **Bun risk [Unverified]:** APNs requires HTTP/2 and Bun's `node:http2` client behaviour for this use has not been confirmed. Spike for one day; fallbacks are `node-apn`/`apns2` under Node, or a small sidecar.
- Human steps that only the owner can do: create the APNs auth key and enable Push Notifications, Associated Domains and (optionally) Time Sensitive Notifications for the App ID.

### 3.5 Live Activities and Dynamic Island

Facts [Apple]: Live Activities appear on the Lock Screen, Dynamic Island, StandBy, CarPlay, the paired Mac menu bar and the Watch Smart Stack; an app must support **all** presentations (compact, minimal, expanded, lock screen); a Live Activity lasts up to 8 hours active, then up to 4 more on the Lock Screen (12 maximum); start from the foreground with `Activity.request`, or by push-to-start token (`pushToStartTokenUpdates`, iOS 17.2+ ) with `apns-push-type: liveactivity`, topic `<bundle>.push-type.liveactivity`; priority 5 does not count against the update budget, priority 10 does, and `NSSupportsLiveActivitiesFrequentUpdates` raises it ([displaying](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities), [push](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)). HIG: use for tasks with a defined start and end, do not display sensitive information, keep interactivity to one element, alert only for essential updates and **do not send an ordinary push alongside a Live Activity for the same update** ([HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)). On Duo the outer camera region expands into the Dynamic Island for Live Activities ([HIG Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)).

**Fit.** A help request has a clear start (agent asks) and end (handed back, expired, cancelled). Content: agent label, "waiting 2:14", "Tap to take over". **Recommendation:** ship plain notifications first; add the Live Activity in 1.1 (widget extension target, push-to-start token, one Live Activity per help request, ended on hand-back with a short dismissal date; while one exists, suppress the duplicate alert). Effort 8-12 days plus a review-surface increase; not a launch item.

### 3.6 Detecting that an agent is waiting on the user

| Runtime | Public signals | Notes and caveats |
|---|---|---|
| **Claude Code** (CLI, IDE, Desktop Code tab) | Hooks (`http`, `command`, `mcp_tool`, `prompt`, `agent` handlers): `PermissionRequest` fires when Claude is *about to ask* (immediate); `Notification` with `permission_prompt` (after about 6 s), `idle_prompt` (about 60 s after finishing), `elicitation_dialog`, `elicitation_url_dialog`; `Stop`. Notification hooks cannot block; you receive them even if desktop notifications are off. In sessions hosted by Claude Desktop or VS Code (`canUseTool`), `permission_prompt` fires about 6 s after the ask ([hooks](https://code.claude.com/docs/en/hooks)) | Best passive signal. Users can disable hooks; installation is a user action |
| **Claude Cowork** | Plugin `hooks/hooks.json` are marked **Loads** in Cowork (ignored in chat); local MCP servers load when the Cowork session runs on the computer ([platform support](https://claude.com/docs/plugins/platform-support)) | Whether hook processes run on the host or inside a sandbox, and can reach `127.0.0.1`, is **[Unverified]**: spike |
| **Codex** (desktop app, IDE extension, CLI) | Hooks are stable: `PermissionRequest`, `PreToolUse`, `Stop`, `Interrupt`, `SessionStart`…; handlers `command` and `mcp_tool`; `~/.codex/hooks.json`, repo `.codex/hooks.json`, or plugin-bundled; non-managed hooks need user review; `notify` fires only `agent-turn-complete`, and the TUI's `approval-requested` is terminal-only ([hooks](https://learn.chatgpt.com/docs/hooks), [config](https://learn.chatgpt.com/docs/config-file/config-advanced)) | Codex has **no HTTP hook type** in the docs read: use `command` (a tiny `pocketdeskctl`) or an `mcp_tool` hook against our MCP server. Output schema for PreToolUse/PermissionRequest decisions must be confirmed against the installed version |
| **ChatGPT / Claude chat, any MCP client** | Nothing passive. The agent has to *choose* to call `request_human_help` | Add instructions (server `instructions` and a Skill) telling the model when to call it; model-dependent |
| **MCP elicitation (URL mode)** | Spec: servers can direct users to a URL out of band; clients must show the full domain, get consent, not pre-fetch, and open in a context the model cannot inspect (SFSafariViewController is good, `WKWebView` is not) ([spec](https://modelcontextprotocol.io/specification/latest/client/elicitation)). Claude Code declares `elicitation: {form:{}, url:{}}` on revision 2026-07-28 connections ([MCP](https://code.claude.com/docs/en/mcp)) | Claude's docs list "advanced or draft capabilities" as unsupported and ChatGPT support is unknown: optional enhancement, never a dependency |
| Screen-scraping the Mac for dialogs | rejected: brittle and it defeats the privacy stance | |

**Recommendation.** Two independent triggers, both optional, both off until the user connects an agent: (a) **agent-initiated** `request_human_help` (works in every MCP client), (b) **passive** hooks for Claude Code, Cowork and Codex sending only "type + agent label" to the Mac companion. Default to *blocking* events only (permission prompt, elicitation, explicit help request); idle and "finished" are separate opt-ins.

### 3.7 Safe exclusive take-over and hand-back

**What PocketDesk can and cannot promise.** PocketDesk itself gives agents no input control (by design: no AI takeover, automatic approval or access to unrelated sessions). "Exclusive" therefore means: the human holds the single PocketDesk controller lock (B13) **and** cooperating agents are paused. Unrelated Mac software and non-cooperating agents remain outside the guarantee.

**Enforcement options ranked.**

| Mechanism | Pauses | Weakness |
|---|---|---|
| **`PreToolUse` gate hook** (Claude Code, Cowork, Codex): runs before every tool call whether or not it needs permission; `deny` reason is shown to the model; `additionalContext` is injected on resume ([hooks](https://code.claude.com/docs/en/hooks)) | Next and every subsequent tool call, including subagents | **A timed-out command hook lets the tool call continue** (documented). So exclusivity is best-effort: set the hook timeout above the lock TTL, and never present the state as guaranteed |
| Held/long-poll MCP tool (`await_human`) | The calling agent while the call is open | Claude Code moves a main-conversation MCP call still running after 2 minutes to a background task and continues (v2.1.212+, `CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS`); idle timeout 5 min for HTTP servers unless progress is sent; claude.ai and Desktop cap a call at 240 s ([MCP](https://code.claude.com/docs/en/mcp), [Claude building](https://claude.com/docs/connectors/building)). **Not a reliable pause.** |
| Channels (`notifications/claude/channel`) to inject "resume" into the live session | Resume only | Research preview; custom channels need `--dangerously-load-development-channels`; allowlist-gated ([channels reference](https://code.claude.com/docs/en/channels-reference)). Later, feature-flagged |
| Codex `app-server` adapter (`turn/interrupt`, `turn/steer`, approval requests) | Sessions we own | Child-process ownership, unresolved earlier review; keep as later tier ([app-server](https://learn.chatgpt.com/docs/app-server)) |

**Tiered protocol.**
- **Tier 0 (any MCP client, chat or terminal):** `request_human_help` returns immediately with an instruction to *stop desktop actions, do not call other tools, and wait for the user to say they are back*; `help_status` reports the state. Resume is user-initiated ("done" in chat) or by the widget's `ui/message` once an embedded card exists. Honest label: "cooperative".
- **Tier 1 (Claude Code / Cowork / Codex with the PocketDesk hook pack):** gate hook holds or denies tool calls while the human lock is active; release returns `allow` plus `additionalContext` "the human used the Mac for 4 min; screen state may have changed, re-observe before acting" (duration only, no content). This gives automatic resume with no adapter.
- **Tier 2 (later):** owned Codex runtime adapter; Claude Channels.

**Invariants.** Human input beats agent state; releasing the lock first runs `releaseAll` on held input (existing lease semantics); Stop Sharing, revocation, phone disconnect beyond a 60 s grace, or lock TTL (default 30 min, renewable) auto-release the lock **and** tell the gate to resume with a note; a gate hook that cannot reach the Mac companion fails **open**, because if the host is down no human control exists either; agent-supplied reason text is untrusted, plain text, length-capped, never a link, never used to pick a pixel or a URL.

### 3.8 What Workbench's "monitor agents" actually does

| Claim | Where | What it amounts to |
|---|---|---|
| "monitor their AI agents from anywhere, without being tied to a desk"; "check logs and output to verify agent work, restart failed tasks, or reconnect to long-running jobs" | [MacRumors](https://www.macrumors.com/2026/04/08/astropad-workbench-app/) | Remote desktop |
| "Real-Time Job Monitoring: review logs and progress as your AI agents run behind the scenes"; headless Mac mini control; device catalogue | [Astropad product page](https://astropad.com/product/workbench/) | Screen access plus virtual display |
| "especially designed with AI workflows in mind"; no notifications, agent detection or integrations mentioned | [9to5Mac 8 Apr](https://9to5mac.com/2026/04/08/astropad-unveils-workbench-for-mac-remote-desktop-made-for-the-ai-era/) | Marketing |
| Watchdog relaunches *Workbench itself* after crash/hang; PiP; voice dictation to steer agents | [1.3 notes](https://astropad.com/blog/workbench-1-3/) | Reliability of the remote app, not agent awareness |
| User: "Great way to watch over my AI remotely from my iPhone … peek in and control the Mac mini" (5 stars, v1.2.2) | App Store review feed | Peek-and-steer use case is real |

**Conclusion.** No push, no agent detection, no vendor integration is documented; "monitor" means *you look at the screen and type or dictate*. Agent-awareness is an open lane against Workbench, but the vendors' own apps already cover text-level supervision (3.1).

### 3.9 Smallest compelling demo (launch video, 45 to 60 seconds)

Honest constraints: recorded on a real iPhone with a QuickTime capture, real APNs, real Mac, no compositing of the notification.

1. **0-8 s.** Mac, terminal on the left: Claude Code (or Codex) is doing a real task, for example setting up a project that needs a login in the Apple Developer portal. Phone on a table, locked.
2. **8-14 s.** Agent calls `request_human_help("Need you to sign in in Safari")`. Lock screen banner: "PocketDesk: Claude Code needs you on your Mac". (No prompt text in the banner.)
3. **14-24 s.** Tap. PocketDesk opens straight to a small sheet (agent label, reason, [Take over] [View only] [Not now]); Take over; live Mac appears; Mac menu bar shows "iPhone has control, Claude Code is paused".
4. **24-40 s.** Sign in with the on-screen keyboard and biometric autofill in the real page; password never goes through the chat or agent.
5. **40-48 s.** Tap **Hand back**. Phone: "Handed back". Mac terminal: the agent resumes with "Human used the Mac for 0:38".
6. **48-55 s.** Negative-test cut (proves it is real): open the old notification again, "This request has ended."; end card "Your agents ask. You answer."

**Acceptance is receipts, not the video:** a log of the hook gate holding a tool call for the human interval, the lock state transitions, and an APNs response id.

---
## 4. What Workbench users praise and request (phone-side)

**Sources.** Public App Store customer-review feed for the US storefront (24 reviews, versions 1.0.1 to 1.3; `itunes.apple.com/us/rss/customerreviews/…/id=6758788573`), one Australian review, MacStories (5 May 2026), Astropad release notes and help centre, and one search-snippet mention I could not re-open (marked). 4.8 stars from 182 US ratings [App Store page](https://apps.apple.com/us/app/astropad-workbench/id6758788573). Reddit was inaccessible. Small sample, mixed versions: directional only.

| Theme | Evidence (version) | What it means for PocketDesk |
|---|---|---|
| **Connection reliability and multitasking drops** | "connection drops all the time, like if I switch to the Notes app for 15 seconds … have to reconnect" (2 stars, 1.2.2); "constantly crashes" after 10-15 min (1 star, 1.1.1); "fails to connect on second try" (1 star, 1.1); post-subscription connect failure with no error or reset step (1.1.1); placeholder page on iPhone (1.0.1) | Section 1a is the fix; add visible states, a "Reset connection" action, and never show an empty page |
| **Sign-in churn** | constantly signed out (1 star, 1.2.1); forced to log back in (2 stars, 1.2.2); "HATE email verification … let me stay signed in" (4 stars, 1.1.1) | **No account** is a differentiator; keep pairing persistence rock solid |
| **Keyboard and shortcuts** | delete key returns "a" (3 stars, 1.3); Esc exits the connection, requested an option to disable (5 stars, 1.2; 3 stars, 1.2.2); Cmd-Tab and app switching do not work (1.2.2; answered by remap in 1.3); Japanese keyboard inputs (1.2.4 fix; one 2-star review before it) | Section 2.4: Esc never exits; test delete/repeat/dead keys; remap table |
| **No trackpad-style cursor mode** | "I want to be able to move the cursor like a trackpad" (3 stars, 1.1); "No trackpad control mode" (1 star, 1.1) | **Relative trackpad is a validated differentiator**; keep it the default and add hardware-pointer Follow |
| **Copy/paste freezes** | Workbench locks up when copy/pasting (5 stars, 1.2.1); MacStories lists clipboard freezes and lost typing | Clipboard design must fail safe (bounded, explicit, no lockup); already a P1 in BUILD-PRIORITIES |
| **Praise: speed, unified display, iPad as a laptop, Blender usability, cellular access to a sleeping Mac, customer service** | "Unified display is a game changer" (5 stars, 1.1.1); "fast, seamless"; "Blender … usable to the point I forget it's a remote connection" (1.2); "connect to my sleeping dual monitor Mac … over cellular" (1.1.1) | Sleeping-Mac reachability and multi-display are host features outside this round; note them as things users notice |
| **Praise: agent peek use case** | "Great way to watch over my AI remotely from my iPhone … peek in and control the Mac mini" (5 stars, 1.2.2) | Confirms the peek-and-steer use case; nothing about alerts |
| **Requests** | file transfer (AU, 1.2.2); different app icon options (1.1.1); lifetime option, lower price, Windows (3 stars, 1.0.1); a search snippet mentions movable mic/keyboard buttons on iPhone because they "get in the way" (page later returned 410, treat as low confidence) | Make floating controls repositionable/hideable; consider an icon set; pricing is in PRODUCT section 10 |
| **Trajectory** | 10 releases in six months: keyboard and zoom fixes, non-English dictation, background persistence, Scribble, clipboard reliability, iPad shortcut mapping, PiP, Privacy Curtain, Watchdog | Astropad iterates monthly on exactly these phone-side items; parity work is a moving target |

**Not found.** No public request in the sampled material asks for agent notifications from Workbench: the market signal for "agent needs you" comes from Anthropic and OpenAI shipping it, not from Workbench users.

---

## 5. Concrete spec: v1 "agent needs you → open Mac → take over → hand back"

Status: proposal for review, not implemented; subordinate to PRODUCT.md; no chat message was sent and nothing was deployed. It reuses what exists: paired native session, host-enforced controller lock and view-only/control scopes, MCP OAuth grants, intent links, host status RPC, `inspect_screen` (untouched).

### 5.1 Scope and non-goals

In: help request from an agent (explicit tool, or passive hook), APNs alert, tap into the paired app, View/Take over, exclusive human control with cooperative pause, hand back with context note, expiry and revoke, a visible "Send test alert" control.
Out for v1: embedded live viewer in chat, Live Activity, arbitrary GUI-chat takeover, PocketDesk clicking on the agent's behalf, screen content in notifications, Codex app-server adapter, Channels, Pencil, PiP.

### 5.2 Flow

```mermaid
sequenceDiagram
    participant A as Agent (Claude Code / Codex / Cowork / chat)
    participant S as PocketDesk server
    participant H as Mac host (menu bar app)
    participant P as APNs
    participant U as iPhone app
    A->>S: MCP request_human_help(reason)   [or hook via H]
    S->>H: help_request {id, agentLabel, expires}
    H-->>S: accepted (host online, user opted in)
    S->>P: alert push (generic text, collapse id)
    P-->>U: banner "Claude Code needs you on your Mac"
    U->>U: tap → /open/<intent> or notification default action
    U->>H: native paired session (view or control)
    H-->>U: help_context {label, reason} (sealed, never via APNs)
    U->>H: takeover
    H->>H: acquire single lock; banner "iPhone has control"
    Note over A,H: Tier 1: PreToolUse gate holds/denies tool calls
    U->>H: handback
    H->>H: releaseAll input; release lock
    H-->>A: gate resumes + additionalContext (duration only)
    S-->>A: help_status = handed_back
```

### 5.3 State machine (server-authoritative record, host-enforced lock)

`pending → notified → seen → human_active → handed_back`, with terminal states `expired` (default 15 min, max 60), `cancelled` (agent), `declined` (user "Not now"), `aborted` (Stop Sharing, revoke, unpair), `notify_failed`. Timers: lock TTL 25 min (renewable by user activity), disconnect grace 60 s, gate hook timeout 30 min (must exceed the lock TTL), APNs expiration 15 min.

### 5.4 Server (Bun) work

**New MCP scope** `agent.help`, granted in the existing Mac-approved OAuth screen with its own consent line ("Allow this assistant to send you 'needs you' alerts"). Existing `desktop.access` and `screen.inspect` unchanged; opening a link still grants nothing.

**New tools** (annotations: not read-only, not destructive, not open-world; rate-limited):

| Tool | Input | Output |
|---|---|---|
| `request_human_help` | `reason` string 1-140; `expiresInMinutes` int 1-60 default 15 | `{helpRequestId, state, instruction, viewerURL}` where `state ∈ pending, host_offline, no_phone_registered, muted, rate_limited`; `instruction` tells the model to stop desktop actions, avoid other tools and wait for the user; `viewerURL` = `https://<origin>/open/<intentID>` |
| `help_status` | `helpRequestId` | `{state, humanActiveSeconds?, handedBackAt?}` (own grant only, like `session_status`) |
| `cancel_help` | `helpRequestId` | `{cancelled}` |

Later: register with the SDK's `registerAppTool` and `_meta.ui.resourceUri` for the status card, plus app-only tools (`visibility:["app"]`).

**Push relay.** `PushRegistry` (0600 JSON file): room → `[{apnsToken, env: production|sandbox, addedAt, lastOk}]`; registration over the authenticated `/signal` socket; `ApnsClient` (HTTP/2, ES256 provider token refreshed every 45 min, `apns-push-type: alert`, `apns-topic`, `apns-priority: 10`, `apns-collapse-id: h-<id[0..12]>`, `apns-expiration: now+900`); drop tokens on 410/`BadDeviceToken`; per-room rate limit; metrics without content. The reason string is held in memory only until the Mac acknowledges it.

**Routes.** `/.well-known/apple-app-site-association` (application/json, no redirect) and `/open/<intentID>` (serve the AASA-matched page; if the app is absent it shows the existing browser viewer entry).

### 5.5 Mac host work

- **Setting "Agent alerts"** (off by default; per-agent toggles; quiet hours; "include reason preview in app only").
- **Local agent bridge** on `127.0.0.1:<random>`; port and secret in a 0600 file; endpoints `POST /agent/v1/event` (non-blocking: `{agent:{kind,label,sessionHash},type,toolName?}`, message text redacted) and `POST /agent/v1/gate` (long-poll: returns immediately when no lock, otherwise holds until release, TTL, abort). Bind loopback only; reject non-loopback Host; reject anything without the bearer.
- **`pocketdeskctl`** small signed binary shipped inside the app bundle: `hook event`, `hook gate`. It speaks hook JSON on stdin, prints hook JSON on stdout. One tool serves Claude Code, Cowork and Codex (Codex has no HTTP hook type).
- **Lock and banner.** Reuse the existing single-controller rule; new `AgentLock` with holder peer, TTL, state; menu bar item "Agent help requested: Claude Code", banner "iPhone has control · Claude Code is paused", **Hand back to agent** and Stop Sharing always visible; Stop Sharing aborts the lock.
- **Connect agents wizard.** Shows the exact hook JSON it will write, with a diff, and writes only on explicit confirmation (creating standing configuration is a user-permission action); offers "copy to clipboard" and a plugin folder as alternatives.

### 5.6 Phone work

- **`@UIApplicationDelegateAdaptor`** for token callbacks; `PushRegistrar`; permission requested when the user turns on Agent alerts; `UNUserNotificationCenterDelegate.didReceive` routes to the help request; categories `AGENT_HELP` with actions Not now and Mute 1 h.
- **Deep links.** `.onOpenURL` and `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` for `/open/<id>`; Associated Domains entitlement; unknown or foreign intent shows "This link is for a different Mac" with a web-viewer button (browser enrolment stays separate from native pairing).
- **`HelpRequestSheet`** (agent label, reason as plain text, age, View only, Take over, Not now); state comes from the Mac over the sealed control channel.
- **`HandBackPill`** in the session HUD while `human_active`, plus a confirmation haptic and a "Handed back" state; input release is guaranteed before the lock release message is sent.
- **Settings > Agent alerts** with a visible **Send test alert** button (also gives App Review a way to see the feature without an agent).

### 5.7 Hook pack (Claude Code and Cowork; Codex uses the same commands in its own file)

Claude Code plugin `hooks/hooks.json` (also usable in `~/.claude/settings.json`); fields verified against the hooks reference:

```json
{
  "hooks": {
    "PermissionRequest": [
      { "hooks": [ { "type": "command",
        "command": "/Applications/PocketDesk Host.app/Contents/MacOS/pocketdeskctl",
        "args": ["hook", "event", "--agent", "claude-code"], "timeout": 5 } ] }
    ],
    "Notification": [
      { "matcher": "permission_prompt|elicitation_dialog|elicitation_url_dialog",
        "hooks": [ { "type": "command",
          "command": "/Applications/PocketDesk Host.app/Contents/MacOS/pocketdeskctl",
          "args": ["hook", "event", "--agent", "claude-code"], "timeout": 5 } ] }
    ],
    "PreToolUse": [
      { "hooks": [ { "type": "command",
        "command": "/Applications/PocketDesk Host.app/Contents/MacOS/pocketdeskctl",
        "args": ["hook", "gate", "--agent", "claude-code"],
        "timeout": 1800, "statusMessage": "Paused: you are in control from PocketDesk" } ] }
    ]
  }
}
```

Notes: `PermissionRequest` fires immediately, `Notification` `permission_prompt` only after about 6 s, so use both and dedupe by session; a `PreToolUse` command hook that times out lets the tool continue, so `timeout` (1800 s) exceeds the lock TTL (1500 s); the gate prints `hookSpecificOutput.additionalContext` on resume ("Human used the Mac for 4 min; re-observe the screen before continuing") and `permissionDecision: "deny"` with a reason only when the request itself was cancelled by the human; The docs say `PreToolUse` runs before every tool call whether or not a permission is needed; behaviour under `bypassPermissions`, with subagents and with a 3-minute hold is spike S-HOOK-2. Codex: same commands under `PreToolUse` and `PermissionRequest`, non-managed hooks require user review on first run, decision output schema to be confirmed on the installed version.

### 5.8 Push payload (no content)

```json
{ "aps": { "alert": { "title": "PocketDesk", "body": "Claude Code needs you on your Mac" },
           "sound": "default", "thread-id": "agent-claude-code", "category": "AGENT_HELP",
           "interruption-level": "active", "relevance-score": 1 },
  "h": "<helpRequestId>" }
```
`interruption-level: time-sensitive` only if the user turns it on and the capability is present.

### 5.9 Security and privacy invariants

1. A link, a notification and an intent grant no authority; the phone must already be paired to the Mac named by the request.
2. Notification and APNs carry label and category only; the reason text travels sealed Mac to phone.
3. The lock is host-enforced and single; the agent's tool result or hook can never grant or extend control; agents cannot send input through PocketDesk.
4. Agent text is untrusted: plain text, capped, no links, no automatic actions from it.
5. Passwords are typed on the phone into the Mac directly; nothing passes through the model, tool result or log. `inspect_screen` stays a separate Mac-created grant, and App Review 5.1.2(i) (disclose and get permission before sharing personal data with third-party AI) is why that separation stays visible.
6. Release order on hand-back and abort: `releaseAll` input, release lock, then resume the gate.
7. Fail open for the gate when the Mac companion is unreachable; never claim "agent paused" unless the gate acknowledged a hold; Tier 0 labels itself cooperative.

### 5.10 Failure modes

| Failure | Behaviour |
|---|---|
| No phone registered / notifications denied | tool returns `no_phone_registered`; agent tells the user in chat |
| Mac offline or sharing off | `host_offline`; no alert (nothing to take over) |
| APNs 410 / bad token | delete token, state `notify_failed`, one retry to other tokens |
| Alert storm | collapse id, dedupe per session, per-room cap 6 per hour, then `rate_limited` |
| Old or forwarded link | "This request has ended" or "different Mac"; web viewer needs its own enrolment |
| Phone drops mid-takeover | input released at once; lock kept 60 s; then auto hand-back with a "phone disconnected" note |
| Mac Stop Sharing or revoke | lock aborted; gate resumes; phone shows ended |
| Hook cannot reach the Mac | fail open |
| Hook times out | Claude Code proceeds (documented); prevented by TTL < timeout and logged |
| Several agents | queue oldest first; one human lock; banner names the agent |
| Agent ignores the instruction (Tier 0) | UI never says "paused"; only Tier 1 with a gate acknowledgement does |

### 5.11 Tests and receipts

Automated: state machine and timers with an injected clock; rate limits; token registry file permissions; mock APNs HTTP/2 server for headers and payload size; hook gate hold for a fixed interval and resume with context; lock TTL less than hook timeout invariant; replay, expiry, wrong-room and revoke-mid-flow rejects; kill the host mid-lock.
Device: real APNs sandbox and production (TestFlight); universal link taps from Claude iOS, ChatGPT iOS, Messages, Notes and Safari; app installed and absent; notification while another session is active; airplane-mode drop mid-takeover.
Measured (report, do not promise): alert-to-banner time, tap-to-first-frame on direct and forced relay, release-to-resume time.
Receipts to file: APNs response ids, gate hold log, lock transitions, screenshots of both negative tests; the demo video is separate from acceptance.

### 5.12 Work packages (planning estimates, engineer-days)

| WP | Content | Days | Depends on |
|---|---|---|---|
| 1 | Server: help-request store, state machine, MCP tools, scope, rate limits, tests | 4-6 | OAuth, public origin |
| 2 | Server push: APNs client, token registry over `/signal`, AASA and `/open`, mock APNs tests (+1 day Bun HTTP/2 spike) | 3-5 | APNs key, capabilities |
| 3 | Mac host: local bridge, `pocketdeskctl`, lock and banner, prefs, wizard, redaction | 5-8 | WP1 contract |
| 4 | Phone: registrar, delegate, router, sheet, hand-back pill, test alert, tests | 5-7 | WP2 |
| 5 | Hook pack and skill text (Claude Code, Cowork, Codex), docs | 3-5 | WP3 |
| 6 | Security review and race/negative tests | 4-6 | all |
| Total | | **24-37**, about 3 calendar weeks with parallel workers | public endpoint about 19 Oct |

**Schedule.** 5 Oct human portal steps (APNs key; Push, Associated Domains, optional Time Sensitive on the App ID; domain); 12 Oct spikes finished (section 7); 19 Oct public endpoint plus AASA live, WP1-2 done; 26 Oct WP3-5 integrated, first real demo; 2 Nov go/no-go with receipts; 3 Nov submit; 17 Nov launch. This competes with the P0 engine and relay work for the same people: if P0 slips, cut in the order given in 0.1.

---

## 6. After launch (proposed order)

1.1 (December): PiP with Mac audio, crop-to-region PiP, window-strip mini map, Live Activity for help requests, Pencil squeeze mapping, repositionable controls. 1.2: embedded status card (MCP App) in Claude, indirect Scribble over remote fields, external-display scene (iOS 27), Duo arrangement layout. Later: Codex owned-runtime adapter, Claude Channels resume (when out of research preview), Pencil pressure/tilt, ChatGPT plugin submission.

---

## 7. Spikes and open questions (with pass criteria)

| ID | Question | Method | Pass | Owner |
|---|---|---|---|---|
| S-PiP-1/2/3/4 | Section 1.6 | real iPhone, 10 min soak | S-PiP-1 or -2 stable and defensible to App Review | phone |
| S-LINK-1 | Does a tapped universal link in Claude iOS, ChatGPT iOS (web-search or plugin reply), Messages and Notes open the app? Custom connector modal behaviour | one test connector, real phones | opens app on at least Claude iOS and Messages; document the rest | phone + server |
| S-LINK-2 | Widget `ui/open-link` from a custom Claude connector: modal text and result | tiny MCP App | works with one extra tap | server |
| S-EMB-1 | Live WebRTC receive inside Claude iOS WKWebView (view-only, fullscreen) | tiny page with `connectDomains` and `ui.domain` | media flows, touch and keyboard focus measured | server |
| S-HOOK-1 | Cowork: do plugin hooks run on the host with `127.0.0.1` reachable? | plugin with a logging hook | hook log appears on host | agent |
| S-HOOK-2 | Claude Code `PreToolUse` hold of 3 min plus subagent and bypass mode | scripted session | tool call waits; resumes with context; timeout behaviour as documented | agent |
| S-HOOK-3 | Codex hook decision schema and desktop app behaviour | scripted session | gate holds in desktop app and CLI | agent |
| S-APNS-1 | Bun HTTP/2 to APNs, token refresh, collapse id | sandbox token | 200 with `apns-id`; fallback chosen if not | server |
| S-KEY-1 | iPad hardware keyboard: Esc, delete repeat, reserved-shortcut list, `prefersPointerLocked` in Stage Manager window | borrowed iPad + keyboard + mouse | documented behaviour table | phone |
| S-WB-1 | Workbench teardown T1-T8 (section 1.5) | free tier | numbers recorded | benchmark |
| Decision | Add Mac audio forwarding to scope (enables honest `audio` mode, PiP, and is a user-visible feature)? | owner | yes/no | product |
| Decision | Domain name for the public origin and AASA | owner | chosen | product |

---

## 8. Sources (all read 28 September 2026 unless noted)

**Apple.** [PiP for video calls](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls); [PiP in a custom player](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player); [AVPictureInPictureController](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller); [ContentSource](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class); [playback delegate](https://developer.apple.com/documentation/avkit/avpictureinpicturesamplebufferplaybackdelegate); [video-call view controller](https://developer.apple.com/documentation/avkit/avpictureinpicturevideocallviewcontroller); [media playback config](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback); [WWDC21 10290](https://developer.apple.com/videos/play/wwdc2021/10290/); [background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time); [App Review Guidelines, updated 8 June 2026](https://developer.apple.com/app-store/review/guidelines/) (2.5.4, 2.5.16, 4.2.7, 4.5.3, 4.5.4, 5.1.2(i)); [prefersPointerLocked](https://developer.apple.com/documentation/uikit/uiviewcontroller/preferspointerlocked); [UIPointerLockState](https://developer.apple.com/documentation/uikit/uipointerlockstate); [GCMouseInput](https://developer.apple.com/documentation/gamecontroller/gcmouseinput); [GCKeyboard](https://developer.apple.com/documentation/gamecontroller/gckeyboard); [wantsPriorityOverSystemBehavior](https://developer.apple.com/documentation/uikit/uikeycommand/wantspriorityoversystembehavior); [UIEvent.ButtonMask](https://developer.apple.com/documentation/uikit/uievent/buttonmask-swift.struct); [UIPointerStyle.hidden()](https://developer.apple.com/documentation/uikit/uipointerstyle/hidden()); [UIHoverGestureRecognizer](https://developer.apple.com/documentation/uikit/uihovergesturerecognizer); [allowedScrollTypesMask](https://developer.apple.com/documentation/uikit/uipangesturerecognizer/allowedscrolltypesmask); [UIScribbleInteraction](https://developer.apple.com/documentation/uikit/uiscribbleinteraction); [UIIndirectScribbleInteraction](https://developer.apple.com/documentation/uikit/uiindirectscribbleinteraction-1nfjm); [Customizing Scribble](https://developer.apple.com/documentation/pencilkit/customizing-scribble-with-interactions); [UIPencilInteraction](https://developer.apple.com/documentation/uikit/uipencilinteraction); [connected displays](https://developer.apple.com/documentation/uikit/presenting-content-on-a-connected-display); [iOS and iPadOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes); [Apple releases](https://developer.apple.com/news/releases/); [iPhone Duo](https://www.apple.com/iphone-duo/), [HIG Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Preparing for Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), [tech talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/); [universal links](https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content); [associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains); [ActivityKit push](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications); [Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities); [HIG Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities); [APNs send](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns), [payload](https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification), [token auth](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns), [time sensitive](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive), [actionable notifications](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types), [permission](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications); [PushKit and CallKit](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit).

**MCP, Anthropic, OpenAI.** [MCP Apps overview](https://modelcontextprotocol.io/extensions/apps/overview); [MCP Apps spec 2026-01-26](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx); [extension client matrix](https://modelcontextprotocol.io/extensions/client-matrix); [elicitation (latest)](https://modelcontextprotocol.io/specification/latest/client/elicitation); Claude: [interactive connectors](https://support.claude.com/en/articles/13454812-use-interactive-connectors-in-claude), [custom connectors, 11 Aug 2026](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp), [build an MCP server](https://claude.com/docs/connectors/building), [MCP Apps getting started](https://claude.com/docs/connectors/building/mcp-apps/getting-started), [design guidelines](https://claude.com/docs/connectors/building/mcp-apps/design-guidelines), [external links](https://claude.com/docs/connectors/building/mcp-apps/external-links), [troubleshooting](https://claude.com/docs/connectors/building/mcp-apps/troubleshooting), [directory vs custom](https://claude.com/docs/connectors/building/directory-vs-custom), [plugin platform support](https://claude.com/docs/plugins/platform-support); Claude Code: [hooks](https://code.claude.com/docs/en/hooks), [mobile](https://code.claude.com/docs/en/mobile), [Remote Control](https://code.claude.com/docs/en/remote-control), [Channels](https://code.claude.com/docs/en/channels), [Channels reference](https://code.claude.com/docs/en/channels-reference), [MCP](https://code.claude.com/docs/en/mcp); [Dispatch](https://support.claude.com/en/articles/13947068-assign-tasks-from-anywhere-in-claude-cowork); [claude-code #42693](https://github.com/anthropics/claude-code/issues/42693). OpenAI: [ChatGPT UI](https://developers.openai.com/plugins/build/chatgpt-ui), [UI guidelines](https://developers.openai.com/plugins/concepts/ui-guidelines), [developer mode](https://developers.openai.com/api/docs/guides/developer-mode), [connect ChatGPT](https://developers.openai.com/plugins/deploy/connect-chatgpt), [plugin surfaces](https://learn.chatgpt.com/docs/plugins), [Codex hooks](https://learn.chatgpt.com/docs/hooks), [Codex config](https://learn.chatgpt.com/docs/config-file/config-advanced), [Codex app-server](https://learn.chatgpt.com/docs/app-server), [Codex in ChatGPT mobile, 9to5Mac 14 May 2026](https://9to5mac.com/2026/05/14/openai-brings-codex-control-to-chatgpt-for-iphone-and-android/), [community thread, Aug 2026](https://community.openai.com/t/widgets-are-not-loading-in-the-chatgpt-mobile-apps-for-launched-apps-plugins/1388831). Context7 `/modelcontextprotocol/ext-apps` for `registerAppTool`, `registerAppResource`, app-only tool visibility, `requestDisplayMode`.

**Astropad.** [Product page](https://astropad.com/product/workbench/); [1.3 release notes](https://astropad.com/blog/workbench-1-3/); [App Store page and version history](https://apps.apple.com/us/app/astropad-workbench/id6758788573); [9to5Mac launch, 8 Apr](https://9to5mac.com/2026/04/08/astropad-unveils-workbench-for-mac-remote-desktop-made-for-the-ai-era/); [9to5Mac 1.3, 19 Aug](https://9to5mac.com/2026/08/19/astropad-workbench-1-3-adds-faster-streaming-privacy-curtain-and-more/); [MacRumors](https://www.macrumors.com/2026/04/08/astropad-workbench-app/); [MacStories, 5 May](https://www.macstories.net/reviews/astropad-workbench-rethinks-remote-mac-control-for-ai-agents/); help articles: [mini map](https://support.astropad.com/en/articles/14022295-workbench-mini-map), [mouse, keyboard, input](https://support.astropad.com/en/articles/14025802-mouse-keyboard-and-input-in-workbench), [Apple Pencil](https://support.astropad.com/en/articles/14011069-apple-pencil-input-with-workbench), [iPad shortcut mapping](https://support.astropad.com/en/articles/16448910-ipad-shortcut-mapping); [LIQUID](https://astropad.com/blog/liquid/); App Store customer-review feed (US, AU storefronts).

**Third-party (lower confidence).** [Fora Soft PiP guide](https://www.forasoft.com/blog/article/picture-in-picture-mode-on-ios-implementation-and-peculiarities-1662); [Zoom Video SDK PiP](https://godevelopers.zoom.us/blog/video-sdk-ios-picture-in-picture/); [meowdisplay PR 15](https://github.com/raiseCatError/meowdisplay/pull/15); [Moonlight iOS issue 686](https://github.com/moonlight-stream/moonlight-ios/issues/686); [iOSSH issue 39](https://github.com/m96-chan/iOSSH/issues/39); [Apple forum thread 739333](https://developer.apple.com/forums/thread/739333).

**Repo.** `PRODUCT.md`; `Docs/research/2026-09-28/{PHONE-UX,AGENT-INTEGRATION,BUILD-PRIORITIES}.md`; `Docs/BENCHMARK-WORKBENCH-2026-09-28.md`; `Docs/IDEA-VALIDATION-2026-09-13.md`; `Docs/AGENT-HANDOFF.md`; `Docs/APPLE-INTERACTION-RESEARCH-2026-09-28.md`; `Docs/REMOTE-PROTOCOL.md`; `Server/src/mcp/*`, `Server/src/browser/{service,mcp-host-bridge}.ts`, `Server/src/server.ts`; `RemotePhone/RemotePhoneApp.swift`, `RemotePhone/NativeSessionView.swift`; `RemoteShared/Pairing.swift`; `project.yml`.

## Appendix: corrections to earlier repo statements

- `AGENT-INTEGRATION.md` says `server.ts` has no MCP route: true for the native signaling server, but the MCP app is mounted by `Server/src/browser/service.ts` when an exact origin and `POCKETDESK_MCP_PRIVATE_DIR` are set. Tests of the MCP module still do not prove a deployed connector.
- `BUILD-PRIORITIES.md` lists PiP as a P2 bounded prototype. Refined here: it is a 3-day spike plus an App Review decision, with multitasking survival split out as a cheap P1.
- `AGENT-INTEGRATION.md` centres a Codex app-server adapter for take-over. A hook-based gate is smaller, uses documented public APIs in Claude Code, Cowork and Codex (desktop app, IDE, CLI), and avoids owning a child process; the adapter stays as a later tier.
- `BENCHMARK-WORKBENCH-2026-09-28.md` row "Marketed for monitoring agents; in practice remote desktop plus dictation" is confirmed by vendor and press pages (3.8), with PiP now also shipping.
