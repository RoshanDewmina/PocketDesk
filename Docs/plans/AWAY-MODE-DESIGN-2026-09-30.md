# Away mode — design spec

30 September 2026, rev 1. **Proposal; not approved, no code.** Subordinate to PRODUCT.md (D04, F09–F11, §7, §8). **VERIFIED** = Apple header/doc or local read-only check (macOS 27.0.1); **V2** = secondary report; **INFERRED** = design reasoning, test first. Lines from `86d643a`.

## 1. What Roshan asked for, and why

One opt-in switch that keeps the Mac awake and unlocked only while sharing is on and Away mode is armed, with the screen covered, so the promise becomes "your Mac stays reachable and private while you're away".

Launch risk: Farside tears sharing down on lock (`HostKeepAwake.swift:55-63`, `HostModel.swift:1786-1806`) and lets the display sleep when no phone is connected (`HostKeepAwake.swift:35-37`). macOS can require the password when the display turns off or the screen saver starts (VERIFIED, Apple mchlp2270; "Immediately" default V2). So an unattended Mac probably locks soon after display sleep and paid Anywhere access fails (PRODUCT line 15 records this physically). This is option (b), with (c) as fallback. Out of scope: remote unlock, storing or typing the password, changing any system setting.

## 2. User experience

**Mac Settings** (under "Keep this Mac awake", `HostSettingsView.swift:64`): **Away mode**, off by default. Subtitle: "Keep this Mac unlocked for your iPhone while you're away. The screen is covered and the Mac locks if anyone touches it."

**Turn-on sheet (at the Mac, shown once):**
> While Away mode and sharing are both on, Farside keeps this Mac awake and unlocked so you can reach it from your iPhone. After 2 minutes with nobody using it, Farside covers the screen. If anyone touches the keyboard, mouse or trackpad, the Mac locks straight away, and you unlock it with your password as usual.
> **What it can't do:** keep a MacBook awake with the lid closed (unless it's on power with an external display, keyboard and mouse); survive a power cut, restart or macOS update (after a restart, someone has to sign in at the Mac); unlock a Mac that's already locked; or hide notification sounds. It never changes your security settings, and Farside never sees your password.
> Away mode needs power. On battery it ends after 5 minutes and the Mac locks. It also ends, and locks the Mac, after 24 hours without a phone connection.
> [Turn On Away Mode] [Cancel]

**Popover** (armed): "Away mode · covers in 1:40", or "Away · covered, locks if touched", with **Cover now** and **Turn off**. Warnings (one line each): "On battery — Away mode ends in 4:12", "Your organisation manages this Mac's lock settings — Away mode unavailable", "Needs Accessibility".

**Phone:** session chip "Mac covered · locks if touched"; Controls gains **End and lock Mac** (locking is the safe direction); the Mac list shows "Away mode was on when you last connected" (last-known, labelled). If the Mac locked anyway, today's locked message gains "Away mode can't unlock it."

## 3. Mechanism

**States:** `off` → `armedPresent` (someone is using the Mac, no cover) → `armedCovered` (cover up with or without a phone) → `ending` (lock, then release). Arming requires sharing on, Accessibility granted, AC power, no managed lock policy, and a Mac that is not locked.

