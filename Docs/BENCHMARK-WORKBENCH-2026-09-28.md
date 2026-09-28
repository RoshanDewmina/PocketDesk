# Benchmark: Astropad Workbench vs PocketDesk

**Adopted 28 September 2026.** Roshan named Astropad Workbench the primary benchmark: “we should try to match or ideally beat all of these features, and add more like better UI/UX … dynamic zoom etc.” Jump Desktop and Screens remain secondary performance/feature references ([competitor landscape](COMPETITOR-LANDSCAPE-2026-09-28.md); earlier notes in [COMPETITOR-FEATURES-2026-09-13](COMPETITOR-FEATURES-2026-09-13.md)).

Workbench facts are from its product page, App Store listing, help centre and press, checked 28 September 2026. Vendor claims are marked as such; nothing below was hands-on tested by us yet.

## Workbench at a glance

- Native Mac + iPhone + iPad apps. Launched 24 March 2026 (1.0), announced 8 April; **1.3.1 on 17 September 2026**; ten releases in six months.
- **4.8★ from 182 US ratings.** Praise: speed, simplicity, Unified Display. Complaints: copy/paste freezes, connection issues after subscribing, occasional render failures and lost typing (MacStories).
- Requires macOS 15+ (Apple silicon preferred), iOS/iPadOS 26+. Account required (email/Apple/Google, 2FA).
- Pricing: free 20–30 min/day; unlimited **US$14.99/month or US$79.99/year** (launched at $10/$50).

## Feature matrix

Legend: ✅ have · 🟡 partial/unverified · 🔨 in progress (28 Sep agents) · ❌ missing · ⭐ PocketDesk advantage

### Streaming and quality
| Workbench | PocketDesk (28 Sep) |
|---|---|
| LIQUID proprietary tile-based multi-codec (64×64/128×128 tiles, only changed tiles sent), “perceptually lossless”, **“often under 16 ms end-to-end on a local network” (vendor claim)** | ❌ WebRTC H.264. Measured on phone: 15–28 distinct updates/s during motion, p90 gap 117 ms. 🔨 performance agent |
| H.265/HEVC on Apple silicon; user codec choice; switches to standard codecs for video playback | ❌ H.264 only. 🔨 HEVC under evaluation |
| Content-aware encoding for text clarity and refresh (1.3) | ❌ |
| “30% faster streaming” rebuild (1.3) | 🔨 |
| Retina / full-fidelity colour | 🟡 “Sharper” up to 3840 px; likely costs frame rate; 4:2:0 chroma |
| “Velocity Control” network adaptation for zoom/pan/scroll | 🟡 stock WebRTC congestion control. 🔨 frame-rate-first adaptive policy |

### Input
| Workbench | PocketDesk |
|---|---|
| iPhone touch is **direct/absolute** (tap where you want) | ⭐ relative trackpad (precise on small targets). ❌ no direct-touch option |
| Two-finger scroll; touch-and-hold drag | ✅ |
| External mouse/trackpad and hardware keyboard through iPhone/iPad | 🟡 unverified |
| On-screen keyboard with ⌘⌥⌃⇧, arrows, Tab | ✅ compact toolbar |
| Voice dictation button (multi-language) | ❌ (iOS keyboard dictation untested) |
| Apple Pencil incl. Scribble | ❌ |
| Middle mouse (3D/CAD) | ❌ |
| Clipboard sync | ❌ |
| iPad shortcut remapping; ⌘Space, Mission Control, Dock | 🟡 ⌘Space only |
| Click haptics | ⭐ not advertised by Workbench |

### Viewing and navigation
| Workbench | PocketDesk |
|---|---|
| Pinch/pan zoom (smoothed in 1.2.2) | ✅ basic. 🔨 natural pinch, Fill/Fit + toggle |
| Mini map with zoom slider (iPad only) | ❌ |
| Unified Display: all Mac displays combined, matched to device resolution | ❌ single display |
| Virtual screen for headless Mac mini | ❌ |
| Fullscreen mode | ✅ immersive session, hideable dock |
| Picture-in-Picture (1.3) | ❌ |
| Gesture reminder (ⓘ) | ❌ |
| Visible macOS cursor (1.1) | 🟡 tiny. Next: phone-rendered pointer (see cursor research) |
| — | ⭐ edge auto-follow panning; 🔨 Fill-reachable / Fit-in-safe-area modes |

