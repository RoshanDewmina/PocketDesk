# Mac host gaps vs Astropad Workbench: solutions research (round 2)

Checked 28 September 2026 against the installed Xcode 27.0 / MacOSX27.0.sdk / DriverKit27.0.sdk headers, Apple documentation, Apple Developer Forums (DTS answers), Astropad/Jump/Screens/Parsec/Chrome docs and open-source prior art. Research only: no code, project file, login item, launch agent or entitlement was changed or requested. Subordinate to [PRODUCT.md](../../../PRODUCT.md); extends [MAC-HOST-FEATURES.md](../2026-09-28/MAC-HOST-FEATURES.md) and [BUILD-PRIORITIES.md](../2026-09-28/BUILD-PRIORITIES.md), whose "research only" tags on curtain and virtual display are refined here into concrete public-API designs.

Evidence tags used below: **[SDK]** read in the installed headers, **[Apple]** Apple documentation or WWDC, **[DTS]** Apple engineer answer on the forums, **[Vendor]** competitor's own docs, **[2nd]** secondhand (GitHub READMEs/issues, search-engine excerpts, blogs), **[Inf]** my inference, unverified. Jump and Parsec help pages returned HTTP 403 to the fetch tool, so their behavior is quoted from search excerpts and tagged **[2nd]**.

---

## 1. Executive summary

| # | Workbench feature | Recommended approach for PocketDesk | Distribution | Effort (eng-days) | Pre-launch (17 Nov) |
|---|---|---|---|---|---|
| 1 | Privacy Curtain | **Cover + local-input block as one feature.** Per-display shield-level overlay windows, hidden from the phone with `SCContentFilter(display:excludingApplications:exceptingWindows:)`; lease-bound lifetime; in-process hang watchdog; local emergency chord; active `CGEventTap` on its own thread. **No backlight dimming** (no reliable public API). | Overlay: public, sandbox-safe in isolation. Input block: needs Accessibility, so **Developer ID only** (sandboxed apps cannot hold Accessibility [DTS]). | Cover 8-10, block +4-5 | **Conditional GO.** Lowest-priority pre-launch item; cut line 19 Oct. Never ship cover without block, and never block without escape. |
| 2 | Watchdog | `SMAppService.agent` LaunchAgent whose `BundleProgram` is the host executable, `KeepAlive{SuccessfulExit:false}`; in-process main-thread hang watchdog that exits non-zero; recovery ledger + safe mode; "recovered after a problem" state to the phone. Phone-triggered relaunch via a separate always-on helper later. | Public API; MAS-possible in principle, but host is Developer ID anyway. | 4-6 (helper +10-15) | **GO** (agent + hang exit). Helper: later. |
| 3 | Smart sleep | System-sleep assertion for "remote access available" (AC-only default), `IOPMAssertionDeclareUserActivity` to wake the display on connect, stop treating display sleep as terminal, "goodbye reason" to the phone, lock/screensaver detection, away-readiness checks. **No Wake-on-LAN pre-launch.** Apply for the Persistent Content Capture entitlement now. | Public, all. | 4-6 | **GO.** |
| 4 | Unified Display / virtual screen / headless | **No `CGVirtualDisplay` pre-launch.** Public alternatives: viewport-aware capture (`sourceRect`), `CGDisplaySetDisplayMode` with automatic revert, window fit, and later a multi-display compositor for Unified. Verify headless Apple silicon Mac mini works out of the box (it exposes a 1920x1080 1x display [Vendor]). | Public alternatives are MAS-compatible. `CGVirtualDisplay` is private, cannot ship on the Mac App Store, Developer ID only, with regressions reported on macOS 26 and the 27 betas. | Mode fit 3-5; compositor 15-20; CGVirtualDisplay 20-30 plus ongoing | **NO-GO** virtual/unified. Optional GO for mode-fit and a headless smoke test. |
| 5 | Multi-Mac device list | Phone-side multi-record store and Mac list with signaling presence; Bonjour "nearby" optional; multi-phone-per-Mac and iCloud sync later. | Public; iOS Local Network permission for Bonjour. | List 4-6, presence 2-3, Bonjour 3-4, multi-phone host 8-10 | **GO** for list (capacity-gated); rest later. |

Recommended pre-launch total: **about 12-18 engineer-days without the curtain** (sleep + watchdog + Mac list), **24-33 with it**, plus 3-5 for the optional display-mode fit. Suggested order: 3, 2, 5-list, then 1 (conditional).

Three findings change earlier assumptions:

