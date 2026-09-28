# Apple API reference and freshness record

Latest focused refresh **28 September 2026**; original capture/transport snapshot **12 September 2026**. This is a focused engineering reference, subordinate to [PRODUCT.md](../PRODUCT.md). It records the relevant material actually inspected, not a claim to have read all Apple documentation or demonstrated runtime compatibility.

## Click-to-keyboard focus refresh — 28 September 2026

Checked Apple ApplicationServices documentation for [system-wide AX access](https://developer.apple.com/documentation/applicationservices/1462095-axuielementcreatesystemwide), [focused UI element](https://developer.apple.com/documentation/applicationservices/kaxfocuseduielementattribute), [position hit testing](https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition), [roles](https://developer.apple.com/documentation/applicationservices/carbon_accessibility/roles), and [messaging timeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout). These support a bounded per-click focused-element check under existing Accessibility permission. AX behavior varies by destination app; role support is not proof of successful detection in every editor or browser. Do not read field text/value. System-wide timeout changes affect the process; serialize/restore if used. AX work must stay off the capture/input main thread. [Observers cannot register on the system-wide element](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification), so the scoped feature uses a one-shot query rather than a broad focus monitor.

## Camera easing refresh — 28 September 2026

For the cursor-follow correction, rechecked Apple’s live [smooth spring animation](https://developer.apple.com/documentation/swiftui/animation/smooth(duration:extrabounce:)) documentation and the SwiftUI section of the [iOS27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes), using the linked Markdown forms. Apple describes smooth as a tunable no-bounce spring; PocketDesk uses0.36s for automatic camera movement and discrete zoom, with Reduce Motion bypass. The app continues to build against SDK27 with iOS26 deployment. This API choice does not measure physical rendering cadence.

[Screen Studio’s animation guide](https://screen.studio/guide/animations) separates fast-settling readable motion from more fluid camera motion. Its homepage demo and guide inform the easing reference; PocketDesk does not copy its private animation algorithm or add postprocessed cursor movement/motion blur.

## Focused interaction and adaptive-layout refresh — 28 September 2026

Follow-up source/SDK review: `NSCursor.currentSystem` is a deprecated public cross-app image/hotspot API; installed `NSCursor.h:155–156` warns it will return nil in a future macOS version. `current` is application-local. This materially strengthens the S0 pointer feasibility gate; no complete replacement visibility/shape contract or runtime support was demonstrated. See the [follow-up research](APPLE-INTERACTION-RESEARCH-2026-09-28.md#follow-up-review-cursor-feasibility-and-native-control-references) for sources, source-format differences and limits. Xcode27.0/27A266a and iPhoneOS SDK27.0 were rechecked. No builds or new native tests ran.

See [Apple interaction research](APPLE-INTERACTION-RESEARCH-2026-09-28.md) for current source links and [native build plan](NATIVE-EXPERIENCE-BUILD-PLAN-2026-09-28.md) for proposed uses. Reviewed current Mac gestures/Force Touch, public double-click timing, scroll phases, UIKit gesture/indirect input, haptics, iPad windowing and official Duo preparation.

- Local command verification: Xcode27.0 build27A266a, iPhoneOS SDK27.0. Device OS and physical performance were not refreshed by this pass.
- [Apple Duo preparation](https://developer.apple.com/videos/play/tech-talks/111461/) documents SDK27.1 full inner-display layout, scene bounds/size classes and asymmetric safe areas. Reserved-region APIs require compatible SDK/runtime gating. No Duo simulator or physical validation was performed here.
- Public [NSEvent.doubleClickInterval](https://developer.apple.com/documentation/appkit/nsevent/doubleclickinterval) exposes host preference; exact private acceleration and gesture heuristics remain unavailable. [Momentum phases](https://developer.apple.com/documentation/appkit/nsevent/momentumphase) describe native scroll semantics, not proof of equivalent injected behavior.
- Haptic feedback depends on device capability. [Apple haptic preparation](https://developer.apple.com/documentation/corehaptics/preparing-your-app-to-play-haptics) identifies unsupported devices including iPad. Local acknowledgement cannot certify remote completion.
- The source audit found cursor included in capture and no separate cursor state contract; public cursor position/visibility/shape feasibility must precede an overlay. SDK symbol presence alone will not pass this test.

The environment table and capture/transport findings below remain dated historical evidence except where explicitly refreshed above.

## Environment verified locally

| Item | Observed |
|---|---|
| Xcode | 27.0, build 27A266a |
| Mac operating system | macOS 27.0, build 26A428 |
| Active Mac SDK | MacOSX27.0.sdk inside `/Applications/Xcode.app` |
| New PocketDesk deployment targets | iOS 26.0 and macOS 26.0 in `project.yml` |
| Simulator build checked | PocketDeskRemote, Debug, booted iOS 27 iPad mini simulator; successful, no native launch |
| WebRTC package | stasel/WebRTC 153.0.0; revision `4266157cd08f92115de885ab12d87196a8db87e1`, verified in Package.resolved |

SDK availability, installed OS behavior, package implementation, and measured device performance are four different kinds of evidence. Building with SDK 27 does not automatically require OS 27; adopting newer symbols requires availability checks or an explicit minimum-OS decision.

## Reviewed sources and implications

| Area | Verified source | PocketDesk implication |
|---|---|---|
| Current platform changes | [macOS 27 RC release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes), relevant Network Security, gesture, TCC, SwiftUI, and VideoToolbox sections; [macOS overview](https://developer.apple.com/macos/whats-new/) | Record concrete changes instead of assuming every new feature improves remote desktop performance |
| Capture | [Apple capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), local `SCStream.h` | Use capture metadata and explicit queue/resolution settings; distinguish complete, idle, blank, suspended, and stopped status. A new received frame is not proof the captured content is current |
| Encoding | [Low-latency VideoToolbox session](https://developer.apple.com/videos/play/wwdc2021/10158/), local `VTCompressionProperties.h` | A dedicated low-latency mode exists; validate its actual use through the WebRTC codec implementation. Preferring H.264 is insufficient evidence |
| Networking alternative | [TN3213 Network migration](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework), revised July 2026; [QUIC.Datagrams](https://developer.apple.com/documentation/network/quic/datagrams) | Native QUIC supports reliable streams and best-effort datagrams. It is a credible measured alternative, not a complete remote-video/NAT/relay stack |
| Sidecar touch | [TN3212](https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support) | macOS 27 documents gesture handling for Sidecar-connected iPads. This does not establish a third-party iPhone touch transport or portrait virtual-display support |
| Existing transport | [WebRTC connectivity](https://webrtc.org/getting-started/peer-connections), [playout-delay design](https://webrtc.googlesource.com/src/+/refs/heads/main/docs/native-code/rtp-hdrext/playout-delay/README.md) | ICE/relay behavior and receiver buffering require tuning and testing. WebRTC is not an Apple framework; upstream documentation must accompany Apple references |

### Specific macOS 27 findings

- The current release notes identify additional VideoToolbox scaling and interpolation capabilities. **Recommendation:** keep these outside the first baseline. They do not themselves prove sharper code text or reduced touch-to-visible delay, and processing must be measured before adoption.
- Network Security changes in the release notes explicitly concern selected system/management processes. Do not generalize that entry into a new universal PocketDesk transport requirement. Valid TLS and authenticated endpoints remain requirements independently.
- TCC release notes say direct access to the local TCC database is no longer available. Permission checks should use supported APIs and normal system settings; database inspection must not become an implementation dependency.
- Gesture behavior and native glass fixes are relevant to interaction tests. Sidecar receiving touch remains a separate capability from injecting input into arbitrary remote Mac apps.

### What the installed SDK establishes

`SCStream.h` declares frame statuses and identifies source rectangles in logical points versus destination rectangles in pixels. Its queue-depth comment currently describes a default of eight and a maximum of eight. The sample explicitly selects five and the prototype explicitly selects three. Use explicit settings and measurements rather than inheriting or guessing a default from older material.

`VTCompressionProperties.h` declares the hardware-required encoder option, the hardware-use query, and the low-latency rate-control option. Hardware-required session creation must fail if hardware encoding is unavailable. The low-latency mode disables frame reordering/lookahead according to the installed header. The current PeerMedia code delegates encoder creation to a default WebRTC factory, so these properties are **not yet verified as active in PocketDesk**.

The current QUIC.Datagrams documentation reports availability beginning with OS 26. The installed `Network.framework/Headers/quic_options.h` also exposes older lower-level datagram APIs. Their existence proves neither faster results than WebRTC nor automatic internet reachability. A custom transport would still need video packetization/reassembly, loss recovery, congestion handling, connection establishment, identity, and a relay strategy. A switch should follow a demonstrated bottleneck and a bounded comparison.

## Retained material

Five official Markdown documents are saved under [References/apple/2026-09-12](References/apple/2026-09-12/README.md): RC release notes, TN3213, capture sample, TN3212, and QUIC.Datagrams. The [manifest](References/apple/2026-09-12/manifest.json) records exact source URL, retrieval time, size, and SHA-256. These are dated source snapshots, not permanently current documentation. Copyright/source notices are preserved.

The web reader could not render the Markdown content type; the snapshots were retrieved with the system's HTTPS client and read locally. Xcode's semantic documentation tool required separate project authorization and was not used; public Apple pages and installed SDK headers supplied the evidence instead. No TLS verification was disabled. No complete offline Apple documentation library was downloaded.

## Future-session freshness procedure

At the start of each PocketDesk task, read PRODUCT, the implementation handoff, and this reference before assuming previous platform facts still apply. Check the current official release-note page and documentation updates for the frameworks being changed. If Xcode/OS versions, relevant documentation, or dependencies changed, update the affected entries and date; preserve historical evidence separately. If online verification is unavailable, label the snapshot as dated and leave new platform claims unverified.

For an API decision, record: exact symbol/source, supported OS range, required permission/entitlement, current code call site, and the test that will demonstrate the intended behavior. Prefer installed SDK declarations for compile-time availability and current official docs for platform guidance; record any disagreement rather than choosing silently. Header declarations do not replace physical acceptance.

Refresh only relevant sections instead of downloading the entire library for every conversation. No recurring background monitor has been configured.

## Still to verify during implementation

- Exact WebRTC binary codec settings, hardware path, receiver buffering controls, security maintenance, and distribution notices.
- CGEvent and Accessibility behavior across actual apps, geometry changes, and secure input contexts, using current relevant symbol documentation at implementation time.
- Current screen-capture permission/entitlement behavior on the supported OS versions; the source review in PRODUCT is not approval for PocketDesk.
- Physical iPhone OS/signing, hardware decoder, thermal behavior, and cellular route.
- A supported commercial path for virtual displays and restoring the user's workspace after disconnect; no public API route is established here.

These are explicit work items, not reasons to substitute assumptions for measurements.

### Implementation refresh, 12 September 2026

The current release-note and capture-sample Markdown endpoints were fetched again with the system HTTPS client; both SHA-256 values matched the retained manifest. Xcode 27.0 (27A266a) and macOS 27.0 (26A428) were rechecked. Python's separate certificate store failed validation; TLS verification was never disabled. WebRTC statistics and relay-policy symbols were checked against the installed pinned framework headers. Native execution and physical capture remain separate gates in the implementation ledger.
