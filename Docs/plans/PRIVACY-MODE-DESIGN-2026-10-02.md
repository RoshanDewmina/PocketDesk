# Privacy mode — design

2 October 2026, revision 2 (after the independent design review, see §8). Status: **Roshan decided this morning that the Mac goes into a privacy mode by default when a phone connects, changeable in settings.** This file records how that is done. Subordinate to PRODUCT.md (D55 for Big Text). Line numbers are from `claude/batch-6` 20aded1 unless marked (b7).

## 1. What Roshan asked for

- By default, when a phone connects, the person at the Mac does not see what the phone user is doing, and their own screen is not visibly rearranged.
- The phone picture stays crisp and phone-friendly; quality first; simple and automatic.
- One setting for people who need to watch at the Mac (today's Big Text-on-the-real-screen behaviour).
- Launch ~27 Oct, universal iPhone + iPad.

## 2. Decision

**Privacy mode is the existing privacy curtain, turned on by default, with Big Text unchanged underneath it, plus four continuity fixes so the curtain never drops in the middle of a session and the Big Text mode switch happens under it.** Nothing new is built on the display side; the default flips, the copy says what it does, an internal kill switch restores the old default, and explicit prior choices survive.

Why this and not the others:

| | (a) Phone-shaped virtual display + curtain | **(b) Curtain over the real display, Big Text mode as today** | (c) Both |
|---|---|---|---|
| Local person sees phone activity | No, if every window the phone uses sits on the virtual display | **No: opaque shielding-level windows on every display, all Spaces and full-screen apps** (`PrivacyCurtain.swift:453-470`) | as (a) |
| Local screen rearranged | Mode untouched, but windows must be moved to a 1311×603 pt desktop and back (AX, cross-display, full-screen Spaces cannot move) | Big Text changes the mode; windows can shift and are restored best-effort (`BigTextWindows.swift`, D55). With rev 2 the switch waits for the curtain and the restore finishes under it, so the person sees neither (§4) | worst of both |
| Phone crispness | 1:1 phone pixels at 2622×1206 (the quality win) | Streamed 2560×1656 scaled 0.73× into the phone; the scroll/codec lanes own that | as (a) |
| Restore on disconnect / crash | Display removed on release and on `kill -9` in 224 ms (vdisplay NOTES Q5); window positions would need a cross-display snapshot that does not exist | `.forAppOnly` reverts on normal termination per Apple; SIGKILL revert is unproven (`BigTextDisplaySwitcher.swift:107-108`). Curtain windows die with the process; hang watchdog 4 s while covered, 12 s during a display change (`HostHangWatchdog.swift:33-41`), helper heartbeat 1 s (`HostWatchdogReporter.swift:9`) | both |
| Multiple displays / external monitor | Unknown with the ASUS attached; mirror never run | One curtain per `NSScreen`; a foreign display change lifts it and restarts the session (`PrivacyCurtain.swift:357-365`) | |
| Lock screen / screen saver / display sleep | untested | Locked → curtain down and sharing ends; display asleep → curtain stays so waking never exposes the desktop (`:62`) | |
| Menu bar, Dock, notifications | Virtual display has its own menu bar; Dock follows the pointer | Covered locally; the phone still sees them. Notification banner layer not verified (§6 E3) | |
| 60/120 fps | Content capped at 60 in the spike; 120 unproven | Unchanged capture path; exclusion costs no frames, a few points of WindowServer CPU (§6 E1) | |
| App Review / notarization | Private `CGVirtualDisplay` SPI looked up at run time (`VirtualDisplaySpike.swift:548-592`); Developer ID so possible, but every macOS update is a risk | Public API only | |
| Readiness for 27 Oct | Spike only; rotation 0.46 s, portrait→landscape lands on 1× first, mirror/sleep untested | Shipped on-device since 28 Sep (ledger MH06); Roshan's Mac already has it on (`privacyCurtainWhileSharing = 1`) | |

(a) stays the 1.1 path for quality: it removes the mode switch and the scaling at once. It is not launch-safe with "bulletproof restore" and an untested window-moving layer.

## 3. User experience

**Mac.** Settings → "While your iPhone is connected" keeps one switch, **Hide this Mac's screen**, now on by default. Subtitle: "On by default. Your phone still sees everything; press Esc three times at this Mac to show it." Greyed out while sharing a single window or app, with that reason. The popover row says the same. While covered the Mac shows "This Mac is being used remotely · Press Esc three times to show this screen" (`PrivacyCurtainView`). Turning it off at the Mac or from the phone is the "show on Mac screen" behaviour: today's Big Text on the real screen.

**Phone.** No new control: the session panel's **Hide Mac screen** row and Settings → Mac privacy already exist and write the same Mac preference (`RemotePhoneApp.swift:1884-1888`, `HostModel.swift:3214-3226`). Default-on shows no pill. Pills only for "lifted at the Mac", "failed", and (new) "can't hide its screen until Farside has Accessibility there", once per session (`SessionContinuity.swift` `curtainChange`).

**When it cannot apply**, the Mac stays visible and says why: Accessibility missing, stream check failed, window- or app-scoped sharing, Couch mode (no picture, so nothing to hide), safe mode after crashes.

**First connect from setup.** The person who pairs is sitting at the Mac; their first connect covers it with the explanation line above while the phone shows "Covered · Esc three times at the Mac lifts it". Chosen on purpose: one consistent behaviour that teaches the feature, instead of a special case the next session would contradict.

## 4. Mechanism

Existing (20aded1):
1. Capture becomes healthy → `reconcileCurtain` → `raise`: windows at alpha 0 on every screen, `excludeWindows` on the live SCContentFilter, 150 ms settle, luma signature, windows opaque, 500 ms later a second signature; curtain-dark stream → lift and report `.failed` (`PrivacyCurtain.swift:231-275`, `RemoteCapture.swift:497-535`).
2. Big Text's change: `bigTextStateChanged` (before `bigTextQuiesce`, `BigTextController.swift:253-256`) grows the curtain windows by a coverage envelope, the quiesce stops capture keeping the exclusions, the mode switches (~330 ms measured by the b7-bigtext lane), `bigTextResume` restarts with the exclusions kept (`HostModel.swift:3600-3639`, `3666-3675`).
3. Esc×3 at the Mac lifts for the session and tells the phone (`liftedLocally`), which offers "Hide it again".

Added in this lane (b7), all at HostModel call sites and in `PrivacyCurtainPolicy`, separable from the b7-bigtext controller work:
4. **Big Text waits for the curtain.** The session's first `displayScale` request is held up to `scaleHoldLimit` (1 s) while the curtain is expected to go up (`curtainWillCoverSoon`), then applied; a raise failure or Esc×3 releases it at once. The mode switch and the window shuffle happen under the curtain.
5. **Session end keeps the curtain through the restore, keyed off a restore actually running.** `stop()` and `endCapture()` call `liftCurtain(holdingForRestore: true)`: with the curtain up and Big Text engaged, the curtain stays (policy input `restoreHold`). If no restore has started within `restoreHoldDetect` (1.5 s) the hold ends and the Mac uncovers (that is the reconnect grace after a dropped connection, 20 s today). If a restore is observed (`bigTextStateChanged` with `isChanging`, or one already running), the hold lasts until `restoreHoldShouldEnd` (restore finished and the host's `bigTextNeedsRefresh` cleared, which outlives Big Text's phase so the window moves are done) or `restoreHoldLimit` (3 s). During the hold the stream stops but its window exclusions are kept (`endCapture` → `capture.stop(keepingExclusions: curtainRestoreHold)`), so a reconnect starts the next stream with the curtain already excluded; Esc ×3 during the hold only ends it and never pre-dismisses the next session. **Integration dependency:** on 20aded1 every phone End or drop goes through `connection.onEnded → bigText.connectionLost()` (20 s grace), so only Mac "Stop Sharing" restores at once; the b7-bigtext lane's capability-gated explicit-End signal makes a deliberate End restore within ~1 s, which must stay under the 1.5 s detect window for the hold to cover it.
6. **Phone background keeps the curtain.** `pauseForPhoneBackground` cancels a half-raise, stops capture keeping the exclusions, and the policy keeps a raised curtain for `pausedHold` = `BackgroundContinuity.maximumHold` (25 s); resume restarts with the exclusions kept. The lifecycle timer keeps reconciling while paused, so the cap is enforced.
7. **One restart helper.** `restartCapture()` = cancel a half-raise, `beginCapture(keepingExclusions: curtain.phase == .up)`; used for the audio toggle, leaving view-only, Couch→picture, display switch and resume. A raise overtaken by a capture restart (`captureAttempt` changed) is retried, never recorded as `failed` for the session.
8. **Silent phone.** In picture mode the phone heartbeats every 0.25 s (`RemotePhoneApp.swift:2897`); after `phoneSilenceLimit` (10 s) of silence the curtain is down, raised or not, even before the media link reports `disconnected` (`RemoteCoordinator.swift:1363`). Mac capture stays healthy when the phone vanishes, so the rule applies regardless of phase to avoid flapping. Resume after a phone background resets the heartbeat clock.
8a. **Luma check and restarts.** The raise's second luma signature returns nil when the capture attempt changed since the raise began (Big Text's switch can land inside the 500 ms check), so a dark mode-switch frame never lifts the curtain mid-change.
9. **Diagnostics.** The session report gains `curtainOn`, `curtainCovered`, `curtainLiftedAtMac`, `curtainFailed` facts (`SessionDiagnosticReport.swift`), written at `endCapture`.

