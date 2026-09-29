# Measurement session protocol (phone in hand)

For the orchestrator to schedule Roshan's time. Every run needs a quiet Mac: no builds, simulators or browsers other than the bench window, iPhone Mirroring closed, Mac on AC. Record load average (`uptime`) before and after. One variable per A/B; the active switches are written into every statistics sample (`tuning` field), so the export is self-describing.

## Setup once (5 min)

1. Install the host and phone builds that contain the instruments (the orchestrator does this from main).
2. Mac: `defaults write com.roshan.PocketDesk.RemoteHost PocketDeskStreamStats -bool YES`, then relaunch the host.
3. Phone: Controls → Picture → Stream statistics on, Sharper.
4. Mac: launch the bench window: `open -n "<DerivedData>/Build/Products/Debug/Farside Test Pad.app" --args --bench`. It covers the whole display; `q` quits it. From the phone's keyboard (through Farside): `c` new chart, `m` motion on/off, `s` scroll on/off, `j` page jump, space = flash target.
5. Connect the phone, Fill view. The overlay's first lines should show `640c34`, `2560×1656`, `120Hz`, then `glass p50 … ±u` (marker seen) and `Mac VT lat …`.

Each run below is 60–90 s: 20 s static (chart visible, motion off), 30 s motion (`m`), 20 s clicks on the flash target (space or tap it), then Controls → Picture → Export statistics log (AirDrop) and note the time. Do not record the phone's screen during encoder runs.

## Run A: encoder latency (3 runs, ~6 min)

| Run | Mac defaults (relaunch the host after each `defaults write`) | Phone |
|---|---|---|
| A1 baseline | none (delete the keys below if set: `defaults delete com.roshan.PocketDesk.RemoteHost PocketDeskEncoderCeilingKbps`) | Sharper |
| A2 ceiling | `defaults write com.roshan.PocketDesk.RemoteHost PocketDeskEncoderCeilingKbps -int 12000` | Sharper |
| A3 pixels | delete the ceiling key | Responsive |

Read: `Mac VT lat p50/p90`, `in-flight ≤N`, `rate upd`, `session` age, `Mac encode … fps`, `limit`. In-flight > 1 at 58 fps means queueing; in-flight 1 at 40 ms means engine latency; rate updates beside latency tests the property-set hypothesis.

## Run B: arrival gaps (2 runs, ~4 min)

| Run | Change |
|---|---|
| B1 | as A1 |
| B2 | Mac: `sudo ifconfig awdl0 down` (diagnostic only; `up` afterwards) or Ethernet; phone: AirDrop receiving Off, Handoff off; iPhone Mirroring closed |

Read: `glass p95/max`, `distinct …/s` during motion, `shownΔ p90`, `gap … max`, RTT p90. The ≥98 ms per-second gap either disappears or it does not.

## Run C: calibration (once, ~5 min)

Second phone at 240 fps slow motion, Mac clock and iPhone clock in frame for 5 s during motion (STREAM-FIX-REPORT §7 step 3). The difference between the camera's median and the overlay's `glass p50` for the same seconds becomes the panel constant in the notebook.

## Quick-win A/Bs (each 2 × 60 s, later)

| Switch | Mac defaults key | Read |
|---|---|---|
| G1 native capture rate | `PocketDeskCaptureNativeRate -bool YES` | capture fps, `distinct …/s`, glass p50 |
| G15/G16 route-aware seed | `PocketDeskRouteAwareSeed -bool YES` (needs a P2P or relay route to differ) | sent/target ramp in the first 10 s, CER at +1/+3 s |
| G9 restart floor + IDR budget | `PocketDeskRestartFloorKbps -float 1500` and `PocketDeskRestartKeyFrameBudgetMs -float 250` (needs a thin link) | CER after idle, pacer max |

Undo any switch with `defaults delete com.roshan.PocketDesk.RemoteHost <key>` and relaunch the host.

## Run D: observer effect (2 × 60 s, motion on)

The instruments themselves touch the frame path: with Stream statistics on, the phone reads the marker strip on the decode thread and takes the drawable before WebRTC's draw. Compare the same 60 s of motion with statistics **on** and **off**; the Mac's own log (`~/Library/Caches/PocketDeskStreamStats.jsonl`, `bench/stats_summary.py --last=60`) records encoded/sent fps and RTT in both cases, and a 30 s phone screen recording run through `bench/analyze.py` gives the delivered cadence in both. If the stats-on run shows lower cadence or more superseded frames, the marker reading is the suspect (a phone-side "marker off while stats on" switch is a code follow-up).

## Mandatory last step: clear every experiment key

Experiment switches live in the host's user defaults and would silently change Roshan's normal sessions if left behind. After the session, on the Mac:

```
for key in PocketDeskLegacyStreamTuning PocketDeskCaptureNativeRate PocketDeskRouteAwareSeed \
           PocketDeskRestartFloorKbps PocketDeskRestartKeyFrameBudgetMs PocketDeskEncoderCeilingKbps; do
  defaults delete com.roshan.PocketDesk.RemoteHost "$key" 2>/dev/null
done
defaults read com.roshan.PocketDesk.RemoteHost | grep -c "PocketDeskCaptureNativeRate\|PocketDeskRouteAwareSeed\|PocketDeskRestart\|PocketDeskEncoderCeiling\|PocketDeskLegacyStreamTuning"
```

The count must print `0`. Relaunch the host, connect once, and check that the `tuning` field of the next stats sample (phone overlay first lines, or the Mac log's last line) reads exactly `playout 0-0ms · mode bitrates · keep resolution · encoder restart · max refresh`: nothing after "max refresh". On the phone, switch Stream statistics off and leave "Previous stream tuning" off. Prefer launch arguments (`-PocketDeskEncoderCeilingKbps 12000` on the host's command line) over `defaults write` for future A/Bs; they cannot outlive the process.

## Screenshots

`script/perf/legibility.sh --marker screenshot.png` scores a phone screenshot of the chart (the seed is read from the marker strip in Fit view; pass `--seed 0x…` otherwise). Score the Test Pad's own PNG (`bench.snapshot`) the same way for the Vision ceiling.
