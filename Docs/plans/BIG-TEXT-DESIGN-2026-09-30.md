# Big Text — design spec

30 September 2026, revision 2. Status: **design, awaiting Roshan's review. Nothing is implemented.** PRODUCT.md D38 records the decision; this file holds the engineering design. Physical behaviour below is a requirement to verify, not an observed result.

Revision 2 incorporates an independent adversarial review (Claude Opus, same day; see §11). Its critical findings were checked against the source before being accepted.

## 1. What Roshan asked for

- While a phone is connected, the Mac switches to a larger text size ("looks like" scaled mode); when the session ends it goes back.
- The person picks the size. It is remembered **per phone and Mac pair**: this iPhone remembers its own level for this Mac, and an iPad paired with the same Mac can keep a different one.
- It applies **automatically on connect** once a level is saved. A quick control turns it off for the current session only, without forgetting the saved level. Default is Off.
- Approach A (chosen 30 Sep): switch the Mac's real display scaling. Rejected: a phone-shaped virtual display (separate, heavier project) and macOS Zoom (blurry pixel magnification, not safely controllable).

Why it matters: the launch promise is readable small text without lag. A larger "looks like" mode renders natively sharp at the new size, enlarges the whole interface (menus, controls, text) rather than one zoomed region, and has fewer pixels to capture and encode. The encode effect must be measured, not claimed. Before implementation, compare against the existing sharp viewport capture (`capture.viewport.1`) on the same text sample, so the value over zooming is shown rather than assumed.

## 2. User experience

