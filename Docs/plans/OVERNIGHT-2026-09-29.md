# Overnight run — 28→29 Sep 2026

Owner (Roshan) is asleep; manual testing starts first thing in the morning. Mandate: keep building and testing in a loop until the app works consistently; match or beat Astropad Workbench; haptic, fun, native-fast feel; best-possible website SEO; social media kit for X, Instagram + Threads and TikTok researched first and made from our own design (no Higgsfield).

## Owner answers (28 Sep, ~22:15)
- "Rebutting" = both reconnecting (drops, app switches, backgrounding) and recovering after a Mac restart. Simulate restarts by quitting/relaunching the host — never reboot the Mac.
- Real-Mac end-to-end tests are allowed: the simulator may drive the real Mac (pointer, clicks/typing inside dedicated test windows only, full-screen/Space switching restored afterwards). Mac left unlocked, awake, plugged in. `caffeinate -dimsu -t 43200` is holding the display awake (screen lock is "immediate" on display sleep).
- Social platforms: X, Instagram + Threads, TikTok.
- Install the final build on the iPhone and iPad (left plugged in) plus the Mac host.
- No more Higgsfield spend.

## Hard limits
Never reboot, log out, lock the screen or sleep the display; never touch the owner's documents/apps; no purchases, deploys, DNS, account creation or posting; bundle IDs, PRODUCT_NAME, signing and install paths unchanged; installs only via `script/build_and_run.sh` from the integrated main checkout; xcodebuild wrapped in `lockf -k /tmp/farside-xcodebuild.lock`.

## Work in flight
| Workstream | Output | Merge order |
|---|---|---|
| Stream fix (per-stage timing, zero receiver smoothing, bitrate ramp, encoder tuning) | branch | 1 |
| iPhone/iPad Reach redesign + motion/haptics | branch | 2 |
| Mac companion Reach redesign | branch | 3 |
| Mac parity: launch at login, watchdog + crash-loop guard, privacy curtain, diagnostics | branch | 4 |
| End-to-end harness: Test Pad fixture, DEBUG-only E2E hooks, XCUITest scenarios, soak | branch | 5 |
| Website (static, Cloudflare Pages) + SEO pages + Lighthouse on every page | `Website/` | any |
| App motion lab, brand motion lab | artifacts | — |
| Social kit (research first) | `design/social/`, `~/Downloads/farside-social/` | — |

Next wave after the phone redesign merges: phone parity (direct-touch mode, iPad hardware keyboard + mouse/trackpad passthrough, middle click, iPad mini map, display picker) and system integrations (App Shortcuts/Siri intents, time-sensitive "agent needs you" notification with actions, session Live Activity; tested with `xcrun simctl push`).

## Test loop
1. Merge a finished branch → `xcodegen` → build host + phone → run RemoteTests, RemotePhoneTests, RemotePhoneUITests (serially).
2. Install the integrated host with `script/build_and_run.sh` (identity guard preserved).
3. Run `script/e2e/run-e2e.sh --repeat N` (pair, connect, pointer/click/drag/scroll/zoom, typing/modifiers, clipboard, background 5 s/60 s, host kill/relaunch, signaling restart, full-screen Space switching, 20-minute soak).
4. Triage failures → fix on a branch → merge → repeat.
5. ~06:30: final build → install host, iPhone, iPad → smoke test → morning report.

## Workbench parity tracker (see Docs/BENCHMARK-WORKBENCH-2026-09-28.md)
Done/merged: big phone-drawn pointer (beats), click haptics (beats), clipboard sync, background grace + auto-reconnect, display-sleep reachability, voice dictation, fullscreen immersive session, gestures incl. Mission Control/Spaces, no-account pairing (beats).
Tonight: stream latency/quality, Reach redesign + gesture coach, launch at login + watchdog, privacy curtain, diagnostics, direct-touch mode, iPad keyboard/mouse passthrough, middle click, iPad mini map, display picker, Siri/App Shortcuts, agent-alert notification, session Live Activity.
Blocked on owner: deployed relay (domain + Cloudflare TURN key), APNs key, persistent-capture entitlement (website + App Store record).
Post-launch per research: HEVC/4:4:4, custom codec, virtual/unified display, PiP, embedded chat viewer.
