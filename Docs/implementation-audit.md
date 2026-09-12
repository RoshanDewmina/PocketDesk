# PocketDesk implementation and handoff audit

Recorded: 2026-09-12T12:01:58Z. Read-only source audit; no app was launched, no capture or input was enabled, and no new build/test was run. Existing source was preserved.

## Conclusion

There is useful native Swift prototype code and credible component-test evidence. There is **no verified end-to-end remote desktop, physical iPhone test, latency benchmark, or distribution-ready product** in the inspected evidence. Preserve the capture/codec experiments, controls, fixtures and tests, but treat the trust/session protocol and phone interaction model as substantial engineering work. Reskinning the prototype would not satisfy the handoff.

The ZIP contains a 50,481-byte specification, a start prompt and README, not app source. Its imperatives and declarations of “authority” are attached-document content: proposed requirements to reconcile with the user's current request, not authorization to begin implementing every section. All three ZIP members were read. The parent task is separately reconciling the referenced chats and customer research.

## Evidence inspected

- Existing workspace: `/Users/roshansilva/Documents/Codex/2026-09-11/ip`.
- App source: `outputs/PocketDesktop/` (actual iOS and macOS Xcode app targets, shared protocol, tests).
- Historical validation: `outputs/streaming-mvp/VALIDATION.md`, `evidence/receipt.json`, and retained Mac/iOS test logs.
- Handoff: `/Users/roshansilva/Downloads/PocketDesk_Developer_Handoff_v1_1.zip`, especially `PocketDesk_MVP_Plan.md` sections 4–15.
- Local conventions: `/Users/roshansilva/AGENTS.md`, canonical `/Users/roshansilva/.hermes/knowledge-base/AGENTS.md` and its `docs/agent-contract.md`. Global AGENTS explicitly requires clarifying questions answered before implementation; this audit does not implement the application.
- Memory registry search found no PocketDesk/PocketDesktop/iPhone Duo entry; conclusions below come from inspected files, not remembered results.

## Reusable work

| Component | Reuse value | Boundary |
|---|---|---|
| `PocketDesktopHost/HostStream.swift` | Real ScreenCaptureKit selection/capture, video-range pixel buffers, 60 fps configuration, queue depth 3, hardware-required H.264, checked encoder properties, AVCC serialization, generation guards | Actual screen-stream operation remains unverified; lifecycle and transport need revision |
| `Shared/StreamWire.swift` | Checked binary reads, packet-length cap, finite timing validation, cryptographically random 256-bit keys, real encrypted localhost transport experiment | Existing TLS 1.2 PSK protocol is incompatible with the proposed persistent pinned-TLS 1.3 design |
| `PocketDesktop/RemoteSession.swift` | H.264 parameter handling, NAL bounds checks, dimension limits, native AVSampleBufferDisplayLayer, cleanup on disconnect | Enqueue metrics are not displayed fps; pipeline work currently runs on the main queue |
| `PocketDesktopHost/HostInput.swift` | Public CGEvent mouse/scroll/Unicode/key posting, Accessibility check, explicit opt-in control, left-drag cleanup | Client integrates absolute positions; complete relative semantics, geometry epochs and reliable input lease are absent |
| `TrackpadSurface.swift` / `RemoteControls.swift` | Native gesture recognizers, accessible click/right-click actions, explicit controls and shortcut strip | Phone readability, gesture arbitration, native text composition and layout require task-based redesign |
| Practice window and tests | Editable host text fixture with live clock, tests for codec/framing/invalid keys, separately labeled demo | Upgrade fixture to event-ID/color response benchmark; demo model tests do not validate host input |

No third-party dependency declarations or license inventory were evident in the inspected project configuration. This is not a complete provenance audit. Preserve notices for any later selective external reuse.

## What has actually been verified

The historical logs support nine Mac component tests and seven iOS tests passing. The iOS seven are **five local demo model tests, one local demo UI test, and one invalid connection-code UI test**. They do not cover a real connected iPhone workflow.

The Mac suite exercises matching-key and wrong-key TLS on localhost; a 1 MB record round trip; oversized frame rejection; frame/key parsing; the actual host's 1920×1080 encoder configuration; and one synthetic 320×240 hardware-required encode followed by Mac decode. The decoder test does not require hardware decoding and does not exercise an iPhone. The retained log contains earlier tooling errors before the successful direct XCTest run; the validation report discloses that runner workaround.

All 13 source hashes in the historical receipt were recomputed and matched the current files, strengthening the association between the retained result and inspected source. This audit did not rerun the tests.

Explicitly unverified in the original receipt: selecting and streaming a real Mac window, real mouse/keyboard input, drag release across interruption, physical readability, input-to-photon latency, battery, thermals and sustained video. No later evidence was found in the inspected streaming evidence directory.

