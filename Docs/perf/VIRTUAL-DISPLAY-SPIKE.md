# Virtual-display 120 fps spike (29 Sep 2026)

Evidence labels as in PLAN-120FPS-AND-LOAD.md: **[M]** measured here, **[S]** read in this repo or SDK, **[3P]** third-party report, **[E]** estimate.

## Purpose

The first priority of the performance effort is 120 fps, and G5 makes Farside follow the captured display's real refresh. Roshan's ASUS VG32VQ1B (2560×1440 at 144 Hz, 1×) is the only 120 Hz source, and only when it is plugged in. This one-day, Debug-only spike answers one question: **can a `CGVirtualDisplay` give a 2560×1440 @ 120 Hz display whose ScreenCaptureKit capture really delivers ≥ 110 frames a second**, so 120 fps sessions can be tested without the ASUS? The known risk (plan §2) is that macOS reports 120 Hz but composites at 60. The measurement decides.

## Go / no-go rule

Over **10 s of moving content** on the `1x-120` scenario (2560×1440 px, 1×, a single 120 Hz mode), counting complete ScreenCaptureKit frames by distinct `displayTime`:

- **GO**: mean ≥ 110 fps **and** p90 inter-frame gap ≤ 12 ms.
- **NO-GO**: anything else. In that case the virtual display stays a 60 Hz text-mode idea (plan §2) and 120 fps needs a real 120 Hz display.

(This replaces the plan's older "sckprobe ≥ 110 for 30 s" gate with the approved spike's gate: 10 s plus a gap bound, so a 60 Hz cadence with bursts cannot pass.)

## What the spike does

Code: `RemoteHost/VirtualDisplaySpike.swift` (the whole file is inside `#if DEBUG`) and one hook in `RemoteHostApp.init()`: in a Debug build launched with `--virtual-display-spike`, it runs the spike and exits before the host model, pairing, network, login item or app delegate exist. `NSApp.delegate` is cleared and the activation policy is accessory, so no host launch code runs.

For each scenario (`1x-120`, then `1x-144`, then `hidpi-120`; choose with `--scenarios`):

1. Creates the virtual display through the private CoreGraphics classes (below): name `Farside Spike <scenario>`, 697×392 mm (the ASUS panel), vendor 0xFA51 and a fixed product and serial per scenario, `hiDPI` 0 or 1, one mode.
   - `1x-120`: `maxPixels` 2560×1440, mode 2560×1440 @ 120.
   - `1x-144`: the same at 144 Hz.
   - `hidpi-120`: `maxPixels` 2560×1440, `hiDPI` 1, mode 1280×720 @ 120 (HiDPI modes are given in points). If macOS does not pick the 1280 pt / 2560 px mode, the spike switches to it with `CGConfigureDisplayWithDisplayMode` and `.forAppOnly`, which macOS undoes when the process exits.
