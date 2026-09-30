# Performance pack — checks that need Roshan and the phone

Branch `farside-perf-pack` (plan: `PERF-PACK-2026-09-30.md`). Everything below needs the real iPhone, the real Mac host and a person. The automated tests can't cover it. Install the merged build the usual way (`script/build_and_run.sh` for the host, the device build for the phone) and turn on **Stream statistics** on the phone (Controls → Picture) before starting.

Each switch named below is a kill switch: if a check fails, turn it off and note it. No reinstall is needed for host defaults (relaunch the host); phone switches need an app relaunch.

## 1. Pointer feel with merged moves (≈ 5 min)

- [ ] **Trackpad mode.** Slow and fast circles, then small precise moves onto a 1-pixel target (a window corner).
  - The pointer must feel exactly as before: no lag, no stepping, no overshoot.
  - The overlay line `moves merged N` should now be **above 0** while moving fast. Before this pack it was always 0.
- [ ] **Drag.** Drag a window, select text by dragging and draw a line in Preview (Markup). The drawn line must be smooth. Drags are never merged on the Mac.
- [ ] **iPad pointer / direct touch (if on iPad).** Hover and drag.
- [ ] **Click right after a fast move.** The click must land where the pointer was drawn, never at an earlier point.
- [ ] **Weak Wi-Fi** (walk to the far room). Move, then click. After a stall the pointer must jump to the finger's position, with no slow replay of every old move.
- Kill switches:
  - phone: `PocketDeskMergePointerMoves` = NO;
  - host: `defaults write com.roshan.PocketDesk.RemoteHost PocketDeskInputQueue -bool NO`, then relaunch the host.

## 2. Newest frame wins (run E7 in `Docs/perf/SESSION-PROTOCOL.md`)

- [ ] Quiet Mac, then `bench/load/realistic-load.sh start heavy`. Toggle **Settings → Newest frame wins** on and off on the Mac.
- [ ] Compare the overlay's `distinct/s`, `presented` fps and `dropped at submit` per second.
- [ ] Pass: no visible drop in smoothness with it on, and lower `encode` latency under load.
- [ ] Watch the new `in-flight expired` count. More than a few per minute means VideoToolbox is silently dropping frames, so note it.
- Kill switch: the Settings switch, or `PocketDeskNewestFrameWins` = NO.

## 3. LAN headroom (only if it shipped on)

- [ ] Same Wi-Fi. Open a full-screen change repeatedly: Mission Control, switching Spaces, a large web page jump.
- [ ] The overlay's `pacer` and the phone's gap after each change should be lower with `PocketDeskLANHeadroom` 3 than with 1. `target` must never fall below about 5000 kb/s after the first seconds.
- [ ] Also run one relay session ("Relay-only test") and check the tuning line does **not** show LAN headroom being applied: the `max` in the Mac line stays at the picture ceiling.
- Kill switch: `defaults write com.roshan.PocketDesk.RemoteHost PocketDeskLANHeadroom -int 1`.

## 4. Per-frame timing

- [ ] With Stream statistics on, the overlay shows a `frame` line: Mac display → encoded, → phone, → shown, p50/p95. Numbers should be plausible: host a few to 30 ms, to-phone 20–80 ms on LAN.
- [ ] Export the stats JSONL and check it has `frameHostP50Ms` … fields.
- [ ] A browser viewer (if used) must still work.
- Kill switch: `PocketDeskFrameTimingSEI` = NO on the Mac.

## 5. 240 fps camera baseline

Follow `bench/CAMERA-KIT.md`: a second device that films 240 fps, Test Pad `--bench`, auto-flash (key **a**). Minimum set: **LAN** and **forced relay**. Then, if time allows: cellular, a 5 Mb/s cap, 1 % loss and touch-to-photon.

- [ ] Record p50/p95/p99 per run in `Docs/perf/LAB-NOTEBOOK.md`.
- [ ] Compare the results against the proposed budgets in the plan (§4c). These gate any latency claim in the listing.
