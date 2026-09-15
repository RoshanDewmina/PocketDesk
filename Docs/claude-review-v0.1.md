I reviewed the specification only. I did not read or run any PocketDesk code. I ran a filesystem search and observed four top-level directories (`~/Documents/ChatGPT/Saas/PocketDesk`, `-signaling`, `-media`, `-research`) plus the handoff ZIP in two locations — I opened none of them, and nothing below is a claim about what that code does.

**Labels used throughout:** `[E]` = evidence I verified against a primary or near-primary source this session (cited at the end); `[I]` = inference from the document plus platform mechanics; `[P]` = my preference/judgement call, where a reasonable person could choose differently.

---

## 1. Overall assessment

The document is unusually well-disciplined for a v0.1. The confirmed/proposed/later/unverified labelling, the contradictions-resolved table (§14), and the refusal to launder a passing build into a working product (§12) are better than most funded PRDs. My criticism is not that it is sloppy; it is that **its rigour is aimed at the wrong risks.**

Three structural problems:

**(a) The specification's core scenario invalidates most of its own recovery design.** `[I]` Section 2 says the job is "control a Mac while away from home." Section 7's state table then resolves at least six failure states with an action at the Mac: *"recovery on Mac,"* *"grant control on Mac,"* *"explicitly select another display,"* *"Generate a new invitation."* In the product's defining moment the user is a hundred kilometres from the Mac. Every one of those is a dead end at the exact moment the product is supposed to earn its existence. This is the single most important gap in the document, and it is invisible because each state reads sensibly in isolation.

**(b) The viewing model is specified in a way that cannot work on a phone.** `[I]` F13 proposes 40–45% of portrait content height for the desktop, and F15 defers continuous zoom to beta. On an iPhone 17 (~400 pt wide, ~740 pt usable height), a 13.6" MacBook Air display fitted to width renders at roughly **0.27× scale** — macOS 13 pt body text becomes ~3.5 pt, about 7–8 device pixels of cap height before H.264 compression touches it. It is not small; it is unreadable. Yet §9(B)'s pass gate requires *"edit a short document."* Zoom is not a beta refinement — **it is the reading mechanism**, and the prototype cannot pass its own acceptance criteria without it. Once you accept that, the premise of a permanent split (always keep the desktop visible above a trackpad) weakens: at legible zoom you are looking at a small window onto the desktop, so *panning and orientation* dominate, not a fixed proportion.

**(c) Host availability is written as an open product decision. It is mostly an OS constraint.** `[E]` Third-party apps cannot capture the macOS login window — ScreenCaptureKit has no graphical context there and no TCC prompt can appear without a user session. Separately, since macOS Sequoia, screen-recording permission requires **monthly re-approval**, with no documented path to the Persistent Content Capture entitlement. F10 ("Release decision") and F09 therefore are not really decisions: a logged-in, unlocked session is a hard requirement, and your capture permission can silently lapse *while you are away* — a failure mode the document does not contain at all. Apple's built-in Screen Sharing works when locked because it is privileged; you cannot match it.

Beyond those: the product value case is the weakest part of the document, and it is weak in a specific way. The differentiation hypothesis is "reliable remote access **plus** unusually comfortable phone controls." `[I]` Reliable remote access is the capital-intensive, decade-of-edge-cases half that Jump, Screens, Splashtop and (free) Chrome Remote Desktop already have; comfortable controls is the differentiable half that any of them could copy in one release. The document's own research finding — users like one app's controls but trust another's connections — argues that reliability, not comfort, is what actually moves people. So the plan is to spend most of the effort on the commodity half in order to ship the copyable half. `[P]` That is worth doing as a personal tool and a portfolio piece; it is not yet a defensible product thesis, and the spec should say which of those two it is, because almost every downstream decision (accounts, pricing, relay, support, App Store) hangs on it.

The good news: the actual v1 is much smaller than this document, and the operating risk you are most worried about (relay bandwidth) is the one you should worry about least at your scale. `[E/I]` At Cloudflare Realtime TURN's $0.05/GB with 1,000 GB free, a ~1.5 Mbps session costs ~$0.034/hour relayed; 20 beta testers at 3 hours/month is ~40 GB — inside the free tier. Abuse of an open relay, not legitimate use, is the cost risk.

---

## 2. Prioritized gaps

