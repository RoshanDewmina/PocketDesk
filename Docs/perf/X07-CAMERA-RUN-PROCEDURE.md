# X07 calibrated camera run — procedure (pending Roshan)

Status: **procedure only; the run has not happened.** It needs Roshan physically (second 240 fps camera, the ASUS display, cellular, Network Link Conditioner). Build 20260930.9 carries the X06 exact per-frame timing (`video.timing.1`) that this run calibrates. No latency figure may be published before this run is accepted.

Prerequisites: `bench/CAMERA-KIT.md` (kit, camera placement, analysis tool) and `Docs/perf/SESSION-PROTOCOL.md` (quiet Mac, instruments, cleanup). Both are unchanged; this file only adds what X06 brought and the matrix the plan requires.

## What X06 adds to the overlay

With Stream statistics on and a .9 host, the phone overlay and the exported log carry two new lines:

```
exact tagged software source→decode p50/p95 …/… ms · source→public presentation …/… ms ±U ms
tagged records decoded N · original presented P · unique sources S · resends R · timed T · clock unavailable M
```

- `source` is the SCK `displayTime` of the frame (WindowServer software time), `decode` is native decoder output, `presentation` is the public `MTLDrawable.presentedTime`. None of these is a photon. The camera run turns `source→public presentation` into glass-to-glass by adding the panel constant measured below.
- `±U` is the clock-mapping uncertainty from the selected heartbeat sample. Reject a run whose `U` exceeds 5 ms or whose `clock unavailable` count grows during the run.
- `unique sources` versus `tagged records decoded` is the join coverage. Report both; a coverage below 90 % of the camera-counted transitions makes the exact line supporting evidence only.
- `resends` are idle re-sends of the same source frame; they never create a timing record.

## Conditions and sample sizes (plan §Measurement contract)

Three independent trials per condition, at least 100 camera-paired transitions per condition (about 60 s of auto-flash per trial), one variable changed at a time. Write the stimulus and failure rules down before filming: auto-flash on, Fit view, Sharper, no zoom; a transition is "unpaired" if no phone change follows within 400 ms.

| Condition | How | Pass marks (retained from the plan) |
|---|---|---|
| Quiet attached LAN | default | glass p50 ≤ 35 ms, p95 ≤ 50 ms; touch p50 ≤ 60 ms, p95 ≤ 90 ms |
| Congested local Wi-Fi | `bench/load/realistic-load.sh start typical` plus a second device streaming on the same AP | p95 ≤ 120 ms; record the ladder rung sequence instead of hiding adaptation |
| Relay around 40 ms RTT | phone Diagnostics → Relay-only test, set before connecting | p95 ≤ RTT + 70 ms; record the measured RTT distribution, not the label |
| Cellular around 100 ms RTT | Wi-Fi off, Anywhere on | p95 ≤ 200 ms, ≥ 30 unique delivered fps |
| 5 Mbps cap | Network Link Conditioner custom 5 Mbps both ways | sender queue ≤ 100 ms (X17 `senderQueueMs` estimate), glass tail ≤ 200 ms, readable text, 15 fps allowed |
| Loss | NLC 1 %, 2 %, 5 % random, then burst | 1 %: no freeze > 100 ms and no IDR storm; 2 %: ≥ 30 fps; 5 %: usable |

Record per trial: build, host/phone OS, display (`captureDisplay`), route and RTT, codec and negotiated pixels/fps, load, `n`, unpaired count, p50/p95/p99/max from `bench/glass_to_glass.py`, and the two exact lines from the same seconds. Stage p50s are not added together; RTT/2 is never reported as one-way delay.

## Panel constant (calibration, once per phone)

1. LAN trial as above, 60 s.
2. From the exported log take `exact … source→public presentation p50` for the same seconds the camera filmed.
3. `panel constant = camera glass-to-glass p50 − exact source→presentation p50`. Expect a small positive number (scanout and panel response). Write it in `Docs/perf/LAB-NOTEBOOK.md`; from then on, the overlay line plus the constant is the quoted in-app estimate, and only the camera number is a claim.

## Touch-to-photon

Separate metric, separate 20-tap run per condition as in CAMERA-KIT.md ("Touch-to-photon"). Not derived from glass-to-glass.

## Files

- Raw clips, `*.json`, `*.csv` and the exported statistics log go under `Docs/perf/runs/2026-10-<day>-x07/` (not committed if over 10 MB; note the path).
- One line per trial in `Docs/perf/LAB-NOTEBOOK.md`.
- Run the SESSION-PROTOCOL cleanup loop afterwards; `defaults read … | grep -c` must print `0`.