2. Waits until `CGGetOnlineDisplayList` lists the display and an `NSScreen` exists for it, then prints what the OS reports: `CGDisplayCopyDisplayMode` (points, pixels, `refreshRate`), `CGDisplayBounds`, `CGDisplayPixelsWide/High`, the `NSScreen` frame, backing scale, `maximumFramesPerSecond`, minimum and maximum refresh interval, every offered mode, and what the host itself would do: `DisplayRefresh.rateHz` and the resulting `CaptureRatePolicy` target.
3. Opens a borderless black window covering that screen, with a white bar that moves 16 pt and a frame counter that advances on every `NSView.displayLink` tick (bound to that screen, preferred rate = the mode's rate).
4. Starts an `SCStream` on that display configured like `RemoteCapture` at 120: `minimumFrameInterval = .zero`, `queueDepth` 8 (`CaptureRatePolicy.queueDepth(for: 120)`), 420v pixels, full native pixel size, no cursor, no audio.
5. **Moving, 10 s**: prints distinct frames for each second, mean fps, median, p90 and maximum inter-frame gap, the total, every `SCFrameStatus` count, repeated or missing `displayTime`, and the display link's own ticks per second and interval (the rate the compositor drives for that display).
6. **Idle, 5 s**: the display link is stopped and the content is static; the same figures show how ScreenCaptureKit behaves on a still virtual display.
7. Stops the stream, closes the window, releases the virtual display and waits until it is gone from the online list.

The output ends with one `VIRTUAL-DISPLAY-SPIKE-SCENARIO:` line per scenario and a final line for the verdict scenario (`1x-120`, or the first one chosen):

```
VIRTUAL-DISPLAY-SPIKE: GO fps=… p90gap=…ms median=…ms distinct=… reported=…Hz link=… idle=… scenario=1x-120
VIRTUAL-DISPLAY-SPIKE: NO-GO fps=… …
VIRTUAL-DISPLAY-SPIKE: ERROR reason="…" scenario=…      (could not measure; not a no-go)
```

### How the private classes are reached

No header, no linking: `NSClassFromString` and `class_getInstanceMethod` / `class_getClassMethod`, with the implementation cast to a C function of the exact type encoding. The classes and selectors were read from the runtime on this Mac (macOS 27.0, build 26A428) by introspection, without creating a display **[M]**:

| Class | Used | Encoding on 27.0 |
|---|---|---|
| `CGVirtualDisplayDescriptor` | `-init`; KVC `queue`, `name`, `maxPixelsWide`, `maxPixelsHigh`, `sizeInMillimeters`, `vendorID`, `productID`, `serialNum`, `terminationHandler` | setters `v20@0:8I16` (unsigned int), `{CGSize=dd}`, block `@?` |
| `CGVirtualDisplaySettings` | `-init`; KVC `hiDPI`, `modes` | `hiDPI` unsigned int |
| `CGVirtualDisplayMode` | `+alloc`, `-initWithWidth:height:refreshRate:` | `@32@0:8I16I20d24`: unsigned int, unsigned int, double |
| `CGVirtualDisplay` | `+alloc`, `-initWithDescriptor:`, `-applySettings:`, KVC `displayID` | `applySettings:` returns `bool` (`B24@0:8@16`) |

Every KVC key is checked with `respondsToSelector:` first, so a renamed property fails with a message instead of an exception. The display exists as long as the `CGVirtualDisplay` object does; dropping the reference removes it.

Present on 27.0 but not used: `CGVirtualDisplaySettings.refreshDeadline` (double), `rotation`, `isReference`, and `-[CGVirtualDisplayMode initWithWidth:height:refreshRate:transferFunction:]`.

## How to run

Needs the shared build lock, then a quiet Mac: no builds, simulators or browsers, the installed Farside host paused or quit (it would otherwise see the extra display), and `/tmp/farside-quiet` absent unless the quiet window is the lead's own.

1. Build this branch's Debug host under the lock:

```sh
cd <worktree or integrated checkout>
/usr/bin/lockf -k /tmp/farside-xcodebuild.lock xcodebuild build -scheme PocketDeskRemoteHost \
  -destination 'platform=macOS' -project PocketDesktop.xcodeproj -configuration Debug \
  -derivedDataPath /Volumes/Studio/Development/Caches/Xcode/DerivedData/FarsidePerf-W5
```

2. Run the spike (about 70 s for all three scenarios):

```sh
script/perf/virtual-display-spike.sh \
  /Volumes/Studio/Development/Caches/Xcode/DerivedData/FarsidePerf-W5/Build/Products/Debug/PocketDeskRemoteHost.app \
  /tmp/farside-virtual-display-spike.log
```

With no arguments the script uses `…/DerivedData/FarsidePerf/Build/Products/Debug/PocketDeskRemoteHost.app` (the perf branch's DerivedData, once this is merged there) and a timestamped log in `/tmp`. `--scenarios 1x-120` runs only the gate. The script builds nothing. It refuses a Release build (no hook), a non-host bundle and a second running spike, and it will not start while `/tmp/farside-quiet` exists unless `FARSIDE_SPIKE_IGNORE_QUIET=1`. It prints the output live, then the verdict line, and exits 0 on GO, 1 on NO-GO, 2 on an error or a missing verdict. Ctrl-C sends SIGINT to the spike, which removes its window and display before exiting. The spike also exits on its own after 240 s plus the extra steps' allowance per scenario (`SpikeSteps.extraSeconds`).

### Permissions

ScreenCaptureKit needs Screen Recording for the *responsible* process. By default the script starts the app through LaunchServices (`open -n -W`, the pattern script/e2e uses), so the app is responsible for itself. The Debug build is signed Apple Development with the installed host's bundle identifier and team, so its designated requirement should match the installed host's grant (Docs/MAC-PERMISSION-IDENTITY.md) **[E, not yet run]**. `--direct` executes the binary instead; then macOS checks the terminal app's grant. The output's second line prints `CGPreflightScreenCaptureAccess`; if it says `false`, or ScreenCaptureKit reports a declined permission, stop and follow MAC-PERMISSION-IDENTITY.md. Do not reset grants or edit the privacy database for this spike. A macOS screen-recording confirmation prompt, if one appears, is Roshan's to answer.

No entitlement, SIP change or private entitlement is involved: the classes are ordinary Objective-C classes in CoreGraphics, and DeskPad and BetterDisplay use them from hardened, Developer ID-signed apps **[3P]**. Whether hardened-runtime Debug builds behave the same on 27.0 is part of what the first run shows.

## Measured

**Pending — the lead runs it.** Fill in from the log:

| Field | 1x-120 | 1x-144 | hidpi-120 |
|---|---|---|---|
| Date and time, macOS build, Mac model, branch and SHA | | | |
| Mac state (quiet flag, installed host paused, load average) | | | |
| Online after (ms) | | | |
| `CGDisplayCopyDisplayMode`: pt, px, `refreshRate` | | | |
| `NSScreen.maximumFramesPerSecond`, backing scale, refresh intervals | | | |
| Host view: `DisplayRefresh.rateHz` → target fps | | | |
| Display link, moving: ticks/s and interval (ms) | | | |
| SCK moving, per second (10 values) | | | |
| SCK moving: mean fps, gap median / p90 / max (ms), distinct | | | |
| SCK moving: statuses, repeated / missing `displayTime` | | | |
| SCK idle 5 s: complete/s, statuses | | | |
| Scenario verdict line | | | |

Final line (verbatim): `pending`

Decision: `pending` (GO: 120 fps sessions can be tested on the virtual display without the ASUS; NO-GO: 120 fps testing needs the ASUS, and the feature claim stays "120 fps on ProMotion and 120 Hz displays").

## Phone-shaped display extension (1 Oct 2026)

The spike grew three HiDPI scenarios shaped like an iPhone 17 (2622×1206 px at 3×, 874×402 pt): `phone-2x-60` and `phone-2x-120` (1311×603 pt, 2× = pixel-exact 2622×1206 px) and `points-2x-120` (874×402 pt, 2× = 1748×804 px). `--virtual-display-spike-portrait` swaps width and height. The descriptor's `maxPixelsWide/High` is now the larger pixel side on both axes (override: `--virtual-display-spike-max-pixels N`), and a HiDPI scenario advertises two modes, the 2× raster anchor then the logical size, as node-mac-virtual-display does; the HiDPI selection still asks for duplicate low-resolution modes, as OpenDisplay does. Optional steps after the gate, `--virtual-display-spike-steps a,b,…` (script: `--steps`):

- `encode`: HEVC then H.264 `VTCompressionSession` (hardware required, RealTime, no reordering, 25 Mb/s, ExpectedFrameRate = the scenario's rate) fed from the capture callback at the stream's pixel size, one frame in flight, 240 frames; prints the IDR, p50, p90 and max submit→callback ms and the mean P-frame size (`SPIKE ENCODE …`).
- `rotate`: re-applies settings with swapped width and height on the **same** `CGVirtualDisplay` object, then reports the ms until `CGDisplayBounds` changes, until the `NSScreen` frame changes, and until the first complete captured frame at the new size, whether the display ID survived, and every other app's window that moved or ended up off every display; then 3 s of moving capture in the new orientation.
- `mirror:virtual` (default for `mirror`) / `mirror:panel`: `CGConfigureDisplayMirrorOfDisplay` (`.forAppOnly`) so the virtual display shows the panel (the panel stays main), or the built-in panel shows the virtual display, for 5 s of moving capture, then undone and verified with `CGDisplayIsInMirrorSet`. **Only with Roshan's OK** (it changes what his screen shows).
- `sleep`: `pmset displaysleepnow`, 15 s of capture while dark, `caffeinate -u -t 2`, then checks the virtual display, its NSScreen, its mode and the stream, plus 3 s of moving capture. Never `pmset sleepnow`. **Only with Roshan's OK**: if the Mac requires a password after display sleep, the wake lands on the lock screen, which breaks iPhone Mirroring and any live host session.
- `hold:<s>`: keeps the display alive after the measurements and prints `HOLD display <id> pid <pid>`; the script's `--kill9 N` SIGKILLs it N seconds later and polls `CGGetOnlineDisplayList` to time the teardown.

Results: `~/Documents/Codex/2026-10-01/perf-push/vdisplay/NOTES.md` (run logs in `logs/`).

## Caveats

- **Private API.** `CGVirtualDisplay` is undocumented SPI; any macOS update can rename or remove it. The selectors above were verified on 27.0 (26A428) only.
- **Debug only, never ship.** The file and the hook are inside `#if DEBUG`; a Release build contains neither (the script checks for the argument string in the binary and its `.debug.dylib`). The spike stays out of `RemoteCoreTests`. Remove it, or keep it Debug-only, after the decision.
- **Screen Recording (TCC)** is required, see Permissions.
- **Window positions may shift.** Adding a display is a display reconfiguration: macOS can move windows, and when the virtual display goes away it gathers anything on it back to the remaining displays. The spike's own window is removed first; nothing else is restored. The menu bar and Dock stay on the main display. With "Displays have separate Spaces", the virtual display briefly gets its own Space.
- **Display records.** macOS keeps arrangement records per display identity; the spike uses a fixed vendor, product and serial per scenario, so repeated runs should reuse three records rather than add new ones **[E]**.
- **Removal on exit.** The display is released on every normal path; on SIGINT, SIGTERM or SIGHUP the spike tears down and exits; on a crash or the timeout (240 s plus the steps' allowance) the process's window-server connection closes, which removes the display and the window with it. The HiDPI mode switch is `.forAppOnly` and ends with the process.
- **What it does not measure.** Encoding, WebRTC and the phone: this is capture delivery only. Full 2560×1440 capture at `.zero` is the conservative case; G5 would scale to 2048 at 120.
