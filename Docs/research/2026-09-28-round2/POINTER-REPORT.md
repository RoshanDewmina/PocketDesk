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

## Two-minute physical check

After this branch is integrated into the main checkout, install from there through `script/build_and_run.sh` (never from a worktree; do not bypass the identity guard) and the usual phone install, connect with control enabled, Medium size.

1. **Fit, idle (15 s).** Tap Fit. One large black arrow is visible; there is no second small arrow in the video. Move the real Mac mouse: the phone pointer follows smoothly.
2. **Finger feel (30 s).** Drag one finger slowly, then fast, across the whole desktop and into each edge. The pointer moves with the finger, stops at the edges without bouncing, and never jumps backward when you stop. Note any rubber-banding.
3. **Shapes (30 s).** Hover a text field (I-beam), a Safari link (pointing hand), a Finder column divider (resize), a window corner (diagonal). Each should change within about a tenth of a second.
4. **Clicks land (15 s).** Zoom to 2×; click a small toolbar button and place the caret between two letters. The click happens exactly under the tip.
5. **Fallback (15 s).** Turn on Airplane Mode for 3 s, then off. The picture and pointer may freeze or the session may show reconnecting; once the picture is live again there is exactly one pointer, never zero.
6. **Size (15 s).** Controls → Pointer size → Extra Large, then Small. The tip stays on the same spot.

Record pass/fail and anything odd (duplicate pointer, missing pointer, wrong shape, lag) in the implementation ledger.
