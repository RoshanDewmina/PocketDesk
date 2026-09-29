# Performance instruments: design (29 Sep 2026)

Owner: performance lead. Status: design, sent to the orchestrator before building. Gap numbers refer to `~/reports/src/farside-vs-parsec-page/research/FARSIDE-PERFORMANCE-GAPS.md`.

Three instruments, in the order the brief asks for them. Everything runs on Roshan's real iPhone with the existing "Stream statistics" toggle and no camera; the same fields feed the JSONL export, `bench/stats_summary.py`, the phone's E2E `e2e.state`, and the lab notebook.

## 1. Per-frame glass-to-glass (G28)

**What it measures.** For every frame the phone actually presents: Mac display time → phone display time, on a shared clock, p50/p95/p99/max per second. Also the true delivered cadence (distinct frames per second), the true on-device presentation cadence (does 120 Hz engage), and click → photon for the flash target. The overlay's current "Mac display → phone draw" line is a sum of stage averages; this replaces it with a physical per-frame number.

**Stimulus: Farside Test Pad `--bench`.** The existing Test Pad target gains a kiosk-style bench mode: one borderless window covering the whole display (`NSScreen.frame`, above the menu bar), so window coordinates equal display coordinates and fractions of the window equal fractions of the captured frame at any capture size. Content:

- **Marker strip** at (0, 5 % of height), block size `s = width / 72`, four rows of 18 blocks: a sync row (alternating white/black; also gives the reader its white and black levels), then three data rows, each `[guard white][16 bits][guard black]`:
  - row A: bits 0–15 of `timeMs`
  - row B: bits 16–23 of `timeMs`, then CRC-8 (poly 0x07) of the three time bytes
  - row C: 12-bit chart seed, flash bit, motion bit, two parity bits
  `timeMs` is the frame's **target display time** (`CADisplayLink.targetTimestamp`, i.e. `mach_absolute_time` converted to ms, mod 2^24 ≈ 4.7 h), so "Mac glass" is the marker value itself, not draw time plus a guessed refresh.
- **Large ms clock** for the 240 fps camera method (replaces `bench/stimulus.html` for that step).
- **Size chart** (§2), **motion lane** (bouncing box), **scrolling code pane**, **flash target** (toggles colour and the flash bit on mouse-down; logs the mach time of the event), all driven by commands on the existing `testpad-commands.jsonl`: `bench.chart [seed]`, `bench.motion on|off`, `bench.scroll on|off`, `bench.jump`, `bench.flash`, `bench.snapshot`. Keyboard shortcuts in the bench window do the same (`c`, `m`, `s`, `j`, space), so Roshan can drive it from the phone.
- **The marker only ticks while something else moves.** During a "static" step the strip holds its last value, so ScreenCaptureKit goes idle exactly as on a real static desktop and the idle-refinement work (G8) stays measurable. Events (chart change, flash) redraw once.
- Ground truth for each chart goes to `testpad.jsonl` (`bench.chart {seed, rows}`) and the Test Pad writes its own backing-scale PNG of the chart on `bench.snapshot` (Vision ceiling, PSNR reference).

**Reader (phone).** `BenchMarker.read(luma:width:height:stride:)` in RemoteShared: ~70 pixel reads at block centres, thresholds at the midpoint of the sync row's white and black means, checks sync (≥ 16/18), guards and CRC. Called from `FrameObserver.renderFrame` on WebRTC's decode thread, only while Stream statistics is on. A frame whose marker fails silently counts as "no marker".

**Frame identity through presentation.** `RestampingRenderer` already gives every forwarded frame a unique stamp; it now remembers `stamp → (marker, arrival)` for the last few frames. In `VideoPresentationProbe.draw(in:)`, when a decoded frame is pending, the probe takes `view.currentDrawable` **before** calling WebRTC's renderer and adds a presented handler; after the draw it reads the drawn stamp (`lastFrameTimeNs`, the KVC the existing tests already use; fallback: newest pending) to attach the right marker. `MTLDrawable.presentedTime` is the phone's display time of that frame. Cost: one closure per presented frame.

**Clock alignment (phone ↔ Mac).** Cristian sync over the existing control channel: the phone's 250 ms heartbeat carries `clock: {phoneMs}` twice a second; the host echoes a heartbeat with `{phoneMs, hostReceivedMs, hostSentMs}` (Mac `mach_absolute_time` in ms, the same clock as the marker). Phone: `offset = ((t1 − t0) + (t2 − t3)) / 2`, `rtt = (t3 − t0) − (t2 − t1)`; keep the lowest-RTT sample of the last 30 s; report offset and `±rtt/2` as the uncertainty. LAN samples are 3–8 ms RTT, so the best-of-window uncertainty is about ±1–2 ms. New optional `RemoteAction.clock` field, allowed only on `heartbeat`, validated like the other probes; old peers ignore it.

