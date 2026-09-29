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

## 1. Phone session, 29 Sep 2026 10:09–10:45: encoder runs A1–A3, AWDL B2, camera C, observer D

**Setup.** Phone build 20260929.4 (instruments), host 5b235bb (encoder trace, clock echo). Built-in display 2560×1656 ("looks like" 1920×1243), bench = FarsideE2E Test Pad `--bench`, seed 1449, Sharper 25 Mb/s unless noted, Fill. The orchestrator ran the Mac side; Roshan held the phone and the DJI camera (1080p, 240 fps). Load average at run starts 2.5 / 2.2 / 2.8 / 2.4. **Contamination:** the fork's backend agent ran vitest 10:06–10:13 (A1), its full suite 10:30–10:38 (A3) and a 100-room WebSocket load test 10:40–10:42 (B2 tail, D start); A2 is the cleanest run. Stats samples carry no wall-clock time; the phone rows were aligned to the Mac log by cross-correlating the host summary's `encodedFPS` (`scratchpad/session/align.py`, 79–100 % agreement), and only motion windows count (`bench/ab_summary.py --rows`, marker distinct ≥ 20/s). Windows (phone export row : Mac log line): A1 export 2 rows 1262–1298 : lines 2235–2271; A2 export 3 rows 1398–1502 : 2376–2480; A3 export 4 rows 1637–1716 : 2618–2697; B2 export 5 rows 1854–1923 : 2840–2909; D stats-on export 5 rows 1967–2019 : 2953–3006, stats-off Mac lines 3007–3234.

**Per-run figures** (phone export, motion windows; Mac-side figures from `mac_active.py` where marked ᴹ):

| | A1 Sharper 25 Mb/s | A2 Sharper 12 Mb/s | A3 Responsive 1920×1242 | B2 AirDrop+Handoff off | D stats on |
|---|---|---|---|---|---|
| VT lat p50/p90 ms | 23.1 / 31.6 | 22.4 / 25.8 | **13.1 / 15.7** | 20.6 / 24.6 | 37.4 / 40.9 |
| in-flight max (p50 ᴹ) | 5 (3) | 3 (2) | 2 (1) | 5 (3) | 3 (3) |
| capture fps p50/p90 ᴹ | 49.9 / 58 | 45 / 50 | 46 / 50 | 54 / 58 | 57 / 58 |
| encoded fps p50 | 49 | 44 | 46 | 54 ᴹ | 57 |
| decoded / shown p50 | 50 / 40.7 | 44.3 / 35 | 46 / 35.1 | 55 / 50 | 57 / 42 |
| superseded/s | 8 | 10 | 11 | 8 | 14 |
| gap max p50 ms / seconds with a ≥ 80 ms gap | 106 / 100 % | 110 / 100 % | 109 / 100 % | 98 / **52 %** | 102 / 67 % |
| glass p50/p95 ms (overlay, uncalibrated) | 64.2 / 92.7 | 63.8 / 106.2 | **55.8 / 83.5** | 73.5 / 97.8 | 84.9 / 111.4 |
| distinct/s | 41 | 34 | 35 | 50 | 41 |
| rtt p50/p90 ms | 7 / 60 | 7 / 60 | 7 / 77 | 8 / 49 | 7 / 94 |
| click→photon p50 ms | – | 109 | 130 | – | 125 |
| `limit cpu` seconds | 0 % | 0 % | 0 % | 0 % | 0 % |
| rate updates/s ᴹ | 2 | 2 | 2 | 2 | 1 |

