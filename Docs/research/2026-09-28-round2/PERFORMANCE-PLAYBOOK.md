# PocketDesk performance playbook — round 2

**28 September 2026. Research only: no existing file was modified.** New files are this playbook and `probes/` (scratch programs used for the measurements below, kept so anyone can re-run them). Scope: MacBook Air M4 host (Mac16,13, macOS 27.0, Xcode 27.0 / SDK 27) to iPhone 17 native viewer, iOS/macOS 26 deployment floor, conditional 17 November launch (2 Nov go/no-go, 3 Nov submission per PRODUCT.md). Subordinate to PRODUCT.md and to the earlier [ENCODER.md](../2026-09-28/ENCODER.md) and [NETWORK-AND-SESSION.md](../2026-09-28/NETWORK-AND-SESSION.md), which this document corrects or sharpens where it found hard evidence.

## 0. How to read this

Every factual claim carries one label. Do not mix them.

| Label | Meaning |
|---|---|
| **[M]** | **Measured by this pass** on the project Mac (or with its exact WebRTC binary) on 28 Sep 2026. Method in Appendices B and C, code in `probes/`. |
| **[S]** | **Read from source**: an installed SDK header, the shipped `WebRTC.xcframework` binary (symbols/strings), the repo, or WebRTC source from the LiveKit m150 mirror (not byte-identical to the stasel M153 build; used only for logic that the M153 binary's strings and behaviour corroborate). |
| **[D]** | Apple, W3C or IETF **documentation** (non-performance statements such as API semantics). |
| **[V]** | **Vendor claim** (Astropad, Parsec, Jump, Apple marketing, Microsoft). Not reproduced by us. |
| **[3P]** | Third-party report or measurement. Not reproduced by us. |
| **[E]** | **Engineering estimate or inference.** Needs a test. |

Evidence-strength letters used in the change table: **A** measured by us on the shipped binary or hardware; **B** mechanism verified in source/header plus partial measurement; **C** documentation or vendor claim only; **D** inference.

**Measurement caveats (important).** The Mac was shared with other agents. Load average was 5–10 during the "quiet-window" runs used as primary evidence, 20–70 during some VideoToolbox runs, and rose above 1,000 late in the session (a simulator test fan-out), at which point even a 1920-wide loopback collapsed to 1 fps and I stopped. Rules I applied: (1) ratios and large effects are reported, absolute milliseconds are ±20%; (2) results that were obviously perturbed (the 2940-wide WebRTC loopback runs, encode 82 ms median) are excluded from conclusions and listed as such; (3) quality (PSNR) results are far less load-sensitive than latency, which is why some perturbed runs still carry a qualitative reading. Nothing here is phone-side: **no iPhone decode, render, thermal, radio or touch result was measured.** Synthetic frames (code editor, scrolling pane, moving block) are not a substitute for real screens or human legibility judgments; PSNR is a proxy, not "readable text".

## 1. Bottom line

1. **The soft text and the low, uneven frame rate are, on current evidence, mostly a rate-control and buffering problem, not a codec-choice problem.** In the exact WebRTC binary PocketDesk ships, the stock encoder uses non-low-latency VideoToolbox rate control **[S]**, the bandwidth estimator starts at 300 kbps **[S]**, an in-process loopback settles at QP 51 and about 22 dB luma PSNR on static text **[M]**, and the receiver adds 10–32 ms of jitter buffer even with zero network jitter **[M]**. None of that is fixed by HEVC.
2. **Two changes measured large and cost hours, not weeks:** forcing zero receiver smoothing through WebRTC field trials cut push-to-render-callback latency from a 26.8 ms median to 7.8 ms (p99 32 to 10.5 ms) on a quiet machine **[M]**; starting the bandwidth estimate at 12 Mb/s moved QP 51 to 40 and text-region PSNR from 22.6 to 36.5 dB **[M]** (but costs about +13 ms median if the receiver buffer is left on, so ship the two together).
3. **Verdict for 17 November (details in section 6):** ship *tuned hardware H.264 over WebRTC plus the WebRTC knobs above plus a sharp-on-idle refresh*. Treat **HEVC/4:4:4 as a post-launch native experiment** (host hardware supports it, iPhone decode and WebRTC glue are unproven). Treat a **dirty-rect lossless layer** as at most a small *settled-region refresh*, and only if a refresh keyframe is not enough. **A full custom tile codec is not a launch item.**
4. **Two findings sharpen earlier repo statements:** (a) ENCODER.md left HEVC 4:4:4 unproven; for the *host* it is now proven feasible: this M4's hardware HEVC encoder emits RExt 4:4:4 (chroma_format_idc 3) and the Mac hardware-decodes it **[M]**; the open questions are iPhone 17 decode and WebRTC transport. (b) Apple's guidance implies low-latency rate control lowers encode latency; **not observed**: it matched or exceeded default real-time encode latency, and its benefit is bitrate efficiency (section 5, R4).
5. **A "<16 ms end-to-end" result is not reachable with this hardware pair regardless of codec** **[E]**: a 60 Hz MacBook Air panel means a mean 8.3 ms (up to 16.7 ms) wait before capture, encode is 5–14 ms, and a phone display adds ~4 ms mean at 120 Hz. Astropad's claim is a **[V]** with an unstated method; a realistic tuned floor here is roughly 25–40 ms typical glass-to-glass on LAN (section 4).

### Top 10 recommendations (ranked; detail in section 5)

| # | Recommendation | Evidence | Effort | Beyond the parallel agent's work? |
|---|---|---|---|---|
| 1 | Zero playout smoothing: `WebRTC-ForcePlayoutDelay` (phone) and `WebRTC-ForceSendPlayoutDelay` (host) = `min_ms:0,max_ms:0` via `RTCInitFieldTrialDictionary` | A | 0.5 day | Yes |
| 2 | Bitrate ramp: `setBweMinBitrateBps(nil, current: 12M on Direct, max: 40M)`, raise per-encoding cap to 25–30 Mb/s on LAN | A | 0.5 day | Yes |
| 3 | Sharp on idle: after the screen settles, send one high-quality intra refresh (custom encoder) or a cancelable lossless refresh; stop trusting `qpAverage` as a sharpness metric | A/B | 2–5 days | Yes |
| 4 | Tuned VT H.264: `EnableLowLatencyRateControl` (High profile), `RealTime`, `AverageBitRate`, `MaxKeyFrameInterval` large; do **not** rely on `PrioritizeEncodingSpeedOverQuality` (unsupported in that mode) | A | (agent) | Refines it |
| 5 | Pixel budget: cap encoded area (about 4.3 MP / 2560×1664 for 60 fps, less on thermal pressure); encode time scales with pixels | A | 1 day | Yes |
| 6 | Phone renderer: 120 Hz, 2 drawables, present on arrival, `CADisableMinimumFrameDurationOnPhone`; quick KVC test on `RTCMTLVideoView.metalView` first | B | 0.5 day test, 1–2 weeks full | Yes |
| 7 | Split input: unordered, `maxRetransmits: 0` pointer channel, binary, latest-wins at 120 Hz; keep an ordered channel for clicks/keys | B | 3–5 days | Yes |
| 8 | Bound pacer delay for keyframes: `WebRTC-Video-Pacing/factor:2.5,max_delay:30ms` (needs an IDR-spike test) | B | 0.5 day + test | Yes |
| 9 | Viewport-native capture (`SCStreamConfiguration.sourceRect` + 1:1 pixel mapping) for sharp zoomed text: the best sharpness lever before any tile codec | C/D | 2–3 weeks | Yes |
| 10 | Measure properly: camera glass-to-glass, SCK `displayTime` anchor, `outbound-rtp.totalPacketSendDelay`, `MTLDrawable` presented time, and an Ethernet/AWDL A/B | C/3P | 2–4 days | Extends it |

## 2. What the code and the shipped binary actually do

Facts first; hypotheses are in section 3.

| # | Fact | Label and source |
|---|---|---|
| F1 | The shipped `WebRTC.xcframework` (stasel 153.0.0) links only these VideoToolbox **encoder** symbols: `AllowFrameReordering`, `AverageBitRate`, `DataRateLimits`, `ExpectedFrameRate`, `MaxKeyFrameInterval`, `MaxKeyFrameIntervalDuration`, `ProfileLevel`, `RealTime`, `UsingHardwareAcceleratedVideoEncoder`, `ForceKeyFrame`, and (macOS) `EnableHardwareAcceleratedVideoEncoder`. **Absent:** `EnableLowLatencyRateControl`, `PrioritizeEncodingSpeedOverQuality`, `MaxAllowedFrameQP`, `MinAllowedFrameQP`, `Quality`, `EnableLTR`, `ConstantBitRate`, `MaxFrameDelayCount`; no HEVC strings. | **[S]** `nm -u` and `strings` on both slices under `DerivedData/…/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework`. The LiveKit m150 fork's `RTCVideoEncoderH264.mm` *does* set low-latency RC and `MaxAllowedFrameQP`; **do not read that file as what PocketDesk runs.** |
| F2 | H.265 **RTP packetizer, depacketizer and bitstream parser are compiled in** (`rtp_packetizer_h265.cc`, `video_rtp_depacketizer_h265.cc`, `h265_bitstream_parser.cc`, `WebRTC-H265-QualityScaling`), but there is **no VideoToolbox HEVC wrapper**: no H265 ObjC encoder/decoder classes in the shipped headers (only `RTCVideoEncoderH264`, `RTCVideoDecoderH264`, `RTCCodecSpecificInfoH264`). HEVC therefore needs a custom `RTCVideoEncoder`/`RTCVideoDecoder` pair. | **[S]** binary strings and `Headers/` listing. The LiveKit fork contains reference H265 classes (`RTCVideoEncoderH265.mm`, `RTCVideoDecoderH265.mm`). |
| F3 | Field-trial names present in the M153 binary include `WebRTC-ForcePlayoutDelay`, `WebRTC-ForceSendPlayoutDelay`, `WebRTC-Video-Pacing`, `WebRTC-JitterEstimatorConfig`, `WebRTC-Bwe-ProbingConfiguration`, `WebRTC-KeyframeInterval`, `WebRTC-FrameDropper`, `WebRTC-Bwe-ScreamV2`, `WebRTC-RFC8888CongestionControlFeedback`. `RTCInitFieldTrialDictionary` is exported (header marks it deprecated with a "delete after 1 Jan 2026" TODO, yet it is present and **works**, see Appendix B). | **[S]** strings/`nm`; **[M]** effect proven in Appendix B. |
| F4 | ObjC surface in M153: **no** receiver jitter-buffer/playout API; **yes** `setBweMinBitrateBps:currentBitrateBps:maxBitrateBps:`, `RTCRtpEncodingParameters.{min,max}BitrateBps, maxFramerate, networkPriority, scalabilityMode`, `RTCRtpParameters.degradationPreference`, `RTCConfiguration.enableDscp`, data-channel `isOrdered/maxRetransmits/maxPacketLifeTime`. | **[S]** shipped headers. |
| F5 | The 12 Mb/s and 60 fps caps are applied **only** when the peer is native (`PeerMedia.configureNativeSender`, `nativeDesktopCodecs == true`). For a **browser viewer** the host's sender keeps WebRTC's default cap: 2.5 Mb/s for frames above 960×540 (`GetMaxDefaultVideoBitrateKbps`, screenshare floor 1.2 Mb/s), which will look soft on text. | **[S]** `RemoteShared/PeerMedia.swift`; WebRTC `encoder_stream_factory.cc`. |
| F6 | WebRTC's send-side start estimate is **300 kbps** (`BitrateSettings::kDefaultStartBitrateBps`); the repo's own receipt logs `SetStartBitrate 300000`. Pacing rate is target **× 1.1** once send-side BWE is active, with a 2 s expected-queue limit. | **[S]** WebRTC source; repo `work/continuation/final-codec-benchmark.log`. |
| F7 | For screencast sources WebRTC's default degradation preference is `MAINTAIN_RESOLUTION`: under pressure it drops **frame rate**, not pixels. For H.264/H.265 the *static-QP* "quality converged" threshold is disabled (-1), so WebRTC gives no QP-based convergence signal for these codecs (whether its dynamic detection converges was not checked). Zero-hertz screenshare repeat logic exists but is armed only when constraints set `min_fps = 0`, which the native `RTCVideoSource` path does not do. | **[S]** `webrtc_video_engine.cc`, `quality_convergence_controller.cc`, `video_stream_encoder.cc`. |
| F8 | Phone rendering uses stock `RTCMTLVideoView`, which wraps an `MTKView` with defaults: `preferredFramesPerSecond` **60**, `CAMetalLayer.maximumDrawableCount` **3** (valid range 2–3). iPhone 17 is ProMotion up to 120 Hz. `CADisableMinimumFrameDurationOnPhone` is **not** set in `project.yml` (grep found none), and Apple says without it Core Animation will not exceed 60 Hz on iPhone. | **[S]** `RTCMTLVideoView.m` (m150), `MTKView.h`, `CAMetalLayer.h` (iPhoneOS 27.0 SDK), repo grep; **[D]** Apple ProMotion article; iPhone 17 specs (2622×1206 px, 460 ppi, ProMotion). |
| F9 | The WebRTC H.264 decoder sets `RealTime` and decodes asynchronously, asks VideoToolbox for **NV12 full-range** output, and in loopback the delivered buffers were `420f` (`34323066`). | **[S]** `RTCVideoDecoderH264.mm`; **[M]** loopback receipt. |
| F10 | Capture: `minimumFrameInterval` 1/60, `queueDepth` 3, `420YpCbCr8BiPlanarVideoRange`, cursor drawn into the video, `dirtyRects` unused. SDK 27 header: `queueDepth` default **8**, "should not exceed 8"; `minimumFrameInterval = kCMTimeZero` means the display's native refresh; supported `pixelFormat`s include `xf44` (10-bit 4:4:4). Apple's WWDC22 session text says the default is 3 and recommends 3–5; **the header and the session disagree, so always set it explicitly** (PocketDesk does). | **[S]** `RemoteCapture.swift`, `SCStream.h`; **[D]** WWDC22 10155 (checked 28 Sep 2026). |
| F11 | A pointer move is a JSON `ControlPacket`: **169 bytes** (legacy) to **215 bytes** (with `NativeInteraction`), versus ~9 bytes in a binary encoding. The control channel is ordered and reliable; `sendControl` refuses to send when `bufferedAmount ≥ 64 KB`. | **[M]** `probes/jsonsize`; **[S]** `PeerMedia.swift`. |
| F12 | `PocketDesktopHost/HostStream.swift` (older custom-wire prototype) sets H.264 **Main** with low-latency RC; the SDK 27 header says low-latency RC supports **High profiles only**. It is not the production WebRTC path; noted so nobody copies it. | **[S]** file and `VTCompressionProperties.h`. |
| F13 | Encoder inventory on this M4: `ave.avc` / `ave.hevc` (hardware) for default sessions; enabling low-latency RC selects **different encoders** (`h264.rtvc`, `hevc.rtvc`). In low-latency mode `PrioritizeEncodingSpeedOverQuality` returns **-12900** (`kVTPropertyNotSupportedErr`) for both codecs, although Apple's header recommends it for cloud gaming. Low-latency sessions use only 3–6% of one core, so they are effectively hardware even though `UsingHardwareAcceleratedVideoEncoder` does not report `true` for them. | **[M]** `probes/vtprops`, `probes/vtprobe`; **[S]** header recommendation. |
| F14 | This M4's **hardware HEVC encoder accepts 4:4:4 input (`444v`, `444f`, `xf44`) and, with no profile constraint, emits HEVC RExt with `chroma_format_idc = 3`** (8-bit and 10-bit), and the VideoToolbox decoder hardware-decodes it to `444v`/`444f`/`pf44`. H.264 silently converts the same inputs to High 4:2:0. HEVC Main/Main10/Main42210 constants exist; there is no public "Main 4:4:4" constant, which is why the earlier note could not confirm it. | **[M]** `probes/vtfmt2` (SPS parsed). |

## 3. Why the phone shows 15–28 distinct frames/s, 117 ms gaps and soft text

Ranked by how well the evidence fits all three symptoms. Each has a falsification test that uses stats PocketDesk already emits (`targetKbps`, `qpAverage`, `qualityLimitation`, `jitterBufferMs`, `renderGapP90Ms`) so it can be settled on the phone in one 5-minute session.

| H | Hypothesis | Evidence | Falsify by |
|---|---|---|---|
| H1 | **Bitrate/rate-control starvation.** BWE starts at 300 kbps; VideoToolbox default rate control spends far less than the target on screen content; the first keyframe of a static screen is encoded at starved quality and static text is never refined because P-frames are all-skip (they even *report* QP 51). Under motion, screenshare `frame_drop_enabled` plus `MAINTAIN_RESOLUTION` turns starvation into dropped frames (low, uneven fps) while text stays soft. | **[M]** loopback baseline: target 2.4–5.6 Mb/s but sent 0.65 Mb/s, QP 51, text PSNR 22.6 dB; BWE start 12M: QP 40, 36.5 dB. **[S]** F6, F7, `frame_drop_enabled: 1` in the repo receipt. | On the phone, log `targetKbps`, `qualityLimitation`, framesDropped-at-encoder and `qpAverage` over the first 60 s and after a full-screen change. If target is ≥ 8 Mb/s from second 2 and fps is still low, H1 is wrong. |
| H2 | **Keyframe bursts and pacing.** IDRs are 176–432 KB (H.264) and up to 594 KB (HEVC 4:4:4) at 2940×1912 **[M]**; at pacing = 1.1 × BWE (12 Mb/s) that is roughly 105–260 ms (H.264) just to leave the sender queue **[E]** (size ÷ 13.2 Mb/s), longer for bigger keyframes or a lower estimate. Anything queued behind it (later frames, and input replies) waits. | **[M]** IDR sizes; **[S]** F6. | Watch `pliReceived`, `keyFrames`, `outbound-rtp.totalPacketSendDelay` (key exists in M153 strings) against gap spikes. |
| H3 | **Receiver smoothing.** Default playout adds 10–32 ms on a zero-jitter loopback and grows with frame size. | **[M]** 10 ms (base), 23.5 ms (bigger frames), 0 with forced 0/0. | Force 0/0 (R1) and re-measure gap p90. |
| H4 | **60 Hz render cap and a deep drawable queue** on a 120 Hz phone. | **[S]** F8. | On-device `MTLDrawable` presented-time histogram; swap renderer (R6). |
| H5 | **Wi-Fi jitter (AWDL/channel hopping)** on Mac and phone radios. | **[3P]** an IIJ researcher reported Moonlight-style tests bouncing between 3 and 90 ms with AWDL active (RIPE 91, 23 Oct 2025). Not measured on this network. | A/B: Ethernet on the Mac, or `sudo ifconfig awdl0 down` for the test only, same content. |
| H6 | **Capture cadence itself** (60 Hz panel, content that updates at 20–30 Hz, SCK `.idle`). | **[D]** SCK delivers frames only when content changes. **[E]** | Passive `probes/sckprobe` on the real screen (not run: machine saturated). |

`qpAverage` is a poor sharpness proxy for static screens: skip-only P-frames report QP 51 while text quality is set by the last keyframe **[M]** (the combined R1+R2 run reported median QP 51 yet 34.1 dB text PSNR). Use a legibility metric (PSNR/SSIM of a fixed text crop, or a blind read test) instead.

## 4. Latency budget per stage

Two paths. "Target" assumes the tuned configuration on a good 5/6 GHz LAN, 60 Hz Mac panel, 120 Hz iPhone 17. "Likely today" is a range, not a measurement, unless marked.

### 4a. Screen change on the Mac to photons on the phone

| Stage | Target | Likely today | Basis |
|---|---|---|---|
| Window server draws → SCK sample callback | 0–17 (mean 8) | same | **[E]** 60 Hz panel; 60 Hz cap; callback latency vs `SCStreamFrameInfoDisplayTime` **not measured** (`probes/sckprobe` ready) |
| SCK callback → `pushFrame` → WebRTC source | < 1 | < 1 (try-lock can drop a frame) | **[S]** `PeerMedia.pushFrame` |
| Encode (hardware VT) | ≤ 8 | 5.4 ms at 1920×1248, 12–14 ms at 2940×1912 (both H.264 and HEVC low-latency), default HEVC 7.4 ms at 2940 | **[M]** Appendix A |
| Packetize + pacer | ≤ 3 typical, ≤ 30 for an IDR | 1–3 typical; IDR 100–340 | **[E]** arithmetic on **[M]** sizes and **[S]** pacing factor |
| Wi-Fi one way | 2–6 | 2–8 typical, spikes to tens of ms | **[E]**; **[3P]** for AWDL |
| Receive smoothing | 0–5 | 10–32 (loopback, zero jitter) | **[M]** |
| Decode | ≤ 4 | 2–4 on Mac; **iPhone unmeasured** | **[M]** Mac loopback |
| Render wait (display link + drawable queue) | ≤ 4 | 0–17 for the 60 Hz display link plus up to one more frame of drawable queue | **[S]** F8 |
| Panel scanout at 120 Hz | mean 4 | mean 4 | **[E]** |
| **Total** | **about 25–40 typical, p95 ≲ 70** | **about 60–110 typical**, with 100–350 ms spikes from IDR pacing, BWE swings and Wi-Fi | **[E]** sum of the above; consistent with the observed 117 ms p90 gap |

Loopback reference (no network, no display) **[M]**, 1920×1248, quiet machine: push→render-callback median **26.8 ms** (p99 32.0) in the current configuration, **7.8 ms** (p99 10.5) with forced zero playout delay, **39.9 ms** (p99 113.7, max 159.6) with only the 12 Mb/s start added, **14.3 ms** (p90 27.3, p99 41.6, max 157.7) with 12 Mb/s start + zero playout delay + a pacer bound. Note the last row's tail: a mid-run large frame still produces a spike, which is why R8 needs an IDR test rather than a promise.

### 4b. Touch to visible reaction

| Stage | Target | Likely today | Basis |
|---|---|---|---|
| Touch sampling (120 Hz; coalesced touches add precision, not latency) | mean 4 | mean 4–8 | **[D]** UIKit coalesced/predicted touches |
| Gesture engine, JSON encode, SCTP enqueue | < 1 | < 1 (169–215 B/move) | **[M]** F11 |
| Wi-Fi uplink; ordered-reliable head-of-line risk | 2–6 | 2–8, plus stall if a keyframe burst shares the path | **[E]** |
| Host receive → admission → `CGEvent` post | 1–3 | 1–3; `CGEvent.post(tap: .cghidEventTap)` costs 7 µs median, 731 µs p99 (loaded machine) | **[M]** `probes/cgprobe` |
| App reaction + window server composite | 8–33 | same | **[E]** |
| Then the 4a path | 25–40 | 60–110 | above |
| **Total** | **about 45–90 typical** | **about 85–190 typical** | **[E]**; PRODUCT.md's proposed bar is p95 ≤ 150 ms on LAN |

A phone-rendered local pointer removes the pointer-motion portion of this path from the user's perception (the finger and the cursor never wait), but per PRODUCT.md it must not be marketed as lower application-response latency.

## 5. Ranked changes

Columns: impact on the stated symptom, effort (one developer plus AI help; all effort figures are **[E]** estimates), risk, evidence letter. "Agent" marks work the parallel agent (stage instrumentation, H.264 low-latency tuning) already owns; "Beyond" marks items that go past it.

| ID | Change | Impact | Effort | Risk | Ev. | Scope |
|---|---|---|---|---|---|---|
| R1 | Zero receiver smoothing (field trials) | Latency −10 to −20 ms typical; removes the buffer that grows with frame size | 0.5 d | Low-med | A | Beyond |
| R2 | BWE start/floor/cap | Sharpness (QP 51→40, +13 dB text PSNR); fewer starved frames | 0.5 d | Low | A | Beyond |
| R3 | Sharp-on-idle refresh | Static text becomes crisp; today it stays at first-IDR quality | 2–5 d | Med | A/B | Beyond |
| R4 | Tuned VT H.264 (low-latency RC) | Quality per bit (+7 dB at same target in synthetic desktop); no encode-latency gain | (agent) | Med | A | Agent, refined here |
| R5 | Pixel budget and adaptive area | Encode 5.4 ms → 12–14 ms as area doubles; headroom | 1 d | Low | A | Beyond |
| R6 | Phone renderer (120 Hz, 2 drawables, present on arrival) | −8 to −25 ms, smoother pan/zoom | 0.5 d test; 1–2 wk full | Med | B | Beyond |
| R7 | Split input channels, binary, coalesced | Removes head-of-line risk; smoother pointer | 3–5 d | Low-med | B | Beyond |
| R8 | Bound pacer delay for large frames | Caps IDR queueing (100–340 ms → ≤ 30 ms target) | 0.5 d + test | Med | B | Beyond |
| R9 | Viewport-native capture (`sourceRect`) | Best lever for sharp zoomed text; fewer pixels to encode | 2–3 wk | Med-high | C/D | Beyond |
| R10 | Network hygiene: Ethernet, AWDL A/B, DSCP | Removes Wi-Fi spikes if H5 holds | 1 d | Low | C/3P | Beyond |
| R11 | Loss recovery without IDR (LTR) | Removes IDR bursts on lossy links | 2–3 wk | Med | C | Post-launch |
| R12 | HEVC / 4:4:4 native experiment | Bits (−30%) and chroma | 2–3 wk | High | A(host)/U(phone) | Post-launch |
| R13 | Dirty-rect use: (a) content classifier, (b) settled-region lossless refresh | (a) policy switching cheap; (b) crisp text with cancelable delivery | (a) 2–3 d; (b) 2–4 wk | (a) low; (b) high | B/C | Beyond |
| R14 | Instrumentation additions | Makes everything above falsifiable | 2–4 d | Low | A/C | Extends agent |
| R15 | Full custom codec / QUIC transport / L4S | None for launch | 12–24+ wk | Very high | C | No |

### R1. Zero receiver smoothing (measured, ship first)

Mechanism **[S]**: `VCMTiming::UseLowLatencyRendering()` is true when `min_playout_delay == 0` and `max_playout_delay <= 500 ms`; `RenderTime()` then returns 0, meaning decode and render as soon as a frame is complete. With max exactly 0 the 8 ms `WebRTC-ZeroPlayoutDelay` inter-decode pacing is skipped and stale queued frames are fast-forwarded. The sender-side trial makes the RTP `playout-delay` header extension carry the values (so any receiver that implements the extension can honour it; browser behaviour is untested here); the receiver-side trial overrides locally and is what the loopback measured.

```swift
// Very first WebRTC touch in BOTH processes, before RTCInitializeSSL / factory creation.
RTCInitFieldTrialDictionary([
  "WebRTC-ForcePlayoutDelay":     "min_ms:0,max_ms:0",   // phone (receiver)
  "WebRTC-ForceSendPlayoutDelay": "min_ms:0,max_ms:0",   // host (sender), for browser viewers
])
```

Measured **[M]** (1920×1248, quiet machine): jitter buffer 10.1 → 0.0 ms, push→render median 26.8 → 7.8 ms, p90 30.2 → 9.5, p99 32.0 → 10.5. Effect held at 2940×1912 in a load-perturbed run (median 15.6 ms) but treat that as qualitative.
Risks: Wi-Fi jitter now shows up directly as cadence jitter; a lost packet freezes until NACK recovery (same as before, without the cushion). Test `min_ms:0,max_ms:20` and `0/50` if 0/0 looks uneven on the phone. `RTCInitFieldTrialDictionary` is deprecated in the M153 header: **add a launch-blocking unit check** that asserts `jitterBufferMs ≈ 0` in a loopback test so a WebRTC bump that removes the symbol or the trial is caught.

### R2. Bandwidth-estimate start, floor and cap (measured)

```swift
// After the peer connection is connected, host side, when the route is Direct (MediaRoute == "Direct"):
_ = connection.setBweMinBitrateBps(nil, currentBitrateBps: NSNumber(value: 12_000_000), maxBitrateBps: NSNumber(value: 40_000_000))
// Per-encoding cap (today 12_000_000 on the native host only):
encoding.maxBitrateBps = NSNumber(value: 30_000_000)   // LAN; keep 12_000_000 or lower on Relay/cellular
encoding.maxFramerate  = NSNumber(value: 60)
```

Header text **[S]**: `currentBitrateBps` "will force the available bitrate estimate to the given value". GCC then still adapts down on congestion. Apply a lower start (for example 3 Mb/s) on Relay or cellular routes. Also raise the **browser** sender's cap (default 2.5 Mb/s, F5) if browser viewers matter.
Measured **[M]**: baseline QP 51, text PSNR 22.6 dB, 0.67 Mb/s sent; with a 12 Mb/s start QP 40.1, text PSNR 36.5 dB, 1.66 Mb/s sent; at 2940×1912 QP 44.4, 33.0 dB (load-perturbed run). Trade-off: bigger keyframes and a larger jitter target (23.5 ms) unless R1 ships too. The combined run still showed run-to-run variance in first-keyframe quality (34.1 dB text PSNR at QP 51 median), because the first IDR can be encoded before the new estimate reaches the encoder. That variance is the argument for R3.

### R3. Sharp on idle: stop freezing text at first-IDR quality

Two implementation routes; pick by effort:

1. **Custom encoder route (fits the agent's H.264 work).** When SCK reports no complete frame for about 150 ms after activity, the wrapper issues `kVTEncodeFrameOptionKey_ForceKeyFrame` for one refresh frame, preceded by raising the rate budget for that frame and (in low-latency mode, where `Quality` is not offered) tightening `kVTCompressionPropertyKey_MaxAllowedFrameQP` toward about 24 for the refresh only; restore afterwards. Verify each property is honoured mid-session (`VTCopySupportedPropertyDictionaryForEncoder` lists `MaxAllowedFrameQP` as ReadWrite in low-latency mode **[M]**). Caveat from Apple's WWDC21 session **[D]**: hitting the QP cap with an exhausted budget makes the encoder drop frames. Pacer caveat: a 150–400 KB refresh IDR queues later frames behind it, so pair with R8.
2. **Stock-encoder hack (untested).** Force a reconfigure (`RTCVideoSource.adaptOutputFormat` nudged by 2 px and back) right after a BWE bump. `probes/wrtcbench` has this (`REFRESH_AT`, `BWE_LATE`) but the run could not complete on the saturated machine; **treat as unverified**.
3. **Cancelable lossless refresh.** Better than an IDR because it can be aborted the moment a dirty rect touches the region (R13b).

Success metric: text-crop PSNR (or blind read test) after 300 ms idle at least 40 dB on a 13 px code sample, and no added p95 input latency when interaction resumes within 100 ms of a refresh.

### R4. Tuned VideoToolbox H.264 (the parallel agent owns this; measured facts to feed it)

Apple's SDK 27 header recommends for "ultra-low-latency conferencing and cloud gaming": `EnableLowLatencyRateControl`, `RealTime`, `ExpectedFrameRate`, `PrioritizeEncodingSpeedOverQuality`. What I measured on this M4 differs from that advice in several ways **[M]**:

| Finding | Data |
|---|---|
| `PrioritizeEncodingSpeedOverQuality` is **unsupported** in low-latency mode (returns -12900) for both H.264 and HEVC | `probes/vtprobe`: rows show identical results with and without it |
| Low-latency RC did **not** lower encode latency vs RealTime + no reordering (which already reports `MaxFrameDelayCount = 0`) | 1920×1248: 5.3 vs 5.4 ms p50; 2940×1912: 13.5–13.8 vs 11.7–12.0 ms p50 (H.264); HEVC 14.3–14.9 vs 7.3–7.5 ms |
| Low-latency RC **spends the bitrate budget and holds quality**; default RC underspends. Same "12 Mb/s" target, 2940×1912 desktop content: H.264 default 4.42 Mb/s, 43.4 dB luma; low-latency 7.03 Mb/s, 50.8 dB. Full-motion scroll: default 9.03 Mb/s, 36.1 dB; low-latency 12.57 Mb/s, 41.2 dB | Appendix A |
| Under starvation low-latency RC **drops frames** instead of degrading quality: at a 5 Mb/s target, full-motion 2940×1912 dropped 40 of 240 frames (16.7%), 1920×1248 dropped 4 | This is the same shape as "15–28 distinct frames/s" and is a design choice to make deliberately (frame drops vs blur) |
| Throughput ceilings (unpaced): 2940×1912 about 74–85 fps; 1920×1248 about 170–186 fps | At native resolution 60 fps leaves only 25–30% headroom |

Recipe to test: High profile only, `EnableLowLatencyRateControl = true` at session creation, `RealTime = true`, `AllowFrameReordering = false`, `ExpectedFrameRate = 60`, `AverageBitRate` from WebRTC's `setBitrate`, `MaxKeyFrameInterval` large, `DataRateLimits` optional, `SpatialAdaptiveQPLevel` disabled (header: must be disabled in low-latency mode), `MaxAllowedFrameQP` unset except for refresh (R3). HEVC with low-latency RC also selects a different encoder (`hevc.rtvc`). Do not set `Main` or `Baseline` with low-latency RC (header: High only; the LiveKit source warns it disables hardware).
Private-looking keys appear in the supported dictionary (`NumberOfSlices`, `QualityMode`, `SliceQP`, `SliceMaxQP`, `PerceptualQualityOptimization`) but are **not in the SDK 27 headers**: do not depend on them (stability and App Review risk).

### R5. Pixel budget

Encode time scales roughly linearly with area on this hardware (about 2.3 ms per megapixel for H.264 low-latency) **[M]**. Policy: cap the encoded area at about 4.3 MP (2560×1664, about 10 ms) for 60 fps; use about 2.7 MP (2048×1331, about 6 ms) on thermal pressure or on Relay; keep capture exactly at the fitted size so WebRTC never runs CPU crop/scale (`cropAndScaleTo` in the ObjC encoder is a per-frame CPU path) **[S]**. Native 2940×1912 leaves 25–30% headroom **[M]** and would cap out under 120 Hz capture. The phone's landscape width is 2622 px, so a 2560-wide stream is close to 1:1 in full-width landscape; portrait Fit needs only 1206 px.

### R6. Phone renderer

Quick experiment (0.5 day): `view.value(forKey: "metalView")` on `RTCMTLVideoView` (a class-extension property, reachable through KVC) and set `preferredFramesPerSecond = 120`, `(layer as? CAMetalLayer)?.maximumDrawableCount = 2`; add `CADisableMinimumFrameDurationOnPhone = YES`. Full version: own `CAMetalLayer` renderer driven by `CAMetalDisplayLink` (iOS 17+, `preferredFrameLatency`, `preferredFrameRateRange` 80–120), draw the newest decoded frame only, `presentsWithTransaction = false`, sample with a text-friendly filter (nearest at integer scale, Lanczos otherwise, not the compositor's bilinear). Measure with `MTLDrawable.addPresentedHandler` so the effect is a number, not a feeling. Alternative for a WebRTC pipeline: a custom `RTCVideoRenderer` feeding an `AVSampleBufferDisplayLayer` with `kCMSampleAttachmentKey_DisplayImmediately` (Apple: display as soon as possible rather than at the PTS) as Moonlight iOS does (it enqueues to the layer and paces with a `CADisplayLink`, optionally holding one frame). Low power mode and thermals can disable 120 Hz **[D]**; never assume it.

### R7. Input channel

Add a second data channel (`isOrdered = false`, `maxRetransmits = 0`) for pointer motion only: fixed binary frame (about 9–16 bytes: sequence, dx/dy or absolute position, buttons), sender coalesces to the latest state at display cadence (up to 120 Hz), host applies only the newest pending move per tick and posts it off the main actor. Use cumulative or absolute values so a lost datagram cannot cause drift. Keep the existing ordered, reliable channel for clicks, keys, scroll phases and text (and repeat the pointer position inside each click so ordering is never ambiguous). `UIEvent.coalescedTouches(for:)` gives more samples per event and `predictedTouches(for:)` a short-horizon estimate **[D]**; use them for smoothing, not to invent latency wins. CGEvent posting is not the bottleneck **[M]**.

### R8. Bound pacer delay

`WebRTC-Video-Pacing/factor:F,max_delay:D/` sets the pacing multiplier (default 1.1) and the queue-time limit (default 2 s) **[S]**; when the expected queue time exceeds the limit the pacer raises its rate to drain within it. Candidate: `factor:2.5,max_delay:30ms` (host process). Result **[M]**: no change on the desktop synthetic (no large frames), so the effect is **unproven**; a keyframe-injection A/B is the required test (`REFRESH_AT` in `probes/wrtcbench`, not completed). If the RFC 8888 congestion-control feedback trial is ever enabled, pacing is decided in the congestion controller and this trial no longer applies.

### R9. Viewport-native capture (highest sharpness ceiling before any custom codec)

The phone is a pannable, zoomable viewport. Everything the user actually reads is shown at some non-integer scale, so text is resampled twice: once by the codec and once by the compositor. Instead, capture only what is visible: `SCStreamConfiguration.sourceRect` (logical points) with `width/height` equal to the phone's physical pixel size of the viewport so one video pixel maps to one screen pixel; update after gestures settle via `SCStream.updateConfiguration` (Apple: dynamic updates supported **[D]**) while the local transform keeps the last frame under the user's fingers. It also cuts encoded pixels 4–8× when zoomed (R5). Risks: input-coordinate mapping, cursor overlay, reconfiguration hiccups and blank frames on some updates (unknown), and it interacts with the native-experience work. PRODUCT.md already lists "sharper zoomed regions" as an experiment; this section is the evidence for prioritising it over a tile codec. Not measured here.

### R10. Network hygiene

Put the Mac on Ethernet or a clean 5/6 GHz channel for the benchmark; A/B `sudo ifconfig awdl0 down` (diagnosis only, never shipped) **[3P]** reports for AWDL; set `RTCConfiguration.enableDscp = true` and `RTCRtpEncodingParameters.networkPriority = .high` for WMM marking (helps only if the access point honours it). L4S needs ECN-marking bottlenecks and a scalable congestion controller; Apple documents automatic support for TCP/QUIC/HTTP3 from iOS 17 / macOS 14, not for WebRTC **[D]**; skip for launch.

### Reference tables: exact settings

**ScreenCaptureKit (`SCStreamConfiguration` and frame info)**

| Property | Today | Recommendation | Evidence |
|---|---|---|---|
| `queueDepth` | 3 | Keep it explicit. Shallower means less buffering latency but surfaces must be released within roughly `minimumFrameInterval × (depth − 1)` or frames drop (WWDC22); the header default is 8, which buffers more. A/B 3 vs 5 with `probes/sckprobe` on a quiet machine | **[D][S]** |
| `minimumFrameInterval` | 1/60 | Right for a 60 Hz panel. `.zero` means the display's native rate; only matters for a 120 Hz host display. Apple's remote-desktop sample uses 720p at 15 fps: a sample, not a target | **[S][D]** |
| `pixelFormat` | `420v` | Keep: encoder-native, no conversion, and Apple's streaming guidance. `xf44` (10-bit 4:4:4) only for the 4:4:4 experiment; BGRA adds a conversion | **[D][S]** |
| `width` / `height` | policy-fitted | Keep explicit and identical to what the encoder receives (R5) so WebRTC never crops or scales on the CPU | **[S]** |
| `captureResolution` | unset | Leave unset while width/height are explicit; `.nominal` (point resolution) is a cheap way to halve pixels for a Responsive mode (unmeasured) | **[S]** |
| `showsCursor` | true (cursor baked into video) | Set false only when the phone-rendered pointer has an authoritative pointer source (PRODUCT S0 gate); then pointer latency stops depending on video latency | **[S]** |
| `sourceRect` / `destinationRect` | unused | R9 | **[S]** |
| `dirtyRects`, `displayTime` | unused | R13a and the latency anchor in section 7 | **[S]** |
| `presenterOverlay*`, `captureDynamicRange` | n/a | Leave off / SDR (the overlay composites a camera; HDR adds cost) | **[S]** |
| Colour range | default | Measured decoded buffers arrive as full-range `420f` with values range-converted (background luma 226 in the video-range source became 249), so any custom renderer must treat them as full range | **[M]** |

**VideoToolbox encoder properties on this M4 (macOS 27)**

| Property | Default encoder (`ave.*`) | Low-latency encoder (`rtvc`) | Recommendation |
|---|---|---|---|
| `RealTime`, `AllowFrameReordering` | supported | supported / n/a | `true` / `false` |
| `MaxFrameDelayCount` | read-only, reports 0 | not listed | do not set (the reason upstream WebRTC's attempt failed) |
| `PrioritizeEncodingSpeedOverQuality` | supported | **unsupported (-12900)** | do not rely on |
| `AverageBitRate`, `DataRateLimits` | supported | supported | use |
| `ConstantBitRate`, `VariableBitRate`, `VBV*` | supported (macOS 13 / 26) | not listed; header: incompatible with low-latency | avoid (header: CBR is for legacy CDNs) |
| `Quality` | supported | not listed | avoid in low-latency; candidate for a separate refresh session |
| `ConstantQualityFactor`, preset `ConsistentQuality` | macOS 27 only | not listed | availability-gate; test for refresh only |
| `MinAllowedFrameQP`, `MaxAllowedFrameQP` | supported | supported | refresh only; the encoder may drop frames to honour the cap |
| `SpatialAdaptiveQPLevel` | supported | header: must be disabled | leave default |
| `EnableLTR`, `ReferenceBufferCount`, `BaseLayerFrameRateFraction` | not listed | supported | LTR is R11; temporal layers are unusable with stock WebRTC H.264 (the RTP sender has no H.264 temporal-layer support **[S]**) |
| `NumberOfSlices`, `QualityMode`, `SliceQP`, `PerceptualQualityOptimization` | present, undocumented | present | not in public headers: do not depend on them |
| Profile / chroma | H.264 High/Main/Baseline; HEVC Main, Main10, Main42210; RExt 4:4:4/4:2:2 when no profile is set and the source is 4:4:4/4:2:2 | High only (header) | High for launch |

**WebRTC settings**

| Setting | Today | Recommendation | Evidence |
|---|---|---|---|
| Degradation preference | screencast default `MAINTAIN_RESOLUTION` (drops fps) | Keep. Never `MaintainFramerate` for text (it scales pixels down; W3C "motion" hint). `MaintainFramerateAndResolution` on Direct routes is an option once instrumented | **[S][D]** |
| Content hint | not exposed in ObjC; `videoSource(forScreenCast: true)` sets screenshare | Nothing to do; W3C "text"/"detail" hints map to maintain-resolution | **[S][D]** |
| Start / max bitrate | 300 kbps / 12 Mb/s (native only) | R2 | **[S][M]** |
| RTX and NACK | on | Keep; watch `nackReceived` | **[S]** |
| FEC | not used by default | Keep off on LAN (Sunshine's default costs 20% overhead); `WebRTC-FlexFEC-03` exists if a relay proves lossy | **[3P][S]** |
| Keyframes | start, PLI, resize; encoder GOP 7,200 frames | Keep an effectively infinite GOP; track `pliReceived`; LTR later (R11); `WebRTC-KeyframeInterval` trial exists if needed | **[S]** |
| Data channel | ordered, reliable | R7 | **[S]** |
| DSCP | off | `enableDscp` plus `networkPriority` | **[S]** |
| Playout | default smoothing | R1 | **[M]** |

### R11–R15 in one paragraph each

**R11 (LTR).** VideoToolbox supports long-term-reference frames (`kVTCompressionPropertyKey_EnableLTR`, acknowledgement via `kVTEncodeFrameOptionKey_AcknowledgedLTRTokens`, refresh via `ForceLTRRefresh`); Apple's WWDC21 session says the LTR-predicted frame is usually much smaller than a keyframe, and the acknowledgements must be carried by the app (for example RTCP RPSI) **[D]**. It only exists in low-latency mode **[M]**. Moonlight's maintainers are moving their own reference-frame-invalidation protocol to LTR **[3P]**. Useful for lossy Wi-Fi or relay; needs an ack path over the data channel and a custom encoder; post-launch.
**R12 (HEVC).** See section 6.
**R13 (dirty rects).** SCK `dirtyRects` are pixel rectangles, the union of redrawn and moved regions, absent on iOS **[S]**; Apple's WWDC22 session suggests sending only those regions and compositing on the receiver **[D]**. (a) *Classifier-lite (2–3 days):* dirty-area fraction and frequency select an encoder policy per moment (text/idle: quality first, refresh armed; scroll/video: frame-rate first), no new codec. (b) *Settled-region refresh (2–4 weeks):* after N ms with no dirty rect on a region, send it losslessly (LZ4 or PNG tiles) on a separate cancelable channel, composite on the phone only while the region's epoch is current. Precedents: Xpra's default lossless auto-refresh 0.25 s after a lossy update (3P doc); Chrome Remote Desktop's open-source VP9 wrapper uses `active_map` from the updated region, cyclic-refresh AQ, and a lossless/I444 mode **[S]**. Do (a) with R3; do (b) only if R3 is not enough.
**R14 (instrumentation).** See section 7.
**R15.** No: nothing in the data says the WebRTC transport itself is the bottleneck; the fixes above are inside it.

## 6. Verdict for 17 November: HEVC, tuned H.264, dirty-rect text layer, or full custom codec

| Option | Fit for 17 Nov | What the evidence says | Decision |
|---|---|---|---|
| **Tuned hardware H.264 over WebRTC (+ R1, R2, R3, R5, R6, R7, R8)** | Fits: about 2–4 developer-weeks total, mostly small; keeps browser compatibility | Attacks H1–H4, the measured causes. Encode cost is 5–14 ms and hardware; the bitstream is not what limits sharpness on LAN (0.65 Mb/s was actually used) | **Ship this** |
| **HEVC (native peer only)** | Not for launch | [M] Host is capable: default HEVC encode 7.4 ms at 2940×1912 (the fastest encoder measured), low-latency HEVC about 30% fewer bits at equal PSNR on desktop content (4.96 vs 7.03 Mb/s, +0.4 dB) and +4 dB at equal bitrate under full-motion at 2940×1912 (only +0.6 dB at 1920×1248); **but** bitrate is not the LAN bottleneck, M153 has no VT HEVC wrapper (F2), phone decode capability and thermals are unmeasured, RExt profiles are not standard WebRTC SDP, browsers stay on H.264 | **Post-launch branch.** Value shows up on cellular/relay (paid tier), not on LAN |
| **HEVC RExt 4:4:4 (sharp colored text)** | Not for launch | [M] Feasible on the Mac: HW encode 5.9 ms (1920×1248) to 7–10 ms (2940×1912), 102–130 fps ceiling, 8–20 Mb/s; hardware decode works on the Mac. **iPhone 17 hardware decode of RExt 4:4:4 is unverified** (one third-party PR confirms M4 Mac decode only) | **Probe now, decide later.** Run the decode probe on the phone in one hour (below) before spending on it |
| **Dirty-rect lossless UI layer** | (a) classifier: yes. (b) settled refresh: only if R3 fails | [B/C] Sound in principle (Xpra, CRD, RDP, LIQUID all use content-aware paths), but it is a second media stack with epochs, loss recovery and phone compositing; the measured defect (static text frozen at starved first-IDR quality) is fixable more cheaply | **(a) now with R3; (b) gated** |
| **Full custom tile codec + transport** | No | Nothing measured points at WebRTC transport as the limiter; Astropad itself falls back to standard codecs for motion; 12–24+ weeks and no browser path | **Not before evidence from R1–R9 fails on the phone** |

**Phone-side decode probe for 4:4:4 (do this once, on the iPhone 17):** encode a few `444v` frames on the Mac with `probes/vtfmt2` (writes SPS-verified RExt samples), ship the sample buffers to a tiny iOS test target, create `VTDecompressionSession` with `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder = true`, decode one frame and read `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`. If it fails or reports software, close the 4:4:4 question for this device generation.

**What would change this verdict:** if, after R1–R3 and R5–R6, the phone still shows p90 gaps above 50 ms with `qualityLimitation = none` and stable BWE, the limiter is Wi-Fi or capture (H5/H6), not the codec: fix those, do not reach for HEVC. If colored small text is still unreadable at 40 dB luma PSNR, 4:4:4 (or the R9 native-scale capture) is the next lever, and the R9 route is cheaper.

Contradictions and corrections to earlier repo statements: (1) the "LIQUID <16 ms" figure is a vendor claim that also cannot include a 60 Hz capture wait plus a display wait on this hardware **[E]**; (2) Apple's "up to 100 ms less delay at 720p30" for low-latency RC (WWDC21) compares against the default configuration, not against RealTime + no reordering, which we measured as equal in encode latency here; (3) the earlier note treats 4:4:4 as unproven; it is now proven feasible for the host encoder and Mac decoder **[M]** and still unknown for the phone; (4) "Main" plus low-latency RC in `HostStream.swift` contradicts the SDK header (High only).

## 7. What to measure and how

**Glass-to-glass (the number that matters).** Film the Mac screen and the iPhone side by side with a second iPhone in 240 fps slow motion (4.2 ms per frame), with `bench/stimulus.html` showing the millisecond clock on the Mac; latency is the difference between the clock digits visible on both screens, per frame, 100+ samples. `bench/analyze.py` works on 60 fps screen recordings and can only count distinct updates (16.7 ms quantisation, and iOS screen recording can itself drop frames); it cannot give latency. Use it for cadence only.

**In-app stage timeline (one frame ID end to end).** Anchor T0 at `SCStreamFrameInfoDisplayTime` (mach absolute time when the window server displayed the frame **[S]**), then: SCK callback, `pushFrame`, `RTCVideoFrame.timeStampNs`, encoder output (WebRTC `totalEncodeTime`), pacer exit (`totalPacketSendDelay`), receive/decode (`jitterBufferDelay/EmittedCount`, `totalDecodeTime`, `totalProcessingDelay`), and presentation (`MTLDrawable.addPresentedHandler` presented time). All of those stat keys are present in the M153 binary **[S]**. The RTP extensions `abs-capture-time` and `video-timing` are also compiled in and could carry the sender timeline. Sync the two clocks with a Cristian-style round trip over the data channel and report the offset uncertainty (do not compute frame age from RTT alone; PRODUCT.md already forbids that).

**Input latency.** `UITouch.timestamp` (seconds since boot **[D]**) → host inject time → first captured frame that contains the change; verify with the camera by making the stimulus flip colour on `pointerdown`.

**Per session log (already partly emitted):** target and available bitrate, sent kbps, `qualityLimitation`, encoder-dropped frames, key frames, PLI/NACK counts, jitter-buffer ms, render-gap p50/p90/max, thermal state, selected ICE pair, and a fixed-crop PSNR/SSIM of a text region (not `qpAverage`).

**Pass/fail suggestions (for the product owner).** On `bench/stimulus.html` on the LAN: at least 45 distinct updates/s median and 30 at p10, p90 gap under 50 ms, p95 input-to-photon under 100 ms (stretch) and under 150 ms (PRODUCT bar), text crop at least 40 dB luma PSNR after 300 ms idle, zero persistent stale regions, no sustained serious thermal state in 20 minutes.

**One-day diagnostic protocol** (settles H1–H6): (1) baseline 5-minute phone run with stream stats on; (2) same with R1; (3) R1+R2; (4) add Ethernet on the Mac (or awdl0 down); (5) camera glass-to-glass for each. Change one thing at a time; keep resolution, content, phone brightness and router constant.

## 8. Vendor claims versus measured facts

| Subject | Vendor / third-party statement | What we measured or can say |
|---|---|---|
| Astropad LIQUID | **[V]** "often under 16 ms" end to end on a local network; 64×64 or 128×128 independent tiles; UDP with "Velocity Control"; switches to a standard codec for video. Workbench 1.3: "30% faster" and content-aware text/image coding. No method, no numbers. | Not reproduced. **[E]** With a 60 Hz host panel, capture wait alone averages 8.3 ms; the claim only holds if latency is defined narrowly or the host runs at 120 Hz+. Workbench's own Vitals page shows HEVC and "Liquid" tile bandwidth separately, i.e. a mixed codec, **[V]**. |
| Parsec | **[V]** total pipeline 4–8 ms at 240 fps on gigabit LAN, camera-measured, 100 Mb/s cap; "no buffers of any kind on video"; bitrate is the congestion lever; BUD is UDP + DTLS. | Confirms the design direction (no receiver buffer, encoder bitrate as the control knob): our R1 and R2 are the WebRTC equivalents. The number is at 240 Hz with dedicated hardware, not comparable to a 60 Hz laptop panel. |
| Apple High Performance Screen Sharing | **[V]** 4:4:4, 30/60 fps, low latency, Apple silicon Mac-to-Mac, 75 Mb/s recommended for one 4K display. | Consistent with **[M]**: the Mac's hardware HEVC does 4:4:4. It says nothing about iPhone decode. |
| Microsoft RDP | **[V]/[D]** AVC 4:4:4 mode carries 4:4:4 over standard 4:2:0 hardware H.264 encoders/decoders "to avoid blurry text". | A viable trick with H.264 hardware on both ends (two 4:2:0 streams), at roughly double the pixels; not needed unless colored text stays unreadable after R3/R9. |
| Chrome Remote Desktop | **[S]** open-source VP9 wrapper: I444 profile for lossless-colour mode, `active_map` from damage rects, cyclic-refresh AQ, CBR. | Same pattern (damage-driven, quality convergence when static). |
| Xpra | **[3P]** lossless auto-refresh 0.25 s after lossy updates by default. | The pattern R3/R13b copies. |
| Moonlight/Sunshine | **[3P]** default FEC 20% of packets per frame; variable frame rate on static screens (about 10 fps); AWDL can add 3–90 ms swings; RFI moving to LTR. | FEC costs 20% bandwidth by default; on LAN prefer NACK/RTX, no FEC. |
| Jump Desktop Fluid | **[V]** 60 fps target, about 10 ms audio latency on a good connection, halving fps roughly halves bandwidth and CPU. | Not reproducible; no method. |
| Splashtop | **[V]** sustained 60 fps at 4K with hardware-accelerated encode/decode, options up to 240 fps, a 2026 "AI-optimized codec" that adapts to network and on-screen content, 37 fps on 4G and 60 fps on 5G in an NTT Docomo test. | Not reproduced; no per-stage numbers. Same theme: content-adaptive codec plus hardware video. |
| NoMachine | **[3P]** (its own knowledge base) hybrid: H.264 for video, JPEG for static images, X graphics primitives for text; hardware encode via NVENC on Windows/Linux; H.264 said to cut bandwidth and encode time 20–30%. | A protocol-level (not pixel-level) text path is unavailable on macOS screen capture; the transferable idea is per-content-type paths, which is R13. |
| Apple low-latency VT (WWDC21) | **[D]/[V]** up to 100 ms less delay for 720p30 vs default; H.264 only at the time. | Encode latency was **equal** to RealTime + no reorder here; benefit is rate-control efficiency **[M]**. HEVC low-latency now exists (`hevc.rtvc`). |

## 9. Overlap with the parallel agent

Already covered by it (do not duplicate): stage instrumentation, and H.264 low-latency tuning through a custom `RTCVideoEncoder` in `PocketDeskVideoEncoderFactory`. My additions to feed into that work: F1 (the stock binary does none of it), R4's measured caveats (no `PrioritizeEncodingSpeedOverQuality`, frame-drop-under-starvation semantics, High-only, rate-control efficiency rather than latency), R3 (refresh keyframe), R5 (pixel budget). Everything else in section 5 is beyond it: R1, R2, R6, R7, R8, R9, R10, R11, R13, and instrumentation extras in R14 (SCK `displayTime`, `totalPacketSendDelay`, presented time, camera method, AWDL/Ethernet A/B).

**Process warning:** a concurrent iOS-simulator test fan-out drove the Mac's load average to about 1,000, which invalidates any latency benchmark and can stall the host itself. Do not run latency or encode benchmarks while that suite is running; serialise them.

## 10. Experiments not completed (and exact commands)

Blocked by machine saturation; all are scripted in `probes/`.
1. **Repeat the WebRTC matrix three times at 1920×1248 and once at 2940×1912** (`probes/wrtcbench/matrix2.sh`, waits for load < 14): confirms R1/R2 effect sizes with medians.
2. **Refresh test** (`REFRESH_AT=9 BWE_LATE=12000000 SERIES=1`): does a keyframe after the BWE bump restore text PSNR (R3 route 2)?
3. **Keyframe pacing test** (same with `WebRTC-Video-Pacing=factor:2.5,max_delay:30ms`): R8 effect on the IDR spike.
4. **Passive capture probe** (`probes/sckprobe`): `SCStreamFrameInfoDisplayTime`-to-callback latency, complete-frame cadence and dirty-rect coverage on the real screen for `queueDepth` 3/8, `minimumFrameInterval` 1/60 vs zero, 1920 vs native, 420v vs BGRA (needs Screen Recording permission for the launching process and a quiet machine).
5. **iPhone probes:** presented-time histogram, hardware decode of RExt 4:4:4, decode time at 1920×1248 and 2560×1664, thermal state over 20 minutes.

## 11. Sources (all opened 28 September 2026)

Apple documentation and headers: [WWDC21 10158 Explore low-latency video encoding with VideoToolbox](https://developer.apple.com/videos/play/wwdc2021/10158/); [WWDC22 10155 Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/); [WWDC23 10136 What's new in ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/); [WWDC23 10004 Reduce network delays with L4S](https://developer.apple.com/videos/play/wwdc2023/10004/); [Optimizing iPhone and iPad apps to support ProMotion displays](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays); [CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink); [CAMetalLayer.maximumDrawableCount](https://developer.apple.com/documentation/quartzcore/cametallayer/maximumdrawablecount); [Getting high-fidelity input with coalesced touches](https://developer.apple.com/documentation/uikit/getting-high-fidelity-input-with-coalesced-touches); [UIEvent.predictedTouches(for:)](https://developer.apple.com/documentation/uikit/uievent/predictedtouches(for:)); [kCMSampleAttachmentKey_DisplayImmediately](https://developer.apple.com/documentation/coremedia/kcmsampleattachmentkey_displayimmediately); [kVTDecompressionPropertyKey_RealTime](https://developer.apple.com/documentation/videotoolbox/kvtdecompressionpropertykey_realtime); [Apple newsroom, iPhone 17](https://www.apple.com/newsroom/2025/09/apple-debuts-iphone-17/) and [iPhone 17 tech specs](https://support.apple.com/en-us/125089); [High Performance Screen Sharing](https://support.apple.com/en-tm/guide/mac-help/mchl1883115d/mac); local headers `SCStream.h`, `VTCompressionProperties.h`, `CAMetalLayer.h`, `CAMetalDisplayLink.h`, `MTKView.h` from Xcode 27.0 SDKs; [WWDC26 ScreenCaptureKit expansion (third-party summary)](https://www.macotakara.jp/news/entry-51358.html).

WebRTC: shipped `WebRTC.xcframework` 153.0.0 (binary inspection); [LiveKit webrtc-sdk m150_release](https://github.com/webrtc-sdk/webrtc) source (`timing.cc`, `frame_decode_timing.cc`, `video_send_stream_impl.cc`, `pacing_controller.cc`, `webrtc_video_engine.cc`, `encoder_stream_factory.cc`, `rtp_sender_video.cc`, `rtp_video_stream_receiver2.cc`, `RTCMTLVideoView.m`, H264/H265 ObjC codecs); [playout-delay extension README](https://webrtc.googlesource.com/src/+/refs/heads/main/docs/native-code/rtp-hdrext/playout-delay/README.md) (read from the mirror copy); [W3C Media Capture content hints](https://www.w3.org/TR/mst-content-hint/).

Competitors and third parties: [Splashtop 4K/5K low-latency press](https://www.techradar.com/news/splashtop-adds-low-latency-4k-and-5k-video-streaming-support) and [Splashtop AI-optimized codec](https://itbrief.news/story/splashtop-unveils-ai-powered-codec-for-4k-remote-work) (search summaries); [NoMachine H.264 knowledge base](https://kb.nomachine.com/AR04Q01022) (search summary); [Astropad LIQUID](https://astropad.com/blog/liquid/); [Workbench 1.3](https://astropad.com/blog/workbench-1-3/); [Workbench Vitals/connection support page](https://support.astropad.com/en/articles/13978237-connection-requirements-quality); [Parsec 240 fps latency post](https://parsec.app/blog/parsec-game-streaming-total-latency-at-240-frames-per-second-c0818cc0daa5); [Parsec BUD protocol](https://parsec.app/blog/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007); [Moonlight iOS VideoDecoderRenderer.m](https://github.com/moonlight-stream/moonlight-ios/blob/master/Limelight/Stream/VideoDecoderRenderer.m); [Moonlight FAQ](https://github.com/moonlight-stream/moonlight-docs/wiki/Frequently-Asked-Questions); [Sunshine configuration](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html); [moonlight-common-c issue 120 (RFI to LTR)](https://github.com/moonlight-stream/moonlight-common-c/issues/120); [Chromium remoting VP9 wrapper](https://github.com/chromium/chromium/blob/main/remoting/codec/webrtc_video_encoder_vpx.cc); [Xpra encodings](https://github.com/Xpra-org/xpra/blob/master/docs/Usage/Encodings.md) and [xpra(1) man page](https://man.archlinux.org/man/xpra.1.en) (the 0.25 s `auto-refresh-delay` default comes from the man page); [Microsoft RDP 10 AVC/H.264 improvements](https://techcommunity.microsoft.com/blog/microsoft-security-blog/remote-desktop-protocol-rdp-10-avch-264-improvements-in-windows-10-and-windows-s/249588) (search summary; page body was not retrievable); [Jump Desktop Fluid](https://support.jumpdesktop.com/hc/en-us/articles/216423983-General-Fluid-Remote-Desktop) (search summary); [AWDL latency, The Register on RIPE 91](https://www.theregister.com/2025/10/23/apple_airdrop_awdl_latency_research/); [iShareScreen HEVC 4:4:4 hardware-decode PR](https://github.com/madmalkav/iShareScreen/pull/15).

---

## Appendix A. VideoToolbox micro-benchmark **[M]**

Method: `probes/vtprobe` (main.swift). Synthetic desktop frames (13 pt Menlo code text in four colours, a scrolling right pane, a moving block, a blinking caret) rendered with CoreText, converted to NV12 video range once (24 distinct frames cycled); 240 frames submitted at a 60 fps pace; latency is submit→output callback; decode is a second VideoToolbox session on the same Mac (**not** an iPhone); PSNR compares decoded luma with the pre-encode NV12 every 6th frame ("text region" = left 55%). Two full runs agreed within about 0.5 ms on p50. Machine load average 5–28 during these runs. Hardware-required sessions succeeded for every configuration listed. "Full-motion" scrolls the whole frame.

**2940×1912, desktop content**

| Configuration (target 12 Mb/s unless noted) | Encode p50 / p95 ms | Mb/s at 60 fps | Inter / key avg bytes | Dropped | Luma PSNR avg (min) dB | Text region dB |
|---|---|---|---|---|---|---|
| H.264 High, RealTime, no LL, AverageBitRate + DataRateLimits (WebRTC-like) | 11.7–12.0 / 12.8–15.4 | 4.42 | 8,514 / 176,088 | 0 | 43.4 (32.5) | 42.4 |
| H.264 High, low-latency RC (+ PrioSpeed, which is unsupported) | 13.5–13.8 / 14.5–16.1 | 7.03 | 13,774 / 221,961 | 3 | 50.8 (34.9) | 50.2 |
| same, target 30 Mb/s | 13.6–13.7 / 14.5–15.4 | 7.06 | 13,140 / 387,134 | 0 | 52.7 (42.0) | 52.2 |
| same, target 5 Mb/s | 13.4–13.9 / 14.0–15.3 | 5.39 | 10,422 / 188,851 | 18 | 45.1 (32.8) | 44.9 |
| HEVC Main, low-latency RC | 14.3–14.5 / 15.4–17.0 | 4.96 | 9,463 / 215,803 | 3 | 51.2 (35.1) | 50.4 |
| HEVC Main, RealTime, no LL | 7.3–7.5 / 13.8–16.5 | 11.26 | 21,616 / 461,531 | 0 | 44.6 (37.4) | 45.3 |
| HEVC Main, low-latency RC, target 5 Mb/s | 14.3–14.9 / 16.8–17.3 | 4.60 | 8,777 / 184,997 | 22 | 48.7 (33.5) | 48.3 |
| HEVC RExt 4:4:4 (`444v`), RealTime, target 12 / 25 / 40 Mb/s | 7.3 / 9.6 / 7.5 | 11.76 / 15.47 / 19.82 | 22,405 / 30,004 / 39,074 | 0 | 43.9 / 47.2 / 50.5 | 44.8 / 48.1 / 51.7 (chroma 48.7 / 51.2 / 54.0) |
| Unpaced throughput | H.264 LL 79–85 fps; HEVC LL 74–77 fps; HEVC 4:4:4 102 fps | | | | | |

**2940×1912, full-motion scroll:** H.264 default 9.03 Mb/s, 36.1 dB; H.264 LL 12.57 Mb/s, 41.2 dB (4 dropped); LL at 30M 25.05 Mb/s, 51.9 dB; LL at 5M 6.05 Mb/s, 31.2 dB, **40 dropped (16.7%)**; HEVC LL 12.36 Mb/s, 45.3 dB; HEVC default 12.58 Mb/s, 34.8 dB; HEVC LL at 5M 35 dropped, 35.0 dB; 4:4:4 at 12M 12.72 Mb/s, 33.1 dB luma.

**1920×1248, desktop content:** encode p50 5.3–5.9 ms for every configuration (default H.264 5.4, LL H.264 5.3, HEVC LL 5.8, HEVC default 5.7, 4:4:4 5.9); default H.264 3.48 Mb/s, 46.1 dB; LL H.264 4.16 Mb/s, 51.2 dB; HEVC LL 3.58 Mb/s, 50.6 dB; HEVC default 4.50 Mb/s, 52.5 dB; 4:4:4 at 12M 4.97 Mb/s, 52.1 dB (chroma 52.9); at 25M 8.05 Mb/s, 58.9 dB. Unpaced: H.264 LL 186 fps, HEVC LL 169 fps, 4:4:4 130 fps.
**1920×1248, full-motion:** H.264 default 8.55 Mb/s, 38.9 dB; LL 12.01 Mb/s, 43.0 dB; LL 30M 29.43 Mb/s, 51.8 dB; LL 5M 5.08 Mb/s, 34.6 dB (4 dropped); HEVC LL 12.03 Mb/s, 43.6 dB; HEVC default 12.46 Mb/s, 45.2 dB.

CPU: every configuration used 2–9% of one core over the run (hardware path); Mac decode 0.6–1.4 ms at 1920×1248 and 1.2–2.5 ms at 2940×1912 for 4:2:0, 2.3 ms for 4:4:4 at 2940×1912.

Caveats: synthetic content, one machine, a shared machine, default rate control behaves non-monotonically with target (do not extrapolate the "underspends" finding to all content), and PSNR is not legibility.

## Appendix B. WebRTC loopback on the exact M153 binary **[M]**

Method: `probes/wrtcbench` compiles copies of the repo's `PeerMedia.swift`, `VideoCodecPolicy.swift`, `StreamStatistics.swift`, `NativeCodecCapability.swift` (with an env-driven scratch patch, `peermedia-scratch.patch`: BWE start, caps, degradation preference, forced-keyframe nudge) and links the stasel 153.0.0 macOS slice. Two in-process peers negotiate H.264 (`640c34`, level 5.2, VideoToolbox hardware); the host pushes 60 fps of 48 marker-tagged frames; a renderer on the receiver reads the 6-bit marker from the decoded frame, giving per-frame push→render-callback latency and text-region PSNR against the source. No network, no display, no phone. Field trials are applied with `RTCInitFieldTrialDictionary` before any other WebRTC call.

Quiet-window runs (load 5–10), 1920×1248, desktop content, 16 s, steady state after 5 s:

| Configuration | Sent / target kbps | QP (avg) | Jitter buffer ms | Push→render median / p90 / p99 / max ms | Text PSNR |
|---|---|---|---|---|---|
| Current PocketDesk defaults | 648–666 / 5,100–5,570 | 51 | 10.1–15.7 | 26.8 / 30.2 / 32.0 / 33.3 (another run: 24.2 / 26.7 / 28.4 / 29.6; a first run at higher load gave 45.8 / 57.5 / 74.8 / 134.8, showing how much load alone moves this number) | 22.6 dB |
| `ForcePlayoutDelay` + `ForceSendPlayoutDelay` 0/0 | 667 / 5,114 | 51 | 0.0 | **7.8 / 9.5 / 10.5 / 14.6** | 22.6 dB |
| BWE start 12 Mb/s | 1,655 / 12,000 | 40.1 | 23.5 | 39.9 / 46.8 / 113.7 / 159.6 | 36.5 dB |
| `Video-Pacing factor:2.5,max_delay:30ms` only | 665 / 5,392 | 51 | 13.4 | 22.1 / 27.0 / 29.5 / 92.0 | 22.6 dB |
| BWE 12M + playout 0/0 + pacing bound | 879 / 12,000 | 51 (median) | 0.0 | 14.3 / 27.3 / 41.6 / 157.7 | 34.1 dB |

The 2940×1912 runs (encode median 82 ms in the baseline, load average 35+) were perturbed by other work on the Mac and are **excluded**; qualitatively the same ordering appeared (BWE start improved QP 51→44.4 and text PSNR 25→33 dB, playout 0/0 dropped the jitter buffer to 0). Baseline overall frame delivery in the quiet runs was 59–60 fps with no drops, which is expected: the synthetic screen is cheap. The loopback cannot reproduce BWE ramp under real congestion, Wi-Fi jitter, or real screen complexity, and reflects the *quality* problem (H1) more than the *frame-rate* problem.

The repo's earlier receipts (`work/continuation/final-codec-benchmark.log`) agree in shape: `SetStartBitrate 300000`, `content_type: kScreenshare`, `frame_drop_enabled: 1`, target 12,000 kbps, max QP 51, jitter buffer 261.9 ms median at 2940×1912 (that run used random glyph noise as content, far more complex than mine).

## Appendix C. Other probes and how to run them

| Probe | Purpose | Result |
|---|---|---|
| `probes/vtprops` | Supported VT properties with and without low-latency RC | Low-latency selects `h264.rtvc` / `hevc.rtvc`; `PrioritizeEncodingSpeedOverQuality`, `Quality`, `SpatialAdaptiveQPLevel`, `ConstantQualityFactor` not listed in that mode; `EnableLTR`, `ReferenceBufferCount`, `BaseLayerFrameRateFraction`, `Min/MaxAllowedFrameQP` are; `MaxFrameDelayCount` is read-only in default mode |
| `probes/vtfmt2` | Emitted HEVC SPS for 4:2:0, 4:4:4, 4:2:2, 10-bit; hardware decode | RExt 4:4:4 (`chroma_format_idc = 3`) and 4:2:2 emitted in hardware; hardware decode on the Mac to `444v`/`444f`/`pf44`/`p422` |
| `probes/cgprobe` | `CGEvent` creation and post cost | `CGEvent(source: nil).location` p50 < 1 µs; `post(tap: .cghidEventTap)` of a same-location `mouseMoved` p50 7 µs, p99 731 µs (n = 2,000, loaded machine, Accessibility trusted) |
| `probes/jsonsize` | Encoded size of `ControlPacket` for a move | 169 B legacy, 215 B with `NativeInteraction`, 280 B for a click with token |
| `probes/sckprobe` | Passive SCK latency/cadence/dirty rects | Built, **not run** |

Every `probes/*/main.swift` is a single-file program except `jsonsize` (also needs the repo's `ControlProtocol.swift`, `NativeInteraction.swift`, `PointerLocation.swift`, `StreamQuality.swift`, plus its `shim.swift`) and `wrtcbench` (needs four repo files, below). Build (from the repo root, scratch output elsewhere):
`swiftc -O -swift-version 5 probes/vtprobe/main.swift -o /tmp/vtprobe -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework CoreText -framework CoreGraphics -framework AppKit`, then `/tmp/vtprobe 2940 1912 bench` (also `props`, `formats`, `bench444` with `PIXFMT=444v`; `FULLMOTION=1` for the scroll content).
WebRTC loopback: copy the four repo sources named above next to `probes/wrtcbench/main.swift`, apply `peermedia-scratch.patch` to the `PeerMedia.swift` copy, then `swiftc -O -swift-version 5 -F <…/WebRTC.xcframework/macos-x86_64_arm64> -framework WebRTC -Xlinker -rpath -Xlinker <same> *.swift -framework VideoToolbox -framework CoreVideo -framework CoreText -framework AppKit`; drive with `run1.sh LABEL W=1920 H=1248 SECONDS=16 BWE_START=12000000 'TRIALS=WebRTC-ForcePlayoutDelay=min_ms:0,max_ms:0;WebRTC-ForceSendPlayoutDelay=min_ms:0,max_ms:0'`. Run only on an otherwise idle Mac.
Binary inspection: `lipo -thin arm64 WebRTC -output x; nm -u x | grep -i 'kVT\|VTCompression'; strings -a x | grep -o 'WebRTC-[A-Za-z0-9_.-]*' | sort -u`.