Severity: **S1** blocks a useful product · **S2** causes a bad first release · **S3** wastes effort or creates avoidable risk · **S4** document hygiene.

| # | Sev | Section | Concrete failure scenario | Recommended change | Resolve by |
|---|---|---|---|---|---|
| 1 | S1 | §7 state table; F33; F17 | You are at the airport. Control silently stops because Accessibility was reset by an OS update. The app says "recovery on Mac." You have no Mac. Session is unrecoverable for three days. `[I]` | Add a rule: **every state must have an action performable from the phone alone, or be explicitly marked "requires physical access" and prevented in advance.** Rewrite the six Mac-action rows. Add host self-checks that run before you leave and a push notification when a capability lapses. | Before mockups |
| 2 | S1 | F13, F15, §5 portrait | Prototype ships; you cannot read a Terminal line or a document; §9(B) gate cannot be met. `[I]` | Move continuous zoom + pan to **prototype**. Replace the fixed 40–45% split with a **full-bleed desktop + thumb-reachable overlay control layer**; keep the split as an option to test, not the default. | Before mockups |
| 3 | S1 | D04, F09, F10, §8 | Mac is logged in but the lid is closed / it slept / screen-recording approval lapsed after 30 days. Nothing works and Home still shows the Mac as saved. `[E]` | State as a **permanent constraint**, not a decision: PocketDesk requires an awake, logged-in, unlocked session; lock-screen and login-window control are out of scope unless Apple grants an entitlement. Add: TCC re-approval monitoring, a keep-awake assertion with battery caveats, and an honest host-reachability heartbeat. | Before prototype build |
| 4 | S1 | §2 purpose, §3 | Product ships, works, and nobody (including you) opens it twice a month. No way to tell in advance. `[I]` | Add a **falsifiable wedge statement** and an intent declaration (personal tool vs commercial bet). Name one recurring job and one measurable success signal (e.g. "≥6 self-initiated away sessions in 4 weeks, unprompted"). | Before more design |
| 5 | S2 | F24, F25, §5 keyboard | Compose-and-Send works for a typo fix; it fails for Spotlight, search fields, autocomplete, shells, vim, any per-keystroke UI. Separately, **synthetic keystrokes are blocked in password fields by macOS secure input** — "log into a site on my Mac" simply cannot work. `[E/I]` | Recognise F24 and F25 share one key-event transport; staging them apart is a false economy. Build key events first, ship **live typing as default with compose-and-Send as the long-text fallback**. Document the secure-input limitation as a product constraint on the box, not a discovered bug. | Before prototype build |
| 6 | S2 | F03, F04, §8 | A pairing QR shown on a Mac in a co-working space, or an invitation pasted into a chat thread, enrols an attacker. Approval dialog only says "someone holding this invitation." `[I]` | Add **channel binding**: after key exchange, both devices display a short comparison string the user matches before approving. Also specify **host long-term key pinning** at pairing and verification of the media fingerprint against it — this is what "the service cannot substitute an endpoint" actually means. | Before prototype build |
| 7 | S2 | F06, F31, §10 | Phone is stolen on holiday. Trust lives only on the two devices. There is no way to revoke without flying home. `[I]` | Accept for prototype but **name it as a known hole** with a planned answer. Design device identity so an account can be layered later **without re-pairing**. Add "Revoke all devices" at the Mac. | Documented now; solved before beta |
| 8 | S2 | §10, §9(D) | Signalling service is down for 30 minutes. That is a 100% product failure at the only moment that matters. No SLO, no rollback plan, no status surface. `[I]` | Add a short **service acceptance section**: uptime target, deploy/rollback, an in-app status message, and a **service-independent LAN direct path** using cached pairing. The LAN fallback is cheap insurance and a real trust story. | Before beta |
| 9 | S2 | §4 stages | The "prototype" column contains ~18 features. It is a beta. It will not be finished, and the availability and legibility problems above will surface late. `[I]` | Cut prototype to the list in §4 below. Demote F08, F17, F18, F19, F20-as-a-mode, landscape-as-designed-layout, F06 multi-device. | Now |
| 10 | S3 | §11 deferred ideas | "App launcher, app-aware controls, macros" would likely reclassify you under **App Store guideline 4.2.7**, which requires remote desktop clients that mirror *specific software or services* to be **LAN-only** with account management on the host — fatally incompatible with your confirmed goal. `[E]` | Move those from "deferred" to **"excluded — would jeopardise App Store eligibility."** Keep PocketDesk a generic mirror of the host device. | Now (one line) |
| 11 | S3 | §8 media baseline | 60 fps target burns battery, bandwidth (relay cost) and engineering for a product whose job is reading text and clicking precisely. `[I/P]` | Target **30 fps with sharp still-frame refresh on idle**; spend the budget on input-to-photon latency and text sharpness. Replace Auto/Sharp/Save-data trio with one automatic mode + one "sharpen now" action. | Before prototype build |
| 12 | S3 | §8 input lease | A 2-second lease means a held mouse button can persist up to 2 s after the phone dies — long enough to drop a dragged file in the wrong folder. `[I]` | Shorter heartbeat (250–500 ms, release after 2 misses) **for held state specifically**; refuse to *begin* a drag unless the lease is healthy. Keep 2 s for session liveness. | Before prototype build |
| 13 | S3 | §10, §8 | The document treats relay bandwidth as the headline economic risk. At beta scale it is roughly free; abuse of an open relay is the real exposure. `[E/I]` | Rewrite the relay-economics paragraph around **abuse quotas and short-lived credentials**, and **rent managed TURN for v1** rather than operating relays. | Now |
| 14 | S3 | §2, §13 Q10 | "Proposed minimum iOS 26 / macOS 26" was written two days before **iOS 27 and macOS 27 ship (14 September 2026)**; macOS 27 is Apple-silicon only. `[E]` | Restate as "floor iOS 26 / macOS 26, developed and tested on 27." Add an annual-OS-break maintenance line — capture and permissions APIs shift most years. | Now |
| 15 | S3 | §8, §11 | Your Mac screen is lit and unattended in your home while you work on it from a café; notifications render into the stream. Not addressed anywhere. `[I]` | Add a privacy note and a host option to warn about notifications. Mark "blank the host display during a session" as **unverified feasibility**, not a promise. | Before beta |
| 16 | S4 | §4 table | Cells reading "Prototype / release" (F06, F15, F17, F18, F24, F33, F35, F38) are unfalsifiable — you cannot tell what must exist when. `[I]` | Split into two columns: *prototype line* and *release line*, each a sentence. | Now |
| 17 | S4 | §3, §9 | §3's "What we must test" column has no method, threshold, or owner; §9 forbids invented latency claims but sets no provisional bar, so nothing can fail. `[I]` | Add provisional, explicitly revisable bars (e.g. p95 input-to-photon ≤150 ms LAN / ≤400 ms relayed; ≥95% session establishment within 10 s). A wrong number you can revise beats no number. | Before prototype build |
| 18 | S4 | §12, §14 | Document says "a separate PocketDesk project"; I observed four sibling directories. Relative `Docs/…` links have no stated root. `[E]` | Name the canonical repo path and root explicitly; list the other directories as archived or fold them in. | Now |