### Mac companion and reliability
| Workbench | PocketDesk |
|---|---|
| Privacy Curtain: hide/dim the Mac’s screen, optional local input block (1.3) | ❌ |
| Watchdog: auto-relaunch after crash/hang (1.3) | ❌ |
| Smart sleep handling (1.1) | 🟡 keep-awake; Mac must stay unlocked |
| Background connection persistence (1.2) | ❌ session ends on background. 🔨 survive `.inactive` |
| Diagnostic report submission | ❌. 🔨 stats overlay |
| Device catalogue / switch Macs | 🟡 one paired Mac |
| Simple native Mac app | 🔨 menu bar app + setup window |

### Connectivity and account
| Workbench | PocketDesk |
|---|---|
| Global relay, 11 regions, no port forwarding, cellular/VPN/corporate networks | ❌ Tailscale only; own signalling/TURN code exists, not deployed |
| End-to-end AES-256 | Protected WebRTC DTLS-SRTP media; negotiated cipher parity has not been verified |
| Account + 2FA required | ⭐ no account: QR pairing + approval on the Mac |
| Free 20–30 min/day; $14.99/mo, $79.99/yr | ⭐ proposed: unlimited free on own network; CA$5.99/mo or CA$49.99/yr remote |

### AI and agents
| Workbench | PocketDesk |
|---|---|
| Marketed for monitoring agents; in practice remote desktop + dictation | 🟡 MCP backend built (routes unmounted); open-from-chat and agent pause/takeover/resume planned — **proposed differentiator, not an implemented authenticated chat handoff** |

## Where we stand

- **Behind:** the streaming engine (frame delivery, codec, text fidelity, measured latency), Mac-side polish (privacy curtain, watchdog, sleep), deployed relay, clipboard, dictation, PiP, mini map, multi-display.
- **Potential differentiators, not measured competitive wins:** trackpad-first phone ergonomics, auto-follow, haptics, no account, free local use, planned chat/agent integration.

The completed [research synthesis and priority order](research/2026-09-28/BUILD-PRIORITIES.md) supersedes the rough order below. Privacy curtain, PiP, background persistence and virtual display support are not established quick additions. Current build verification is recorded in the implementation ledger.

## Plan to match, then beat

1. **Engine parity (critical path).** Fix frame delivery; HEVC; text-fidelity strategy (content-aware / region-based encoding); publish our own measured latency. See encoder research in `Docs/research/2026-09-28/`.
2. **Separate feature experiments (public API and lifecycle validation required):** clipboard sync, dictation button, zoom indicator (iPhone) and mini map (iPad), privacy curtain, watchdog + launch at login, PiP, background persistence, optional direct-touch mode.
3. **Beat on UX:** dynamic zoom (caret-follow while typing, tap-to-fit window), phone-rendered crisp pointer, haptics, gesture coach, one-tap reconnect.
4. **Beat on agents:** open your Mac from ChatGPT/Claude, “agent needs you” alerts, explicit takeover and hand-back.
5. **Access parity:** deploy owned relay for cellular without Tailscale before charging.
6. **Later:** unified/virtual display for headless Macs, Apple Pencil, middle mouse.

Benchmark tests use `bench/stimulus.html` and `bench/analyze.py`; include Workbench (free tier) in every head-to-head recording set.

## Sources

[Product page](https://astropad.com/product/workbench/) · [App Store](https://apps.apple.com/us/app/astropad-workbench/id6758788573) · [1.3 notes (9to5Mac)](https://9to5mac.com/2026/08/19/astropad-workbench-1-3-adds-faster-streaming-privacy-curtain-and-more/) · [Launch (9to5Mac)](https://9to5mac.com/2026/04/08/astropad-unveils-workbench-for-mac-remote-desktop-made-for-the-ai-era/) · [MacRumors](https://www.macrumors.com/2026/04/08/astropad-workbench-app/) · [MacStories review](https://www.macstories.net/reviews/astropad-workbench-rethinks-remote-mac-control-for-ai-agents/) · [LIQUID](https://astropad.com/blog/liquid/) · [Help: input](https://support.astropad.com/en/articles/14025802-mouse-keyboard-and-input-in-workbench) · [Help: mini map](https://support.astropad.com/en/articles/14022295-workbench-mini-map) · [Help: iPhone setup](https://support.astropad.com/en/articles/14025859-setting-up-workbench-on-your-ipad-iphone) · [Help centre](https://support.astropad.com/en/collections/18710933-workbench)
