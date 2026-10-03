# B12: bounded encoder pipelining

3 October 2026, base `136361c`, lane `claude/b12-encoder-throughput`.

The .7 test build enables `FarsideEncoderPipelining` by default. The owned VideoToolbox encoder admits at most two frames, drops excess delta frames, and retires the compression session before a key-frame request or stalled-frame replacement supersedes outstanding work. This bounds actual submissions as well as bookkeeping. The compatibility encoder keeps one frame in flight.

Setting the key to NO restores the original ladder rules and default one-frame limit. Existing explicit `PocketDeskEncoderMaxInFlight` diagnostic overrides retain their original meaning with NO; delete that override when checking the default rollback. ON clamps even an unlimited or oversized saved override to 1–2. There is no new settings UI, wire message, capability, or version bump.

## Rate recovery and backlog

At a same-size 30→60 step, thirty delivered frames cannot prove sixty-frame capacity because capture has already been thinned. After the existing ten-second clean wait/backoff, the new policy permits a trial when delivery keeps up with offered demand and p90 encode delay has 10% headroom below two 60 fps intervals (30 ms). While at 60, measured delivery must sustain at least 95% of offered demand, with a one-frame sampling allowance. Low-activity, size-increase, higher-rate, missing-trace, and compatibility paths keep the original conservative gate.

The owned encoder now reports the share of each statistics window spent at its capacity. At least 90% occupancy for two consecutive load samples, delivery shortfall, or p90 end-to-end encode delay above two frame intervals causes a step down. Ordinary two-frame overlap does not. Occupancy flushes even when callbacks stop and preserves closed history until the next drain. These statistics remain local to the Mac.

## Investigation limits

The historical cache has 135 active 2360×1526 rows, median capture 57.7 fps and encoded 28.0 fps. Median full encode p50/p90 is 22.3/22.8 ms, VT p90 is 22.6 ms, and the paired full-minus-VT difference is 0.2 ms. It reports hardware owned HEVC, one frame in flight, QP bound 26 and low-latency mode off. The rows lack timestamps, so this is not a verified attribution to the reported 19:30 session.

This trace begins after pixel adaptation: it implicates VT in the measured delay but cannot rule out Retina scaling or conversion before submission. The old unpaced lab queues 240 frames and often omits the QP bound; its 74–186 fps is not a matched two-frame comparison. QP, scaling, pixel formats and quality settings are unchanged in this lane.

Matched loopback receipts, test counts and final verification are recorded in the lane's `NOTES.md` under `~/Documents/Codex/2026-10-01/perf-push/b12-encoder-throughput`. Loopback uses a prebuilt pixel buffer and real encode/decode; it does not establish ScreenCaptureKit, network, installed-host or iPhone performance.

## Verified checkpoint and external gate

The independent GPT reviewer approved the source after two regression fixes. Native test-first evidence includes the expected baseline failures and passing implementation checks. The core remainder passed 1,993 tests (13 skipped), and the full phone suite passed 800 tests (two skipped), both with zero failures. Native core and simulator phone test builds passed.

The first complete core run stalled in the existing Vision text-recognition test. A process sample showed a semaphore wait inside Apple TextRecognition. The exact base `136361c` OCR sources passed in a fresh native test bundle; a complete core retry is still required rather than treating the stall as a reproduced baseline failure.

At 12:53 ET the orchestrator's `PAUSE-BUILDS` gate remained active after shared-Mac memory exhaustion. The prepared complete core retry never started. Host and generic iOS compilation and all matched quiet measurements remain pending. The lane left no active waiter or measurement. `QUIET-REQUEST-b12-encoder-throughput` requests four minutes after remaining verification; there has been no grant or performance measurement.

| Requested stream | Before/after encoded fps | Before/after encode latency |
| --- | --- | --- |
| 1920×1248 | Pending quiet grant | Pending quiet grant |
| 2560×1660 | Pending quiet grant | Pending quiet grant |
| 2360×1526 | Pending quiet grant | Pending quiet grant |

The prepared `core-retry.zsh`, `compile-final.zsh`, and `bench-quiet.zsh` commands and exact log paths are in the lane's external `NOTES.md` HANDOFF. This is a verified implementation checkpoint, not completed performance acceptance.

## Combined .7 iPhone acceptance

After the orchestrator integrates and installs the combined build:

1. Use the same Wi-Fi, an awake/unlocked cool Mac, and a continuously scrolling long page or Test Pad. Connect on the iPhone with the normal default quality and rotate to landscape. Scroll for 60 seconds at the native large stream size.
2. Confirm the 60 fps rung persists, encoded delivery keeps up with at least 95% of offered source frames (one-frame window allowance), the stream avoids an exact 30 fps plateau, p90 encode delay stays below 33.3 ms, and in-flight maximum stays at two or less. A roughly 57 fps capture source need not produce exactly 60 encoded frames.
3. Check readable text and responsive controls. Rotate both ways, then background/resume twice; picture and controls should recover without corruption or a sustained stall.
4. For rollback, the orchestrator sets the host defaults key to NO and restarts through its approved installation workflow. With the old diagnostic override absent, expect the original one-frame limit and single-frame climb gate. Restore YES for the combined test.

Live ScreenCaptureKit throughput, physical iPhone acceptance and mixed-version sessions require that combined device check. Protocol changes were unnecessary.
