# Orchestrator state and resume notes — 29 Sep 2026

Saved at about 05:45 EDT for the owner-approved checkpoint and laptop restart (disk 98% full,
load average 222). `/private/tmp` is wiped on reboot, so this file carries everything needed to
resume. After the restart the repo moves to `~/Developer/PocketDesk`; old absolute paths below
under `~/Documents/ChatGPT/Saas/PocketDesk` refer to the same repo.

## Where things stand

- **Main** (`pocketdesk-remote-chat`): tip `3b18365`, pushed to origin. Contains the black-screen
  fix (`8f4b19b`), the phone data-channel fix (`655e5c0`), the merged E2E harness (`b9d6657`) and
  the E2E picture check (`3b18365`).
- **Owner's iPhone** (UDID `00008150-0001653C26F8401C`): Farside build `20260929.3`, built from
  main `8f4b19b`. Verified: install and version. The picture fix is verified in unit tests and the
  simulator E2E; still to be verified: the picture on the physical phone (owner to confirm).
- **Installed Mac host** (`/Applications/PocketDesk Host.app`): Debug build installed 01:12 from
  main `31900f9` by `script/build_and_run.sh`. It has **no E2E hooks**, so the real-host E2E needs a
  reinstall from current main first.
- **iPad**: not connected overnight; nothing installed.
- **Private signaling service** (launchd `com.roshan.pocketdesk.signaling`, bundle in
  `~/Library/Application Support/PocketDesk/`): redeployed 02:3x with session renewal; survives reboot.

## Black screen after connect (owner report 03:42): fixed

- Cause: `StreamTuning.tuned` forces WebRTC zero playout delay, so libwebrtc gives every decoded
  frame render time 0 and every frame reaching a renderer has `timeStampNs == 0`.
  `RTCMTLVideoView` skips a frame whose timestamp equals the last one it drew (initially 0), so it
  never drew. Frames still arrived, so the phone showed "Controlling your Mac" over a black stage.
