# Duo lane source checkpoint — 2 October 2026

This is an engineering handoff, subordinate to PRODUCT. The lane supplies Duo sensing and
reserved-region handling for the concurrent b7-ipad layout. It does **not** establish the
featuring nomination's half-folded layout or a release-ready build.

## Platform evidence refreshed today

- [Apple preparation talk](https://developer.apple.com/videos/play/tech-talks/111461/),
  0:30–1:17: SDK27 apps run on Duo with improved inner-display sizing, but SDK27.1 opts into
  edge-to-edge space. SDK27.0 is a compatibility fallback, not full Duo integration. At1:17
  Apple demonstrates Device Hub open/close/rotate/fold controls; at6:06 it covers asymmetric
  safe areas and Split View dragging from the home indicator. No UIRequiresFullScreen opt-in
  or device-idiom layout branch is added here.
- [HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
  and [Duo preparation](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo):
  use local window geometry/size classes. Native overlay arrangements place secondary content
  leading/top and primary content trailing/bottom when an active fold divides the window.
  Farside's picture is therefore secondary and its pad primary if a native arrangement is used.
- [UIHingeInteraction](https://developer.apple.com/documentation/uikit/uihingeinteraction):
  the handler receives optional hinge state. Prefer status over angle; nil clears posture facts.
  There is no hinge delegate protocol in the installed headers.
- [Reserved regions](https://developer.apple.com/documentation/uikit/uiview/reservedregions(kind:options:)):
  public Swift spelling is `reservedRegions(kind:options:)`. Frames are in the query view's
  coordinates and already include interactive margins. Explicitly filter active regions.
  Layout/safe-area/window/hinge callbacks refresh the query; coverage of independent
  same-bounds camera-region changes is unproven and remains a runtime gate.
- Local stable Xcode27.0/27A266a has SDK27.0; installed27.2 beta2/27B5028f has SDK27.2.
  Both compiler versions are6.4, so compiler-version checks cannot substitute for SDK guards.
  [Apple release table](https://developer.apple.com/xcode/system-requirements) lists stable27,
  beta27.1 and beta27.2, with no release SDK27.1+ today. App Store submission therefore remains
  blocked for full native Duo support until a compatible release toolchain is available and
  its release artifact passes the same checks. A beta simulator build is development evidence.
- Live [Xcode27 notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
  and [27.2 beta2 notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes)
  were inspected. Beta2 documents Duo black screenshots for minutes after boot and limited
  Duo accessibility visibility in Device Hub. The simulator supports poses; local CUA access
  timed out, which does not prove poses are unsupported.

## Integration contract

`RemotePhone/DuoSessionLayout.swift` defines window-local facts and a stable UIKit probe.
`NativeSessionView` stores `duoLayout` and attaches the probe to the full stage. Preserve that
same coordinate space for `DuoReservedRegionShield`, picture placement and trackpad placement.
The code uses no device names, screen dimensions or angle thresholds.

After integrating b7-ipad's existing layout, use:

```swift
// Keep the iPad lane's ordinary sizing/coverage/hysteresis calculation.
let nextStacked = !couch && duoLayout.stacked(ordinary: ordinaryStacked)
// A folded window always uses phone chrome, regardless of any previous width-class state.
let regular = horizontalSizeClass == .regular && duoLayout.posture != .folded
```

When `duoLayout.division` exists, use its `picture`, `trackpad` and `hinge` rectangles instead
of the ordinary picture height. `.vertical` is a horizontal hinge: picture ends at the hinge's
minimumY, pad starts at maximumY, with the hinge gap between. `.horizontal` is the book pose:
picture leading, pad trailing. A Split View window wholly outside the fold gets no division
and retains the ordinary layout. Flat unfolded windows also retain that rule.

Keep picture/pad children stable across these frame changes. Do not switch renderer branches,
recreate the model/coordinator, start/end a session, or reset zoom. Apply frame changes together;
the integrator must verify that viewport coordinates and pad input stay aligned and controls
are placed within safe regions. The mask prevents input inside active camera/fold regions;
masking alone does not move a control away from those regions.

When combining the DEBUG rotation probe with b7-ipad, its applied-viewport size predicate must
compare `viewport.canvasSize` with the layout's `pictureSize`, rather than the whole stage's
`canvasFrame.size`. Keep the separate probe/stage size comparison; the probe spans the window.
The standalone branch has one full-stage picture, so those sizes are currently equal.

`FARSIDE_DUO_SDK` is automatically enabled by target settings for SDK names matching
`iphone*27.1*` and `iphone*27.2*`. New API references are also gated at runtime27.1. Future
SDK versions require refreshing this record and extending the SDK setting. SDK27.0 has no
references to new APIs and retains the ordinary geometry fallback. `disableDuoSessionLayout`
disables native facts; `disableDuoInactiveContinuity` restores the previous inactive hold policy.

Inactive scenes still release input and shield content, but no longer start a background expiry
task by default. Only actual backgrounding uses the existing concealment/hold/PiP lifecycle.
This is a source fix for unfocused Split View sessions; live folding continuity is not measured.

## Verification and remaining gates

- Fresh GPT source review approved the repaired current-geometry readiness predicate and
  lifecycle rollback switch. Native delivery verdict remains **incomplete**.
- Whitespace checks and the worker's changed UI-test syntax checks passed. Parent parse-only
  attempts could not acquire the shared build lock (bounded retry exit75); they are not passes.
- Internal free bytes fell to6,482,194,432 and later8,591,867,904, below the shared10GB limit.
  No dual-SDK build, policy/lifecycle XCTest, Duo UI suite or after screenshots ran. Do not
  promote the historical F9 result14pass/1skip/4fail to a passing result.
- F9 tests now read a DEBUG offline-only `remote.layout.state` JSON probe, checking exact
  interface orientation and applied geometry consistency. Device/interface landscape names
  are inverse. Background coverage activates Settings and verifies real background state,
  concealed content, absent canvas/controls and explicit Return to Farside recovery. The
  original recording never left the canvas after Home; the wrong-display explanation remains
  an inference. This revised test has not run.
- Resume commands and logs belong to
  `/Users/roshansilva/Documents/Codex/2026-10-01/perf-push/b7-duo/run-check.sh` and `logs/`.
  Run build27, unit, ui; then build272, unit, ui. Each operation rechecks pause/quiet/priority,
  disk and shared `lockf -k` gates and uses the lane's own DerivedData. Do not install from
  this worktree to the host or a real device.
- After iPad integration, capture actual folded/unfolded/half-folded session screenshots
  under `/Users/roshansilva/Documents/Codex/2026-10-01/ipad-design/duo-after/`, label toolchain
  and native pose, and exercise both Split View sides. A debug geometry fixture is not native
  pose evidence. Device Hub screenshots may need several minutes after simulator boot.

After the orchestrator integrates and installs an eligible candidate, Roshan must verify a
real Duo: connect, zoom/pan, hold a click then fold/rotate/unfold, use both Split View sides,
switch focus, background and return. Pass criteria: session identity stays unchanged, held
input releases, picture/pad avoid the actual hinge and camera, pointer mapping stays correct,
chrome stays reachable, background snapshot is concealed, and no black frame/renderer restart
occurs during ordinary posture changes. Real hinge tolerances, display handoff, input feel,
latency/thermal behavior and physical no-flicker acceptance cannot be proven by simulator logic.
