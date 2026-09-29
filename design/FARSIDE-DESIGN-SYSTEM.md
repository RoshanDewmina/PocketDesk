# Farside design system — "Reach"

Adopted 28 Sep 2026. Roshan chose concept **21 · Reach** (`design/farside-round1/21-reach.html`) as the brand and product direction. This file is the design source of truth for the iPhone/iPad app, the Mac menu-bar companion and the website. PRODUCT.md remains the product/scope authority.

Owner decisions (28 Sep): **dark only** for 1.0; **Apple system font** (SF Pro / SF Mono) for everyday app UI with Reach's display accents; the website is a **static site on Cloudflare Pages** using Geist; a Higgsfield hero video may later replace the canvas hero, keeping the ember contact beat.

## 1. The idea

Two hands that can't quite touch is the oldest picture of distance. Farside closes it: your fingertip on the glass, your Mac's pointer on the far side, and **one ember dot where they meet**. That dot is the mark, the app icon's tip, the live indicator and the click ripple. Everything else is quiet: a black void, bone-white type, and halftone dots in the art.

## 2. Tokens

Implemented in `RemoteShared/FarsideTheme.swift` (shared by the phone and Mac targets). Web uses the same values as CSS custom properties.

| Token | Hex | Use |
|---|---|---|
| `void` | `#050505` | App and window background |
| `void2` | `#0B0B0B` | Secondary background, sheet base |
| `panel` | `#121212` | Cards, grouped rows |
| `panel2` | `#191919` | Raised controls, pressed states |
| `bone` | `#EDE8DF` | Primary text, primary icons, white-pill buttons |
| `ash` | `#8C877F` | Secondary text, captions (≈5.6:1 on void — OK for body) |
| `dim` | `#4A4742` | Disabled, decorative only — never for readable text |
| `line` | `#EDE8DF` @ 12% | Hairlines, card borders |
| `line2` | `#EDE8DF` @ 22% | Stronger borders, focused outlines |
| `ember` | `#FF5B1F` | **Contact only:** live/connected indicator, click ripple, Stop/End, the mark's dot, the primary Connect arrow |
| `emberDeep` | `#C23D0E` | Pressed ember, ember on bone |

Rules: text on ember uses `void`. Ember never decorates; if nothing is connected, clicked or stopping, there is no ember on screen (the app icon and the mark are the exception). Semantic success is expressed with bone + a checkmark, not green.

**Type (app).** SF Pro via the system font for all UI text with Dynamic Type; SF Mono (`.monospaced()`) for captions, latencies and technical readouts. Two bundled accents, both SIL OFL 1.1:
- **Doto** (dot-matrix) for display moments only — hero numbers, big headings, the distance readout — at ≥ 28 pt. Doto renders `.` and `:` like a "+", so keep punctuation out of Doto strings (set it in SF or draw it).
- **Instrument Serif Italic** for exactly one accent word in a heading ("The app, *just* working").

**Type (web).** Geist (UI/body), Geist Mono (captions), Doto (display), Instrument Serif (accent) from Google Fonts.

**Spacing** 4 · 8 · 12 · 16 · 24 · 32 · 48. **Radii** control 12, card 20, sheet 28, pill 999. **Hairlines** 1 px `line`.

**Motion.** Primary ease `cubic-bezier(.16,1,.3,1)`; reveal ease `cubic-bezier(.22,1,.36,1)`. Durations: micro 140 ms, standard 320 ms, entrance 600–900 ms with 40–120 ms staggers. Every animation has a Reduce Motion alternative (cross-fade or still frame). The viewport's pointer-follow and zoom keep the existing eased camera (≈0.36 s).

**Haptics.** Click: heavy impact (existing). Connect: success notification + the ember ripple. Errors: warning notification. Coach steps: light selection tick.

## 3. Dither and halftone rules

1. Canvas/Metal halftone for heroes and art; a CSS/SwiftUI **dot screen** for UI texture (e.g. dimming the desktop behind the dock sheet instead of a blur).
2. **Never** dither the streamed Mac picture, text, or controls. Text always sits on a solid plate (`void`, `panel`) — never directly on dots.
3. Ember only for contact: live, click, stop.
4. Art is ambient: low frame rate (≤ 30 fps, pause when off-screen), a still frame in Low Power Mode and with Reduce Motion.
5. Optional privacy idea from the concepts: show the Mac's last frame on Home as a halftone thumbnail that only sharpens after you connect.

