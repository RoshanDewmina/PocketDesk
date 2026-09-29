# Farside system integrations: report

29 Sep 2026. The 1.0 system integrations for the iPhone/iPad app (`PocketDeskRemote`, shown as Farside): App Shortcuts and App Intents, "agent needs you" notifications, the session Live Activity, and the Mac-side scaffold that feeds alerts to the phone. Branch `worktree-agent-a752967d0e530c55c`, rebased onto `pocketdesk-remote-chat` at `31900f9`. The build follows `Docs/research/2026-09-28-round2/SYSTEM-INTEGRATIONS.md` (sections 2 to 6) and `PHONE-AND-AGENT-GAPS.md` section 5, in the Reach look of `design/FARSIDE-DESIGN-SYSTEM.md`.

Evidence levels: simulator builds, unit tests, UI tests, SpringBoard tests on an iPhone 17 Pro simulator (iOS 27.0, Xcode 27.0 27A266a), and macOS tests. Nothing here is a physical-device result, and no real push was sent: there is no APNs key yet.

## What shipped

**1. App Shortcuts and App Intents** (`RemotePhone/SystemIntegrations/FarsideIntents.swift`)

| Intent | Runs | Authentication | Says |
|---|---|---|---|
| Connect to Mac | in the app, foreground | required (unlocked phone) | "Connecting to <Mac>." |
| Is my Mac awake? | in the background | required | whether the Mac's Farside answered, honestly: "It may be asleep, off or offline." |
| End session | in the background | none: it only moves toward safety | "Session ended." / "There is no open session." |

- **Mac parameter.** `MacEntity` with an opaque id (`m_` plus 16 hex of a SHA-256 of the room, never the room or key). With one paired Mac nothing is asked; with several and none named, Siri or Shortcuts ask "Which Mac?" (`requestDisambiguation`). Names come from the Keychain pairing, so the intents work before the app has run this launch.
- **Phrases.** Every phrase carries `\(.applicationName)`, names no other product, and Siri replies carry no app name and no humor: "Connect to my Mac with Farside", "End my Farside session", "Is my Mac awake in Farside", and the `\(\.$mac)` variants. Tile colour tangerine. App Shortcuts are what Spotlight, Shortcuts and the Action button offer for an app; whether the system has indexed them, and how Siri hears the phrases, needs a phone (see "Still needs").
- **Authentication policy is checked from the build output,** not from the source: a unit test reads the extracted `Metadata.appintents/extract.actionsdata` and asserts policy 1 for Connect and Is-my-Mac-awake and 0 for End session, and the `supportedModes` of each.
- **No intent grants the phone any authority on the Mac.** Nothing types, clicks, launches an app or runs a command. `Is my Mac awake?` registers as a client on the signaling service like a real phone and reads the answer (`MacReachabilityProbe`), then leaves; it never opens media.
- **Wiring.** Connect posts to a request inbox that the Home screen drains through the same path as the Connect button (including the one-time Local Network explanation). End goes through `SessionIntentBridge` to the model's own `disconnect()`, and always ends every session activity even when the app model is not there.

**2. "Agent needs you" notifications** (`AgentNotifications.swift`, `AgentAlertCenter.swift`, `FarsideAppDelegate.swift`, `AgentAlertViews.swift`)

