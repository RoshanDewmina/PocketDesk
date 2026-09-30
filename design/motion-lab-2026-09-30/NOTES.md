# Motion lab, 30 September 2026: implementation notes

## Decided and implemented (30 Sep, PRODUCT D38/D39)

- **Phone: A · Reach, restored.** The stage words became dot-matrix glyphs, one per stage (`StageGlyph`: sweeping chevron, ring blooming from the contact dot, opening aperture). The rest lives in `RemotePhone/ConnectMotion.swift`: the iris into the session and the CRT power-down out (`PhoneRemoteView`); Core Haptics beats (`ConnectHaptics`); the arrival route toast; the reconnect veil and "Back" pill; the code-to-mark pairing flight; and the Anywhere unlock art. The pure rules live in `RemoteShared/ConnectMotionModel.swift`, covered by `RemoteTests/ConnectMotionTests.swift`. `ResolutionLockView` now steps only on connected → video track → first frame. Waiting rings start 0.4 s after connecting, so a quick connect shows none.
- **Mac: 1 · Live strip + "—" meters.** `RemoteHost/HostLiveStrip.swift` holds the tap ripples, power-down, meters, sparkline, activity lights, the inline Stop confirmation and the in-popover pairing code. `HostActivity.swift` is the throttled input feed. `HostMenuBarGlyph.swift` adds the arrival wave, breathing halo and tap flash to the existing mark. Decline is the default on "Is this your phone?". The phone's name travels in the sealed `acceptedAck` (`PhoneIdentity`) and is stored on `HostPair.phoneName`. Without Apple's user-assigned-device-name entitlement iOS reports only "iPhone", so the Mac shows "Your iPhone" until that entitlement exists.
- Screenshots: `screens/`.

Open `index.html` in a browser; it is self-contained apart from Google Fonts. Pick a scenario on the left, a direction above the frame, and a case under it. **Manual states** holds every stage until you press **Next state** (key `N`), which shows that nothing advances without a real state. **Reduce Motion** swaps in each reduced variant. The URL hash (`#connect/A`, `#macStop/1`) links straight to a view.

Roshan's request (30 Sep): bring back the connect animation Codex removed, and make connections, other states and the Mac menu bar more dynamic and satisfying. PRODUCT.md constraints still hold: no distance counter and nothing that implies measured distance ("Home connection readout", 29 Sep), Reach brand (D31/D32), ember only for contact, and Mac Settings keeps native accessibility and destructive-action confirmation.

## What was actually removed

`git show 88c9c3d` ("Show connection stage in home artwork") swapped the Doto **`Gap NN cm`** count-down in `ReachArt`'s bottom-right overlay for a small SF Mono stage caption. The gap-closing art itself is still in `HomeView.gapArt` (`gapTarget` 34 → 18 → 8 → 2 by `MacStatus.progress`, ember contact ripple and `.impact(weight: .medium)` when `inContact`). So the part Roshan misses is mainly the big dot-matrix readout ticking down. The Home view also never had a connected moment: it is replaced by `NativeSessionView` and `ResolutionLockView` without a transition. Direction A restores the readout as stage words (not distance) and adds that missing moment.

## Real states the lab uses

Phone (`RemoteShared/RemoteCoordinator.swift`, `RemotePhone/HomeView.swift` `MacStatus`, `RemotePhone/RemotePhoneApp.swift`):

| Lab key | Real source | Derived |
|---|---|---|
| `tap` | `HomeView.connect()` → (`AnywhereAccess.prepareForConnection()`) → `connection.start()` | press feedback only, never progress |
| `p1` | `status = "Connecting securely…"` | `MacStatus.progress == 1`, `tone .busy` |
| `p2` | `status = "Authenticating your Mac…"` | `progress 2`, `inContact` |
| `ap` | `status = "Approve this phone on your Mac"`, `awaitingApproval` | `needsApproval` |
| `p3` | `status = "Connecting live desktop…"`, then RTC `"checking"`/`"connected"` | `progress 3` |
| `live` | `connection.connected == true` | `PhoneRemoteView.showsSession` |
| `track` | `connection.remoteVideo != nil` | video track attached |
| `frame` | `PhoneRemoteModel.fresh == true` | `ResolutionLockView(pictureReady:)` |
| `drop` | `status = "Connection interrupted · retrying…"` | `MacStatus` "Reconnecting", `sessionHeld` |
| `gaveup` | retries exhausted (`sessionLossRetryLimit: 24`) | `FriendlyError.Kind.connectionLost`, `ResumeState` |
| `end` | `model.disconnect()`; `FarsideSessionAttributes.EndReason.user` / `.macStopped` | `model.macNotice` |
| `fail` | `HostPresence.sleeping` → `FriendlyError.napping`; `"Connection timed out"` → `.unreachable` | `HomeView.statusChanged` → `friendlyError` |
| pairing | scanner detection; `PairingSheet` `pairedInSheet` / `PairingBurstView`; `"invalid or expired"` → `.codeRejected` | |
| Anywhere | `AnywhereStore.PurchaseState` `.purchasing/.purchased/.pending`; `AnywhereEntitlement.Phase` `.trial/.active`, `hasAccess` | |

