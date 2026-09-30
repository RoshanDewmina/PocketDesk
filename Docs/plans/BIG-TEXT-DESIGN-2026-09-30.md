# Big Text — design spec

30 September 2026. Status: **design, awaiting Roshan's review. Nothing is implemented.** PRODUCT.md D38 records the decision; this file holds the engineering design. Physical behaviour below is a requirement to verify, not an observed result.

## 1. What Roshan asked for

- While a phone is connected, the Mac switches to a larger text size ("looks like" scaled mode); when the session ends it goes back.
- The person picks the size. It is remembered **per phone and Mac pair**: this iPhone remembers its own level for this Mac, and an iPad paired with the same Mac can keep a different one.
- It applies **automatically on connect** once a level is saved. A quick toggle turns it off for the current session only, without forgetting the saved level. Default is Off.
- Approach A (chosen 30 Sep): switch the Mac's real display scaling. Rejected: a phone-shaped virtual display (separate, heavier project) and macOS Zoom (blurry pixel magnification, not safely controllable).

Why it matters: the launch promise is readable small text without lag. A larger "looks like" mode renders natively sharp at the new size and also has fewer pixels to capture and encode, which should help the softness and encoder pressure recorded on 28 September. That performance effect must be measured, not claimed.

## 2. User experience

**Choosing a level (phone).** Controls → Settings → Picture gains a **Big Text** row. It lists the steps this Mac's current display offers, largest text last, the way System Settings → Displays does: `Off` (the Mac's own setting) and up to four larger steps, each with a small caption such as "looks like 1280 × 832". Changing the step applies live after a 0.6 s pause (debounced, because every change costs a brief freeze) and saves immediately. While the display re-sizes, the phone shows a "Making text bigger…" pill over the last frame; input is blocked until the new picture arrives (new epoch, see §4).

**Every later connection.** If this phone saved a level for this Mac and display, the phone asks for it as soon as the host advertises support. The session starts at the Mac's normal size and switches within about a second; the pill covers the change.

**Session-only off.** The fixed Controls panel (D36) gains a **Big Text** toggle beside Display. Off restores the Mac's size for this session only; the next connection applies the saved level again. With no saved level, tapping it opens the Picture page.

**On the Mac.** The physical screen shows the larger size too while a phone is connected (the privacy curtain can still hide it). The menu-bar popover shows "Big Text on · looks like 1280 × 832". Mac Settings has no separate control in 1.0; the level belongs to the phone–Mac pair.

**When it cannot apply.** Messages are short and specific; the session continues at normal size:
- "Can't change text size while an app is full screen on your Mac."
- "Big Text needs Accessibility permission on your Mac" (see §5, window restore).
- "This display doesn't offer larger sizes."

## 3. Which steps are offered

The host builds the list from `CGDisplayCopyAllDisplayModes` for the streamed display, with duplicate low-resolution modes included, and keeps a mode only if it:
1. is HiDPI (`pixelWidth == 2 × width`),
2. has the same aspect ratio as the baseline mode (±0.5 %),
3. has the same refresh rate as the baseline mode,
4. is **smaller** in points than the baseline (bigger text). "More Space" modes are out of scope.

Keep at most four, evenly spread from the list sorted by width descending (closest to the baseline first). The **baseline** is the mode that was current when the first Big Text change of this session happened; it is also what `Off` means.

The phone stores the chosen step as its point width (`looksLikeWidth`), not an index, because the list can differ between displays and macOS versions. On apply, the host picks the offered step with the nearest width; if none is within 10 % the host refuses with "This display doesn't offer larger sizes" and the phone keeps the saved value untouched.

## 4. Host behaviour

**Applying a step.** On a valid request for the streamed display:
1. Snapshot window frames (§5) if no snapshot exists for this session.
2. Record the baseline mode if not yet recorded.
3. Arm a self-reconfiguration marker (`expectingOwnReconfiguration` with a 3 s deadline).
4. `CGBeginDisplayConfiguration` → `CGConfigureDisplayWithDisplayMode` → `CGCompleteDisplayConfiguration(config, .forAppOnly)`. `.forAppOnly` means macOS reverts to the login-session configuration when the host process exits, including a crash or a watchdog kill.
5. On failure, cancel the configuration, disarm the marker and report the reason to the phone.

**Screen-parameter notifications.** Today every `didChangeScreenParametersNotification` stops sharing (`HostModel.swift` ~line 352). New rule: while the marker is armed and the streamed display still exists, treat the change as our own: do **not** `stop()`; reload displays, then follow the existing `switchSessionDisplay` path (lift curtain, `beginCapture()` with a new input epoch and geometry, send the display list). Re-raise the curtain afterwards if it was up, sized to the new frame. Any other change, or one after the deadline, keeps today's stop behaviour. The privacy curtain's own observer must also ignore our change and re-cover rather than stay lifted.

**Restoring.** Put the baseline mode back (same `.forAppOnly` call and marker), then restore windows, whenever the session is released: phone End, Stop Sharing, Pause, revocation, the phone's background grace expiring, Mac lock/sleep/user switch, or the host quitting normally. A background pause that is still inside its grace period keeps Big Text. Session-only Off restores the baseline but keeps the window snapshot until the session ends.