## 5. Changes in this lane

- `HostPreferences.privacyCurtain`: default **true** unless the internal defaults key `privacyModeDefaultOff` is set; an explicit stored value always wins (`RemoteHost/HostReadiness.swift`).
- `PrivacyCurtainPolicy`: `pausedFor`, `phoneSilentFor`, `restoreHold` inputs and their limits; `PrivacyCurtainController.cancelRaise()`.
- `HostModel`: §4 items 4–9.
- Copy: Mac setting subtitle (default, Esc, scoped reason), curtain line, phone row caption and footer for Off, the Accessibility notice.
- Tests: preference default/explicit/kill switch, policy (paused hold, silence, restore hold), notices, copy.
- No protocol change: `curtain.1` is already advertised and gates every phone control; an older phone sees `curtain: up` on `capture` status as before; an older host ignores nothing new because the phone sends nothing new.
- Kill switch: `defaults write com.roshan.PocketDesk.RemoteHost privacyModeDefaultOff -bool YES`.

## 6. Evidence gathered before build (harness `perf-push/b7-privacy/harness/`, never the installed host)

- E1 Exclusion cost (QUIET window 05:37, load average 70–315 because other lanes were running simulators): delivered fps with/without the excluded curtain 57.7/57.8 and 57.4/57.6; WindowServer CPU +4 to +10 points with the exclusion (+1 to +4 for the window alone). No frame-rate cost; a quiet re-measure is owed.
- E2 Click pass-through: a `CGEvent` click posted under the shielding-level `ignoresMouseEvents` curtain reached the window beneath 3/3.
- E3 Notification banner layer: not verified; the harness's `display notification` produced no banner window. Three WindowServer-owned windows (cursor, shields) sit above the shielding level; app windows do not.
- E4 Device acceptance (Roshan): see the lane report's steps: 20 connects with Big Text on, an external display attached, Mission Control, Spaces, Stage Manager, a full-screen app, phone backgrounded, Mac "Stop Sharing" (restore finishes covered today), phone End (finishes covered only once the b7-bigtext explicit-End signal is integrated; on 20aded1 the Mac uncovers after 1.5 s and restores at 20 s), airplane mode (curtain down within ~10 s).