| Piece | Design | Evidence |
|---|---|---|
| System sleep | Keep today's `PreventUserIdleSystemSleep` (`HostKeepAwake.swift:13`) | VERIFIED: it does not stop lid-close, Apple-menu or low-battery sleep, and has no effect in Dark Wake (`IOPMLib.h:285-289`) |
| Display-off lock | Hold `PreventUserIdleDisplaySleep` while armed, **even with no phone connected**. Today it is held only while connected (`HostKeepAwake.swift:36`). Change to `display = keepAwake && sharing && (phoneConnected \|\| awayArmed)` | VERIFIED: it stops idle display-off and so also idle system sleep (`IOPMLib.h:296-312`). `NoDisplaySleepAssertion` is a deprecated alias (`IOPMLib.h:1033-1037`) |
| Screen-saver lock | **Not controlled by any documented API.** Display assertions reportedly don't stop the screen saver (V2: Apple forum 26776, Jan 2022). A periodic `IOPMAssertionDeclareUserActivity` may reset its timer (V2, conflicting). Spike S1 decides; see Q4 | INFERRED |
| Reading lock settings | Don't: on 27.0.1 `com.apple.screensaver` has no `askForPassword*` keys and `sysadminctl -screenLock status` requires `-password` | VERIFIED locally, read only |
| Managed Macs | `CFPreferencesAppValueIsForced` on `com.apple.screensaver` keys (`idleTime`, `askForPassword*`) → Away mode unavailable | VERIFIED that the API is public; which keys MDM forces is INFERRED |
| Cover | Reuse curtain windows (`PrivacyCurtain.swift:304-321`) without a session; today they need `sessionLive` + healthy capture (`:51-59`, `HostModel.swift:975`). New policy input `awayCovered`. On connect, start capture with the windows already excluded; never lift/re-raise; capture loss never lifts it | INFERRED |
| Idle → cover | 2 min without *local* input, from our own monitor (system idle counters would include phone input, posted at the HID tap, `RemoteInputDriver.swift:115`) | INFERRED |
| Touch → lock | Global key/mouse/scroll monitors ignore tagged injected events (`RemoteInputTag`, `PrivacyCurtain.swift:290-292`). Any local event while covered → lock. **Esc ×3 locks instead of revealing** (`:240-244` today reveals) | INFERRED |
| Lock action | Post the system Lock Screen shortcut ⌃⌘Q via CGEvent (Accessibility held), confirm with `HostScreenLock.isLocked()` (`HostKeepAwake.swift:73`). Not locked in 2 s → release assertions, keep cover, let the user's own display-sleep lock apply. Private `SACLockScreenImmediate` rejected | INFERRED; S2 |
| Battery | `IOPSGetProvidingPowerSourceType` (VERIFIED, `IOPowerSources.h:307`). Arm on AC only; on battery: no phone → end after 5 min, phone → end at 20 %. Low Power Mode (`isLowPowerModeEnabled`, macOS 12+, VERIFIED) → warning | INFERRED policy |
| Expiry | 24 h without a phone session → `ending` | INFERRED |
| Crash / hang | Windows vanish with the process (MAC-GAPS §3, V2). Add `awayCoverUp` to the watchdog record (`HostWatchdogReporter.swift:58`); the relaunched host **locks first** (fail-closed). Hang threshold stays 4 s (`HostHangWatchdog.swift:33`) | INFERRED |
| Every exit | Stop Sharing, Quit, expiry, battery, End and lock → lock, then release. Setting turned off at the Mac → release only | INFERRED |

Protocol: feature `away.1`; `capture` status `away: off|armed|covered`; phone action `lockMac` gated like `curtain`.

## 4. Security and privacy

Threat: someone physically at an unlocked, covered Mac while the owner is away.

| Attack | Mitigation | Residual |
|---|---|---|
| Moves mouse, clicks, types | Locks on the first local event | That event is **delivered** (listen-only; curtain ignores mouse, `PrivacyCurtain.swift:311`); one click/keystroke can land (S3). Active tap closes this (Q2) |
| Focused password field (Secure Event Input) | Keystrokes aren't seen, but mouse/trackpad input still locks | Typed keys reach that field (TN2150, via MAC-GAPS) |
| USB keystroke injector | First key triggers the lock | Can type many characters first; active tap reduces this |
| Waits for a crash | Relaunch locks first | Uncovered and unlocked for about 2–4 s (watchdog relaunch) |
| Reads the covered screen | Opaque shielding-level windows | The pointer is visible; notification banners above the shielding level are untested (MAC-PARITY §5) |
| Closes the lid / cuts power | The Mac sleeps or dies, and waking needs the password | None added |
| Holds the owner's paired phone | Unchanged pairing trust | Mac reachable for longer |

Not covered: software already running on the Mac, Keychain items open while unlocked, action before the first detected event. Copy says "covered and locks if touched", never "locked" or "secure". Away mode is visible, time-bounded and user-chosen; no setting changes, and the Mac's own lock applies whenever it's off.

## 5. App Review and notarization

