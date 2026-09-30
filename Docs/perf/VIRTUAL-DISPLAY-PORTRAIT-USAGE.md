# Debug portrait virtual-display prototype

30 September 2026. This is the isolated implementation described by `VIRTUAL-DISPLAY-PORTRAIT-IMPLEMENTATION-2026-09-30.md`. It creates a private SPI virtual display only on an explicit Start or smoke invocation. The experiment captures Farside's own synthetic window into a local preview. Ordinary host launches and Release builds contain none of this new prototype.

The proposed modes are 430 × 932 logical points at 60 Hz, with 430 × 932 pixels for `1x` or 860 × 1864 pixels for `2x`. The prototype accepts a mode only if the actual CGDisplayMode, NSScreen scale, own-window filter and delivered frame size agree. It does not reconfigure a physical display, choose a new main display, migrate another app's window, pair a phone or start host services. Creating a display still changes the shared desktop topology.

## Commands

Use the isolated Debug build; nothing in the runner builds or installs an app. The default product is `/Volumes/Studio/Development/Caches/Xcode/DerivedData/FarsidePortraitPrototype/Build/Products/Debug/PocketDeskRemoteHost.app`. Supply `--app` if the parent verification build used another DerivedData directory.

```sh
# Default: report permission preflight and private method ABI, without creating a display or window.
script/perf/virtual-display-portrait.sh --action check

# Validate runner arguments/bundle/Debug marker only; never execute the app.
script/perf/virtual-display-portrait.sh --validate-only

# Explicit bounded smoke: moving synthetic content for 5 s, then static content for 2 s.
script/perf/virtual-display-portrait.sh --action smoke --mode 1x
script/perf/virtual-display-portrait.sh --action smoke --mode 2x

# Local control panel: Start/Stop and a coalesced preview. Close the panel to stop and exit.
script/perf/virtual-display-portrait.sh --action interactive --mode 2x
```

LaunchServices is the default so macOS checks the built app's responsible-process permission identity. `--direct` executes the binary directly and may instead check the invoking terminal's permission. Missing Screen Recording permission fails without calling a permission-request API, creating a display or acquiring the runtime lease. Do not reset permissions or act on a system prompt automatically.

Run real smoke only after the independent code review and parent resource coordination. Do not run performance measurement beside simulators, browsers, builds or another benchmark. The runner rejects an active `/tmp/farside-quiet` marker for smoke/interactive actions. It preserves installed hosts and rejects `/Applications` artifacts.

## Evidence and outcomes

Private log files default to a new `/private/tmp/farside-portrait.XXXXXX/` directory. `--log` selects a new destination; existing files and symlinks are rejected. Reports are stdout lines prefixed `VIRTUAL-DISPLAY-PORTRAIT-JSON:` followed by JSON, plus a readable `VIRTUAL-DISPLAY-PORTRAIT:` outcome. No pixels, screenshots, clipboard values or unrelated window titles are written.

The report includes requested and observed dimensions/refresh, OS/revision, own window/display identity, capture filter scale, first-frame timing, moving display-link ticks, moving/static complete/idle/missing/repeated timestamps, distinct-frame cadence and gaps, storage overflow, before/after display inventories and verified cleanup. The revision comes from the runner's checkout and is `unknown` for an invocation without that environment; it is not a build provenance attestation. The check action reports permission/ABI support without registering a display.

A smoke passes only with the intended geometry and capture identity, at least two distinct complete motion timestamps, correct frame sizes, no capture failure and observed owned-display removal. Actual fps remains a measurement; a requested 60 Hz mode is not a promise of 60 distinct frames each second. Own-window capture does not prove full virtual-desktop capture, phone latency, encoder/network performance or another app's usability.

Every async capture start/stop remains owned after a deadline. A late successful start is stopped through the exact acquired stream. Failed stop or unknown display identity retains ownership and blocks another Start. Partial creation/configuration failure retains the display and runtime lease until disappearance is observed. Normal Stop, panel close, SIGINT/SIGTERM/SIGHUP and capture/display failure share cleanup. A private no-follow 0600 file and nonblocking advisory lock serialize cooperative portrait processes; the file is intentionally not deleted. Existing experiment display identities are rejected before allocation.