1. **The Mac host is a Developer ID app, not a Mac App Store app, and every competitor's Mac side is too.** Workbench's Mac app is a direct download from astropad.com while the iOS app is on the App Store [Vendor: [MacStories](https://www.macstories.net/reviews/astropad-workbench-rethinks-remote-mac-control-for-ai-agents/), [product page](https://astropad.com/product/workbench/), [App Store listing](https://apps.apple.com/us/app/astropad-workbench/id6758788573)]; Jump Desktop Connect and Screens Connect are separate installers. Our host already uses cross-app Accessibility (`HostTextFocusProbe.swift:73-90`) and unsandboxed `CGEvent` posting, so "App Store" applies to the iPhone/iPad app; the host ships notarized (matches PRODUCT.md F38).
2. **`NSWindow.sharingType = .none` is not a dependable way to hide our overlay from ScreenCaptureKit.** DTS: "no public APIs for preventing screen capture" on macOS 15.4+ [[DTS 792152](https://developer.apple.com/forums/thread/792152)]; field reports conflict. The documented mechanism is the content filter: excluding your own app is Apple's stated use case for screen-sharing apps (mirror-hall effect) [[WWDC22 10155](https://developer.apple.com/videos/play/wwdc2022/10155/)].
3. **The recurring Screen Recording re-approval prompt is the biggest "away" risk and is independent of all five gaps.** macOS 15+ re-prompts monthly; the prompt blocks capture until someone clicks Allow at the Mac [[DTS 756908](https://developer.apple.com/forums/thread/756908), [MacRumors](https://www.macrumors.com/2024/08/15/macos-sequoia-screen-recording-app-permissions/)]. The only exemption is `com.apple.developer.persistent-content-capture` (macOS 14.4+, requires Apple approval, documented for VNC-class apps) [[Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture)]. **Submit the request form this week**; approval time is unknown (other entitlements have taken days to 13 months).

---

## 2. Ground truth

### 2.1 What Workbench actually documents

| Feature | What the vendor says | What it does not say |
|---|---|---|
| Privacy Curtain (1.3, 19 Aug) | Styles Workbench/Frost/Black; "Hide my screen while sharing"; optional dim to 30% backlight; "Block local input while curtained" with an override shortcut that ends the session [[help](https://support.astropad.com/en/articles/16401471-what-is-the-privacy-curtain-in-workbench), [release notes](https://astropad.com/blog/workbench-1-3/)]. Fixes shipped later (App Store history for 1.3.1, 17 Sep: Mission Control/Dock toggle, "major fixes for an issue that could unexpectedly log you out"). | Crash, disconnect, lock-screen, permission and multi-display behavior; implementation. |
| Watchdog (1.3) | Background helper, on by default after first launch; Settings > Remote Access > Automatic Recovery; relaunches on crash, freeze, dropped connection, or a connection attempt hanging 10-15 s; the phone shows **Relaunch** in place of Connect; sends no notification; turning it off "stops the background helper entirely" [[help](https://support.astropad.com/en/articles/16415600-watchdog-for-workbench)]. | Mechanism (LaunchAgent/SMAppService), how the phone reaches a helper when the app is dead (evidently via their account/relay). |
| Smart sleep (1.1) | "Wakes displays on connection"; prevents sleep automatically once remote access is set up; the Mac "needs to be awake and running Workbench"; cannot wake a sleeping Mac; recommends auto-login and FileVault off; "may fall back to the last known resolution when the display is off" [[setup](https://support.astropad.com/en/articles/14010461-setting-up-your-mac-for-remote-access), [headless guide](https://astropad.com/blog/headless-mac-mini-setup-guide/)]. | Anything about lock screen; no Wake-on-LAN. |
| Unified Display | "Full Retina-resolution virtual display matched to your device"; combines all displays into one; toggled per device; single display is the default; resolution "returns to normal" after the session; headless Apple silicon Mac mini defaults to a fuzzy 1920x1080 1x display; dummy plugs "mostly a thing of the past" [[display modes](https://support.astropad.com/en/articles/14026370-workbench-display-modes), [dummy-plug post](https://astropad.com/blog/dummy-plug-headless-mac-mini/)]. | The API. Because the Mac app is a direct download, private API is possible **[Inf]**. |
| Device list | Discovery is local-network plus same-account; "device catalog" to swap between devices [[iPhone setup](https://support.astropad.com/en/articles/14025859-setting-up-workbench-on-your-ipad-iphone), [product page](https://astropad.com/product/workbench/)]. | Account required. |

Reading between the lines: the curtain's "30% backlight" is a real-backlight claim, which on Apple silicon implies the private DisplayServices path **[Inf]** (see 3.3). The Watchdog's phone-side "Relaunch" implies a helper with its own network presence **[Inf]**. Neither is available to a public-API-only build in the same form; the designs below reach the same outcomes differently.

### 2.2 What our host does today (code facts)

- Capture filter is `SCContentFilter(display: display, excludingWindows: [])` (`RemoteCapture.swift:206`); cursor shown, 60 fps cap, queue depth 3. Frame status is tracked; only `.complete`/`.idle` count as healthy (`CaptureHealthState`). `SCFrameStatus` also has `.blank` ("display has gone blank") and `.suspended` [SDK: `SCStream.h:45-56`].
- Keep-awake is `kIOPMAssertionTypePreventUserIdleDisplaySleep` (`HostKeepAwake.swift:11`), held only while `active`.
- `HostModel.swift:162-170`: `willSleep`, `sessionDidResignActive` **and `screensDidSleep`** all call `autoStart.suspend(); stop()`, which stops the connection (`connection.stop()`), so the phone cannot tell "asleep" from "gone". Display sleep alone therefore makes the host unreachable if keep-awake is off.
- Login: `SMAppService.mainApp` only (`HostModel.swift:377`). Nothing restarts the host after a crash. `HostTermination.swift` handles SIGTERM cleanly (exit 0).
- `relaunch()` (`HostModel.swift:227-239`) spawns `/bin/sh` that waits for the old pid then runs `/usr/bin/open`. Under launchd supervision that child lives in the job's process group and is killed when the job exits unless `AbandonProcessGroup` is set (**[Inf]** from launchd semantics; must be reworked, see 4.4).
- Input: `CGEvent.post(tap: .cghidEventTap)` with `source: nil` (`RemoteInputDriver.swift`); Accessibility gate via `AXIsProcessTrusted()`.
- Pairing is **single-record**: one Keychain item per role (`PairStore(account: "host"|"phone")`, `RemoteCoordinator.swift:51`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), one `HostPair`, a 32-byte AES-GCM key and a room digest on the signaling server. There is **no Bonjour/`NWBrowser`/`NWListener` anywhere** in RemoteShared, RemoteHost or RemotePhone. Presence exists only as the server's per-room `peer{online}` message (`Server/src/server.ts:207-208, 292`).
- Project: no entitlements file, hardened runtime, Apple Development identity, `LSUIElement` (`project.yml:124-142`). The identity-continuity guard in [MAC-PERMISSION-IDENTITY.md](../../MAC-PERMISSION-IDENTITY.md) will (correctly) refuse an in-place update from an Apple Development build to a Developer ID build; treat the switch as a one-time identity migration with a fresh permission grant, not a bypass.

### 2.3 App Sandbox reality (why "Developer ID for the host")

| Capability | Sandboxed Mac App Store app? | Source |
|---|---|---|
| ScreenCaptureKit capture | Yes (TCC Screen Recording) | standard |
| `CGEvent` posting | Only via the separate PostEvent privilege; older DTS answer said no, newer says yes | [DTS 789896](https://developer.apple.com/forums/thread/789896), [28605](https://developer.apple.com/forums/thread/28605) |
| Listen-only event tap | Yes (Input Monitoring) | DTS 789896 |
| **Active (filtering) event tap** | **No**: sandbox gets ListenEvent and PostEvent but not Accessibility | DTS 789896 |
| AX on other apps (`AXUIElementCreateSystemWide`, hit testing) | **No** | [DTS 756130](https://developer.apple.com/forums/thread/756130) |
| `SMAppService` agents | Plist ships inside the bundle; behavior of a sandboxed agent target not verified **[Inf]** | [Apple](https://developer.apple.com/documentation/servicemanagement/smappservice) |
| LaunchDaemons | Require notarization/admin approval | [SDK: `SMAppService.h:54-55, 160-161`] |

A Mac App Store host would lose the AX text-focus probe, local-input blocking, and any login-window work. Recommend a single distribution decision now: **iOS app on the App Store, Mac host Developer ID + notarization.**

---

## 3. Gap 1: Privacy curtain

### 3.1 Options considered

| Option | Public API? | Hidden from the phone's stream? | Verdict |
|---|---|---|---|
| **A. Overlay windows above everything + exclude our app from the SCStream filter** | Yes | Yes, by content filter (documented) | **Recommended** |
| B. `NSWindow.sharingType = .none` alone | Yes | Unreliable. DTS 792152: no public API prevents capture on 15.4+; [Tauri #14200](https://github.com/tauri-apps/tauri/issues/14200) reports SCK ignoring it; yet [opendisplay #289](https://github.com/peetzweg/opendisplay/issues/289) shows SCK omitting Teams overlays flagged non-shareable. Conflicting [2nd]. | Use only as defense in depth. |
| C. Gamma-table blackout (RustDesk) | Yes | Capture is pre-gamma, so unaffected | **Rejected as primary.** `CGSetDisplayTransferByTable` silently does nothing on MacBook M5 Pro/Max/Neo from 26.3 through 27.x (FB22273730 open as of June 2026) [[DTS 819331](https://developer.apple.com/forums/thread/819331)], and with "Automatically adjust brightness" on [[795074](https://developer.apple.com/forums/thread/795074)]. The call returns success, so failure is undetectable. ColorSync resets tables on display reconfiguration, forcing polling [[RustDesk #14102](https://github.com/rustdesk/rustdesk/pull/14102)]. The formula API cannot reach full black (max must be in (0,1]) [SDK: `CGDirectDisplay.h`]. Upside: tables revert on process death [2nd] and `CGDisplayRestoreColorSyncSettings()` exists. |
| D. Backlight dimming | `IODisplaySetFloatParameter` is a no-op on Apple silicon built-in panels [2nd]; the working route is private `DisplayServices*` | n/a | **Rejected** (private). |
| E. `CGDisplayCapture` (exclusive display) | Yes | Would own the display and blank the stream too [Inf; untested] | Rejected. |
| F. Virtual display + switch physical displays off (Parsec, Jump) | Private (`CGVirtualDisplay` + display-disable) | Yes, strongest privacy | Rejected pre-launch: private API and the failure modes in 6.3. |
| G. Lock/login-window curtain (Chrome Remote Desktop, Screens) | System service | n/a | Not available: Chrome Remote Desktop's curtain "is no longer supported on Mac devices running macOS Big Sur or later" [[Google](https://support.google.com/chrome/a/answer/2799701)]; Screens' Curtain Mode requires Apple's Remote Management and "does not function at the login window" [[Screens](https://help.edovia.com/en/screens-5/features/curtain-mode)]. |

### 3.2 Recommended design

**Windows.** One borderless `NSWindow` per `NSScreen`, level `Int(CGShieldingWindowLevel())`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `sharingType = .none` as belt and braces (SDK note: such windows do not take part in some system services, acceptable here). Styles: Black (default), Frost (`NSVisualEffectView`), PocketDesk card. Must be **click-through** (`ignoresMouseEvents = true`), otherwise our own injected clicks hit the overlay instead of the app underneath. Consequence: an overlay alone does not stop a bystander typing or clicking into the hidden desktop, which is why cover and input block ship together.

**Exclusion.** Replace the filter at `RemoteCapture.swift:206` with `SCContentFilter(display:excludingApplications:[ownSCRunningApplication], exceptingWindows: [])`. App-level exclusion covers windows created later (curtain rebuilt after hotplug) without re-resolving `SCWindow`s [[WWDC22 10155](https://developer.apple.com/videos/play/wwdc2022/10155/), [SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter)]; `SCStream.updateContentFilter` exists if the filter must change on a live stream [SDK: `SCStream.h:520-525`]. Side benefit: the phone can no longer see (or be tempted to click) the host's own pairing/consent windows; the input driver should also refuse synthetic events aimed at them. Open question for the spike: is a menu-bar-only `LSUIElement` app present in `SCShareableContent.applications` before it has a window? If not, build the filter after creating the (hidden) overlay windows.

**Fail-closed activation order.**
1. Capture healthy. 2. Create overlay windows hidden. 3. Resolve own app in `SCShareableContent`; apply the filter; assert none of the overlay windows appear in the resulting `SCContentFilter.includedWindows`. 4. Show overlays. 5. Canary: compare the captured frame's mean luminance before and 300 ms after; if it collapsed to near-black while the previous frame was not, exclusion failed, so lift and tell the phone. 6. Phone shows "Curtain on: you should still see your desktop here" with a Lift button.
If any step fails, no curtain is shown. (RustDesk refuses to enter privacy mode if displays cannot be protected [[PR 15004](https://github.com/rustdesk/rustdesk/pull/15004)].)

**Local input block (Developer ID only).**
- `CGEvent.tapCreate` at `.cgSessionEventTap` (the HID location is documented as root-only for non-root callers [Apple, old CGEventTapCreate discussion]; confirm in the spike), `.defaultTap`, mask covering keyboard, mouse, scroll, gesture and system-defined (`NX_SYSDEFINED`) events, run on **its own high-QoS thread**, callback does no work beyond a tag check.
- Pass our own injected events: tag them by creating a dedicated `CGEventSource` with `userData` (`kCGEventSourceUserData`, field 42) and fall back to `kCGEventSourceUnixProcessID == getpid()` (field 41) [SDK: `CGEventTypes.h:349-356`]. Requires a small change to `RemoteInputDriver` (today `source: nil`).
- Re-enable on `kCGEventTapDisabledByTimeout/UserInput`; a disabled tap means local input flows again, which is the safe direction.
- Permission model: active tap = Accessibility (already required); listen-only = Input Monitoring; sandboxed apps cannot hold Accessibility [DTS 789896].
- **Secure Event Input hole.** While any process has it on (a focused password field, Terminal "Secure Keyboard Entry"), key events are not delivered to event taps **or to keyboard-seizing HID clients** [Apple: [TN2150](https://developer.apple.com/library/archive/technotes/tn2150/_index.html)]. Local typing then reaches the focused app. Detect with `IsSecureEventInputEnabled()` and tell the phone "Local keyboard block paused: a password field is active". Never claim the block is absolute. Power button, lid, Touch ID and hard shutdown are unaffected.
- `CGEventSourceSetLocalEventsFilterDuringSuppressionState` is only a short post-injection suppression window, not a block [SDK: `CGEventSource.h:185-247`].

**Lifetime and failure safety (the part RustDesk got wrong).** RustDesk's macOS mode has no local exit and stays blanked and blocked if the controller crashes [[issue 16192](https://github.com/rustdesk/rustdesk/issues/16192), macOS 27.0]. Layers:

| Failure | Behavior | Mechanism |
|---|---|---|
| Host crash / `kill -9` / quit | Overlay and tap vanish | Windows and event taps are owned by the process; the OS reclaims them [2nd: RustDesk PR review notes] |
| Host **hang** (main thread stuck) | Overlay would stay (WindowServer keeps drawing) | In-process watchdog thread exits the process after 3 s of missed main-thread heartbeats; launchd then relaunches (see 4). A separate curtain-owner helper process is the stronger v1.1 option. |
| Explicit End / Stop Sharing | Lift synchronously before teardown | Session state machine |
| Phone drops unexpectedly | Keep up to a grace window (default 15 s, 0-60), then lift | Session lease; reconnect within grace resumes |
| Display sleep, system sleep, lock, fast-user-switch | Lift; re-arm only if the session is still authenticated afterwards | `NSWorkspace` notifications, lock notification (5.2) |
| Capture unhealthy or stopped | Lift | Nothing to protect; avoids a stuck black screen |
| Display hotplug / Space change | Reconcile in the same runloop turn; if any display cannot be covered, lift everything and tell the phone | `NSApplication.didChangeScreenParametersNotification`, `activeSpaceDidChange` |
| Tap disabled by the system | Local input flows again | fail-open |
| Local human wants control back | **Chord always active, handled inside the tap before blocking** (proposal: hold Control-Option-Command-Escape 2 s), ends the remote session; hint text on the overlay | "Physical presence wins" |
| Relaunch after crash | Curtain is **not** persisted; only the preference "Hide my screen while sharing" is; it applies at the next authenticated session start | avoids re-curtaining with no live controller |

**Lock interplay.** Lift the curtain on lock and tell the phone "Mac is locked"; the lock UI belongs to loginwindow and is not ours to cover. Whether the overlay ever appears above the lock UI, and what SCK returns while locked, are unverified (spike S4). Jump and Parsec instead lock the Mac when the last viewer disconnects [2nd, search excerpts of their help pages]; that is one-way for a user-session host (a locked Mac cannot be reached again remotely, 5.3), so offer it only as an explicit opt-in ("lock when the session ends", posting Control-Command-Q, whose behavior depends on the user's shortcut settings).

**Dimming.** Do not promise it. If wanted later: best-effort gamma with a "may not work on all Macs" label and `CGDisplayRestoreColorSyncSettings()` on every exit path; or accept a Developer-ID-only private path knowingly. Black overlay already removes the visual exposure that matters.

### 3.3 Risks

Overlay exposure gap during hotplug (a new display can show content for a few frames before we cover it); notification banners or system UI possibly drawn above the shield level (test); cursor remains visible on the overlay; audio and notification sounds are not hidden; a curtain is not a lock and copy must say "hides your screen from people nearby". Secure input leak above. Multi-display Macs: Screens warns of flicker and restoration issues [Vendor]; Jump warns some base Apple silicon Macs support only one external display when privacy mode is used [2nd], a limit that does not apply to plain overlays.

### 3.4 How we beat Workbench

Publish and test the failure table (their docs are silent on crash, disconnect, lock and permissions); guaranteed local escape; curtain state and a Lift button on the phone; honest keyboard-block status; self-test that the phone still sees the desktop; hotplug-safe; no account. Parity gap accepted: no backlight dim.

### 3.5 Effort and gate

Cover, exclusion, lease, hang watchdog integration, chord, multi-display, phone UI: **8-10 days**; input block with tagging, own thread, secure-input detection, chord: **+4-5**; QA matrix (Spaces, full-screen apps, Stage Manager, two monitors, hotplug, clamshell, sleep/wake, lock, `kill -9`, `kill -STOP`, disconnect, Mission Control, force-quit dialog): included. **Go/no-go: conditional GO.** Build last; if sleep/lock and watchdog are not green by **19 Oct**, defer the whole curtain to v1.1 rather than ship a partial version.

---

## 4. Gap 2: Crash recovery / watchdog

### 4.1 Recommended architecture (v1.0)

1. **LaunchAgent that supervises the host itself.** Register with `SMAppService.agent(plistName:)`; the plist lives at `Contents/Library/LaunchAgents/<label>.plist` inside the signed bundle (tamper-evident), `BundleProgram` points at the **executable**, not the `.app` [[DTS 750528](https://developer.apple.com/forums/thread/750528)]. Do not mix legacy and SMAppService installation for the same agent [[DTS 775490](https://developer.apple.com/forums/thread/775490)].

```xml
<dict>
  <key>Label</key><string>com.roshan.PocketDesk.RemoteHost.agent</string>
  <key>BundleProgram</key><string>Contents/MacOS/CFBundleExecutable-goes-here</string>
  <key>AssociatedBundleIdentifiers</key><array><string>com.roshan.PocketDesk.RemoteHost</string></array>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
```

`SuccessfulExit=false` relaunches after a crash signal or any non-zero exit, and stays down after `exit(0)`, so **Quit and Stop Sharing are respected** (Stop is a state, not an exit; `sharingEnabled` is already persisted). It implies run-at-login. Keys per the [launchd.plist man page](https://keith.github.io/xcode-man-pages/launchd.plist.5.html); launchd throttles rapid respawn (default 10 s). A GUI app launched directly by an Aqua-session agent needs `LSUIElement` (already set); an older DTS thread prefers login items to launchd for GUI apps and warns that direct execution can behave differently for window-server and TCC context [[DTS 71304](https://developer.apple.com/forums/thread/71304)], so spike S6 must confirm window server access and permission inheritance before we commit. TCC grants follow the code identity (designated requirement), not the launch method, so the relaunched instance keeps Screen Recording and Accessibility, provided the signing identity is stable ([MAC-PERMISSION-IDENTITY.md](../../MAC-PERMISSION-IDENTITY.md)).
   - Replace `SMAppService.mainApp` registration with the agent (registering both double-launches at login); keep a single-instance guard.
   - Register only when running from `/Applications` (not from a translocated path); surface `.requiresApproval` with `openSystemSettingsLoginItems()`; the user sees a "background item added" notice and can disable it in System Settings, and the app must treat that as a preference, not an error.
2. **Hang detection inside the process.** Main-thread heartbeat (`DispatchQueue.main.async` every 1 s) watched by a dedicated thread using `mach_absolute_time` (which does not advance during sleep, avoiding false positives after wake). If stalled for 8-10 s (3 s while a curtain is up), and not debugger-attached, `_exit(2)`; launchd relaunches. Verify the heartbeat still fires during modal alerts and menu tracking.
3. **Escalation ladder** (beats a bare relaunch): soft (restart `SCStream`, capture stalled > 10 s), medium (tear down the peer and re-register with signaling), hard (exit non-zero).
4. **Crash-loop guard.** PRODUCT.md and MAC-HOST-FEATURES.md require bounded backoff and a visible failure. Keep a launch ledger (timestamps in defaults); on the 3rd unexpected launch inside 10 minutes start in **safe mode**: sharing paused, menu-bar warning, no auto-resume, and stay alive (a clean `exit(0)` would silently end supervision).
5. **Sentinel and phone state.** Write a "running" sentinel at launch, delete on clean exit; a stale sentinel means the previous run ended abnormally. The host tells the phone on reconnect ("Mac app recovered after a problem"); the server can mark a room's last disconnect as `abrupt` vs `goodbye`. Phone retries with backoff for about 90 s.
6. **Restore state:** persisted already (paired trust, `sharingEnabled`, control consent, keep-awake). Add selected display by UUID (`CGDisplayCreateUUIDFromDisplayID`, since IDs change) and the curtain **preference** (not curtain-active).

### 4.2 Integration hazards to fix before enabling

- `relaunch()` (permission-change flow) must exit **non-zero** when supervised (or be replaced by `launchctl kickstart -k`), otherwise its shell child is reaped with the job or the new `open`ed instance escapes supervision and KeepAlive can double-launch.
- Force Quit from Activity Monitor is a `SIGKILL`; a signal death should count as an unsuccessful exit and relaunch, but the launchd man page does not spell out `SIGKILL` handling **[Inf, test in S6]**. Accept and document, or offer "Quit PocketDesk" as the supported off switch.
- The macOS crash dialog appears on the physical screen after a crash; it cannot be suppressed without changing system settings, which we should not do.

### 4.3 v1.1 helper (phone-triggered Relaunch)

Workbench's Relaunch button needs something alive when the app is dead. Build a tiny `LSBackgroundOnly` agent that holds signaling presence and a shared-Keychain pairing key, authenticates a phone "relaunch" request, kills and reopens the host. It must not resurrect an intentional Quit (sentinel says clean exit). Also enables "Mac app not running" vs "Mac offline" on the phone. Effort **10-15 days** plus security review. Pre-launch phone behavior is simply "reconnecting for ~90 s".

### 4.4 Distribution and risks

Public API; `SMAppService` daemons need notarization [SDK] but we are not using one. Risks: agent registration breaks if the app is moved (re-register); Developer ID identity migration invalidates dev-build permissions once; launchd relaunch is at least the throttle interval (~10 s); a whole-process wedge in the kernel is not caught by the in-process watchdog (helper solves).

### 4.5 Effort, beat, gate

**4-6 days** (agent + migration 1; hang watchdog 1; ledger/safe mode 1; sentinel + phone messages 1; fault injection `kill -9`/`kill -STOP`/logout/login/Quit/Stop/relaunch flow 1-2). Beats Workbench with a visible "recovered" state on the phone, the escalation ladder, crash-loop protection, and no silent restarts. **GO.**

---

## 5. Gap 3: Sleep, lock and login-window handling

### 5.1 Sleep and power

- **Assertion type.** Use `kIOPMAssertPreventUserIdleSystemSleep` for "remote access available" (name it in the UI "PocketDesk remote access"); "the display may dim and idle sleep ... The system may still sleep for lid close, Apple menu, low battery, or other sleep reasons" and it "has no effect if the system is in Dark Wake" [SDK: `IOPMLib.h:275-292`]. Keep the existing display-sleep assertion **only while a session is active** (`kIOPMAssertPreventUserIdleDisplaySleep`, `HostKeepAwake.swift:11`). This is the equivalent of Workbench's automatic "prevent sleep".
- **Battery policy.** Default to AC-only on laptops with a visible override (Jump offers "Sleep Override: always or only on AC" [[Jump 10](https://docs.jumpdesktop.com/whats-new/jump-desktop-10/)]). Read AC state with the IOPS APIs; warn on `ProcessInfo.isLowPowerModeEnabled` and thermal state.
- **Wake the display on connect.** `IOPMAssertionDeclareUserActivity(name, kIOPMUserActiveRemote, &id)`: "causes the display to power on and postpone display sleep ... No special privileges are necessary" [SDK: `IOPMLib.h:541-579`]. This is Workbench's "wakes displays on connection". Then restart capture if needed; time-to-first-frame after display wake is a spike item (S7). While asleep, SCK reports `.blank` frames [SDK], which our health logic already treats as unhealthy.
- **Stop tearing down on display sleep.** Change the `screensDidSleep` handler (`HostModel.swift:162`) so display sleep pauses capture and updates state but keeps the signaling presence, so the phone can connect and trigger the wake. Keep full teardown for `willSleep` and fast-user-switch.
- **Goodbye reason.** On `willSleep`/lock/session-resign send one small "host state" message before tearing down; the server stores the last reason and time per room; the phone shows "Mac went to sleep at 3:14 pm" instead of "unavailable". Only what the Mac itself told us may be stated as fact (PRODUCT.md: do not pretend to know sleep or lock status when we do not).
- Lid close, shutdown, power loss and FileVault pre-boot cannot be prevented; laptops need AC plus an external display for clamshell use (documentation, not a feature).

### 5.2 Wake for a sleeping Mac: what is realistic

| Method | Works from cellular? | Notes |
|---|---|---|
| Nothing (Workbench "cannot wake a sleeping Mac" per its support docs, seen via search excerpt; its setup article says the Mac "needs to be awake") | n/a | Parity. |
| **Bonjour Sleep Proxy** | LAN only | Mac with "Wake for network access" advertising a Bonjour service; a proxy (Apple TV, AirPort base station; HomePod unconfirmed) answers for it and wakes it when a client connects [[Cheshire](https://stuartcheshire.org/sleepproxy/)]; laptops need AC power and a display (lid open or external) [2nd: blog and Apple Community excerpts]. Phone side is a plain `NWConnection` to the service, **no entitlement**. Requires us to add Bonjour advertising first (none today). Unverified on Apple silicon and macOS 27 **[Inf]**. |
| Magic packet from the phone | LAN only | UDP broadcast on iOS needs `com.apple.developer.networking.multicast` (Apple-approved); unicast and Bonjour/`NWBrowser` do not [[DTS 655920](https://developer.apple.com/forums/thread/655920)]. |
| Power Nap / APNs push wake | No | Dark Wake is brief, no display, assertions have no effect there; not viable for streaming. |
| Home hub device | Yes | A second always-on device on the LAN sends the packet on request. Post-launch idea only. |

Pre-launch: no wake feature; detect-and-explain plus keep-awake plus a readiness checklist. Later: LAN "Wake Mac" through Sleep Proxy; apply for the multicast entitlement early if magic packets are wanted.

### 5.3 Lock screen and login window

| Question | Finding |
|---|---|
| Can a user-session `SCStream`/`CGEvent` app capture or control the lock screen? | Not established; treat as **unsupported**. Third-party evidence: black frames while locked with secure screen savers [2nd]; keyboard `CGEvent` posting at the login window unreliable and intermittent on Intel (an unanswered developer report, [forum thread 724740](https://developer.apple.com/forums/thread/724740)). Astropad requires an unlocked, logged-in Mac and recommends auto-login [Vendor]. Verify on macOS 27 (spike S4). |
| Can anything capture the **login window**? | Yes, on macOS 14.4+, with Apple's blessed architecture: a LaunchDaemon (network) plus a LaunchAgent in `/Library/LaunchAgents` with `LimitLoadToSessionType` = `Aqua` and `LoginWindow`, joined by XPC; a daemon must not touch GUI APIs [[DTS 814152](https://developer.apple.com/forums/thread/814152)]. Root-installed, notarized, Developer ID only; FileVault pre-boot is unreachable by any software. |
| Should the phone type the Mac password? | **No-go now.** It makes the phone a login factor (a lost unlocked phone means Mac access), so it needs its own threat model, biometric gate, explicit Mac-side opt-in, never store or log the password, and the login-window architecture above. PRODUCT.md already lists "login-password storage" as out of scope. |
| Detecting lock | `DistributedNotificationCenter` names `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` (widely used, undocumented names [2nd]); `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` as a poll fallback. `sessionDidResignActive` is only for fast user switching [[Apple](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification)], so our current lock handling at `HostModel.swift:162` may not fire on a plain lock (spike S4). Screensaver via `com.apple.screensaver.didstart/didstop` [2nd]. |

### 5.4 Detect-and-explain states for the phone

| State | Detected by | Phone says | Action offered |
|---|---|---|---|
| Ready | awake, unlocked, capture healthy | (live view) | none |
| Display asleep | `screensDidSleep`, `CGDisplayIsAsleep`, `.blank` frames | "Mac display is asleep, waking it" | declare user activity, retry |
| Screen saver | distributed notification | "Screen saver is running" | tap to wake |
| **Locked** | lock notification / CGSession | "Mac is locked. PocketDesk can't unlock a Mac; unlock it in person." | wait; auto-resume on unlock |
| Another user active | `sessionDidResignActive` | "Another user is using the Mac" | wait |
| Asleep / lid closed / offline | goodbye message (if received) else no peer | "Mac went to sleep at ..." or "Mac offline, last seen ..." | Wake (LAN, later) |
| Restarted / login screen / FileVault | no peer | "Needs someone at the Mac" (never "it is asleep" without proof) | setup guidance |
| PocketDesk not running | no peer plus watchdog recovery pending | "PocketDesk is restarting on your Mac" | wait ~90 s |
| Screen Recording approval pending | `CGPreflightScreenCaptureAccess`, SCK error | "macOS is asking to approve screen recording (monthly)" | needs Mac; entitlement request |

### 5.5 Away-readiness checklist (PRODUCT.md "Before leaving")

Read-only checks: keep-awake active, AC power, Low Power Mode, auto-login (`/Library/Preferences/com.apple.loginwindow` `autoLoginUser`), FileVault status, screen-lock delay, "Wake for network access", monitors attached. Deep-link to the relevant System Settings pane; do not change system power settings ourselves (that needs root and PRODUCT.md says do not instruct users to weaken security). Workbench claims it "manages these sleep settings" for the user, which implies elevated helper behavior we should not copy **[Inf]**.

### 5.6 Effort, beat, gate

**4-6 days** (assertions and battery policy 1; display wake and reworked sleep handling 1; lock/screensaver detection 1; goodbye reasons and phone states 2; tests 1). Add the entitlement request (no engineering). Beats Workbench with honest reasons, a readiness check and an attempt to wake displays, plus a later LAN wake. **GO.**

---

## 6. Gap 4: Unified Display, virtual screen, headless

### 6.1 What competitors use

| Product | Approach | Distribution |
|---|---|---|
| Workbench | Undocumented; marketing says a Retina "virtual display matched to your device" and "returns to normal" after the session **[Inf: private virtual display API]** | Mac app: direct download |
| Jump Desktop Connect | Virtual displays on the Mac host (macOS 10.14+; Apple silicon up to 4); "replaces the host's actual monitors" while active; "Keep After Disconnect" persistence; extensive fix history [[docs](https://docs.jumpdesktop.com/whats-new/jump-desktop-10/), [virtual displays](https://changelog.jumpdesktop.com/virtual-displays-pbTZC), [changelog](https://changelog.jumpdesktop.com/)] | Connect is a separate installer |
| Screens | Relies on Apple's Screen Sharing (Apple creates a virtual display for headless Macs); Curtain Mode needs Remote Management [[Screens](https://help.edovia.com/en/screens-5/features/curtain-mode)] | Connect installer |
| Parsec | macOS virtual displays without a driver; privacy mode turns physical displays off and locks after the last guest **[2nd]** | direct |
| Sunshine | No virtual display on macOS "because there is no public virtual display API" **[2nd]**; users add BetterDisplay or `CGVirtualDisplay` tools | direct |
| DeskPad, BetterDisplay, OpenDisplay, vdisplay, go-macos/virtualdisplay | All `CGVirtualDisplay` [[DeskPad](https://github.com/Stengo/DeskPad), [go-macos](https://github.com/go-macos/virtualdisplay)] | direct/Homebrew |

### 6.2 Is there a public API?

- **`CGVirtualDisplay`: private.** `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplayMode`, `CGVirtualDisplaySettings` are exported in `CoreGraphics.tbd` of the macOS 27.0 SDK but declared in **no header** [SDK]. Programs linking it "cannot ship on the Mac App Store, [review] rejects private-API use" [2nd, consistent across [go-macos](https://github.com/go-macos/virtualdisplay), DeskPad and OpenDisplay docs]. Notarized Developer ID distribution works (Jump, BetterDisplay do).
- **DriverKit: no display family.** Several third-party READMEs say the public route is "a DriverKit driver extension". In the installed DriverKit 27.0 SDK the families are Audio, BlockStorageDevice, HID, MIDI, Networking, PCI, SCSIController, SCSIPeripherals, Serial, USB, USBSerial and **Video**; `VideoDriverKit` (`IOUserVideoDevice/Stream/Box/Buffer`, "CoreVideo host") is the video-device analogue of AudioDriverKit, not a framebuffer or display driver [SDK, header inspection]. I found no public virtual-display route.
- **Sidecar**: private. TN3212 covers touch input from a Sidecar iPad, not creating displays [[retained snapshot](../../References/apple/2026-09-12/sidecar-touch-tn3212.md)].
- **Apple appears to use one itself**: search excerpts say Screen Sharing's High Performance mode (macOS 14+, Apple silicon) supplies virtual displays, and Screens notes headless Macs already get a private virtual display for remote sessions [2nd; Screens page above says only the latter]. That suggests removal is unlikely soon, but there is no compatibility promise.

### 6.3 `CGVirtualDisplay` failure modes (why not pre-launch)

Documented in public trackers and vendor changelogs: SCK never lists the virtual display, offline stale displays leave streams black ([opendisplay #142](https://github.com/peetzweg/opendisplay/issues/142)); on 26.6.2 a virtual display whose mode was changed is not removed by releasing the object; resolution fallback to 1280x720 on macOS 26; missing higher HiDPI modes in macOS 27 developer beta 3 ([BetterDisplay #5614](https://github.com/waydabber/BetterDisplay/discussions/5614)); HiDPI modes advertised but not activated; teardown takes up to about 1.9 s ([go-macos README](https://github.com/go-macos/virtualdisplay)); Jump fixed Intel Macs left headless until reboot, an external monitor left black after a lid-closed session, misconfigured displays after display-settings changes, and reconnect loops with third-party display managers (Jump changelog). Positive: the window server reclaims the display when the creating process exits or crashes [2nd]. Verdict: viable only as a flagged, per-OS-allowlisted Developer ID "Labs" feature later; too much risk before 17 Nov.

### 6.4 Public alternatives that get most of the value

1. **Viewport-aware capture (no display change).** `SCStreamConfiguration.sourceRect` and `destinationRect` crop and scale on a live stream through `updateConfiguration` [SDK: `SCStream.h:289-294`]. Capturing the phone-sized region at native pixels gives 1:1 crisp text, the main benefit of a device-matched virtual display, and matches PRODUCT.md's viewport-aware encoding experiment. Costs: no reflow of the Mac layout to the phone aspect.
2. **Display-mode fit (opt-in).** `CGDisplayCopyAllDisplayModes` with `kCGDisplayShowDuplicateLowResolutionModes`; apply through `CGBeginDisplayConfiguration` / `CGConfigureDisplayWithDisplayMode` / `CGCompleteDisplayConfiguration(config, .forAppOnly)`. The SDK documents that the mode "persists for the life of the program, and automatically reverts ... when the program terminates" and that `forAppOnly` changes revert when the app exits [SDK: `CGDirectDisplay.h`, `CGDisplayConfiguration.h`; [Apple](https://developer.apple.com/documentation/coregraphics/cgcompletedisplayconfiguration(_:_:))], which is a **crash-safe restore**. Limits: only offered modes (rarely phone aspect), visible to the local user, window rearrangement, fails when another app is full screen. Also the mirror APIs (`CGConfigureDisplayMirrorOfDisplay`) exist for a crude single-master layout but reshuffle windows.
3. **Window fit.** `SCContentFilter(desktopIndependentWindow:)` per window, with AX resize to a phone-friendly frame (host is unsandboxed): ties to PRODUCT.md's "tap to fit window".
4. **Unified via compositor (post-launch, 15-20 days).** One `SCStream` per display composited (Metal) into a canvas using `SCDisplay.frame` offsets; encode only the viewport; input maps to global coordinates, which `CGEvent` already uses. No display reconfiguration and no window shuffling; pairs with the iPad mini map. Risks: multi-stream latency, GPU cost, differing scale factors, HDR.
5. **Headless.** Workbench says an Apple silicon Mac mini with no monitor creates a 1920x1080 1x display by default [[Vendor](https://astropad.com/blog/headless-mac-mini-setup-guide/)], and SCK errors include `SCStreamErrorNoDisplayList` [SDK: `SCError.h:28`]. **Not verified on hardware by us** (spike S5). Intel Macs and any Mac in an odd display state need a dummy plug or a virtual display. Headless plus the monthly re-approval prompt makes the entitlement request more urgent. Guidance (auto-login, sleep, FileVault) as in 5.5.

### 6.5 How we beat Workbench

No display reconfiguration for the default path (no Jump-style black-monitor bugs); native-pixel viewport capture; mini map/workspace canvas for multi-display; explicit "restores automatically if PocketDesk quits" for the mode-fit option; no account.

### 6.6 Effort and gate

Mode-fit 3-5 days; headless smoke test 1 day (needs a headless Mac mini); compositor 15-20; `CGVirtualDisplay` Labs 20-30 plus ongoing maintenance. **NO-GO** for virtual and unified display pre-launch. **GO (optional)** for mode-fit plus the headless smoke test. Do not adopt private declarations from community snippets without a Developer ID decision, a crash-restoration test and a kill switch (as MAC-HOST-FEATURES.md already requires).

---

## 7. Gap 5: Multi-Mac support

### 7.1 Today

Single trust record per role and no LAN discovery (2.2). The server's per-room presence (`peer{online}`) is only delivered to a client that has registered in that room; a 1-host/1-client room model means a probe occupies the client slot.

### 7.2 Recommended design

- **Phone store:** array of `PairedMac { id = room digest, name, server, key, lastConnected, lastState }`, one Keychain item per Mac (account = room). Keep `WhenUnlockedThisDeviceOnly`; iCloud Keychain sync is a later, explicit "add this Mac to my other devices" flow with its own review (losing a phone already has no independent revocation route per PRODUCT.md).
- **UI:** Mac list with name, key fingerprint (labels are not identity), presence and last-seen, "Add Mac" (existing QR pairing), swipe to remove, switch = end session A then connect B; one controller per Mac (existing "another controller" state).
- **Presence:** N short-lived signaling probes on the list screen, or add a batched `presence` op to `Server/src/server.ts` (preferable: no client-slot contention).
- **Bonjour "nearby" (optional):** host advertises `_pocketdesk._tcp` with a TXT record (room digest prefix, name, protocol version) using `NWListener`; phone uses `NWBrowser`. iOS needs `NSLocalNetworkUsageDescription` and `NSBonjourServices`; browsing needs no multicast entitlement [[DTS 655920](https://developer.apple.com/forums/thread/655920)]. Doubles as the Sleep Proxy hook in 5.2.
- **Multi-phone per Mac (iPhone + iPad):** `HostPair` becomes a list with per-phone client tokens/rooms and a Trusted Devices list with revoke (already in the Mac companion inventory). Later.

### 7.3 Distribution, effort, beat, gate

All public API, MAS-compatible. Effort: phone list 4-6 days, presence 2-3, Bonjour 3-4, multi-phone host 8-10. Beat Workbench: no account (it needs a same-account catalog), works with only a paired key, fingerprints shown, Bonjour discovery without login. **GO** for the phone-side list (small, avoids a wall for anyone with two Macs) if capacity allows; multi-phone host, Bonjour and iCloud sync after launch.

---

## 8. Sequenced plan to 17 November

| When | Work |
|---|---|
| Week of 28 Sep | Submit Persistent Content Capture request. Spikes S1-S4, S6, S7 (about 4 days total). Decide the Developer ID/notarization pipeline and identity migration. |
| 5-16 Oct | Sleep/lock/explain (Gap 3), agent + hang watchdog + ledger (Gap 2). |
| 19 Oct | Checkpoint: curtain proceeds only if these two are green and P0 streaming/relay work is on track. |
| 19-30 Oct | Multi-Mac list; curtain cover + block (conditional); optional mode-fit and headless smoke test. |
| 2 Nov | Go/no-go with fault-injection evidence attached per feature. |

### Validation spikes (each has a pass/fail)

| ID | Test | Pass criterion |
|---|---|---|
| S1 | Overlay exclusion: two-display Mac plus notched MacBook, Spaces, full-screen app, Stage Manager, hotplug; app-level exclusion; `includedWindows` assertion; is a windowless `LSUIElement` app listed by SCK | Phone stream shows the desktop, local screen black, no exposure beyond 1 frame on hotplug; also test with `sharingType=.none` removed |
| S2 | `kill -9`, `kill -STOP`, disconnect with curtain up | Overlay and tap gone within 1 s of kill; `kill -STOP` lifted by the watchdog within 3-5 s |
| S3 | Secure Event Input: focus a password field with block on | Confirms the leak and the phone banner appears |
| S4 | Lock screen matrix: Control-Command-Q, screensaver, fast user switch; SCK output; event acceptance; lock notification timing; `sessionDidResign` behavior | Documented behavior; states in 5.4 match reality |
| S5 | Headless Apple silicon Mac mini (needs hardware): SCK displays, mode list, mode change | Capture works at 1920x1080; report available modes |
| S6 | Agent + KeepAlive: kill, hang exit, Quit, Stop, logout/login, reboot, move app, permissions retained after relaunch, `relaunch()` rework | Matches 4.1 semantics; no double launch |
| S7 | Display asleep then connect: user activity, time to first frame, `didChangeScreenParameters` behavior | Frames within 3 s |
| S8 | Monthly Screen Recording prompt cadence on macOS 27 and behavior with a pending prompt | Documented; informs entitlement urgency |

### Decisions needed from Roshan

1. Confirm "iOS on App Store, Mac host Developer ID"; a Mac App Store host would drop AX text-focus, input blocking and any login-window work.
2. Is the curtain worth 12-15 days of the pre-launch window, or is it v1.1 (my lean: build only if the 19 Oct checkpoint is green)?
3. Hardware for spikes: a headless Mac mini, an M5-class MacBook, and a second display.
4. Willingness to request the Persistent Content Capture entitlement (and later the multicast entitlement) under the team account.

---

## 9. Sources

Vendor: [Privacy Curtain](https://support.astropad.com/en/articles/16401471-what-is-the-privacy-curtain-in-workbench) · [Watchdog](https://support.astropad.com/en/articles/16415600-watchdog-for-workbench) · [Display modes](https://support.astropad.com/en/articles/14026370-workbench-display-modes) · [Mac mini](https://support.astropad.com/en/articles/14062891-using-workbench-with-your-mac-mini) · [Remote access setup](https://support.astropad.com/en/articles/14010461-setting-up-your-mac-for-remote-access) · [iPhone setup](https://support.astropad.com/en/articles/14025859-setting-up-workbench-on-your-ipad-iphone) · [1.3 notes](https://astropad.com/blog/workbench-1-3/) · [9to5Mac 1.3](https://9to5mac.com/2026/08/19/astropad-workbench-1-3-adds-faster-streaming-privacy-curtain-and-more/) · [headless guide](https://astropad.com/blog/headless-mac-mini-setup-guide/) · [dummy plug](https://astropad.com/blog/dummy-plug-headless-mac-mini/) · [product](https://astropad.com/product/workbench/) · [App Store](https://apps.apple.com/us/app/astropad-workbench/id6758788573) · [MacStories](https://www.macstories.net/reviews/astropad-workbench-rethinks-remote-mac-control-for-ai-agents/) · [Jump 10](https://docs.jumpdesktop.com/whats-new/jump-desktop-10/) · [Jump virtual displays](https://changelog.jumpdesktop.com/virtual-displays-pbTZC) · [Jump changelog](https://changelog.jumpdesktop.com/) · [Jump Privacy Mode](https://support.jumpdesktop.com/hc/en-us/articles/18250305826573-Privacy-Mode-for-Fluid) and [Mac external displays](https://support.jumpdesktop.com/hc/en-us/articles/18219686885773-Mac-Privacy-mode-with-external-displays) (403; excerpts only) · [Screens Curtain Mode](https://help.edovia.com/en/screens-5/features/curtain-mode) · [Parsec Privacy Mode](https://support.parsec.app/hc/en-us/articles/32361381211284-Privacy-Mode) (403; excerpt only) · [Chrome Remote Desktop](https://support.google.com/chrome/a/answer/2799701).

Open source: [RustDesk macOS privacy mode PR 14102](https://github.com/rustdesk/rustdesk/pull/14102) · [15004](https://github.com/rustdesk/rustdesk/pull/15004) · [issue 16192](https://github.com/rustdesk/rustdesk/issues/16192) · [DeskPad](https://github.com/Stengo/DeskPad) · [go-macos/virtualdisplay](https://github.com/go-macos/virtualdisplay) · [opendisplay #142](https://github.com/peetzweg/opendisplay/issues/142), [#289](https://github.com/peetzweg/opendisplay/issues/289) · [BetterDisplay #5614](https://github.com/waydabber/BetterDisplay/discussions/5614) · [oldmac-display (Sunshine on macOS)](https://github.com/crazyathlete220-stack/oldmac-display).

Apple: [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) · [SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter) · [WWDC22 10155](https://developer.apple.com/videos/play/wwdc2022/10155/) · [CGCompleteDisplayConfiguration](https://developer.apple.com/documentation/coregraphics/cgcompletedisplayconfiguration(_:_:)) · [sessionDidResignActive](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification) · [Persistent Content Capture](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture) · [TN2150](https://developer.apple.com/library/archive/technotes/tn2150/_index.html) · forums [792152](https://developer.apple.com/forums/thread/792152), [814152](https://developer.apple.com/forums/thread/814152), [819331](https://developer.apple.com/forums/thread/819331), [795074](https://developer.apple.com/forums/thread/795074), [756908](https://developer.apple.com/forums/thread/756908), [789896](https://developer.apple.com/forums/thread/789896), [28605](https://developer.apple.com/forums/thread/28605), [756130](https://developer.apple.com/forums/thread/756130), [655920](https://developer.apple.com/forums/thread/655920), [775490](https://developer.apple.com/forums/thread/775490), [750528](https://developer.apple.com/forums/thread/750528), [71304](https://developer.apple.com/forums/thread/71304), [724740](https://developer.apple.com/forums/thread/724740) · [launchd.plist man page](https://keith.github.io/xcode-man-pages/launchd.plist.5.html) · [Sleep Proxy (Cheshire)](https://stuartcheshire.org/sleepproxy/) · [MacRumors on monthly prompt](https://www.macrumors.com/2024/08/15/macos-sequoia-screen-recording-app-permissions/).

Installed SDK headers read (Xcode 27.0, MacOSX27.0.sdk): `ScreenCaptureKit/SCStream.h`, `SCError.h`, `SCShareableContent.h`; `CoreGraphics/CGDirectDisplay.h`, `CGDisplayConfiguration.h`, `CGEvent.h`, `CGEventTypes.h`, `CGEventSource.h`, `CoreGraphics.tbd`; `AppKit/NSWindow.h`; `IOKit/pwr_mgt/IOPMLib.h`; `ServiceManagement/SMAppService.h`; DriverKit27.0.sdk framework list and `VideoDriverKit` headers.

Not verified by me: any behavior on physical hardware (curtain exposure, lock-screen capture, headless capture, Sleep Proxy wake on Apple silicon, entitlement approval timing), the launchd process-group behavior of `relaunch()`, and the undocumented distributed-notification names for lock and screensaver.
