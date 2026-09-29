# HEVC 4:2:0 feasibility spike

Worker W6, 29 Sep 2026, branch `perf-120fps` (base `5fdab5b`). Bounded spike: Debug- and switch-gated, no product code changed. Separate from the 4:4:4 work (G11). Evidence tags follow the lab notebook: **[M]** measured, **[S]** static inspection of the shipped binary, headers or source, **[E]** estimate.

**Why.** This morning's sessions put VideoToolbox H.264 at ≈ 13 ms per 2560×1656 frame on the M4 Air (LAB-NOTEBOOK §1), so 120 fps (8.3 ms per frame) at full phone pixels is out of reach with H.264 and one frame in flight. The fork's research puts HEVC standard mode at ≈ 1.8× H.264's throughput and HEVC low-latency mode at 0.5×.

**Later source preparation, 29 Sep 2026.** These probes remain experiments, not a production codec change.
Hands-on acceptance and hardware measurements are deferred. Neither probe was run for this preparation;
the installed .11 apps and the uninstalled .12 development candidate are separate artifacts.
Both test classes now require a Debug configuration and the exact `POCKETDESK_HEVC_PROBE=1` opt-in;
the phone class always skips on a simulator. Default and Release suites do no probe hardware work.
All callback waits have five-second deadlines. A timeout, encoder error/drop or decoder error/drop fails
the probe explicitly; incomplete rows must not be used as performance evidence. Throughput counts only
successful encoded sample or decoded-image callbacks, excluding the initial key frame. Attempted,
delivered, dropped and error counts are reported separately. Decode-output rate is not display
presentation rate, sustained playback, negotiated media flow or glass-to-glass latency.

Original scope evidence: Claude Code session `ec632039-cbe8-4dc5-acc9-9bd5d44783a1`, user message
`2026-09-29T13:41:04.579Z`, asks agents to finish display-refresh, phone-pixel-cap, viewport-capture and
quality-ladder performance work. Fork `1433a11f-eb91-4433-8035-0e86b5b1824a`, user messages
`2026-09-29T10:18:11.737Z` and `13:21:27.155Z`, prioritize performance and explicitly request
competitor/performance investigation on Apple silicon and large displays. W6's delegated initial
prompt in the `ec632039` subagent transcript `agent-a7b43c2748ef289af.jsonl` bounds this to two opt-in
probe files and this report, with no product codec edits until measured. The current implementation
ledger's hands-on deferral supersedes the earlier proposed immediate measurement schedule.

Current-main dependencies are `RemoteShared/LegibilityChart.swift` (`layout`, `cells`),
`RemoteShared/BenchRenderers.swift` (`LegibilityChartRenderer.draw`),
`RemoteShared/LegibilityScore.swift` (`score`, `cerBySize`) and
`RemoteShared/NativeCodecCapability.swift` (`systemAndModel`). Their APIs remain compatible with this
additive package. `project.yml` includes `RemoteTests/` and `RemotePhoneTests/` by directory;
the parent owns any generated project membership and compilation. Static review or compilation
does not invoke these test methods and cannot establish their pending hardware results.

## Answers at a glance

| # | Question | Answer | Evidence |
|---|---|---|---|
| 1 | Does our WebRTC build negotiate H.265? | **Yes, at the SDP level, without a custom build.** The C++ core of the stasel M153 binary has H.265 SDP parameters, RTP packetizer, depacketizer and bitstream parser. It ships **no** Objective-C H.265 encoder or decoder (no VideoToolbox wrapper, no `kRTCVideoCodecH265Name`), so we supply our own `RTCVideoEncoder`/`RTCVideoDecoder`. An app factory that lists `H265` gets it offered and answered; an old peer answers H.264. **Catch:** a sendrecv m-line (how `PeerMedia` adds the track today) drops H.265 unless the Mac's *decoder* factory lists it too; a sendonly transceiver offers it. | [S] headers, `nm`, `strings`; [M] offer/answer on the shipped macOS binary |
| 2 | M4 HEVC vs H.264 encode time per frame | **Pending: probe written, not run.** No build lock was granted, and at ≈ 11:30 EDT the Mac ran at load average 287 with another agent's `xcodebuild` holding the lock, so any number would have been contaminated. Prior probe (28 Sep, 2940×1912, paced 60 fps): HEVC standard p50 7.3–7.5 ms against H.264 11.7–12.0 ms (1.6×), HEVC low-latency 14.3–14.9 ms (0.5× of standard). | [M] prior, different harness; run §7 |
| 3 | iPhone 17 hardware decode time | **Pending (device).** Probe written; decode p50/p90 per codec at 2560×1656 and 2622×1206. | run §7 |
| 4 | Bitrate at equal legibility | **Pending (Mac run).** Probe written: bench chart seed 1449, 1–12 Mb/s, Vision CER, and the first bitrate per codec at which 11 pt reaches the target. Prior probe: HEVC low-latency needed ≈ 30 % fewer bits than H.264 low-latency for equal luma PSNR (4.96 against 7.03 Mb/s, +0.4 dB); PSNR is not legibility. | run §7 |
| 5 | Fallback and capability flag | Design in §5: `PocketDeskHEVC` (default off) on both apps, HEVC capability probes on both ends, `SessionFeature` `codec.hevc.1`, H.265 first in a sendonly offer with H.264 kept, an H.265 level budget, and a codec-agnostic encoder wrapper. | design |

