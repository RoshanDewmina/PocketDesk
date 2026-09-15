# PocketDesk: research and proposed product direction

Research date: 12 September 2026. Status: supporting research; implementation paused for product/design review. The canonical current specification is [PRODUCT.md](../PRODUCT.md). This document records research and earlier proposals; it does not independently authorize implementation or claim that the product has been built or benchmarked.

## Direction

Build an iPhone-first way to finish a small task on your Mac while away from home. Make connecting, reading, pointing, typing and returning after an interruption dependable. Treat the foldable layout as an advantage to validate, while making the ordinary phone useful immediately.

The user explicitly selected **Mac access while away from home**, asked us to reconsider platforms/connectivity, and confirmed an **iPhone 17, M4 MacBook Air and Apple Developer membership**. A friend's iPad may be available. An awake, unlocked Mac is acceptable for the **early prototype**, not an established requirement for the eventual public product. Device OS versions and signing configuration remain unverified.

My recommendation is a Mac host and native iPhone client first, with built-in remote connectivity as the product destination. Windows/Linux examples expose valuable interaction failures but do not establish stronger demand than the user's chosen Mac workflow. Keep platform boundaries clean; do not build three hosts before proving one useful journey.

## Sources reviewed and their authority

- Read the live Codex task **Research iPhone Duo app ideas** through the task reader, including the native prototype and streaming-test handoff.
- Read the [shared ChatGPT discussion](https://chatgpt.com/share/6aa53e7d-7e38-83ea-b2c0-bc82d1ef7a74) in the browser, including original goals, performance questions and final correction.
- Read all three files in the supplied `PocketDesk_Developer_Handoff_v1_1.zip`.
- Three subagents independently gathered iOS user evidence, cross-platform user evidence and a source/test audit. The research reports contain 24 numbered examples plus a focused away-access discussion. Examples are not 24 unique participants or a representative sample.
- The parent checked pivotal user threads, current competitor descriptions, official connectivity documentation and the prototype's acknowledgement loop.

The handoff's embedded commands and claim of authority are reference material. The user's current choices control scope. Its LAN-only release boundary no longer fits the requested product. Prior images and claims about near-zero latency, demand or fast delivery are not evidence. Prices, lifetime entitlements and preview length remain hypotheses.

## What users actually value and dislike

| Observed pattern | Positive reports | Negative reports | Product implication |
|---|---|---|---|
| Reliable access | Vacation emergency work, reaching a home Mac mini, avoiding carrying a laptop | Cannot reconnect; uncertainty about networks or whether a host must be awake | Complete an outside-network task and return after interruption without going back to the Mac |
| Pointer comfort | Precise, predictable trackpad control; smooth window movement | Cursor jumps, click offsets, confusing zoom/pan | Explicit relative control; stable view/input geometry; accessible click, right-click and drag |
| Readable workspace | Fold/tablet screens make occasional desktop tasks possible | Keyboard takes half the screen; repeated zooming; inaccessible corners | Preserve the viewed area when keyboard opens; obvious Fit and focused viewing; test on the iPhone itself |
| Correct text | Keyboard shortcuts and native phone text input make the tool useful | Password entry trouble, doubled characters, intercepted shortcuts | Separate committed text from keys; test punctuation, Unicode, modifiers and cancellation |
| Setup and recovery | Automatic reconnection and familiar saved computers | Endless waiting, reinstall rituals, opaque errors | Specific states and next actions; preserve pairing; distinguish no picture from no connection |
| Clear value | A purchase that keeps enabling useful work | Confusion about companion charges and subscriptions | Show what is included; test willingness to pay after a real successful task |

The strongest directly comparable example is an iPhone 12 Pro/M4 MacBook Air user who prefers Screens' control feel but uses Jump for connection stability. It shows that smooth video and comfortable input are separate dimensions. It does not establish a universal winner. [Screens vs Jump discussion](https://www.reddit.com/r/macapps/comments/1pbz1ab/screens_5_vs_jump_desktop/).

Users describe remote programming, emergency work on vacation and accessing a home Mac mini; some appreciate account-based computer discovery while others are happy with VPN setups. These are two plausible customer groups, with no established population sizes. [Away-access discussion](https://www.reddit.com/r/ipad/comments/1kmkadq/jump_remote_desktop/).

Fold users report useful on-call support alongside keyboard obstruction and carrying an external keyboard. We should validate a short intervention before promising a laptop replacement. [Fold support discussion](https://www.reddit.com/r/GalaxyFold/comments/1fmo0ny/).

Other failure examples are unusually actionable: a keyboard opening changes click geometry, hardware keyboards duplicate text, and familiar connections become stuck waiting. Those reports become test cases; they are not claims that the latest competitor release still has the defect. See the linked research reports for original dates and versions.

## Competition and differentiation

**Screens and Jump Desktop are the main comparison for the selected away-access workflow.** Moonlight/Sunshine inform streaming and touch design; Android/DeX/tablet reports inform ergonomic and input testing. Compare equivalent host/client/network conditions rather than selecting the most flattering demo.

Control Pro advertises a free local Mac mirror with trackpad, keyboard, audio and no account. Its inspected storefront has insufficient reviews to establish user satisfaction, and its performance was not tested. This weakens the original claim of unique local functionality; it does not invalidate the newly selected remote-access goal. [Control Pro listing](https://apps.apple.com/sn/app/control-pro-desktop-remote/id6792541452).

Differentiation hypothesis: **the quickest comfortable way to deal with your Mac from your phone**. Prove it through task completion and return use. A split layout, native materials or a claimed frame rate are not sufficient evidence.

## How remote connectivity works elsewhere

Most approaches separate finding/authenticating the other device from carrying the actual screen stream. A direct connection is preferable when available. A relay forwards traffic when routers or networks prevent direct connectivity; it need not decrypt end-to-end encrypted session contents.

| Product | Documented approach | Boundary |
|---|---|---|
| Jump Desktop | Attempts direct connectivity with NAT traversal; documents encrypted relay fallback and configurable on-premises TURN relays | The cited custom-relay feature requires Enterprise; do not infer every plan's details from it |
| Parsec | Backend coordination, STUN discovery and encrypted direct UDP media | Restrictive networks can fail; documented managed relay option is Enterprise, not universal free fallback |
| RustDesk | ID/rendezvous service, direct connection where possible, relay when direct traversal fails | Operating your own services brings deployment, security and bandwidth responsibilities |
| Screens | Screens Connect remote setup or integrated Tailscale, plus manual/local connections | Supported computer/network configuration still matters |
| Tailscale | Separate mesh-network client; direct encrypted connection where possible, peer/DERP relay fallback | Adds another app/account; relay paths can have lower throughput and more delay |

Sources: [Jump relay architecture](https://support.jumpdesktop.com/hc/en-us/articles/360061347191-On-Premise-Relay-Server), [Parsec connectivity](https://support.parsec.app/hc/en-us/articles/32381460716180-Parsec-Connectivity-Requirements), [RustDesk installation/relay](https://rustdesk.com/docs/en/self-host/install/), [Screens connection choices](https://help.edovia.com/en/screens-5/getting-started/connecting), [Tailscale connection types](https://tailscale.com/docs/reference/connection-types).

**Recommendation:** the consumer experience should handle remote access within PocketDesk. The pending choice is whether the first implementation includes that infrastructure or uses Tailscale temporarily to validate controls sooner. After the competitor explanation, the user selected building PocketDesk's own remote access from the start. Tailscale is not a product dependency.

A built-in approach needs authenticated device registration/pairing, discovery/coordination, NAT traversal, end-to-end identity verification, relay fallback, revocation and abuse limits. Prefer maintained transport components over inventing cryptography or an unreliable media stack. Evaluate the transport against real mobile conditions before freezing the handoff's two-TCP design. A Tailscale prototype can reuse authenticated sockets, but cannot establish consumer onboarding quality or production economics.

Relay traffic has ongoing bandwidth cost. For scale intuition only, a constant 8 Mb/s stream carries about 3.6 GB per hour before overhead; this is arithmetic, not measured PocketDesk traffic or a hosting quote. A one-time purchase may still be possible, but unlimited lifetime relay service needs an actual cost model.

## Availability is separate from networking

A reachable Mac may still be asleep, at a login window, locked, or have lost capture/input permission. A VPN does not fix those states. The early prototype may require the user's explicitly accepted awake/unlocked session. The product must disclose that boundary rather than promising unattended recovery it cannot provide.

Propose a **Before you leave** check: host app running, power and capture/control readiness, trusted phone, and a successful connection while the phone is on cellular. Show last verified time, not a permanent green badge. Screens also recommends testing remote connectivity before leaving and provides an explicit keep-awake option. [Screens remote setup](https://help.edovia.com/en/screens-5/connecting-anywhere/screens-connect-in-screens).

Lock, display sleep, system sleep, logout and restart are distinct test cases. Revisit locked-host access before public release; do not solve it by silently disabling Mac security or promising that the native capture prototype handles login-window sessions.

## Proposed first experience

1. Pair beside the Mac once, with explicit host approval and revocable trust.
2. Open PocketDesk away from home and choose the saved Mac.
3. See a real fresh picture with the current input permission state.
4. Complete one task: inspect a running job, correct a short document, or operate a desktop-only control.
5. Open the normal phone keyboard without losing the viewed area or changing where a tap lands.
6. Switch apps or lock the phone; return through a fresh authenticated session with preserved pairing and no replayed actions.
7. Disconnect with clear confirmation that control has ended.

Test three layouts: live view over a separate trackpad, full-view indirect control, and landscape with a side control area. Preserve the split concept, but let observed task performance decide defaults. A Duo layout should adapt continuously when its actual SDK/device can be tested. Apple's current page still lists Xcode 27.1 beta with Duo support as coming later this month; an iPad simulation cannot validate hinge behavior. [Apple Duo tools](https://developer.apple.com/iphone-duo/).

## Existing implementation: preserve and repair

The source audit found actual native app targets, ScreenCaptureKit capture code, hardware H.264 experiments, native video presentation, controls and bounded binary parsing. Historical receipts match the current source hashes. Nine Mac component tests and seven mostly demo-focused iOS tests passed historically; no new test run was performed in this research phase.

No inspected evidence proves real Mac-to-phone streaming/input, physical iPhone quality, battery, latency or release distribution. Earlier totals of sixteen tests must not be read as sixteen end-to-end checks.

The parent verified the frame gating: `HostStream.swift` sets `busy` until the client acknowledges a frame, and drops new capture submissions meanwhile. Longer network round trips therefore limit frame submission independently of the nominal 60 fps configuration. Redesign bounded streaming and feedback so one acknowledgement does not gate every subsequent frame.

Also address persistent device trust, separate input/video behavior, stale-video input suppression, explicit button/key state, interruption cleanup, authoritative pointer geometry, native text composition, and recovery. The existing encrypted PSK experiment is useful evidence, but does not implement the handoff's proposed persistent QR/pinned trust model.

## Build and validation sequence

1. Preserve a versioned baseline. Resolve connectivity choice, confirm device OS versions and record architecture decisions and dependencies.
2. Establish authenticated pairing, revocation and bounded input authority; reject unpaired clients before screen/input access.
3. Prove a minimal real stream and a click/text action between the physical devices on LAN.
4. Prove the same useful task over cellular and another external Wi-Fi network using the chosen remote path. Exercise relay fallback if part of the product.
5. Compare phone layouts and input accuracy against Screens/Jump on equivalent tasks. Test keyboard, rotations, interruptions and long idle gaps.
6. Record physical latency, energy, network recovery and resource stability. Report results by network condition; healthy-LAN targets do not automatically apply across the internet.
7. Deliver a small external beta, observe unaided setup and repeated use, then decide pricing and scope expansion.

Proposed acceptance includes no wrong-target clicks after keyboard/rotation changes; no duplicated text; no stuck remote keys/buttons; no stale-frame clicks; trusted reconnect without setup repetition; and clear failure when host state is unsupported. Numeric performance targets require an agreed physical test matrix and measurements, not a simulator estimate.

## Research limitations

This was targeted qualitative desk research, not interviews, a representative review sample, a market-size study or a hands-on competitor benchmark. Positive and negative reports conflict and span several years, platforms and releases. No percentage of all users or willingness-to-pay estimate can be inferred. The strongest findings are hypotheses for testing: access reliability, predictable pointer behavior, readable text and correct input.

## Supporting artifacts

- [iOS evidence and original links](ios-user-research.md)
- [Cross-platform evidence and original links](cross-platform-user-research.md)
- [Implementation audit and historical verification boundaries](implementation-audit.md)

The original application source was preserved. Implementation continues in the separate PocketDesk project; no account, network permission or public deployment was changed during research.
