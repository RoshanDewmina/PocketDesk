# Stream fix report — round 2 (28 September 2026)

Scope: the native stream only (Mac `PocketDeskRemoteHost` → iPhone `PocketDeskRemote`, WebRTC stasel 153.0.0, H.264). Branch `worktree-agent-a7825c70835ffca64`, rebased on `pocketdesk-remote-chat` at `3ee9b28`. Nothing was installed on the phone, in `/Applications` or through `script/build_and_run.sh`; no macOS permission was changed; `showsCursor` handling is upstream's. HEVC and custom codecs were not started (note in §8). Companion research from the same day: [PERFORMANCE-PLAYBOOK.md](PERFORMANCE-PLAYBOOK.md); its independent measurements agree with this report where they overlap.

Evidence labels: **[M]** measured here, **[S]** read from source, binary symbols or headers, **[D]** Apple documentation checked today, **[E]** estimate. Every measurement below is a same-Mac loopback, a direct VideoToolbox probe or a unit test. **No iPhone, Wi-Fi, ScreenCaptureKit capture or glass-to-glass number was measured.**

## 1. Summary

| | Before (HEAD behaviour) | After (this branch) | Evidence |
|---|---|---|---|
| Rendered code text, luma PSNR | 20.5–22.2 dB | 41.1–47.0 dB steady; 38.9–44.4 dB including start-up | [M] loopback, §4 |
| Push→decoded latency p50, static page 2560 | 14.4 ms (p90 19.1) | 13.2 ms (p90 18.1) | [M] |
| Push→decoded latency p50, full-screen scroll 2560 | 79.3 ms (p90 83.0) | 15.1 ms (p90 18.4) | [M] |
| Receiver jitter buffer, scroll 2560 | 64.0 ms | 0.2 ms | [M] |
| Phone presentation | 60 Hz, 3 drawables, no timing | 120 Hz request, 2 drawables, decoded→draw timing | [S]/[D]; unit test in the simulator |
| Stage visibility | 3 lines, receiver only | Mac and phone stages, overlay, exportable log | unit tests |

The two things that made the stream "laggy and blurry even on high" on the loopback were **libwebrtc's receive jitter buffer** and **a VideoToolbox session that starts at libwebrtc's 300 kb/s and never recovers text quality** under the wrapper's tight data-rate limit. Sharper added pixels, not bits, so it inherited both.

## 2. Root causes, with evidence

| # | Cause | Evidence | Symptom |
|---|---|---|---|
| 1 | **Receiver jitter buffer.** The frame buffer holds each frame for a jitter estimate that grows with frame size, even with zero network jitter. | [M] legacy scroll 2560: jitter buffer 64.0 ms, push→decoded p50 79.3 ms (p90 83.0). [S] `VCMTiming::UseLowLatencyRendering` requires `min_playout_delay == 0`; `WebRTC-ForcePlayoutDelay` is present in the shipped binary. | Lag that grows during motion. |
| 2 | **300 kb/s start + tight `DataRateLimits`.** The first key frame of the desktop is coded at 300 kb/s. The shipped wrapper pairs every rate with `DataRateLimits` of 1.5× per second, and under that limit VideoToolbox recovers text quality very slowly after the rate rises. Unchanged screen blocks are then coded as *skip*, so the soft picture persists. | [M] VideoToolbox probe, rendered code page 2560×1664: key frame at 0.3 Mb/s 22.4 dB. Rate raised to 18 Mb/s in the same session with a 1.5×/s limit: key frame immediately 20.3 dB, after 1 s 21.6 dB, after 3 s 23.7 dB. Same history with no limit: 36.5 dB after 1 s, 41.4 dB after 3 s. A new session at 18 Mb/s: 32.5 dB immediately. [S] binary strings `_bitrateAdjuster`, "Failed to set data rate limit with code:". | Blurry text in every mode. |
| 3 | **Frame-rate collapse from encoder pressure (older builds).** PRODUCT's 3684×2384 phone session: median encode 52.8 ms, 50 CPU-limited windows; screencast degradation keeps resolution and drops frames. | [S] PRODUCT.md. [M] at 2560×1664 encode is 10–12 ms, far below libwebrtc's hardware-overuse threshold (2× the 16.7 ms frame interval). | 15–28 frames/s. Addressed by the earlier 2560 cap; kept. |
| 4 | **Capture queue of 3 surfaces**, one of which the idle-refresh copy keeps. | [D] `queueDepth` minimum/default 3; "specifying more frames … may allow you to process frame data without stalling"; Apple's capture sample uses 5. **Not measured** (test runner has no Screen Recording permission, deliberately not granted). | Possible capture stalls under motion. |
| 5 | **60 Hz, three-drawable presentation** on a 120 Hz phone. | [S] `RTCMTLVideoView` wraps a default `MTKView` (60 fps). [D] iPhone needs `CADisableMinimumFrameDurationOnPhone` for >60 Hz. | Up to a frame of extra display wait; judder when frames arrive unevenly. |

