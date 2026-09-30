# Couch mode — design spec

30 September 2026, revision 1. Status: **proposed; awaiting Roshan's answers to §9.** Design only: no code, build or physical result exists. Labels: **VERIFIED** = read in source at the cited line in `farside-feature-specs` (HEAD `86d643a`); **INFERRED** = design reasoning to confirm during implementation.

## 1. What Roshan asked for

- When the phone is in the same room as the Mac (Mac on a TV, across the desk), the phone becomes a **trackpad and keyboard only**: no video, no capture, very low latency and battery cost.
- Free-tier daily-use hook: it keeps Farside installed, paired and familiar before someone needs Anywhere (D28).
- Reuse the D20/D22/D26 relative trackpad, click haptics, keyboard/dictation, clipboard and the D36 Mac keys.

The design problem: today input is allowed only with a fresh picture. In Couch mode the person's eyes on the Mac are the picture, so safety must come from an explicit mode, a proven one-hop local link, a Mac-side indicator and short leases.

## 2. User experience

**Entry (Home).** A secondary button under the Connect pill: **Couch mode**, caption "Trackpad and keys. No picture." It is shown for every paired Mac, even off Wi-Fi, because the local proof is the real check. While the proof runs, connecting shows "Checking you're on the same network…".

**The surface (iPhone portrait).** Void background, no picture.
- Top line (SF Mono caption): `Studio Mac · Couch · 4 ms`, with the ember live dot.
- Trackpad: one card (radius 20, `line` border) filling the rest of the screen. At rest it reads "Look at your Mac. This is its trackpad." with the deadpan line "The picture is the one on your wall." The text fades on first touch.
- Clicks give an ember ripple and the existing heavy haptic.
- Key row: **Keys · Mic · Clip · Picture · Controls**. Controls opens the D36 panel without its Display and Hide Mac screen rows. End stays in the dock footer.
- Landscape and iPad: the key row moves to the trailing edge. iPad hardware keyboard and trackpad keep working, relative motion only.

**Gestures.** Control-mode `NativeGestureEngine` behaviour: move, tap, two-finger right-click and scroll, hold-drag, and three-finger Spaces and Mission Control. View pan/pinch, direct touch and `moveTo` are off, since there is nothing to aim at. The gain uses `pointerScale = 1` (today it is divided by the viewport scale, `NativeGestureEngine.swift:419`, VERIFIED), with a 1.4× default speed to tune physically (INFERRED).

**Switching.** **Picture** → "Showing your Mac's screen…", a normal session on the same connection. The dock's **Mode** tile gains **Couch** to go back. Each switch starts a new epoch.

**Refusal and error copy:**
- "Couch mode works on the same Wi-Fi or Ethernet network. Join your Mac's network and try again."
- "Control is off on your Mac. Turn on Allow control in Farside's menu."
- "Update Farside on your Mac to use Couch mode. Showing the picture instead."
- "Your Mac isn't answering. Input paused."

**On the Mac.**
- On connect, a 3 s non-activating HUD: "iPhone is steering this Mac · Couch mode, no picture shared".
- Ember menu-bar tip for the session.
- Popover line "Couch mode · Roshan's iPhone is steering (no picture)", with Stop Sharing.
- The chime preference applies.

## 3. Architecture

**Choosing the mode before media.** The host's offer is built in `prepareMedia` when the phone's `acceptedAck` arrives (`RemoteCoordinator.swift:486-488`, VERIFIED). Capture starts on `onAuthenticated → phoneConnected → beginCapture` (`HostModel.swift:292`, `695`, `1231`, VERIFIED).
- The phone puts `{"mode":"couch"}` in the `acceptedAck` body, inside the pairing cipher.
- An older host ignores that body: its handler checks only state, and the replay guard checks only request, session and sequence (`Pairing.swift:181-184`, VERIFIED). So the request is backward compatible.
- A new host records `sessionMode`, and `phoneConnected` calls `beginCouch()` instead of `beginCapture()`.

