# 120 fps and busy-Mac plan (29 Sep 2026)

Roshan's priorities: (1) 120 fps, (2) a stream that stays usable on a loaded Mac. This plan says what 120 fps can mean on each source, what the pipeline needs, how viewport capture and a ladder make it sustainable, and how the session measures it. Evidence labels as in the baseline: **[M]** measured here, **[S]** read in this repo or SDK, **[D]** Apple documentation, **[3P]** third-party report, **[E]** estimate. The fork's `PERF-UNDER-LOAD-AND-120FPS.md` (competitor handling, per-Mac matrix, ladder recommendation) will refine §5 when it lands; nothing here duplicates it.

## 1. Bottom line

1. **The built-in panel of Roshan's MacBook Air is 60 Hz, so no capture API can deliver more than 60 unique frames a second from it** [D, gap report §5.1]. On his machine, 120 fps of Mac content needs a 120 Hz *source*: an external 120/144 Hz display (his M4 Air supports two 4K displays at 144 Hz, or one 5K at 120 Hz / 4K at 240 Hz [D, Apple 122212]), or a 120 Hz virtual display through the private `CGVirtualDisplay` API, which macOS may *report* as 120 Hz but composite at 60 [3P, below]. ProMotion MacBook Pro users get up to 120 automatically once the pipeline stops assuming 60.
2. **What 120 already means on the phone, on any source:** presentation at 120 Hz (shipped, with the probe re-asserting it), the phone-drawn pointer and pan/zoom at 120 Hz (pointer agent), and a 60 fps stream shown at 120 Hz with about 4 ms less display wait. The overlay's `shownΔ … at 120Hz %` now measures it.
3. **The pipeline is ready for 120 in 1–2 days (G5)** and only activates on a ≥ 100 Hz source, so it is safe to ship. The hard limits are the encoder: at 2.3 ms per megapixel [M, playbook] a 120 fps frame must stay under about 3 MP (≈ 7 ms), i.e. 2048 wide or a viewport-sized region (G4), and the VideoToolbox latency state seen in the baseline (14.7 ms in its *good* state at 2560) already exceeds an 8.3 ms frame interval, so WebRTC's overuse detector would cut 120 to 60 immediately unless frames are smaller or the app runs its own ladder.
4. **Viewport capture (G4) is the lever for both priorities**: at reading zoom it encodes 1.46 MP instead of 4.24 (3.4 ms per frame, 120 with headroom, and 3× the bits per visible pixel), and on a busy Mac the ladder (G12) has a smaller picture to protect.

## 2. Sources for 120 fps (a)

| Source | Unique fps available | On Roshan's Mac today | Risks and costs |
|---|---|---|---|
| Built-in 60 Hz panel | 60 | yes | none; this is the ceiling of every measurement so far |
| External 120 or 144 Hz display (USB-C/HDMI) | up to the display's rate, when content moves | if he has or gets one; M4 Air: 4K@144 ×2, 5K@120 or 4K@240 ×1 [D] | 4K@120 is 8.3 MP per frame: capture must scale to ≤ 3 MP (G4 or the pixel budget); the Mac composites and the encoder works twice as hard while the lid display idles |
| 120 Hz virtual display (`CGVirtualDisplay` SPI) | unknown: macOS can report 120 Hz and composite at 60 [3P] | a one-day spike | private API (works under Developer ID, no review, but can break on any macOS update); windows must be moved onto it, or mirrored at the master's rate [E]; BetterDisplay's maintainer: "macOS reporting 120Hz … does not mean 120Hz working"; one user saw it fail to hold 120 while dragging windows, one reported success on a specific monitor, the Sidecar-at-120 trick "worked once" [3P] |
| ProMotion MacBook Pro (built-in) | up to 120, adaptive: static content idles, motion goes up | not his | none once G5 lands; capture at the panel's native cadence follows ProMotion's variable rate |
| Phone-shaped virtual display at 60 Hz (1311×603 pt @2× = 2622×1206 px) | 60 | a spike, same SPI | the best *text* mode regardless of 120: 1:1 pixels, no scaling anywhere; same window-management cost |

