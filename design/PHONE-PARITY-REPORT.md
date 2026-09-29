# Farside phone and iPad parity with Workbench — report

29 Sep 2026. Input and viewing features that match or beat Astropad Workbench on iPhone and iPad (see `Docs/BENCHMARK-WORKBENCH-2026-09-28.md`, `Docs/research/2026-09-28-round2/PHONE-AND-AGENT-GAPS.md` §2). Branch `worktree-agent-a9c91c9bb117300d3`, rebased onto `pocketdesk-remote-chat`. Evidence levels: unit tests (macOS and iOS), simulator UI tests driven through an offline input probe, simulator screenshots. **Nothing here is a physical-device result**; see "Needs real hardware".

## What shipped

### 1. Direct touch (Controls → Touch: Trackpad / Direct)

Trackpad stays the default. In **Direct** the finger is the pointer:

| Touch | Mac |
|---|---|
| Touch down | Pointer jumps under the finger (hover effects, the phone-drawn pointer jumps too) |
| Tap | Click exactly there; a second tap within the double-click time and 24 pt lands on the first tap's point and counts 2 |
| Slide (> 10 pt) | Press where the finger landed, drag with the finger, release on lift |
| Touch and hold (0.5 s, still) | Press and hold there (Dock and toolbar press-and-hold menus), release on lift |
| Double-tap then slide | Drag with click count 2 (word selection) |
| Two fingers | Scroll what is under them (pointer moves to their midpoint once, then stays), pinch zooms the view locally, two-finger tap right-clicks at the midpoint |
| Three fingers | Swipes as before (Spaces, Mission Control, App Exposé); **tap = middle click** at their centroid |

Canvas points go through the live viewport (`DirectTouchMapping` → `ViewportTransform.sourcePoint`), so Fit/Fill, zoom, pan, rotation and safe areas are all accounted for; letterbox bands have no target and never click. Positions travel in 1/64 pt steps. Direct needs the updated Mac companion (`pointer.absolute.1`); with an older Mac, touches stay a trackpad and Controls says why.

### 2. Middle click

Three-finger tap in both touch modes (unused before: the engine only knew three-finger swipes; iOS reserves three-finger taps for text editing only when a text field is focused) and the mouse's middle button on iPad (GameController `GCMouse` — UIKit reports only primary and secondary). The Mac gets a centre-button click (`middle`, `pointer.middle.1`). VoiceOver has a "Middle-click" action. Ripple: one tight ember ring; haptic: one rigid tap.

### 3. Hardware keyboard (iPhone and iPad)

- Physical keys go to the Mac **by position** (USB HID usage → Mac virtual key code) with ⌘⌥⌃⇧ as flags, so the Mac's own layout, dead keys and input methods apply exactly as on a Mac keyboard. Letters, digits, punctuation, Return/Tab/Space/Delete/Forward Delete/Escape, arrows, Home/End/Page Up/Page Down/Help, F1–F20, keypad and JIS keys. The Mac adds the Fn or numeric-pad flag a Mac keyboard sets. Caps Lock capitalises letters (not with ⌘/⌃/⌥).
- No on-screen keyboard: the canvas holds first responder without being a text input. When the keyboard bar's text field is focused, typing goes into the local draft instead — never both (UI-tested).
- **Escape always reaches the Mac** and never ends the session (a Workbench complaint): iOS gives Esc to its focus/dismiss systems first, so the canvas registers priority key commands for Esc with every modifier combination.
- **⌘W, ⌘M, ⌘Q, ⌘N and ⌘, go to the Mac, not to Farside's window.** iPadOS 26 gives Farside a menu bar whose Close Window, Minimize, Quit, New Window and Settings shortcuts are resolved before any key command: on the iPad simulator ⌘W/⌘M closed or minimized Farside (the session went behind the privacy cover) even with priority key commands. While a session canvas sends keys to the Mac, Farside rebuilds its main menu (`UIMainMenuSystem` build handler, installed on first use, SwiftUI's own menu contributions kept) with those items still in the menu bar but without their shortcuts, so the keys reach the canvas and the Mac. The shortcuts come back when the session ends or Controls, voice or the keyboard bar take over. iPad only; the iPhone never lost them.
- **Shortcuts the system keeps** (⌘Tab, ⌘Space, ⌘H, screenshots never reach an app): press **⌃⌥ instead of ⌘** — ⌃⌥Tab → ⌘Tab (⌃⌥⇧Tab backwards), ⌃⌥Space → ⌘Space, ⌃⌥H → ⌘H, ⌃⌥Q → ⌘Q, ⌃⌥W → ⌘W, ⌃⌥M → ⌘M, ⌃⌥, → ⌘,, ⌃⌥D → ⌥⌘D, ⌃⌥3/4/5 → ⇧⌘3/4/5. On by default, switchable in Controls → Keyboard and pointer, with the list. Unlike Workbench's remap, other chords pass through untouched.
- Held keys repeat on the phone (0.5 s, then every 70 ms, latest key only, never Escape or function keys) so a lost connection can never leave a key down on the Mac. Modifiers held on the keyboard also apply to taps, clicks and drags (⌘-click, ⇧-click, ⌥-drag).
- Keyboard connect/disconnect via `GCKeyboard` notifications: a notice "Keyboard connected · keys go to your Mac"; disconnect, background, focus loss and sheets release repeats and modifiers.
- Older Mac companion: only the original key set is sent; others show one notice.

