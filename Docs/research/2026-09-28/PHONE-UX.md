# Phone UX research and staged experiments

Checked 28 September 2026. Recommendations for later implementation unless listed in the current build receipt. PRODUCT.md owns scope.

## What to improve first

Whole-desktop relative trackpad remains the default: it preserves precise acquisition of small Mac targets. Offer Fit inside the safe area and Fill with every edge reachable. Show the current mode in compact native chrome. Preserve the viewport focal anchor through keyboard and rotation, keep Release visible during a drag, and make ordinary desktop taps stay ordinary clicks. Workbench documents mini-map, voice input, display modes and peripheral support; these are useful reference features, not proof that its interaction model is superior. [Workbench feature help](https://support.astropad.com/en/collections/18729715-workbench-features).

The existing phone redesign uses Apple Home device-card and Apple TV unobstructed-content references inspected by the implementation worker. That is visual inspiration only. Native controls, Dynamic Type, VoiceOver and reduced-transparency states must be tested in the actual app.

## Dynamic zoom without surprise motion

Start with explicit Focus pointer/Reset controls and a zoom indicator, then add optional caret-follow. The host may query the focused accessible element, selected text range and bounds-for-range; capability and timeout failure must leave manual zoom usable. Cross-app Accessibility can return unsupported attributes and does not work uniformly in terminals, canvas editors or protected inputs. Do not infer the caret from arbitrary pixel text or send surrounding text for this feature. [Apple parameterized Accessibility query](https://developer.apple.com/documentation/applicationservices/1461203-axuielementcopyparameterizedattr).

Transmit only bounded rectangle/geometry metadata in an authenticated session. Tag it with source display geometry, generation and freshness. The phone transforms that rectangle into viewport coordinates; manual pan wins, auto-follow pauses while dragging, and hysteresis prevents oscillation near an edge. Avoid animated zoom when Reduce Motion is on. Tap-to-fit a window needs an explicit mode because ordinary taps already mean clicks; never silently repurpose them.

## Next small features

| Feature | Proposed slice | Required proof |
|---|---|---|
| Gesture coach | Short first-session sheet, reopen from controls | Discoverable; no unwanted remote input |
| Zoom indicator / mini-map | Noninteractive indicator first, iPad navigator later | Accurate after rotation, letterboxing and keyboard |
| Dictation | Use system keyboard dictation into the existing local text draft | User can correct before Send; no duplicate IME commit |
| Clipboard | Explicit copy/paste controls with size/type limits | No silent clipboard monitoring or secret retention |
| Direct-touch option | Separate mode with visible mode state | Coordinate accuracy, clipping and cancellation tests |
| Hardware peripherals | iPad keyboard/pointer adapter | Real hardware; modifier release on disconnect |

UIPasteControl provides a user-invoked paste affordance; support through the normal native paste path before inventing continuous sync. [Apple UIPasteControl](https://developer.apple.com/documentation/uikit/uipastecontrol).

## Acceptance experiment

Compare current build and Workbench on the same phone/Mac/network: acquire five small targets, select and edit a disposable sentence, drag with a stationary hold, scroll and reverse, pinch, reveal keyboard, rotate and recover after interruption. Record task success, accidental clicks, corrections and time. Use real finger tests for feel and haptics. A simulator screenshot or app screen recording cannot establish touch-to-photon latency.

Start with three participants beyond the builder after Roshan's own task succeeds; this is a proposed qualitative sample, not population evidence. No new review scraping or representative user-sentiment claim was completed in this continuation. Estimates: coach/indicator 1–3 engineer-days; bounded caret-follow prototype 3–7 days plus compatibility testing; full peripheral/clipboard breadth is larger. These are planning estimates, not commitments.