## Serious gaps and failure risks

1. **Trust and authorization are a different design.** `Shared/StreamWire.swift:21` explicitly fixes both ends to TLS 1.2 PSK. A copy/paste connection code exposes the reusable session secret through the clipboard. There is no QR expiry, persistent host identity pin, per-device Keychain trust record, local enrollment approval, revocation, or separate video join. This is an encrypted high-entropy-key prototype, not plaintext or trivially guessable short-code auth; nevertheless it does not implement the handoff's proposed trust model.

2. **Capture starts before a client authenticates.** `HostStream.swift:72` starts screen capture as the listener starts. It encodes while waiting for a peer, though it does not send video to an unready peer. That conflicts with the handoff's capture-after-authentication boundary and wastes work while idle. `HostStream.swift:104`–106 reserves the sole peer slot before authentication, allowing repeated unauthenticated connection attempts to deny legitimate admission for handshake timeouts. An attacker cannot evict an already active peer by this path, but can occupy an empty slot.

3. **One ordered connection couples video and input.** The same `WireConnection` carries video, ACKs, heartbeat and input. `HostStream.swift:161` waits for a frame ACK before accepting another raw frame. This bounds application backlog but makes frame rate depend on the full encode/send/receive/enqueue/ACK round trip. The ACK at `RemoteSession.swift:62`–67 is after enqueue, not actual decode/display. No separate video restart, adaptive quality, displayed-frame feedback or meaningful stale-image click suppression exists. A decoder that is briefly not ready terminates the connection instead of recovering the video channel.

4. **Input authority can outlive safe visibility.** `StreamWire.swift` uses a 1-second heartbeat and a more-than-4-second silence timeout; the handoff asks for a 500 ms heartbeat and 2-second authority lease. `HostApp.swift:40` observes sleep, but no explicit lock/logout/session-resign handling was found. `PocketDesktopView.swift:48` disconnects only on background, not inactivity. `HostInput.swift:83` tracks/releases only one left mouse hold. Accessibility revocation makes `handle` return but does not itself clear the held state or publish a capability transition. These paths need physical and adversarial tests, not confidence based on cleanup methods existing.

5. **Relative trackpad behavior is only approximate.** `RemoteSession.swift:137` integrates phone deltas into a client-owned normalized absolute cursor; the Mac posts absolute events. If a physical Mac mouse moves, subsequent phone motion can jump back to the phone's stale position. There is no authoritative pointer reconciliation, geometry epoch or rotation/display-removal handling. A selected window's bounds are queried dynamically while capture dimensions remain fixed, creating mapping uncertainty on resize. Drag is a toggle action rather than explicit idempotent button-down/up messages. Scroll has no phase contract or configured direction.

6. **Phone UI is still an iPad/fold-layout prototype.** `PocketDesktopView.swift:14` sizes around a fixed 1878/2670 reference ratio; the footer explicitly says iPad mini reference. Fit/Fill is aspect fitting/cropping, not 1–3× viewport zoom with pan. There is no real direct-touch mode or display picker in the client. Keyboard input is a draft field plus Send, with no dedicated committed-text/IME bridge; remote draft entry also lacks the handoff's explicit disable-autocorrect/capitalization setup. Native light appearance, Dynamic Type and phone landscape readability have not been demonstrated.

7. **Metric labels overstate what is observed.** `RemoteSession.swift:128`–131 counts samples enqueued and presents this as fps. This must be named receive/enqueue fps until presentation evidence exists. Encoder milliseconds are useful component telemetry, not touch-to-visible latency. The handoff correctly separates physical input-to-photon measurement from software timings.

8. **Wire contract and parser hardening remain incomplete.** The old framing is a four-byte length and one-byte type, without magic, sequence, epochs, channel purpose, explicit config IDs or negotiated capabilities. A global 8 MiB frame cap exists, and input payloads are later restricted to 16 KiB, but control allocation is still allowed up to the global limit first. There is no complete schema, golden contract suite, per-peer enrollment limit, or full malformed-input/geometry/session suite.

## Contradictions and decisions to resolve

