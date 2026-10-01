# Prototype gates (X22, X24, X26)

1 October 2026, batch 2. Three report features are prototypes. Each stays gated, off by default, and out of Release unless a promotion is decided with the evidence below. Matrix rows X22, X24 and X26 in the execution matrix define acceptance. This page records the current gate, what a Release build contains, what promotion needs, and the check that proves exclusion.

## Verify exclusion

```sh
# Release host: exits 1 if any Mach-O image carries a prototype marker.
script/release/verify-prototype-exclusion.sh /path/to/Release/PocketDeskRemoteHost.app

# Debug host control: exits 1 unless Contents/MacOS exposes the portrait entry markers and the FlexFEC preference key and trial reference,
# which proves the scanner detects what it looks for.
script/release/verify-prototype-exclusion.sh --expect-debug /path/to/Debug/PocketDeskRemoteHost.app
```

The script reads every Mach-O image in the bundle three ways: raw bytes, `strings -a` and `nm -a`. It never builds, launches, signs or installs anything. It replaces the marker check that used to live outside the repository (`verify-batch1-artifacts.py`, `MARKERS` and the Release exclusion check).

| Marker | Prototype | Where it is checked |
|---|---|---|
| `--virtual-display-portrait`, `VIRTUAL-DISPLAY-PORTRAIT-JSON:`, `VirtualDisplayPortraitPrototype`, `--virtual-display-spike` | X24 | every image |
| `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings`, `CGVirtualDisplayMode` (private SPI) | X24 | every image |
| `farsideRelayPacketRepair` (host preference key) | X22 | every image |
| `WebRTC-FlexFEC-03`, `kRTCFieldTrialFlexFec03Key`, `kRTCFieldTrialFlexFec03AdvertisedKey` | X22 | every image except the vendored `WebRTC.framework`, which defines them for its own receiver |

Markers must be longer than 15 UTF-8 bytes. Swift encodes shorter literals inside instructions, where no byte or `strings` scan sees them. For example, the `flexfec-03` codec name used by the receive path is invisible to the scan.

Recorded on 1 October 2026 with hosts built from `claude/b2-proto` 6038f25, build 20260930.8. The later review fixes changed only the script, the Picture copy and where the idle resend is counted; none of them adds or removes a marker. The Release host from `b2.sh proto host-release` printed `PASS Release exclusion: 8 Mach-O images, no prototype markers`. The Debug host from `b2.sh proto host-build` printed `PASS Debug control: 10 Mach-O images`. All hits in the Debug build were in `PocketDeskRemoteHost.debug.dylib`: the eight virtual-display markers, `farsideRelayPacketRepair`, `kRTCFieldTrialFlexFec03Key` and `kRTCFieldTrialFlexFec03AdvertisedKey`. The `WebRTC-FlexFEC-03` literal was not found there, because Farside refers to the trial only through the WebRTC constants.

The check fails closed. An unreadable bundle file, or a `strings`, `nm` or `grep` read failure on any image, exits 1 with a message rather than counting as no hits. The WebRTC exemption applies only to images under `Contents/Frameworks/WebRTC.framework/`.

## X22 relay FlexFEC packet repair

- **Gate.** The sender is compiled only into Debug builds (`#if DEBUG`). In Debug it is default-off behind the `farsideRelayPacketRepair` preference ("Packet loss testing" in Mac Settings), and the setting takes effect only after the app is restarted. `PacketRepairPreferences.resolve(debugBuild:stored:)` makes repair active only when both values are true. `PrototypeGates.isDebugBuild` is false in Release, so `activeThisLaunch` is always false there. Repair is also sent only for native codecs, on a route that is not proven local and is an observed selected Relay (`maySend`).
- **What Release contains.** No toggle row, no preference key and no FlexFEC field trial; `StreamTuning.prepareRuntime` never installs the trial. The receive capability is untouched: the default WebRTC receiver still accepts FlexFEC from a peer (`NativePacketRepairColdReceiverTests`). Guest media still filters FlexFEC out of its sender preferences.
- **Tests.** `PacketRepairReleaseGateTests` checks that the Release policy is off for any stored value, and that the Debug policy follows the preference with the default off. The `NativePacketRepairTransportTests` sender fixtures are unchanged and run in their own cold XCTest process. Run the cold receiver fixture in a separate process as well.
- **Evidence needed to promote.** (1) A pinned libwebrtc negotiation that shows the repair SSRC and actual recovered packets, not just `flexfec-03` in SDP. (2) Loss runs at 1%, 2% and 5%, both burst and random, at 100 ms and 150 ms RTT, comparing FEC against no FEC at equal total send rate. (3) The overhead and congestion trade-off, with no automatic 20% copy. (4) Fallback to no FEC, plus Relay→Direct retirement, on a real TURN or WAN path with the default phone. (5) Coexistence with the guest exclusion and aggregate caps. Promotion then means removing the `#if DEBUG` around the row and the trial, and making an explicit decision on default-off or default-on.

## X24 device-matched virtual display

