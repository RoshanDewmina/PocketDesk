# Offline codec A/B

This opt-in harness links Farside's production `OwnedVTEncoder` into the existing **RemoteCoreTests** target. It is not included in either app. It creates synthetic, non-sensitive desktop content; no capture permission, installed host, phone, signaling or relay session is needed. The batch-7 request authorizes measurements and a recommendation, **not changing the app default**.

Run from this worktree:

```sh
script/codec-ab.sh build
script/codec-ab.sh check
script/codec-ab.sh quality
# Request a quiet window after compiling; only the orchestrator grants it.
printf '%s\n' 'Offline H264/HEVC encoder and Mac decode timing, 15 minutes, no phone session' \
  > ~/Documents/Codex/2026-10-01/testing/QUIET-REQUEST-b7-codec
script/codec-ab.sh timing
```

The wrapper waits for PAUSE-BUILDS, PRIORITY-BUILD and other lanes' quiet windows, and checks gates again after acquiring `lockf -k /tmp/farside-xcodebuild.lock`. Timing also requires `QUIET-GRANTED-b7-codec`. It never removes another lane's flags. The grant/request owner removes its own quiet files after the timing process has exited. Do not delete the shared lock file. Build uses dedicated `/Volumes/Studio/Development/Caches/b7-codec/DD` and the pinned shared package cache.

`check` exercises metric assertions and confirms the expensive benchmark skips by default. `quality` and `timing` use `FARSIDE_CODEC_BENCH=1`, `FARSIDE_CODEC_MODE` and `FARSIDE_CODEC_OUT` automatically. Use `FARSIDE_CODEC_FRAMES` and `FARSIDE_CODEC_CASE` for a short diagnostic subset. Store each invocation in its own output directory; rerunning into an existing directory can overwrite receipts.

The full clip defaults to 240 frames (four one-second phases). Timing holds at most 240 NV12 frames, about 1.5 GB for the full desktop, per case. Its second repeat reverses case order. Rendering, hashing, scoring and PNG exports are outside timed callbacks; corpus generation still warms the Mac, so retain thermal/load evidence. The wrapper snapshots source before compilation, seals the test executable SHA-256 afterwards, and refuses measurements after source or executable changes. A filter or smaller frame count is diagnostic evidence, not the full matrix.

## Comparison contract

Both codecs receive the same deterministic clip, source-frame timestamps and rate. The display is 1280×828 points at 2× (2560×1656 pixels), matching the task's measured Big Text mode. Representative portrait and landscape zoom cases derive their crop/output dimensions through `ViewportCapturePolicy`. Text must retain its source pixel font size when cropped. Scenes cover a static editor with small punctuation and syntax colours, realistic scrolling with reversal, a moving video region, and a mixed desktop. Synthetic content is reproducible; it is not a representative sample of all Mac applications or natural camera footage.

Bitrate values come from `StreamQuality` in `StreamTuning.swift`: Sharper LAN start/floor 10 Mb/s and ceiling 25; Responsive LAN start/floor 6 and ceiling 12; internet P2P start 3 and relay start 2.5. These are **fixed-rate encoder points**, not a simulation of WebRTC congestion control, packet overhead, pacing, network loss or the adaptive ladder. Full-size low-bitrate cases deliberately expose overload; a live ladder may reduce size or rate.

The owned encoder supplies the shipped hardware-required VideoToolbox setup, QP ceiling, realtime setting, rate limits and keyframe policy. HEVC uses its production Main configuration. H.264 High 5.2 (`640034`) matches the historical measured native session in `IMPLEMENTATION-PLAN.md`; current negotiation may select a different profile, which this isolated harness cannot prove. Shipped High 5.2 uses VT low-latency rate control, while standard HEVC does not. Forcing both into identical low-latency settings would cease to compare the actual configuration.

Quality and timing are separate passes. Per-frame quality is compared to the **NV12 luma source actually fed to the encoder**, isolating codec error from RGB→NV12 transfer error. Video-range (16–235) and full-range (0–255) decoded luminance are normalized to the same domain before scoring; the actual format is recorded. This matters because the two shipped decoders can return different ranges. Text SSIM excludes low-variance windows, avoiding scores dominated by flat backgrounds. PNG crops additionally allow visual checking of coloured glyphs. Missing frames must remain visible in the report rather than improving averages by omission. PSNR/SSIM are fidelity proxies, not proof that a person can read every token. Timing records serial submit-to-callback cost, not capture-to-phone presentation latency or achieved live frame rate; the Mac's decoder cannot establish iPhone decode cost. Inspect per-run configuration evidence, drops, key bursts and ordering as well as averages.

Validate and generate the complete table after both passes:

```sh
python3 script/codec-ab-report.py \
  ~/Documents/Codex/2026-10-01/perf-push/b7-codec/quality/codec-quality.jsonl \
  ~/Documents/Codex/2026-10-01/perf-push/b7-codec/timing/codec-timing.jsonl \
  --output ~/Documents/Codex/2026-10-01/perf-push/b7-codec/RESULTS.md
```

The reporter requires every declared case/repeat to finish, both codecs per point, complete frame timelines, matching source hashes across modes/codecs/rates/repeats, and valid decode timestamps/dimensions. It rejects interrupted or one-codec receipts.

## Freshness and evidence

On 2 October 2026, local Xcode was 27.0/27A266a, macOS 27.0.1/26A434, pinned WebRTC 153.0.0. Live [Apple compression callback documentation](https://developer.apple.com/documentation/videotoolbox/vtcompressionsessionencodeframe(_:imagebuffer:presentationtimestamp:duration:frameproperties:infoflagsout:outputhandler:)) and [decompression callback documentation](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsessiondecodeframe(_:samplebuffer:flags:infoflagsout:outputhandler:)) describe callback completion and OS availability. [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes) were re-fetched; the focused VideoToolbox entries concern scaling/interpolation, which this harness does not introduce. Raw receipts are in the lane's `apple/` directory. Each run also writes a source/environment manifest and a test log.

Lane results, recommendation, review disposition and exact two-minute phone check live in `~/Documents/Codex/2026-10-01/perf-push/b7-codec/NOTES.md`. No result here authorizes a codec/default change or a device installation.
