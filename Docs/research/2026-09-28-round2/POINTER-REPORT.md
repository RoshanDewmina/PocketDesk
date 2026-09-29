# Phone-drawn pointer — design, evidence and physical check

28 September 2026 · Claude worktree branch, rebased on `pocketdesk-remote-chat`. Engineering report, subordinate to [PRODUCT.md](../../../PRODUCT.md). It implements the "authoritative larger pointer" P1 item from [BUILD-PRIORITIES](../2026-09-28/BUILD-PRIORITIES.md) and the phone-rendered option recommended in [CURSOR-RESEARCH](../../CURSOR-RESEARCH-2026-09-28.md). **Compiled and automatically tested; not yet used on a physical iPhone and Mac.**

## What changed for the user

- The Mac pointer is drawn **by the iPhone** as crisp vector artwork at a fixed on-screen size, so it stays readable at Fit and at every zoom. Controls → Feel → **Pointer size**: Small, **Medium (default)**, Large, Extra Large (arrow height 26 / 34 / 44 / 56 pt). Medium is about five times the streamed macOS arrow at Fit on a 1440-point display.
- It moves the instant the finger moves (predicted locally), then quietly agrees with the Mac.
- It changes shape with the Mac: arrow, I-beam, pointing hand, open/closed hand, crosshair, column/row and diagonal resize, not-allowed, context-menu, copy, link, zoom in/out. Anything unrecognised is drawn as the arrow.
- Once the phone draws it, the Mac stops putting its own cursor into the video, so there is one pointer. Older phones, the browser viewer and any failure keep the streamed cursor.
- The locator ring is gone. No highlight was added: nothing tested well enough to justify one without a device.

Screenshots from the iPhone 17 simulator (offline layout fixture): `~/Downloads/pocketdesk-pointer-medium-fit-2026-09-28.png`, `…-extra-large-fit-…png`, `…-glyph-gallery-…png`.

## Design

### Protocol (backward compatible)

One optional envelope, `RemoteAction.pointerSync: PointerSync?` (`RemoteShared/PointerTelemetry.swift`), plus one new action, `pointer`. Unknown JSON keys are ignored by every existing decoder, so the envelope is invisible to old peers. An old phone *would* end the session on an unknown action, so the host sends `pointer` **only** to a phone that advertised support.

| Direction · action | Envelope fields | Meaning |
|---|---|---|
| Host → phone · `capture` (every 0.25 s and on change) | `version`, `videoCursor` | Host supports v1; whether video frames currently contain the cursor |
| Phone → host · `heartbeat` (every 0.25 s) | `version`, `overlay` | Phone supports v1; `overlay: true` = "I am drawing it from fresh telemetry, you may hide yours" |
| Phone → host · `move` | `move` (ordinal, per epoch) | Lets the host acknowledge exactly which deltas it has applied |
| Host → phone · `pointer` (≤ 60 Hz, keep-alive 4 Hz) | `x`, `y` (capture-display logical points), `visible`, `shape`, `applied`, `sample`, `videoCursor` | Authoritative sample |

Validation is strict per direction (letters-only shape ≤ 32 bytes, finite coordinates 0…20000, positive ordinals, no stray fields); an unknown shape name decodes as `.unknown` rather than failing, so a newer host can never end an older phone's session. A 64-character-session `pointer` packet is under 400 bytes (below 24 KB/s at the 60 Hz ceiling, reached only while the pointer moves; 4 keep-alives a second otherwise). `ControlProtocol.swift` has exactly two added lines (the property and one early-return in `validate()`); everything else lives in new files to keep merges small.

### Negotiation and the "never missing" rule

1. Host advertises in `capture`. 2. Phone heartbeats carry the envelope with `overlay: false`. 3. Host starts streaming samples. 4. Only after the phone has *received fresh samples* does it send `overlay: true`. 5. Host hides the cursor via `SCStreamConfiguration.showsCursor = false`.