**Encoder root cause (runs A).** VideoToolbox's latency is the number of frames inside it times its service time: ≈ 13 ms per frame at 4.2 MP (2560×1656) and ≈ 8 ms at 2.4 MP (1920×1242). With one frame in flight the latency is 13 ms (A3, and the "good" state of the baseline); with two it is 22–24 ms (A1, A2); with three, 38–41 ms (D and B2's 58 fps stretches). At 58 fps a 4.2 MP frame arrives every 17 ms and takes 13 ms, so the engine runs near saturation and any slowdown leaves a permanent queue of 2–3 frames that libwebrtc's H.264 wrapper never limits; the queue is the whole of the 30–42 ms state. Halving the bitrate (A2) trims only the tail (p90 31.6 → 25.8) — bitrate is secondary. Rate updates run at 1–2/s in every run with no relation to the latency, so the property-set hypothesis (H-B) is out. `qualityLimitation` was never `cpu`: libwebrtc's overuse detector did not cut the rate in these runs; the 44–50 fps of A1–A3 is capture-side (`captureFPS` ≈ `encodedFPS`, with `captureIdleFPS` 4–9 and `captureGapMax` 46–53 ms, i.e. SCK skipped frames during the contaminated runs), while the clean stretches of B2 and D captured 57–58. Consequences: (1) the 120-fps tier on this M4 Air cannot use H.264 at phone pixels — 8.3 ms per frame allows ≈ 2.6 MP with one frame in flight, so it needs the G4 crop (reading zoom ≈ 1.5 MP) or HEVC; the phone-pixel cap alone (3.2 MP, ≈ 10 ms) tops out near 100 fps; (2) the newest-frame-wins gate (queue row 15, `PocketDeskEncoderMaxInFlight 1`) attacks the dominant encoder term directly and should be A/B'd first in the next session (run E7 in the protocol); (3) the ladder's backlog trigger should fire at in-flight ≥ 2, not 3.

**AWDL verdict (run B2): implicated, not proven.** Every motion second of A1, A2 and A3 (AirDrop on) had a ≥ 80 ms render gap; with AirDrop receiving and Handoff off on both devices, 52 % of B2's seconds had one, and B2's first 15 s of motion were the day's only gap-free stretch (gap max 21–28 ms, 58 fps decoded and 54–58 shown, superseded ≈ 0). The gap then returned within the same run. `awdl0` read UP at 10:40:10, so the interface was never confirmed down, and 49–67 % of the following seconds (AirDrop state unknown) had the gap. Next: repeat B2 with `sudo ifconfig awdl0 down` confirmed by `ifconfig awdl0 | grep status` and once on Ethernet; a gap-free run at 58 fps would also show the ceiling the 120 target has to clear.

**Glass-to-glass.** Overlay p50 56–85 ms, p95 84–111 ms across runs against the ≤ 40 / ≤ 60 ms targets; A3's smaller picture buys 8 ms at p50 and 9–23 ms at p95 (the VT term). D's 85 ms p50 is the three-frame encoder queue (VT 37 ms). The camera calibration (run C, clips A1/A2/A3/B2, analysed on the PC) is pending: `camera-calibrated glass = …` [to be filled from the DJI analysis: camera median vs overlay p50 per run, and the panel constant].

**Observer effect (run D).** Mac side, active seconds only: stats on vs off — capture 57 vs 56 fps, encoded 57 vs 57, VT lat p50 38.0 vs 27.8 (p90 41.0 vs 39.9), sent 1316 vs 1198 kb/s, RTT p50 8.5 vs 18 ms (the WebSocket load test overlapped the start of D). Nothing on the Mac side changes with the phone's statistics on. Phone side (the 49.5 s screen recording at ≈ 54 fps, stats on then off): delivered-cadence comparison pending from the PC analysis [to be filled]. Field finding on the instruments: glass counted the idle re-pushed frames (follow-up 10); the overlay's `glass` is valid only while `distinct` > 0.

**Legibility.** Not scored this session (no chart snapshots were taken); the CER column stays empty.