Kill switch and default are read when the host launches (`HostModel.init` copies the preference); changing `privacyModeDefaultOff` takes effect at the next host launch.

## 7. Risks and what remains

- A dropped connection (not a deliberate End) leaves the Mac in Big Text and uncovered from 3 s after the drop until the 20 s grace restore. Chosen on purpose: a black Mac with no phone is the worse failure.
- Local keyboard, mouse and trackpad still reach the apps under the curtain (the curtain covers pixels, not input, MH06), and Esc presses at the Mac reach whatever app the phone user is in before the third one lifts the curtain. Away mode owns local-input lockout; privacy mode does not claim it.
- Notification banners from the Mac's own apps may appear over the curtain locally; no public API suppresses them. They are the Mac owner's notifications, not the phone user's activity.
- The pointer moves over the black curtain. Hiding it system-wide would also hide it from the stream unless the phone draws its own pointer in every mode; left for later.
- Marketing and ledger copy that calls the curtain "opt-in" (ledger MH06, security row) needs updating by the simplify/marketing lanes.

## 8. Review

Revision 1 was reviewed on 2 October by an independent Claude Opus agent (fresh context, read-only): **build with changes**; rejecting (a) for 1.0 justified. P0: phone backgrounding uncovered the Mac for up to 45 s then flickered; the mode switch and the end-of-session restore happened in view. P1: other capture restarts lifted and re-raised, and a restart during a half-raise failed the curtain for the session; the phone was never told when Accessibility blocks the curtain; a vanished phone depended on media-link detection; curtain outcomes were not in the diagnostic report. P2: three citations, a false "failed" after a capture-owner change, copy, first-run behaviour, local input. All P0/P1 items are in §4; P2 items are in §3, §4.7 and §7.
