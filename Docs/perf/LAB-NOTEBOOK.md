# Performance lab notebook

One entry per experiment: hypothesis, change, conditions, before and after, verdict. Read the whole file before starting an experiment. Conditions always record power, load average and network; a number without them is not a result. Instruments: `Docs/perf/INSTRUMENTS-DESIGN.md`. Baseline: `Docs/perf/BASELINE-2026-09-29.md`.

Conventions: numbers are per-second stream statistics unless marked; **[M]** measured, **[E]** estimate; "quiet Mac" means no builds, simulators or browsers, and iPhone Mirroring closed.

---

## 0. Baseline, 29 Sep 2026 07:14–07:22

**Question.** Where does the post-tuning stream stand on a real iPhone 17?

**Conditions.** M4 Air on AC after a reboot, load ≈ 4 but the landing pass was building and testing on the Mac; iPhone Mirroring open earlier; Wi-Fi Direct route, RTT p50 6 ms p90 49–63 ms, loss 0 %. Host Debug `31900f9`, phone `20260929.3`, Sharper, stats on.

**Result [M].** Capture 58 fps, 2560×1656, H.264 5.2 hardware. Encoded 58 fps only while `encodeMs` was in its low state (14.7 ms); at 30–42 ms WebRTC's overuse detector cut to 38 fps for 59 of 136 s. Phone decode 7 ms, decoded→draw 6 ms, jitter 0.9 ms, presented 0.83 of decoded, 9–20 superseded/s. A ≥ 98 ms arrival gap in every second at the phone with capture and pacer clean. Stage sum p50 50.7 ms, p90 71 ms (no panels). `analyze.py` on the recording: 19.9 distinct updates/s, p99 gap 467 ms, 20 stalls.

**Verdict.** Two blockers ahead of any quick win: (1) encoder latency state (bimodal 14.7 vs 30–42 ms, fps collapse is a symptom), (2) once-a-second ~100 ms arrival gaps (network/AWDL suspected). Neither is root-caused yet; both get an instrument before a fix. Details and evidence in the baseline doc.

---

## 0a. Vision ceiling of the legibility chart, 29 Sep 2026

**Question.** What does the scorer read on a pristine render, so on-stream numbers have a reference?

**Method [M].** `LegibilityChartRenderer` at 2× for a 1440×932 pt display (seed 0x3a7), scored by `script/perf/legibility.sh --marker` on this Mac (Vision accurate, no language correction, look-alike folding on). The marker strip in the same image decoded to the right seed and time.

**Result [M].** CER 9 pt 18.8 %, 11 pt 7.8 %, 13 pt 4.7 %, 15 pt 10.9 %, coloured 11 pt 9.4 %; 16 of 32 cells exact. Nearly every error is a confusable pair the chart is built from (O↔0, l↔I↔1), one to three per token; one 9 pt mono token was not read at all (counted 100 %). Before look-alike folding Vision also returned Cyrillic glyphs for a few Latin ones.

**Verdict.** The scorer is usable as a relative measure: a stream that reads like the source scores ≈ 8–16 %, an unreadable size scores 50–100 %. Re-run the ceiling whenever the chart, fonts or Vision change; the same seed gives the same tokens.

## Queue

Run steps and the defaults keys for every switch: `Docs/perf/SESSION-PROTOCOL.md`.

Instrument status (29 Sep, branch tip d3ffe4e): builds and unit suites pass (RemoteCoreTests 14 classes, phone 34 tests in 5 classes, host, Test Pad, stub host); nothing has run on the physical phone yet, so the first session is also the instruments' first field check.