**What changes in the 120 plan.** (a) H.264 at 120 fps is engine-limited to ≈ 2.6 MP per frame on the M4 Air: the tier needs the G4 crop or HEVC, and E1 on the ASUS at 3.7 MP will not reach 120 with H.264 whole-display capture — expect ≈ 70 fps there and read that as the engine, not a bug. (b) Newest-frame-wins moves up the queue: E7 is the first A/B of the next session, and its default flips on if it holds VT lat at ≈ 13 ms without visible drops. (c) The ladder reads in-flight ≥ 2 as backlog. (d) A gap-free stretch exists (B2), so the ≥ 98 ms/s gap is environmental, not structural; B2 is repeated with the interface confirmed down before any transport work. (e) The instruments hold up in the field except the idle-glass artefact (follow-up 10) and the missing timestamps (follow-up 11).

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
| 6 | G15/G16 route-aware bandwidth seed (`PocketDeskRouteAwareSeed`) | sent/target ramp, legibility at +1/+3 s on P2P and relay routes | switch built, default off; the production relay (`wss://relay.getfarside.com/signal`, forced relay via the relay env, rooms approved from Server/) is live — runs are scheduled through the orchestrator, phone on cellular for real routes |
| 7 | G9 restart floor 5 → 1.5 Mb/s with an IDR link-time budget (`PocketDeskRestartFloorKbps`, `PocketDeskRestartKeyFrameBudgetMs`) | legibility after idle, pacer max, key-frame bytes | switch built, default off; needs a thin link |
| 8 | G18 survive a transient ICE `disconnected`: `PeerMedia` reports a new "unstable" state instead of "disconnected", holds the session for an 8–10 s grace, the host calls `restartICE()` after 2 s, teardown only on `failed` or when the grace expires; coordinator shows "Reconnecting…" and the phone's 2 s frame-freshness gate already holds input | D2 blackout profile on the shaper (1 s, 3 s, 6 s); reconnects vs recoveries, time to fresh picture | batch 2, design only |
| 9 | G8 restart-on-idle: after 300–500 ms without a complete SCK frame, if the screen changed since the last clean key frame and the IDR fits the link budget (G9's gate), reuse the encoder restart once per idle period; suppressed while input is active | CER at +0.3/+1/+3 s after a chart change, key-frame bytes, pacer max | batch 2, design only |
| 10 | G17 pointer channel transport half (second data channel, unordered, no retransmits, latest-wins `sendPointer`), payload owned by the pointer agent | control-channel buffered/dropped counters, pointer gap histogram | batch 2, starts on the orchestrator's go |
| 11 | G5 120 fps: target follows the display (≥100 Hz → 120, `PocketDeskHighRefreshCapture`, `PocketDeskTargetFPS`), sender at 120 with WebRTC adaptation off by default (`PocketDeskHighRefreshNoAdaptation`), level fit and pixel budget at 120; ASUS at **120 Hz**, not 144 (uneven 6.9/13.9 ms sampling from 144 Hz vsyncs) | `targetFPS`, `captureDisplay`, capture gap median, presented fps; protocol runs E1–E4 | perf-120fps, W1 sender half in progress; pass marks in the protocol |
| 12 | Phone-pixel cap: capture long edge ≤ the phone's panel (`screenPixels` on heartbeats, `PocketDeskCapToClientPixels`) | picture size, VT lat; run E6 | perf-120fps, host side built, phone heartbeat W2 |
| 13 | G4 viewport capture: phone sends its visible Mac rect, host crops with `sourceRect` at a fixed output size and echoes `captureRegion` (`PocketDeskViewportCapture`) | encode fps and VT lat at reading zoom; run E5 | perf-120fps, W2 phone / W3 host in progress |
| 14 | G12 ladder + "Mac is busy" pill (`PocketDeskLadder`): fps steps before size, down in 2 s, up after 10 s; busy state from the same signals | `ladder`, `busy` fields; runs F0–F(d) with one load at a time | perf-120fps, W4 engine in progress; HostModel wiring is the lead's |
| 15 | Newest frame wins: drop at submit while N frames are inside VideoToolbox (`PocketDeskEncoderMaxInFlight`, Chrome Remote Desktop keeps one) — the research's reading of the 30–42 ms state as queueing inside VT; run A's in-flight figures decide whether it is worth defaulting | dropped-at-submit per second, VT lat p90, in-flight; run E7 | switch built (0adb726), default off, unchecked until the Mac is free |
| 16 | HEVC 4:2:0 feasibility spike (research §4b: 1.8× the throughput of H.264 standard; low-latency mode is 0.5× and stays off): does the stasel build negotiate H.265, M4 HEVC encode ms per frame at 2560×1656 / 2560×1440 / 2622×1206 vs H.264's 13 ms, iPhone 17 decode ms, bitrate at equal CER, capability flag + H.264 fallback design; separate from G11 (4:4:4), switch-gated, no product change until measured | `RemoteTests/HEVCProbeTests`, `RemotePhoneTests/HEVCDecodeProbeTests` (device), `Docs/perf/HEVC-SPIKE.md` | W6 in progress (probes + doc); runs after the first build round |

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
10. Glass counts idle re-pushed frames (field finding, 29 Sep session, chart visible and motion off: "glass p50 18818ms · n 3 · distinct 0.0/s" — the frame's age, not latency). Record glass only on the first presented appearance of each marker value and print "glass —" when distinct is 0 (handed to W1 with the StreamStatistics changes). Until then `bench/ab_summary.py` uses motion windows only (marker distinct ≥ 20/s) and `--rows=START:END` cuts a run by sample index.
11. Stats samples carry no wall-clock time (neither the Mac log nor the phone export), so runs can only be cut by sample order; add an `at` (ISO 8601, second resolution) field to every sample.

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