**Capability.** `SessionFeature.couch = "couch.1"` (`SessionContinuity.swift:24`), plus a `mode` field on the `capture` status. If the phone asked for Couch but the host's status lacks `couch.1`, the Mac is older: the phone keeps the normal picture session and shows the update notice.

**`beginCouch()`** advances the epoch and sends `geometry` using the online displays' `CGDisplayBounds` (CoreGraphics, no Screen Recording; INFERRED). It configures the driver, starts the 0.25 s lifecycle timer and `HostPointerTelemetry`, applies keep-awake and wake, and shows the HUD.

It **does not** start `SCStream`, the encoder, the load monitor, viewport crop or cursor hiding. It does not raise the privacy curtain (that would cover the screen being watched) or apply Big Text. The host still adds an idle video track (`PeerMedia.swift:274-281`, VERIFIED) and feeds it no frames.

**Driver.** `configure(bounds:)` exists (`RemoteInputDriver.swift:245`, VERIFIED) but clamps to one rectangle. Couch needs `configure(displays: [CGRect])`, which clamps to the nearest display so the pointer can cross an extended TV. Mirrored displays are one rect (INFERRED).

**Switching inside a session.**
- Couch → Picture calls `beginCapture()`, the path `switchSessionDisplay` already uses (`HostModel.swift:1727`, VERIFIED).
- Picture → Couch quiesces like `pauseForPhoneBackground` (`HostModel.swift:1751`, VERIFIED): release input, expire tokens, stop capture, then `beginCouch()`.

**Input safety without a picture.** Today the host enables input only when `userConsent && accessibility && captureHealthy` (`HostPermissionState.swift:92-99`, VERIFIED). Status ticks issue 1 s tokens (`NativeInputFreshness.swift:19`, `HostModel.swift:1648`, VERIFIED). The phone's `canControl` also needs a frame less than 2 s old (`RemotePhoneApp.swift:281-287`, `1266-1273`, VERIFIED). Couch replaces only the picture term:

| Layer | Picture session (today) | Couch session |
|---|---|---|
| Host gate | `captureHealthy` | `couchHealthy` = own proven local link still selected, phone heartbeat < 0.75 s old, unlocked, active user, Allow control on, Accessibility granted |
| Tokens | 1 s, issued each 0.25 s tick | Unchanged; issued only while `couchHealthy` |
| Phone gate | `fresh && captureHealthy` | Host `capture x=1` < 1 s old and `mode == couch`; `fresh` not required |
| Held button | 2 s lease (`RemoteInputDriver.swift:19-23`) | 1 s lease renewed by `holdRenew`; the existing 10 s Hold-click auto-drop stays |
| Delivery health | Frame age | Pointer telemetry `applied` acks: any move not acknowledged within 300 ms blocks new drags and clicks, releases holds and shows "Your Mac isn't answering" |

The phone does not draw the pointer: the person sees the real one. Telemetry is kept only for the acks.

## 4. Tier rules

- Couch mode is **free and only on a proven directly attached link, for everyone**, including Anywhere subscribers. It never uses a relay or internet route.
- A server `route` with `access: local` already makes both peers run the HMAC, TTL-1, one-hop UDP proof and pin ICE to the proven host candidates (`RemoteCoordinator.swift:518`, VERIFIED; `Backend/ENTITLEMENT-CONTRACT.md` §route.1).
- A paid phone would normally get `access: remote` and skip the proof. For a Couch connection the phone therefore sends no entitlement token and does not list `remote.1`. The server then publishes `local` (`Backend/src/room.ts:897-902`, VERIFIED), and no `entitlement_required` error fires (`RemoteCoordinator.swift:214-216`, VERIFIED). No backend change is needed.
- The host independently refuses Couch unless its own `routePolicy.access == .local` and a proven link exists. It answers with `mode: refused` and a reason, so a compromised server cannot route Couch remotely.
- A path change ends the session, as it does today (`RemoteCoordinator.swift:542-545`, VERIFIED).

## 5. Security