Mac (`RemoteHost/HostReadiness.swift`, `HostPresentation.swift`, `HostModel.swift`): `HostStatus` (`.ready`, `.controlling`/`.viewing`, `.paused`, `.unavailable` with `HostAvailabilityNote`, `.pairing`, `.approvalRequested`), `HostMarkState` (`.idle/.live/.paused/.attention`), `HostPopoverPresentation.Mood`, `HostPairingState` (`.showingCode(code, expires:)`, `.awaitingApproval`, `.expired`), `HostSessionReadout` (route, `roundTripMs`, `framesPerSecond`), and `HostModel.sessionStartedAt` (private today) for elapsed time.

**Honesty fix that applies to every direction.** `ResolutionLockView.run()` steps from noise to coarse to fine on fixed 300 ms sleeps, so those two steps are cosmetic. Tie them to events instead: coarse on `connected`, fine on `remoteVideo != nil`, crisp on `fresh` (the lab does this). Waiting loops (A's bone search rings, B's shimmer, C's glint) repeat without advancing and stop the moment a state arrives.

**Frame rate.** `CADisableMinimumFrameDurationOnPhone` is already on. Keep 120 Hz motion to transforms and opacity (`scaleEffect`, `offset`, `opacity`, scaled `Circle` masks), which Core Animation renders. The halftone `Canvas` stays capped at 30 fps (`TimelineView(.animation(minimumInterval: 1/30))`). During iris or zoom transitions, stop re-rasterising the art: snapshot it once and scale that layer.

**Haptics engine.** One `CHHapticEngine` owned by the connect flow, created on tap, `playsHapticsOnly = true`, stopped after `.success`. If the engine fails, fall back to the existing `.sensoryFeedback`. Keep `.success`/`.warning` as `UINotificationFeedbackGenerator` via `.sensoryFeedback`. Under Reduce Motion, drop only the decorative ticks. `ResolutionLockView` already does this.

## Connect directions

### A · Reach, restored (recommended)

- **Look:** gap closes per stage; a Doto readout names the stage (`reaching`, `found`, `allow`, `opening`) with three pips (bone, then ember at contact). Bone search rings leave the fingertip every 1.6 s while waiting. On `connected` the fingertip touches, the meeting dot flashes, and the session opens as a 440 ms iris out of that dot, with the lock inside.
- **SwiftUI:** restore `ReachArt`'s overlay as `Text(stageWord).font(Farside.Typeface.display(30))` with `.contentTransition(.numericText())`, or a 240 ms scramble in a `TimelineView` (Doto has no punctuation issues with these words). Add a `searchRings` ripple source to `FarsideHalftone` (bone-only `HalftoneRipple` with no ember term). For the iris, give `PhoneRemoteView` an `.transition(.modifier(active: IrisMask(scale: 0.01, anchor: meetingPoint), identity: IrisMask(scale: 1, ...)))` where `IrisMask` masks with `Circle().scaleEffect(scale, anchor:)`. The anchor comes from `ReachArt.meetingPoint(in:)` converted to global space with `onGeometryChange`.
- **Haptics (`CHHapticPattern` sketch):**
  ```swift
  // p2 · contact
  CHHapticEvent(eventType: .hapticTransient, parameters: [.init(parameterID: .hapticIntensity, value: 0.7), .init(parameterID: .hapticSharpness, value: 0.35)], relativeTime: 0)
  CHHapticEvent(eventType: .hapticContinuous, parameters: [.init(parameterID: .hapticIntensity, value: 0.3), .init(parameterID: .hapticSharpness, value: 0.1)], relativeTime: 0, duration: 0.18)
  // + CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [.init(relativeTime: 0, value: 1), .init(relativeTime: 0.18, value: 0)], relativeTime: 0)
  // p3 · click (decorative): transient I 0.4 S 0.8
  // live · meet: transient I 1.0 S 0.55 + continuous 0.24 s, intensity curve 0.6 → 0
  // tap: transient I 0.5 S 0.7 · frame: .sensoryFeedback(.success)
  ```
- **Reduce Motion:** still art, readout cross-fades, no rings, 250 ms cross-fade into the session.
- **Effort:** about 2.5 days, including device haptic tuning.

### B · The window opens

- **Look:** the Mac card lifts; its halftone thumbnail is noisy with a shimmer on `p1`, then snaps finer with a rigid tick on `p2` and `p3`. On `connected` the thumbnail zooms to full screen, its dots growing as if magnified, and hands over to the lock.
- **SwiftUI:** `FarsideHalftone(style: HalftoneStyle(cell: cell(for: status.progress)))` in `MacCard`. For the zoom, use iOS 18 `.matchedTransitionSource(id: "mac", in: ns)` + `.navigationTransition(.zoom(sourceID:in:))`. That needs the session presented via `fullScreenCover` or `NavigationStack` rather than the current `Group` swap in `PhoneRemoteView`, which is the main risk. Alternatively, use a manual `matchedGeometryEffect` across the swap. The lab blends the thumbnail's landscape layout into the portrait crop during the zoom so it never snaps.
- **Haptics:** rigid transient ticks I 0.45/0.6/0.75 S 0.9 (the same language as the existing lock ticks), lift I 0.5 S 0.2 on `connected`, `.success` on `fresh`.
- **Reduce Motion:** thumbnail cross-fades per step without shimmer; zoom becomes a cross-fade.
- **Effort:** about 3 days (presentation refactor).

### C · Button portal

- **Look:** the Connect pill folds into a bone ring on tap. This is press feedback, not progress. 18 dots around it light in thirds on `p1`, `p2` and `p3` (ember from `p2`). The arrow becomes the ember dot at `p3`, and on `connected` the ring opens into a full-screen portal. Cancel sits under the ring.
- **SwiftUI:** a `matchedGeometryEffect` between the pill background and a `Circle`, or a width animation on a `Capsule` while the label fades. The ring is a `ZStack` of 18 `Circle`s with the lit count bound to `MacStatus.progress`; each dot pops with `.phaseAnimator`. The portal is the same circular-mask transition as A, anchored at the button.
- **Haptics:** press I 0.6 S 0.9; segments I 0.35 S 0.6 (decorative); contact I 0.55 S 0.45; `connected` continuous 0.3 s rising 0.5 → 0.8, S 0.3, then transient I 1.0 at +300 ms; `.success`.
- **Reduce Motion:** instant swap to the ring, no pop or glint, cross-fade portal.
- **Effort:** about 2 days.

## Shared phone states (Reach vocabulary, fit any direction)

| Scenario | Approach | Driving states | Haptics | Effort |
|---|---|---|---|---|
| Arrival | Pointer lands with an ember pulse and a 16-dot settle halo (`KeyframeAnimator`). The route toast shows "Measuring…" until stats exist, then route · ms, and folds after 2 s. The dock handle rises. | `fresh`, `pointerLocator.followUpdates`, `connection.diagnostics`/stream stats | none (success already fired) | 1 d |
| Reconnecting | Freeze plus a `FarsideDotScreen` wipe (mask `scaleEffect(y:)`). The tip goes hollow and breathes; `ReconnectPill` keeps End. On return, an inverted circle mask opens from the pointer and the pill shows "Back · Direct · 16 ms". | `"Connection interrupted · retrying…"`, `connected`, `fresh`, retry limit | slack I .35 S .15 · back I .55 S .5 · `.warning` on give-up | 1 d |
| Ended | Custom `Transition`: `scaleEffect(y: .006)` then `scaleEffect(x: .012)` (CRT), then a dot `matchedGeometryEffect` into the MacCard `LiveDot`; Home fades in and the gap widens. | `disconnect()`, `EndReason`, `macNotice` | soft I .5 S .3 (you) · `.warning` (Mac stopped) | 1.5 d |
| Pairing | Corners snap on detection. The code's modules fly into the mark via one `Canvas` + a precomputed module→dot map (upgrades `PairingBurstView`). A Mac menu-bar sliver pulses the attention ring until Allow; an expired code shakes once. | scanner detection, `pairedInSheet`, `awaitingApproval`, Allow, `.codeRejected` | lock I .6 S .9 · `.success` · allowed I .7 S .5 · `.warning` | 1.5 d |
| Failure | Search rings with no echo. Asleep: the pointer sinks and tilts, Doto z's rise, the hand retreats. Unreachable: the pointer dissolves. Then the existing `FriendlyErrorView` cover. Adds `ptrDy/ptrRot/ptrLum` to `FarsideArt.reach`. | `HostPresence.sleeping` → `.napping`; timeout → `.unreachable` | `.warning` only when the reason is known | 1 d |
| Anywhere | Dotted home-Wi‑Fi edge scatters, the hand stretches to the far pointer, and "anywhere" resolves in Doto dots. No celebration for Ask to Buy. | `PurchaseState`, `AnywhereEntitlement.hasAccess` | `.success` once, on real access | 1 d |

## Mac directions

The same rules apply to all three. Toggles stay real `Toggle`s (switch role, keyboard, VoiceOver). Sections use `HostSettingsSection`/`HostHairlineList`, **never `GroupBox`** (AGENTS.md CUA note). Motion layers are `accessibilityHidden`. Each state change posts one `AccessibilityNotification.Announcement`. **New:** Stop Sharing while `HostStatus.isSessionLive` asks first. Keep Sharing is the default and cancel action, and Stop Sharing is `role: .destructive`. Today it stops immediately. Pause 10 min stays one click because it undoes itself.

**Status item constraint.** A `MenuBarExtra` label is rendered as a static image, so SwiftUI effects don't run there. The status item can animate in two ways. The first is swapping pre-rendered `NSImage` frames on a timer, only while there is something to show (12 fps, stopped when not live, and not while the display sleeps). The second is moving to an `NSStatusItem` with a layer-backed button and `CABasicAnimation`s, which run off the main thread. The second is cheaper for continuous effects. Keep the template image for idle, paused and attention so macOS still tints it.

### 1 · Live strip (recommended)

- **Look:** today's layout. The halftone strip becomes the session: the hand closes on the pointer when a phone connects, and each click the phone sends makes a small ember ripple. The who-row gets an elapsed timer and a dot sparkline of measured RTT. Stop gets an inline confirmation, then the strip powers down (CRT) and the ember tip fades. Pairing shows the QR in the popover: it dithers in, 12 dots drain over the 2-minute code life, and a scan collapses it into the ember dot before "Is this your phone?".
- **Status item:** ember halo breathes (2.8 s) while live; a one-shot brightness wave runs tip to tail on connect.
- **SwiftUI:** `HostArt(.popoverStrip)` Canvas using `FarsideArt.reach(gap:contact:)`. Ripples need a new throttled input-event publisher from `RemoteInputDriver` (clicks only, at most 4/s). The sparkline is a `Canvas` over a 40-sample ring buffer of `HostSessionReadout.roundTripMs`. `sessionStartedAt` must be exposed on `HostViewState`. The QR moves from the setup window into the popover for `.pairing`; keep "Show Code…" as a fallback.
- **Effort:** about 3.5 days.

### 2 · Control room

- **Look:** header chip "Live · 12:04". A session card with Doto meters (route, latency, frames) that read "—" until measured. Activity pips (pointer, click, keys, scroll) light ember on phone input, which doubles as a security cue. Toggle tiles. An ember line sweeps the card on connect. The status item flashes a ring per input event (at most 4/s).
- **SwiftUI:** `.contentTransition(.numericText())` + `.monospacedDigit()` meters; pips from the same input-event publisher (≤10 Hz, typed); tiles as `Toggle` with a custom `ToggleStyle`; `NSStatusItem` + CALayer ring.
- **Effort:** about 4.5 days (layout rework plus the event publisher).

### 3 · Quiet native

- **Look:** a well-made macOS popover. The SF Symbol header swaps with a bounce (`iphone` → `cursorarrow.rays`), captions use numeric transitions, and Stop Sharing uses a system `.confirmationDialog`. The status item bounces once on connect and then stays still.
- **SwiftUI:** `.contentTransition(.symbolEffect(.replace))`, `.confirmationDialog` with `Button(role: .destructive)` and `.keyboardShortcut(.cancelAction)` on Keep Sharing, and 5 pre-rendered bounce frames.
- **Effort:** about 1.5 days.

## Recommendation

Phone: **A** for connect. It is the thing Roshan misses, it is the most on-brand, and the iris adds the missing "we're in" beat without adding wait time. Take the shared states as a set. If only two ship first, do Reconnecting and Ended. Mac: **1 · Live strip**, plus two things from 2: meters read "—" until measured, and optionally the per-event status-item ring as a privacy cue (a setting, off by default).

## Open questions for Roshan

1. The readout words in A: `reaching / found / opening`, or plainer (`connecting / verifying / opening`)? Or the pips with no word at all?
2. Should the Mac show the phone's name ("Roshan's iPhone")? The host only knows "Your iPhone" today. That needs the device name stored at pairing (it's personal data, so opt-in).
3. On the Mac, should phone input be visible as activity (direction 2 pips, or the status-item ring)? It is useful for safety but may feel busy.
4. Move the pairing QR from the setup window into the popover?
5. Stop Sharing confirmation: inline (1, 2) or the system alert (3)? And should Allow remain the default button on "Is this your phone?", or should Decline be the safe default?
6. Is 1.6 s the right cadence for the search rings, and should they appear at all on a fast LAN connect (under about 400 ms)?