| # | Experiment | Instrument it needs | Status |
|---|---|---|---|
| 1 | Encoder latency: quiet-Mac repeat, Sharper 25 Mb/s vs Sharper capped at 12 Mb/s (`PocketDeskEncoderCeilingKbps`) vs Responsive; per-frame trace shows in-flight frames, bytes and rate updates | encoder trace (host summary fields) | built, awaiting install + session (protocol run A) |
| 2 | Arrival gaps: marker distinct-gap histogram with AWDL on vs off (Mac `awdl0` down, phone AirDrop off, Mirroring closed) | G28 marker | built, awaiting session (protocol run B); 2a = the orchestrator's stats-only AWDL check if Roshan runs it |
| 3 | Marker calibration against one 240 fps camera run | G28 marker, Test Pad bench clock | needs Roshan, 5 min (protocol run C) |
| 4 | G25 pointer display link 80–120 Hz range | presented cadence | handed to the pointer agent (owns PointerOverlay) |
| 5 | G1 capture `minimumFrameInterval` 1/60 vs native (`PocketDeskCaptureNativeRate`) | capture fps, marker distinct fps, glass p50 | switch built, default off |
| 6 | G15/G16 route-aware bandwidth seed (`PocketDeskRouteAwareSeed`) | sent/target ramp, legibility at +1/+3 s on P2P and relay routes | switch built, default off; relay needs the Windows shaper |
| 7 | G9 restart floor 5 → 1.5 Mb/s with an IDR link-time budget (`PocketDeskRestartFloorKbps`, `PocketDeskRestartKeyFrameBudgetMs`) | legibility after idle, pacer max, key-frame bytes | switch built, default off; needs a thin link |
| 8 | G18 survive a transient ICE `disconnected`: `PeerMedia` reports a new "unstable" state instead of "disconnected", holds the session for an 8–10 s grace, the host calls `restartICE()` after 2 s, teardown only on `failed` or when the grace expires; coordinator shows "Reconnecting…" and the phone's 2 s frame-freshness gate already holds input | D2 blackout profile on the shaper (1 s, 3 s, 6 s); reconnects vs recoveries, time to fresh picture | batch 2, design only |
| 9 | G8 restart-on-idle: after 300–500 ms without a complete SCK frame, if the screen changed since the last clean key frame and the IDR fits the link budget (G9's gate), reuse the encoder restart once per idle period; suppressed while input is active | CER at +0.3/+1/+3 s after a chart change, key-frame bytes, pacer max | batch 2, design only |
| 10 | G17 pointer channel transport half (second data channel, unordered, no retransmits, latest-wins `sendPointer`), payload owned by the pointer agent | control-channel buffered/dropped counters, pointer gap histogram | batch 2, starts on the orchestrator's go |
| 11 | G5 120 fps: target follows the display (≥100 Hz → 120, `PocketDeskHighRefreshCapture`, `PocketDeskTargetFPS`), sender at 120 with WebRTC adaptation off by default (`PocketDeskHighRefreshNoAdaptation`), level fit and pixel budget at 120; ASUS at **120 Hz**, not 144 (uneven 6.9/13.9 ms sampling from 144 Hz vsyncs) | `targetFPS`, `captureDisplay`, capture gap median, presented fps; protocol runs E1–E4 | perf-120fps, W1 sender half in progress; pass marks in the protocol |
| 12 | Phone-pixel cap: capture long edge ≤ the phone's panel (`screenPixels` on heartbeats, `PocketDeskCapToClientPixels`) | picture size, VT lat; run E6 | perf-120fps, host side built, phone heartbeat W2 |
| 13 | G4 viewport capture: phone sends its visible Mac rect, host crops with `sourceRect` at a fixed output size and echoes `captureRegion` (`PocketDeskViewportCapture`) | encode fps and VT lat at reading zoom; run E5 | perf-120fps, W2 phone / W3 host in progress |
| 14 | G12 ladder + "Mac is busy" pill (`PocketDeskLadder`): fps steps before size, down in 2 s, up after 10 s; busy state from the same signals | `ladder`, `busy` fields; runs F0–F(d) with one load at a time | perf-120fps, W4 engine in progress; HostModel wiring is the lead's |
| 15 | Newest frame wins: drop at submit while N frames are inside VideoToolbox (`PocketDeskEncoderMaxInFlight`, Chrome Remote Desktop keeps one) — the research's reading of the 30–42 ms state as queueing inside VT; run A's in-flight figures decide whether it is worth defaulting | dropped-at-submit per second, VT lat p90, in-flight; run E7 | switch built (0adb726), default off, unchecked until the Mac is free |
| 16 | HEVC tier (research §4b: 1.8× the throughput of H.264 standard; low-latency mode is 0.5× and stays off) as the ladder's codec step between fps and pixels | encode fps under load, IDR bytes | design only; after 120 lands |

Research read 29 Sep (fork's `PERF-UNDER-LOAD-AND-120FPS.md`): libwebrtc's overuse detector uses 150/200 % of the frame interval for a hardware encoder (public source, unverified in the stasel binary) — 34 ms at 58 fps matches the baseline's 38 fps episodes; 16.7 ms at 120 sits just above VT's good state, so 120 runs with WebRTC adaptation off and the app's ladder on. The stock encoder already sets `kVTCompressionPropertyKey_RealTime`, so a realtime-priority switch is not a quick win here.

## Code follow-ups from the landing review of 4ca2a30 (branch `perf-followups-1`, written, unbuilt until the lock is free)

1. Switch for the level-5.2 probe warm-up and its positive cache (the batch's only default-behaviour change); fix the cache-key comment (major.minor.patch, and `utsname.machine` is "arm64" on macOS, so the key needs `hw.model` there).
2. Show `StreamTuning.current.summary` in host diagnostics; prefer launch-argument defaults for A/Bs.
3. Clamp `rateUpdates`, `encodeInFlightMax`, `encoderSessionAgeS` at the source (a failed summary validation ends the session).
4. `DesktopH264Encoder.sharedCounters`: per-`PeerMedia` or locked, not a static weak var.
5. Word the reduced-picture notice neutrally (the Mac's probe can be the one that failed).
6. Observer-effect A/B (protocol run D) and a phone-side "marker off while stats on" switch.
7. Clamp the legibility crop (it grows with zoom²) or crop to the visible area.
8. Match clock echoes to outstanding probes.
9. Route seed: a missing RTT is unknown, not LAN.

## Code follow-ups from the landing review of 4ca2a30 (small branch after .4)

1. Switch for the level-5.2 probe warm-up and its positive cache (the batch's only default-behaviour change); fix the cache-key comment (major.minor.patch, and `utsname.machine` is "arm64" on macOS, so the key needs `hw.model` there).
2. Show `StreamTuning.current.summary` in host diagnostics; prefer launch-argument defaults for A/Bs.
3. Clamp `rateUpdates`, `encodeInFlightMax`, `encoderSessionAgeS` at the source (a failed summary validation ends the session).
4. `DesktopH264Encoder.sharedCounters`: per-`PeerMedia` or locked, not a static weak var.
5. Word the reduced-picture notice neutrally (the Mac's probe can be the one that failed).
6. Observer-effect A/B (protocol run D) and a phone-side "marker off while stats on" switch.
7. Clamp the legibility crop (it grows with zoom²) or crop to the visible area.
8. Match clock echoes to outstanding probes.
9. Route seed: a missing RTT is unknown, not LAN.

## Entry template

```
## N. Title, date

**Hypothesis.**
**Change.** (files, switch name, default)
**Conditions.** power · load average · network route/RTT · host build · phone build · content
**Before [M].**
**After [M].**
**Verdict.** keep / revert / inconclusive, and why
```