---

## 3. The five questions that matter most

**Q1 — Is PocketDesk a personal tool and portfolio piece, or a commercial bet?**
*Recommended default:* **Personal tool first.** `[P]` Build it for yourself, use it for four weeks, and defer every account, pricing, support and multi-device decision until then. Nothing in §10 needs an answer to ship something you use. If self-usage is low, you have learned the most valuable thing cheaply. This single answer deletes roughly a third of the open questions in §13.

**Q2 — Full-bleed desktop with an overlay control layer, or the split?**
*Recommended default:* **Full-bleed + overlay, with pinch-zoom and pan in the prototype.** `[P]` The split is an appealing idea that the arithmetic does not support at phone scale. Keep it as a switchable mode so you can test the hypothesis rather than abandon it — but do not let the first build depend on it. Related: don't defer landscape. Rotating a full-bleed view costs nothing and gives ~1.6× more legible pixels; what you defer is the *designed side-control layout*, not the orientation.

**Q3 — Compose-and-Send, or live keystrokes?**
*Recommended default:* **Both, live by default.** `[P]` You must build key-event transport for Esc/Tab/arrows/modifiers anyway (F25 is already prototype-stage); compose-and-Send is then a UI that replays a buffer through the same path. Make Terminal usage part of the prototype gate — it is the fastest way to find out whether your input layer is honest.