## 4. Voice

Quirky, deadpan, always clear about what a button does. Jokes live in secondary lines and empty/error states, never in button labels. Plain language errors with one fix (see `Docs/research/2026-09-28-round2/UX-AUDIT.md` for the 12 rewrites).

Examples from Reach: "Your Mac is far. Your reach isn't." · Connect — "Closes the gap" · "Last reached 11:48 PM · We won't ask why" · Coach: "Tap anywhere to click." with the practice dialog "Are you sure you're sure? This dialog has been open since 2019." → "Thank you. It needed that." · Error: "Your Mac is napping." — "Tap any key on the Mac or open its lid, then try again." · Mac setup: "Two permissions. *Then* we stop asking." · "We only look while a phone you approved is connected."

Avoid "the far side" phrasing in marketing until the trademark opinion is in (use "over there", "far away", "wherever you are").

## 5. Screens (target designs = concept 21)

**iPhone/iPad**
1. **Home** — header with mark + lowercase `farside` wordmark and a help button; halftone art showing the gap ("Gap · 8,421 km" when known, otherwise a playful line); the Mac card (name, model, one honest status line with the live dot, last-reached time, optional halftone thumbnail); one big bone **Connect** pill ("Connect · Closes the gap →", ember arrow box); a short list (Pair another Mac, How to steer · 40 sec); footer caption of plan state.
2. **Live session** — the Mac picture full-bleed and crisp; the phone-drawn pointer (existing) with an ember contact dot at the tip on click and a halftone settle-halo; only the dock handle visible.
3. **Dock sheet** (swipe up) — the desktop dims through a dot screen; buttons Keys · Mic · Clip · Fit · Mode; dictation row (waveform, "Listening · speak, then Done"); segmented Fit/Fill and View/Control; footer "Studio Mac · 14 ms" + ember **End session**.
4. **Keyboard bar** — modifiers first (⌘ ⌥ ⌃ ⇧), then Tab/Esc/arrows, clipboard actions last or in a menu; ⌘ must be visible without scrolling in portrait.
5. **Gesture coach** — 5 short lessons on a local practice pad (nothing reaches the Mac): move, click, scroll, drag, zoom. Skippable, replayable from Home.
6. **Friendly errors** — halftone illustration, plain headline, one fix, one button; secondary tip line.
7. **Pairing, permissions priming, paywall, settings** — same system: void background, panel rows, bone type, one primary action per screen.

**Mac companion**
- **Menu-bar icon**: the mark; its tip glows ember while a phone is connected.
- **Popover**: halftone strip with "Connected · sharing this Mac", who is steering (device, network, latency, fps), Allow control toggle ("Off means view only"), chime toggle, **Pause 10 min** and ember **Stop Sharing**, footer Settings… · Pair a phone… · Quit.
- **Setup window**: left rail with halftone art and steps (Hello · Permissions · Pair your phone · Ready check); right pane with dot progress, heading with one serif accent, permission rows that update by themselves, Back/Continue.

## 6. App icon

Void background; a halftone fingertip (upper left) and a crisp pointer arrow (lower right) with the ember dot where they meet. Must read at 60 px: at small sizes drop the halftone to a few large dots and keep the ember dot. Provide iOS 1024 px (no alpha) and macOS sizes; the Mac menu-bar mark is a template image with the ember tip drawn separately when live.

## 7. Website (static, Cloudflare Pages)

Start from concept 21's hero and sections: full-viewport canvas halftone hero ("Your Mac is far. Your reach isn't."), how it works (3 steps), features, pricing (Free at home / Anywhere CA$5.99/mo or CA$49.99/yr, 7-day trial), FAQ, Download for Mac + App Store badge, plus required pages: Privacy Policy, Support, Terms. Geist + Geist Mono + Doto + Instrument Serif. Lighthouse ≥ 95, reduced-motion still frame, OG images, JSON-LD `SoftwareApplication`, sitemap. No domain yet — deploy only after it's bought.