**Choosing a level (phone).** Controls → Settings → Picture gains a **Big Text** row listing the steps the streamed display offers: `Off` (the Mac's own setting) and up to four larger steps, each captioned "looks like 1280 × 832". Changing the step applies after a 0.6 s pause (debounced, because each change costs a brief freeze) and saves immediately. During the change the phone shows "Making text bigger…" over the last frame and blocks input until the new picture and epoch arrive. If no answer arrives within 8 s the pill clears and the row shows "Couldn't change text size".

**Every later connection.** If this phone saved a level for this Mac and display, the phone asks for it once the host advertises support. The session starts at normal size and switches within about a second under the pill. A saved level at or above the Mac's current size does nothing, silently.

**Session-only off.** No new row in the fixed D36 panel (it does not scroll and has no room on small iPhones). The existing **Display** key gains a Big Text state: long-press or its menu offers "Big Text: On / Off for this session". The same menu appears on the landscape and iPad one-row overlay. With no saved level, it opens the Picture page.

**On the Mac.** The physical screen shows the larger size while a phone is connected (the privacy curtain can still cover it). The menu-bar popover shows "Big Text on · looks like 1280 × 832" with a **Restore normal size** button, which ends Big Text for the session. Mac Settings gains **Allow a connected phone to change text size** (default on); off hides the feature from phones. Windows on other Spaces also shrink and may not be restored (§5); the setup copy says so once.

**When it cannot apply.** The session continues at normal size with one short message:
- "Can't change text size while an app is full screen on your Mac."
- "Big Text needs Accessibility permission on your Mac."
- "This display doesn't offer larger sizes."
- "Big Text is turned off on this Mac."

## 3. Which steps are offered

The host builds the list from `CGDisplayCopyAllDisplayModes` (duplicate low-resolution modes included) for the streamed display and keeps a mode only if it:
1. `isUsableForDesktopGUI()`,
2. is HiDPI (`pixelWidth == 2 × width`),
3. matches the baseline's aspect ratio (±0.5 %) and refresh rate,
4. is smaller in points than the baseline (bigger text; "More Space" is out of scope),
5. is not a duplicate of an already kept width/height.

Keep at most four, spread evenly from the list sorted by width descending. The **baseline** is the mode current when the first Big Text change of the session happens; `Off` means the baseline.

The phone stores the chosen step as `looksLikeWidth` (points), not an index. The host applies the offered step with the nearest width; none within 10 % → `unsupported`, and the phone keeps its saved value.

## 4. Host behaviour — a state machine

States: `idle` → `changing(target, generation)` → `applied(baseline, current)` → `restoring(generation)` → `idle`. One change at a time; requests arriving during `changing`/`restoring` replace a single pending "latest request", which runs next. Every request gets a reply (§6); nothing is dropped silently.

**Before any change (apply or restore):**
1. Quiesce like `pauseForPhoneBackground`: release remote-held input, expire input tokens, advance the input epoch, disable input, and stop capture. The capture-ownership guard discards any late stop/failure from the old stream, so it cannot reach `captureFailed()` and end the session.
2. Keep the privacy curtain windows up if they are up (§4.4).
3. On first apply only: snapshot windows (§5) and record the baseline mode.

**Performing the change.** `CGBeginDisplayConfiguration` → `CGConfigureDisplayWithDisplayMode` → `CGCompleteDisplayConfiguration(config, .forAppOnly)`. `.forAppOnly` scope: Apple documents that after the application terminates the settings revert to the current login session configuration. On failure: cancel the configuration, resume capture at the unchanged size, reply with the error (`fullScreen` when another app is full screen, else `failed`).

**4.1 Recognising our own change.** Register `CGDisplayRegisterReconfigurationCallback` for the host's lifetime. Our change is recognised only when all hold: the state is `changing`/`restoring`; the after-change callback for the streamed display carries `setModeFlag` and no add/remove flags; the online display list is unchanged; and `CGDisplayCopyDisplayMode` equals the target. Multiple callbacks and `didChangeScreenParametersNotification`s for the same generation coalesce into one completion. Timeout 10 s (external monitors can be slow); on timeout, treat the state as foreign (§4.3).

**4.2 Completing the change.** After recognition plus a 300 ms settle:
1. Re-enumerate displays explicitly with a generation-guarded `SCShareableContent` fetch. `loadDisplays()` cannot be reused because it returns early while a session is active (`HostModel.swift` `guard !active`); the stale `SCDisplay.frame` would otherwise feed capture geometry and the input driver's bounds (`RemoteInputDriver.configure`).
2. Check the new `SCDisplay.frame` against `CGDisplayBounds` for the streamed display; mismatch → retry the fetch once, then treat as foreign.
3. Start capture on the refreshed display with a filter that already excludes the curtain windows, send the new geometry and epoch, re-enable input, send `displays` with `scaleCurrentWidth`.
4. On first apply: record each snapshotted window's post-change frame (§5).

**4.3 Changes we did not make.** Today every screen-parameter change stops sharing (`HostModel.swift` ~352), and the curtain observer lifts the curtain. Keep that for any change not recognised in §4.1, with one addition: if the streamed display's mode changed for any other reason (for example the person picked a resolution in System Settings), **forget the baseline without restoring it**, so we never overwrite their choice. Restore windows only if the display still has the mode we set.

**4.4 Curtain during a change.** A capture restart currently drops the curtain's capture exclusions, which lifts the curtain and would show the physical screen for 1–3 s on every step. Instead, for our own changes: leave curtain windows up, resize them in place to each screen's new frame once §4.1 recognises the change, and start the new stream with the curtain windows already excluded. The curtain's screen-change observer defers to the Big Text state machine while it is `changing`/`restoring`.

**4.5 Restoring.** Restore is wired to the points every session ends through, not to a list of user actions: `endCapture`, `stop`, `stopForTermination`, a display switch (phone or Mac side), `captureFailed`, pairing removal, and Screen Recording revocation. It restores the baseline mode (same `.forAppOnly` call and §4.1 recognition), then restores windows (§5). A background pause still inside its grace period keeps Big Text. On an unexpected disconnect, wait 20 s before restoring so a quick reconnect does not cycle the mode twice.

If a restore cannot run or fails (for example at sleep, lock or user switch), set a persistent **restore pending** flag in memory and retry on wake, unlock and session-active notifications. The popover shows "Restoring normal size…" while it is pending.

**4.6 Crash, hang and quit.**
- Normal quit: `stopForTermination` restores the mode synchronously; window restore is skipped if it cannot finish within 1 s (quit must stay prompt).
- Crash or watchdog kill: macOS reverts the mode on termination per the `.forAppOnly` documentation. Reverting after SIGKILL is inferred, not documented; it is a physical test gate (§9).
- Hang: while Big Text is applied, the hang watchdog treats the host like "curtain up" (`HangWatchdogPolicy.threshold` returns the 4 s curtain threshold), so a hung host is killed and the mode reverts rather than staying large until someone force-quits.
- Windows are not restored after a crash in this version (no on-disk snapshot). Accepted trade-off: crashes are rare, and a stale snapshot applied later is worse than shrunken windows.

**Note on the scope:** on host exit macOS reverts to the login-session configuration, which includes any earlier `forSession` change and could also undo another app's app-only mode (for example a display utility). This is acceptable and noted in support documentation.

## 5. Window restore (in memory only)

Shrinking the usable area makes macOS shrink windows that no longer fit, and it does not grow them back.

**Snapshot, before the first change.** For every standard window on the streamed display, keep in memory: the `AXUIElement` reference, its owner PID, the `CGWindowID` matched through `CGWindowListCopyWindowInfo` (owner PID and bounds only; the window name key is never read), and its position and size. Titles and contents are never recorded. Minimised and full-screen windows are skipped. Nothing is written to disk.

**After the change settles**, record each window's post-change frame.

**Restore** re-applies the pre-change frame only to windows that still exist (same `AXUIElement`/`CGWindowID`) and are still at their recorded post-change frame, so windows the person moved or resized during the session are left alone. Apply largest first; ignore refusals. Skip restore entirely when Stage Manager is on.

**Threading.** All Accessibility calls run off the main thread with a 0.1 s messaging timeout (as `HostCursorShape` does), so a slow app cannot stall the main thread into the hang watchdog. Restore starts only after §4.1 recognises the restoring mode change plus the 300 ms settle.

Big Text is offered only when the host has Accessibility permission, because without it windows cannot be restored. View-only sessions whose Mac has Accessibility granted can still use it.

## 6. Protocol

- New capability `SessionFeature.displayScale = "display.scale.1"`, in `SessionFeature.host` only when the Mac setting (§2) allows it. The phone sends scale actions only to a host that advertises it.
- `DisplayDescriptor` gains optional `scaleSteps: [ScaleStep]`, `scaleBaselineWidth`, `scaleCurrentWidth`. `DisplayDescriptor` and `RemoteAction` use synthesized `Codable`, which ignores unknown keys, so older phones decode these safely. `ScaleStep` is `{ width, height }` in points, validated like the descriptor: finite, 1…20 000, at most 4 entries, all smaller than the baseline.
- New phone → host action `displayScale` with `display` and `looksLikeWidth` (points; `0` = Off for this session). Add `displayScale` to `RemoteAction.displayActions` and to the actions that may carry `display` in `validateDisplaySelection`, with the same stray-field rules.
- The host always replies with `displays` (refreshed list, `scaleCurrentWidth`) and an optional `scaleError`: `fullScreen`, `noAccessibility`, `unsupported`, `disabled`, `busy`, `failed`. `busy` is sent only when a request is superseded before it runs, and is followed by the reply for the latest request.
- Requests with a stale epoch get a `displays` reply carrying the current epoch rather than silence, so the phone's pill cannot wait forever (plus the 8 s phone timeout in §2).

## 7. Phone storage

Follow `DisplayMemory` (`RemoteShared/DisplaySelection.swift`): a `BigTextMemory` in `UserDefaults`, keyed by a hash of the pairing room (`"farside-bigtext|" + room`), then by display using `DisplayMemory`'s id-plus-unique-name fallback, so an external monitor whose ID changes after a reboot still matches. The value is `looksLikeWidth`. It never leaves the phone and is deleted with the pairing. An iPad paired with the same Mac has its own storage, which gives the per-pair behaviour.

## 8. Edge cases

| Case | Behaviour |
|---|---|
| Phone switches display mid-session | Restore the old display (mode and windows), then apply the saved level for the new display, if any |
| Streamed display unplugged | Foreign change: today's stop behaviour; no mode left to restore on it; restore other windows where possible |
| Person changes resolution in System Settings during a session | Foreign change: stop as today, forget the baseline without restoring, never overwrite their choice |
| Monitor plugged in during our change | Add flag seen → not our change → today's stop behaviour |
| Two quick step changes | Phone debounce; host keeps only the latest pending request |
| Host hangs while applied | Hang watchdog uses the 4 s threshold; mode reverts on kill |
| Stage Manager on | Mode changes work; window restore skipped |
| Mac setting off | Capability not advertised; phone hides the row and Display-key option |
| Mac already at the largest step | Only `Off` offered; row says "Already at the largest size" |
| Older host | Row and Display-key option hidden |

## 9. Testing

Automated (core and phone suites; the display-configuration, reconfiguration-callback, SCShareableContent and Accessibility APIs are injected, so no real display changes):
- Step builder over captured mode lists from the M4 Air built-in display and at least one external monitor: GUI-usable, HiDPI, aspect/refresh match, smaller-only, de-duplication, spread to four, nearest width and the 10 % refusal.
- `BigTextMemory`: per room and per display keys, unique-name fallback, deletion on unpair, iPhone/iPad independence.
- Protocol: `displayScale` validation, stray fields, oversized lists, older-peer gating, older decoders ignoring the new descriptor fields, stale-epoch reply.
- State machine: quiesce before change, own-change recognition (flags, display list, mode match, coalescing, 10 s timeout), foreign change during `changing`, re-enumeration and frame/bounds check, latest-request-wins, every restore trigger in §4.5, restore-pending retry, 20 s disconnect grace, hang-policy threshold while applied.
- Curtain: stays up through own changes, resized in place, new stream starts with exclusions; foreign change still lifts it.
- Window restore against fake Accessibility trees: matching by element/window ID, skip moved windows, skip minimised/full-screen, Stage Manager skip, refusals, no titles read, off-main-thread with timeout.

Physical (Roshan's devices, during a quiet window with no other agents running):
- Built-in display: each step applies within about a second without ending the session; clicks land correctly immediately after each change; End restores mode and windows.
- Drag held across a step change is released safely before the change.
- Curtain up: the physical screen stays covered through step changes.
- `kill -9` of the host mid-session: mode reverts (gate for the §4.6 inference); windows stay shrunken (accepted).
- Full-screen app on the Mac: clear refusal, session continues.
- Change resolution in System Settings mid-session: session stops, the person's choice is kept.
- Readability and stream cost: same text sample at Off, at the middle Big Text step, and zoomed with viewport capture; record encode ms, fps and bitrate. No speed claim unless the numbers show it.
- External monitor if one is available; otherwise record it as unverified.

## 10. Size and order

About 7–10 engineer-days; the host state machine, curtain handling and window restore are most of it. Order: readability/cost comparison against viewport capture (half a day, decides whether to proceed) → step builder, protocol, phone storage and UI behind the capability → host state machine with own-change recognition and explicit re-enumeration → curtain handling → window restore → physical checks. Not a 3 November launch gate unless Roshan decides to ship it in 1.0.

## 11. Review record

Revision 1 was reviewed on 30 September by an independent Claude Opus agent (verdict: revise, then implement). Accepted and verified against source: `loadDisplays()` returns early while a session is active, so revision 1 would have kept stale geometry and input bounds; capture restarts drop curtain exclusions; the hang watchdog has no threshold when recovery is off and the curtain is down; the reconfiguration callback fires before and after each change. Accepted design changes: quiesce before changing, callback-based own-change recognition, explicit re-enumeration, curtain kept up, session-end-point restore with retry, forget-baseline on foreign changes, identity-safe in-memory window restore that skips moved windows, and always-reply protocol. The earlier plan for a GPT 6.1 Sol review could not run because that model is not available on the current Codex login.