**Per-second fields** (phone `StreamStatsReport`, JSONL, overlay, `e2e.state`):

| Field | Meaning |
|---|---|
| `markerFrames`, `markerDistinctFPS` | presented frames with a valid marker; distinct marker values per second (delivered cadence during motion) |
| `glassP50Ms`, `glassP95Ms`, `glassP99Ms`, `glassMaxMs` | `presentedTime − (markerMs + offset)` per presented frame |
| `clockOffsetMs`, `clockUncertaintyMs`, `clockSamples` | sync state |
| `presentedIntervalP50Ms`, `presentedIntervalP90Ms`, `presentedAt120Share` | true cadence from presented handlers; share of intervals ≤ 9 ms (120 Hz truth) |
| `inputToPhotonP50Ms`, `inputToPhotonP95Ms`, `inputToPhotonSamples` | flash-bit flip presented time − send time of the last click (≤ 1 s earlier) |

Overlay line: `glass p50 31 p95 44 max 61 ms ±2 · n 58 · distinct 59/s · shownΔ p50 8.3`. The stage-sum line stays for comparison.

**Calibration.** One 240 fps camera session (§7 step 3 of STREAM-FIX-REPORT) against the same seconds of marker data; the residual (panel response on both ends) becomes a stated constant in the notebook. The E2E stub host also draws the marker and echoes clock probes, so the simulator self-test exercises the whole reader path without ScreenCaptureKit.

## 2. Legibility score (G29)

**Chart.** `LegibilityChart` in RemoteShared, shared by the Test Pad (draws it) and the phone (scores it): 8 rows = {9, 11, 13, 15 pt} × {SF Pro, SF Mono}; each row has four tokens in four colourways: black on white, white on dark, blue on white, red on white. Tokens are 8 characters, alternating a confusable set (`Il1|O0rnmSZ5B8`) and a distinct set, generated from the 12-bit seed in the marker by a tiny deterministic PRNG, so the phone knows the ground truth without any message. Layout is in display **points** (the phone knows the display's point size from the geometry message and the frame's pixel size, so it can crop rows in pixels).

