# Couch input timing — 2 October 2026

Batch7 lane `claude/b7-couch`, baseline `20aded1` / installed20261002.2. Product behavior stays in PRODUCT. This is implementation/evidence and a device measurement recipe, not physical acceptance. Speed remains `CouchTuning.speed = 1.4`; no user-facing setting was added.

## Path and source findings

1. `NativeTrackpadSurface.touchesMoved` previously forwarded only a finger callback endpoint. Couch now replays actual chronological coalesced samples for one owned direct finger through `NativeGestureEngine.updateCoalescedMotion`, before existing velocity-dependent gain. The final sample is not duplicated; old/invalid samples are ignored; at most24 samples per callback. Multi-touch, Picture, Pencil and hardware keep their prior delivery. Gain and8pt tap deadband stay unchanged. That deadband inherently delays initial pointer movement until intentional travel; it is not a transport measurement.
2. `PhoneDisplayTickInputPump` keeps the existing immediate leading motion and150ms retained link, but Couch prefers the active display maximum rather than60Hz. Picture still prefers60. Apple says the hint is best effort;60Hz hardware/system policy is supported. A mode transition invalidates the old callback generation without discarding pending ordered motion.
3. `RemoteCoordinator.sendMotionPrefix` uses the already-negotiated `pointer-causal-1` channel: unordered, zero retransmissions, with a full unacknowledged relative prefix. Opening/congestion failure uses ordered reliable control. The prefix is still24 segments /8KiB; more source samples can reach its bound sooner during long transport/ACK stalls. Recovery preserves accepted displacement and semantic barriers. No reliability, wire field, feature negotiation or bounds changed.
4. `PeerMedia.receivePointer` retains the newest delivered full prefix in a main-queue mailbox. Coordinator decode/admission still runs on main; `HostInputExecutor` posts on its serial user-interactive queue under generation/route/token/hold authority. Burst endpoint coalescing preserves sequential display clamps and semantic exceptions. No artificial host smoothing wait was added.
5. Production `HostModel` formerly constructed the executor's default driver, which called `CGPreflightPostEventAccess` on every action and host momentum tick despite a separate model permission cache. It now injects a thread-safe posting-grant observation, refreshed by the existing250ms active probes and expiring strictly at500ms. Probe-start timestamp prevents a slow check publishing stale permission as fresh. Observed denial and existing synchronous disable/generation cancellation still revoke input; cleanup releases bypass grant admission. macOS remains the final authority for event posting. This removes a synchronous public preflight from the native posting path; it does not prove that preflight caused the reported lag.

## Baseline evidence and limits

Read-only host logs in Toronto `[2026-10-02 04:40,05:10)` contain1,820 `TCCAccessRequest() IPC` records,1,817 on the predominant main thread. Complete early minutes have120/min, later minutes mostly60/min. The records do not identify the TCC service, Swift callsite or duration. Main periodic calls include ScreenCapture preflight at1Hz plus posting/AX probes at1Hz idle / an extra4Hz active. The former default driver also probed per event; AX cursor fallback has additional checks. Do not attribute every log record to the removed driver probe. Redacted detailed receipt is in the lane notes directory.

The saved statistics cache contains87 capture-free LAN input reports,20 with main/send timings. Median **per-report** main-delay p50/p95 was1.0/11.35ms; worst main delay30.9ms. Median per-report send→arrival p50/p95 was4.5/29.35ms, worst260.3ms, with median/max clock uncertainty3.0/3.9ms. Median per-report post p95 across87 reports was0.2ms, worst0.9ms. These reports lack exact Couch/build identity and event inter-arrival data. They neither locate the upstream tail uniquely nor establish a new-build improvement. Window percentiles cannot be pooled into raw-event percentiles.

## Verified candidate and synthetic before/after

Host Debug build and core build-for-testing passed.181 selected core tests,39 phone tests (23 pump +16 Couch model), and5 Python analyzer tests passed with zero failures. Final phone build-for-testing passed after correcting a test-only optional frame-rate unwrap. Fresh independent GPT source review approved with no unresolved findings. Commands and logs are in `~/Documents/Codex/2026-10-01/perf-push/b7-couch/logs/`.

The hosted fixture supplies exact-phase120Hz offers and an injected link honoring the requested rate:

| Metric | Prior requested60Hz | Couch requested120Hz |
|---|---:|---:|
| Added phone queue wait p50/p90 |0 /8.33ms|0 /0ms|
| Send-gap error versus120Hz p50/p90 |8.33 /8.33ms|approximately0 /0ms|

These values prove the pump's synthetic queue behavior only. Physical host-arrival/post jitter p50/p90, end-to-end added latency and touch→visible-pointer improvement remain unmeasured. Actual OS callbacks, network delay, acceleration, permission enforcement and WindowServer presentation require the controlled device recipe below. No installation or running-host mutation occurred in this lane.