### 4. Mouse and trackpad on iPad ("Follow")

- The Mac pointer goes exactly where the iPad pointer is over the picture (`UIHoverGestureRecognizer` → `moveTo`); the iPad pointer is hidden there with `UIPointerStyle.hidden()` while controlling, so only the Mac pointer shows. Apple Pencil hover (height > 0) is ignored.
- Primary click with UIKit's click count (double and **triple** click), press-and-move drags, press-and-hold (0.35 s) holds, secondary button right-clicks, the middle button middle-clicks.
- Scroll wheel and two-finger trackpad scroll pass through with began/changed/ended phases (`UIPanGestureRecognizer.allowedScrollTypesMask = .all`, no touches); a trackpad pinch zooms the view locally.
- Needs `pointer.absolute.1`; on an older Mac a mouse does what it did before (nothing).
- **Not done: pointer lock** (`prefersPointerLocked`) and relative `GCMouse` deltas. The app uses the SwiftUI `App` lifecycle, whose root `UIHostingController` cannot override `prefersPointerLocked`, and SwiftUI has no pointer-lock modifier on iPadOS (checked: `pointerVisibility`/`pointerStyle` are macOS/visionOS only). A captured mode needs a UIKit-owned full-screen presentation whose controller prefers the lock, then `GCMouse` deltas → relative `move`; that must be tried on a real iPad because the simulator cannot show whether the lock engages. Follow mode covers desktop work; captured mode matters for 3D/CAD/games.

### 5. Mini map

A small overview of the whole Mac display with the visible area outlined in bone, the rest under a void veil, and the Mac pointer as a small dot. It appears bottom-right when the view moves while part of the display is off screen (zoom, pan, pointer follow, rotation, closing the dock or Controls), stays while touched, and fades 3 s after the view stops. Drag the outline to pan; tap anywhere to jump (the tapped point is centred, within pan limits). Hidden while the dock, keyboard, Controls, voice, privacy shield or the resolution lock is showing. **On by default on iPad; "Mini map in landscape" option on iPhone (off by default).** The thumbnail is a second `RTCMTLVideoView` on the same track, fed through `RestampingRenderer` like the main picture (a view added straight to a tuned track stays black) and created only while the map is visible. VoiceOver: "Mini map" with "Visible area" (how much and where, e.g. "49 percent of the screen, centred 41 percent across and 60 percent down") and actions to move the view and show the whole screen; the "Visible area" element sits exactly on the drawn outline (placed by alignment guides — with `.position` VoiceOver framed the whole map, with `.offset` the unmoved spot). Reduce Motion: fades only; tap-to-jump does not animate.

### 6. Display picker