- **Category `AGENT_HELP`:** two background actions, "Snooze 15 min" and "Not now" (neither opens the app, neither is destructive or authentication-required); `.customDismissAction`; hidden-preview placeholder "An agent needs you." with the title still shown. Snooze schedules one passive local reminder (`AGENT_HELP_REMINDER`, whose only action is Not now); a second Snooze is quietly a dismissal.
- **Time Sensitive is entitlement-only** (`UNAuthorizationOptionTimeSensitive` is deprecated). The Focus switch says "Not available in this build" when iOS reports no support after permission is answered, and the default delivery is `.active`. It becomes `.timeSensitive` only when the person turns "Break through Focus" on in a build that has the entitlement.
- **Tap routing.** A tap opens an alert sheet for that request (`agent.alert.sheet`), never a connection: routes are navigation only. Routes: `farside://help/<id>`, `farside://open[/<id>]`, `farside://session`, and `https://<associated host>/open[/<id>]` (the Associated Domains entitlement is declared, domain TBD). A wrong-category or malformed-id payload routes nowhere.
- **Permission priming in the Reach style** reuses the existing `PermissionPrimingView` with a new `notifications` kind ("Know when it needs you."). iOS is asked only after the person turns Agent alerts on in Home, "Alerts & Lock Screen", never at launch, and never provisional.
- **Payload handling** follows section 4.2 of the research: the parser reads the category, `hid` and an allow-listed agent name from `title-loc-args`; no text from a payload ever reaches the screen (a compromised agent cannot write on a lock screen). Copy lives in `en.lproj/Localizable.strings` as `AGENT_NEEDS_YOU_TITLE` and friends, which is also what a push's `title-loc-key` names.
- **Sample pushes** in `script/push-samples/`: `agent-needs-you.apns`, `agent-needs-you-active.apns` (Codex, active level), `agent-needs-you-unknown-agent.apns`, `agent-snooze-reminder.apns`, and two that must not route (`agent-malformed-id`, `agent-wrong-category`). `send.sh <sample>` pushes one to a booted simulator; `verify-routing.sh <udid> <derived data> [sample[:actions] ...]` starts a UI test that waits, pushes each sample with `xcrun simctl push`, taps the real banner and asserts the sheet (or the absence of one). `<sample>:actions` runs a second test that long-presses the banner and asserts that Snooze and Not now are offered and open nothing; it had not run when work stopped.
- **From a live session.** When the Mac reports an alert while a session is open, it arrives as an optional `agentAlert` on the `capture` status message (a kind, a request id, an event name, a time: no words). With the app in front it is one quiet banner over the picture; with the app holding the session in the background it becomes the local notification a push would have been. Repeats are announced once, declined ones never again, and an event or version this phone does not know is ignored (a newer Mac cannot end an older phone's session with a new word).

**3. Session Live Activity** (`FarsideWidgets/` extension `com.roshan.PocketDesk.Remote.Widgets`, `SessionActivityMachine.swift`, `SessionActivityController.swift`)

- **States.** Live (ember dot, time held), Paused (pause glyph, countdown to when Farside lets go, from a real deadline), Reconnecting, and the ended states (user, timeout with a Reconnect button, Mac stopped, error), plus a stale look ("Session ended?"). Lock Screen and StandBy, Dynamic Island compact, minimal and expanded. Ember only on the live dot and the End button. The wording is the house voice ("Holding your Mac", "Mac on hold: Farside lets go soon. Come back and it never happened.").
- **What it never carries.** No screen content, prompts, file names or latency. The Mac's name shows only if the person turns "Show Mac name" on; the default is "Your Mac". Times are computed by the system from dates in the state, so a phone off the network keeps the right clock.
- **Lifecycle.** Started after the handshake, moved through Live, Paused and Reconnecting by the session model, ended with the reason. It is derived only from a small snapshot the person could see (connected, reconnecting, background hold deadline, coarse route word, end reason). **Renewals are invisible:** the room lease renewal, the relay credential refresh and the Mac's ICE restart from the merged session-renewal work change none of those fields, so they cannot move the Lock Screen; "Reconnecting" appears only when the phone's own automatic reconnect engages after a live session dropped, after a 1.5 s debounce so a blip never shows. Tests pin both.
- **Stale dates.** Live goes stale 180 s after its last refresh and the running app refreshes it every 60 s; Paused goes stale 5 s after its deadline; Reconnecting after 120 s. An app that died therefore never leaves a frozen "Live" on the Lock Screen. Ended activities stay 6 s after the person ended it and 90 s otherwise.
- **End button.** `EndSessionIntent` is a `LiveActivityIntent`, which the system runs in the app's process, so it works from a locked phone. It releases the Mac and ends the activity, and it ends every session activity even when the model is not there. No App Group and no shared storage are needed.
- **The system asks twice.** The first time an app starts a Live Activity, iOS shows "Allow Live Activities from Farside?" on the Lock Screen, and later "Do you want to continue to allow Live Activities from Farside?" with Always Allow. These are the system's questions, remembered per app, and the UI tests answer them.
- **Preview.** Settings, "Preview Live Activity" starts a labelled sample ("SAMPLE · PREVIEW") that connects to nothing and never starts over a real session.
- **Push.** Not requested (`pushType: nil`). See "Still needs" for what a Live Activity push adds.

**4. Mac-side scaffold** (`script/agent-hooks/farside-notify`, `RemoteHost/AgentAlert*.swift`, `HostAgentAlerts.swift`)

- **`farside-notify`** is a POSIX shell script an agent's hook calls. It reads the hook JSON on stdin, decides whether the event is blocking (Claude Code `PermissionRequest`, and `Notification` of type `permission_prompt`, `elicitation_dialog` or `elicitation_url_dialog`; Codex `PermissionRequest`), and sends **only** `{"agent":{"kind","sessionHash"},"type":"needs_user"}`. The session hash is the first 12 hex of a SHA-256 of a namespaced session id, so repeats collapse and the id never leaves the script. It prints nothing (a permission hook's output can be read as a decision), always exits 0 (it can never block or steer an agent; `--strict` changes only the exit status), and hands the token to `curl` on stdin, never in the argument list where `ps` could read it. `--dry-run`, `--verbose`, `--print-hooks claude-code|codex`, `--help`.
- **The bridge** is a loopback-only listener (127.0.0.1, random port). Every request needs the per-install 256-bit token (constant-time compare); the port and token live in `~/Library/Application Support/Farside/agent-bridge.json` (mode 0600, in a 0700 folder). A wrong `Host` (DNS rebinding) or any browser header (`Origin`, `Sec-Fetch-*`) is refused, one strict request shape is accepted (small, no chunking, no pipelining, read deadline, connection cap), and the body is read only for a kind, a hash and an event name. The agent's own words are never read, stored or forwarded.
- **The Mac side** (`HostAgentAlerts`): off by default, with two rows in Settings under General: the "Agent alerts (beta)" switch, and once it is on an "Agent hooks" row with "Copy Setup" and "Reset" (a new link token; old hooks stop working). A 60 s per-session cooldown and six alerts an hour. With a phone in a live session the alert goes over the existing control channel; otherwise it would go out as a push, which is a stub that says why it cannot (`UnconfiguredAgentPushRelay`). Settings shows the last result in plain words ("Claude Code asked 2 min ago · told your iPhone").
- **Hook setup.** "Copy Setup" copies the exact JSON to add to `~/.claude/settings.json` and to `~/.codex/hooks.json` (Codex has no Notification event, so its file has only the permission request). The script is first copied to `~/Library/Application Support/Farside/farside-notify`, so an agent's configuration keeps working when the app is updated or moved. Nothing is ever written to an agent's configuration by Farside.

