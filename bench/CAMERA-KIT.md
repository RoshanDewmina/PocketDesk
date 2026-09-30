# 240 fps camera glass-to-glass kit

This kit measures what a person actually sees: the time from a change lighting up on the Mac's screen to the same change lighting up on the phone. It also covers the time from a finger tap to the result appearing. The in-app numbers (Stream statistics, per-frame timing) are only calibrated by this measurement. **No latency claim goes in the App Store listing without a run of this kit** (competition report §8a #7).

## What you need

- **A second device that films 240 fps slow motion.** An older iPhone or an iPad works: Camera → Slo-Mo, set to 240 fps in Settings → Camera → Record Slo-mo. The iPhone under test can't film itself.
- The Mac host and the phone on the same Wi-Fi. The Mac should be on power, with display brightness at 100 % on both screens and auto-brightness and True Tone off. Low Power Mode off on the phone.
- A stand or a stack of books, so the camera doesn't move.
- On the Mac: `python3` and `ffmpeg` (`brew install ffmpeg`).

## Set up (5 min)

1. **Start the bench on the Mac.** Launch Farside Test Pad in bench mode: `open -a "Farside Test Pad" --args --bench` (add `--bench-display 1` for a second display). It covers the whole display and shows a large ms clock, a marker strip and a **flash target** (the 220-pt square, bottom right).
2. **Connect from the phone** as usual.
   - Picture: **Fit**, no zoom, for the standard run.
   - For a larger target, pinch-zoom until the flash target fills about a quarter of the phone screen. Record which zoom you used, because zoom changes the capture size.
3. **Place the camera** so that it sees **the Mac's flash target and the phone screen side by side at the same height**.
   - Phone cameras read the sensor row by row (rolling shutter). With both targets on the same rows, they are sampled at the same instant.
   - Fill the frame. Both targets should be at least 40 px across in the video.
4. **Turn on auto-flash**: press **a** on the Mac, or append `{"cmd": "bench.autoflash", "on": true}` to `/private/tmp/farside-e2e/testpad-commands.jsonl`. The target now toggles dark/green every 400–700 ms at irregular intervals, so each Mac change pairs unambiguously with the phone change that follows it.

## Record

For each condition, film **at least 30 s** (about 50 toggles). Change one thing at a time.

| Run | How | Notes |
|---|---|---|
| LAN | Same Wi-Fi, default settings | The baseline |
| LAN, busy Mac | Same, with `bench/load/realistic-load.sh start typical` running | |
| Forced relay | Phone: the "Relay-only test" switch in the phone's diagnostics section (set it before connecting) | Note the RTT shown in Connection Health |
| Cellular | Phone Wi-Fi off, Anywhere on | Note the RTT shown |
| 5 Mb/s cap | macOS Network Link Conditioner, "custom" profile, 5 Mb/s down/up | Leave it on for only this run |
| 1–2 % loss | Network Link Conditioner, packet loss 1 %, then 2 % | |

**Touch-to-photon (optional).**

1. Turn auto-flash **off**, press **a** again.
2. Film the phone and the Mac target while you **tap the flash target on the phone** 20 times, about 1 s apart. Each tap clicks the Mac target, which toggles it.
3. The camera must see your fingertip land.

**Export.** Share each video from Photos with **Options → All Photos Data** (or AirDrop it) so the original 240 fps file arrives, not a 30 fps rendition. Check it:

```
ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate,r_frame_rate -of csv=p=0 clip.MOV
```

It should report 240.

## Analyse

```
cd ~/Developer/PocketDesk
python3 bench/glass_to_glass.py clip.MOV --snapshot=frame.png --start=2
```

Open `frame.png` and write down the two flash targets as `X,Y,W,H`, in pixels or as fractions of the frame. Take only the inside of each target, not its border. Then:

```
python3 bench/glass_to_glass.py clip.MOV --mac 812,400,60,60 --phone 1210,410,50,50 --start=2 --dur=30 \
    --json lan.json --csv lan.csv
```

Output:

```
frames 7200 · interval 4.17 ms (±2.1 ms before interpolation)
transitions: mac 52 · phone 52 · unpaired 0
glass-to-glass: n 52 · p50 38.4 · p95 49.0 · p99 51.2 · max 51.6 ms
```

How to read it:

- **Unpaired** counts Mac changes with no phone change within 400 ms: a freeze, a missed frame or a region that's wrong. More than a couple means you should check the regions against `frame.png`.
- For **touch-to-photon**, list the time in seconds of the clip at each frame where the fingertip first touches the glass, one per line in `touches.csv`. In QuickTime, step with ←/→ and read the time with ⌥-drag, or use the frame number divided by 240. Then add `--touch-times touches.csv`. The tool reports touch → Mac photon and touch → phone photon.
- The ±2.1 ms quantisation is before interpolation between frames. The analysis interpolates each change to sub-frame time, which is good to about ±1 ms on a steady clip.

Save the JSON files and a line per run in `Docs/perf/LAB-NOTEBOOK.md`: date, build, route, RTT, p50/p95/p99, n.

## Targets (proposed, PERF-PACK-2026-09-30 §4c)

| Condition | Glass-to-glass | Touch-to-photon |
|---|---|---|
| LAN, same Wi-Fi | p50 ≤ 35 ms, p95 ≤ 50 ms | p50 ≤ 60 ms, p95 ≤ 90 ms |
| Congested Wi-Fi | p95 ≤ 120 ms | — |
| Relay, 40 ms RTT | p95 ≤ RTT + 70 ms | p95 ≤ RTT + 100 ms |
| Relay or cellular, 100 ms RTT | p95 ≤ 200 ms, ≥ 30 fps | p95 ≤ 250 ms |
| 5 Mb/s cap | p95 ≤ 200 ms | — |

## Calibrating the in-app numbers

The Test Pad logs every shown toggle as `bench.flashShown` with the Mac display time (`markerMs`), and the phone's Stream statistics export has per-frame timing. Run a camera session with Stream statistics on. The difference between the camera's p50 and the app's `frameAgeMs` p50 (or `glassP50Ms`) over the same seconds is mostly the two panels' response and scan-out. Record it in the lab notebook as the calibration constant.
