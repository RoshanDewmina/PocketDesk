# Farside end-to-end harness

The iOS Simulator phone app drives the **real Mac host** on this Mac. Every click and keystroke lands
only in the **Farside Test Pad**, a fixture window that logs everything it receives. The harness is
meant to run unattended (overnight loops) and writes a JSON + Markdown report per run.

## Run it

After the integrated Debug host is installed (`script/build_and_run.sh` from the main checkout):

```sh
script/e2e/run-e2e.sh --host-app "/Applications/PocketDesk Host.app"             # all scenarios once
script/e2e/run-e2e.sh --host-app "/Applications/PocketDesk Host.app" --repeat 8  # overnight loop
script/e2e/run-e2e.sh --host-app "/Applications/PocketDesk Host.app" --long      # 45-min soak past the 30-min lease
script/e2e/run-e2e.sh --self-test --soak-seconds 60                              # harness self-test, no real host
```

Options: `--scenarios a,b,c,d,e,f` (d = d1–d5), `--repeat N`, `--soak-seconds S` (default 1200),
`--long` (2700 s soak), `--room-lifetime S` (the service's room lease, 60–3599 s; e.g. 300 crosses
several renewals in a 10-minute soak), `--simulator NAME`, `--skip-build`, `--derived-data PATH`,
`--no-caffeinate`, `--keep-simulator`, `--keep-xcresults` (by default only failed scenarios keep
their `.xcresult`, so overnight loops do not fill the disk). A run killed outright (no cleanup) leaves
a pid list; the next run stops those leftovers first — only processes carrying the harness's own
markers (`--farside-e2e`, the Test Pad's `--run-id`, `src/index.ts`).
Exit code 0 = every scenario passed (or failed only a known-issue check), 1 = a scenario failed,
2 = usage, 3 = setup failure, 75 = another harness run is active.

Reports: `/private/tmp/farside-e2e/reports/<run>/report.md` and `report.json`
(`reports/latest` points at the newest). Each scenario folder keeps `xcodebuild.log`, the
`.xcresult` bundle (screenshots on failure), the test's own `result.json` (checks, metrics, notes)
and `harness.json` (exit code, timing, timeouts). `iter-N/logs/` keeps the host, phone and Test Pad
logs, per-second stream statistics, the service and watchdog logs and a process CPU/memory sample
every 5 s. When `bench/stats_summary.py` exists, the report includes its per-stage summary of the E2E
stream stats.

Requirements: Xcode with an iOS simulator runtime, Bun, and — for the real host — an installed
**Debug** build of this branch with Screen Recording and Accessibility already granted. The
harness never requests permissions. The Mac must be unlocked when the run starts.

## What it does

1. Takes a run lock (`/private/tmp/farside-e2e.run.lock`), checks tools, the lock screen, the host
   bundle (id, E2E hooks present in the host and its `FarsideWatchdog`) and whether Mission
   Control's ⌃←/⌃→ Space shortcuts are on.
2. Creates/boots the dedicated simulator **Farside E2E iPhone**; builds Farside Test Pad, the phone
   app and `RemoteE2ETests` (every `xcodebuild` runs as `lockf -k /tmp/farside-xcodebuild.lock …`).
3. Holds `caffeinate` assertions for the run (display on, no idle sleep, periodic user activity)
   so the Mac cannot sleep or lock mid-run. They end with the harness. Nothing is set system-wide.
4. Per iteration: writes a one-time pairing token (0600), starts the signaling service from
   `Server/` on a free loopback port (18790–18899; the owner's 18787 service is never touched),
   launches Farside Test Pad in the **lower-left quadrant** of the main display, then runs each
   scenario as its own `xcodebuild test-without-building` invocation while serving the tests'
   requests (quit/kill/relaunch its own host, start/stop its own E2E watchdog, stop/start its own
   service, read the service's `/ready` counters, activate the Test Pad) and sampling CPU/memory.
5. Cleans up only what it started: stops its watchdog, exits full screen, quits the Test Pad, stops
   its host instance and service, shuts the dedicated simulator down, deletes the token and
   invitation files.

## Scenarios

| Id | Test | What it proves |
|---|---|---|
| a | `test_a_PairConnectStream` | Fresh pairing through the phone's **Paste a pairing code** flow; the host approves only because the encrypted proof carries the one-time token (token then deleted, no manual approval); control session; host sending and phone decoding frames; resolution and requested quality settle (host sent size = phone received size, applied = requested); phone-drawn pointer active. |
| b | `test_b_PointerClicksDragScrollZoom` | Closed-loop pointer steering onto Test Pad targets through the product's relative-pointer path; phone-drawn pointer agrees with the Mac pointer (≤ 3 pt); tap = click, double tap = click count 2, two-finger tap = right click; double-tap-hold-drag moves the drag handle; two-finger scroll produces a began…ended scroll stream and moves the Test Pad scroll view; pinch zooms only the phone view (no Mac input) and the view auto-follows the pointer while zoomed. |
| c | `test_c_TypingModifiersClipboardDictation` | Click focuses the Test Pad text view; phone keyboard text arrives exactly; Shift+Left ×3 selects and Delete removes; ⌘A selects all; the dock's **Clip** row: **Copy from Mac** (⌘C) brings the selection to the phone (digest compared) and **Paste to Mac** writes the Mac clipboard and presses ⌘V; the dictation **Done-to-insert** path inserts a synthetic transcript. |
| d1 | `test_d1_BackgroundShort` | Home for 5 s: no input reaches the Mac while backgrounded; the session resumes (held or reconnected) without re-pairing; a click lands afterwards. |
| d2 | `test_d2_BackgroundLong` | Same for 60 s (past the phone's hold): automatic reconnect with saved trust. |
| d3 | `test_d3_HostRebootRecovery` | Normal restart: the harness quits **its own** host instance gracefully (SIGTERM, a clean exit the watchdog ignores) and opens it again, as after a reboot or update; the phone must reconnect **without a tap** within 60 s; clicks land afterwards. |
| d4 | `test_d4_SignalingRestart` | Stop the harness's signaling service, restart it on the same port; both sides reconnect automatically within their retry budgets. |
| d5 | `test_d5_WatchdogRelaunch` | Crash recovery: with the host's own `FarsideWatchdog` running in E2E mode, **one** `kill -9` of the E2E host; the watchdog must reopen it within **10 s** (as a recovered launch that knows it ended unexpectedly), the phone must reconnect by itself (≤ 100 s) and show "Your Mac’s Farside restarted — reconnected." exactly once; a click lands afterwards. Real host only. |
| e | `test_e_FullScreenSpaces` | The phone clicks the Test Pad's full-screen button; three-finger swipe right (⌃←) leaves the Space; **Controls › Next Space** (⌃→) returns; the stream stays fresh; a click lands in the full-screen Test Pad; the phone exits full screen and the window is back on the original Space. Skipped when the ⌃←/⌃→ shortcuts are off. |
| f | `test_f_Soak` | 20 min (default) of continuous pointer motion plus a verified click every 15 s. The host is relaunched right before the soak, so the room lease (30 min by default) ends at a known point. Fails on **any** disconnect, a video stall over 1 s, a missed click, or a memory trend (> max(96 MB, 35 %) growth after warm-up). With `--long` (45 min) it also asserts the session **survived the 30-minute lease without a disconnect**; whenever the soak outlives the lease's half-life it asserts the service **renewed** the lease (`/ready` → `renewal.renewals`). |

The E2E service runs with the product's defaults (30-minute room lease with session renewal
`renew.1`, no TURN) except a higher per-source connection-attempt cap (600/min), because every harness
connection comes from 127.0.0.1 and the recovery scenarios reconnect far more often than a person
would. It is the repository's own `Server/` started directly (`bun src/index.ts`), not
`Server/scripts/run-bounded-standalone.sh`; if you soak against a service started with that script,
give it a 3600 s duration so the service outlives a `--long` soak.

Multi-finger gestures (two-finger scroll, three-finger swipe, double-tap-hold-drag) use XCTest's own
event-synthesis classes, looked up at runtime (`RemoteE2ETests/E2ETouchSynthesizer.m`); if a future
Xcode removes them those steps skip with a clear reason. ⌘A has no button in the phone UI, so the test
sends it through a DEBUG-only phone command inbox that uses the same admitted key path (fresh
picture, host token, epoch) as the keyboard bar.

## Safety model: the E2E hooks cannot run in Release

All hook code is inside `#if DEBUG` (`RemoteShared/E2ESupport.swift`, `RemoteShared/E2EMedia.swift`,
`RemoteHost/HostE2E*.swift`, `RemotePhone/PhoneE2E.swift`, `RemoteWatchdog/WatchdogE2E.swift`, small
call sites in the host/phone models, the coordinator, peer media and the watchdog supervisor), so a
Release build contains none of it. The harness also refuses a host binary that lacks the hooks,
because a Release host would start as the normal host.

A Debug build enters E2E mode only with **both** the `--farside-e2e` launch argument **and**
`FARSIDE_E2E=1` in its environment. A half-configured E2E launch exits (code 78) instead of running
as a normal app. In E2E mode:

- **Isolation.** The host keeps its trust in Keychain account `host.e2e` and its preferences in the
  suite `com.roshan.PocketDesk.RemoteHost.e2e` (control allowed, keep awake on, connect chime off so
  overnight loops stay silent, privacy curtain off); the phone uses account `phone.e2e`. The owner's
  real pairing and settings are never read or replaced. The harness launches a *second* host
  instance (`open -n`); the owner's running host is untouched, and only the PID the harness launched
  (checked by launch id and executable path) is ever signalled.
- **Watchdog isolation.** The E2E host never registers or unregisters the login item or the
  watchdog LaunchAgent, and writes its run record to `/private/tmp/farside-e2e/host/watchdog`
  instead of Application Support. For d5 the harness runs the installed bundle's `FarsideWatchdog`
  directly (not through launchd) with `--farside-e2e`: it reads only that record and crash ledger,
  counts only E2E instances as running, and relaunches the host with the same E2E contract. The
  owner's registered watchdog ignores E2E instances, and its crash-loop ledger never sees the E2E
  kill. The harness stops its watchdog at the end of every scenario and never kills more than once
  per run, far from the 3-exits-in-5-minutes crash-loop guard.
- **No prompts.** E2E media uses loopback ICE only (Wi-Fi/Ethernet/VPN/cellular adapters ignored,
  non-loopback candidates dropped), so no Local Network prompt; nothing calls an API that would ask
  for Screen Recording or Accessibility (the harness checks the host's state and fails cleanly); the
  Test Pad never warps the cursor. The phone skips first-run permission priming and the gesture coach
  in E2E mode.
- **Never clicks system dialogs.** Before every click-producing gesture the test checks, from
  `CGWindowListCopyWindowInfo`, that no other window (alerts, crash reports, CoreServicesUIAgent,
  System Settings, banners, other apps) overlaps the Test Pad; full-screen system containers (Dock,
  Notification Centre, Screenshot, menu bar, cursor) are recognised as backdrops. If something is on
  top, the Test Pad moves to another quadrant; if every quadrant is covered the scenario fails with
  "blocked by system dialog". The host's input fence applies the same rule to every injected click.
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
file checks, every fence rule, and real token auto-approval through the Bun service) and
`RemoteTests/E2EWindowCoverTests.swift` (which windows count as covering the Test Pad).

## Known product issue the harness catches

`PeerMedia.peerConnection(_:didOpen:)` assigns the data channel's delegate asynchronously, so the
host's one-time geometry/viewing message can arrive before the phone listens; the session then stays
view-only (geometry epoch 0) until a reconnect. The tests fail fast with that diagnosis instead of
timing out. Seen intermittently in scenarios c and d4 of the self-test.

## Self-test mode

`--self-test` drives `FarsideE2EStubHost` instead of the installed host: the same coordinator,
pairing, token approval, session renewal and control protocol, generated video, and a virtual
pointer. It never captures the screen or injects events, so it proves the harness (simulator,
pairing, gestures, recovery orchestration, reports) without the installed app. Test Pad assertions,
clipboard and full-screen steps are skipped or reduced to host-side input checks in this mode, and
d5 is skipped (the watchdog ships only inside the real host).

## What still needs a real device

Click haptics, camera QR pairing, true iOS background time limits and socket survival (the
simulator is lenient), Dynamic Island / Live Activities, the microphone and on-device speech
recognition (only the Done-to-insert delivery is tested), physical multi-touch feel and gesture
conflicts with iOS system gestures, cellular and forced-relay routes (the E2E media is loopback
only), real network loss, and performance on iPhone hardware.