## Building for a device with Xcode's wildcard profile, and turning push on

The owner's iPhone is signed with the wildcard development profile, which cannot carry Push Notifications, Time Sensitive, Associated Domains or App Groups. So **none of those entitlements is in a normal build**: `RemotePhone/Farside.entitlements` is applied only when `FARSIDE_ENABLE_PUSH=YES` (default `NO`, `project.yml`). Everything else builds, signs and installs on the wildcard profile: App Intents and App Shortcuts, local notifications and the test alert, the Live Activity through ActivityKit without push, and the widget extension (child bundle ID `com.roshan.PocketDesk.Remote.Widgets`, automatic signing, team `39HM2X8GS6`). Without the entitlements the app degrades honestly: the Focus switch says "Not available in this build", and registering for remote notifications fails quietly (the phone keeps no token and shows no error).

Device-style build, no `-allowProvisioningUpdates`:

```
lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote \
  -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/farside-integrations-dd CODE_SIGNING_ALLOWED=YES build
```

Turning push on, in this order:
1. Apple Developer portal: register an explicit App ID `com.roshan.PocketDesk.Remote` (team `39HM2X8GS6`) with **Push Notifications**, **Time Sensitive Notifications** and **Associated Domains**. Live Activities need no capability, only the `NSSupportsLiveActivities` key already in `Info.plist`. For TestFlight or the store, register `com.roshan.PocketDesk.Remote.Widgets` too (automatic signing does it).
2. Choose the public domain, then replace `farside.example` in `RemotePhone/Farside.entitlements` and `FarsideRoute.associatedHosts` together, and serve `https://<domain>/.well-known/apple-app-site-association` (no redirect, `application/json`):
   ```json
   {"applinks":{"details":[{"appIDs":["39HM2X8GS6.com.roshan.PocketDesk.Remote"],"components":[{"/":"/open/*"}]}]}}
   ```