- Pairing is unchanged. Only a paired phone (pairing key plus host token) reaches the proof, so someone else's phone cannot enter Couch mode.
- With Allow control off, the host refuses Couch.
- Stop Sharing, Pause, lock, sleep and user switch work through the existing paths.
- Residual risk: same network is not the same room, so the owner could steer blind from another room. The HUD, ember tip and chime tell anyone at the Mac. macOS shows no capture indicator because nothing is captured, which is why the HUD is required.
- Clipboard keeps its current rule, `current && controlEffective`, which never needed a picture (`HostModel.swift:1684`, VERIFIED).

## 6. Edge cases

| Case | Behaviour |
|---|---|
| Older Mac or older phone | Picture session (plus the update notice when the phone asked for Couch) |
| Anywhere phone on cellular | Proof fails → refusal + "Connect with picture" |
| Phone backgrounded | Existing `pause.1`; holds released |
| Mac locked or display asleep | Locked: existing teardown. Asleep: a tap sends `wake` |
| Picture asked for, no Screen Recording | "Your Mac needs Screen Recording to show the picture." Couch continues |
| Display plugged in or removed | Today this stops sharing (`HostModel.swift:353-359`, VERIFIED). Couch rebuilds the display rects and continues (INFERRED) |
| Curtain on, saved Big Text level | Neither applies in Couch |

## 7. Testing

**Automated:**
- The `acceptedAck` mode body is read by a new host and ignored by the current handler.
- Refusal when the route is remote, there is no proven link, or control is off.
- `couchHealthy` over heartbeat age, link loss, lock and consent; no tokens while unhealthy.
- Phone `canControl` in Couch without `fresh`.
- The ack watchdog and the 1 s hold lease.
- Multi-display clamp.
- Picture↔Couch epoch changes drop old-epoch input.
- A capture spy shows `beginCouch` never captures.

E2E keeps the `HostE2E` Test Pad fence. It uses the DEBUG legacy route with an injected proven link, because loopback cannot pass a real proof.

**Physical** (iPhone 17 + M4 Air, quiet Mac), Couch vs Picture:
- Tap-to-click latency, using the 240 fps method in `POINTER-REPORT.md`.
- Battery over 30 min: phone % and host CPU.
- Cellular, VPN and a paid phone off-LAN are refused.
- The HUD shows; Stop Sharing and lock end the session.
- A drag held while Wi-Fi drops is released within 1 s.

## 8. Size and order

About 5–7 engineer-days, in this order: handshake, `couch.1`, `beginCouch`, `couchHealthy` and refusal (2 d) → phone surface, entry, switching and ack watchdog (2 d) → Mac HUD and popover (0.5 d) → multi-display clamp (0.5–1 d) → tests and physical checks (1 d). It is independent of Big Text, and not a 3 November gate unless Roshan wants the free hook in 1.0.

## 9. Open questions for Roshan

1. **Who gets Couch mode, over which routes?**
   - A) Everyone, only on a proven same-network link. Anywhere subscribers too; never internet or relay. *(Recommended: the local proof is the proximity check that replaces the picture.)*
   - B) Free users on the same network; Anywhere subscribers anywhere.
   - C) Anywhere only.
2. **Should Couch mode ever show a picture?**
   - A) No picture; one tap on Picture switches to a normal session. *(Recommended: keeps capture, Screen Recording and the battery cost out of Couch.)*
   - B) An optional 1–2 fps thumbnail inside Couch.
   - C) No picture and no switch.
3. **Mac-side indicator?**
   - A) A 3 s HUD at connect, the ember menu-bar tip and the popover line. *(Recommended.)*
   - B) A small on-screen badge for the whole session.
   - C) Menu bar only.
4. **Screen Recording permission?**
   - A) Keep Mac setup unchanged for 1.0 (both permissions); Couch simply never captures. *(Recommended: today registration requires Screen Recording, `HostModel.swift:701-712` and `1122-1133`, VERIFIED.)*
   - B) Add an Accessibility-only "Couch-only" Mac setup. Changes the registration, display and readiness gates, about 2 more days.
