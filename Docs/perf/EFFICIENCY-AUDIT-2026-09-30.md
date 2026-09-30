# Efficiency audit: Farside on a busy base M1 with 8 GB (30 Sep 2026)

**Question (Roshan, 30 Sep).** The measurements so far ran on a quiet M4 Air with AirDrop off and other work stopped. Real users will have other apps open, for example on a base M1 MacBook Air with 8 GB. Can the host and the phone get lighter and more efficient without losing performance?

**Scope.** This is a static audit plus a measurement plan. Nothing was built, run or measured: `/tmp/farside-quiet` was set while Roshan tested with the phone. One exception is disclosed under "Incident" below. Branch `farside-efficiency-audit` (worktree `.claude/worktrees/efficiency`), based on main `6d83703`.

**Evidence labels:**

- **[S]** read in source at `6d83703`.
- **[M]** measured earlier, from `LAB-NOTEBOOK.md` or `BASELINE-2026-09-29.md`. Nothing was measured today.
- **[D]** Apple documentation (§7).
- **[E]** estimate or inference that still needs a test.

## 0. Bottom line

1. **The host already does the big things right [S].**
   - No capture or encoding runs until a phone connects, and both stop when the phone goes to the background.
   - ScreenCaptureKit (SCK) hands 4:2:0 frames straight to VideoToolbox with no copy.
   - WebRTC never rescales frames on the CPU.
   - Only complete frames are encoded. Idle-status frames are skipped.
   - Nothing logs per frame.
   - The viewport crop, the client pixel cap, the ladder and thermal/Low Power Mode inputs are all on by default.

   The idle host sits at 0 % CPU with a 52 MB footprint (Roshan's figure). The waste that remains is in three places:
   - how the encoder behaves under contention;
   - main-thread and inter-process chatter while streaming;
   - the phone redrawing at 120 Hz while the picture is static.
2. **On a loaded machine, the encoder queue is the main latency lever.**
   - VideoToolbox (VT) latency equals the frames waiting inside VT times the time to encode one. That was about 13 ms per 4.2 MP frame on the M4 [M].
   - When anything slows that service time, a queue of 2–3 frames forms and latency jumps from about 13 ms to 30–42 ms [M].
   - An M1's media engine is older, and on a busy Mac it is shared with FaceTime, Zoom or a video export, so the queue will form sooner [E].
   - "Newest frame wins" (`PocketDeskEncoderMaxInFlight`) is built but **off by default** [S]. Today the ladder's answer to a queue is to lower fps or picture size.
   - Dropping the stale frame at submit keeps full pixels and cuts latency. It is the change that best fits "no compromise when resources are free".
3. **The rest are small, safe wins, most of them already committed here:**
   - timer slack on the host;
   - removing the duplicate 2.5 Hz capture-status path;
   - a non-blocking Mac-name lookup;
   - less work in the watchdog helper;
   - fewer SwiftUI invalidations on the phone.

   Proposals needing a phone check:
   - the phone stops forcing 120 Hz redraws on a static picture;
   - the phone tells the Mac its panel rate;
   - an Accessibility-trust cache so the input path doesn't make a TCC call per event.
4. **Only a real M1 settles the rest.** That covers encode service time per megapixel, whether the default Sharper picture holds 60 fps under load, and when the fanless M1 Air throttles. A 16 GB M4 with 8 GB of memory ballast approximates memory pressure and nothing else (§5.4).

## 1. Host hot path

The pipeline [S]: `SCStream` (420v, `queueDepth` 5, 8 at 120 fps, `minimumFrameInterval` 1/60) delivers a sample on the capture queue (`PocketDesk.capture`, `.userInteractive`, `RemoteCapture.swift:511`). From there:

1. `PeerMedia.pushFrame` wraps the `CVPixelBuffer` in `RTCCVPixelBuffer`, with no copy.
2. libwebrtc's frame adapter passes it on. `maintainResolution` means no CPU scaling. The ladder applies its size step inside SCK, not in WebRTC (`PeerMedia.swift:411`).
3. `DesktopH264Encoder` wraps the stock `RTCVideoEncoderH264`, which feeds `VTCompressionSession`.
4. Packets go through the pacer to the network.

| Area | Finding | Cost | Verdict |
|---|---|---|---|
| Capture size | Pixel cap by mode, then the client's long edge. G4 crop at reading zoom (~1.5 MP instead of 4.2) [S] | Encode time is linear in pixels (~2.3–3.1 ms/MP on M4) [M] | Good. On an M1 the crop matters more |
| Pixel format | `420v` (`RemoteCapture.swift:496`). SCK converts BGRA→YUV in hardware [D]. The stock encoder resets its session to the frame's format, so no conversion [S, upstream] | none | Good |
| Copies | None between SCK and VT unless the adapted size differs from the buffer. `SenderOutputFormat` and `senderLadder` keep them equal [S] | – | Good. A future change that adapts in WebRTC would bring back a CPU `NV12Scale`; keep sizing in SCK |
| Unchanged frames | `.idle` status frames are counted, not encoded (`:797–804`). A static desktop is re-pushed about every 0.8 s: a 0.4 s timer with a 0.45 s threshold, so every second tick [S] | ~1.25 full-frame encodes/s when static, ≈ 2 % of the media engine at 4.2 MP [E] | Keep (phone freshness gate, encoder refinement). See proposal P7 |
| `queueDepth` | 5 at 60 fps, 8 at 120. Apple: minimum 3, at most 8, deeper uses more memory [D] | 5 × 6.4 MB = 32 MB of surfaces at 2560×1656; 51 MB at depth 8 [E] | Proposal P6 (pressure-aware) |
| Dirty rects | `SCStreamFrameInfo.dirtyRects` is unused [S]. Apple suggests using them [D] | With a G4 crop, a change outside the crop may still produce a complete frame and a full encode [E] | Proposal P8 (probe first) |
| Encoder settings | Stock: `RealTime` on, no frame reordering, hardware requested [S, upstream]. Low-latency rate control measured worse here [M]. `MaxFrameDelayCount` and `PrioritizeEncodingSpeedOverQuality` can't be reached through the stock wrapper [S] | – | Proposals P1, P5 |
| Encoder queue | `encoderMaxInFlight` is nil by default: frames queue inside VT [S]. The ladder steps down at 2 in flight (`LadderPolicy.swift:56`) | 13 → 22 → 38 ms at 1/2/3 in flight [M] | **P1, top** |
| Thread QoS | Capture queue `.userInteractive`; statistics and input on main (userInteractive). Hang watchdog thread `.userInteractive`, 2 wakes/s. libwebrtc thread priorities not checked in the binary | – | Fine. Watchdog could drop to `.utility` (P12) |
| Timers | 13 periodic sources were inventoried (appendix A). While streaming, the main thread woke about 8.5 times/s on top of statistics, and none of the timers set a tolerance | small CPU, but E-core wakeups and main-thread contention with input | **Fixed in part** (§4) |
| Logging | None per frame. `StreamDebug` and the statistics JSONL are opt-in [S] | – | Good |
| Retained buffers | `lastBuffer` holds one surface for the idle refresh and is dropped on stop and on region change [S]. `PeerMedia.factory` (three libwebrtc threads) lives for the whole process after the first session [S] | a few MB after the first session [E] | Measure footprint before, during and after a session (§5) |
| Per-frame allocations | Attachment bridging `as? [[SCStreamFrameInfo: Any]]`, plus an `RTCVideoFrame` and `RTCCVPixelBuffer` for each frame [S] | µs per frame [E] | Ignore |
| WebRTC build | stasel M153 release xcframework, universal (x86_64 + arm64) [S]. The app is arm64-only (D35) | download size only, no RAM | Thin with `lipo` at archive time (P14) |
| **Build under test** | The installed host is a **Debug** build (orchestrator notes) | `-Onone` Swift in capture, push and counters | Benchmark the Release configuration (§5) |

### Main-thread and IPC chatter while streaming [S]

- **Capture status sent twice.** The lifecycle timer sends `capture` status at 4 Hz. The capture's 0.4 s health tick also called `captureHealthChanged` on main every time, without deduplication. Each call ran an `AXIsProcessTrusted`, a curtain reconcile and another full `capture` send with JSON encoding. That is about 6.5 status messages a second where 4 are enough. **Fixed** (§4).
- **`AXIsProcessTrusted()` per input event** (`HostModel.swift:1446`, in `receive`), plus the 4 Hz lifecycle and 1 Hz permission checks (the 2.5 Hz health path now only runs on a change).
  - As far as I know, this is a synchronous TCC preflight with an XPC call to `tccd` [E, to confirm with a microbenchmark].
  - At 60–120 pointer moves a second, a scheduling delay in `tccd` on a busy Mac adds straight to input latency.
  - The OS already enforces Accessibility when events are posted, so a cached answer refreshed by the 4 Hz lifecycle tick is as safe. Proposal P3.
- **Diagnostics trigger view updates.** `RemoteCoordinator.diagnostics` changes every second. `HostModel` forwards all of `connection.objectWillChange` (`:293`), so `App.body` is re-evaluated at 1 Hz. That rebuilds the menu-bar `NSImage` and, while the popover or setup view is alive, `viewState`. `viewState` called `Host.current().localizedName`, which resolves the host's addresses and can block. **Fixed** with `SCDynamicStoreCopyComputerName`. Splitting diagnostics out of the model is P10.
- **Pointer telemetry** runs a 60 Hz main-thread timer (2 ms leeway) with a `CGEvent(source:nil)` allocation per tick for the whole session, even when the phone never asked for it (`HostPointerTelemetry.swift:32`). Proposal P9.

## 2. Phone decode and render path

H.264 is decoded by hardware VideoToolbox (asynchronous), goes through `FrameObserver` and `RestampingRenderer`, and is drawn by `RTCMTLVideoView` without a CPU copy [S]. The findings below came from a sub-agent's read-only audit, and I verified 3 and 5.

| # | Finding | Cost | Status |
|---|---|---|---|
| 1 | The video view runs at a fixed 120 Hz with its draw loop always on, and `VideoPresentationProbe` re-asserts 120 after every draw (`VideoPresentationProbe.swift:121–154`). A static desktop keeps the panel and main thread at 120 Hz | Probably the largest steady drain on the phone battery [E] | **P2**: drop to 30 after ~0.5 s with no new frame. Restore 120 and draw immediately when the next frame arrives |
| 2 | The Mac picks 120 fps from its own display alone. A 60 Hz phone (non-Pro iPhones, most iPads) then decodes 60 frames/s it never shows. The ladder may also read the superseded frames as phone overload | Double the encode, network and decode | **P4**: the heartbeat carries `maximumFramesPerSecond` and the host caps its target. Only matters for 120 Hz sources |
| 3 | `fresh = true` at 4 Hz and `link` / `streamSummaryLines` at 1 Hz always publish, even when unchanged. That re-renders the 2,470-line `NativeSessionView` about 6 times a second | main-thread time | **Fixed** (§4) |
| 4 | The full WebRTC statistics report is parsed on main every second, even with statistics hidden | ~1–3 ms/s [E] | P11: parse off-main |
| 5 | A 20 Hz pointer timer runs all session. With current hosts it only calls `clear()`, which re-published `point` | 20 wakes/s | `clear()` now publishes only on change (**fixed**). Gating the timer is P13 |
| 6 | Video keeps decoding and drawing under the privacy shield while `.inactive` | short-lived | P13 |

Already good [S]:

- The pointer overlay's display link runs only while the pointer moves.
- The halftone art is capped at 30 fps and pauses in Low Power Mode, with Reduce Motion, off-screen or in the background.
- Going to the background sends `pause` and tears down the surface.
- Two drawables.
- The mini map's second view exists only while it is shown.
- Low Power Mode and "serious" thermal state feed the ladder.

## 3. What degrades on a loaded base M1 with 8 GB, and the mitigations

Each mitigation is chosen so that it costs nothing when the resource is free.

| Resource under contention | What degrades in Farside | Signal available today | Mitigation (quality kept when resources are free) |
|---|---|---|---|
| **Media engine** (FaceTime/Zoom, a video export, Safari's WebRTC). An M1 has one encode engine [3P, prior report] | VT service time rises, frames queue in VT and latency goes from 13 to 40 ms; then the ladder cuts fps or size | `encodeLatencyP90`, `encodeInFlightMax` (encoder trace) | **P1:** newest frame wins at 1 in flight, so a stale frame is dropped at submit instead of queued. The ladder then reacts only if drops exceed 5 % of fps (existing trigger). **P5:** `PrioritizeEncodingSpeedOverQuality` in a custom encoder, gated by legibility |
| **CPU, P- vs E-cores** (Xcode indexing, Electron apps, browser JS) | Main-thread input handling and statistics; WebRTC network, pacer and SRTP threads; the host's `tccd` round trips | load average only | Keep the hot path event-driven and off main (§1 fixes, P3, P9–P11). QoS stays `.userInteractive` only for capture and input. Everything periodic gets tolerance so it coalesces onto already-awake cores [D, timers] |
| **GPU** (WebGL tab, video playback, a game) | SCK's composite, scale and YUV conversion runs in WindowServer on the GPU. Capture latency and missed frames rise | `captureLatencyP90`, `captureFPS`, `captureBehind` trigger | Capture fewer pixels (G4 crop, client cap: on). Prefer integer scale ratios (P15, research). The ladder's rate step (60 → 45 → 30) needs no key frame |
| **Memory pressure, 8 GB** (Safari tabs, Electron, Xcode) | Page faults on the host's first touch of code or data after idle. Capture surfaces (32–51 MB) and VT reference and pool memory compete. Swapping shows up as frame-time outliers, not steady slowness [E] | none | **P6:** a `DispatchSource` memory-pressure source. At `warn`: `queueDepth` 5 → 4 (never below 3) and a ladder input "memory". At `normal`: restore. **P12:** keep the idle footprint low (helper and watchdog trimming, done in part) |
| **Thermal**, fanless Air | Sustained SCK + VT + Wi-Fi heats the Air. macOS throttles P-cores and the media engine | `ProcessInfo.thermalState` into the ladder, step at `.serious` [S] | Already there. Add `thermalStateDidChangeNotification` so a change applies at once rather than on the next 1 s sample (minor) |
| **Wi-Fi / AWDL** (AirDrop, Handoff, iPhone Mirroring, Universal Control) | A ≥ 98 ms arrival gap in every second at the phone, with loss 0 % [M]. Turning AirDrop and Handoff off reduced it to 52 % of seconds [M]. This is the largest p95 term | phone arrival-gap histogram | Apps can't turn AWDL off. **P16:** detect the once-a-second gap signature from the statistics already collected and show a one-line hint ("AirDrop, Handoff or iPhone Mirroring on your Mac adds stutter") with a settings link. Prefer Ethernet, or 5/6 GHz |
| **Disk** (Spotlight, sync clients, Time Machine) | Hardly anything: nothing touches disk in the streaming path. The statistics log is opt-in, and watchdog heartbeats are written every 10 s | – | None needed |

## 4. Changes made in this branch

**Verified 30 Sep, after the quiet window** (Debug, DerivedData `…/DerivedData/efficiency`, under the build lock): host build succeeded; `RemoteCoreTests` 709 tests, 0 failures (7 skipped); `HostUISnapshotTests` 15/15; `RemotePhoneTests` 301, 0 failures (1 skipped) on an iOS 27 iPhone 17 simulator, with `AnywhereStoreKitTests` excluded (it hung on a StoreKit purchase in the plain scheme; it has its own runner, `script/verify-storekit.sh`, and nothing here touches it). Still pending: phone UI suite, real-host E2E, and the physical checks in §6a.

The changes don't alter behaviour. They remove duplicate or unobserved work, or give timers slack. Every one needs `RemoteCoreTests`, the host tests, the phone unit and UI suites, and one real-host E2E pass before merge.

| File | Change | Why it is safe |
|---|---|---|
| `RemoteHost/RemoteCapture.swift` | 40 ms leeway on the 0.4 s health and idle-refresh timer | Health goes stale after 0.8 s and the idle refresh threshold is 0.45 s; 40 ms of slack changes neither |
| `RemoteHost/HostModel.swift` | `captureHealthChanged` returns early when health hasn't changed (the first unhealthy report still records `captureUnhealthySince`) | The 4 Hz lifecycle timer already does the Accessibility check, the curtain reconcile (including the time-based `unhealthyFor`) and the `capture` send. Input tokens (1 s life) are still refreshed every 250 ms |
| same | Mac name from `SCDynamicStoreCopyComputerName` instead of `Host.current().localizedName` (`viewState`, pairing name) | Same computer name, read from configd without name resolution. `nonisolated` so the pairing closure can call it |
| same | Tolerance: permission poll 0.2 s (1 s timer), lifecycle 25 ms (0.25 s timer) | Apple suggests ≥ 10 % [D]. Lock, activation and permission fast paths are notification-driven |
| `RemoteHost/BrowserMediaSession.swift` | 20 ms tolerance on the 0.2 s browser-session timer | as above |
| `RemoteShared/PeerMedia.swift` | 0.1 s tolerance on the 1 s statistics timer (host and phone) | The ladder and busy state work on whole seconds |
| `RemoteWatchdog/WatchdogSupervisor.swift` | The helper runs the `NSRunningApplication` query and reads the hang note only when judging an unexpected exit (`!alive && !cleanExit`) | `WatchdogPolicy.decide` reads neither while the host is alive or after a clean exit (`HostWatchdogState.swift:158–168`) |
| `RemotePhone/RemotePhoneApp.swift` | `fresh`, `link` and `streamSummaryLines` are assigned only when they change | Same values; SwiftUI just stops re-rendering the session view for no-op sets. `TimelineView`s drive the time-based UI |
| `RemotePhone/PointerLocator.swift` | `clear()` publishes `point = nil` only when it isn't already nil | Same state |
| `bench/load/*` | Load generators and a sampler (§5). Scripts only; nothing ran. They refuse to start while `/tmp/farside-quiet` exists | Not shipped |

## 5. Realistic-load benchmark

### 5.1 Principles

- Keep the protocol in `SESSION-PROTOCOL.md`: one variable per run, the still / motion / taps pattern, statistics on, and switches recorded in every sample.
- A run is a **(machine, load profile, build)** triple. Always compare against the same load **without** Farside, so the host's own cost can be separated from the load's.
- **Release configuration only.** Build the host Release for these runs, or at least record that it is Debug.
- AC power and battery are separate runs, because a fanless Air behaves differently on each. Record the thermal state at the start and the end.

### 5.2 Load generators (`bench/load/realistic-load.sh`, committed, not run)

| Profile | What it does | Stands in for |
|---|---|---|
| `cpu-bg N` / `cpu-fg N` | N × `yes`. `-bg` runs under `taskpolicy -b`, so E-cores first | background indexing / a foreground compile |
| `ballast GIB` / `ballast-8gb` | `ballast.py` holds incompressible random pages and re-touches every page every 2 s. `ballast-8gb` holds (RAM − 8 GiB) | an 8 GB Mac's missing RAM |
| `pressure warn\|critical` | `memory_pressure -l` | the OS pressure states themselves |
| `gpu [ITERS]` | `gpu-load.html` in Safari: a full-window WebGL2 shader at display rate | a busy browser tab or game |
| `vt` | `ffmpeg … h264_videotoolbox -realtime 1` at 1080p30, 3 Mb/s | a FaceTime or Zoom call encoding beside Farside |
| `disk` | a 2 GiB `dd` write/read loop | sync clients, Spotlight |
| `apps` | Safari with 5 tabs, Slack/Cursor/Notion/WhatsApp (Electron, whichever is installed), Xcode with this project idle, Music | "some apps open" |
| `typical` | apps + gpu 32 + 2 background CPU | an everyday Mac |
| `m1-8gb` | `typical` + `ballast-8gb` | a base M1 8 GB, memory side |
| `heavy` | `m1-8gb` + vt + disk + 2 foreground CPU | a bad day |

### 5.3 Metrics and how they are collected

| Metric | Source |
|---|---|
| Host CPU %, energy impact, threads | `bench/load/sample-host.sh` (`top` one-second interval: `cpu`, `power`, `th`), helper too |
| phys_footprint | same script, `footprint -p` every 5 s (check the parse once by hand). Record before connect, at 60 s of streaming, and 30 s after disconnect (a leak or retention check) |
| System memory pressure, swap, compressor, CPU speed limit | same script (`kern.memorystatus_vm_pressure_level`, `vm.swapusage`, `vm_stat`, `pmset -g therm`) |
| Package power | `sudo powermetrics --samplers cpu_power,gpu_power,thermal -i 1000` (Roshan runs it; needs sudo) |
| Encode ms p50/p95, in flight, dropped at submit, capture fps and gap, sent fps, ladder rung, busy | the host's own statistics JSONL, `bench/stats_summary.py`, `bench/mac_active.py` |
| Delivered/presented fps, distinct/s, glass p50/p95, arrival-gap max | the phone export, `bench/ab_summary.py` (motion windows) |
| Touch-to-visible | the existing 240 fps camera harness (run C calibration, then per profile) |
| Legibility | `script/perf/legibility.sh` on chart snapshots per profile. A ladder step must show up as a CER change, never a hidden one |
| Phone battery and thermal | Instruments Energy Log on the device during a 10-minute static + 10-minute motion session, before and after P2 |

**Matrix (M4, one session ≈ 45 min):** {quiet, typical, m1-8gb, heavy} × {Farside off, streaming Sharper at Fill}. Then P1 on/off under `heavy` only. Each streaming run is 90 s: 20 s still, 50 s motion, 20 s taps.

**Pass marks for "the same experience under load":**

- `typical` within 10 % of quiet on glass p50 and on delivered fps.
- `m1-8gb` holds ≥ 55 fps delivered at rung 0 with glass p95 ≤ quiet + 15 ms.
- `heavy` steps at most one rung and recovers within 15 s of the load stopping.
- The host adds ≤ 1 swap-in burst per minute (compare pressure and swap with Farside off).

### 5.4 Approximating an 8 GB M1 on the 16 GB M4 Air

| Can be approximated | How | Can't be |
|---|---|---|
| Free RAM and pressure level | `ballast-8gb` (8 GiB of incompressible, re-touched pages) plus the app set. Confirm the pressure level reaches `warn` with the app set and not without it | M1 memory bandwidth (68 vs 120 GB/s) |
| Swap and compressor behaviour | the same, from the sampler columns | M1 SSD latency when swapping (the 256 GB base drive is slower) |
| Media-engine contention | the `vt` profile | **M1 H.264/HEVC encode time per MP.** The whole encoder budget, and whether 2560 Sharper holds 60 fps at one frame in flight |
| GPU contention | the `gpu` profile | the M1's 7/8-core GPU and SCK composite time |
| CPU contention | `cpu-*` | 4P+4E vs 4P+6E and M1 core speed. `taskpolicy` can't remove cores |
| Thermal | – | **When the fanless M1 Air throttles** during a 30-minute session |

## 6. Proposals (not implemented: each can affect quality or needs a device)

Ranked by expected impact on a loaded base M1.

| # | Proposal | Expected effect | Risk / gate |
|---|---|---|---|
| **P1** | Newest frame wins on by default (`encoderMaxInFlight = 1`, or 2 if drops are visible). The ladder keeps `droppedBeforeEncode > 5 %` as its trigger, so it only steps down when drops are sustained | Holds VT latency at about one service time under contention, with no pixel loss | May drop frames under motion. Protocol run E7, then the `heavy` profile. Watch distinct/s and presented fps |
| **P2** | Phone: idle video view drops to 30 Hz (or pauses) after ~0.5 s without a frame. `FrameObserver` restores 120 and draws immediately on arrival | Large phone battery and thermal saving on static desktops [E] | Latency of the first frame after idle if the immediate draw is missed. Glass p50 A/B plus Energy Log |
| **P3** | Cache Accessibility trust. The lifecycle tick refreshes it (≤ 250 ms stale) and input events read the cache | Removes 60–120 `tccd` round trips a second while dragging | Needs a microbenchmark of `AXIsProcessTrusted` first. Revocation is still enforced by the OS |
| **P4** | The phone sends `maximumFramesPerSecond` on heartbeats and the host caps `targetFPS` at it | Halves encode, network and decode for 120 Hz host → 60 Hz phone | Protocol field (`SessionFeature`). Old phones send nothing, so the behaviour is unchanged for them |
| **P5** | A codec-agnostic VT encoder (already planned for HEVC) that sets `PrioritizeEncodingSpeedOverQuality` and `MaxFrameDelayCount = 1`, and uses the session's pixel buffer pool attributes [D] | Lower service time, so less queueing on an M1 | Text quality: gate on CER at 9/11 pt. Needs the HEVC-spike wrapper |
| **P6** | Memory-pressure source (`DispatchSource.makeMemoryPressureSource`) [D]: at warn, `queueDepth` 5 → 4 and a ladder reason "memory"; restore on normal | Up to ~6 MB per surface back; avoids swap-induced stalls [E] | Fewer SCK surfaces can stall at 60 fps if the encoder holds several (P1 makes that safer) |
| **P7** | Static re-push backs off from 0.8 s to 1.6 s after 3 identical re-pushes, still under the phone's 2 s freshness gate | ~half the static-screen encodes | Encoder refinement of static text and the freshness gate. Phone test |
| **P8** | Probe: with a G4 crop, does SCK deliver `.complete` frames for changes outside `sourceRect`? If so, skip delivery when `dirtyRects ∩ crop = ∅` | Skips encodes caused by off-crop animation (Slack GIFs, a video in another window) | None for quality if the probe confirms. Needs the probe |
| **P9** | Pointer telemetry at 4 Hz until the phone opts in, then 60 Hz | −56 main wakes/s when unused | Pointer feature owner to review |
| **P10** | Publish per-second diagnostics separately so `App.body` and the menu-bar image don't rebuild every second. Memoize `HostMenuBarIcon.image` per state | 1 Hz full-model invalidation gone | Touches view data flow and appearance handling |
| **P11** | Phone: parse the statistics report off-main, and skip summary strings when statistics are hidden | 1–3 ms/s of phone main-thread time | Low |
| **P12** | Idle trim: the hang watchdog on a 1 s `DispatchSourceTimer` at `.utility`, with the probe skipped when no threshold applies. The helper polls 10 s while the host is alive (curtain: 1 s), 30 s after a clean quit, with a launch notification to catch restarts. Heartbeat directory creation once | Fewer idle wakeups on a Mac where Farside is always running | Detection-latency trade-offs are safety features. Owner review |
| **P13** | Phone: run the 20 Hz pointer timer only when the host lacks pointer telemetry, and disable the video surface under the privacy shield | 20 wakes/s; brief decode while shielded | Low |
| **P14** | `lipo -thin arm64` the WebRTC framework at archive time | smaller download, no runtime change | Release-pipeline owner |
| **P15** | Research: SCK scale ratio. 2880→2560 is a non-integer resample in WindowServer (GPU) and softens text; compare with 1:1 crops and 2:1 | GPU time and legibility | Measurement only |
| **P16** | AWDL hint: detect ≥ 80 ms once-a-second arrival gaps with 0 % loss for 10 s and show a one-line hint | The single biggest p95 improvement available to users [M] | UX copy; no auto-changes |

## 6a. Decisions implemented (30 Sep, after Roshan approved P1, P2 and P16)

**P1 — newest frame wins is the default.**

- `StreamTuning.tuned.encoderMaxInFlight = 1`. `PocketDeskEncoderMaxInFlight` still overrides it: `0` lets frames queue, `2` allows two in flight.
- Runtime switch: host Settings → General → **Newest frame wins** (`NewestFrameWinsSwitch`, defaults key `PocketDeskNewestFrameWins`). `DesktopH264Encoder.encode` reads it on every frame, so an A/B needs no reconnect.
- Statistics samples and diagnostics carry `StreamTuning.liveSummary`. The canonical tuned string now ends `· max in-flight 1`, plus `· newest-frame-wins off` while the switch is off.
- **Release gate:** before release it must pass the physical no-visible-drop check. That is run E7 in `SESSION-PROTOCOL.md`, switch on vs off, quiet and under `realistic-load.sh start heavy`, with distinct/s, presented fps and dropped-at-submit per second read beside the phone. The ladder still steps down if drops exceed 5 % of fps.

**P2 — the phone drops to 30 Hz while the Mac picture is static.**

- `VideoRefreshPolicy` in `VideoPresentationProbe`. After `idleAfter` = 0.25 s with no new decoded frame and no user activity, the WebRTC Metal view's `preferredFramesPerSecond` (MTKView's display-link rate) goes to 30.
- It returns to the chosen maximum (120 on ProMotion) at once on any of these:
  - **new frame:** `FrameObserver` → `frameForwarded()`, from the decode thread. The main hop raises the rate and calls `metalView.draw()` immediately, so the first changed frame never waits for an idle tick.
  - **touch:** `NativeTrackpadSurface.touchesBegan/Moved`.
  - **pan/zoom:** `viewport.offset` / `viewport.zoom` changes.
  - **pointer motion and any other input:** `PhoneRemoteModel.transmit`.
- A frame still waiting at a draw counts as activity.
- Phone experiment key `PocketDeskIdleVideoRefresh` (default on; "Previous stream tuning" turns it off). When off, the summary says `no idle refresh`.
- With the Mac's static re-push every ~0.8 s, the view is at 120 Hz for about 0.25 s of each 0.8 s on a still desktop. P7 would stretch that further.
- To verify on device: glass p50/p95 on the first frame after ≥ 1 s idle (the camera or the marker), `presentedAt120Share` during motion unchanged, and Instruments Energy Log on a static desktop, before and after.

**P16 — Wi-Fi stall tip (AWDL).**

- `WiFiStallDetector` / `WiFiStallTip` (`RemoteShared/WiFiStallDetector.swift`) reads the phone's existing per-second `StreamStatsReport`.
- A second counts only with motion (received ≥ 20 fps), loss ≤ 1 %, a non-relay route, and the Mac capturing and pacing on time (host capture gap p90 ≤ 40 ms, pacer ≤ 30 ms). It is a stall when its largest frame-arrival gap is ≥ 80 ms.
- The tip shows when ≥ 7 of the last 10 counted seconds stall, and clears at ≤ 2.
- Tip text: "Wi-Fi hiccups every second — turning off AirDrop/Handoff on your Mac can smooth this".
- **Integration point for `farside-connection-health`:** `PhoneRemoteModel.wifiStallTip` (`@Published`, nil when not seen; reset at session start and end). Connection Health should render it as a non-blocking tip beside its live-session state (for example under `networkSlow`), with `title` and `detail` from `WiFiStallTip`. Nothing on this branch displays it, so the two branches don't conflict.
- Thresholds come from the 29 Sep baseline (a ≥ 98 ms gap in every one of 115 windows with AirDrop on; 52 % of seconds with it off). Confirm them on the next phone session: the tip should appear within about 10 s of motion with AirDrop on and never with the Mac on Ethernet.

## 7. Apple documentation (verified 30 Sep via the developer.apple.com JSON endpoints and the macOS 27 SDK headers)

- **ScreenCaptureKit:**
  - `SCStreamConfiguration`: `queueDepth` (default and minimum 3, maximum 8, deeper uses more memory); `minimumFrameInterval`; `pixelFormat` (420v/420f for encoding); `captureResolution`; `width`/`height`.
  - `SCFrameStatus.idle`: no new surface, so skip encoding.
  - `SCStreamFrameInfo.dirtyRects`.
  - WWDC22 [10155](https://developer.apple.com/videos/play/wwdc2022/10155/) and [10156](https://developer.apple.com/videos/play/wwdc2022/10156/).
- **VideoToolbox:**
  - `kVTCompressionPropertyKey_RealTime`, `MaxFrameDelayCount` (default unlimited), `PrioritizeEncodingSpeedOverQuality`, `ExpectedFrameRate`, `AllowFrameReordering`.
  - `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` (WWDC21 [10158](https://developer.apple.com/videos/play/wwdc2021/10158/)).
  - `RequireHardwareAcceleratedVideoEncoder`.
  - `MaximizePowerEfficiency`: may be ignored with RealTime, per the header.
  - `VTCompressionSessionGetPixelBufferPool`: mismatched attributes mean an internal conversion.
  - `ReferenceBufferCount` (header).
  - Decode: `kVTDecodeFrame_1xRealTimePlayback`. The decompression header says `MaximizePowerEfficiency` with `RealTime` is undefined behaviour.
- **iOS display:**
  - `CADisplayLink.preferredFrameRateRange` and `CAFrameRateRange`.
  - "Optimizing iPhone and iPad apps to support ProMotion displays".
  - WWDC21 [10147](https://developer.apple.com/videos/play/wwdc2021/10147/).
  - `ProcessInfo.thermalState` and `thermalStateDidChangeNotification`; `isLowPowerModeEnabled` (iOS and macOS 12+).
- **macOS scheduling and energy:**
  - "Tuning your code's performance for Apple silicon" (QoS and core types).
  - Tech Talk [110147](https://developer.apple.com/videos/play/tech-talks/110147/).
  - Energy Efficiency Guide for Mac Apps, archived: [Timers](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html) (≥ 10 % tolerance), App Nap, thermal notifications.
  - `Timer.tolerance`; `DispatchSource.makeMemoryPressureSource`; `ProcessInfo.ActivityOptions.latencyCritical` ("very few apps").
  - `man memory_pressure` (local; no developer.apple.com page).
- **Unverified:** no Apple source compares the power of `AVSampleBufferDisplayLayer` and Metal. The cost of `AXIsProcessTrusted` per call is my inference (P3 benchmarks it).

## 8. Needs from Roshan

1. **Access to a real base M1**, ideally a MacBook Air with 8 GB and a 256 GB drive, for one 45-minute session: the §5 matrix plus a 30-minute sustained run on battery. Borrowed is fine; the host is a single app (Release build) plus its helper.
2. **One phone session on the M4** (≈ 30 min): E7 (P1) under `quiet` and `heavy`, then the `typical` / `m1-8gb` pair. A `sudo powermetrics` terminal during it.
3. **Decisions:**
   - whether P1 may become the default if E7 shows no visible drops;
   - whether P2's 30 Hz idle on the phone is acceptable (it changes nothing while the picture moves);
   - whether the AWDL hint (P16) belongs in the product.

## Incident

At about 08:58 EDT, a file-write hook opened the new `bench/load/gpu-load.html` in Claude's embedded Browser pane, which started the WebGL load page, for a few seconds. I closed both tabs at 08:59. When I checked at 08:59:20, `/tmp/farside-quiet` no longer existed, but I can't tell whether it was still present at 08:58. A physical phone test running around 08:58 may have seen brief GPU load on the Mac.

## Appendix A: periodic work inventory (host, static)

| Where | Interval | When | Notes |
|---|---|---|---|
| `HostModel` permission poll | 1 s (tolerance 0.2 s now) | always | TCC ×2, `CGSessionCopyCurrentDictionary` |
| `HostHangWatchdog` | 0.5 s sleep + main probe | always | P12 |
| `HostWatchdogReporter` | 10 s (1 s with curtain), 10 % | always | atomic JSON write |
| `WatchdogSupervisor` (helper) | 3 s alive, 1 s curtain, 2 s host not running, 25 % | always, including after quit | LaunchServices query now only when judging an exit |
| `HostModel` lifecycle | 0.25 s (tolerance 25 ms now) | streaming | lease, AX, curtain, `capture` send |
| `RemoteCapture` health / idle refresh | 0.4 s (leeway 40 ms now) | streaming | still hops to main every tick; `captureHealthChanged` now returns early unless health changed |
| `HostPointerTelemetry` | 1/60 s, 2 ms | streaming | P9 |
| `PeerMedia` statistics | 1 s (tolerance 0.1 s now) | connected | parse on main |
| `BrowserMediaSession` | 0.2 s (tolerance 20 ms now) | browser session | – |
| Keep-awake | assertion, no timer | sharing on (system sleep), phone connected (display) | intentional |
