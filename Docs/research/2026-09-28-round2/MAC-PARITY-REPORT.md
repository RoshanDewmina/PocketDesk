# Mac parity with Workbench — launch at login, watchdog, privacy curtain, diagnostics

29 September 2026 (overnight run) · Claude Code worktree branch `worktree-agent-a506802250196dd9b`, rebased onto `pocketdesk-remote-chat` (includes the stream-tuning merge `fc91903` and the Mac companion Reach redesign `1b0178a`). Subordinate to PRODUCT.md; implements MAC-GAPS-SOLUTIONS.md gaps 1 (curtain, cover only) and 2 (watchdog), launch at login, and Workbench-style diagnostics.

**Evidence reached:** source, compilation of host / helper / phone, automated unit tests, real signaling + WebRTC integration tests for host restart, a real-Mac ScreenCaptureKit probe of curtain exclusion, and an end-to-end run of the real watchdog helper binary against a stand-in app. **Not reached:** the installed host with the helper registered through ServiceManagement, a real phone watching a real host crash and come back, the curtain on the owner's displays during a live session, a real person pressing Esc three times. See §8.

## 1. Summary

| Feature | Workbench | Farside after this branch | Evidence |
|---|---|---|---|
| Launch at login | Implicit | `SMAppService.mainApp`, **turned on once when setup first completes** (only for a copy in /Applications), visible toggle in the popover and Settings, status read back from macOS: on / off / waiting for approval / unavailable | Unit tests with fake services |
| Watchdog | Background helper, on by default, relaunch after crash/freeze | Bundled `FarsideWatchdog` LaunchAgent (`SMAppService.agent`), on by default after setup, toggle "Restart Farside if it quits". Relaunches after a crash (≈2–4 s) or a hang (main-thread stall 12 s in-process, or stale heartbeat 45 s from the helper; 4 s / 6 s while the curtain is up). **Crash-loop guard: 3 unexpected exits in 5 min → one launch in safe mode (sharing paused, "Farside stopped after repeated crashes"), then nothing more until the person resumes** | Policy unit tests; 14/14 end-to-end checks with the real helper binary; in-process stall detector test |
| Recovery shown to the phone | Phone shows "Relaunch" | Phone retries a lost live session for ~90 s (was ~15 s), reconnects to the relaunched host with the same pairing, and shows "Your Mac’s Farside restarted — reconnected." once | Real-service integration tests (restart with same pairing; ordinary failures keep the short window; host waits out its predecessor's room) |
| Privacy curtain | Hide/dim, optional input block | Opt-in, default off. Opaque Farside-styled window per display at shielding level, **excluded from our own `SCContentFilter` by window** (no reliance on `sharingType`), fail-closed raise with a stream canary. Lifts on session end, Stop Sharing, Pause, phone background pause, lock/sleep/user switch, display change, capture lost, Accessibility lost, crash (process-owned windows), hang (watchdog), and Esc ×3 at the Mac. Phone can toggle it (capability `curtain.1`). No dimming, **no input blocking** | Policy/controller unit tests (off-screen windows only); real-Mac SCK probe: shielding window visible to a plain filter, absent with window exclusion |
| Diagnostics | Report submission | Settings › General › **Copy Diagnostics**: versions, permissions, background items, sharing/curtain state, watchdog history, session counts/route, last 40 sanitized events. No screen content, typed text, clipboard, pairing codes, tokens, hosts or IP addresses | Sanitizer and report unit tests |

## 2. Platform facts checked (29 Sep)

| Question | Finding | Source |
|---|---|---|
| Login item / agent API | `SMAppService.mainApp`, `agent(plistName:)` (plist in `Contents/Library/LaunchAgents`, `BundleProgram` bundle-relative), `register()`/`unregister()`, `status` ∈ notRegistered/enabled/requiresApproval/notFound. "If an app updates either the plist or the executable for a LaunchAgent … the SMAppService must be re-registered … recommended to also call unregister before re-registering". Unregistering a running agent kills it. | MacOSX27.0.sdk `SMAppService.h`; developer.apple.com SMAppService JSON |
| launchd keys | `KeepAlive true`, `ThrottleInterval` (default 10 s), `LimitLoadToSessionType`, `ProcessType Standard` (= unspecified), `AssociatedBundleIdentifiers` for Login Items attribution | `man launchd.plist` (local) |
| Capture exclusion | `SCContentFilter(display:excludingWindows:)`; `SCStream.updateContentFilter`; `SCShareableContent.applications/windows` | MacOSX27.0.sdk `SCStream.h`, `SCShareableContent.h` |
| **Real-Mac probe** | A 120×80 shielding-level (`windowLayer 2147483628`) window, ordered in at alpha 0, **is listed** by `SCShareableContent(onScreenWindowsOnly: false)`. With alpha 1 for ~150 ms, `SCScreenshotManager` with a plain display filter sampled rgb(240, 88, 248) (the window); the same display with the window excluded sampled rgb(52, 54, 54) (desktop). Window closed immediately. | `scratchpad/probe/curtainprobe.swift`, run 29 Sep 00:21 |
| Global key monitoring | `NSEvent.addGlobalMonitorForEvents` delivers key events only when the app is trusted for Accessibility; injected events can be tagged with `kCGEventSourceUserData` | AppKit docs; CGEventTypes |

## 3. Launch at login

- `HostBackgroundServices` owns both background items. When `setupStep` first becomes `.done` (checked on the existing 1 s permission poll, so it also runs at each launch of an already set-up Mac) it registers `SMAppService.mainApp` **once** and records `launchAtLoginDefaultApplied`; turning it off later sticks forever.
- Only a copy under `/Applications` or `~/Applications` (not AppTranslocation, not DerivedData) is registered automatically; the toggle works anywhere.
- Status is read back from `SMAppService.status`, never assumed: Settings and the popover say "Back by itself after a restart", "Waiting for approval in Login Items" (with **Allow in Login Items…** → `openSystemSettingsLoginItems()`), or "Move Farside to Applications first". `kSMErrorAlreadyRegistered` counts as success; other errors are shown and logged to diagnostics.
- The redesign's Ready check row "Opens at login" now passes after setup.
- **PRODUCT F11 conflict:** F11 says "Explicit opt-in, off by default". This task specified on-by-default after first successful setup (Workbench parity). Needs Roshan's confirmation; reverting is one line (`shouldEnableLoginByDefault` → false).

## 4. Watchdog

### Architecture
- `FarsideWatchdog` — a ~450 KB command-line helper embedded at `Contents/MacOS/FarsideWatchdog`, registered with `SMAppService.agent(plistName: "com.roshan.PocketDesk.RemoteHost.watchdog.plist")` (`RunAtLoad`, `KeepAlive true`, `ThrottleInterval 10`, `LimitLoadToSessionType Aqua`, `AssociatedBundleIdentifiers` = host). Signed by the same team with hardened runtime; `codesign --verify --deep --strict` passes. Host bundle ID, PRODUCT_NAME, signing identity and install path are unchanged, so the identity-continuity guard is unaffected.
- The host is launched as a normal app by LaunchServices (`NSWorkspace.openApplication`, not activated, argument `--farside-recovered`), not by launchd directly — this avoids the window-server/TCC caveats in DTS 71304 and keeps `SMAppService.mainApp` as the login item without double-launching.
- Host ↔ helper state lives in `~/Library/Application Support/com.roshan.PocketDesk.RemoteHost/Watchdog/<hash of bundle path>/` (0700), one writer per file: `host.json` (pid, launch ID, boot session UUID, executable path, heartbeat uptime, clean-exit flag, curtain up, crash-loop reset), `watchdog.json` (helper ledger), `hang.json` (in-process hang note). Scoping by bundle path means a DerivedData build never shares state with, or is relaunched by, the installed copy's helper.
- The helper supervises only records whose executable lives inside its own bundle; watches the pid with a kqueue process-exit source (immediate) and polls adaptively (1 s with curtain, 3 s live, 2 s idle); verifies liveness by pid **and** executable path (pid reuse); ignores records from a previous boot (`kern.bootsessionuuid`); never kills a process being debugged (`P_TRACED`); stops relaunching on `willPowerOff`; exits to be restarted by launchd when its own binary is replaced by an update; retries a failed LaunchServices launch 3×.
- The host re-registers the agent (unregister → register) when the helper binary's size/mtime changes, as `SMAppService.h` requires after updates. Turning the toggle off unregisters it (which ends the helper).

### Crash and hang handling
| Situation | What happens |
|---|---|
| Quit from the popover, SIGTERM (e.g. `script/build_and_run.sh`), logout | Host writes `cleanExit` synchronously in `stopForTermination()`; helper does nothing |
| Crash, `kill -9`, Force Quit | Relaunched ≈2–4 s later (fixture: 1.6–4.1 s under load); the new host reports `recovered` to the first phone |
| Main thread stalled 12 s (only when the helper is registered) or 4 s with the curtain up | In-process watchdog thread writes `hang.json` and `_exit(3)`s; helper relaunches and records the exit as a hang |
| Whole process frozen (`kill -STOP`, deadlock) | Helper sees the heartbeat stop: SIGKILL after 45 s, or 6 s with the curtain up; relaunched (fixture: 8–13 s) |
| 3 unexpected exits within 5 minutes | Helper records `stoppedAt` and opens Farside once with `--farside-safe-mode`: sharing paused, popover "Stopped after repeated crashes · Farside stopped itself · Try Again", Settings footer; a further crash is not relaunched. **Try Again** clears it (host writes `crashLoopResetAt`). A new boot also clears it |
| Host opened by hand while stopped | Reads the ledger and starts in safe mode too |
| Previous run died without a clean exit in this boot | `recovered` is included on `capture` status for the first session (≤ 1 h after launch) |

The in-process stall detector posts a probe to the main queue and measures how long it waits, so App Nap or timer coalescing on the watchdog thread cannot look like a hang.

### Phone reconnect after a host restart
Before: a lost session retried 5× (0.5–8 s, ≈15.5 s total) and then showed "Check the Mac and retry" — shorter than a crash-relaunch-register cycle under load. Now `RemoteCoordinator` takes `sessionLossRetryLimit`/`maximumRetryDelayNanoseconds`; the phone uses 24 retries capped at 4 s (≈87 s) **only when an established session drops**. A failed first connect keeps the short window (test). The host now also retries `already_connected` at registration, so a relaunched host waits out its crashed predecessor's room instead of failing (test). Tested end to end with the real signaling service: the phone reconnects to a new host coordinator restored from the same saved pairing, with no re-pairing, after staying away longer than the old window.

### End-to-end helper check (`scripts/verify-watchdog.sh`)
Builds a stand-in LSBackgroundOnly app that publishes the same run record, copies the **built** `FarsideWatchdog` into it, runs the helper outside launchd and drives crash/quit/hang commands. 14/14 checks: idle while healthy; crash 1 and 2 relaunched with `--farside-recovered`; crash 3 opens once with `--farside-safe-mode` and records `stoppedAt`; crash 4 not relaunched; exactly four launches; clean quit never relaunched; hung host killed, relaunched and recorded as `hang`. It never touches the real host, launchd or ServiceManagement, and signals only its own processes.

## 5. Privacy curtain

### Design
- Preference `privacyCurtainWhileSharing` (default **off**); toggles in the popover's slot-in list, Settings "While your iPhone is connected", and the phone's Controls › Mac privacy (only when the Mac advertises `curtain.1` and control is allowed — covering the Mac's own screen needs the same authority as controlling it).
- One borderless window per `NSScreen`: `CGShieldingWindowLevel`, all Spaces + full-screen auxiliary, `ignoresMouseEvents` (injected clicks reach the apps underneath), never key (typing goes to the focused app). Farside Reach styling: void background, ember live dot, "This Mac is being used remotely" / "Press Esc three times to lift".
- **Fail-closed raise:** create windows at alpha 0 → resolve every one of them in `SCShareableContent` (all or nothing) → `SCStream.updateContentFilter(SCContentFilter(display:excludingWindows:))` → wait 150 ms → sample a coarse 8×8 luma grid → alpha 1 → after 500 ms sample again; if the stream turned curtain-dark while it was not before, lift and report `failed`. Filter updates are serialized so an older request can never replace a newer filter. `sharingType` is not used (DTS 792152). Only the curtain windows are excluded, so the phone still sees Farside's own popover and Settings.
- Raised only against a healthy picture; a new capture session drops old exclusions and lifts the curtain first.

### Lift triggers
| Trigger | Mechanism |
|---|---|
| Session ends, phone leaves, grace expires | `endCapture()` lifts and resets the session's local dismissal |
| Stop Sharing, Pause 10 min | `stop()` lifts synchronously before teardown |
| Phone backgrounded (pause) | `pauseForPhoneBackground()` lifts; re-raised after resume once the picture is healthy |
| Lock, system sleep, user switch | lifted at the start of `tearDownForUnavailability` |
| Display added/removed | controller lifts on `didChangeScreenParametersNotification` (host also stops) |
| Picture lost | lifted after 5 s of unhealthy capture (not while the display is merely asleep, so waking it never exposes the desktop) |
| Accessibility revoked, crash-loop safe mode | policy keeps it down (`unavailable`) |
| Esc ×3 at the Mac | global + local key monitors; three separate presses within 2 s; key repeats and phone-injected keys (tagged with `kCGEventSourceUserData`, or our pid) never count; phone told `liftedLocally` and shows a notice; "Hide it again" on the phone re-raises |
| Host crash | windows are owned by the process and vanish with it |
| Host hang | in-process watchdog ends the host after 4 s while the curtain is up; helper backstop 6 s |

### Protocol (appended, capability-gated)
- Host advertises `curtain.1` in `features`; reports `curtain` on `capture` status: `off | pending | up | liftedLocally | unavailable | failed`.
- Phone sends `{"action":"curtain","curtain":"up"|"down"}` only after seeing `curtain.1`; the host ignores it unless the session is current, control is effective and not paused.
- `hostEvent: "recovered"` on `capture` status. Old phones ignore unknown keys (JSON decoding); old hosts never receive `curtain` (gated). Validation rejects the fields on any other action and any non-token value.

### Known limits (honest copy)
- No local input blocking (out of scope; no event taps added). A person at the Mac can still type/click blind; the curtain hides, it does not lock.
- Esc ×3 needs Accessibility (the curtain is unavailable without it) and does not work while macOS Secure Event Input is on (a focused password field); lid close, power button or sleep still lift it.
- The pointer stays visible over the curtain; notification sounds are not hidden. Whether banners/system alerts draw above the shielding level is untested.
- Auto-keyboard after a click (`AXUIElementCopyElementAtPosition`) may hit the curtain window while it is up; manual keyboard still works. Untested.
- No backlight dimming (no reliable public API on Apple silicon).

## 6. Diagnostics

**Copy Diagnostics** puts a plain-text bundle on the Mac clipboard: app version/build, macOS, model identifier, whether it runs from Applications, uptime; Screen Recording/Accessibility; login item and recovery state; status, sharing/paired/connected/control/keep-awake, display count, last message; curtain preference and state; recovered-this-launch and cause, safe mode, helper relaunches/last exit/stop this boot; sessions since launch, last session length, route/codec/fps/RTT line; last 40 events (relative times). Excluded by construction: screen content, typed text, clipboard contents, pairing codes, keys, service address, Mac name, display names. A sanitizer also redacts URLs, e-mail addresses, UUIDs, IPv4/IPv6, host names, long mixed tokens and home-folder user names from every free-text value (tested).

## 7. Tests

| Suite | Result |
|---|---|
| `RemoteCoreTests` (macOS) after the final rebase | 297 tests, 3 skipped (opt-in benchmarks); every full run had exactly one failure in one of two known load-sensitive `SessionIntegrationTests` (`testHostKeepsRegisteredRoomWhenPhoneLeavesOrMediaDrops` or `testGraceExpiryEndsOnlyThePhoneSessionAndCachedTrustRejoins`); the untouched base fails the same way, see §9. Before the redesign rebase: 260 tests, 1 skipped, 0 failures. New: 44 unit tests (background services, watchdog policy/assessment/files/reporter/stall detector, curtain policy/Esc/tagging/exclusion/canary/controller with off-screen windows/protocol, sanitizer/report) + 3 real-service integration tests (relaunched host reconnects; ordinary failures keep short window; host waits out predecessor room) |
| `HostUISnapshotTests` | 6/6, including crash-loop and curtain popover/settings renders (reviewed) |
| `RemotePhoneTests` (dedicated iPhone 17 Pro sim, deleted after) | 45/45, including curtain state + once-per-session recovery notice |
| `scripts/verify-watchdog.sh` | 14/14 |
| Real-Mac SCK exclusion probe | PASS |
| Identity continuity (`script/verify_host_identity.sh` installed vs built, read-only) | "Host signing identity is unchanged"; the embedded helper does not change the designated requirement |
| Builds | Host (with embedded helper + LaunchAgent plist), phone (iOS Simulator), core, host UI tests — all succeed; every `xcodebuild` under `lockf -k /tmp/farside-xcodebuild.lock` |

## 8. Needs the real Mac / phone (checklist for the morning)

1. Install via `script/build_and_run.sh` from the integrated main checkout. Expect macOS notifications "Login Item Added" / "Background Item Added" once setup is detected. Check Settings: Open at login and Restart Farside if it quits show **on** (or "Waiting for approval").
2. `launchctl print gui/$(id -u)/com.roshan.PocketDesk.RemoteHost.watchdog` shows the helper running.
3. With the phone connected: `kill -9 $(pgrep -x PocketDeskRemoteHost)` → Farside back within ~5 s, phone reconnects by itself and shows "Your Mac’s Farside restarted — reconnected." Confirm Screen Recording/Accessibility still allowed after the helper's relaunch.
4. Three `kill -9` within 5 minutes → popover "Stopped after repeated crashes", no sharing; **Try Again** resumes.
5. Curtain: turn on "Hide this Mac’s screen", connect → every display covered, phone still sees the desktop; Esc ×3 at the Mac lifts it and the phone says so; Stop Sharing / Pause / phone background / lock each lift it; `kill -STOP` the host with the curtain up → curtain gone within ~6 s and host relaunched.
6. Copy Diagnostics → paste into a note and read it for anything private.

## 9. Open risks

- **E2E harness interaction:** the overnight harness's "host kill/relaunch" step now races the watchdog (harmless: LaunchServices dedupes) but **three SIGKILLs within 5 minutes will trip the crash-loop guard** and leave sharing paused. Use SIGTERM/`quit` for restart tests, or delete `watchdog.json` between kills, or `defaults write com.roshan.PocketDesk.RemoteHost automaticRecoveryEnabled -bool NO` and relaunch.
- Registration from `/Applications` happens automatically on the next installed launch (owner's Mac included). This is the requested default but it is a system-visible change.
- Unverified: TCC grants after a helper-initiated relaunch (identity is unchanged, so they should hold); `SMAppService.agent` status on first registration (`notFound` vs `notRegistered` is handled either way); helper behaviour across an app update in place.
- Two `SessionIntegrationTests` are flaky: `testHostKeepsRegisteredRoomWhenPhoneLeavesOrMediaDrops` (documented as load-sensitive in POINTER-REPORT, CLIPBOARD-BACKGROUND-REPORT, STREAM-FIX-REPORT) and `testGraceExpiryEndsOnlyThePhoneSessionAndCachedTrustRejoins`; both end with the host's "Secure connection failed" catch after a late signal from the previous phone session. Comparison against the untouched base `b5ffaa7` (exported tree, separate derived data, same machine, alternating): room test alone, base 1/3 failed and branch 1/3 failed; whole `SessionIntegrationTests` suite, base 1/3 runs failed (room test) and branch 2/3 runs failed (one each). Both tests use default coordinator parameters, so the new retry paths are inert there, and the host's new `already_connected` retry can only help the grace-expiry case. Not a regression; worth fixing separately (ignore stale signals after a session reset instead of failing the host).
- The phone's 90 s session-loss retry also applies to a Mac that genuinely went away (e.g. lid closed); the Home card shows "retrying" with Cancel during that time.
- Curtain limits in §5; the canary cannot prove exclusion on an already-dark desktop (it then trusts the filter, which the probe showed works).

## 10. PRODUCT.md to record on merge

- F11 → "Launch at login: on by default once setup first completes (Applications copy only), visible toggle and honest status" — **decision needed** (conflicts with "explicit opt-in, off by default").
- New: automatic recovery (watchdog helper) on by default after setup, crash-loop guard (3 in 5 min → safe mode), phone reconnects for ~90 s after a lost session and says when the Mac app restarted.
- New: privacy curtain (opt-in, cover only, no input block, Esc ×3, phone toggle); §8 "Blanking the physical display … unverified later capability" becomes "cover implemented; physical acceptance pending".
- F36: redacted diagnostics export is implemented on the Mac (copy to clipboard; no upload).

## 11. Files

Host: `RemoteHost/HostLoginItem.swift`, `HostWatchdogState.swift` (shared with helper), `HostWatchdogReporter.swift`, `HostHangWatchdog.swift`, `PrivacyCurtain.swift`, `HostDiagnostics.swift`; edits to `HostModel.swift`, `RemoteCapture.swift` (exclusion, luma sample), `RemoteInputDriver.swift` (event tag), `HostViewState.swift`, `HostReadiness.swift`, `HostPresentation.swift`, `HostPopoverView.swift`, `HostSettingsView.swift`, `RemoteHostApp.swift`. Helper: `RemoteWatchdog/main.swift`, `WatchdogSupervisor.swift`, `LaunchAgent/com.roshan.PocketDesk.RemoteHost.watchdog.plist`. Shared: `RemoteShared/ControlProtocol.swift`, `SessionContinuity.swift`, `RemoteCoordinator.swift`. Phone: `RemotePhone/RemotePhoneApp.swift`, `NativeSessionView.swift`. Tests: `RemoteTests/{HostBackgroundServicesTests, WatchdogTests, PrivacyCurtainTests, HostDiagnosticsTests, HostRestartIntegrationTests}.swift`, `RemotePhoneTests/MacParityPhoneTests.swift`, `HostUITests/HostUISnapshotTests.swift`. Scripts: `scripts/verify-watchdog.sh`, `scripts/watchdog-fixture/`. Project: `project.yml` (FarsideWatchdog tool target embedded in the host; LaunchAgent copy phase), regenerated `PocketDesktop.xcodeproj`.