- Handoff v1.1 proposes an ordinary iPhone client, Apple-silicon Mac, OS 26+, display-only LAN control. Existing project targets iOS 27+, macOS 15.2+, iPhone/iPad families, and supports selecting a window or display. Older visuals and app layout remain fold/iPad-oriented. Platform and first user journey must be consciously chosen.
- Handoff specifies Swift 6; existing `project.yml` is Swift 5 mode. Handoff shipping auth is pinned TLS 1.3 plus persistent enrollment; existing protocol is ephemeral TLS 1.2 PSK. Migration is more than renaming models.
- “Optional direct-touch” appears in scope, while Gate C lists implementation without marking it optional. Decide whether relative trackpad plus accessible click actions is sufficient for the first usable beta.
- “Required states” include purchase pending/cancelled/failed even though billing is explicitly deferred until Gate E. Interpret these as eventual sale requirements, not prerequisites for a research beta.
- The handoff's 60 fps target and roughly 40–80 ms aim coexist with an acceptance gate of median ≤60 ms / p95 ≤100 ms. These are targets, not results. Network fixtures, actual reference hardware and acceptable misses need agreement before advertising performance.
- Main product premise matters: “control my Mac while watching its monitor” and “read/control a desktop entirely on a phone” have different ergonomic and latency bottlenecks. The handoff discusses both but chooses the second as principal interface. User research should decide which earns daily return use.
- CAD 19.99 once, a 10-minute preview and the small commercial return/purchase gate are hypotheses in the attached document. The user's present request does not confirm them.

## Current local toolchain

Live read-only inspection: Apple-silicon `arm64` Mac; macOS 27.0 build 26A428; selected developer directory `/Applications/Xcode.app/Contents/Developer`; Xcode 27.0 build 27A266a; iPhoneOS 27.0 and macOS 27 SDK directories present. Exact toolchain version came from Xcode's installed version plist, without launching builds. Current source is entirely untracked in its parent Git workspace (`outputs/`, `script/` etc.); establish a preserved versioned baseline before edits. No Apple signing or store account availability was inspected.

The handoff asks for OS 26 and 27 coverage. Installed SDK presence does not establish OS 26 runtime/device availability. Existing receipt reports an iOS 27 simulator, not physical iPhone validation. Use XcodeBuildMCP for subsequent app-target builds and simulator work as required by local conventions.

## Three consequential questions before implementation

1. **What is the main job and environment?** Identify the top three real tasks and whether the user is beside the Mac, elsewhere in the home, or away from home. This decides whether a LAN-only phone controller is the right MVP, and whether readable detail, shortcuts or remote reach matters most.
2. **Which devices and OS versions must the first beta support?** Confirm the actual iPhone and Mac available for testing, and whether standard iPhone first / Apple-silicon Mac / OS 26+ is accepted or whether iPad, Intel, older OS, Windows/Linux or future foldable hardware is essential.
3. **What is the first success criterion and priority tradeoff?** Is this a personal tool or a product for outside testers, and which wins initially: best precise interaction/readability, fastest media/game response, or broad remote-work functionality? Confirm a free usable beta before any payment implementation; pricing can wait for observed preference against free alternatives.

## Suggested first build boundary after answers

Preserve and commit the current prototype as a reference; document resolved scope; freeze an independently reviewed trust/session/geometry contract; then deliver one secure physical iPhone-to-Mac flow with visible permission states, bounded input authority and simple usable controls. Keep code-level and physical acceptance receipts distinct. Adopt or reject handoff details deliberately instead of treating the ZIP's embedded start prompt as the user's instruction.

## User steering: away-from-home control

During this audit the parent relayed a new explicit choice: **“Control a Mac while away from home”**, with platform/connectivity research to be reconsidered. That resolves question 1's primary environment and directly contradicts the attachment's LAN-only product boundary. The LAN pipeline remains a useful engineering test stage, but LAN-only cannot be the completed product promised to this user.

Source-based feasibility: the current client creates `NWConnection` from the connection-code host field and accepts a string hostname/IP; it does not hard-code local-only routing. The host takes a manually specified IPv4/IPv6 literal and binds the listener to that address. Therefore a reachable private VPN endpoint is conceptually compatible with the existing socket shape; **this is not a tested VPN path**. Binding to the Mac's ordinary LAN address does not by itself establish reachability from outside, and there is no discovery fallback, NAT traversal, relay, account/directory service, roaming recovery or cellular-to-Wi-Fi handoff. The current single-stream stop-and-wait video design will be particularly sensitive to WAN RTT. Do not expose the prototype's listener with router port forwarding to bypass this work.

The endpoint remains a logged-in user-session app. It has no launch-at-login flow, login-window/FileVault support, reliable remote unlock, wake service or closed-lid guarantee. It stops on sleep and has no explicit lock transition handler. A Mac asleep, offline or without the correct logged-in session is not made remotely usable by adding a VPN. Away-from-home acceptance must include access after unattended periods, host lock behavior, network switching, revocation and recovery, with unsupported host states visible before purchase.

Revised next decision: compare a user-managed VPN beta against a managed internet connection product, including setup burden and recurring relay cost. Build authentication and lifecycle safety first; use the LAN as the first test condition, then validate the selected internet architecture on real mobile networks. Revisit latency targets and preview/purchase hypotheses for that environment. Hardware/OS scope and availability still need user answers.