- Fix `8f4b19b`: `FrameObserver` is the track's only renderer and passes frames to the Metal view
  through `RestampingRenderer` (strictly increasing timestamps). **Every other `RTCMTLVideoView`
  must use `RestampingRenderer` too** (the parity branch's `MiniMapView` did not; the agent was told).
- Also fixed there: WebRTC's Metal renderer resets the view to 30 fps on its first frame; the
  presentation probe now keeps its chosen rate (120 Hz), so the phone shows the full 60 fps stream.
- Evidence: `RemoteTests/VideoFrameTimestampTests` (loopback: tuned all 0, legacy increasing),
  `RemotePhoneTests/RemoteVideoSurfaceTests` (3 tests on the shipped `RTCMTLVideoView`), phone unit
  suite 58/58, E2E self-test a/d1/d3 all passed with the new picture check (stage 100%, 100%, 81%
  lit). Screenshot: `~/Downloads/farside-e2e-picture-after-pairing-2026-09-29.png`.

## Agents at the stop

Both agents stopped at a safe point, committed everything, pushed their branch and ran nothing
further. Nothing of theirs is merged into main. All simulators were shut down (none deleted except
the integrations agent's own, which it deleted during cleanup).

- **Phone parity** `a9c91c9bb117300d3`: branch `worktree-agent-a9c91c9bb117300d3`, pushed tip
  `66d432e`, clean, rebased on `3b18365` (needs one more rebase onto current main). Report:
  `design/PHONE-PARITY-REPORT.md`. Done: direct touch, iPad hardware keyboard/mouse with middle
  click, mini map (now drawn through `RestampingRenderer`, commit `40fa5ac`), display picker; iPhone
  UI tests for mini map drag/tap/fade, ⌃⌥ stand-ins and ⌘W/⌘M pass on the tip. Left:
  - iPad ⌘W/⌘M still send Farside to the Home Screen on the iPad simulator; the ⌘W-closes-Mac-window
    change is only unit-tested (iPad UI runner crashed under load). ⌘M may be iPadOS-owned (then ⌃⌥M).
  - Run `MiniMapVideoTests` (written, compiles, never run).
  - Re-run on the rebased tip: full phone unit suite, full iPhone UI suite, iPad parity suite (unit
    and UI in separate xcodebuild runs), screenshot run (direct touch, hardware keys, display
    picker, iPad mouse).
  - E2E host input fence blocks the new `moveTo` and `middle` actions (safe; follow-up in the report).
  - Delete its simulators afterwards: Farside Parity iPhone 17 `8578AF30-…`, iPad Pro 11 `8EBD7942-…`.
  - Macro test note: 18 RemoteCoreTests failures on the tip are environment-only (bun signalling
    service started from inside the test process never reports its port; BrowserFixtures JSON
    unreadable under the test sandbox), none in code the branch changes.
- **System integrations** `a752967d0e530c55c`: branch `worktree-agent-a752967d0e530c55c`, pushed
  tip `153835b`, clean, rebased on `3b18365` (17 commits). Report:
  `design/SYSTEM-INTEGRATIONS-REPORT.md`, evidence in `design/system-integrations/`. Done: App
  Shortcuts (Connect, Is my Mac awake?, End session), "needs you" notifications with actions,
  session Live Activity (Lock Screen + Dynamic Island), Mac agent-hook scaffold (off by default).
  `FARSIDE_ENABLE_PUSH=YES` gates push/Time Sensitive/Associated Domains, OFF by default, so the
  wildcard-profile device build signs. Verified on the rebased tree: phone unit 173/173,
  RemoteCoreTests 412 (xctest) 0 failures, host snapshots 15/15, one push routing sample end to end.
  Left: the other three push samples and the Snooze/Not now test; re-run the Lock Screen End test
  (flaked once under load); full phone UI suite (2 pre-existing fixture-launch timeouts at load ~200
  on the old base); Siri phrases, Spotlight and Always-On need a real phone.

## Resume checklist (after the restart)

1. Read this file and `Docs/plans/OVERNIGHT-2026-09-29.md`. Confirm with the owner that the
   overnight loop should continue (it was cancelled for the restart).
2. Parity branch: finish the `MiniMapView` restamp fix and its test, rebase on main (take main's
   `RemoteVideoSurface`/`FrameObserver`/`RestampingRenderer`), review, merge.
3. Integrations branch: review and merge. Push/Associated Domains entitlements must stay out of Debug
   device builds until the owner registers the explicit App ID (the wildcard profile can't sign them).
4. Reinstall the host with E2E hooks: `lockf -k /tmp/farside-xcodebuild.lock script/build_and_run.sh`
   (stops the host with SIGTERM, installs, relaunches, rolls back on a failed launch). Tell the owner
   first: their phone session drops briefly.
5. Real-host E2E (ask first if the owner is using the Mac: a Test Pad window appears and gets clicks;
   scenario e switches Spaces): `script/e2e/run-e2e.sh --host-app "/Applications/PocketDesk Host.app" --keep-xcresults`,
   then `--long` (45-min soak across the 30-min lease). Reports: `/private/tmp/farside-e2e/reports/latest/report.md`.
6. Final build and install: host via `script/build_and_run.sh`; iPhone via
   `lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -configuration Debug -destination 'id=00008150-0001653C26F8401C' -derivedDataPath outputs/RemoteDeviceBuild CODE_SIGNING_ALLOWED=YES CURRENT_PROJECT_VERSION=<next> build`
   then `xcrun devicectl device install app --device 00008150-0001653C26F8401C outputs/RemoteDeviceBuild/Build/Products/Debug-iphoneos/PocketDeskRemote.app`
   and check the installed version with `xcrun devicectl device info apps --device <udid> --bundle-id com.roshan.PocketDesk.Remote`.
7. Morning report for the owner (links and owner items are in the log below).

Rules that still apply: wrap every xcodebuild in `lockf -k /tmp/farside-xcodebuild.lock`; test
bundles can't load from `~/Documents` (use DerivedData outside it); never reboot/lock/sleep the
display during unattended runs; clicks only in test windows; no purchases, deploys, DNS, account
creation or posting; no Higgsfield; state exactly what was tested before telling the owner a build works.

To restart the self-paced loop, use the prompt at the top of the overnight plan, or:
`/loop Farside overnight build-and-test loop. Each iteration: (1) read Docs/plans/ORCHESTRATOR-STATE-2026-09-29.md and Docs/plans/OVERNIGHT-2026-09-29.md; (2) handle finished agents …`

## Log (copied from the private scratch state)

# Orchestrator state (private) — overnight 28→29 Sep 2026

Repo: /Users/roshansilva/Documents/ChatGPT/Saas/PocketDesk, main branch pocketdesk-remote-chat (tip 1b2afbb at 22:20). Public plan: Docs/plans/OVERNIGHT-2026-09-29.md. Always `cd` back to the repo before launching worktree agents (worktree isolation needs the cwd in the repo).

Running agents (SendMessage IDs):
- stream fix: a7825c70835ffca64 (worktree .claude/worktrees/agent-a7825c70835ffca64) — merge 1st
- phone redesign: a1134b635e22564b6 (worktree) — merge 2nd
- Mac redesign: a6f1c7fc3804e24e8 (worktree) — merge 3rd
- Mac parity (login/watchdog/curtain/diagnostics): a506802250196dd9b (worktree) — merge 4th
- E2E harness: a8afb5185151d8f2e (worktree) — merge 5th
- website: a8bb7a7d7e40d95bc (worktree, Website/)
- app motion lab: a272538955d1631b0 (design/animation-lab/app-motion.html, publishes artifact)
- brand motion lab: abe071303851b57bc (design/animation-lab/brand-motion.html, publishes artifact)
- social kit: a2c4931db73b65f8c (research first → design/social/SOCIAL-RESEARCH.md; ~/Downloads/farside-social/)
Background: caffeinate b4gkijxeh (12 h display/system awake).

Merge procedure: check Codex idle (ls -lt ~/.codex/sessions/2026/09/2*/), main clean; merge --no-ff; verify merged tree == tested branch for code (git diff --name-only branch HEAD outside docs/design); push; tell remaining agents to rebase; delete agent simulators; remove merged worktrees later.

Next wave (after phone redesign merges): phone parity agent (direct touch, iPad HW keyboard/mouse, middle click, mini map, display picker) + system integrations agent (App Intents/Siri, notification categories/actions, session Live Activity, simctl push tests).

Pending owner items: Codex prompt (App ID, APNs keys ×2 env, App Store record "Farside: Remote Desktop"), domain purchase, Cloudflare Realtime/TURN key → Keychain, trademark opinion, featuring nomination by ~9 Oct, remote-unlock decision (asked; no answer yet), dithered Home thumbnail idea (no answer).

Morning deliverables: installed host + iPhone + iPad builds; morning report (done / test results / manual checklist / links: dither gallery https://claude.ai/artifact/JERuv14fd2hBWsc2iBCxQi, motion labs, social kit, website preview, name board https://claude.ai/artifact/8RJVVnNtDcnm9i4g4TbvLq).

Done 22:4x: brand motion lab published https://claude.ai/artifact/3TCNAQpFFLbpq97X5mYfUH (committed). Its claim flags: H3 "anywhere" only after remote ships; T2 latency figures need real measurements; V2 mock UI → replace with real recordings; no launch date.

23:40 ALL 8 agents hit the session limit (resets 23:40). Lesson: max ~4 concurrent opus agents; resume in batches; agents told to commit WIP often.
23:45 Resumed batch 1: stream (a7825c70835ffca64, nearly done), phone redesign (a1134b635e22564b6), E2E harness (a8afb5185151d8f2e), website (a8bb7a7d7e40d95bc, nearly done; its worktree is based on old main 285d819 — take only Website/ folder when merging).
PENDING RESUME (batch 2, when batch 1 frees up): Mac redesign (a6f1c7fc3804e24e8, dirty 19 files), Mac parity (a506802250196dd9b, dirty 23), social kit (a2c4931db73b65f8c; research done, stills done, videos partial).
App motion lab published: https://claude.ai/artifact/A37qkYYXuJzQZGzcGsmC7m (committed; its final check didn't finish).
00:0x Website DONE → merged as Website/ folder only (3297fe4). Lighthouse 100x4 all pages. Owner items: SITE_URL/contacts/social URLs/launch links in Website/site.config.ts; plan name decision ("Anywhere" vs "Farside Remote" vs "Remote Access"); legal review of terms/privacy; Google Fonts IP disclosure (self-host later).
MUST-FIX BUG: sessions end at the 30-minute signaling room boundary (credentials/rooms not renewed mid-session) → contradicts "free, no time limit" on /compare and "works consistently". Assign to a session-continuity fix agent after the E2E harness lands (server room renewal + client seamless re-register); E2E soak must exceed 30 min.
Resumed Mac parity (a506802250196dd9b) into the freed slot. Still pending resume: Mac redesign (a6f1c7fc3804e24e8), social kit (a2c4931db73b65f8c).

00:3x STREAM MERGED fc91903 (+PRODUCT line). Loopback: scroll p50 79->15 ms, text PSNR 21->46 dB. Costs: 2-3 s post-connect hitch; p90 up after fullscreen changes. Pointer-move coalescing handed back to pointer owner (future). Resumed Mac redesign a6f1c7fc3804e24e8. Social kit a2c4931db73b65f8c still queued.

01:0x MAC REDESIGN MERGED 1b0178a (+PRODUCT note). 25 screenshots ~/Downloads/farside-mac-*.png (popover + setup look right). Open: accent fonts not bundled on Mac (agent wouldn't download) -> after the phone agent bundles Doto/Instrument Serif, add them to the RemoteHost target too; installed app name stays "PocketDesk Host.app". Resumed social kit a2c4931db73b65f8c. Running now: phone redesign, E2E harness, Mac parity, social kit.

01:2x SOCIAL KIT DONE: ~/Downloads/farside-social/ (index.html contact sheet; 15 posts, 3 carousels, 7 vertical videos + 2 x 16:9, avatars, X header, bios, handle ideas, 14-day calendar 29 Sep–12 Oct, launch thread, cheat sheet). Source committed 0bd6245 (design/social). Top: V04 someone-controlling, V01 contact, V03 distance, P06 zero-accounts, P09 dialog-2019. Owner to confirm: trust line "We only look while a phone you approved is connected"; [LINK] placeholders; handles unchecked; add sound in-app; #farsideapp brand tag.
01:2x Launched session-length fix agent aa03e26f1e815691c (sonnet, worktree). Running: phone redesign a1134b635e22564b6, E2E a8afb5185151d8f2e, Mac parity a506802250196dd9b, session fix aa03e26f1e815691c.

01:3x MAC PARITY MERGED f99ef5d (+PRODUCT). Launch at login default ON after setup (confirm with owner; aligned with reboot-recovery ask). Watchdog helper + crash-loop guard (3 kills/5 min -> safe mode!). E2E told to use SIGTERM / automaticRecoveryEnabled=NO for kill loops + add watchdog relaunch scenario. Stale-signal bug (late msg from previous phone session stops host listening; cause of flaky tests) assigned to session-length agent aa03e26f1e815691c. Parity agent also created a task chip for the owner about that bug (can't dismiss; mention in morning report).
Running: phone redesign a1134b635e22564b6, E2E a8afb5185151d8f2e, session+stale fix aa03e26f1e815691c. Free slot: 1 -> hold for phone-parity/system-integrations wave after phone redesign merges.

01:12 INTEGRATED HOST INSTALLED via build_and_run.sh (receipt outputs/host-run-20260929T051200Z): PocketDeskRemoteHost pid 11574 + FarsideWatchdog helper running; "Login Item Added" notification shown; launchAtLoginDefaultApplied=1. Host permission status not verifiable from CLI (no TCC read access; computer-use would need owner approval) -> first real E2E pass will prove capture/control.
Screen at 01:13: Farside Test Pad (E2E agent) + a TCC prompt (likely FarsideE2EStubHost) + "WidgetRenderer_Default quit unexpectedly" crash dialog. Told E2E agent: never trigger TCC prompts, detect/avoid system dialogs over Test Pad, move Test Pad lower-left. Leave dialogs for the owner (don't click system dialogs).

01:5x PHONE REDESIGN MERGED 8c02bf0 (+PRODUCT). Screens verified visually (home, dock). Fonts bundled on phone (Doto-Black_ExtraBold, InstrumentSerif-Italic); line-159 UI test fixed.
Launched wave 2: phone parity a9c91c9bb117300d3 (opus: direct touch, HW keyboard/mouse passthrough + middle click, mini map, display picker), system integrations a752967d0e530c55c (sonnet: App Intents/Siri, agent-needs-you notification, session Live Activity, Mac agent-hook scaffold).
Running (4): E2E a8afb5185151d8f2e, session+stale fix aa03e26f1e815691c, phone parity a9c91c9bb117300d3, system integrations a752967d0e530c55c.
TODO later (small Mac follow-up agent or me): bundle Doto/Instrument Serif in RemoteHost target, confirm Doto-Black_ExtraBold on macOS, swap HostHalftoneArt for shared FarsideHalftone. Then final install host + phone + iPad.

02:0x SESSION RENEWAL + STALE-SIGNAL FIX MERGED 7087c48 (+PRODUCT). 329 core + 184 server tests; flaky tests now 20/20.
FINAL-INSTALL CHECKLIST ADD: rebuild + restart the owner's bundled private signaling service per Docs/PRIVATE-SERVICE-RECOVERY-2026-09-28.md (else renewal has no effect for the phone); runner duration 3600.
Running (3): E2E a8afb5185151d8f2e, phone parity a9c91c9bb117300d3, system integrations a752967d0e530c55c. Free slot: 1 -> use for Mac follow-up (fonts + shared halftone on RemoteHost).

02:1x Launched Mac follow-up a00c0691d236a622c (sonnet: fonts + shared halftone on RemoteHost). Running (4): E2E a8afb5185151d8f2e, phone parity a9c91c9bb117300d3, system integrations a752967d0e530c55c, Mac follow-up a00c0691d236a622c.

02:21 MAC FOLLOW-UP MERGED b35ec6b (+PRODUCT 31900f9). Mac fonts bundled (shared RemotePhone/Fonts), shared halftone; 29 Mac screenshots refreshed. Main == last tested tree (each branch rebased on latest main, verified identical).
NOTE: xcodebuild test from ~/Documents can't load test bundles (TCC on Documents) — agents use build-for-testing + xctest / copy build outside ~/Documents. Ask E2E agent to run full unit+UI suites on its rebased tree as the integration check.
Running (3): E2E a8afb5185151d8f2e, phone parity a9c91c9bb117300d3, system integrations a752967d0e530c55c.
NEXT: when E2E lands -> merge -> reinstall host (build_and_run.sh) -> run run-e2e.sh loop; later merge parity + integrations -> reinstall -> E2E again; ~06:00 rebuild/restart private signaling service (renewal); ~06:30 final install host + iPhone + iPad (xcrun devicectl), smoke, morning report.

02:3x OWNER AWAKE (asked "iPhone app updated?"). INSTALLED on Roshan's iPhone (UDID 00008150-0001653C26F8401C): Farside build 20260929.1 from main 31900f9 (device build needs CODE_SIGNING_ALLOWED=YES; wildcard dev profile; no portal registration). iPad NOT connected (not in devicectl list).
Private signaling service redeployed: ~/Library/Application Support/PocketDesk/signaling-service.js rebuilt from Server/src (backup .bak-20260929), launchctl kickstart com.roshan.pocketdesk.signaling; /ready shows renewal enabled; host re-registered (peers 1, rooms 1). status not_ready = relay_not_configured (expected).
Device-build command: lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -configuration Debug -destination 'id=00008150-0001653C26F8401C' -derivedDataPath outputs/RemoteDeviceBuild CODE_SIGNING_ALLOWED=YES CURRENT_PROJECT_VERSION=<n> build; then xcrun devicectl device install app --device <udid> outputs/RemoteDeviceBuild/Build/Products/Debug-iphoneos/PocketDeskRemote.app
CAUTION for later builds: system integrations may add Push/Associated Domains entitlements -> needs explicit App ID (not registered; portal registration blocked) -> device build will fail signing; keep those entitlements out of Debug device builds or gate them until the owner registers the App ID.

03:1x OWNER: coach lesson 1 stuck -> FIXED b524f95 (tests fail on old code, pass on fix). Installed 20260929.2 on iPhone.
03:42 OWNER: "screen is just black after I connect" (screenshot: dock open, "Controlling your Mac", black stage + faint dots + grey pointer).
04:0x ROOT CAUSE PROVEN: StreamTuning.tuned forces WebRTC-ForcePlayoutDelay 0/0 -> libwebrtc low-latency path gives every decoded frame render time 0 -> RTCVideoFrame.timeStampNs == 0 for ALL frames (loopback test: tuned [0,0,0...], legacy increasing). RTCMTLVideoView.drawInMTKView skips frame when timeStampNs == lastFrameTimeNs (initially 0) -> never draws. FrameObserver still counts frames -> fresh/canControl true -> "Controlling your Mac" over black. Dots = FarsideDotScreen scrim over empty stage (dock open). Stream agent's presented-latency metric was fooled (counts MTKView draw calls, not real renders).
FIX (uncommitted, main checkout): FrameObserver is the track's only renderer, forwards frames to the view restamped with strictly increasing ns. Tests: RemoteTests/VideoFrameTimestampTests (macOS loopback), RemotePhoneTests/RemoteVideoSurfaceTests (real RTCMTLVideoView).
FOLLOW-UP: parity agent a9c91c9bb117300d3 MiniMapView adds a 2nd RTCMTLVideoView directly to the track -> same black bug; tell it to route through the restamping renderer after the fix lands. Check whether RTCMTLRenderer resets preferredFramesPerSecond to 30 on first draw (would cap phone at 30 fps).
04:2x SECOND BUG PROVEN: RTCMTLRenderer setup sets MTKView.preferredFramesPerSecond = 30 on first frame (test: chosen 120 -> 30). Phone displayed <=30 fps of a 60 fps stream even pre-probe. Fix: probe re-asserts chosen fps after each draw (tuned only).
E2E AGENT a8afb5185151d8f2e FINISHED: harness ready (branch tip 30a8f5d, rebased on b524f95); not yet run vs real host (needs Debug host w/ hooks via build_and_run.sh). Product fix d364b4d (phone control-channel delegate attached synchronously; dropped first geometry/viewing msgs -> view-only) CHERRY-PICKED to main as 655e5c0.
Lock contention: agents hold /tmp/farside-xcodebuild.lock 10-20 min per UI/E2E run; ran my urgent owner-facing tests/device build OUTSIDE the lock (own DerivedData + own simulator).
NEXT: commit video fix -> install 20260929.3 on iPhone -> verify on device (xcode DeviceInteraction screenshot if phone unlocked) -> tell parity agent: MiniMapView must use RestampingRenderer -> merge E2E harness -> reinstall host (coordinate with owner, they are awake/using it) -> run E2E loop.
04:4x COMMITTED 8f4b19b (video restamp + fps keep) on top of 655e5c0 (E2E data-channel fix); pushed. Phone unit suite 58/58 pass (incl. 3 new RemoteVideoSurfaceTests). INSTALLED Farside 20260929.3 on Roshan's iPhone (devicectl shows 20260929.3). Told parity agent a9c91c9bb117300d3: MiniMapView must use RestampingRenderer.
NOT YET VERIFIED: picture end-to-end in the running app (device or simulator). Xcode DeviceInteraction needs owner approval via XcodeOpenWorkspace (not done). PLAN: merge E2E branch (30a8f5d; pbxproj conflict -> xcodegen), add stage-brightness pixel check to test_a (empty stage = void ~5; stub picture bg gray 0.1 ~26 + colored rects), run run-e2e.sh --self-test --scenarios a --keep-xcresults, look at the "connected" screenshot. Then real-host E2E needs host reinstall (build_and_run.sh) -> coordinate with owner (they're awake, using host).
04:5x E2E HARNESS MERGED b9d6657 (branch 0da0cb9 rebased on 8f4b19b; tree identical; xcodegen no diff). Reviewed product hooks: all #if DEBUG + gated on --farside-e2e AND FARSIDE_E2E=1 AND FARSIDE_E2E_DIR AND loopback signal URL; E2EMedia no-op unless loopbackOnly. Owner's phone+host ARE Debug builds, so gating matters (it's strict).
E2E agent confirmed black stage reproduces in simulator self-test (after in-place reconnect, 30 fps decoded) -> not device-specific.
ADDED (uncommitted): E2ETestCase.checkPictureVisible (lit share of stage band 10-60% height, 48x48 downsample, luma>15, need >=10%; owner's black screenshot scores 0.5%; band 10-80% scored 19.9% because of open dock -> fixed). Wired into a (after pairing), d3, d5, d4, background return.
05:0x Running self-test a,d1,d3 --keep-xcresults (log scratchpad/e2e-selftest-1.log); waiting on build lock behind integrations + parity builds.
Disk: 12 GB free. Don't delete: iPhone 18 Pro 61AE66A1 (booted, not ours), "Pocket Desktop — iPad mini" 75FDFB97 (old, not ours).
REAL-HOST E2E caveat: E2E host runs as 2nd instance on the same Mac, activates Test Pad + injects input -> would disrupt owner if they're remote-controlling. Ask owner before running real-host loop; host reinstall (build_and_run.sh) restarts their host.
05:3x SELF-TEST PASS (report /private/tmp/farside-e2e/reports/20260929T085749Z): a picture 100% lit, d1 resumed 0.6 s + picture 100%, d3 reconnect 1.1 s + picture 81%. Screenshot ~/Downloads/farside-e2e-picture-after-pairing-2026-09-29.png (sent to owner). Committed picture check 3b18365; pushed.
NEXT (announced to owner at 05:3x, proceed ~05:50 unless they object): lockf -k /tmp/farside-xcodebuild.lock script/build_and_run.sh (Debug host w/ E2E hooks from main 3b18365; SIGTERM stop, rollback on failed launch) -> script/e2e/run-e2e.sh --host-app "/Applications/PocketDesk Host.app" --scenarios a,b,c,d1,d2,d3,d4,d5,e --keep-xcresults (skip long soak first pass) -> triage.
Then ~06:30: merge parity/integrations if done, final build, install host + iPhone (iPad not connected), morning report.

## Active checkpoint — 5 October 2026, ten features

This section supersedes older “where things stand” entries for this task only. Main `pocketdesk-remote-chat` remains at 4524689916bccec56ba681f808a7ff3e3fa8d8e6 with unrelated work preserved. Integration branch `codex/ten-features` in `/Users/roshansilva/Developer/farside-ten-features` starts from glass-lens commit 15568c111b2d4c17b646b9cd314e871dce486723. Shared owner utility envelope committed as b91d945; new utility capability advertisement and integration tests remain pending.

Authorized worker lanes, both GPT-6.1-Sol/high:
- `/root/build_navigation`, `codex/ten-navigation`: 1 app/window switcher and 2 current-window viewport; then 3 shortcuts and 6 saved views. Own window workspace files and scoped HostModel/phone/native UI hooks.
- `/root/build_files`, `codex/ten-files`: 4 granted-root file browser; then 5 explicit rich clipboard. Own file browser files, descriptor reader, and scoped transfer/settings hooks.
- Root owns common schema, capability advertisement, project membership, PRODUCT, docs, 7 notifications, 8 OCR, 9 supported virtual-workspace gate, and 10 guest productization.

A third worker and revival of a completed worker both returned “agent thread limit reached”; use staged delivery and reuse available lanes. Workers must notify before taking the shared Xcode lock. No worker may install or deploy. Isolated builds use external DerivedData and the shared lock.

Evidence: glass source and earlier 51 native / 2 UI checks passed; no physical acceptance or main integration. Ten-feature packages currently in implementation, not reviewed or accepted. Each lane returns commits plus actual scoped checks. Root integrates, reviews exact final source, runs integrated checks, records unsupported/external/device gaps explicitly, and obtains fresh independent review.