**Q4 — What availability do you promise?**
*Recommended default:* **"Requires your Mac awake and logged in"** — permanently, in marketing, not as a prototype caveat. `[E-backed]` Then invest the saved effort in making that state *observable and defensible*: keep-awake assertion, screen-recording permission freshness monitoring, host heartbeat so Home can say "reachable 4 minutes ago" honestly, and a push when something lapses. This converts a limitation into the product's most trustworthy feature.

**Q5 — Do you operate infrastructure, or rent it?**
*Recommended default:* **Rent.** `[P]` Managed TURN plus the smallest possible signalling endpoint. Do not run relay servers for v1. "Build PocketDesk's own remote access" (D03) means owning the integration and the customer experience — the document already says exactly this in §8, and renting TURN is fully consistent with it.

---

## 4. Smallest useful version

**One sentence:** *From cellular, away from home, read and fix something on my Mac without touching it.*

**Mac host** — menu-bar app only. Capture the main display. Post pointer/keyboard events. Pair via expiring QR with a comparison code. Trusted devices list with revoke. Prominent Stop sharing. Keep-awake toggle. Screen-recording-permission freshness check.

**iPhone** — saved Mac; Connect; **full-bleed desktop with pinch zoom and pan**; thumb-reachable overlay bar (trackpad toggle, click, right-click, deliberate drag, keys + modifiers, text); honest connecting/stale/disconnected states; Disconnect always reachable.

**Transport** — WebRTC, rented TURN, minimal signalling, host public key pinned at pairing.

**Explicitly out of v1:** multi-display, multi-device, quality presets, connection-details panel, before-you-leave ritual, view-only as a designed mode (keep it as a degraded state), designed landscape layout, external keyboard, shortcut buttons, sensitivity settings, direct-touch mode, iPad, accounts, payments, diagnostics export.

**Single gate:** on two different days, from cellular and away from home, fix a typo in a document **and** run one command in Terminal, with no physical access to the Mac before or after. If that is dull rather than impressive, it is working.

---

## 5. Specific edits to the document

1. **§2, after the purpose statement** — add a falsifiable wedge and an intent line: *"PocketDesk is being built first as a tool Roshan uses. A commercial decision is deferred until four weeks of unprompted self-use. Wedge hypothesis: existing apps connect well but are uncomfortable to operate one-handed on a phone; PocketDesk trades feature breadth for phone ergonomics."*
2. **§2 platform scope** — replace the OS sentence: *"Floor: iOS 26 / macOS 26. Development and testing target: iOS 27 / macOS 27 (released 14 September 2026; macOS 27 is Apple-silicon only). Expect annual capture/permission API churn as recurring maintenance."*
3. **§4, F09/F10** — collapse into one feature and change its framing from decision to constraint: *"F09 Host availability (constraint). PocketDesk requires an awake, logged-in, unlocked macOS session. Third-party apps cannot capture the login window, and screen-recording permission requires periodic re-approval since macOS Sequoia. Lock-screen and login-window control are out of scope unless Apple provides an entitlement."* Delete F10's "Release decision" status.
4. **§4, F15** — move continuous zoom and pan from beta to **prototype**, and add: *"Fit-to-screen is an orientation aid, not a reading mode."*
5. **§4, F13/F14** — restate the split as an experiment: *"Default viewing model is full-bleed desktop with a revealable, thumb-reachable control overlay. A 40–45% portrait split is retained as a comparison option to be tested, not the shipping default."*
6. **§4, F24/F25** — merge the transport, split the UI: *"F24/F25 share one key-event channel. Live keystrokes are the default; compose-and-Send is a long-text convenience. macOS secure input blocks synthetic keystrokes in password fields; this is a permanent product limitation and must appear in onboarding, not only in help."*
7. **§4, F20** — demote from feature to state: *"View-only is a degraded state when control permission is unavailable, not a designed mode."*
8. **§4, F08** — replace the "turn off Wi-Fi and test" ritual with *"host-side reachability heartbeat; Home shows a dated, honest last-reachable time."*
9. **§5 Mac companion inventory, Incoming approval row** — add: *"Both devices display a short comparison string derived from the completed key exchange. Approval is only meaningful if the user confirms the strings match."*
10. **§7 state table** — add a column: **"Can the user act from the phone alone?"** Any row answering "no" is either a design bug or must be prevented before departure. Rewrite the rows currently resolving with "recovery on Mac."
11. **§8 media baseline** — replace *"a 60 fps target with lower-quality/30 fps fallback"* with *"30 fps target, prioritising input-to-photon latency and text sharpness; still-frame refresh when the desktop is idle."* Delete the sentence about round-trip-acknowledged frames — it is a bug note, not architecture; move it to the engineering doc.
12. **§8 input lease** — specify two timers: *"Held input (buttons, modifiers, drags) uses a 250–500 ms heartbeat and is released after two missed beats. Session liveness uses a 2 s lease. A drag may not begin unless the held-input channel is healthy."*
13. **§10** — rewrite the relay paragraph: *"At beta scale, relay bandwidth is not a material cost (managed TURN is priced near $0.05/GB with a large free allowance; a session costs a few cents per hour). The real exposures are abuse of an open relay, service uptime at the moment of need, and support load from carrier/NAT edge cases. v1 rents TURN rather than operating relays."*
14. **§11** — move "App launcher, app-aware controls, macros" from *deferred* to a new **Excluded** group with the reason: *"Would likely reclassify PocketDesk under App Store guideline 4.2.7 (mirrors of specific software/services), which mandates LAN-only operation — incompatible with D01."*
15. **§12** — name the canonical project path and state the status of the other three sibling directories.
16. **§13** — reduce to the five questions in section 3 above; the remaining ten are downstream of them.