Sources: [Apple, MacBook Air displays](https://support.apple.com/en-us/122212); [BetterDisplay discussion 4280](https://github.com/waydabber/BetterDisplay/discussions/4280); [BetterDisplay discussion 5609](https://github.com/waydabber/BetterDisplay/discussions/5609); [DeskPad-derived virtual display package](https://github.com/SliBox/VirtualScreen_Macos).

**Decision for the virtual display:** a measured spike, not an investment. A Debug-only host flag creates a 120 Hz virtual display (phone-shaped) and the existing `probes/sckprobe` counts complete frames per second while the bench window's motion lane runs on it. Go if ScreenCaptureKit delivers ≥ 110 complete frames/s for 30 s; otherwise the virtual display stays a 60 Hz text-mode idea and 120 needs a real display.

## 3. Pipeline changes for ≥ 100 Hz sources (b), G5

Today 60 is hard-coded in four places [S]: `RemoteCapture` (`minimumFrameInterval` 1/60), `PeerMedia` (`maxFramerate = 60`, `adaptOutputFormat(fps: 60)`), `H264LevelPolicy.fitsAt60FPS` and `CapturePixelDimensions.fitted`. The change, behind `StreamTuning.highRefreshCapture` (default on; only takes effect when the captured display reports ≥ 100 Hz) with a `PocketDeskTargetFPS` override for tests:

1. **Read the source rate.** `CGDisplayCopyDisplayMode(displayID)?.refreshRate`, falling back to the matching `NSScreen.maximumFramesPerSecond`; 0 means unknown (some virtual and adaptive displays) and is treated as 60 unless overridden. Target fps = 120 when the rate is ≥ 100, else 60. Recorded as `displayRefreshHz` and `targetFPS` in the host summary.
2. **Capture at the native cadence**: `minimumFrameInterval = .zero` for a 120 target (and the G1 A/B at 60); `queueDepth` 8 at 120 (the header's maximum) so a burst does not drop frames.
3. **Fit the level at the target rate**: `H264LevelPolicy.fits(width:height:fps:)` (macroblocks × fps ≤ 2,073,600 and ≤ 36,864 per frame). At 120 fps 2560×1656 is 1.997 M, inside level 5.2 but with no headroom [S].
4. **Pixel budget by rate**: `StreamQuality.maximumDimension(at fps:)`: Sharper 2560 at 60, 2048 at 120 (2.7 MP, about 6 ms); Responsive 1920 at 60, 1600 at 120 (1.7 MP). G4 replaces the budget with the viewport size later.
5. **Sender**: `maxFramerate = target`, `adaptOutputFormat(fps: target)`; WebRTC then passes 120 to the encoder settings, so VideoToolbox's `ExpectedFrameRate` follows [S-up].
6. **Rate control**: keep the stock encoder's default rate control. Low-latency rate control gave no encode-latency gain and dropped frames under a low target [M, playbook R4]; the fork's loaded 120 fps benchmark dropped every frame with it. P-frames halve in size at 120 for the same bitrate, so the 25 Mb/s ceiling stays.
7. **Overuse detector**: with an 8.3 ms interval, WebRTC cuts the rate whenever encode latency exceeds about 7 ms. Two levers, both switches: smaller frames (4), and `degradationPreference = .disabled` in 120 mode with the app-level ladder (§5) making the decisions from the encoder trace instead of WebRTC's usage estimate.
8. **Phone**: the decoder is asynchronous VideoToolbox [S]; measured decode is 7 ms at 2560 [M], so 120 needs the smaller sizes (expected 4–5 ms at 2048, to be measured). Presentation already runs at 120 Hz with two drawables; the presented-handler instrument reports `presentedAt120Share` and superseded frames, which should be near zero at 120/120.
9. **Thermal and power**: `ProcessInfo.thermalState` on both sides and the phone's Low Power Mode flag go into the reports; a fanless Air and a phone decoding 120 fps over Wi-Fi will throttle in long sessions, and the ladder must read it.
10. **E2E**: the stub host gets a 120 fps generator option for the phone plumbing test (its simulator receiver is level 3.1, so at a small size).

## 4. Why viewport capture and a ladder make 120 sustainable (c)

**G4 viewport-matched capture** (gap report §5.2 B): the phone sends its visible Mac rect in points and its viewport size in pixels; the host sets `SCStreamConfiguration.sourceRect`. The output is capped by the whole-display budget and drops toward 1:1 crop pixels at deeper zoom. A hysteresis band holds the current output through small changes, but a large zoom can change the frame size and trigger an encoder key frame. Pixel counts on an iPhone 17 landscape: Fit 2622×1206 = 3.16 MP (7 ms, marginal at 120: the ladder picks 60 at full size or a smaller rung); reading zoom 1784×820 = 1.46 MP (3.4 ms, 120 with headroom); 3× zoom about 0.7 MP. These are estimates, not device results. Fast-pan crop reconfiguration and frame-size hitches still need a physical check. `captureRegion` status and RTP video travel separately: an older frame already in flight may briefly be placed using the new region. Do not treat static geometry tests as proof of pixel alignment during that transition.

**Interim cap to the phone's pixels** (this week): the phone advertises its screen pixel size on the capture message; the host caps the long edge to it (2622 on an iPhone 17, so Sharper 2560 is already about 1:1; an iPad 13" gets its native 2752 instead of 2560).

**G12 ladder** (after the encoder trace data): the 120 fps path is 120@100 % → 60@100 % → 60@75 % → 30@75 % → 30@50 %; a 60 fps source starts 60@100 % → 30@100 % → 30@75 % → 30@50 %. Each step reduces rate or size without increasing the other. Inputs are encoder latency p90 and frames in flight, capture rate and delay, estimate versus target bitrate, pacer delay, encoder drops, and optional bounded phone feedback (superseded frames, decode time, presented rate, thermal state and Low Power Mode). An older phone supplies no feedback; stale reports expire. Step down within 2 s, step up after 10 s of headroom; step fps before size because an fps change needs no key frame while a size change does. Every step is an `updateConfiguration`, not a stream restart.

**"Your Mac is busy"**: when the ladder sits at its floor, or capture fps stays under 80 % of the target for 5 s, or encoder latency exceeds twice the interval, the phone shows an honest pill ("Mac is busy · 30 fps at 1440 px") and the host popover the same; it clears after 10 s of headroom. The signal is the same data the ladder uses, so it cannot disagree with what the user sees.

**Large displays (up to 6K)**: virtual displays at 60 Hz are reliable [3P] and are the test rig: a 6016×3384 virtual display (20 MP backing) captured to the phone's pixels measures ScreenCaptureKit's scaling cost under load and the cap logic; the ladder must never send a 6K frame.

## 5. What the session measures (d)

Already in the instruments (this morning's branch): glass-to-glass per frame, distinct frames per second, presented cadence and the 120 Hz share, VideoToolbox latency and frames in flight, decode ms, legibility.

Added for 120: `displayRefreshHz`, `targetFPS`, capture interval p50 (ScreenCaptureKit's real cadence), `thermalState` on both sides, the phone's Low Power Mode flag, and the queue depth in use. Pass marks for a 120 fps source: capture ≥ 110 complete fps with the bench motion on; `distinct/s` ≥ 110 at the phone; `presentedAt120Share` ≥ 80 %; encoder latency p90 ≤ 7 ms; decode ≤ 6 ms; glass p50 ≤ 30 ms (the capture wait halves); no `cpu` limitation; superseded frames near zero.

Sources for Roshan's session: (1) his ASUS VG32VQ1B at 2560×1440, set to **120 Hz** (it offers 100/120/144; 120 matches the phone's cadence, while 120 fps sampled from 144 Hz vsyncs gives uneven 6.9/13.9 ms gaps); (2) the virtual-display spike (Debug-only, W5) as a fallback if it measures ≥ 110 fps; (3) the 60 Hz panel, where the 120 mode is verified only for the phone side and the pipeline switch is inert. Load generators for the busy-Mac runs, one at a time (research §4c.5): a second VideoToolbox session (`ffmpeg … hevc_videotoolbox -realtime 1`), a Simulator animation, iPhone Mirroring, an `xcodebuild`; the landing agent's simulator fan-out reached load average 646 this morning and serves as the extreme case.

Refinements from the fork's `PERF-UNDER-LOAD-AND-120FPS.md` (29 Sep): libwebrtc's overuse detector trips at 200 % of the frame interval for a hardware encoder (34 ms at 58 fps matches the baseline's 38 fps episodes; 16.7 ms at 120 sits just above VT's good 14.7 ms state), so 120 mode runs with WebRTC's adaptation off by default and the ladder in charge; "newest frame wins" (drop at submit while a frame is inside VideoToolbox) is a switch for run E7; the stock encoder already sets `kVTCompressionPropertyKey_RealTime`; HEVC standard mode (≈1.8× H.264's throughput, low-latency mode 0.5× and avoided) becomes the ladder's codec step between fps and pixels once 120 lands. The pass marks in `SESSION-PROTOCOL.md` (build .5 section) supersede the ones above: ≥115 delivered and presented, capture gap 8.3 ± 0.5 ms, VT p90 ≤ 6 ms with ≤ 1 in flight, glass p50 ≤ 40 / p95 ≤ 60.

## 6. Order and timeline

| When | Work | Gate |
|---|---|---|
| This week (29 Sep–3 Oct) | G5 plumbing + instruments for ≥ 100 Hz (2 days); phone-pixel cap (1 day); virtual-display spike (1–2 days, Debug-only) | sckprobe ≥ 110 complete fps on the virtual display, or a real 120 Hz display on hand |
| 6–24 Oct | G4 viewport capture (2–3 weeks), ladder G12 and the busy state alongside (1 week, overlapping), 6K virtual-display tests | 120 fps measured end to end on a real source; busy-Mac run at load > 20 stays at ≥ 30 fps with the pill shown |
| After | G17 transport half, G18, G8 as queued | – |

Assumptions: Apple silicon only (D35), so VideoToolbox hardware encode and decode everywhere; the production relay for the G15/G16 and forced-relay runs when the fork's relay is up.

## 7. Risks

- The VideoToolbox latency state from the baseline (30–42 ms at 2560) makes 120 impossible at any size until it is understood; the encoder trace and the three session A/Bs come first.
- The virtual display may not composite at 120 on macOS 27; then Roshan's own 120 fps needs an external display, and the feature is honest: "120 fps on ProMotion and 120 Hz displays".
- Phone thermals: 120 fps decode plus 120 Hz display plus Wi-Fi on an iPhone will throttle; the ladder reads the phone's signals too.
- Bandwidth: 120 fps of full-screen motion at the LAN ceiling is fine; on internet P2P or relay the ladder drops to 60 first.