The runner's outer limit is 60 seconds for check/smoke and 300 seconds for interactive. It sends TERM only to the new experiment PID after checking its executable, arguments and process start time, allows a 12-second cleanup grace, and can kill that owned process if it remains stuck. An outer timeout exits 3 and explicitly leaves cleanup unverified even if process death is expected to release the WindowServer connection. Synchronous private calls cannot be forcibly cancelled in-process. Crash/SIGKILL cleanup, lock/sleep, old OS compatibility, window/Space restoration and physical phone acceptance remain untested.

## Author checks and remaining verification

Author source and XCTest typechecks use SDK27, arm64 and the retained macOS26 target. Shell syntax and 16 fabricated runner fixture cases pass without executing an app. Parent owns the actual Debug/Release build, scoped XCTest, binary exclusion check, fresh independent review and any explicitly coordinated runtime smoke. The existing 120/144 Hz spike is unchanged. No installed host, permission grant, pairing, service, simulator or display was changed by author checks.

### Own-window placement correction

The first parent-coordinated 1× smoke verified 430 × 932 at 60 Hz and successful display removal, but failed the strict capture identity/placement guard before creating a capture stream. Inspection found the explicit-screen NSWindow initializer was given a global screen origin. [Apple's initializer documentation](https://developer.apple.com/documentation/appkit/nswindow/init(contentrect:stylemask:backing:defer:screen:)) specifies a rectangle relative to the supplied screen's origin. The fixture now passes a zero-origin rectangle of the target screen's size; a pure regression covers primary, right, left, above and below arrangements. A bounded `placement` report records only the exact requested window's ID/PID/frame and owned-screen geometry before the unchanged identity/placement guard. This source correction still needs independent review, compilation and a coordinated rerun; it does not establish captured-window or frame-cadence acceptance.

The next coordinated smoke confirmed the AppKit window frame, but its first SCWindow snapshot was inset/scaled (422 × 916 instead of 430 × 932). This is consistent with an inferred order-front animation; that cause remains an inference. The fixture now sets [animationBehavior](https://developer.apple.com/documentation/appkit/nswindow/animationbehavior-swift.property) to `.none` before ordering, as Apple's API disables automatic order-front/order-out animations. It rediscovers only the exact owned window within one shared five-second deadline, rejecting every snapshot until all original identity and geometry gates pass. The report retains only the latest bounded snapshot plus attempt count/timing. No capture stream is created on a transient, wrong-owner, wrong-screen or expired snapshot. These corrections await independent review and a coordinated runtime rerun.

### Owned HiDPI mode selection

The later 1× smoke passed own-window capture and verified removal. The 2× run created a native 860 × 1864-point/860 × 1864-pixel mode with backing scale 1, so it correctly failed the intended 430 × 932-point/860 × 1864-pixel acceptance check and removed the display. Setting the private `hiDPI` flag alone did not select the intended logical mode on that runtime.

For 2× only, the prototype now enumerates [publicly offered modes](https://developer.apple.com/documentation/coregraphics/cgdisplaycopyalldisplaymodes(_:_:)) on its retained virtual display and selects an exact 430 × 932-point, 860 × 1864-pixel, 60 Hz candidate with [CGDisplaySetDisplayMode](https://developer.apple.com/documentation/coregraphics/cgdisplaysetdisplaymode(_:_:_:)). Immediately before the sole mutation, it checks the retained object's display ID, vendor/product/serial identity, online status, non-main status and absence from a mirroring set. It never selects a physical/main/mirrored display, creates a new mode, changes the existing SPI signature/mode descriptors or falls back to another screen. Missing candidate or setter failure stops the run through retained-owner cleanup.

The public setter is synchronous and documented as lasting for the calling process. Its execution consumes the same five-second mode-stage budget; AppKit/CG geometry and backing scale must settle within the remaining budget before creating the synthetic window. A synchronous call cannot be forcibly cancelled in-process; the runner's outer timeout remains a separate unverified-termination outcome. Reports retain up to 64 offered mode summaries, total count, selected mode, result code and observed post-selection geometry. The desktop-GUI usability flag is reported; actual creation/capture geometry remains the acceptance evidence. This source correction requires independent review, builds/tests and coordinated 2× runtime acceptance.

Mode verification rechecks generation admission and the original deadline after all CG/AppKit geometry reads, immediately before recording a verified result. Even exact geometry returned at or after the deadline is rejected; synchronous setter interruption remains outside the in-process guarantee.