- **Gate.** `RemoteHost/VirtualDisplaySpike.swift` and `RemoteHost/VirtualDisplayPortraitPrototype.swift` are wrapped entirely in `#if DEBUG`. Their only entry points, `--virtual-display-portrait` and `--virtual-display-spike` in `RemoteHostApp.init`, are inside `#if DEBUG`. Both are off unless launched with those arguments. This batch made no behaviour change.
- **What Release contains.** Nothing from either prototype, including no private `CGVirtualDisplay*` class names. This is confirmed by the Release scan above.
- **Evidence needed to promote.** The production decision in `farside-virtual-display-decision.md` must be made first. Either the Farside-owned private-SPI Mac adapter, with an explicit undocumented-SPI distribution choice, or an optional external creator (BetterDisplay), with a dependency, licence and economics decision. Then the build must show all of the following:
  - It uses a supported production API or an accepted distribution route.
  - Source cadence is measured rather than taken from the declared refresh.
  - The phone's pixels, orientation and HiDPI match.
  - It owns only its exact created display, with topology restored after normal exit, timeout and crash.
  - There is a safe fallback.
  - Full-desktop capture goes through the authenticated host/phone session, not an own-window synthetic proof.
  - It has a supported OS matrix and passes signed distribution acceptance.

  Big Text is not a substitute.

## X26 true 120 fps

- **Gate.** No prototype code: the 120 fps capture tier is existing default behaviour. `CaptureRatePolicy.targetFPS` returns 120 when `highRefreshCapture` is on (default) and the Mac display reports at least 100 Hz. Otherwise it returns 60. The phone presents at 120 Hz where it can. This batch adds measurement and honest copy only.
- **What Release contains.** The same 120 fps tier as before, plus the counters below. The Picture page and the Diagnostics codec line say "up to 120 fps on a 120 Hz Mac display" only when all three hold:
  - A Mac report less than 5 s old shows a refresh of at least 100 Hz.
  - If that report includes a target, it is 120 fps.
  - This phone's measured presentation rate (`displayMaxFPS`) is at least 100.

  Otherwise the copy says "60 fps", including on a 60 Hz phone and for older Macs that send no refresh. A stalled heartbeat does not flip the row: while the Mac report is merely stale, the session keeps its last known value. The value resets when a new session connects and when the session ends. This uses `CaptureRatePolicy.pictureRateDescription` and `LinkSummary.frameRate`.
- **Counters.** All of these appear in the statistics overlay and the `PDSTATS` log, separate from presentation (`shown`), redraw and Smooth motion.
  - **Host `uniqueSourceFPS`.** Complete ScreenCaptureKit frames whose display time is later than every earlier one. Idle-status callbacks, frames with no display time, repeated display times and idle resends are excluded.
  - **Host `captureResendFPS`.** Idle re-pushes of the last unchanged frame, counted separately and only when the push actually goes out (after the capture-scope guards).
  - **Phone `uniqueDecodedFPS`.** Frames handed to the WebRTC renderer whose RTP timestamp was not among the last 32. Smooth motion frames are never counted, because they never pass through that renderer.

  The Mac forwards `uniqueSourceFPS` and `resendFPS` to the phone in `HostStreamSummary`; older phones ignore them. A Mac idle resend gets a new RTP timestamp, so phone unique decoded includes resends. Read it next to `Mac resends`. Resends happen only after 0.45 s without a new frame, so they are zero during sustained motion.
- **Tests.** `StreamStatisticsTests.testUniqueSourceFramesExcludeIdleResendsAndRepeatedDisplayTimes` and `testUniqueDecodedFramesCountDistinctRtpTimestampsSeparatelyFromRedraws` cover the counters. `CaptureRatePolicyTests.testPictureCopyPromises120OnlyForAHighRefreshMacTargetOnAHighRefreshPhone` and the phone test `PhoneInstrumentsTests.testLinkSummaryPromises120OnlyFromAFreshHighRefreshMacReportOnAHighRefreshPhone` cover the copy.
- **Evidence needed to promote the 120 fps claim.** A physical display source of at least 100 Hz, such as a ProMotion MacBook Pro panel or an external 120 Hz display, or a proven virtual cadence. Then a sustained-motion run at the declared pixel size and load with all of these:
  - Host unique source ≥ 100 fps.
  - Phone unique decoded ≥ 100 fps.
  - Mac resends 0/s.
  - Redraw and interpolation excluded.

  The run must also report thermal state on the Mac and the iPhone over time, the M1 floor and pixel size, and the added latency of interpolation if Smooth motion is on. Until that receipt exists, no marketing or store copy may claim verified 120 fps.

## Follow-ups

- Extend `verify-prototype-exclusion.sh`:
  - Raw text scan of non-Mach-O bundle files (resources, plists, scripts).
  - A check that no symlink inside the bundle escapes it or is broken. The old out-of-repo script did this.
  - Call it from `archive-mac.sh` or `validate_archive.py`, so every distribution archive runs it automatically.
