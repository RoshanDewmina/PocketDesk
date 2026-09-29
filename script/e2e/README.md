# Farside end-to-end harness

The iOS Simulator phone app drives the **real Mac host** on this Mac. Every click and keystroke lands
only in the **Farside Test Pad**, a fixture window that logs everything it receives. The harness is
meant to run unattended (overnight loops) and writes a JSON + Markdown report per run.

## Run it

After the integrated Debug host is installed (`script/build_and_run.sh` from the main checkout):

```sh
script/e2e/run-e2e.sh --host-app "/Applications/PocketDesk Host.app"             # all scenarios once
script/e2e/run-e2e.sh --host-app "/Applications/PocketDesk Host.app" --repeat 8  # overnight loop
script/e2e/run-e2e.sh --host-app "/Applications/PocketDesk Host.app" --long      # 45-min soak
script/e2e/run-e2e.sh --self-test --soak-seconds 60                              # harness self-test, no real host
```

Options: `--scenarios a,b,c,d,e,f` (d = d1–d4), `--repeat N`, `--soak-seconds S` (default 1200),
`--long` (2700 s soak), `--room-lifetime S`, `--simulator NAME`, `--skip-build`,
`--derived-data PATH`, `--no-caffeinate`, `--keep-simulator`. Exit code 0 = every scenario passed
(or failed only a known-issue check), 1 = a scenario failed, 2 = usage, 3 = setup failure,
75 = another harness run is active.

Reports: `/private/tmp/farside-e2e/reports/<run>/report.md` and `report.json`
(`reports/latest` points at the newest). Each scenario folder keeps `xcodebuild.log`, the
`.xcresult` bundle (screenshots on failure), the test's own `result.json` (checks, metrics, notes)
and `harness.json` (exit code, timing, timeouts). `iter-N/logs/` keeps the host, phone and Test Pad
logs, per-second stream statistics, the service log and a process CPU/memory sample every 5 s. When
`bench/stats_summary.py` exists, the report includes its per-stage summary of the E2E stream stats.

Requirements: Xcode with an iOS simulator runtime, Bun, and — for the real host — an installed
**Debug** build of this branch with Screen Recording and Accessibility already granted. The
harness never requests permissions. The Mac must be unlocked when the run starts.

## What it does

1. Takes a run lock (`/private/tmp/farside-e2e.run.lock`), checks tools, the lock screen, the host
   bundle (id, E2E hooks present) and whether Mission Control's ⌃←/⌃→ Space shortcuts are on.
2. Creates/boots the dedicated simulator **Farside E2E iPhone**; builds Farside Test Pad, the phone
   app and `RemoteE2ETests` (every `xcodebuild` runs as `lockf -k /tmp/farside-xcodebuild.lock …`).
3. Holds `caffeinate` assertions for the run (display on, no idle sleep, periodic user activity)
   so the Mac cannot sleep or lock mid-run. They end with the harness. Nothing is set system-wide.
4. Per iteration: writes a one-time pairing token (0600), starts the signaling service from
   `Server/` on a free loopback port (18790–18899; the owner's 18787 service is never touched),
   launches Farside Test Pad, then runs each scenario as its own `xcodebuild test-without-building`
   invocation while serving the tests' requests (kill/relaunch its own host, stop/start its own
   service, activate the Test Pad) and sampling CPU/memory.
5. Cleans up only what it started: exits full screen, quits the Test Pad, stops its host instance
   and service, shuts the dedicated simulator down, deletes the token and invitation files.

## Scenarios

