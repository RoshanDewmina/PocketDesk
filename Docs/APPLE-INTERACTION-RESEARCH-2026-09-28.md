# PocketDesk: Apple interaction research

Checked 28 September 2026. Official Apple documentation and source inspection inform the recommendations; no new native interaction, haptic or performance tests were performed. Historical Apple event documentation is identified below. Exact signatures must be checked against the implementation SDK before use.

## Follow-up review: cursor feasibility and native control references

The linked chat was read and current source was spot-checked. `RemoteInputDriver.swift` obtains pointer position through `CGEvent(source: nil)?.location`, truncates scroll deltas into Int32 and counts clicks using host arrival time. `TrackpadSurface.swift` uses separate pan/tap recognizers; the phone applies 1.6× movement gain. Capture enables `showsCursor`; the data channel is ordered. These observations confirm the existing gaps, not runtime behavior. Xcode 27.0 (27A266a), iPhoneOS SDK 27.0 and remote-target 26.0 deployment settings were rechecked without building or launching the app.

Apple's [NSCursor.currentSystem](https://developer.apple.com/documentation/appkit/nscursor/currentsystem) describes a cross-application cursor image/hotspot, but its rendered documentation marks it deprecated. The installed SDK's `AppKit.framework/Headers/NSCursor.h`, lines 155–156, additionally warns of future nil results and points toward captured cursor inclusion. The fetched Markdown metadata lists a macOS availability endpoint of 27.0; do not interpret that alone as a runtime experiment or exact removal date. [NSCursor.current](https://developer.apple.com/documentation/appkit/nscursor/current) is application-local. The distinction prevents both an incorrect claim that no public API ever existed and an unsafe assumption that cross-app cursor images are a dependable new foundation.

The inspected `SCStream.h` declaration for [showsCursor](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/showscursor) controls inclusion and defaults to visible. Its frame-info declarations do not establish a separate complete cursor shape/visibility contract. Recommendation: resolve cursor feasibility in S0, retain captured cursor when unproven, and coordinate composition transitions with displayed video. No public replacement satisfying every pointer requirement was established here. This is an explicit unresolved engineering dependency.

Re-fetched public [double-click interval](https://developer.apple.com/documentation/appkit/nsevent/doubleclickinterval) and [momentum phase](https://developer.apple.com/documentation/appkit/nsevent/momentumphase) Markdown confirm system timing and momentum-target semantics. Those contracts inform future experiments; injected behavior is still untested. Apple-hosted Markdown was read via HTTPS when the web reader failed to render it; no TLS checks were disabled.

Apple's [Duo preparation talk](https://developer.apple.com/videos/play/tech-talks/111461/) and [Duo developer resources](https://developer.apple.com/iphone-duo/) were revisited. The SDK27.1 full-inner-display and asymmetric-safe-area guidance supports the existing staged plan. The talk's transcript contains differing orientation phrasing at its inner-display discussion and later fullscreen discussion; this plan deliberately depends on actual bounds and size classes, not an asserted orientation exemption. Verify exact behavior in the compatible future simulator. [UIKit lifecycle guidance](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle?changes=_4) states the SDK27 scene requirement. The current phone entry point already uses SwiftUI App/WindowGroup and scenePhase; inspect generated configuration and exercise lifecycle rather than assume a UIKit migration is automatically needed.

Mobbin returned static screens which were visually inspected: [Freeform canvas](https://mobbin.com/screens/46af0374-1ad1-4caa-a020-d7753d532f34), [Evernote sketch](https://mobbin.com/screens/866d750f-16ce-4ff4-937d-9dc196b88433) and [Google Photos viewer](https://mobbin.com/screens/f5e491ed-bb44-4648-8aa0-a5d526daa9b4). They support small separated action groups, an explicit mode exit and overflow for secondary actions. They do not prove auto-hide, gesture timing, hit-target dimensions or remote interaction quality. Only canonical reference links are retained; no preview images are embedded as design assets.

Applied skills: Build iOS Apps' SwiftUI UI Patterns for ownership/composition and Paperwash for restrained native color treatment. No HTML style framework, new app, toolchain installation or performance run was introduced. Build/run/debug and performance skills are appropriate for the later authorized implementation, after its contracts settle.

## What to borrow from the Mac trackpad

Apple documents one-finger tap-click, two-finger secondary click, two-finger scroll, pinch zoom and two-finger double-tap Smart Zoom. Tracking speed, natural scrolling and gesture preferences are configurable. These establish familiar behaviors, not a single unchangeable gesture vocabulary. Our first version should prioritize pointer, click, secondary click, drag and scroll. Keep local viewport zoom explicit in its meaning. Defer Smart Zoom and multi-finger system gestures until they can coexist without ambiguity. [Mac gestures](https://support.apple.com/en-us/102482), [Trackpad settings](https://support.apple.com/en-gb/guide/mac-help/mchlp1226/mac)

Mac accessibility settings offer multiple dragging styles, including double-tap-and-hold with optional drag lock and three-finger dragging. These are useful references for reducing finger strain. For PocketDesk, start with release-to-drop plus an accessible Hold/Release alternative; defer persistent drag lock because a hidden held state is especially confusing remotely. [Pointer Control settings](https://support.apple.com/en-au/guide/mac-help/-unac899/mac), [Three-finger drag](https://support.apple.com/en-us/102341)

Force Touch hardware measures pressure and supplies tactile feedback. An iPhone tap with vibration can feel crisp, but cannot be described as pressure-sensitive Force Click. Avoid inferring force from contact area or asking users to press harder. The supported touch grammar must work without force sensing. [Force Click and haptics](https://support.apple.com/en-us/102309)

Apple's HIG favors familiar, responsive gestures with feedback and alternative ways to perform essential actions. A short first-use demonstration should show a finger moving anywhere while the remote pointer moves relatively: taps click at the pointer. Make click, secondary click, drag/release and Fit available through native controls as well. [Gestures HIG](https://developer.apple.com/design/human-interface-guidelines/gestures/), [Pointing devices HIG](https://developer.apple.com/design/human-interface-guidelines/pointing-devices)

## Public timing and input tools

| API/source | Verified behavior | Proposed use |
| --- | --- | --- |
| [NSEvent.doubleClickInterval](https://developer.apple.com/documentation/appkit/nsevent/doubleclickinterval) | Returns the system's maximum interval between matching double clicks; public since macOS 10.6 | Read host preference and preserve click counts/order; do not invent a universal Apple threshold |
| [UIGestureRecognizer.require(toFail:)](https://developer.apple.com/documentation/uikit/uigesturerecognizer/require(tofail:)) | Failure dependencies can delay recognition while another gesture remains possible | Avoid delaying every remote single click behind a double-tap recognizer; design ordinary first/second mouse clicks explicitly |
| [UIPanGestureRecognizer](https://developer.apple.com/documentation/uikit/uipangesturerecognizer) | Translation/velocity and touch-count controls | Single owner for pointer versus scroll; classify pinch separately, lock ownership after recognition |
| [touchesCancelled](https://developer.apple.com/documentation/uikit/uiresponder/touchescancelled(_:with:)) | Interruption can cancel touches | Cancel candidates and momentum, release held input; host lease is the disconnected fallback |
| [coalescedTouches](https://developer.apple.com/documentation/uikit/uievent/coalescedtouches(for:)) | Additional chronological samples include a copy of the main reported touch; public since iOS 9 | If used, do not count the main touch twice or send every sample as its own network packet |
| [CADisplayLink](https://developer.apple.com/documentation/quartzcore/cadisplaylink) | Synchronizes callbacks with display updates; requested and actual frame rates can differ | Measure pacing, isolate visual updates; do not assume a constant 60/120Hz or add a frame of command latency unnecessarily |

Apple does not publish a complete portable recipe for its pointer acceleration, tap movement tolerance or recognition heuristics in the reviewed material. Define testable PocketDesk settings and label them as our choices. Start with ordinary UIKit events; add coalesced input only if measured accuracy justifies its processing cost.

## Scroll behavior needs an explicit contract

AppKit distinguishes direct scroll phases from momentum phases. Momentum events stay associated with the view where the flick began. This explains why a scroll should not suddenly move into another window when the pointer moves. Core Graphics exposes scroll phase/momentum fields, but their existence does not prove our injection reproduces native behavior in every app. Test actual results with supported APIs. [NSEvent momentumPhase](https://developer.apple.com/documentation/appkit/nsevent/momentumphase), [CGEventField](https://developer.apple.com/documentation/coregraphics/cgeventfield)

Precise trackpad deltas and coarse wheel deltas need different handling. Keep fractional continuous movement and distinguish pixel-like motion from wheel steps. Do not convert a slow precision scroll into repeated large notches. [hasPreciseScrollingDeltas](https://developer.apple.com/documentation/appkit/nsevent/hasprecisescrollingdeltas)

The archived Cocoa event guide describes gesture sequences, cancellation and scroll targeting. It is useful conceptual background, not a current iOS injection specification. Its old three-finger swipe conventions must not override present platform behavior. [Archived trackpad event guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html)

PocketDesk proposal: natural direction applied once; one momentum owner; immediately interrupt generated momentum on new input, stale state or cancellation; preserve diagonal scrolling. Do not add momentum to hardware events before verifying whether the OS already supplies it. Do not let edge-follow move the viewport during remote scrolling. All of these require physical trials.

## Haptic design

For click acknowledgement, compare a prepared UIImpactFeedbackGenerator with SwiftUI sensoryFeedback on the real iPhone. Standard feedback is the first choice; a custom persistent Core Haptics engine is unnecessary until a concrete gap appears. Use one short cue for an accepted local click, with restrained optional pickup/drop feedback. No repeated pulse for ordinary movement. [UIKit impact generator](https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator), [SwiftUI sensoryFeedback](https://developer.apple.com/documentation/swiftui/sensoryfeedback), [Playing haptics HIG](https://developer.apple.com/design/human-interface-guidelines/playing-haptics)

Feedback must describe the right event. A local pulse cannot certify remote execution. Do not pulse on rejected input; show connection/view-only state clearly. Provide a user preference and visual acknowledgement. Apple explicitly identifies iPad among devices without device haptic playback: capability checks and visual fallback are required. Accessory-specific feedback such as Pencil is a separate capability. [Haptic preparation and support](https://developer.apple.com/documentation/corehaptics/preparing-your-app-to-play-haptics), [Feedback HIG](https://developer.apple.com/design/human-interface-guidelines/feedback)

## Hardware pointer and keyboard paths

UIKit distinguishes indirect pointer events, scroll events and transform gestures. Continuous scrolling includes trackpads/Magic Mouse, while wheel mice can produce discrete scroll. Enable allowedScrollTypesMask where needed and filter direct versus indirect input deliberately. Do not assume numberOfTouches is positive for hardware-driven recognizers. Apple’s WWDC session also explains event buttonMask/modifierFlags and inspecting incoming events during shouldReceive. [Handle trackpad and mouse input](https://developer.apple.com/videos/play/wwdc2020/10094/), [TN3210 iPhone Mirroring](https://developer.apple.com/documentation/technotes/tn3210-optimizing-your-app-for-iphone-mirroring)

Recommended default: UIKit's processed positional pointer maps through the inverse viewport transform; touchscreen motion remains relative. Never process both lanes for the same event. GCMouse raw deltas are a distinct option without the usual sensitivity processing; do not combine them with hover positions or apply the finger gain curve twice. [GCMouseInput](https://developer.apple.com/documentation/gamecontroller/gcmouseinput), [GCMouseMoved](https://developer.apple.com/documentation/gamecontroller/gcmousemoved)

Pointer locking is a preference with scene/foreground restrictions, not guaranteed ownership. Observe actual lock state and provide ordinary positional input for resizable windows. Preserve an obvious exit and release held input on lock loss if capture mode is introduced later. [prefersPointerLocked](https://developer.apple.com/documentation/uikit/uiviewcontroller/preferspointerlocked)

iPad owns system navigation gestures. Do not promise to forward every Mac three/four-finger command; remote shortcut buttons are a more dependable fallback. [iPad trackpad gestures](https://support.apple.com/en-gb/guide/ipad/ipad66ce6358/26/ipados/26)

Separate committed text from physical key identity/down/up/modifier state. Marked text from CJK/IME composition is provisional; avoid sending it repeatedly as committed text. Deduplicate hardware text and raw-key paths. Test accents, dead keys, emoji, dictation, repeated keys and non-US layouts. [Hardware keyboard support](https://developer.apple.com/videos/play/wwdc2020/10109/), [UITextInput](https://developer.apple.com/documentation/uikit/uitextinput)

## iOS 27, iPadOS and Duo

Apple's live release register distinguishes stable platform releases from newer beta toolchains. Xcode 27.0/SDK 27.0 is installed locally; a newer beta listed online is not installed and is not automatically the appropriate release toolchain. Recheck before implementation/submission. [Apple releases](https://developer.apple.com/news/releases/)

iPhone Duo is an officially announced product with an October 23 launch listed by Apple. Its hardware supports high refresh rates, but this does not establish PocketDesk delivery rate, latency, haptic feel or battery use. Device availability should be rechecked before promising physical testing. [Duo product page](https://www.apple.com/iphone-duo/), [Technical specifications](https://www.apple.com/iphone-duo/specs/)

Apple's preparation talk specifies iOS 27.1 SDK builds for full inner-display use, size-class-based adaptation, local scene bounds and asymmetric safe areas. It introduces reserved regions and describes Device Hub pose testing. Outer and inner displays can give different available space without changing the app into an iPad app. Keep runtime availability checks for new APIs; a build SDK and minimum supported OS are separate decisions. [Prepare your app for Duo](https://developer.apple.com/videos/play/tech-talks/111461/)

Reserved-region queries and ArrangementView/UIArrangementViewController are candidates for specialized folded layouts. The first PocketDesk version should use standard containers and a single unobstructed canvas; custom tabletop or multi-display experiences remain optional. Keep task state through folding and avoid constant rearrangement. [Adaptive layout talk](https://developer.apple.com/videos/play/tech-talks/111463/), [Duo HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)

Apple documents changed UIRequiresFullScreen behavior and scene lifecycle requirements in OS/SDK 27. A fullscreen declaration is not a general escape from dynamic resizing. Inspect actual target lifecycle and scene configuration, and test the same model under multiple available window sizes. [TN3192](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key), [Scene lifecycle](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle)

Ordinary interactive iPad windows on external displays are distinct from a custom dedicated external-display scene. Support the former through correct scene geometry; defer a special phone-controller/TV-view split. [Connected displays](https://developer.apple.com/documentation/uikit/presenting-content-on-a-connected-display), [iPadOS design](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados)

Pencil input/hover and accessory gestures are hardware-dependent. Precise pointing can be explored after ordinary touch and hardware pointer paths work. Do not promise pressure-sensitive creative-tablet emulation or infer accessory support from device family. [Apple Pencil](https://developer.apple.com/documentation/applepencil), [Pencil hover](https://developer.apple.com/documentation/uikit/adopting-hover-support-for-apple-pencil)

## Physical acceptance checklist

1. One-finger precision and fast travel; no jump after lifting/repositioning; pointer stops immediately.
2. Tap jitter, double-click, tap-and-hold drag, secondary click with staggered finger arrival; no duplicate click.
3. Horizontal/vertical/diagonal scroll, reversing and stopping on a marked line; pinch does not scroll the Mac.
4. Disconnect, revoked control, background, phone lock and system interruption mid-drag; host lease releases safely.
5. Rotation, keyboard, live iPad resize and Duo pose change; preserve viewed context while canceling stale gesture mappings.
6. Physical keyboard/trackpad/wheel mouse; no doubled acceleration, momentum, text or pointer.
7. Native control accessibility, Dynamic Type, contrast, Reduce Motion/Transparency, gesture alternatives. Pixel video does not automatically expose remote accessibility semantics. [Accessibility testing](https://developer.apple.com/documentation/accessibility/performing-accessibility-testing-for-your-app)
8. Physical timings distinguish local cue, input injection and actual remote visual response. Simulator/Mirroring output cannot validate native tactile feel or end-to-end latency.

No exact private Apple acceleration curve, universal click threshold, equivalent Force Touch implementation, physical Duo validation or new performance result was established by this research.