When the Mac has more than one display, Controls → Display lists them (name, points and pixels, main display first) with the streamed one ticked. Choosing one switches the stream **within the session**: the Mac releases held input, starts a new epoch, resends geometry and restarts capture on that display, so nothing meant for the old display can land on the new one. The choice is remembered per Mac (keyed by a hash of the pairing room) and re-applied on the next connection, matching by display id or, for a monitor that came back with a new id, by a unique name. Choosing what the Mac shares needs the same authority as controlling it: a view-only phone keeps the display the Mac chose. The host already had the selected-display plumbing (`RemoteHostModel.selected`, `displays`, `beginCapture`); `switchSessionDisplay` reuses it.

### 7. Look, haptics, motion, accessibility

Reach tokens only (void/panel plates, bone text, ember only for contact). Haptics: selection tick on touch style, mini map touch and display switch; middle-click rigid tap. Reduce Motion alternatives on the mini map. VoiceOver labels and hints for the canvas in each touch style, the mini map, display rows and settings.

## Protocol (capability-gated, backward compatible)

Details in `Docs/REMOTE-PROTOCOL.md` ("Phone parity capabilities"). Four new features on `capture.features`: `pointer.absolute.1` (`moveTo`, triple click, modifier flags on pointer actions), `pointer.middle.1` (`middle`), `keys.extended.1` (key names), `display.select.1` (`displays`, `display`, `capture.display`). A phone sends a new action or name only after seeing its feature; a host sends `displays` only in answer to a phone's request. Older peers therefore never see anything they would reject, and new fields they receive (`capture.display`) are ignored by their decoders. The browser path's own allowlist is unchanged.

## Verification

Results are filled in below from the final runs after the rebase.

VERIFICATION_TABLE

## Screenshots

In `~/Downloads/`: SCREENSHOT_LIST

## Compared with Workbench

| Workbench | Farside now |
|---|---|
| iPhone touch is direct (tap where you want) | ⭐ both: Trackpad (default, precise) and Direct, switchable; Direct adds touch-and-hold press, double-tap-drag and two-finger right-click where the fingers are |
| Two-finger scroll; touch-and-hold drag | ✅ in both styles |
| External mouse/trackpad and hardware keyboard through iPhone/iPad | ✅ keyboard on both (by position, Esc kept for the Mac, remaps); ✅ mouse/trackpad Follow on iPad; 🟡 no pointer lock yet |
| iPad shortcut remapping | ⭐ ⌘W/⌘M/⌘Q/⌘N/⌘, taken back from Farside's own menu bar for the Mac; ⌃⌥ stand-ins for the shortcuts the system keeps, on by default, others untouched |
| Middle mouse (3D/CAD) | ✅ click (three-finger tap, middle button); 🟡 no middle-drag |
| Mini map with zoom slider (iPad only) | ✅ iPad, ⭐ also iPhone landscape, pointer dot, auto-hide; zoom stays in pinch/slider |
| Unified Display / multiple displays | 🟡 one display at a time, switchable in session and remembered per Mac (no combined view) |

## Needs real hardware

- iPad with a Magic Keyboard / Bluetooth keyboard: Escape and Forward Delete (the simulator never delivers XCTest's synthesized ones), which ⌘ shortcuts iPadOS 26/27 keeps in a full-screen and a Stage Manager window and on an external display, that the menu-bar shortcut release keeps ⌘W/⌘M/⌘Q/⌘N/⌘, for the Mac there too, Esc on keyboards without an Esc key (⌘.), key repeat feel, Caps Lock, non-US layouts on phone and Mac, the Globe key.
- iPad with a mouse and with the Magic Keyboard trackpad: Follow feel and latency, click counts, press-and-hold timing, scroll direction and speed (natural scrolling on both devices), momentum (not forwarded), trackpad pinch, middle button through `GCMouse`, the hidden system pointer in Stage Manager and on an external display.
- Pointer lock / captured mode (not implemented; see §4).
- Direct touch feel on iPhone and iPad: 10 pt slop, 0.5 s hold, accuracy on small targets at Fit on iPhone.
- Mini map legibility and the second video renderer's cost on a real iPad; display switching with a real second monitor (and a monitor that is unplugged while streaming).

## Not done / follow-ups

Pointer lock and relative mouse deltas; middle-button drag (needs a button-aware hold on the host); modifier flags on scroll events; a remap editor; momentum scrolling from hardware; iPhone Duo-specific layout.
