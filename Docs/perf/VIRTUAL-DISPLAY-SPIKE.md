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

## Measured (1 Oct 2026, phone-shaped runs)

Conditions: macOS 27.0.1 (26A434), Mac16,13 (M4 Air), branch `claude/vdisplay-spike` 3d8b439 (batch-3 ab733b4 merged), Debug build launched with `--direct`, quiet window 14:15–15:05 with load 5–9, **ASUS VG32VQ1B attached** (display 2, 2560×1440 @ 144 Hz) and the built-in at a scaled 1920×1243 pt. Raw logs: `~/Documents/Codex/2026-10-01/perf-push/vdisplay/logs/`.

| Scenario | Mode reached | Distinct SCK fps, 10 s moving (gap median / p90 ms) | Display link ticks/s | Idle fps |
|---|---|---|---|---|
| phone-2x-120 (1311×603 pt, 2× = 2622×1206 px) | yes, scale 2.0, 120 Hz | 90.3 (8.33 / 16.67); repeats 89.5, 89.0, 87.9, 85.5 | 60.0 | 0.4 |
| phone-2x-60 | yes, 60 Hz | 59.8 (16.67 / 16.67) | 60.0 | 0.2 |
| points-2x-120 (874×402 pt, 2× = 1748×804 px) | yes, 120 Hz | 89.6 (8.33 / 16.67) | 60.0 | 0.0 |
| phone-2x-120 portrait (603×1311 pt) | yes, 120 Hz | 89.0 | 60.0 | 0.2 |
| 1x-120 (2560×1440) | 120 Hz | 88.9 (8.33 / 16.67) | 60.0 | 0.2 |
| 1x-144 | 144 Hz | 97.9 (6.94 / 20.83) | 60.0 | 0.2 |
| hidpi-120 (1280×720 pt) | yes, 120 Hz | 91.5 (8.33 / 16.67) | 60.0 | 0.2 |

Every scenario is NO-GO on the ≥110 fps gate. The spike window's display link ticked at 60/s on every virtual display, so the drawn content changed 60 times a second; the extra distinct `displayTime`s are compositor presents.

Encode at 2622×1206 (420v capture frames, one in flight, 240 frames, hardware, 25 Mb/s): HEVC p50 7.62 ms, p90 8.03, max 9.45, IDR 24.0 ms; H.264 p50 7.27 ms, p90 7.70, max 9.02, IDR 19.4 ms.

Rotation by `applySettings:` on the same object (display ID kept): landscape→portrait: bounds, NSScreen and the 2× mode settled at 366–367 ms, ScreenCaptureKit size fresh at 412 ms, first full-size frame at 457 ms; no other window moved. Portrait→landscape: bounds at 381 ms but on the 1× mode; after re-selecting 2× it settled about 0.3 s later (0.7 s total without the spike's 2 s grace).

Teardown: normal release removed the display in every run; `kill -9` removed it 224 ms later (shell poller). Display sleep/wake, mirroring and the ASUS-detached condition were not run (not approved). Side effect seen on every release: the iPhone Mirroring window on the ASUS shrank by 11 px (restored by the lane tool).

Final line (phone-2x-120, verbatim): `VIRTUAL-DISPLAY-SPIKE: NO-GO fps=90.3 p90gap=16.67ms median=8.33ms distinct=903 reported=120Hz link=59.9 idle=0.4 scenario=phone-2x-120`

Decision: 2× phone-shaped display works and rotates in place; 120 fps does not (content runs at 60 Hz on a virtual display here).

## Caveats

- **Private API.** `CGVirtualDisplay` is undocumented SPI; any macOS update can rename or remove it. The selectors above were verified on 27.0 (26A428) only.
- **Debug only, never ship.** The file and the hook are inside `#if DEBUG`; a Release build contains neither (the script checks for the argument string in the binary and its `.debug.dylib`). The spike stays out of `RemoteCoreTests`. Remove it, or keep it Debug-only, after the decision.
- **Screen Recording (TCC)** is required, see Permissions.
- **Window positions may shift.** Adding a display is a display reconfiguration: macOS can move windows, and when the virtual display goes away it gathers anything on it back to the remaining displays. The spike's own window is removed first; nothing else is restored. The menu bar and Dock stay on the main display. With "Displays have separate Spaces", the virtual display briefly gets its own Space.
- **Display records.** macOS keeps arrangement records per display identity; the spike uses a fixed vendor, product and serial per scenario, so repeated runs should reuse three records rather than add new ones **[E]**.
- **Removal on exit.** The display is released on every normal path; on SIGINT, SIGTERM or SIGHUP the spike tears down and exits; on a crash or the timeout (240 s plus the steps' allowance) the process's window-server connection closes, which removes the display and the window with it. The HiDPI mode switch is `.forAppOnly` and ends with the process.
- **What it does not measure.** Encoding, WebRTC and the phone: this is capture delivery only. Full 2560×1440 capture at `.zero` is the conservative case; G5 would scale to 2048 at 120.
