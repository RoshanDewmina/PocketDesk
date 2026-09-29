# Farside phone redesign — report

29 Sep 2026. The iPhone/iPad app (`PocketDeskRemote` target, `RemotePhone/`) is redesigned to concept **21 · Reach** per `design/FARSIDE-DESIGN-SYSTEM.md`, with the owner's motion and haptics priority from the overnight run. Branch `worktree-agent-a1134b635e22564b6`, rebased onto `pocketdesk-remote-chat` at `a0c3738` (after the stream-tuning, Mac redesign and Mac parity merges). Evidence levels: simulator build, unit and UI tests, simulator screenshots. Nothing here is a physical-device result.

## What changed

**Theme, fonts, rename.** Doto (variable, `Doto[ROND,wght].ttf` shipped as `Fonts/Doto-Variable.ttf`) and Instrument Serif Italic are bundled with their OFL 1.1 texts and registered through `RemotePhone/Info.plist` `UIAppFonts` (the plist is `INFOPLIST_FILE` in `project.yml`, merged with the stream branch's ProMotion key). CoreText registers the variable font's named instances as `Doto-Black_<Instance>`; plain `"Doto"` resolved to Regular (400), so `Farside.Typeface.dotMatrix` is now `Doto-Black_ExtraBold` (the concept's 800) and `display()` no longer adds `.weight(.heavy)`. `InstrumentSerif-Italic` was already correct. A unit test pins both names. The app is dark only (`UIUserInterfaceStyle = Dark` plus `.preferredColorScheme(.dark)`). `CFBundleDisplayName` is Farside and every user-visible phone string says Farside; bundle IDs, product name, signing and code identifiers are unchanged. `PhoneTheme.swift` is deleted; `RemoteShared/PocketDeskStyle.swift` stays because the Mac host (`BrowserHostSettingsView`) still uses it.

**Shared halftone renderer** (`RemoteShared/FarsideHalftone.swift`, platform-neutral SwiftUI + CoreGraphics, no Metal toolchain needed):
- `FarsideHalftone(style:animated:active:stillTime:ripples:scene:)` rasterises a scene into two tiny luminance bitmaps (bone and ember) and draws one dot per cell in a `Canvas`. It animates through `TimelineView(.animation(minimumInterval: 1/30, paused:))` only while on screen, scrolled into view, `active`, and not in Reduce Motion or Low Power Mode (still frame otherwise).
- `HalftoneLayers` (paint with white; `glow`), `HalftoneRipple` (dated, so it rides the field clock), `HalftoneStyle`.
- `FarsideDotScreen` — the dot-screen dim (tiled dot image over a void wash); it never alters the picture underneath and does not take touches.
- `FarsideArt.reach(gap:contact:)`, `.hand`, `.pointer`, `.radial` — the reaching hand and pointer, reusable by the Mac popover strip and setup rail.

**Component kit** (`RemotePhone/FarsideUI.swift`): dot-matrix mark with ember tip, lowercase wordmark, `FarsideHeading` (Doto for letters/digits/spaces only, punctuation in SF, one Instrument Serif accent word, VoiceOver reads the plain sentence), plates, bone pill / plate / ember-outline / link / round / dock-tile button styles, `LiveDot` (ember only when the Mac is in contact), `FarsideSegmented`, `FarsideNotice`, `FarsideSwitchStyle`.

**Screens**
- **Home**: mark + `farside`, help menu (How to steer, Trouble connecting?, Paste code, Connection details, Forget this Mac), animated halftone gap art, Mac card with an honest status line (the live dot turns ember only once the Mac itself has answered), last-reached time, abstract halftone thumbnail (never a real screen), the big bone **Connect · Closes the gap** pill with an ember arrow, Pair another Mac, How to steer · 40 sec, plan caption. Empty state: "Your Mac is far. Your reach *isn't*." with Scan and Paste.
- **Pairing**: segmented Scan/Paste, inline camera priming, bone viewfinder corners, "Camera is off" with Open Settings, and immediate feedback for a wrong, expired or damaged code (warning haptic, message; acceptance is still only `PairInvitation.parse`). A new pairing notes that it replaces the current Mac.
- **Permission priming** (HIG pre-alert, one Continue): camera (inline), Local Network (before the first connection, or while the Mac approves a new pairing), microphone + speech (before the first dictation).
- **Live session**: full-bleed crisp picture, phone-drawn pointer with an ember contact dot and ring on every accepted click (two concentric rings for a right-click, two quick rings for a double-click), a dotted settle-halo 120 ms after the pointer stops (solid ember while a drag is held), and only a five-dot handle whose middle dot is ember while live.
- **Dock sheet**: swipes up on a spring over a dot-screen dim; Keys · Mic · Clip · Fit · Mode tiles; inline dictation row (dot waveform, "Listening · speak, then Done", scrollable transcript, Done/Retry/Record again, every former voice state and message kept); inline clipboard row (system Paste button, Copy from Mac, Get Mac clipboard); Fit/Fill and View/Control segments; footer with Mac name, route and network round trip ("Direct · 14 ms", from the existing stream statistics), status in plain words, Controls, ember **End session**.
- **Keyboard bar**: ⌘ ⌥ ⌃ ⇧ first, then Esc/Tab, arrows, Delete/Return, clipboard last; ⌘ is fully on screen in portrait (UI test).
- **Gesture coach**: five lessons on a local practice pad driven by the real `NativeGestureEngine` with a local sink (nothing is sent): move (find the one crisp pixel, which is shy), click ("Are you sure you're sure? This dialog has been open since 2019." → "Thank you. It needed that."), scroll (terms nobody read), drag (file into "Definitely final"), zoom (the fine print). Skip always visible; shown once (after a new pairing, or on first Home visit for an existing pairing); replayable from Home and the help menu; VoiceOver gets a summary screen; Reduce Motion gets fades.
- **Friendly errors**: full-screen halftone art, Doto headline, what happened + one fix, one button, optional tip and quip. Kinds mapped from real coordinator statuses and Mac-reported departures only: napping (only when the Mac said it slept), out of reach, still closing, locked, another user, anywhere needs a plan (server code reserved; not emitted yet), code went stale, Mac said no, nobody approved, could not verify, pairing locked (Keychain), relay resting, line went quiet, ended to be safe, relay needs a nod. In-session "Your Mac stopped sharing" card (no Retry: only someone at the Mac can fix it). "Trouble connecting?" checklist sheet.
- **Controls sheet, connection details, concealed/background screen**: restyled on the void/plate system. Merged work from other branches is kept and restyled: Stream statistics toggle, export and Previous stream tuning switch (stream tuning); Mac privacy curtain toggle, "Hide it again" and its footer states, the one-time "Your Mac's Farside restarted" notice and the ~90 s session-loss retry window (Mac parity). The View section is compact so the pointer action tiles also fit in a landscape sheet.

**Motion and haptics** (all with Reduce Motion alternatives): connect sequence (gap art closes as the connection advances, Doto count-down readout, ember ripple and medium tap when the Mac answers); resolution lock before the first frame (noise → coarse → fine placeholder built from abstract art, rigid ticks with rising intensity, success on crisp; it goes straight to crisp when the first frame lands and is never applied to the stream); click heavy impact (existing), right-click two rigid taps 70 ms apart; lift/drop haptics for drags; dictation start/stop; pairing success burst (code dissolves into the mark, success haptic, "Now choose Allow on your Mac"); coach success pop and heavy practice click; springy dock with a light tap; Reconnecting pill that keeps the session view (zoom and pan survive a blip) during the coordinator's own retries.

**iPad and landscape.** Content columns cap at 560 pt; the coach switches to side-by-side in regular width or compact height; the dock caps at 560 (620 in compact height) and hides its segments while a dictation or clipboard row is open in landscape; the Controls View section is compact so pointer actions fit in a landscape sheet.

## Behaviour boundaries

Unchanged: streaming, encoding/decoding, renderer, capture config, `StreamStatistics`/`VideoCodecPolicy`/`StreamQuality`/`PeerMedia`/`StreamTuning`, protocol messages, pairing security, input handling, clipboard and background continuity, pointer telemetry. Model additions are presentation data only: `link` (route + RTT from the existing statistics callback), `lastAcceptedClick` (ripple and haptic kind). Presentation behaviour that did change: dictation moved from a sheet to an inline dock row (same states and guards); the dim behind the dock is visual and passes touches through, as before; a session that is reconnecting by itself stays mounted instead of dropping to Home; the right-click haptic is two rigid taps.

## Verification

All on a dedicated iPhone 17 simulator (iOS 27.0, Xcode 27.0 27A266a), every `xcodebuild` wrapped in `lockf -k /tmp/farside-xcodebuild.lock`, suites run one at a time, final runs on the rebased branch:

| Check | Result |
|---|---|
| `xcodegen generate` | project in sync with `project.yml` |
| `PocketDeskRemote` build-for-testing | succeeded |
| `RemoteCoreTests` (macOS) build-for-testing | succeeded: `FarsideHalftone.swift` and the `FarsideTheme` change compile for the Mac targets |
| `RemotePhoneTests` | 53/53 passed (8 new in `FarsideDesignTests`: bundled font names, Doto punctuation split, error mapping, honest contact state, scan feedback, priming, coach lessons) |
| `RemotePhoneUITests/SessionLayoutTests` | 10/10 passed, including `testOfflineControlsPortraitLandscapeAndKeyboard`, which failed at line 159 on the base; it now passes because the compact View section brings the pointer tiles into the landscape sheet |
| `RemotePhoneUITests/PointerOverlayUITests` | 2/2 passed |
| `RemotePhoneUITests/FarsideRedesignUITests` (new) | 5/5 passed: ⌘ first and fully on screen in portrait; dock tiles, segments, Controls and End; coach runs locally and skips; friendly error closes; expired-code feedback |
| `FarsideScreenshotTour` (new) | skipped by default; with `TEST_RUNNER_FARSIDE_SCREENSHOTS=1` it captured 31 screens on iPhone 17 and on an iPad Pro 11-inch (M5) |

Flake seen under heavy machine load: one run of `testKeyboardKeepsDeliberatelyTypedMultilineDraft` lost characters while XCTest typed ("layouceck"); the rerun and the final run passed, matching the earlier receipt's note on high-speed simulated typing. Updated test strings: "Return to PocketDesk" → "Return to Farside".

## Screenshots

In `~/Downloads/`: `farside-phone-<screen>.png` (iPhone 17 portrait), `farside-phone-landscape-<screen>.png` (iPhone landscape: session, dock, dictation, keyboard, Home, coach), `farside-phone-ipad-<screen>.png` and `farside-phone-ipad-landscape-<screen>.png` (iPad Pro 11-inch), plus `farside-phone-app-icon.png`. Screens: home-empty, home, home-connecting, pairing-camera-priming, pairing-expired-code, pairing-success, priming-local-network, priming-microphone, coach-move, coach-click, coach-drag, error-napping, error-unreachable, error-needs-plan, troubleshoot, session (pointer with contact dot and settle-halo), session-resolution-lock, session-reconnecting, session-sharing-stopped, dock, dock-dictation, dock-clipboard, keyboard, controls, concealed. Session screens use the offline desktop fixture; no real Mac picture is shown or dithered.

Re-capture: `TEST_RUNNER_FARSIDE_SCREENSHOTS=1 xcodebuild … test-without-building -only-testing:RemotePhoneUITests/FarsideScreenshotTour -resultBundlePath <path>` then `xcrun xcresulttool export attachments`. Landscape attachments come out in portrait pixel orientation and need a 90° rotation.

## Known gaps

- No StoreKit or entitlement exists, so the plan caption is static ("Free on home Wi-Fi · Anywhere: off") and the "Anywhere needs a plan" error waits for a server code (`plan_required`, `subscription_required` or `entitlement_required` are mapped already).
- iOS gives no Local Network permission status; priming shows once and the troubleshooter points at Settings.
- The reconnect state cannot dim the last frame (the video view is removed with the track; keeping it would touch the renderer), so it shows a dim noise field.
- Home presence ("awake · home Wi-Fi") needs host presence from the service; the card says only what the phone knows.
- The Mac companion must verify Doto's CoreText name on macOS before using `Farside.Typeface.dotMatrix` there, and can adopt `FarsideHalftone`/`FarsideDotScreen`/`FarsideArt` as is.
- The app icon is a single 1024 px asset; optical small sizes (fewer, larger dots) would need an all-sizes icon set.
- Haptics, 120 Hz smoothness of the halftone art and the gesture coach need a physical iPhone and iPad; the Canvas halftone renders on the main thread at up to 30 fps and has not been profiled on hardware.
- The Mac companion ships its own `HostHalftoneArt` and says it will swap to `RemoteShared/FarsideHalftone` after this merges; it currently has no bundled Doto, and its `NSFont(name: Farside.Typeface.dotMatrix)` check now looks for `Doto-Black_ExtraBold` (the same TTF under `RemotePhone/Fonts` can be reused there).
- Not done in this pass: the "portal" connect alternative, the shy-pointer easter egg on the Home art, splash from dust, speed trail, TipKit follow-up tips, a Live Activity. The session view keeps `stage`, `inputSurface` and the chrome overlays separate so direct-touch mode, hardware keyboard/pointer passthrough and a mini map can slot in.
- PRODUCT.md is not edited here; the integrator records the merge.