Mac host is Developer ID (D30); notarization doesn't review behaviour (research doc A2). All public API (IOPM, NSWindow, CGEvent, NSEvent, IOPS, CFPreferences); the existing undocumented lock notifications are unchanged. iOS gets status and **End and lock Mac**, no unlock or password UI. Metadata: "reachable while you're away", never "unlock remotely" (2.3). Low risk.

## 6. Free vs Anywhere

All plans: it's a Mac-side safety feature and the lock problem exists on the LAN too. Anywhere marketing leads with it. No server change (D28 unaffected).

## 7. Edge cases

| Case | Behaviour |
|---|---|
| Lid closed | Sleeps (VERIFIED header). Clamshell with power, an external display and input stays awake (V2). The copy says so |
| Power loss / restart / OS update | Ends; Mac returns at FileVault/login window where Farside can't run (research doc A3–A4) |
| Fast user switch | Existing teardown (`HostKeepAwake.swift:58`); the cover goes with our session. Switching back needs the password |
| FileVault | Unaffected while running; blocks after a restart |
| Screen saver, hot corner or manual display sleep | Lock follows, existing teardown; recorded for the readiness warning |
| Monitor plugged in while covered | The curtain rule today lifts on screen change (`PrivacyCurtain.swift:297-300`). **Away: lock instead** |
| Low battery sleep | Can't be prevented (VERIFIED); the battery rule ends Away mode first |
| Managed Mac | Unavailable, with an explanation |

## 8. Testing

Automated: power truth table with `awayArmed`; Away state machine (preconditions, idle → covered, touch → lock, every exit locks, expiry, battery); local/injected classifier on tagged fake events; cover without session, connect without re-raise; relaunch → lock; lock-confirm timeout → release; `away.1` gating; forced-preference reader.

Physical (quiet window, macOS 26 and 27):
**S1** screen saver 2 min + password Immediately + display off 2 min, armed, no phone, 30 min: locked? (again with periodic user activity). **S2** posted ⌃⌘Q locks; `isLocked` confirms. **S3** local-event-to-lock latency. **S4** `kill -9` while covered: seconds exposed. **S5** unplug AC; close lid. **S6** away 2 h, connect from cellular, End and lock.

## 9. Size, order, and 3 November

About **7–10 engineer-days** (state machine/power 1; sessionless cover + exclusions 2; local input + lock 1.5; fail-closed relaunch 1; battery/expiry/MDM 1; UI + phone 1; tests 1; physical 1–1.5). Order: **S1 + S2 first (1 day, go/no-go)**, then host core, cover, relaunch, UI, phone. Fits only if S1/S2 pass by ~10 Oct and merge by ~22 Oct; otherwise 1.0 ships (c) "needs your Mac awake and unlocked" plus a locked-while-sharing readiness warning (~0.5 day, needed anyway), Away mode in 1.1.

## 10. Open questions for Roshan

1. **Ship in 1.0?** (A) Yes, if S1/S2 pass by 10 Oct, else fall back to (c) — *recommended*; (B) 1.1 regardless, with (c) copy in 1.0; (C) only tell users to change lock settings (option a).
2. **Local touch policy while covered.** (A) Listen and lock on the first event (the first event lands) — *recommended for 1.0*; (B) active event tap swallows local input, then locks (+2–3 days, secure-input hole remains); (C) today's cover with Esc ×3 reveal (rejected: an unlocked Mac one keypress away).
3. **Power rule.** (A) Arm on AC only; on battery end after 5 min with no phone, or at 20 % with one — *recommended*; (B) allow battery down to 30 %; (C) no battery rule.
4. **If S1 shows the screen saver still locks the Mac:** (A) detect it and explain at the Mac, with a deep link to Lock Screen settings, the user's choice — *recommended*; (B) declare user activity periodically to hold it off (pretends someone is active; disabled on managed Macs); (C) mark Away mode unavailable on those Macs.

## Decisions — 30 September 2026

Roshan approved this design and every recommended answer to the open questions above ("Sounds good … go ahead"). Implementation is authorized on a feature branch; no install, merge into `pocketdesk-remote-chat`, deployment or submission without his separate go-ahead.
The S1 (screen saver) and S2 (posted lock shortcut) feasibility tests lock or idle the Mac and must be run by Roshan, not by agents; the go/no-go for 1.0 still depends on them by about 10 October.
