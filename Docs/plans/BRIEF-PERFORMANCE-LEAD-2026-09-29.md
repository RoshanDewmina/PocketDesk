# Brief: Farside performance lead (Fable 5.1) — 29 Sep 2026

You own Farside's streaming performance end to end. Performance is the product's first priority and the gate for a 17 Nov launch. Roshan wants reading small Mac text on an iPhone to feel instant and sharp: no lag, and the best frame rate the hardware allows.

The research is done. What's missing is measurement: no post-fix number exists from a real iPhone. Your job is to turn the research into wins that are measured one at a time.

## Context

- **Gap analysis:** `~/reports/src/farside-vs-parsec-page/research/FARSIDE-PERFORMANCE-GAPS.md`. It lists 30 ranked gaps (G0–G30), gives a latency budget, suggests an order in §4, and designs a network harness in §6.
- **Same folder:** `APPLE-STREAMING-CEILING.md` and `INDUSTRY-PERFORMANCE.md`. Their encoder timing numbers were taken under heavy load; treat them as provisional.
- **In the repo:** `Docs/research/2026-09-28-round2/PERFORMANCE-PLAYBOOK.md`, `Docs/research/2026-09-28/ENCODER.md`, `STREAM-FIX-REPORT.md` (its §7 is the on-phone protocol), and `PRODUCT.md` for scope.
- **Hardware:**
  - Host: fanless M4 MacBook Air, 16 GB, 60 Hz 2880×1864 panel. It throttles under sustained load.
  - Phone: iPhone 17 (120 Hz).
  - Both a true 120 Hz stream and full-resolution 120 Hz need an external monitor or a virtual display.

## Targets

| Area | Target |
|---|---|
| LAN latency, glass to glass | ≤ 40 ms p50, ≤ 60 ms p95 |
| Frame rate | Solid 60 fps, with the phone rendering at 120 Hz |
| Text | 11 pt Mac text readable on the iPhone |
| Poor networks | Graceful at 2–5 Mb/s, 150 ms RTT and 1–2 % loss |

## How to work

1. **Instruments first.**
   - Build what the gap report says is missing: a per-frame glass-to-glass marker (G28), a legibility score using Vision OCR on a size chart (G29), and the negotiated H.264 level and sent size surfaced in diagnostics (G13).
   - Then run the §7 protocol on Roshan's physical iPhone in a quiet window, and write a baseline.
   - The landing pass runs in parallel. Until the orchestrator says the Mac is quiet, do design, code and unit-level work, and queue builds behind the shared lock.
2. **Quick wins, each A/B measured.** G1, G15, G16, G9, G25, then G18, G8 and G17. Put each change behind a `StreamTuning` switch so it can be reverted.
3. **Big levers.** G4 (capture only the viewed region, at the phone's pixel size), G12 (a resolution and frame-rate ladder), G14 (loss resilience) and G10 (keyframe size). Validate each on the network harness (§6). Its shaping relay will run on the Windows PC, which will be available later today.
4. **One bounded research spike.** Learn from open-source streamers (Moonlight/Sunshine, RustDesk, WebRTC's screen-share path) where it helps with G4, G8, G10 or G14. GPL and AGPL code is for learning only; never copy it. Also check whether the iPhone can hardware-decode HEVC 4:4:4.

## Rules

- **Quiet Mac only.** Measure only when the Mac has no builds, simulators or browsers running; ask the orchestrator for the window. Record the conditions with every number: AC power, load average, network.
- **One variable per A/B.** Never claim an improvement without before and after data from this session.
- **Worktree only.** Work under `.claude/worktrees/`. Don't merge; hand each finished, measured change to the orchestrator.
- **Delegation.** If you delegate code-writing to sub-agents, set their model explicitly to Opus 5.5, and let them work asynchronously while you continue. Give them the reason for the task, not just the steps.
- **Lab notebook.** Keep `Docs/perf/LAB-NOTEBOOK.md`: one entry per experiment, with the hypothesis, the change, the conditions, before and after, and a verdict. Read it before starting each experiment.
- **Scope.** Make targeted edits rather than rewriting whole files. Keep scratch benchmarks out of the committed test suites.
- **Roshan's time.** Keep his involvement to short, planned sessions with the phone in hand. For the §7 protocol and any 240 fps camera shots, tell the orchestrator exactly what you need and when.

## Stop points

Report to the orchestrator at each of these:

1. After the Phase 1 baseline.
2. After each batch of quick wins.
3. Before starting any big lever.

Lead with the outcome, then the numbers, then what you need from Roshan.
