# Performance continuation — 30 September 2026

User authorized completing the unfinished Claude Farside engineering. Isolated `codex/continue-perf` started at `40bceb7`; original Claude dirty worktrees remain untouched. Root owns this package.

Recovered camera verifier changes from `farside-perf-pack`: output width/height and exact known synthetic-delay regression. Recovered timing implementation and tests from `farside-perf-pack-timing`: bounded host capture/push/encoded record ring and phone RTP-offset join/decoder timing. Merged around existing silent-VideoToolbox-drop retirement and encoder cancellation, LAN ceiling kill switch and backlogged pointer coalescing/input-delay instrumentation. No SEI/bitstream modification; no off-main event posting or unordered input channel was added. LAN ceiling remains off by default.

Added defense against finite floating-point stage differences overflowing Int conversion; receiver rejects malformed parallel arrays before reconstruction. A new phone PeerMedia explicitly clears an absent timing log so a disabled timing configuration cannot bind the preceding phone session's log. Host creation does not clear an active phone log used by loopback fixtures.

Actual evidence: Python camera suite ran remotely on authorized PC WSL, with actual ffmpeg/ffprobe synthetic video: **11 tests, 0 failures, 0 skips**, 3.185 seconds. Known-delay fixture rendered 240fps/1920 frames,13 transitions; measured median43.3ms/p95 51.6ms. These are synthetic verifier results, never physical latency acceptance. Changed Swift files parse and whitespace diff check passed before commit. Project regenerated in this isolated worktree to include FrameTiming.swift/FrameTimingTests.swift.

**Pending:** full stable RemoteCoreTests build and scoped/perf tests; native host/phone compile; fresh independent GPT source review; integrated conflict resolution with the new quality pack (both touch StreamStatistics, PeerMedia and encoder counters). Existing loopback tests in FrameTimingTests require execution, not merely source presence. Physical capture/photons and installed-build behavior remain open. Shared project membership is parent-owned during integration.

Timing semantics: Mac display timestamp → decoded frame on phone using estimated clock offset, not photons-on-screen or touch-to-photon. False/no RTP match produces missing diagnostic values and does not affect video. Bounded status summaries add optional fields; old peer/protocol size compatibility must be checked in integration.