**Scoring.** `LegibilityScore` (Vision `VNRecognizeTextRequest`, `.accurate`, language correction off): one request over the chart crop, observations assigned to tokens by best edit distance (tokens are unique), CER = Levenshtein / length, 100 % when unmatched. Two crops are scored: **displayed** (the decoded frame resampled to the phone's on-screen pixel size for the current zoom, bilinear like Core Animation) and **decoded** (native stream pixels). Output per size, averaged over fonts and colourways, plus the coloured rows separately.

**When.** On the phone, automatically while Stream statistics is on and the marker carries a chart seed: at +0.3 s, +1 s and +3 s after the seed changes, then every 5 s (the "time to legible" curve after a chart change). Utility-QoS queue, ~200–400 ms per pass on an iPhone 17. Fields: `legibilitySeed`, `legibilityAgeMs`, `legibilityCER` (`9pt/11pt/13pt/15pt/coloured11pt`, percent), `legibilityDisplayedZoom`. Overlay: `legible 9pt 12% 11pt 3% 13pt 0% 15pt 0% (+1.0 s, displayed ×1.5)`.

**Screenshots.** `script/perf/legibility.swift` (single-file, `swiftc`, macOS Vision): scores any PNG (iPhone screenshot, Test Pad chart PNG) for a given seed by the same best-match assignment, so Roshan's own screenshots and the Test Pad's pristine render (the Vision ceiling) are scored the same way as the in-app number.

**What it is not.** Not a reading test; it is a repeatable relative score. Absolute Vision error on the pristine Mac render is reported next to it.

## 3. Negotiated level and sent size in diagnostics (G13)

- **Probe off the launch path and cached.** `NativeCodecCapability.warmUp()` runs the level-5.2 decode probe on a background queue at app launch (phone and host), so the first factory rarely waits. A **positive** result is cached in UserDefaults keyed by OS version and hardware model; negative and timed-out results are never cached (retried next launch). `NativeCodecCapability.outcome` records what happened: cached, probed (ms), timed out, no hardware decode, simulator.
- **Phone UI.** `LinkSummary` gains the negotiated codec level and the received picture size; the dock caption becomes `Direct · 7 ms · 2560×1656`. The Picture section shows `H.264 level 5.2 · hardware decode · probe cached` (or the failure). A physical device that negotiated below level 5.2 gets one session notice: "Reduced picture: your Mac is sending 832×538. Quit and reopen Farside to retry." The overlay's first line already shows `640c34`; it now also flags a reduced level.
- **Host diagnostics.** `HostDiagnosticsSnapshot` gains `stream` (sent size, level, encoder, hardware flag) from the latest sender statistics, rendered in the diagnostics report next to Route.
- **E2E.** `e2e.state` already carries the whole stats report; a `sentWidth ≥ 1920` assertion for device runs is a one-line follow-up in the harness once the landing pass is merged (not in this batch, to avoid conflicts).

## 4. Encoder trace (added after the baseline)

The baseline showed `encodeMs` (WebRTC's `totalEncodeTime ÷ framesEncoded`) sitting at 30–42 ms while 58 fps was sustained, and at 14.7 ms in a later session on the same content. That number is time inside VideoToolbox, and it cannot say whether frames queue or each one is slow. `DesktopH264Encoder` already wraps `encode()` and the encoded-image callback, so it now keeps `EncoderLatencyTrace`: per submitted frame the submit time (mach ms) and how many frames were already inside; the callback matches by `captureTimeMs` (the frame's `timeStampNs` in ms; oldest-first when unknown) and reports latency, bytes, key/delta and in-flight count to the host's `StreamCounters`. `setBitrate` calls and session (re)starts are counted too, because every estimate change makes WebRTC set VideoToolbox properties mid-session. Per-second host fields and summary: `encodeLatencyMs` (p50), `encodeLatencyP90Ms`, `encodeLatencyMaxMs`, `encodeInFlightMax`, `encodeBytesP50`, `keyFrameBytesMax`, `rateUpdates`, `encoderSessionAgeS`. In-flight > 1 at 58 fps means queueing; in-flight 1 with 40 ms means engine latency; rate updates per second beside latency tests the property-set hypothesis. The phone overlay shows the Mac's line (`Mac VT lat …`) and the age of the Mac summary it is reading.

## Files and ownership

| Area | Files |
|---|---|
| Contracts (lead) | `RemoteShared/BenchMarker.swift`, `LegibilityChart.swift`, `LegibilityScore.swift`, `MachClock.swift`, `ClockSync.swift`; `ControlProtocol.swift` (`clock`); `StreamStatistics.swift` (fields, windows, overlay lines); `NativeCodecCapability.swift`; `RemoteHost/HostModel.swift` (clock echo, diagnostics); `project.yml` (Test Pad and stub host compile the shared files); tests in `RemoteTests/` |
| Mac stimulus (sub-agent, Opus 5.5) | `FarsideTestPad/BenchPad*.swift`, bench hooks in `FarsideTestPadApp.swift`; marker + clock echo in `E2EStubHost/E2EStubHostApp.swift` |
| Phone integration (sub-agent, Opus 5.5) | `RemotePhone/RemotePhoneApp.swift` (marker hook, clock send/receive, `LinkSummary`), `VideoPresentationProbe.swift` (presented handler), `RemotePhone/LegibilityProbe.swift`, `NativeSessionView.swift` (Picture section), `PhoneE2E.swift` (state); tests in `RemotePhoneTests/` |
| Tools and docs (lead) | `script/perf/legibility.sh` + `script/perf/legibility/main.swift`, `bench/stats_summary.py` fields, `Docs/perf/LAB-NOTEBOOK.md`, `Docs/perf/SESSION-PROTOCOL.md` |
| Experiment switches (lead) | `StreamTuning` (`captureAtNativeRate`, `routeAwareSeed`, `restartFloorKbps`, `restartKeyFrameBudgetMs`, `encoderCeilingKbps`, all read from host user defaults and written into every sample's `tuning`), `RemoteCaptureConfiguration.minimumFrameInterval(for:)`, `MediaRoute.detail`, `SeedRoute`, `EncoderRestartPolicy.keyFrameBudgetMs` |

Everything new is behind the Stream statistics switch or `--bench`; nothing changes the stream when statistics are off. No builds until the orchestrator frees the Mac; the first build compiles RemoteCoreTests and the phone app under the shared lock and runs the marker, chart, clock and Vision unit tests.

## Quick wins queued behind the instruments (each behind a `StreamTuning` switch, A/B'd with the instruments above)

G25 pointer display link 80–120 Hz range · G1 capture `minimumFrameInterval` 1/60 vs native · G15 seed only on true LAN (host↔host, RTT < 15 ms) · G16 2.5–3 Mb/s seed on srflx and relay · G9 restart floor 5 → 1.5 Mb/s gated on IDR bytes ÷ estimate ≤ 250 ms. Then G18, G8, G17.