3. Create an APNs auth key (`.p8`) for sandbox and production. Keep it on the push service, never in the repo or the app.
4. Build with `FARSIDE_ENABLE_PUSH=YES` and `-allowProvisioningUpdates`. A simulator build with ad-hoc signing (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- FARSIDE_ENABLE_PUSH=YES`) proves the entitlements are embedded without a profile; a device needs step 1.
5. Keep the widget extension's `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION` in `project.yml` equal to the app's: App Store validation compares them.

## Verification

Two trees were tested: the branch on its old base (`31900f9`, "before"), and after the last rebase onto `3b18365`, which added the E2E harness ("after"). The rows say which. Runs used a dedicated iPhone 17 Pro simulator (iOS 27.0), every `xcodebuild` inside `lockf -k /tmp/farside-xcodebuild.lock`, one derived data folder outside `~/Documents`, and the raw run summaries are in `design/system-integrations/evidence/`. `script/verify-system-integrations.sh` repeats all of it.

| Check | Tree | Result |
|---|---|---|
| `xcodegen generate` | after | project in sync with `project.yml` (no diff) |
| Device-style build: `xcodebuild -scheme PocketDeskRemote -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=YES build`, no `-allowProvisioningUpdates` | after | **BUILD SUCCEEDED.** Signed with `iOS Team Provisioning Profile: *` and Apple Development (2X93YVJ4G4). The app's entitlements are `application-identifier`, `team-identifier` and `get-task-allow`, nothing more; `PlugIns/FarsideWidgets.appex` (`com.roshan.PocketDesk.Remote.Widgets`) is embedded and signed with the same profile; `NSSupportsLiveActivities` and the `farside` URL scheme are in the Info.plist (`evidence/device-build-signing.txt`) |
| The opt-in flag | before | `-showBuildSettings`: `CODE_SIGN_ENTITLEMENTS` is empty by default and `RemotePhone/Farside.entitlements` with `FARSIDE_ENABLE_PUSH=YES` (`evidence/push-flag-build-settings.txt`). Not built with the entitlements on a device: that needs the App ID |
| Mac host build (`PocketDeskRemoteHost`) | after | BUILD SUCCEEDED; `farside-notify` is in `Contents/Resources/agent-hooks/`, mode 755 |
| `RemotePhoneTests` | after | **173/173** (168/168 before; 115 tests are new in this branch) |
| macOS `RemoteCoreTests` | after | **412 executed, 3 skipped, 0 failures** (58 are new: gate, HTTP parser, listener, the script run for real, frame validation, `HostAgentAlerts`, and an alert over a real WebRTC control channel). Run with `xcrun xctest` on the built bundle, see below |
| `HostUISnapshotTests` | after | 15/15, including the new Mac Settings render |
| `SystemIntegrationsUITests` | before | 8/8: Home row, Settings sheet, priming screen, the alert sheet and Not now, Open your Mac connecting only after the tap, the banner over a session, and the real switch (priming, then iOS's question, then on and off) |
| Push routing (`script/push-samples/verify-routing.sh`) | after | `agent-needs-you.apns` **passed**: `xcrun simctl push`, the real banner, a tap, the alert sheet for Claude Code. The other samples (`-unknown-agent`, `-malformed-id`, `-wrong-category`) and the banner's Snooze and Not now actions had not run when work stopped |
| `LiveActivityUITests` (SpringBoard, env-gated) | before | Every state in the Dynamic Island, compact and expanded, with the right button (End session, or Reconnect after a timeout): pass. Every state on the Lock Screen: pass. **End session from the Lock Screen**: passed in one run (Live, then "Session ended", then gone within 6 s: `screenshots/farside-system-live-activity-end-*.png`) and failed in a later run on a machine at load 200, where the activity kept running after the tap; the test now waits 20 s and taps again. Not re-run |
| Whole phone UI suite | before | 31 tests: 6 skipped (env-gated), 23 passed, **2 failed**. Both are existing tests whose offline-fixture launch timed out on the loaded machine (`FarsideRedesignUITests.testDockOffersKeysMicClipFitModeSegmentsAndEnd` at 3 s + 5 s, `SessionLayoutTests.testViewportModeIsRememberedAcrossLaunches`). Not re-run, and not compared against the base |

What could not be verified here, and why:
- **macOS tests under `xcodebuild test`.** With derived data outside `~/Documents`, the test process could not read the repository (`Operation not permitted`), so `FarsideNotifyScriptTests`, the bun-based `SessionIntegrationTests` and `BrowserCryptoTests` failed there, and a crash inside one test hid the rest. The same built bundle run with `xcrun xctest` passes everything above.
- **AppIntentsTesting** (the iOS 27 way to run an intent through the system) refuses to run on a customer OS build ("Unable to run internal tests on a Customer build", error 803), so a UI test that drove the intents that way was removed. Intents are covered by 19 unit tests that call `perform()`, the extracted App Intents metadata, and the same inbox path the alert sheet's Open your Mac test exercises.
- **Spotlight.** A test that typed "Farside" into Spotlight never found the search field in the simulator, so whether the shortcuts appear there is unverified.
- The minimal island (needs a second app's activity) and the Always-On display.

## Screenshots

Cropped and downscaled copies are in `design/system-integrations/screenshots/`; full-size originals are in `~/Downloads/farside-system-<name>.png`. All are the iPhone 17 Pro simulator except the Mac render, which is `HostUISnapshotTests` drawing the real view offscreen.

- **Live Activity** (`farside-system-live-activity-…`): `<live|paused|reconnecting|ended>-lock-screen`, `<state>-island-compact`, `<state>-island-expanded`, and `end-1-before`, `end-2-after`, `end-3-gone` (End session from the Lock Screen). The sample carries its "SAMPLE · PREVIEW" tag. The Lock Screen and island images are from the final layout (title on its own row, a shorter paused line in the island); the End sequence is from the run that passed.
- **Notifications and alerts**: `alerts-settings`, `notification-priming`, `alert-sheet`, `alert-sheet-old`, `alert-sheet-test`, `alert-banner-over-session`, `push-routed-sheet` (from a real `simctl push`), `home-with-alerts-row`.
- **Mac**: `mac-agent-alerts` (Settings, General: the switch with the last alert's result, and the hook row).

## Still needs a real device, an APNs key or a domain

**A real iPhone**
- The Dynamic Island on hardware, the Always-On display (`isLuminanceReduced` paths), StandBy, and the minimal island beside another app's activity (the simulator cannot show two).
- The Lock Screen with a passcode: the simulator's lock has none, so "Connect to Mac" and "Is my Mac awake?" being refused on a locked phone (`.requiresAuthentication`) and "End session" running anyway are established from the extracted metadata, not from a locked device.
- Whether iOS wakes a suspended app to run `EndSessionIntent` at once from the Lock Screen (it did in the simulator, in a few seconds), and how long the End tap takes after a long hold.
- Siri recognising the phrases, Spotlight indexing the shortcuts, the Action button picker, and Shortcuts asking "Which Mac?" with two Macs paired.
- Notification delivery under Focus, Notification Summary and hidden previews on a locked phone.

**An APNs key** (and the service that holds it). What is missing, exactly:
1. The push service: a `PushRegistry` per room and `POST /v1/push/register` (section 6.3 of the research), storing the record `PushRegistrar.registration()` already builds (device token, environment, preferences, locale, build, OS; no Mac name, agent text or screen content).
2. An `agent_event` message on the Mac's host socket, and the relay that turns it into the `alert` push of section 4.2 (`apns-push-type: alert`, priority 10, `apns-collapse-id` from the session hash, expiration 15 minutes, topic `com.roshan.PocketDesk.Remote`). On the Mac, replace `UnconfiguredAgentPushRelay` (`RemoteHost/AgentAlertGate.swift`) with a relay that sends it; on the phone, replace `UnconfiguredPushSink` (`PushRegistrar.swift`) and the queued `AgentAlertReports` (the phone's answers: opened, snoozed, declined) with calls to the service. Until then Snooze is a local reminder and "Not now" is remembered on the phone only.
3. For Live Activity pushes (the "end while the phone is suspended" case): request the activity with `pushType: .token`, forward `pushTokenUpdates`, and send `apns-push-type: liveactivity` to topic `com.roshan.PocketDesk.Remote.push-type.liveactivity`. Not built: the session ends correctly today only while the app runs; a lost end is covered by the stale date, which turns a frozen "Live" into "Session ended?".

**A domain**
- The HTTPS origin for universal links and the service (step 2 above). Until then `farside://` links work and `https://` links are not claimed.

**The owner's Macs and agents**
- `farside-notify` was run against a real bridge with synthetic hook payloads, and the host code against a real WebRTC control channel, but not against a live Claude Code or Codex session. The owner should turn on "Agent alerts (beta)", paste the copied hook setup, and provoke one permission prompt in each agent (spikes S-HOOK-1 and S-HOOK-3 in the gaps document). The Codex hook file shape and its trust step (`/hooks`) are taken from the research, not run.

## Decisions to know about

- **Stop and idle hooks are ignored on purpose.** Only blocking events raise an alert; "finished" and "idle" are separate opt-ins for later.
- **Snooze is a phone-only stand-in** for the service's timer (one passive reminder after 15 minutes).
- **The phone never reports its answers yet** (see push service item 2), and nothing about an alert is stored on the Mac beyond a one-line diary entry with the agent kind.
- **The alert sheet is not a take-over.** It says who asked and offers to look at the Mac; the take-over and hand-back of the gaps document is separate work.
- **Old phones.** `agentAlert` is optional and unknown fields are ignored, so a Mac with this build never sends an old phone an action it would reject.

## Where things stand

Everything under "What shipped" is built and committed on `worktree-agent-a752967d0e530c55c`. Nothing is merged into `pocketdesk-remote-chat`.

Left to do, on a quiet machine (`SIM=<udid> script/verify-system-integrations.sh`):
1. On the rebased tree: the rest of the push routing samples and the banner actions test, the SpringBoard tests (End from the Lock Screen especially), the whole phone UI suite, and the two existing UI tests that failed under load, ideally against the base branch too.
2. On a phone: the list under "Still needs a real device, an APNs key or a domain".
3. Decisions: the public domain and the App ID, then `FARSIDE_ENABLE_PUSH=YES`.