---

## 6. What I would keep unchanged, and why

- **The confirmed/proposed/later/unverified labelling.** `[P]` This is the document's best feature and the reason a useful review was possible at all. Do not let it decay as the spec grows.
- **§14's contradictions-resolved table.** Rare and genuinely valuable. Extend it as decisions change rather than quietly editing history.
- **The refusal to inherit CAD 19.99, the ten-minute preview, "no cloud," and the LAN-only framing.** Correct on every count, and correctly explained.
- **"No replay of queued actions" and "fresh authenticated session after interruption."** `[E/I]` These are safety-critical *and* architecturally forced — iOS suspends backgrounded apps and drops arbitrary sockets, so a resumable session was never available. The document reached the right answer; keep it and keep the reasoning.
- **F37 background privacy and the app-switcher concealment rule.** Cheap, correct, and frequently missed by competitors.
- **The anti-theatre rules:** no decorative fake desktop, no local animation as proof of remote delivery, haptics acknowledge local gestures only. `[P]` These are the most product-mature sentences in the document.
- **§9's insistence on physical devices, a separately demonstrated forced-relay session, 50 connection cycles, and a 30-minute session.** Concrete and falsifiable — the rest of the acceptance criteria should be rewritten to match this standard.
- **§12's honesty about implementation state**, including the failed build. Keep that tone; it is what makes the rest of the document trustworthy.
- **The decision to own connectivity (D03) and to use WebRTC rather than invent transport or require a VPN app.** `[I]` Right call — and renting TURN does not weaken it.

---

**Sources** (verified this session; everything else is labelled inference or preference):

- [Apple App Review Guidelines — guideline 4.2.7, Remote Desktop Clients](https://developer.apple.com/app-store/review/guidelines/)
- [MacRumors — macOS Sequoia requires monthly screen-recording permission re-approval](https://www.macrumors.com/2024/08/15/macos-sequoia-screen-recording-app-permissions/) and [9to5Mac on the same change](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/); [Apple Developer Forums thread on the prompt and the undocumented Persistent Content Capture entitlement](https://developer.apple.com/forums/thread/761443)
- [Apple Developer Forums — ScreenCaptureKit at the login window (no graphical context, no TCC prompt)](https://developer.apple.com/forums/thread/814152)
- [Apple TN2150 — Using Secure Event Input Fairly](https://developer.apple.com/library/mac/technotes/tn2150/_index.html)
- [Apple Developer Forums — iOS app network connectivity from a suspended state](https://developer.apple.com/forums/thread/72027)
- [Cloudflare Realtime TURN service and pricing](https://developers.cloudflare.com/realtime/turn/)
- [MacRumors — Apple announces iOS 27 release date (14 September 2026)](https://www.macrumors.com/2026/09/09/apple-announces-ios-27-release-date/); [9to5Mac — macOS 27 Golden Gate release notes](https://9to5mac.com/2026/09/09/macos-27-golden-gate-here-are-apples-full-release-notes/)

I can turn this into a document you can edit alongside the spec — say the word and I'll publish it as a private page or drop it next to `PocketDesk.md` as markdown.