| Id | Test | What it proves |
|---|---|---|
| a | `test_a_PairConnectStream` | Fresh pairing through the phone's **Paste Code** flow; the host approves only because the encrypted proof carries the one-time token (token then deleted, no manual approval); control session; host sending and phone decoding frames; resolution and requested quality settle (host sent size = phone received size, applied = requested); phone-drawn pointer active. |
| b | `test_b_PointerClicksDragScrollZoom` | Closed-loop pointer steering onto Test Pad targets through the product's relative-pointer path; phone-drawn pointer agrees with the Mac pointer (≤ 3 pt); tap = click, double tap = click count 2, two-finger tap = right click; double-tap-hold-drag moves the drag handle; two-finger scroll produces a began…ended scroll stream and moves the Test Pad scroll view; pinch zooms only the phone view (no Mac input) and the view auto-follows the pointer while zoomed. |
| c | `test_c_TypingModifiersClipboardDictation` | Click focuses the Test Pad text view; phone keyboard text arrives exactly; Shift+Left ×3 selects and Delete removes; ⌘A selects all; **Copy from Mac** (⌘C) brings the selection to the phone (digest compared); **Paste to Mac** writes the Mac clipboard and presses ⌘V; the dictation **Done-to-insert** path inserts a synthetic transcript. |
| d1 | `test_d1_BackgroundShort` | Home for 5 s: no input reaches the Mac while backgrounded; the session resumes (held or reconnected) without re-pairing; a click lands afterwards. |
| d2 | `test_d2_BackgroundLong` | Same for 60 s (past the phone's hold): automatic reconnect with saved trust. |
| d3 | `test_d3_HostRebootRecovery` | Harness SIGKILLs, then SIGTERMs, **its own** host instance and relaunches it; the phone must reconnect **without a tap** within 60 s ("reboot recovery"); clicks land afterwards. |
| d4 | `test_d4_SignalingRestart` | Stop the harness's signaling service, restart it on the same port; both sides reconnect automatically within their retry budgets. |
| e | `test_e_FullScreenSpaces` | The phone clicks the Test Pad's full-screen button; three-finger swipe right (⌃←) leaves the Space; **Controls › Next Space** (⌃→) returns; the stream stays fresh; a click lands in the full-screen Test Pad; the phone exits full screen and the window is back on the original Space. Skipped when the ⌃←/⌃→ shortcuts are off. |
| f | `test_f_Soak` | 20 min (default) of continuous pointer motion plus a verified click every 15 s. Fails on disconnects, a video stall over 1 s, a missed click, or a memory trend (> max(96 MB, 35 %) growth after warm-up). The host is relaunched right before the soak so the signaling room's 30-minute lifetime falls at a known point: with `--long` the report states whether the session **survived the 30-minute room boundary** and whether it recovered by itself (a known product limit, reported as `known-issue`, not a regression). |

The E2E service runs with the product's defaults (30-minute rooms, no TURN) except a higher
per-source connection-attempt cap (600/min), because every harness connection comes from 127.0.0.1
and the recovery scenarios reconnect far more often than a person would.

Multi-finger gestures (two-finger scroll, three-finger swipe, double-tap-hold-drag) use XCTest's own
event-synthesis classes, looked up at runtime (`RemoteE2ETests/E2ETouchSynthesizer.m`); if a future
Xcode removes them those steps skip with a clear reason. ⌘A has no button in the phone UI, so the test
sends it through a DEBUG-only phone command inbox that uses the same admitted key path (fresh
picture, host token, epoch) as the keyboard bar.

## Safety model: the E2E hooks cannot run in Release

All hook code is inside `#if DEBUG` (`RemoteShared/E2ESupport.swift`, `RemoteHost/HostE2E*.swift`,
`RemotePhone/PhoneE2E.swift`, small call sites in the host/phone models and the coordinator), so a
Release build contains none of it. The harness also refuses a host binary that lacks the hooks,
because a Release host would start as the normal host.

A Debug build enters E2E mode only with **both** the `--farside-e2e` launch argument **and**
`FARSIDE_E2E=1` in its environment. A half-configured E2E launch exits (code 78) instead of running
as a normal app. In E2E mode:

- **Isolation.** The host keeps its trust in Keychain account `host.e2e` and its preferences in the
  suite `com.roshan.PocketDesk.RemoteHost.e2e` (control allowed, keep awake on, connect chime off so
  overnight loops stay silent); the phone uses account `phone.e2e`. The owner's real
  pairing and settings are never read or replaced. The harness launches a *second* host instance
  (`open -n`); the owner's running host is untouched, and only the PID the harness launched (checked
  by launch id and executable path) is ever signalled.
- **Loopback only.** The signaling URL must be `ws://127.0.0.1|localhost:<port>/signal`; the
  harness directory must be exactly `/private/tmp/farside-e2e`, owned by the user, not group/world
  writable. The host never presents setup UI or takes focus in E2E mode.
- **One-time pairing token.** The harness writes 32 random bytes (hex) to
  `/private/tmp/farside-e2e/secrets/pairing-token` (mode 0600, directory 0700). The phone receives the
  token as a launch argument and sends it only inside the AES-GCM-encrypted pairing proof while
  enrolling. The host auto-approves a new phone only if the token file is a regular 0600 file owned
  by the user and matches in constant time, then deletes it; any other proof falls back to the normal
  human approval. Already-paired reconnects never need the token.
- **Input fence.** Injected input may only reach the Farside Test Pad
  (`com.roshan.PocketDesk.FarsideTestPad`): moves are clamped to its content area and need it
  frontmost; clicks, drags and scrolls need the pointer inside it with no other window on top;
  typing needs it frontmost; keys are allowlisted (letters, arrows, Return/Tab/Delete/Escape/Space,
  Shift, ⌘A/C/V/X/Z). ⌃←/⌃→ may reach the system away from the Test Pad only when the harness confirmed
  Mission Control's Space shortcuts are on. Mission Control/App Exposé keys, ⌘Q/⌘Tab/⌘Space and
  everything else are refused. Release (mouse up) is always allowed.
- **Observable state** goes only to `/private/tmp/farside-e2e/{host,phone}` (state.json every
  100 ms, events/input/stats JSON lines). Typed text is logged only inside the harness directory.
  The Test Pad logs pasteboard *metadata* only, never clipboard contents.

The clipboard scenario overwrites the Mac's general clipboard with a `FARSIDE-E2E-…` marker (that is
what Paste to Mac does). The E2E Keychain item `PocketDesk.Remote.Trust.v1 / host.e2e` stays in the
login keychain between runs and is reset at the start of each run.

Unit tests: `RemoteTests/E2EHooksTests.swift` (launch gating, loopback URL, token consumption and
file checks, every fence rule, and real token auto-approval through the Bun service).

## Self-test mode

`--self-test` drives `FarsideE2EStubHost` instead of the installed host: the same coordinator,
pairing, token approval and control protocol, generated video, and a virtual pointer. It never
captures the screen or injects events, so it proves the harness (simulator, pairing, gestures,
recovery orchestration, reports) without the installed app. Test Pad assertions, clipboard and
full-screen steps are skipped or reduced to host-side input checks in this mode.

## What still needs a real device

Click haptics, camera QR pairing, true iOS background time limits and socket survival (the
simulator is lenient), Dynamic Island / Live Activities, the microphone and on-device speech
recognition (only the Done-to-insert delivery is tested), physical multi-touch feel and gesture
conflicts with iOS system gestures, cellular and forced-relay routes, real network loss, and
performance on iPhone hardware.
