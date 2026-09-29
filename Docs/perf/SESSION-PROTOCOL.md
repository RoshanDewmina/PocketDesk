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

The instruments themselves touch the frame path: with Stream statistics on, the phone reads the marker strip on the decode thread and takes the drawable before WebRTC's draw. Compare the same 60 s of motion with statistics **on** and **off**; the Mac's own log (`~/Library/Caches/PocketDeskStreamStats.jsonl`, `bench/stats_summary.py --last=60`) records encoded/sent fps and RTT in both cases, and a 30 s phone screen recording run through `bench/analyze.py` gives the delivered cadence in both. If the stats-on run shows lower cadence or more superseded frames, the marker reading is the suspect. With the follow-up branch installed, the cleaner A/B is Stream statistics on with **Read bench marker** on vs off (Controls → Picture): both runs then record every field except the marker-derived ones.

## Build .5 (G5, G4, ladder): 120 fps on the ASUS

Source: Roshan's ASUS VG32VQ1B, 2560×1440 at 1×. Set it to **120 Hz** (System Settings → Displays → ASUS → Refresh rate: 120 Hertz), not 144: sampling 120 fps from 144 Hz vsyncs gives uneven 6.9/13.9 ms gaps. Make it the main display for the bench window (Displays → Arrange, drag the menu bar onto it) or pick it from the phone (Controls → Display). Every stats sample now carries `captureDisplay` ("2560×1440 @1x 120Hz"), `targetFPS`, `hostThermalState` and `lowPowerMode`; copy them into the notebook entry with `uptime` before and after. The overlay's first lines must read `640c34`, `2560×1440`, `120Hz`, `target 120`.

Runs E (120 fps), each 60–90 s in the still / motion / taps pattern, Sharper, Fill:

| Run | Mac | Read |
|---|---|---|
| E1 120 default | ASUS at 120 Hz, no keys | capture fps, `Mac encode … fps`, presented fps, `distinct …/s`, `glass p50/p95`, `Mac VT lat p90`, `in-flight`, capture gap median |
| E2 60 control | `PocketDeskHighRefreshCapture -bool NO`, same display | the same; E1 − E2 is the 120 effect |
| E3 144 judder | ASUS at 144 Hz, no keys (capture thinned to 120) | `shownΔ p90`, `gap max`, capture gap median vs 8.3 ms |
| E4 WebRTC adaptation | `PocketDeskHighRefreshNoAdaptation -bool NO` at 120 Hz | whether libwebrtc's overuse detector cuts the rate (`limit cpu`, encode fps < 100) |
| E5 whole-display | `PocketDeskViewportCapture -bool NO`, phone zoomed to reading size (≈2×) | encode fps and VT lat on the full 3.7 MP vs E1's crop at the same zoom |
| E6 no client cap | `PocketDeskCapToClientPixels -bool NO` at Fit | picture size and VT lat vs E1 |
| E7 newest frame wins | `PocketDeskEncoderMaxInFlight -int 1` at 120 Hz | VT lat p90, `in-flight`, dropped-at-submit per second, presented fps |

Pass marks at 120 (research checklist §2c plus the brief's targets): ≥115 distinct frames/s delivered **and** ≥115 presented/s during motion, taken from the marker, not from the requested rate; capture gap median 8.3 ± 0.5 ms; VT lat p90 ≤ 6 ms with `in-flight` ≤ 1; glass p50 ≤ 40 ms and p95 ≤ 60 ms; 11 pt legibility no worse than the 60 fps run; `limit` none; ladder at rung 0 for the whole run. Reading a failure: encode fps < 100 → encoder (compare E5/E7); encode ≥ 115 but presented < 100 → phone or link (`gap max`, superseded); glass p95 > 60 with the rest passing → link.

Runs F (busy Mac, ladder), 60 s motion each at 120 Hz, one load at a time (research §4c.5): (a) a second VideoToolbox session, `ffmpeg -f lavfi -i testsrc2=s=3840x2160:r=60 -c:v hevc_videotoolbox -realtime 1 -f null -`; (b) a Simulator animation; (c) iPhone Mirroring open; (d) an `xcodebuild`. Start the load 15 s into the run and stop it at 40 s. Read: time from load start to the first ladder step (target ≤ 3 s), the rung sequence and reasons (`ladder` field), the pill's text on the phone, whether pixels were kept while an fps step was enough, and the step-up time after the load stops (target ≤ 12 s). F0: `PocketDeskLadder -bool NO` under load (d) as the control; expect the 38 fps episodes of the baseline and no pill.

Afterwards set the ASUS back to Roshan's usual refresh rate and run the cleanup below.

## Mandatory last step: clear every experiment key

Experiment switches live in the host's user defaults and would silently change Roshan's normal sessions if left behind. After the session, on the Mac:

```
for key in PocketDeskLegacyStreamTuning PocketDeskCaptureNativeRate PocketDeskRouteAwareSeed \
           PocketDeskRestartFloorKbps PocketDeskRestartKeyFrameBudgetMs PocketDeskEncoderCeilingKbps \
           PocketDeskLevel52ProbeCache PocketDeskHighRefreshCapture PocketDeskTargetFPS \
           PocketDeskHighRefreshNoAdaptation PocketDeskCapToClientPixels PocketDeskViewportCapture \
           PocketDeskLadder PocketDeskEncoderMaxInFlight; do
  defaults delete com.roshan.PocketDesk.RemoteHost "$key" 2>/dev/null
done
defaults read com.roshan.PocketDesk.RemoteHost | grep -c "PocketDeskCaptureNativeRate\|PocketDeskRouteAwareSeed\|PocketDeskRestart\|PocketDeskEncoderCeiling\|PocketDeskLegacyStreamTuning\|PocketDeskLevel52ProbeCache\|PocketDeskHighRefresh\|PocketDeskTargetFPS\|PocketDeskCapToClientPixels\|PocketDeskViewportCapture\|PocketDeskLadder\|PocketDeskEncoderMaxInFlight"
```

(The list is `StreamTuning.experimentKeys` in code; the host's diagnostics report also shows the active `Stream tuning` line once the follow-up branch is in.)

The count must print `0`. Relaunch the host, connect once, and check that the `tuning` field of the next stats sample (phone overlay first lines, or the Mac log's last line) reads exactly `playout 0-0ms · mode bitrates · keep resolution · encoder restart · max refresh`: nothing after "max refresh". On the phone, switch Stream statistics off and leave "Previous stream tuning" off. Prefer launch arguments (`-PocketDeskEncoderCeilingKbps 12000` on the host's command line) over `defaults write` for future A/Bs; they cannot outlive the process.

## Screenshots

`script/perf/legibility.sh --marker screenshot.png` scores a phone screenshot of the chart (the seed is read from the marker strip in Fit view; pass `--seed 0x…` otherwise). Score the Test Pad's own PNG (`bench.snapshot`) the same way for the Vision ceiling.