## 1. Does the shipped WebRTC negotiate H.265?

Binary: `…/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework` (stasel `153.0.0`, `WebRTC-M153.xcframework.zip`, checksum `3e3a8946…` in the package's `Package.swift`).

**Headers [S].** Both slices have only H.264 codec classes:

```
$ ls macos-x86_64_arm64/WebRTC.framework/Headers | grep -i 'h265\|hevc\|codec'
RTCCodecSpecificInfo.h
RTCCodecSpecificInfoH264.h
RTCRtpCodecCapability.h
RTCRtpCodecParameters.h
RTCVideoCodecInfo.h
$ grep -rln -i 'h265\|hevc' macos-x86_64_arm64/WebRTC.framework/Headers ios-arm64/WebRTC.framework/Headers
(no output, exit 1)
```

The codec-name constants are `kRTCVideoCodecH264Name` (`RTCH264ProfileLevelId.h`) and, on iOS, `kRTCVideoCodecVp8Name`, `Vp9Name`, `Av1Name` (`RTCVideoCodecConstants.h`). There is no `kRTCVideoCodecH265Name`.

**Exported symbols [S].**

```
$ nm -gU macos-…/WebRTC.framework/Versions/Current/WebRTC | grep -ci 'h265\|hevc'
0
$ nm -gU ios-arm64/WebRTC.framework/WebRTC | grep -ci 'h265\|hevc'
0
$ nm -gU …/WebRTC | grep '_OBJC_CLASS_$_RTCVideo\(En\|De\)coder'     (same on both slices)
RTCVideoDecoderAV1  RTCVideoDecoderFactoryH264  RTCVideoDecoderH264  RTCVideoDecoderVP8  RTCVideoDecoderVP9
RTCVideoEncoderAV1  RTCVideoEncoderCodecSupport  RTCVideoEncoderFactoryH264  RTCVideoEncoderH264
RTCVideoEncoderQpThresholds  RTCVideoEncoderSettings  RTCVideoEncoderVP8  RTCVideoEncoderVP9
```

**Internal strings [S].** The C++ H.265 path is compiled into both slices (identical lists):

```
$ strings -a …/WebRTC | grep -i 'h265\|hevc' | sort -u
../../src/common_video/h265/h265_bitstream_parser.cc
../../src/common_video/h265/h265_pps_parser.cc
../../src/common_video/h265/h265_sps_parser.cc
../../src/modules/rtp_rtcp/source/rtp_packetizer_h265.cc
../../src/modules/rtp_rtcp/source/video_rtp_depacketizer_h265.cc
Empty slice in H265 bitstream.   Encoded.Qp.H265 (.S0 .S1 .S2)   H265   h265
Unable to parse PPS/SPS/VPS from H265 bitstream.   WebRTC-H265-QualityScaling
payload_capacity >= kH265PayloadHeaderSizeBytes
$ strings -a macos-…/WebRTC | grep -i 'level-id\|profile-id\|tier-flag\|tx-mode' | sort -u
level-id  profile-id  tier-flag  tx-mode   (H.265 fmtp keys; plus H.264/AV1 keys)
```

This matches the package's build script, which enables H.265 for every slice:

```
$ grep COMMON_GN_ARGS SourcePackages/checkouts/WebRTC/scripts/build.sh
COMMON_GN_ARGS="is_debug=${DEBUG} rtc_libvpx_build_vp9=true … rtc_system_openh264=true rtc_use_h265=true"
```

**Default factories [M].** Loading the macOS slice with `/usr/bin/python3` + `ctypes` and asking the Objective-C runtime (no compile; scratchpad script `codecs.py`):

```
RTCDefaultVideoEncoderFactory supportedCodecs:
    H264 {level-asymmetry-allowed=1; packetization-mode=1; profile-level-id=640c1f}
    H264 {level-asymmetry-allowed=1; packetization-mode=1; profile-level-id=42e01f}
    VP8 {}   VP9 {profile-id=0}   VP9 {profile-id=2}   AV1 {level-idx=5; profile=0; tier=0}
RTCDefaultVideoDecoderFactory supportedCodecs: the same plus VP9 profile-id 1 and 3
RTCVideoEncoderH265 / RTCVideoDecoderH265 / RTCCodecSpecificInfoH265 / RTCH265ProfileLevelId class present: False
```

So no stock factory ever lists H.265; today's `PocketDeskVideoEncoderFactory` and `PocketDeskVideoDecoderFactory` (fallback `RTCDefault*Factory`, `VideoCodecPolicy.swift`) never offer it.

**An app factory that lists H.265 [M].** Same harness, with Objective-C factory classes created at runtime that return `[H265 {profile-id=1; tier-flag=0; level-id=156; tx-mode=SRST}, H264 {… 640c34}]` (scratchpad `h265factory.py`, `h265offer.py`, `h265offer2.py`):

```
factory advertising [H265, H264] -> sender capabilities:  H265 {level-id=156; profile-id=1; tier-flag=0; tx-mode=SRST}, rtx, H264 {…640c34}, red, ulpfec

OFFER from H265+H264 factory (sendrecv, encoder and decoder factory both list H265):
    m=video 9 UDP/TLS/RTP/SAVPF 35 36 96 97 100 101 102
    a=rtpmap:35 H265/90000
    a=fmtp:35 level-id=156;profile-id=1;tier-flag=0;tx-mode=SRST
    a=rtpmap:96 H264/90000
    a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c34
ANSWER from legacy (RTCDefault*Factory, no H265):
    m=video 9 UDP/TLS/RTP/SAVPF 96 97 100 101 102
    a=rtpmap:96 H264/90000
    a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c1f
ANSWER from H265-capable:
    m=video 9 UDP/TLS/RTP/SAVPF 35 36 96 97 100 101 102
    a=rtpmap:35 H265/90000
    a=fmtp:35 level-id=156;profile-id=1;tier-flag=0;tx-mode=SRST

OFFER, encoder factory [H265, H264], decoder factory RTCDefault (no H265), sendrecv
    m=video 9 UDP/TLS/RTP/SAVPF 96 97 108 109 114          ← H265 dropped
OFFER, same factories, sendonly transceiver
    m=video 9 UDP/TLS/RTP/SAVPF 127 125 96 97 108 109 114
    a=sendonly
    a=rtpmap:127 H265/90000
  ANSWER from H265-capable peer: m=video 9 UDP/TLS/RTP/SAVPF 127 125 96 97 108 109 114, a=recvonly, H265 first
```

**Verdict.** H.265 is negotiable with this binary. The offer order follows the factory order, an H.265-capable answerer keeps H.265 first, and a peer without H.265 answers H.264 alone, so old phones fall back by construction. What is **not** proven: media flow. From upstream source (not re-read for this build, so treat as [S] to confirm): the RTP packetizer is chosen from the negotiated payload name, while the Objective-C encoder bridge converts only `RTCCodecSpecificInfoH264` into native codec info, so our frames would travel as a generic `CodecSpecificInfo` under an H.265 payload type; and the receiving `H26xPacketBuffer` needs VPS, SPS and PPS in band before an IDR to treat it as a key frame. Both are exercised only by a loopback test (§5.7). The iOS slice was checked statically only (same strings, same classes, same build flags); the offer/answer run used the macOS slice.

**If a custom build were ever needed (research only, not recommended).** `rtc_use_h265=true` is already set, so the C++ side needs nothing. A custom build would only add Objective-C conveniences: `RTCCodecSpecificInfoH265` (so frames carry `kVideoCodecH265` instead of generic info) and VideoToolbox `RTCVideoEncoderH265`/`RTCVideoDecoderH265`, which the LiveKit / webrtc-sdk forks add to the `videotoolbox_objc` target and the `framework_objc`/`mac_framework_objc` headers. That means maintaining a fork of stasel's `scripts/build.sh` output (≈ hours of build per release, two slices plus catalyst, re-signing and re-hosting the xcframework) for something app-side Swift classes can do.

## 2. M4 encode time per frame, H.264 against HEVC

**Probe.** `RemoteTests/HEVCProbeTests.swift` (opt-in with `POCKETDESK_HEVC_PROBE=1`). VTCompressionSession per codec with `RequireHardwareAcceleratedVideoEncoder`, `RealTime`, `AllowFrameReordering = false`, H.264 High / HEVC Main (AutoLevel), `ExpectedFrameRate` 60 and 120, `AverageBitRate` 12 and 25 Mb/s (no `DataRateLimits`), `MaxKeyFrameInterval` 7200 / 240 s as libwebrtc sets. Frames: a two-pane editor page (Menlo 22 px, keyword, string and comment colours, a selection band every 11 lines) rendered once with CoreGraphics, converted to NV12 (BT.709) with `VTPixelTransferSession`, scrolled 12 px per frame by row copies into a ring of six buffers so rendering stays out of the timing. 120 frames, frame 0 a forced IDR reported on its own, p50/p90/max over frames 1–119, submit → output-handler latency, unpaced (the next frame goes in as soon as a slot frees). One frame in flight is VideoToolbox's service time; three in flight gives queueing latency and the throughput ceiling (`enc fps`). Each row also prints the encoder ID (e.g. `ave.hevc`), `UsingHardwareAcceleratedVideoEncoder`, rejected properties, and mean P-frame and IDR size. The header line records load average, thermal state, low-power mode and the machine model.

| Codec | Size | fps | Mb/s | 1 in flight p50 / p90 ms | 3 in flight p50 / p90 ms | enc fps (3 in flight) | P KB / IDR KB |
|---|---|---|---|---|---|---|---|
| H.264 | 2560×1656 | 60 / 120 | 12 / 25 | pending | pending | pending | pending |
| HEVC | 2560×1656 | 60 / 120 | 12 / 25 | pending | pending | pending | pending |
| H.264 | 2560×1440 | 60 / 120 | 12 / 25 | pending | pending | pending | pending |
| HEVC | 2560×1440 | 60 / 120 | 12 / 25 | pending | pending | pending | pending |
| H.264 | 2622×1206 | 60 / 120 | 12 / 25 | pending | pending | pending | pending |
| HEVC | 2622×1206 | 60 / 120 | 12 / 25 | pending | pending | pending | pending |
| HEVC low-latency RC | 2560×1656 | 120 | 12 | pending | pending | pending | pending |

(The probe prints one row per fps × bitrate; collapse here once measured.) `testHEVCLowLatencyModeOnce` runs standard HEVC, low-latency HEVC with one in flight and with three, back to back under the same thermal state. Low-latency sessions first try with hardware required and fall back to "enable" only, flagged `hw not required` (the round-2 research found low-latency sessions select `hevc.rtvc` and do not report hardware).

**Prior evidence [M], for orientation only** (`Docs/research/2026-09-28-round2/PERFORMANCE-PLAYBOOK.md`, Appendix A: 2940×1912, synthetic desktop, 240 frames *paced at 60 fps*, load 5–28): H.264 default 11.7–12.0 ms p50, HEVC Main RealTime no-LL 7.3–7.5 ms, HEVC low-latency 14.3–14.9 ms, H.264 low-latency 13.5–13.8 ms; at 1920×1248 every configuration sat at 5.3–5.9 ms (the pacing floor). IDR at 12 Mb/s: H.264 176 KB, HEVC default 462 KB (HEVC's default rate control spent 11.3 Mb/s where H.264 spent 4.4).

**Estimate [E].** If HEVC's service time scales with pixels from 7.4 ms at 5.6 MP, it is ≈ 5.6 ms at 2560×1656 (4.2 MP) and ≈ 4.2 ms at 2622×1206 (3.2 MP): inside 8.3 ms with one frame in flight, which H.264 (≈ 13 ms in the app at 4.2 MP) is not. The probe replaces this line.

## 3. iPhone 17 hardware decode

**Probe.** `RemotePhoneTests/HEVCDecodeProbeTests.swift`, skipped on the simulator (`XCTSkip`) and without `POCKETDESK_HEVC_PROBE=1`. The phone's own hardware encoder produces 120 scrolling code frames per codec (120 fps, 25 Mb/s, one in flight); a decoder with `RequireHardwareAcceleratedVideoDecoder`, NV12 full range and IOSurface output and asynchronous decode (as libwebrtc's `RTCVideoDecoderH264` configures it) decodes them one in flight. It prints `VTIsHardwareDecodeSupported` for both codecs, the device model, thermal state, encode p50/p90, decode p50/p90/max, decode fps, frame sizes and `UsingHardwareAcceleratedVideoDecoder`.

| Codec | Size | Encode p50 / p90 ms | Decode p50 / p90 / max ms | Decode fps | HW decoder |
|---|---|---|---|---|---|
| H.264 | 2560×1656 | pending (device) | pending (device) | pending | pending |
| HEVC | 2560×1656 | pending (device) | pending (device) | pending | pending |
| H.264 | 2622×1206 | pending (device) | pending (device) | pending | pending |
| HEVC | 2622×1206 | pending (device) | pending (device) | pending | pending |

Reference: in-session phone decode was 7 ms for H.264 at 2560×1656 (LAB-NOTEBOOK §0), which includes WebRTC's path.

## 4. Bitrate at equal legibility

**Probe.** `HEVCProbeTests.testLegibilityPerBitrate`. The session geometry: a 1920×1242 pt display at 4/3 px per pt, streamed at 2560×1656, with the code page behind a white panel holding the bench chart (`LegibilityChartRenderer`, seed 1449 as in session 1). For each codec at 1, 2, 4, 8 and 12 Mb/s (4/8/12 as requested, 1 and 2 because a static page may already be legible at 4), 30 static frames at 60 fps, the last one decoded with `VTDecompressionSession` to BGRA and scored with `LegibilityScore` on the chart crop; the table also prints RGB PSNR over the chart and IDR / mean P size. Two ceilings are scored first: the RGB render and the unencoded 4:2:0 frame (chroma subsampling alone).

**Target.** The 60 fps sessions logged no on-stream 11 pt CER (LAB-NOTEBOOK §1: "Legibility. Not scored this session"); the only recorded figure is the pristine Vision ceiling (11 pt 7.8 % at 2× for 1440×932 pt, §0a). The probe therefore uses the unencoded 4:2:0 frame's 11 pt CER plus one character (1.6 %: one of the 64 characters in the eight 11 pt cells) and reports, per codec, the first bitrate whose 11 pt CER is at or under it. `POCKETDESK_HEVC_TARGET_CER11=<percent>` substitutes the session figure once one exists.

| Codec | Mb/s | 9 pt | 11 pt | 13 pt | 15 pt | coloured 11 pt | chart PSNR | reaches target |
|---|---|---|---|---|---|---|---|---|
| RGB / 4:2:0 ceilings | – | pending | pending | pending | pending | pending | pending | – |
| H.264 | 1 / 2 / 4 / 8 / 12 | pending | pending | pending | pending | pending | pending | pending |
| HEVC | 1 / 2 / 4 / 8 / 12 | pending | pending | pending | pending | pending | pending | pending |

Limits: a static page shows converged quality, the best case; motion legibility needs the on-stream scorer.

## 5. Design: HEVC behind a capability flag, H.264 as the fallback

### 5.1 Switch

`StreamTuning.hevc` (`PocketDeskHEVC`, **default off**), read on both apps like the other experiment keys and added to `experimentKeys` and `summary` ("hevc"). Off means byte-identical SDP and behaviour to today. On is necessary but not sufficient: each side still needs its capability probe to pass.

### 5.2 Capability probes (both ends, cached like the level-5.2 probe)

- **Phone (decode).** `NativeCodecCapability.supportsHEVCDecode`: false on the simulator; false unless `VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)`; then a one-frame decode of an embedded HEVC Main IDR at the level we will advertise (2560×1664, level 5.1, VPS/SPS/PPS + IDR generated once on the Mac with VideoToolbox and baked in like the H.264 fixture) through `CMVideoFormatDescriptionCreateFromHEVCParameterSets` with `RequireHardwareAcceleratedVideoDecoder`, checking `UsingHardwareAcceleratedVideoDecoder`. Positive results cached per OS and model under a new `PocketDeskHEVCProbe.<os>.<model>` key, warmed at launch with the same timeout rules.
- **Mac (encode).** `NativeCodecCapability.supportsHEVCEncode`: `VTCopySupportedPropertyDictionaryForEncoder(width: 2560, height: 1656, codecType: kCMVideoCodecType_HEVC, encoderSpecification: [RequireHardwareAcceleratedVideoEncoder: true], …) == noErr` and `kVTProfileLevel_HEVC_Main_AutoLevel` among the supported `ProfileLevel` values. The encoder ID is logged for diagnostics.
- **Level/profile.** Main (`profile-id=1`), Main tier (`tier-flag=0`), `tx-mode=SRST`, `level-id=153` (5.1). Level 5.1 allows 8,912,896 luma samples per picture and 534,773,760 per second: 2560×1656 at 120 (508.7 M/s), 2560×1440 at 120 (442.4 M/s), 2622×1206 at 120 (379.5 M/s) and 3840×2160 at 60 (497.7 M/s) all fit, and its 40 Mb/s Main-tier bitrate cap covers the 25 Mb/s ceiling. Advertise 156 (5.2) only if a 4K120 probe is added. 4:4:4 (RExt, `profile-id=4`) stays with G11.

### 5.3 Session feature

`SessionFeature.hevc = "codec.hevc.1"`, added to `SessionFeature.host` and filtered out in `HostModel.advertisedFeatures` unless `StreamTuning.current.hevc && NativeCodecCapability.supportsHEVCEncode`, the same way `capture.viewport.1` and `ladder.1` are dropped when their switches are off (the list becomes 11 of the 16 the validator allows). Meaning: "this Mac offers H.265 first and sends it when the answer accepts it". SDP alone decides the codec; the feature exists so the phone can label the instruments line ("HEVC offered / negotiated / declined: no decode probe") and so a later mid-session codec switch (§5.6) is only requested from hosts that understand it. `sendCaptureHealth` returns early until `connection.connected`, so features arrive after negotiation; they cannot gate the first answer and do not need to.

### 5.4 Offer and answer

- Mac encoder factory: `[H265 (5.2 above)] + H264LevelPolicy.codecs(…)` when the switch and encode probe allow; otherwise unchanged. H.264 stays in every offer, so an old phone answers H.264 (measured in §1).
- Mac transceiver: **sendonly** when the switch is on (`addTransceiver(with: track, init:)` with `direction = .sendOnly`, `streamIds = ["desktop"]`), because a sendrecv m-line carries only codecs both factories list and H.265 vanished from it in §1. The phone already answers recvonly. The alternative, listing H.265 in the Mac's decoder factory, advertises a receive path the Mac never uses.
- Phone decoder factory: `H265` first when the switch and decode probe allow. A phone with the switch off or the probe failed answers H.264 only.
- Budget: `H264FrameBudget.receivingLimit(sdp:)` returns nil when the first answered payload is not H.264, which would leave the capture unfitted. Replace with a `VideoFrameBudget` that reads either codec: H.265 `level-id` → MaxLumaPs / MaxLumaSr (4.1: 2,228,224 / 133,693,440; 5: 8,912,896 / 267,386,880; 5.1: 8,912,896 / 534,773,760; 5.2: 8,912,896 / 1,069,547,520; 6: 35,651,584 / 1,069,547,520), fitted with the same shrink loop as H.264's macroblock budget.

### 5.5 Encoder and decoder

- **`DesktopVideoEncoder`** (today's `DesktopH264Encoder`, made codec-agnostic): its policy (`EncoderRestartPolicy`), trace (`EncoderLatencyTrace`), newest-frame-wins gate and counters already are codec-neutral; only `inner: RTCVideoEncoderH264` is not. Change `inner` to `any RTCVideoEncoder`, add `init(inner:)`, keep `init(codecInfo:)` for H.264 and a `typealias DesktopH264Encoder` for existing callers and tests. Contract for any inner encoder: set `captureTimeMs = frame.timeStampNs / 1_000_000` (the trace matches completions on it and otherwise falls back to the oldest submission), carry `frame.timeStamp` as the RTP timestamp, survive `releaseEncoder()` followed by `startEncode` (the restart path) and keep its callback across it. Trace lines and `encoderSessionStarted` gain the codec name so the per-second stats say which encoder produced `VT lat`.
- **`VideoToolboxHEVCEncoder: RTCVideoEncoder`** (new, Swift): VTCompressionSession HEVC Main AutoLevel with the probe's settings, `ExpectedFrameRate` from `settings.maxFramerate`, `AverageBitRate` from `setBitrate`, optional `DataRateLimits` like the H.264 wrapper, key frame on request; input `RTCCVPixelBuffer` (ScreenCaptureKit NV12). Output: length-prefixed HVCC → Annex B, with VPS/SPS/PPS (`CMVideoFormatDescriptionGetHEVCParameterSetAtIndex`) prepended on every IDR; `RTCEncodedImage` with `contentType = .screenshare`, `frameType`, sizes, timestamps; codec-specific info an empty `NSObject` conforming to `RTCCodecSpecificInfo` (the bridge maps it to generic info). `scalingSettings` nil (QP scaling stays off, as for screenshare today).
- **`VideoToolboxHEVCDecoder: RTCVideoDecoder`** (new, Swift, phone): split Annex B; on VPS(32)/SPS(33)/PPS(34) rebuild the format description and the session when it changes; length-prefix the slice NALs into a `CMSampleBuffer`; decode async to NV12 full range with IOSurface; deliver `RTCVideoFrame(buffer: RTCCVPixelBuffer(…), rotation:, timeStampNs:)` with the RTP `timeStamp`; return an error when a delta frame arrives without parameter sets so WebRTC requests a key frame.

### 5.6 Fallback behaviour

| Situation | Result |
|---|---|
| Old phone (no H.265 in its decoder factory) | Answers H.264; Mac sends H.264. Measured in §1. |
| New phone, switch off or decode probe failed | Same as old phone. |
| Mac switch off or encode probe failed | No H.265 in the offer; transceiver stays sendrecv; identical to today. |
| Browser peers | Unchanged: `compatibleFactory` is H.264-only. |
| H.265 negotiated, decoder errors or thermal trouble mid-session (phase 2) | Phone sends a `codec` session action (`h264`), gated by `codec.hevc.1`; Mac calls `setCodecPreferences` with H.264 first and renegotiates through the existing host `offer()` path (no ICE restart). Until then, the phone's recovery is a reconnect, which renegotiates with the same preference; so the switch stays off outside Debug until phase 2 exists. |

### 5.7 Proposed code changes (none made in this spike)

| File | Symbol | What |
|---|---|---|
| `RemoteShared/StreamTuning.swift` | `StreamTuning.hevc`, `hevcKey = "PocketDeskHEVC"` | Default off; resolve, `experimentKeys`, `summary`. |
| `RemoteShared/NativeCodecCapability.swift` | `supportsHEVCDecode`, `supportsHEVCEncode`, HEVC fixture, outcomes | §5.2; separate cache key; warm-up alongside the level-5.2 probe. |
| `RemoteShared/VideoCodecPolicy.swift` | `H265Policy` (name `"H265"`, info with the §5.2 fmtp) | No `kRTCVideoCodecH265Name` in this binary, so the literal lives here. |
| same | `PocketDeskVideoEncoderFactory.supportedCodecs/createEncoder` | Prepend H.265 when allowed; `"H265"` → `DesktopVideoEncoder(inner: VideoToolboxHEVCEncoder(…))`. |
| same | `PocketDeskVideoDecoderFactory.supportedCodecs/createDecoder` | Phone: prepend H.265 when allowed; `"H265"` → `VideoToolboxHEVCDecoder()`. |
| same | `H264FrameBudget.receivingLimit(sdp:)` → `VideoFrameBudget` | Read H.264 `profile-level-id` or H.265 `level-id` of the first answered payload; H.265 level table and fit (§5.4). |
| `RemoteShared/DesktopH264Encoder.swift` | `DesktopH264Encoder` → `DesktopVideoEncoder` | `inner: any RTCVideoEncoder`, `init(inner:)`, typealias, codec name in trace and counters (§5.5). |
| `RemoteShared/VideoToolboxHEVCEncoder.swift` (new) | `VideoToolboxHEVCEncoder` | §5.5. |
| `RemoteShared/VideoToolboxHEVCDecoder.swift` (new) | `VideoToolboxHEVCDecoder` | §5.5. |
| `RemoteShared/PeerMedia.swift` | `init` (host track), `receive(_:)` | Sendonly transceiver when `tuning.hevc`; `VideoFrameBudget.receivingLimit`; `nativeCaptureBudget` type. |
| `RemoteShared/SessionContinuity.swift` | `SessionFeature.hevc`, `SessionFeature.host` | `"codec.hevc.1"` added to the list (§5.3). |
| `RemoteHost/HostModel.swift` | `advertisedFeatures` | Drop `codec.hevc.1` unless the switch is on and the encode probe passed. |
| `RemoteShared/StreamStatistics.swift` | `h264ProfileLevel` | Also parse H.265 `level-id` so the instruments show `H265 L5.1`; `codec` already carries `mimeType`. |
| `RemotePhone/RemotePhoneApp.swift` | `hevcSupported` | `hostFeatures.contains(SessionFeature.hevc)`, instruments label only. |
| `RemoteTests/VideoCodecPolicyTests.swift` | new cases | H.265 info fmtp; factory order with switch on/off; `receivingLimit` on the §1 SDP lines. |
| `RemoteTests/StreamLoopbackBenchmarkTests.swift` | HEVC variant | Loopback on the Mac with both new classes: proves packetization with generic codec info, key-frame detection with in-band VPS/SPS/PPS, and the restart path. **Gate before any device session.** |

## 6. Open questions and risks

1. **Media flow is unproven** (§1 verdict): generic `CodecSpecificInfo` with an H.265 payload, and `H26xPacketBuffer`'s key-frame rule. The loopback variant in §5.7 answers both on the Mac in one run.
2. **HEVC default rate control overspends on text** in the prior probe (11.3 Mb/s and a 462 KB IDR at a 12 Mb/s target where H.264 spent 4.4 Mb/s); with libwebrtc's pacer and the G9 key-frame budget, IDR size matters more than average rate. The §2 probe prints IDR and P sizes; if HEVC IDRs stay 2–3× H.264's, add `DataRateLimits` as the H.264 wrapper does and re-measure.
3. **Phone decode and thermals at 120 fps** are unknown until §3 runs; a 5-minute soak belongs in the first device session.
4. **Level asymmetry.** WebRTC M153 negotiates H.265 `level-id` per direction; confirm the answer's `level-id` is what the Mac reads for the budget once the phone advertises 153 against a Mac offer of 153/156.
5. **Offer direction change.** Sendonly with the switch on changes the host m-line for every peer that session; old phones already answer recvonly, but the E2E stub host and browser fixture should be run once with the switch on.
6. **Codec step in the ladder** (LAB-NOTEBOOK queue row 16) needs mid-session renegotiation (§5.6 phase 2); the first HEVC release chooses the codec at session start only.

## 7. Running the probes

Record conditions first (power, load average, network, no builds, simulators or browsers; iPhone Mirroring closed). Both probes print their own conditions line.

Mac (runtime remains unmeasured; every result line is prefixed `HEVC PROBE`). Run only after explicitly
resuming the quiet-machine experiment. Preserve the complete log and check the pipeline exit code:

```
cd ~/Developer/PocketDesk   # or this worktree
set -o pipefail
TEST_RUNNER_POCKETDESK_HEVC_PROBE=1 /usr/bin/lockf -k /tmp/farside-xcodebuild.lock xcodebuild test \
  -project PocketDesktop.xcodeproj -scheme RemoteCoreTests -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /Volumes/Studio/Development/Caches/Xcode/DerivedData/FarsideHEVCProbe \
  -only-testing:RemoteCoreTests/HEVCProbeTests 2>&1 | tee work/hevc-mac-probe.log
```

Single parts: `-only-testing:RemoteCoreTests/HEVCProbeTests/testEncodeLatencyOneFrameInFlight` (…`ThreeFramesInFlight`, `testHEVCLowLatencyModeOnce`, `testLegibilityPerBitrate`). Add `TEST_RUNNER_POCKETDESK_HEVC_TARGET_CER11=<percent>` to use a session's 11 pt CER as the target.

iPhone 17: this installs the Debug test host on the phone and requires coordinated human resumption
of hands-on work first. Run it from the integrated main checkout per AGENTS.md, with the parent
assigning the next `CURRENT_PROJECT_VERSION`. Never run this command as part of source preparation:

```
set -o pipefail
TEST_RUNNER_POCKETDESK_HEVC_PROBE=1 /usr/bin/lockf -k /tmp/farside-xcodebuild.lock xcodebuild test \
  -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -configuration Debug \
  -destination 'id=00008150-0001653C26F8401C' \
  -derivedDataPath /Volumes/Studio/Development/Caches/Xcode/DerivedData/FarsideHEVCDeviceProbe \
  CODE_SIGNING_ALLOWED=YES CURRENT_PROJECT_VERSION=<next> \
  -only-testing:RemotePhoneTests/HEVCDecodeProbeTests 2>&1 | tee work/hevc-phone-probe.log
```

Without a Debug configuration and `POCKETDESK_HEVC_PROBE=1` both classes skip; the phone class also
skips on all simulators. Keep these flags absent during ordinary tests and build-readiness checks.
