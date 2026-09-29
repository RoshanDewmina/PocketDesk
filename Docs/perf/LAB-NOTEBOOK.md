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