Confirmed facts about the codec path **[S]/[M]**: the native path negotiates H.264 High 5.2 (`640c34`) and encodes on VideoToolbox hardware (`encoderImplementation=VideoToolbox`, `powerEfficientEncoder=true`, log "Compression session created with hw accl enabled"). Frames reach the encoder as native CVPixelBuffers with no crop/scale copy (`texture=1`; capture size equals the negotiated budget). **Low-latency rate control is not active and cannot be enabled through the stock encoder**: the shipped binary does not import `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` (`nm -u`). The decoder does not set `kVTDecompressionPropertyKey_RealTime`, but Apple documents that it defaults to real-time **[D]**, so no custom decoder is needed for that.

## 3. What changed

All tuning sits behind `StreamTuning` (`RemoteShared/StreamTuning.swift`). `StreamTuning.tuned` is the default; `StreamTuning.legacy` reproduces the previous behaviour and is selected by the user default `PocketDeskLegacyStreamTuning` (phone: Controls → Picture → *Previous stream tuning*, applied on next launch) so every change can be A/B tested on the real devices.

| Area | Change | Files |
|---|---|---|
| Receiver buffering | `WebRTC-ForcePlayoutDelay/min_ms:0,max_ms:0/` installed once via `RTCInitFieldTrialDictionary` before the first factory: frames go to the decoder as soon as complete; frames queued behind a stall are fast-forwarded. Receiver-side only, so browser viewers are unaffected. | `StreamTuning.swift`, `PeerMedia.swift` |
| Bitrate per mode | Encoder ceiling Sharper 25 Mb/s, Responsive 12 Mb/s (was 12 for both). On a *Direct* route the bandwidth estimate is seeded at 10 / 6 Mb/s from the second statistics sample and re-seeded once if libwebrtc's initial probe results overwrote it (observed in the loopback). Relay routes keep libwebrtc's ramp. Mode changes update the ceiling live; the overlay reports the sender's applied cap. | `StreamTuning.swift`, `PeerMedia.swift`, `RemoteCapture.swift` |
| Encoder restart | `DesktopH264Encoder` wraps the stock `RTCVideoEncoderH264` and recreates its VideoToolbox session (release, then start with the current rate: the calls libwebrtc itself makes when it reconfigures an encoder) when the target has stayed at ≥2× the session's lowest rate and ≥5 Mb/s for 0.75 s; at most one repeat per 15 s. Its first frame is a key frame coded with fresh rate control at the current rate. | `DesktopH264Encoder.swift`, `VideoCodecPolicy.swift` |
| Capture | `queueDepth` 3 → 5; capture queue QoS `.userInteractive`; `SCStreamFrameInfo.displayTime` → callback latency and complete-frame gaps recorded. | `RemoteCapture.swift` |
| Presentation | The `MTKView` inside `RTCMTLVideoView` is set to 120 fps with 2 drawables; its delegate is forwarded through a probe that times decoded frame → draw call and counts frames replaced before any draw. `CADisableMinimumFrameDurationOnPhone = YES` (new `RemotePhone/Info.plist`, merged with the generated plist). If a future WebRTC changes the view, the probe declines and nothing is altered. | `VideoPresentationProbe.swift`, `RemotePhoneApp.swift`, `project.yml` |
| Degradation | Explicit `maintainResolution` (same as libwebrtc's screencast default). Frame-rate-first was measured and rejected (§5). | `StreamTuning.swift` |

### Instrumentation

Per-second report (`StreamStatsReport`, `PDSTATS` JSON to the unified log and `Caches/PocketDeskStreamStats.jsonl` when enabled):

- **Mac:** capture fps, display→callback latency p50/p90, complete-frame gap p90/max (meaningful only while content moves), push skips, frames lost before the encoder, encoded/sent fps, encode ms, **pacer delay** (`totalPacketSendDelay`), sent/target/max/estimate kb/s, QP, retransmits, encoder name + hardware flag, quality limitation, active tuning.
- **Phone:** received/decoded fps, **shown fps and frames replaced before display**, packet assembly, jitter buffer, decode, **decoded→draw latency p50/p90**, shown-frame gap p90, render-callback gaps, display refresh, loss, freezes, control-channel queue, plus the Mac's summary (sent once per sample with the capture heartbeat; older phones ignore the field; validated before the session-extension early returns so no other action can carry it) and a labelled stage-sum estimate "Mac display → phone draw".
- **Overlay:** Controls → Picture → *Stream statistics* shows every line over the picture, records the log and offers *Export statistics log*. `bench/stats_summary.py <log>` prints p50/p90 per stage.
- **Benchmarks:** `StreamLoopbackBenchmarkTests` (opt-in) renders anti-aliased Menlo code at Retina size in three scenes (static page with a moving panel, seamless full-screen scrolling, scrolling with page jumps), reads a frame marker from every decoded frame for push→decoded latency, measures luma PSNR against the source, and takes per-run overrides (`POCKETDESK_BENCH_TUNING`, `_PLAYOUT`, `_BITRATES`, `_REFRESH`, `_DEGRADATION`, `_PACING`, `_BWE_HEADROOM`, `_WARMUP`). `VideoToolboxProbeTests` (opt-in) compares rate-control configurations and quality recovery after a low start.

QP is deliberately not used as a sharpness signal: skip-only screen frames report QP 51 whatever the picture quality (legacy and early tuned runs reported QP ≈ 51 while PSNR differed by more than 10 dB).

## 4. Loopback numbers, before → after

Method **[M]**: two in-process `PeerMedia` peers on this MacBook Air M4 (macOS 27.0), real negotiated H.264/VideoToolbox encode and decode, NV12 frames of rendered Menlo code pushed at 60 Hz. Scenes: *static page + moving panel* (a 640×480 panel moves over a static code page), *continuous scroll* (the whole page scrolls 17 px per frame, seamless), *scroll with a page jump ~2×/s* (12 px per frame with a 372 px jump every 32 frames: a near-full-screen change twice a second). "Before" is `StreamTuning.legacy` (the HEAD code path); "after" is `StreamTuning.tuned`. Rounds were interleaved and started only with ≥60% idle CPU (1-minute load 3–5 for the steady runs); the Mac was shared with other agents, so treat milliseconds as ±20%. Latency is push→decoded-frame callback: ScreenCaptureKit, Wi-Fi and the phone's decode and display are **not** included. PSNR is a legibility proxy, not a reading test. Raw receipts: `outputs/bench/{steady,campaign,campaign1}` in this worktree (git-ignored).

### 4a. Steady state (6 s warm-up, 8 s measured, medians of 2 rounds)

| Scene | Size | before p50 / p90 / p99 ms | after p50 / p90 / p99 ms | before PSNR | after PSNR |
|---|---|---|---|---|---|
| static page + moving panel | 2560×1664 | 14.4 / 19.1 / 21.8 | 13.2 / 18.1 / 19.8 | 22.2 dB | 43.8 dB |
| static page + moving panel | 1920×1248 | 12.1 / 15.2 / 16.9 | 9.4 / 12.0 / 13.7 | 21.9 dB | 42.8 dB |
| continuous scroll | 2560×1664 | 79.3 / 83.0 / 86.2 | 15.1 / 18.4 / 19.8 | 20.6 dB | 46.3 dB |
| continuous scroll | 1920×1248 | 56.0 / 63.1 / 65.0 | 9.8 / 13.4 / 14.8 | 20.9 dB | 47.0 dB |
| scroll with a page jump ~2×/s | 2560×1664 | 105.2 / 110.3 / 113.7 | 18.4 / 77.5 / 117.7 | 20.5 dB | 41.1 dB |
| scroll with a page jump ~2×/s | 1920×1248 | 21.4 / 23.6 / 25.3 | 11.8 / 72.7 / 99.2 | 20.6 dB | 42.8 dB |

### 4b. Including start-up (2 s warm-up, 8 s measured, medians of 3 rounds)

The tuned tails here are the one-time encoder restart (a 300–400 KB key frame about 2–3 s after connecting, §6). "After w/o restart" is the tuned build with the restart disabled: equally fast, but text stays at the starved first-key-frame quality.

| Scene | Size | before p50 / p90 / p99 ms | after p50 / p90 / p99 ms | after w/o restart p50 / p90 / p99 ms | before PSNR | after PSNR | after w/o restart PSNR |
|---|---|---|---|---|---|---|---|
| static page + moving panel | 2560×1664 | 18.6 / 22.5 / 24.3 | 12.9 / 36.4 / 186.4 | 13.0 / 17.6 / 19.3 | 22.2 dB | 41.1 dB | 22.2 dB |
| static page + moving panel | 1920×1248 | 14.0 / 17.1 / 19.5 | 8.5 / 80.7 / 179.5 | 9.9 / 12.3 / 14.1 | 21.9 dB | 41.2 dB | 21.9 dB |
| continuous scroll | 2560×1664 | 68.5 / 86.6 / 89.8 | 13.3 / 18.5 / 20.5 | 12.1 / 12.5 / 13.6 | 20.3 dB | 44.4 dB | 20.9 dB |
| continuous scroll | 1920×1248 | 33.1 / 38.3 / 41.9 | 8.6 / 54.4 / 215.0 | 9.9 / 11.3 / 12.4 | 20.7 dB | 44.0 dB | 20.7 dB |
| scroll with a page jump ~2×/s | 2560×1664 | 101.2 / 103.3 / 105.2 | 17.2 / 166.3 / 333.2 | 12.9 / 17.4 / 18.9 | 20.6 dB | 38.9 dB | 20.6 dB |
| scroll with a page jump ~2×/s | 1920×1248 | 18.0 / 20.9 / 22.6 | 8.6 / 91.0 / 260.7 | 7.9 / 10.1 / 13.0 | 20.7 dB | 39.9 dB | 20.7 dB |

### 4c. Stage view, 2560×1664, steady state

| Stage | static page + moving panel before | static page + moving panel after | continuous scroll before | continuous scroll after |
|---|---|---|---|---|
| encode ms | 9.8 | 11.5 | 11.8 | 11.7 |
| pacer ms | 0.0 | 0.0 | 0.0 | 0.0 |
| assembly ms | 0.0 | 0.1 | 0.1 | 0.2 |
| jitter buffer ms | 1.5 | 0.1 | 64.0 | 0.2 |
| decode ms | 3.0 | 3.3 | 3.4 | 3.3 |
| push→decoded p50 ms | 14.4 | 13.2 | 79.3 | 15.1 |
| decoded fps | 60.0 | 60.0 | 60.0 | 60.0 |
| sent kb/s | 582.1 | 3688.1 | 929.0 | 4784.0 |
| target kb/s | 5784.5 | 23513.0 | 5400.5 | 23511.5 |
| estimate kb/s | 6149.8 | 25000.0 | 5741.5 | 25000.0 |
| text PSNR dB | 22.2 | 43.8 | 20.6 | 46.3 |

Capture (ScreenCaptureKit) and display are outside the loopback; the new overlay reports both on the devices.

### 4c′. Single-factor runs (earlier build, one round each; its "scroll" scene is today's page-jump scene)

| Configuration | Static 2560: p50 / p90 / p99 ms, PSNR | Page-jump scroll 2560: p50 / p90 / p99 ms, PSNR | Encoded size |
|---|---|---|---|
| Before (HEAD path) | 54.5 / 92.4 / 144.2, 22.2 dB | 114.6 / 118.1 / 229.2, 20.6 dB | 2560×1664 |
| Receiver playout 0/0 only | 12.2 / 30.4 / 204.1, 22.2 dB | 12.8 / 43.2 / 64.6, 20.6 dB | 2560×1664 |
| Mode bitrates + seed only | 45.4 / 96.3 / 120.5, 27.2 dB | 36.8 / 41.6 / 245.5, 22.4 dB | 2560×1664 |
| Playout + bitrates | 14.8 / 17.5 / 19.0, 30.7 dB | 12.8 / 17.1 / 18.1, 22.4 dB | 2560×1664 |
| Playout + bitrates + maintainFramerate | 7.3 / 74.4 / 196.8, n/a (downscaled) | 7.2 / 20.3 / 178.5, n/a (downscaled) | 1280×832 |

Receiver playout alone removes most of the latency; bitrate alone adds sharpness but also adds jitter-buffer delay (larger frames); both together are fast but text only reaches 22–31 dB until the encoder restart (4a/4b). `maintainFramerate` halved the resolution (§5).

### 4d. VideoToolbox alone, rendered code page 2560×1664

| Configuration | Key frame | Key PSNR | Next 30 scrolling frames (avg) | Their PSNR |
|---|---|---|---|---|
| Stock-like, 0.3 Mb/s (libwebrtc start) | 126 KB | 22.4 dB | 1.6 KB | 22.4 dB |
| Stock-like, 5 Mb/s | 228 KB | 26.8 dB | 6.7 KB | 28.2 dB |
| Stock-like, 18 Mb/s | 402 KB | 32.5 dB | 26.6 KB | 38.9 dB |
| Stock-like, 18 Mb/s, no DataRateLimits | 612 KB | 38.7 dB | 58.9 KB | 44.5 dB |
| Low-latency rate control, 18 Mb/s | 548 KB | 36.8 dB | 23.2 KB | 40.9 dB |

| Session history (key at 0.3 Mb/s, 1 s static, then 18 Mb/s) | Key right after rise | Key +1 s | Key +3 s |
|---|---|---|---|
| DataRateLimits 1.5×/1 s (shipped wrapper) | 91 KB, 20.3 dB | 116 KB, 21.6 dB | 154 KB, 23.7 dB |
| 4×/1 s | 98 KB, 20.7 dB | 154 KB, 23.7 dB | 250 KB, 27.4 dB |
| 10×/1 s + average over 5 s (newer upstream) | 91 KB, 20.3 dB | 140 KB, 22.9 dB | 206 KB, 25.9 dB |
| None | 263 KB, 26.2 dB | 596 KB, 36.5 dB | 781 KB, 41.4 dB |

## 5. Options measured and not adopted

| Option | Result | Decision |
|---|---|---|
| Frame-rate-first (`maintainFramerate`) | Resolution halved on a loopback with >20 Mb/s available: 2560×1664 → 1280×832, 1920×1248 → 960×624, `qualityLimitation=bandwidth`. libwebrtc's QP-based scaler reads the QP 51 that skip-heavy screen frames report. | Rejected. Frame rate is protected by the pixel cap (encode 10–12 ms), adequate bitrate and the deeper capture queue instead. |
| Forced key frame inside the running session (first version of the refresh) | Text PSNR 23.6 dB vs 30.7 dB without it (window 2560, same build); p99 217 vs 19 ms. The key frame overruns the 1.5×/s window and rate control stays at QP ≈ 51 afterwards. | Replaced by the session restart. |
| Receiver playout 0/100 (keeps 8 ms decode pacing) | Same median as 0/0 in early runs. | 0/0 chosen: frames queued behind a stall are fast-forwarded, which suits remote control. |
| `WebRTC-Video-Pacing/factor:2.5/` | Page-jump scene pacer delay unchanged (50 ms); one first-connection estimate collapse to 2.5 Mb/s. | Not shipped. |
| Estimate ceiling 2× the encoder ceiling | First runs cut the page-jump scene's p90 130 → 60 ms, but in 4 repeated connections the estimate stayed near the 10 Mb/s seed in 3 and collapsed once. | Kept as a knob (`bandwidthHeadroom`), default 1. |
| Pointer-move coalescing under control-channel backlog | Implemented and unit-tested, then removed during the rebase: the merged phone-drawn pointer reconciles every move by ordinal (`PointerOverlay`), so merging moves belongs with that owner. | Deferred to the pointer owner. |
| Custom low-latency VideoToolbox encoder | +4 dB at 18 Mb/s in the probe; the playbook saw no encode-latency gain; needs a full `RTCVideoEncoder` (Annex B, key-frame requests, rates). | Deferred; the restart wrapper already gives 41–45 dB. |
| `WebRTC-ForceSendPlayoutDelay` | Would also change browser viewers, untested there. | Not shipped. |

## 6. Costs, risks and what is still unmeasured

- **Start-up hitch [M]/[E].** The restart sends one 300–400 KB key frame about 2–3 s after connecting (second statistics sample, then 0.75 s of stable target). In the loopback this produced p90/p99 of 36–166 / 180–333 ms in runs whose window included it (table 4b) and nothing comparable in steady state (4a). On Wi-Fi expect one brief pause shortly after connecting and after a large bandwidth recovery (≤1 per 15 s).
- **Full-screen changes [M].** Continuous scrolling is fine (steady p90 18.4 ms at 2560 vs 83.0 before). A near-full-screen change is now coded sharply (100–400 KB) and the pacer, which sends at ~1.1x the estimate, delays the frames right behind it: page-jump scene steady p90 72.7 ms at 1920 (23.6 before) and 77.5 ms at 2560 (110.3 before, when the jitter buffer dominated). A pacer bound or low-latency rate control (which drops instead of queueing) is the next lever; `WebRTC-Video-Pacing` and a higher estimate ceiling were tried without a reliable gain (§5).
- **Estimate collapse [M].** With the seed applied at the first statistics sample, 2 of 8 loopback connections ended with the estimate stuck at ~2–3 Mb/s and a 0.4–1 s pacer queue; a captured case showed libwebrtc's initial probe result replacing the seed. With the shipped policy (second sample, one re-seed) none of 42 later tuned connections dropped below 8 Mb/s. Whether Wi-Fi delay variation triggers back-offs after the seed is unmeasured; the overlay shows `target`, `max` and `pacer` to catch it.
- **iPhone:** decode time, decoded→draw latency, whether 120 Hz engages (Low Power Mode or thermals can prevent it), the effect of two drawables, and the thermal/battery cost of 120 Hz and 25 Mb/s.
- **Wi-Fi:** loss with zero playout delay (a lost packet freezes until retransmission instead of being hidden by the buffer), AWDL jitter.
- **ScreenCaptureKit:** display→callback latency and the effect of queue depth 5.
- **Glass-to-glass and touch-to-visible latency:** use §7. The overlay's "Mac display → phone draw" is a sum of stage averages, not a physical measurement, and excludes panel scan-out and the input path.
- **Dependencies on WebRTC internals:** `RTCInitFieldTrialDictionary` is deprecated ("delete after 1 Jan 2026") but present and working in 153.0.0; the presentation probe relies on `RTCMTLVideoView` hosting an `MTKView` (a unit test fails if that changes); the restart relies on `RTCVideoEncoderH264` supporting release/start on the same instance. Re-run the loopback benchmark after any WebRTC upgrade and check `jitterBufMs ≈ 0` and PSNR.

## 7. Five-minute physical test protocol (iPhone 17 + MacBook Air)

Prerequisites (done by Roshan): install this branch's host and phone builds the usual way. On the Mac run `defaults write com.roshan.PocketDesk.RemoteHost PocketDeskStreamStats -bool YES` and relaunch the host. On the phone open the dock's **Controls** (sliders icon) → Picture → turn on **Stream statistics** and choose **Sharper**. A second phone or camera that records 240 fps slow motion is needed for steps 3–4. Same Wi-Fi, Mac on power, fixed phone brightness, Low Power Mode off.

1. **0:00 Stimulus.** On the Mac open `bench/stimulus.html` in Safari and enter full screen (⌃⌘F). Connect from the iPhone, Fill view, no zoom. Wait 30 s. Screenshot the phone overlay. Expect: `120Hz` in the first line, `jitter` ≈ 0–3 ms, `to-screen` p50 < 9 ms, `shown` ≈ `decoded`, Mac `encode` 60 fps, Mac `max 25000`, `target` well above 5000.
2. **0:45 Motion cadence, 30 s.** Start iOS screen recording from Control Center, record the moving red box for 30 s, stop. On the Mac: `python3 bench/analyze.py tuned=<RPReplay file>.mp4`. Pass mark from ENCODER.md: ≥45 distinct updates/s median and p90 gap < 50 ms.
3. **1:30 Mac display → phone display latency, 20 samples.** Hold the iPhone beside the Mac screen so both `clock` readouts are in frame and film 5 s of slow motion with the second device. Step through 20 frames spread across the clip; latency = Mac clock − iPhone clock. Record median and max. This covers capture, encode, network, decode and both panels.
4. **2:30 Touch to visible, 10 taps.** Move the pointer onto the black "tap / click me" square. Film the iPhone screen and your finger in slow motion; tap the trackpad surface 10 times about 1 s apart. For each tap count frames from first finger contact to the square changing colour on the iPhone (240 fps: 4.17 ms per frame). Record median and max.
5. **3:30 Export.** Controls → Picture → *Export statistics log* (AirDrop to the Mac). Run `python3 bench/stats_summary.py PocketDeskStreamStats.jsonl --last=60` and the same for `~/Library/Caches/PocketDeskStreamStats.jsonl` on the Mac.
6. **4:00 A/B.** Turn on **Previous stream tuning** on the phone and run `defaults write com.roshan.PocketDesk.RemoteHost PocketDeskLegacyStreamTuning -bool YES` on the Mac; quit and relaunch both apps; repeat steps 2–4 (10 and 5 samples are enough for 3 and 4). Undo with `-bool NO` and the switch off.

Record for tuned and legacy: analyze.py updates/s and p90 gap, display→display median/max, touch→visible median/max, and the stats_summary output. For sharpness, take an iPhone screenshot of the 9/11/13 px text lines after 10 s idle in each mode and compare `Il1| O0 rn m`.

## 8. HEVC / custom codec feasibility (note only)

Not started, by instruction. The shipped WebRTC compiles H.265 RTP packetization but has no VideoToolbox H.265 encoder/decoder classes, so HEVC needs a custom `RTCVideoEncoder`/`RTCVideoDecoder` pair and SDP work [S] (playbook F2). The M4 hardware encoder emits HEVC RExt 4:4:4 that the Mac decodes [playbook, M]; iPhone 17 decode of that stream and the phone-side WebRTC glue are unproven. This round shows the softness was a rate-control and buffering problem that H.264 fixes (41–45 dB on static code text), so HEVC should be judged after the physical A/B above.

## 9. Verification

| Suite | Result |
|---|---|
| `RemoteCoreTests` (macOS) | 234 tests, 3 skipped (opt-in loopback benchmark and two VideoToolbox probes), 0 failures. One later full run hit the load-sensitive `SessionIntegrationTests.testHostKeepsRegisteredRoomWhenPhoneLeavesOrMediaDrops`; it passed 2/2 when re-run alone. |
| `StreamTests`, `HostUISnapshotTests` (macOS, sources untouched) | 9/9, 3/3 |
| `RemotePhoneTests` (iOS 27 simulator) | 43/43, including 4 new presentation-probe tests (the probe finds and wraps the `MTKView` inside a real `RTCMTLVideoView`, restores its delegate, and the app's plist carries `CADisableMinimumFrameDurationOnPhone`). |
| `RemotePhoneUITests` | 12 run: 10 pass. `testOfflineControlsPortraitLandscapeAndKeyboard` fails at line 159 on the upstream base `1b2afbb` as well. `testBackgroundConcealsOfflineLayoutUntilExplicitReturn` failed once under heavy load and passed on re-run. |

New unit tests: `StreamTuningTests` (tuning, bitrate ratios, capture timing, queue depth), `EncoderRestartPolicyTests`, `BandwidthSeedPolicyTests`, `HostStreamSummaryProtocolTests` (only on `capture`, bounded, old payloads decode), `NativeSenderTuningTests` (real loopback: applied encoder ceiling and degradation follow the picture mode), `StreamStageStatisticsTests`, `LatencyWindowTests`, `VideoPresentationProbeTests`.

Test mechanics on this Mac: `xcodebuild test` cannot load test bundles built under `~/Documents/.../.claude/worktrees` (the runner reports the executable missing), so macOS bundles were built with `lockf -k /tmp/farside-xcodebuild.lock xcodebuild build-for-testing` and run with `xcrun xctest`, and phone tests ran with `xcodebuild test-without-building -xctestrun` from a copy of the products outside `~/Documents`, on a dedicated simulator.

Follow-up for PRODUCT.md (not edited here): its Sharper paragraph should record that Sharper now raises the encoder ceiling to 25 Mb/s (Responsive 12 Mb/s) and that the stream restarts its encoder once after connecting.

