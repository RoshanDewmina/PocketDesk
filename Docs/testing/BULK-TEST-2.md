# Farside — bulk test batch 2

Candidate build: **20260930.9** on phone and Mac host, branch `claude/batch-2`. The exact commit, automated results and install state are recorded in `~/Documents/Codex/2026-09-30/re/BULK-TEST-2-READY.md`. Run this after the batch-1 pass (`BULK-TEST-1.md`); every batch-1 check still applies.

Marks: **[AUTO]** simulator/unit evidence, **[MIRROR]** Claude can drive it through iPhone Mirroring, **[HANDS]** needs Roshan physically. Record PASS / FAIL / BLOCKED with a short receipt.

Boundary: no backend deployment, no App Store Connect, no purchases, no messages. Nothing here changes the installed host's identity.

## Automated checks before the cut

- [ ] [AUTO] Full core suite passes (one known environment failure allowed: `LegibilityChartTests.testVisionReadsTheRenderedChartAtTwoTimesScale`, a Vision/Neural Engine runtime error that also failed on .8 code).
- [ ] [AUTO] Phone unit suite passes; host snapshots pass (consent sheet, on-battery copy).
- [ ] [AUTO] Host Debug build has zero "Stack Promoted from Box" closures (`nm … | swift-demangle | grep`), and `RemoteHostModel.receive(_:)` / `receiveCausalInput` contain no `swift_weakDestroy` (the .8 crash class).
- [ ] [AUTO] Release host build passes `script/release/verify-prototype-exclusion.sh` (no virtual-display or FlexFEC send markers); the Debug build passes `--expect-debug`.
- [ ] [AUTO] Phone handshake stays within eight features with every opt-in on; a .8-format request decodes to the full base set.

## Regressions carried from .8 (do first)

- [ ] [MIRROR] An older phone build (.7 or .8) connects to the .9 host over LAN; the first tap and key arrive; the host does not crash.
- [ ] [MIRROR] Steady state on a quiet LAN: ≈ 0 PLI/s and no key-frame storm in the host overlay over 60 s still and 60 s motion.
- [ ] [MIRROR] After a 3 s capture-health gap, presentation and `fresh` recover within a few seconds and touch works again.
- [ ] [MIRROR] On the .9 phone, a one-finger drag moves the Mac pointer and a two-finger pinch changes the viewport scale, under HEVC and after forcing H.264 (Picture → compatibility). GATE: the `claude/fix-phone-touch-8` fix must be in the build.

## Consent and power (X13)

- [ ] [HANDS] First host launch after the update: if Farside already opens at login, no sheet at launch; the consent sheet appears from the Dock/Finder reopen, Settings, or the popover's "Review…" button, prefilled with the current choices; Continue (or "Keep current settings") changes nothing.
- [ ] [HANDS] On battery with no phone connected, keep-awake pauses (Settings row says so) and the Mac may idle-sleep; plugged in, it stays awake. With a phone connected and not paused the display never sleeps, on battery or not.
- [ ] [MIRROR] Settings: "Open at login" shows the saved choice and the macOS registration state.

## Data use (X15)

- [ ] [MIRROR] Picture page lists an estimated GB-per-hour range under each preset; the session report shows total bytes split into video+audio / files / other, with measured GB/h next to the preset estimate.
- [ ] [HANDS] Personal Hotspot or cellular: the one-time data card appears under the top pills, the session keeps running, "Use less data" switches to Responsive and survives relaunch, "Keep" dismisses, and it never reappears.

## Files (both directions)

- [ ] [MIRROR] 50 MB file phone→Mac and Mac→phone on LAN: elapsed time for each (expect roughly 1 MB/s); pointer and typing stay responsive during the Mac→phone transfer.
- [ ] [HANDS] Anywhere (relay or cellular): the same file both ways; elapsed time; the rate ramps rather than sitting at tens of KB/s.

## Picture quality (X25) and network (X04/X05/X16/X17)

- [ ] [MIRROR] Picture → Still text: both rows off by default and labelled experimental. Turn on "Sharpen still text", reconnect, confirm the still-text patch; turn on "Text clarity" and watch the host summary's "text clarity active" while the screen is still.
- [ ] [MIRROR] Stream statistics show: `VT in/out · superseded · retired` (X04), `QoS requested (not measured)` on LAN and not on relay (X16), `ceiling … (LAN raised)` only when `PocketDeskLANHeadroom` > 1 (X05, default off), `governor: shadow, …` (X17 never applies by default).
- [ ] [HANDS] Network Link Conditioner 5 Mbps: the overlay's governor line says "would cap" after a few seconds; the picture itself is unchanged (shadow mode).
- [ ] [MIRROR] Window-scope or rotated picture whose shape differs from the view: letterbox bars, never a stretched picture; the pointer glyph lands on its target.

## Audio and input leftovers

- [ ] [HANDS] Background PiP with Mac audio: connect AirPods → PiP and audio continue; remove them → audio stops, PiP continues; dictation stops on either change.
- [ ] [MIRROR] 300 ms / 1 s LAN disruption while typing: "Input catching up…" shows briefly, keys typed during it are refused (no haptic, nothing replayed late), typing resumes cleanly.

## Timing (X06/X07) and prototypes

- [ ] [MIRROR] Stream statistics show the two "exact tagged" lines with a clock uncertainty under 5 ms and "unique source/decoded fps" lines separate from presentation fps.
- [ ] [HANDS] X07 camera run per `Docs/perf/X07-CAMERA-RUN-PROCEDURE.md` — pending, needs the second 240 fps camera.
- [ ] [HANDS] FlexFEC toggle is absent from the Release host and present (default off) in Debug; virtual-display portrait entry exists in Debug only.