## Gated trace and report

In a DEBUG candidate, the process-start internal default `couchInputTimingTraceEnabled=true` emits numeric `couchTiming` unified logs. Leave it off for ordinary feel/performance acceptance; tracing overhead itself needs comparison. No text, key names or pointer coordinates are logged. Correlation uses shortened ephemeral causal nonce/anchor plus geometry epoch, ordinal and **original callback-arrival timestamp**.

Phone logs contain touch timestamp/callback, oldest queued offer/send, actual pointer or reliable send lane, prefix occupancy, encoded bytes and reliable-control buffered bytes. Host logs contain calibrated send time/uncertainty, data-channel callback arrival, main admission trace time, actual posting-queue start/end per accepted motion and named permission probe intervals (`screen`, `post`, `AX`, rollback `post-legacy`). Phone local timestamps are not directly subtracted from host timestamps. Host calibrated send-gap comparisons can include clock-estimate changes; inspect reported uncertainty before interpreting tiny differences.

Export the exact test interval after integration, using the already-installed host only for read-only log collection:

```sh
/usr/bin/log show --start 'YYYY-MM-DD HH:MM:SS' --end 'YYYY-MM-DD HH:MM:SS' \
  --style ndjson --info \
  --predicate 'process == "PocketDeskRemoteHost" AND category == "couchTiming"' > host-couch.ndjson
python3 script/couch_timing_report.py host-couch.ndjson > host-couch-report.json
```

Collect phone syslog separately through the orchestrator and run the same report on its trace messages for phone-only stages. Verify exported wall timestamps respect the requested interval: this Mac's log tool emitted later records in the audit despite `--end`. Analyze only stationary conditions in one known Couch interval. The report excludes phone-idle gaps above150ms, repeated/reordered prefix endpoints and ambiguous/missing post-origin joins. Missing calibration yields null, not zero. Jitter is `abs(host inter-arrival gap - corresponding phone send gap)` (likewise post-gap); p50/p90 is nearest rank. `arrivalToMain` includes main decode/admission before its trace stamp, while `arrivalToPost` also includes executor work. Driver/post intervals bracket `CGEvent.post`; they do **not** measure WindowServer pointer presentation.

Permission trace intervals permit a fresh call-specific TCC correlation and duration check. To reproduce legacy per-event preflights use its rollback key in an integrated candidate. Do not change the installed host/defaults or install/relaunch from this worktree; the orchestrator owns that step.

## Internal rollback keys and clean A/B

- Host `hostPostingGrantSnapshotDisabled=true`: restores native per-event preflight; periodic checks unchanged.
- Phone `couchInputMaximumCadenceDisabled=true`: restores preferred60 with the same retained link and leading sends.
- Phone `couchCoalescedFingerMotionDisabled=true`: restores finger callback-endpoint delivery.
- Existing phone `phoneDisplayTickInputPump.optimizedCadenceEnabled=false` is the broader original cadence rollback; do not use it for the clean60/120 comparison because it changes retention as well.

The orchestrator can install one instrumented candidate, run old behavior with the three new rollback keys enabled, then run new behavior with them disabled under the same quiet LAN conditions. Trace requires process restart; arrange candidate launches through the orchestrator. Do not mix build, network, thermal or gain changes between rounds. Compare raw-event report p50/p90, send→arrival, arrival→post, total send→post and clock uncertainty. The synthetic hosted pump test compares exact-phase120Hz offers with requested60/120Hz ticks; its numbers establish queue behavior only.

## Roshan's feel and safety check

After the orchestrator integrates/installs, connect the iPhone17 on the same Wi-Fi and choose Couch. Confirm no phone picture, watch only the Mac's cursor. With sensitivity unchanged:

1. 30 s slow circles and diagonals, including tiny reversals. Pass: continuous tracking after tap slop, no repeated stop-jump pattern or unexpected acceleration jump.
2. 30 s fast sweeps, display-edge reversals and direction changes. Pass: cursor follows immediately and consistently, with no delayed tail after finger stops.
3. 30 s hold-drag a harmless window, reverse direction, lift/drop repeatedly. Pass: final position follows the finger, no stuck button or motion after release.
4. 15 s pause/restart after idle; 15 s taps/double taps and Space/arrows/text keys. Pass: prompt restart, correct clicks, immediate keys.

Repeat with clean rollback behavior if jitter remains; save both exact intervals plus route, actual phone link callback cadence and clock uncertainty. Separately hold a harmless drag, lock the Mac or switch users: pass requires immediate control/hold revocation and continued denial until authorized recovery. Finally check permission revocation from the Mac settings in a controlled orchestrator-owned test. Device notification delivery, true touch→visible-pointer latency, physical120Hz cadence, permission enforcement and feel are unverified until those runs.