`RemoteCapture.cursorInVideo` is deliberately asymmetric: it becomes **false as soon as hiding is requested** and **true only after showing is applied**. The phone draws whenever `videoCursor` is false and keeps drawing for 0.3 s after it turns true (frames without the cursor may still be in flight). Transitions therefore produce a brief duplicate, never a gap. A failed `updateConfiguration` rolls the request back, reports the cursor as present, and starts a 2 s cooldown before any retry.

Fallbacks to the streamed cursor: phone telemetry older than 0.8 s → phone sends `overlay: false`; no heartbeat envelope for 1 s → host stops streaming and shows the cursor; every new capture session, display change or reconnect starts with the cursor shown. The simulated handshake test runs both state machines through a delayed channel, a 1.5 s telemetry outage and recovery, and asserts at every 4 ms step that the pointer is drawn or in the video.

Compatibility matrix: new phone + old host → no envelope in `capture`, moves stay untagged, the old probe-based edge-follow keeps working, streamed cursor. Old phone + new host → never advertises, never receives `pointer`, streamed cursor. Browser viewer → separate `RemoteCapture` instance that never hides the cursor.

### Host sampling (`RemoteHost/HostPointerTelemetry.swift`)

A 60 Hz main-run-loop timer in common modes (keeps running while the menu-bar menu is open) reads `CGEvent(source: nil).location`, maps it into the captured display (off-display → `visible: false`), and sends only on change ≥ 1/64 pt, a shape/visibility/ack change, or the 0.25 s keep-alive. For 50 ms after the host injects a phone move it reports the injected point, bridging any lag before WindowServer updates the location. Every processed `move` in the current epoch is acknowledged, accepted or not, so a rejected delta can never stay "pending" on the phone.

### Cursor shape without private API (`RemoteHost/HostCursorShape.swift`)

- **Primary:** `NSCursor.currentSystem`. In the installed macOS 27 SDK it is `API_TO_BE_DEPRECATED` with the note "This property will always be nil in a future version of macOS"; Swift emits no warning, and on this Mac (macOS 27.0) it returns the live cursor. Its image is matched against ~50 AppKit standard cursors (including macOS 15+ `columnResize`/`rowResize`/`frameResize(position:directions:)`) by aspect, normalised hot spot and a 64×64 alpha silhouette, with a three-level tone mask only to break ties between identical silhouettes (copy vs not-allowed badge). Enlarged and recoloured accessibility pointers still classify. Measured cost here: 0.44 ms per sample, sampled at 20 Hz while moving and 4 Hz idle (≈ 0.9 % / 0.2 % of one core).
- **Fallback when it returns nil:** Accessibility hit-test under the pointer on a background queue, one query in flight, ≥ 150 ms apart, per-element 0.1 s messaging timeout (never the process-global one): editable text roles → I-beam, `AXLink` → pointing hand, splitter → resize, everything else → arrow. Requires the Accessibility grant the host already needs for control.
- **Rejected:** `CGSCurrentCursor` / SkyLight private calls (App Store 2.5.1), changing the user's global pointer size (see CURSOR-RESEARCH), `NSCursor.current` (in-process only).

### Phone prediction and reconciliation (`RemoteShared/PointerPrediction.swift`)

The host applies each relative move as an absolute `CGEvent` at `current + delta`, clamped to the display — no system acceleration — so prediction is exact in the normal case. The phone tags each move with an ordinal, applies it immediately, and on every sample replays the still-unacknowledged moves over the authoritative position with the **same per-step clamp** (a test drives the real `RemoteInputDriver` and requires identical output). Any residual difference — physical mouse, app warps, rejected or lost moves — is blended out with a 45 ms exponential correction (driven by a `CADisplayLink` only while a correction is visible); jumps over 64 points snap. Pointer motion publishes only on `PointerOverlayModel`, so the session view is not re-rendered at touch rate. Edge-follow now uses the predicted pointer (no round trip), throttled to 60 Hz and suppressed during drags; the probe path remains for older hosts.