**Crash path.** macOS reverts the mode by itself. The window snapshot is persisted (§5), so the relaunched host restores windows on start and deletes the snapshot.

**Capture and stream.** No special casing: `beginCapture()` reads the new `SCDisplay` frame, and the existing Sharper/Responsive caps apply to the new pixel size. Stats keep recording, so the before/after encode cost can be compared.

## 5. Window restore

Shrinking the usable area makes macOS shrink windows that no longer fit, and it does not grow them back. Before the first change the host records, through Accessibility, every standard window on the streamed display: owning app bundle ID, the window's index within that app, position and size. Window titles and contents are **never** recorded. Minimised and full-screen windows are skipped.

Restoring re-applies position and size to the windows that still match (bundle ID + index + unchanged count for that app), largest first, and ignores refusals. It is best-effort: apps that reject moves, windows on other Spaces that Accessibility does not report, and windows opened or closed during the session are left alone.

The snapshot is written to `~/Library/Application Support/Farside/big-text-windows.json` (0600, host-only) before the mode changes, and deleted after a successful restore.

Big Text is offered only when the host has Accessibility permission, because without it windows cannot be restored. View-only sessions whose Mac has Accessibility granted can still use it.

## 6. Protocol

- New capability `SessionFeature.displayScale = "display.scale.1"`, added to `SessionFeature.host`. The phone sends scale actions only to a host that advertises it; a host sends scale fields only to a phone that asked for the display list. Older peers never see them.
- `displays` list entries (`DisplayDescriptor`) gain optional `scaleSteps: [ScaleStep]`, `scaleBaselineWidth` and `scaleCurrentWidth`. `ScaleStep` is `{ width, height }` in points, validated like the descriptor (finite, 1…20 000, at most 4 entries, all smaller than the baseline).
- New phone → host action `displayScale` with `display` (id) and `looksLikeWidth` (points; `0` = Off). Validated in the same style as `validateDisplaySelection`: no unrelated fields, current epoch, not paused, known streamed display.
- Host → phone result on `displays` (the refreshed list with `scaleCurrentWidth`) plus an optional short `scaleError` code: `fullScreen`, `noAccessibility`, `unsupported`, `failed`.

## 7. Phone storage

Follow `DisplayMemory` (`RemoteShared/DisplaySelection.swift`): a `BigTextMemory` in `UserDefaults`, keyed by a hash of the pairing room (`"farside-bigtext|" + room`) and then by display (id + name, as `DisplayMemory.Choice` does). The value is `looksLikeWidth`. It never leaves the phone, and removing the pairing deletes its entries. An iPad paired with the same Mac has its own storage, which gives the per-pair behaviour for free.

## 8. Edge cases

| Case | Behaviour |
|---|---|
| Phone switches display mid-session | Restore the old display's baseline, then apply the saved level for the new display, if any |
| Streamed display unplugged | Existing stop behaviour; there is no mode left to restore on that display; windows restored where possible |
| Person changes resolution in System Settings during a session | Not our change → today's stop behaviour; the next session records a new baseline |
| Two quick step changes | Debounce on the phone; the host serialises and ignores requests while a change is in flight |
| Host watchdog kills a hung host | macOS reverts the mode; windows restored on relaunch from the snapshot |
| Mac was already at the largest step | Only `Off` is offered; the row explains "Already at the largest size" |
| Older host | Row hidden; no toggle |

## 9. Testing

Automated (core and phone suites, no real display changes):
- Step builder: HiDPI filter, aspect/refresh match, smaller-only, spread to four, nearest-width choice and the 10 % refusal, over captured real mode lists from the M4 Air's built-in display and at least one external-monitor list.
- `BigTextMemory`: per room and per display keys, deletion on unpair, iPad/iPhone independence (separate stores).
- Protocol validation for `displayScale` and the new descriptor fields, including rejection of stray fields and oversized lists, and older-peer gating.
- Host state machine with an injected display-configuration API: marker arming/expiry, "own change keeps the session / foreign change stops it", restore on every release trigger, serialised requests, curtain re-cover.
- Window-restore planner against fake Accessibility trees: matching, skipped windows, refusals, no titles recorded, snapshot file permissions and deletion.

Physical (Roshan's devices, during a quiet window, no other agents running):
- Built-in display: each step applies within about a second without ending the session; End restores mode and windows.
- Force-quit the host mid-session: the mode reverts, windows restored after the watchdog relaunch.
- Full-screen app on the Mac: clear refusal, session continues.
- Curtain up during a change: stays covering at the new size.
- Readability and stream cost: same text sample at Off and at the middle step, recording encode ms, fps and bitrate from stream statistics. No speed claim unless the numbers show it.
- External monitor, if one is available; otherwise record it as unverified.

## 10. Rough size and order

Medium: about 5–8 engineer-days, window restore and the host state machine being most of it. Suggested order: step builder + protocol + phone storage/UI (behind the capability), host apply/restore with the self-change rule, window restore, then physical checks. It does not block the 3 November submission and should not be merged ahead of the current launch gates unless Roshan decides to ship it in 1.0.
