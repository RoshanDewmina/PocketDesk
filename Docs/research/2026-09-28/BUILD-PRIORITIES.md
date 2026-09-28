# Workbench benchmark: prioritized PocketDesk build sequence

28 September 2026. Synthesis of the resumed Claude Code work. PRODUCT.md remains the scope authority. Estimates below are engineering planning ranges, not delivery promises. Workbench's marketing performance is not an independent measurement.

## First finish the current native build

Recover and review the three interrupted packages: phone design, Mac menu-bar companion and streaming diagnostics/performance. The codec-level fault found in synthetic loopback is a concrete first fix; a smooth local loopback still does not establish physical touch-to-visible performance. Preserve signing identity, paired trust, session admission and input release. Keep browser compatibility and older-native fallback explicit.

Current acceptance is a disposable real task on the phone: read, select, edit, save/check, drag/hold/release, scroll/reverse, zoom/Fit and keyboard/rotation. Add Control Center recovery, disconnect during drag and persistent Stop Sharing. Compare identical tasks with Workbench before claiming better feel.

## Prioritized backlog

| Priority | Deliverable | Why first / exit gate | Estimated effort |
|---|---|---|---|
| P0 | Codec compatibility, metrics and physical performance | Hardware path verified on target phone; stable cadence, readable text, no stale input; capture/network/encode/decode/display stages separated | Current continuation + device trials |
| P0 | Owned internet access | Direct cellular and forced relay, revocation and reconnection pass; no Tailscale product dependency | 1–2 weeks after credentials/deployment approval |
| P1 | Gesture coach, zoom indicator, reconnect recovery | Fewer accidental clicks and repeatable task completion | 2–5 days |
| P1 | Authoritative larger pointer | One correct pointer through capture-mode transition, stale telemetry and old-client fallback; captured pointer remains until this works | 1–2 weeks prototype plus device checks |
| P1 | Explicit text clipboard and native dictation | User-initiated transfer, bounded types/size, no duplicate composition; secrets excluded from logs | 3–7 days |
| P1 experiment | Tune hardware H.264; native HEVC comparison | Measured quality/bitrate/latency improvement; actual encoder/decoder support; keep browser H.264 | 1–3 weeks |
| P2 experiment | Dynamic caret/window focus and iPad mini-map | Manual pan wins, geometry is accurate, unsupported apps degrade cleanly | 1–2 weeks |
| P2 | Chat access link and managed needs-user demo | Real authenticated entry; exclusive human/runtime control; no arbitrary GUI-session takeover | 1–3 weeks after connector review |
| P2 | Login/recovery policy, optional PiP | Explicit preference and reliable stop/quit; PiP eligibility and physical lifecycle established | Separate bounded prototypes |
| P3 | Lossless text/UI tile layer | Prove quality defect survives tuned video first; frame generations/cache/resync/expiry tested | 4–8 weeks after video gate |
| Research only | Full custom codec/transport, virtual/unified display, privacy curtain | Public API/distribution route, crash restoration, congestion/security and real performance proof | High uncertainty; not launch prerequisites |

Dependencies matter more than numbering: internet access can proceed beside UI work once deployment is authorized; a custom codec cannot substitute for reachability or a precise input model. Avoid calling privacy curtain, PiP, background persistence or virtual displays “quick wins” until public APIs and restoration behavior are demonstrated.

## Research index

- [Encoder strategy](ENCODER.md): H.264 fault, HEVC and 4:4:4 limits, LIQUID claims, hybrid versus full custom codec.
- [Network/session](NETWORK-AND-SESSION.md): TURN cost scenarios, lifecycle and owned-access gates.
- [Phone UX](PHONE-UX.md): safe-area viewing, dynamic zoom, clipboard/dictation and task study.
- [Mac host](MAC-HOST-FEATURES.md): stop/recovery, login, curtain, pointer and headless boundaries.
- [Agent integration](AGENT-INTEGRATION.md): current code gap, authenticated links and adapter-owned demo.

## Corrections to the earlier benchmark

Relative-trackpad input, no account and proposed pricing are differentiators, not established competitive wins. DTLS-SRTP provides protected media but does not by itself prove identical AES-256 cipher negotiation to Workbench. The previously analyzed recording contains idle periods; its distinct-image rate cannot be treated as sustained motion throughput or end-to-end latency. The current product page advertises 20 free minutes/day and $14.99/month or $79.99/year; other vendor pages can disagree, so record source/date and recheck before spending. [Workbench product page](https://astropad.com/product/workbench/).

The conditional November launch should depend on passing the useful-task, safety and away-access gates. Research completion does not mean these features were implemented. No paid service, public endpoint or store submission was created by this continuation.