### Rendering (`RemoteShared/PointerGlyph.swift`, `RemotePhone/PointerOverlay.swift`)

Glyphs are CoreGraphics paths in Mac-cursor points with the hot spot at the origin, drawn per layer as outline pass then body pass (so badges sit on the arrow), in a SwiftUI `Canvas` with a soft drop shadow. macOS conventions are kept (black arrow/I-beam with white outline; white hands with black outline). The same geometry renders on macOS for previews and tests.

## Apple APIs used (checked 28 Sep 2026)

| API | Evidence |
|---|---|
| [`SCStreamConfiguration.showsCursor`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/showscursor) | Docs: macOS 12.3+, visible by default, not deprecated |
| [`SCStream.updateConfiguration(_:)`](https://developer.apple.com/documentation/screencapturekit/scstream/updateconfiguration(_:completionhandler:)) | Docs: macOS 12.3+; does not list which properties apply live — live `showsCursor` toggling is **unverified on hardware** |
| [`NSCursor.currentSystem`](https://developer.apple.com/documentation/appkit/nscursor/currentsystem) | Docs page marks it deprecated (27.0) and recommends ScreenCaptureKit; SDK header is `API_TO_BE_DEPRECATED` and says it will return nil in future; works today (local probe) |
| `NSCursor.columnResize`, `rowResize`, `frameResize(position:directions:)`, `zoomIn`/`zoomOut` | macOS 27 SDK header and Swift interface: macOS 15+ |
| [`CGEvent.location`](https://developer.apple.com/documentation/coregraphics/cgevent/location), [`CGEvent(source:)`](https://developer.apple.com/documentation/coregraphics/cgevent/init(source:)) | Docs; same idiom the existing input driver already uses |
| [`AXUIElementCopyElementAtPosition`](https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition), [`AXUIElementSetMessagingTimeout`](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout) | Docs: system-wide element hit-tests by z-order; setting the timeout on the system-wide element is process-global, so it is set per element instead |
| SwiftUI `Canvas`, [`GraphicsContext` shadow](https://developer.apple.com/documentation/swiftui/graphicscontext/filter/shadow(color:radius:x:y:blendmode:options:)), [`CADisplayLink`](https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange) | Docs: iOS 15+ |

No private API, no global pointer-size change, no new permission.

## Evidence

| Level | Result |
|---|---|
| Build | Mac host (`PocketDeskRemoteHost`, unsigned), iPhone app for simulator, `RemoteCoreTests`: all succeed without new warnings |
| macOS core tests | 20 new (encoding/validation, legacy decoding, negotiation, simulated handshake, sampling, capture cursor-intent contract, prediction incl. driver-exact clamping, blending/snap, classifier incl. enlarged/recoloured/foreign images, glyph rendering). After rebasing on `a805290`: 179 executed, 0 failures, 1 pre-existing skip |
| iPhone unit tests | 5 new overlay-model tests covering a legacy host, drawing only after the host hides its cursor, instant local moves, the restore grace, epoch reset and hot-spot placement at every size. After rebase: 30 executed, 0 failures (iPhone 17 simulator, iOS 27.0) |
| iPhone UI tests | 2 new (size setting reachable and persistent across relaunch; glyph gallery), both passing. Existing layout suite: see below |
| Visual | Simulator screenshots confirm crisp glyphs and exact hot-spot placement at Medium and Extra Large in Fit |
| Local API probe | `currentSystem` non-nil on macOS 27.0 and pixel-identical to `NSCursor.arrow`; 0.44 ms per classified sample |
| **Not verified** | Live `showsCursor` switching mid-stream, real shape changes across apps, feel of prediction over Wi-Fi/cellular, host timer cost during a real session, duplicate/gap duration at transitions, physical readability |

**UI suite under load.** One sequential run of all 12 UI tests at load averages of 200–500: 8 passed. The 4 failures were then re-run one at a time: `testLandscapeControlsKeepZoomReachable` and `testKeyboardKeepsDeliberatelyTypedMultilineDraft` pass alone (the latter had dropped synthesized keystrokes, e.g. "PocDsk" for "PocketDesk", only under load); the pointer size test passes after its helper retries a dropped dock-reveal swipe; `testOfflineControlsPortraitLandscapeAndKeyboard` fails at `SessionLayoutTests.swift:159` (landscape "Double-click" tile not found) identically on the untouched upstream base build, so it is pre-existing. `testPictureQualityCanSwitchWithoutOpeningKeyboard`, which scrolls the Controls sheet past the new Pointer size row, passes.

**Flaky pre-existing test.** `SessionIntegrationTests.testHostKeepsRegisteredRoomWhenPhoneLeavesOrMediaDrops` (real WebRTC loopback + bun service, only `RemoteCoordinator`, untouched here) failed several times while the Mac's load average was 300–800. Alternating runs of the upstream base build and this branch's build failed once each out of three, so it is load-sensitive, not a regression. It passed in the final full run.

Debug-only launch arguments for offline checks: `--ui-layout-check --ui-pointer-preview` (one arrow) and `--ui-pointer-gallery` (every glyph).

## Open risks

1. `NSCursor.currentSystem` will return nil on a future macOS. The Accessibility fallback then provides only text/link/splitter shapes, and hit-testing Chromium/Electron apps can switch on their accessibility trees (CPU cost). Longer term, consider sending the actual cursor bitmap once per change (its image already carries 10× representations) if Apple keeps a public source.
2. Apps that hide the cursor while typing are not detected (no public API); the phone keeps showing it. Custom app cursors and the spinning wait cursor draw as the arrow.
3. `updateConfiguration` latency and first-frame behaviour when toggling `showsCursor` need hardware measurement; the protocol tolerates either order but the duplicate at a transition may be visible for a few frames.
4. If a host ever posts moves faster than WindowServer updates the location, the host itself loses motion; the phone will then blend backward slightly. Watch for "rubber-banding" on the physical check.
5. Tunables awaiting feel tests: sizes, 45 ms blend, 64-point snap, 0.8 s stale, 0.3 s restore grace, 2 s cooldown.
6. Merge surface: `ControlProtocol.swift` (2 lines), `HostModel.swift`, `RemoteCapture.swift` (cursor flag only; encoder/bitrate untouched), `RemoteInputDriver.swift` (`lastPoint` read access), phone model/session view, `project.yml` (one test source). Regenerate the project with `xcodegen` after merging.

## 29 September: first physical check, root causes and fixes

Roshan tried the branch on his iPhone 17 and reported that the pointer "jitters or just jumps around, very annoying or even unusable". Evidence: `~/Downloads/ScreenRecording_09-29-2026 07-40-54_1.MP4` (8.9 s, 1206×2622, 464 variable-rate frames at a nominal 60 fps, stats overlay on, Finder over a Monet desktop, view zoomed to about 1.4× Fit). The Mac was under a load average of 60–400 at the time (other agents building), the link was direct Wi-Fi with RTT 6–7 ms and 0 % loss, and the stream sat at 3–5 fps because the picture was static.

### Measurement

`bench/pointer-recording/track.py` extracts every frame (`ffmpeg -fps_mode passthrough`) and, with masked normalised cross-correlation in numpy, tracks two things per frame: the tip of the phone-drawn arrow (template from frame 161; score < 0.8 means "not on screen") and the Finder toolbar's view-button cluster (a static Mac feature, so its screen position is the picture's position). `analyze.py` prints missing runs, per-frame steps and a full table. Frame times come from `ffprobe -show_entries frame=pts_time`.

Results: the pointer is on screen in 357 of 464 frames. Excluding the last 65 frames (the tip sits on the picture's bottom edge below the tracked band, then Control Center opens), it vanishes five times: frames 3–11, 37–45 and 98–106 (150 ms each, all at the right edge) and 216–218, 241–250 (50 and 167 ms, at the left edge). The picture moves in 164 of 463 frame pairs, up to 60 px per 16.7 ms frame while the finger is still. Median on-screen pointer step while visible is 32 px per frame; 95 frames step more than 80 px.

### Root causes

1. **Pointer vanishes (≥130 ms): the glyph is drawn off screen, not hidden.** In run B the tip moves right at ~135 px/frame, lands exactly on the follow inset line (x = 1110 px = canvas width − 32 pt margin) at frame 36, is gone at 37 and re-enters through the right edge at frame 46 when the finger reverses (run A frame 11 shows it half clipped at x ≈ 1206). Meanwhile the picture accelerates left at 10, 7, 31, 60, 47, 38, 34, 29, 26, 21, 18 px/frame: the spring of a camera pan. Code: `follow()` (NativeSessionView.swift) mutated `viewport` inside `withAnimation(.smooth(duration: 0.36))` at up to 60 Hz, and `PointerOverlayView` positioned the glyph with `.position(viewport.viewPoint(fromSource:))`, a value that depends on `viewport`. SwiftUI animates `.position` additively; each pan step re-pinned the model position at the inset line while the presentation kept the previous, further-out value as a decaying offset, so the offsets from twenty pan steps stacked up and pushed the glyph hundreds of points past the edge for as long as the finger kept pushing. The telemetry freshness policy (0.8 s) and the video-cursor handover were never involved: no `capture`/`pointer` state can hide the pointer within 150 ms, and the streamed cursor never appears in the recording.
2. **Uneven motion (big step, then still, then jump)** is the same mechanism at smaller amplitude: whenever a pan step occurs the glyph inherits a spring-lagged offset, and every touch in between (120 Hz touches, 60 Hz follow throttle) snaps it back to the model value. Run A frames 12–18: after the reversal the glyph moves left 130–160 px/frame while the decaying offsets unwind, and the picture is still drifting left at 26 → 8 px/frame.
3. **The picture slides:** by design the follow pins the pointer at a 32-pt inset and pans by the finger's overshoot, but through a 0.36 s spring retargeted every 16.7 ms, so the picture keeps moving for up to a third of a second after the finger stops and, with the glyph detached from it (1), pointer and picture disagree the whole time.
4. **Not the cause here, but real:** the once-a-second ~100 ms arrival stall the performance lead measured on this link does not hide the pointer (stale is 0.8 s), but a sample that trails the finger, either a stall burst of old samples or the host's `CGEvent.location` lagging its own acknowledgements on a loaded Mac beyond the 50 ms injection bridge, was blended *backwards* over 45 ms by `PointerPredictor.receive`, and a residual over 64 pt snapped.

### Fixes (this branch)

- **Pointer glued to the picture.** `videoLayer` now places the video and the pointer overlay (and its accents) in one container with a single animated `.frame`/`.position`; the glyph is positioned in picture points (`source × scale`) inside it, and `.transaction(value: render.point) { $0.disablesAnimations = true }` guarantees a pointer move never carries the camera's animation while zoom animations still move both together. Whatever the camera does, the pointer can only be where the Mac pointer is over the Mac picture.
- **Camera follow is a choice** (Controls → Feel → Follow the pointer): **Smooth** (default: a 0.22 s no-bounce spring, 48-pt margin so the pointer can lead the eased picture during a fast stroke), **Rigid** (no easing: the picture moves exactly with the finger from a 32-pt margin, nothing moves after the finger stops) and **Off** (two-finger pan and mini map only). Reduce Motion pans without easing in every mode. Follow updates run at up to 120 Hz.
- **Forward-only reconciliation.** `PointerPredictor` keeps the direction of recent local moves; a sample whose residual lies along that direction within 200 ms of the last move is held (drawn position unchanged, no snap) instead of blended. It is released when the finger turns back towards the host's position, it decays 200 ms after the finger rests, and it disappears without motion as soon as the host catches up. Warps (direct touch, iPad pointer) clear it. Sideways and forward residuals, and a physical-mouse jump after rest, blend and snap exactly as before.
- **Host bridging until WindowServer catches up.** `HostPointerTelemetryPolicy` reports the injected point for up to 150 ms (was 50 ms) and stops as soon as the observed cursor is within half a point of it, so a physical mouse move right after a phone move is not masked.
- **120 Hz render loop (G25).** The overlay's `CADisplayLink` now runs while the pointer moves (250 ms linger) or a correction is pending, with `preferredFrameRateRange` 80–120 preferred 120, and is released when idle.

### Evidence for the fixes

Automated only so far; the feel on the phone is the check below. Core (macOS) additions: trailing samples held while the finger moves and vanishing on catch-up; a 150 ms stall burst of trailing samples keeps the drawn x monotonic and ends on the finger's own position; a held rejected move blends only after the finger rests; reversing the finger releases the hold; a 500 ms telemetry gap neither hides the pointer nor withdraws the overlay and reordered samples are dropped; the host reports the injected point until the cursor catches up and no longer. Phone additions: the display link asks for 80–120 Hz while moving and is released when idle; a stall burst through `PointerOverlayModel` keeps rendering, keeps advertising and never moves backwards; the follow styles expose smooth/rigid/off with the expected easing and margins. Results on 29 Sep (worktree rebased on `837b09b`, Mac load average 3–400): `RemoteCoreTests` pointer classes 22/22 (`PointerPredictionTests` 9, `PointerSamplingTests` 3, `PointerNegotiationTests` 6, `PointerTelemetryEncodingTests` 4; run with `xcrun xctest -XCTest <class>` from the `build-for-testing` product); `RemotePhoneTests` 74/74 on an iPhone 17 / iOS 27.0 simulator including the 8 `PointerOverlayTests` and the parity warp test. The rest of the core suite was not rerun for this change: nothing outside the pointer files changed.

### On-phone check (two minutes, after the next install from the main checkout)

1. **Fast strokes while zoomed (30 s).** Zoom to about 1.5×. Drag one finger fast left and right across the whole width, into each edge and back. The arrow must stay on screen the entire time and always sit on the same Mac pixel it was over when the picture moves. Note whether the picture's easing feels right (Smooth) and try Rigid for comparison.
2. **Stop and hold (15 s).** Move quickly, stop dead near an edge. The arrow must not step backwards or creep; the picture may finish a short ease (Smooth) or do nothing (Rigid).
3. **Slow precision (15 s).** Place the tip on a small toolbar button at 2×; it should track the finger with no vibration.
4. **Once-a-second stall (30 s).** Move continuously in a circle for 30 s. Any periodic hiccup means the stall is still visible; note whether the arrow jumps back or only pauses.
5. **Off / Rigid (15 s).** Switch Follow to Off, confirm nothing pans; switch to Rigid, confirm the picture moves exactly with the finger at the edge.
6. **Shapes and clicks (15 s)** as in the original check: I-beam over text, hand over a link, click lands under the tip.

## 29 September, later: "the cursor snaps after I let go" (build 20260929.4)

Evidence: `~/Downloads/dji_mimo_20260929_102238_…_slowmotion.MP4`, a 240 fps clip played at 29.97 fps (one frame = 4.17 ms) of the MacBook screen and the hand-held iPhone, Roshan tapping the bench page's green "tap / click me" button through Farside in Trackpad mode. Analysed on `roshan-pc-1` with `bench/pointer-recording/tap_track.py`: per frame it finds both green buttons by colour, the phone glyph by its white outline (masked NCC), the ember contact dot (the phone's own click marker) and, by eye on 3× zooms, the MacBook's real cursor. Positions are relative to each screen's button, so the moving phone does not matter. Three of the seven clicks in 190–360 s were examined (clip 236.5, 260.1 and 297.3 s).

What the frames show:

1. **The Mac runs behind the phone under load, sometimes far behind.** During ordinary strokes the real cursor follows the glyph with a 40–80 ms lag and moves in ~12-pt steps every 33 ms. In the 260 s window it received only about a third of an up-left stroke while the stroke was happening and caught up hundreds of milliseconds later; at the click it sat at the button's left edge while the glyph (and the ember dot) were inside the button, and the button never flashed. Only one of the three clicks flashed the Mac's button, 190 ms after the phone accepted it. The host based every relative move on `CGEvent.location` and posted clicks there (RemoteInputDriver.swift), so a late WindowServer both drops motion and lands clicks behind the finger.
2. **The one sharp jump of the glyph was input the phone sent, not a correction.** At 297.3 s, 150 ms after the tap, the glyph moved 0.87 button widths to the button's corner in 60 ms; the MacBook cursor started the same move 8–12 ms later and followed it step by step (frames 244–278 at 8 ms resolution). A telemetry snap would have the Mac leading by a sample plus the channel. The finger then dragged back left. The jump starts at the next touch-down after the tap; `NativeGestureEngine` resets its reference point on a fresh single touch, so the remaining candidates are the two-finger/staggered-landing path and a landing roll amplified by the speed curve. That file is the gesture agent's; the phone's `InputProbe` overlay would show the exact commands.
3. **Not the camera or the prediction.** The glyph never moved relative to the picture without either the finger moving or the Mac following, and the forward-only hold was never seen releasing into a visible snap in these windows. It does, however, hide the Mac's lag until the finger rests, so on a slow host the click lands where the Mac is, not where the glyph is.

Fixes on `pointer-host-chain`: the driver chains relative moves and clicks from the last point it posted while pointer events stream and the cursor still reads as a recently posted point (a physical mouse anywhere else is trusted); telemetry keeps reporting the injected point for up to 0.5 s until the cursor catches up (was 0.15 s), so a late WindowServer no longer feeds the phone a stale position that snaps the glyph back 200 ms after the finger rests. Tests: `NativeInputSafetyTests.testLaggingCursorDoesNotLoseMotionOrPullClicksBack`, updated bridging tests in `PointerSamplingTests`.

## Two-minute physical check

After this branch is integrated into the main checkout, install from there through `script/build_and_run.sh` (never from a worktree; do not bypass the identity guard) and the usual phone install, connect with control enabled, Medium size.

1. **Fit, idle (15 s).** Tap Fit. One large black arrow is visible; there is no second small arrow in the video. Move the real Mac mouse: the phone pointer follows smoothly.
2. **Finger feel (30 s).** Drag one finger slowly, then fast, across the whole desktop and into each edge. The pointer moves with the finger, stops at the edges without bouncing, and never jumps backward when you stop. Note any rubber-banding.
3. **Shapes (30 s).** Hover a text field (I-beam), a Safari link (pointing hand), a Finder column divider (resize), a window corner (diagonal). Each should change within about a tenth of a second.
4. **Clicks land (15 s).** Zoom to 2×; click a small toolbar button and place the caret between two letters. The click happens exactly under the tip.
5. **Fallback (15 s).** Turn on Airplane Mode for 3 s, then off. The picture and pointer may freeze or the session may show reconnecting; once the picture is live again there is exactly one pointer, never zero.
6. **Size (15 s).** Controls → Pointer size → Extra Large, then Small. The tip stays on the same spot.

Record pass/fail and anything odd (duplicate pointer, missing pointer, wrong shape, lag) in the implementation ledger.
