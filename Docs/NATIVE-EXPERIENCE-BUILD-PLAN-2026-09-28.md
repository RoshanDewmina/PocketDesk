# PocketDesk native experience build plan

Prepared 28 September 2026. Planning and research only; no native application changes or new performance tests in this pass. This is a reviewable execution plan subordinate to the repository's PRODUCT.md. Current user decisions take precedence over older prototype and browser-first proposals.

Refined in the follow-up review with inspected Mobbin references, installed SDK cursor declarations, explicit S0 feasibility decisions, control recovery states and transport correctness cases. All new implementation details remain proposals; no acceptance gate has been passed by writing this plan.

## The result we are building

Open your Mac, see your work clearly, and control it confidently from an iPhone or iPad. The streamed desktop itself is the relative trackpad. A large, accurate pointer remains readable at every zoom level. Controls take little space and remain easy to recover. Movement, scrolling, clicks and dragging should feel predictable and satisfying.

The phone is a movable viewport onto the desktop. Mac applications retain their layout. Local zoom/pan, remote pointer movement and scrolling inside a Mac application are separate actions.

Confirmed direction: native Apple-platform interface with restrained Paperwash warmth; full-screen relative trackpad; larger pointer; click haptics where supported; portrait and landscape; plan for iPad and Duo. Exact gesture timing, acceleration, tablet layouts and release dates below are proposed implementation choices to validate.

## What we actually have

The 28 September physical receipt establishes an installed iPhone 17 app, pairing, changing Mac video and enabled control permission. It does not establish completed native remote editing, physical latency, sustained comfort, cellular or forced-relay acceptance. Older browser and synthetic test results remain separate evidence.

Read-only source audit found:

| Existing foundation | Gap relevant to this redesign |
| --- | --- |
| SwiftUI native session, Metal WebRTC video, pairing and permissions | Large overlay controls still obstruct the desktop |
| UIKit relative trackpad, tap/right-click, two-finger scroll | Fixed 1.6× motion multiplier; no measured acceleration tuning, native pinch arbiter or click haptics |
| Host CGEvent input, drag lease and input cleanup | Fractional scrolling is truncated; phase/momentum behavior needs work and physical verification |
| Fit, 1–3× zoom slider and ScrollView panning | Explicit unified viewport mapping and midpoint pinch anchoring needed |
| ScreenCaptureKit capture with cursor included | No authoritative cursor telemetry for a separate large pointer; adding an overlay now would duplicate the cursor |
| Reliable ordered WebRTC control channel | Motion can queue under loss; blindly dropping relative deltas would change the target position |
| iPhone and iPad target families | Device-family support is not proof of a good tablet/hardware-input experience |

Installed toolchain rechecked in this pass: Xcode 27.0, build 27A266a, iPhoneOS SDK 27.0. Remote targets currently deploy to iOS/macOS 26. Keep that compatibility until an explicit decision changes it. Preserve existing dirty browser/server/MCP changes and older prototype targets.

## Apple platform decisions

Use stable tools for the ordinary phone build and a separate compatible research toolchain for Duo. Apple documents full inner-display use when built with iOS 27.1 SDK; use Device Hub to test folding and resizing. This is distinct from raising the app's minimum OS. Gate newer APIs and keep fallback layouts. [Apple Duo preparation](https://developer.apple.com/videos/play/tech-talks/111461/)

For release, verify App Store acceptance of the chosen stable 27.1-or-later toolchain. If unavailable by submission, ship only a tested compatible fallback and label full-screen Duo support pending; do not submit an unsupported beta build or claim simulator coverage from the installed 27.0 SDK. Physical Duo validation is a separate gate for advertising device-specific optimization.

Use actual view/scene bounds and size classes, with each safe-area edge handled independently. Do not derive layout from model name, screen pixels or forced orientation. Duo's reserved-region APIs are candidates for avoiding camera/fold/system controls; verify signatures and availability in the installed 27.1 SDK. Keep a single session alive across layout changes. [Duo developer resources](https://developer.apple.com/iphone-duo/)

Canvas hit testing must exclude active occlusions and system-owned regions, not just move buttons around them. Verify the remote target and focal anchor remain reachable when the usable canvas changes; use a contiguous viewport when a fold interrupts comfortable interaction.

The SDK 27 scene-lifecycle requirement should be verified in the actual target before upgrading. [UIKit lifecycle](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle)

## Trackpad experience specification

Apple's Mac conventions are the reference, including configurable tracking, secondary click, natural scrolling and dragging. The implementation must account for a touchscreen that also displays the remote content. [Mac gestures](https://support.apple.com/en-us/102482), [Mac trackpad settings](https://support.apple.com/en-gb/guide/mac-help/mchlp1226/mac)

| Interaction | Proposed behavior | Non-negotiable behavior |
| --- | --- | --- |
| One-finger slide | Relative pointer movement | Re-touch never teleports the cursor; lifting stops motion immediately |
| Stationary one-finger tap | Click at the pointer, with light local feedback | No click merely from touching down or ending a move/pinch |
| Two quick taps | Normal remote double-click | First click remains prompt; second is a correctly counted click, without an extra synthesized single |
| Tap, then hold/move the second touch | Drag; release to drop | Explicit down/drag/up lifecycle; visible Release alternative always available while held |
| Stationary two-finger tap | Secondary click | Uneven finger arrival/removal cannot leak a primary click |
| Two-finger translation | Scroll the remote application, including horizontal/diagonal movement | Pointer stays still; no viewport pan or accidental pinch at the same time |
| Pinch | Local viewport zoom anchored under the fingers | Does not also scroll or zoom the remote app |
| Pan view control | Temporary local viewport movement mode | Obvious state and exit; usable without complex gestures |
| Fit | Full selected desktop | Never assigned to ordinary remote double-click |
| Optional edge-follow | Reveal desktop beyond the visible edge | Only with fresh cursor geometry; stop on motion stop, manual pan, scrolling or unavailable input |

### Movement that feels attached to the finger

Start with a continuous, bounded velocity-dependent gain curve: slow movement gives accurate character/target placement; faster sweeps cross the desktop without repeated lifting. Measure velocity using elapsed time and view-space points so callback frequency does not change sensitivity. Preserve fractional displacement. No pointer inertia, bounce, spring animation, target snapping or smoothing that trails behind a stopped finger.

Define the scale policy explicitly: proposed default keeps perceived screen-space travel broadly stable across local zoom, mapping back through the viewport transform. Compare against constant host-space gain on a real phone before freezing it. Freeze sensitivity, scale policy and curve parameters for a gesture; instantaneous gain still varies continuously with velocity. One user-facing sensitivity setting is enough initially; keep tuning parameters in development diagnostics.

Physical mouse/trackpad events use a distinct path. UIKit pointer positions are already processed; do not apply touchscreen acceleration again. Raw GCMouse deltas, if used later, require their own single gain owner. [GCMouseInput](https://developer.apple.com/documentation/gamecontroller/gcmouseinput)

### Click and drag timing

Read the host's public `NSEvent.doubleClickInterval` and use correct click counts and ordering. Do not advertise invented Apple thresholds. A blanket single-tap-waits-for-double-tap recognizer dependency adds avoidable delay to remote mouse clicks. Define the first-click/second-down/second-up sequence explicitly and test selecting text, opening a Finder item and dragging it. [Double-click interval](https://developer.apple.com/documentation/appkit/nsevent/doubleclickinterval), [Recognizer failure dependencies](https://developer.apple.com/documentation/uikit/uigesturerecognizer/require(tofail:))

Define one semantic click-sequence owner. The current host infers click counts from packet arrival times across button/position changes, which is insufficient under congestion. Classify intentional clicks from client interaction timing, then validate bounded sequence/count/order and session/target context on the host. Reset on button change, meaningful target movement or new session. A second-tap drag must express the correct second-down lifecycle. Delayed independent clicks must not become a double-click merely because they arrive together.

Emit the first completed tap promptly. The next touch enters a second-touch candidate, allowing a brief tested disambiguation period for another finger before committing a remote down. A quick stationary release completes a double-click; a hold/move becomes the declared drag sequence. Before down, cancellation emits nothing; after down, cancellation releases exactly once. Verify click-count semantics for Finder object dragging and double-click-and-drag word selection; do not prescribe a universal count that breaks one of them. Down/move/up must agree, with no extra synthesized click.

Initial drag behavior is release-to-drop; defer hidden drag lock. Preserve bounded host lease/release safeguards, but fix stationary holds: the existing two-second lease renews only on movement and can drop a still-held drag. Add authenticated renewal tied to the exact active hold, session and geometry epoch, independent of ordinary heartbeat. Renew only while the physical hold remains active and control/video are valid; stop on cancellation, stale state, background or authority loss. Test a stationary hold beyond two seconds, lost renewal, finger release and late old-hold packets. An interrupted connection can prevent a release packet arriving, so cleanup cannot depend on the phone alone. A remote release may finish an already started drag; it cannot undo work, so use disposable targets during tests.

### Scrolling with weight and predictable stopping

Preserve fractional continuous deltas; distinguish them from discrete wheel steps. Apply natural-scroll direction once. Use one owner for momentum, with explicit begin/change/end/cancel semantics and a bounded tail. For the finger-simulated trackpad, start by evaluating client-owned momentum sent through the existing authenticated input path. Stop it on a new gesture, reversal, mode/context change, stale video or interruption. Do not add custom momentum to hardware events already carrying it.

Stopping local generation cannot instantly cancel remote deltas already queued on a congested reliable channel. Bound queued age/size; define a host-recognized scroll stream/generation and expiry with stale-tail rejection. Cancellation invalidates its generation when received; host expiry covers a missing cancellation. Specify the allowed remote stop delay and test it under congestion. Do not promise instantaneous remote stopping over an interrupted network.

AppKit documents scroll phases and momentum targeting, and Core Graphics exposes phase fields; correct injected behavior still needs a supported-API experiment in Finder, Safari, an editor and a spreadsheet. Do not equate ordinary wheel injection with a complete native trackpad event stream. [Momentum phase](https://developer.apple.com/documentation/appkit/nsevent/momentumphase), [CGEvent phase fields](https://developer.apple.com/documentation/coregraphics/cgeventfield)

### Haptics with a clear meaning

One restrained pulse means the phone accepted the click into an active control session. It does not mean the Mac application completed it. Return a local accepted/rejected result from the input gate before playing feedback. No click pulse in view-only, stale or disconnected state; no continuous vibration while moving or scrolling.

Compare prepared UIKit impact feedback with simple SwiftUI sensory feedback on the physical phone. Provide Off and a visual fallback. Pressure-sensitive Force Click is not part of this feature. Apple trackpads use actual pressure sensors; phone vibration does not add them. iPad device haptics cannot be assumed. [Impact feedback](https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator), [Force Touch](https://support.apple.com/en-us/102309), [Haptic capability](https://developer.apple.com/documentation/corehaptics/preparing-your-app-to-play-haptics)

### Gesture arbitration and accessibility

Use one input controller with mutually exclusive ownership: local chrome, relative pointer, remote scroll, local zoom/pan, hardware pointer or text. A possible tap can become motion; adding a finger invalidates primary-tap candidacy. A recognized scroll/pinch owns its sequence until end/cancel. Changing finger count, opening controls or receiving cancellation cannot synthesize a click.

Essential actions need labeled alternatives: Click, Secondary click, Double-click, Drag/Release, Zoom/Fit and keyboard commands. Respect system edge and multi-finger gestures; do not promise all Mac gestures on iPhone/iPad. Defer Smart Zoom's two-finger double-tap because it conflicts with prompt secondary-click handling. Remote app accessibility semantics are not automatically available from streamed pixels; native controls can be accessible without claiming a full remote VoiceOver bridge. [Gesture HIG](https://developer.apple.com/design/human-interface-guidelines/gestures/)

## Viewport, pointer and keyboard architecture

Keep the existing WebRTC/ScreenCaptureKit pipeline initially. Extract small components from the current monolithic phone view only where needed:

- Session model: authority, connection, stale state, held input and cleanup.
- Viewport state: source bounds, fit scale, zoom, offset, visible rect and inverse mapping.
- Input controller: gesture ownership and accepted local commands.
- Cursor presenter: authoritative geometry, hotspot, readability and composition mode.
- Native chrome and keyboard bridge: low-frequency UI state, committed text and physical keys.

The parent implementer owns protocol changes before parallel UI work starts. Required geometry includes selected-display identity/origin, logical dimensions, encoded dimensions/content rect, scale and host geometry epoch. Maintain a separate local transform revision for phone resize; a client layout change must not invent a new host geometry epoch. Store the viewed focal anchor in normalized source coordinates.

Cursor telemetry needs authoritative source position, freshness/sequence, visibility semantics, precise hotspot and a documented shape strategy. Investigate public capture/position APIs; do not assume a cross-app cursor-image API exists. A documented generic indicator is a fallback, not proof of correct I-beam/resize/busy shape support. If accurate visibility or composition cannot be established, keep captured-cursor mode and report the feature incomplete.

The follow-up research found a specific limitation: public `NSCursor.currentSystem` does describe the cross-app cursor image and hotspot, but Apple marks it deprecated. Installed Xcode 27.0 `NSCursor.h` also warns that it will return nil in a future macOS release. `NSCursor.current` refers to the application's own cursor. Do not mistake either for a durable, complete cross-app telemetry solution. Evaluate alternatives in S0 before scheduling S2 as routine UI work; no supported replacement for the full shape/visibility contract was established in this review. [System cursor](https://developer.apple.com/documentation/appkit/nscursor/currentsystem), [Application cursor](https://developer.apple.com/documentation/appkit/nscursor/current)

Negotiate cursor mode per session. Disable the captured cursor only for a compatible client with working telemetry; restore the legacy path for other clients. Do not globally hide/enlarge the user's Mac cursor. Match telemetry to geometry, bound updates and never drive edge-follow from stale or speculative positions. Client prediction is deferred until correctness and measured response justify it.

Treat composition changes as acknowledged transitions tied to a video frame boundary or another verified stream boundary. Changing `showsCursor` and immediately toggling an overlay can leave buffered frames with two cursors or no cursor. During fallback, invalidate overlay input and display recovery state until the first confirmed captured-cursor frame is presented. Do not change a shared capture stream's cursor mode for incompatible peers; isolate the mode or retain captured-cursor mode for that stream. Keep a compatibility fixture for an older native client and the current browser client.

S2 passes only with a single visible, correctly placed pointer and verified visibility/hotspot behavior. Captured-cursor fallback preserves usability but does not pass the requested larger-pointer feature. ScreenCaptureKit's cursor inclusion setting alone supplies no separate cursor state contract; establish the public-API route before committing to overlay delivery.

Render the larger pointer at constant UI size, starting from the lab's approximate 34×46 reference and adjusting on-device. Maintain a contrasting outline and exact click hotspot. Hide or clearly invalidate an untrustworthy overlay. Test host-local mouse movement and cursor crossing display boundaries.

On rotation, fold, keyboard or window geometry changes: cancel/release active input safely, invalidate the old local transform, preserve session and source anchor, recompute and clamp. Never replay an old tap under a new mapping. During normal edge-follow, scrolling and drag ownership stay explicit; default edge-follow off during drag until selection/drop behavior is validated. Manual pan takes precedence and suspends follow until pointer input deliberately resumes. Control panels never relocate under an active finger.

Use native text composition. Keep committed text separate from key-down/up/modifier events; deduplicate hardware text delivery. Software keyboard, dictation and IME must not send provisional marked text as final characters. Preserve the task region above the keyboard; provide Escape, Tab, arrows and visible modifiers. Clipboard sync is a separate deferred feature. [UITextInput](https://developer.apple.com/documentation/uikit/uitextinput)

## One layout system across devices

| Situation | Experience | Acceptance |
| --- | --- | --- |
| Phone portrait / closed Duo / narrow iPad window | Canvas with compact controls and overflow; zoom for readable work | Thumb reach, readable pointer, safe areas, keyboard space |
| Phone landscape | More desktop width, minimal status/control layer | No giant trackpad or forced landscape; End remains discoverable |
| iPad / open Duo, spacious window | Same canvas; optional collapsible saved-Mac/sidebar and expanded command strip | Extra space improves work, not permanent control clutter |
| Duo partially folded | Safe contiguous task area; optional later tabletop arrangement | No controls/critical targets lost in active reserved regions |
| Hardware keyboard and pointer | Standard native chrome; direct hardware pointer mapping and remote shortcuts | No duplicate cursor/input, correct modifiers, primary/secondary/drag |
| Window resize / supported external iPad display | Same session, remapped viewport | No reconnect or stale coordinate use; no dependence on pointer lock |

For physical pointers, use UIKit indirect input and continuous/discrete scroll support. Pointer lock is optional and revocable, so ordinary windowed operation must work without it. Do not route hardware events through the finger-relative recognizer. [Apple indirect-input guidance](https://developer.apple.com/documentation/technotes/tn3210-optimizing-your-app-for-iphone-mirroring), [Pointer lock](https://developer.apple.com/documentation/uikit/uiviewcontroller/preferspointerlocked)

Pencil precision pointing is a follow-up after the core hardware lane works. Pressure/tilt tablet emulation, custom dual-display Duo experiences, a dedicated external-screen/controller mode and multiple concurrent remote sessions are deferred. These should not delay an excellent phone experience.

## Compact controls with a dependable way back

Proposed default: one small connection/status control and a bottom cluster containing Keyboard, Fit and More. The canvas occupies the remaining surface. More opens native actions for Pan view, secondary/double click, drag, sensitivity, haptics and End session. End takes at most two deliberate activations from the resting state. Release is promoted to an always-visible action while input is held. A collapsed state retains a labeled Controls button: a canvas tap must never double as a chrome-reveal gesture because it already means remote click. A drag on chrome must not move the Mac pointer.

| State | Visible treatment | Input behavior |
| --- | --- | --- |
| Controlling | Compact status and recoverable controls | Relative touch input; remote actions only inside the input canvas |
| View only | Explicit View only label | Local viewing/zoom remains available; remote commands rejected without click haptics |
| Pan view | Persistent Pan view label and Done | One-finger movement changes only the viewport; exit never synthesizes a click |
| Held input | Release stays visible in a reserved control slot | Opening any other panel first cancels/releases the active gesture |
| Keyboard visible | Compact Escape/Tab/arrows/modifiers above keyboard | Preserve the source focal anchor in the remaining canvas; do not send marked text |
| Stale/reconnecting | Clear unavailable state with recovery action and End | Disable remote input, invalidate candidates, stop momentum, release holds; no replay after recovery |

Use at least 44×44 pt proposed hit regions for compact buttons, with larger accessible arrangements when necessary. Visual glyphs may be smaller. Reserve space for Release before a drag begins so controls never move under the active finger. Large text can expand a sheet or strip; it must not make End/Release unreachable. Warm paper or charcoal surfaces and restrained blue/sage/clay accents belong to native chrome; leave streamed pixels unfiltered and keep connection meaning in text as well as color. Use system typography for operational controls. Decorative paper texture, blur and animation must not impair canvas readability.

Mobbin images were inspected in this review. [Freeform's canvas](https://mobbin.com/screens/46af0374-1ad1-4caa-a020-d7753d532f34) separates a small top action cluster from a bottom tool palette; borrow that hierarchy with fewer permanent controls. [Evernote's sketch screen](https://mobbin.com/screens/866d750f-16ce-4ff4-937d-9dc196b88433) makes its editing context and Done action explicit; use that clarity for Pan view. [Google Photos' viewer](https://mobbin.com/screens/f5e491ed-bb44-4648-8aa0-a5d526daa9b4) combines primary bottom actions with top overflow; use the priority split. These static references establish visual organization, not remote-control gesture behavior or usability evidence.

## S0 decisions that make implementation safe to parallelize

| Decision | Required output before dependent implementation |
| --- | --- |
| Cursor feasibility | API/availability record for position, visibility, image/hotspot and capture composition; then a future disposable-app experiment. If unresolved, continue S1/S3 with captured cursor and mark S2 blocked/incomplete; do not substitute a generic arrow and call it done |
| Geometry | One diagram defining global display coordinates, source coordinates, encoded content rectangle and client view points; forward/inverse mappings, origins and rounding. Host epoch and client transform revision remain distinct |
| Gesture ownership | Event traces for primary tap, staggered two-finger tap, pointer motion, scroll, pinch, drag and cancellation; one command/admission owner |
| Protocol compatibility | Capability/version negotiation with old-native/browser fixtures; define rejection of unsupported actions, bounded fields and ordering without weakening existing authenticated sequence checks |
| Expiry and queues | Freeze proposed numeric age/size budgets and allowed remote stop delay before tests; specify host-comparable time or host-issued freshness tokens and conservative expiry. Arrival time alone cannot prove queued input is fresh |
| Accessible dragging | Define gesture-backed holds separately from a visible command-based Drag/Release mode. Gesture renewal requires physical contact; an accessibility action may have no contact. The latter needs explicit engagement, bounded lifetime, visible state and cancellation rules before it is enabled; generic heartbeat cannot keep either alive |

Proposed owner map: the parent defines and integrates changes to `RemoteShared/ControlProtocol.swift` and target membership first. The viewport/input package covers extracted phone components and `PocketDesktop/TrackpadSurface.swift` while preserving its older target. The host/cursor package covers `RemoteHost/RemoteCapture.swift` and `RemoteHost/RemoteInputDriver.swift`. The chrome/keyboard package starts after extraction from `RemotePhone/RemotePhoneApp.swift`. `RemoteShared/PeerMedia.swift` queue changes stay with the parent or one explicitly assigned transport owner. These are future write sets, not edits performed in this review.

### Transport details that must survive congestion

Use the existing authenticated session and packet sequence as the outer boundary. Add bounded semantic identities for click sequence, hold and scroll generation, plus geometry context. Client monotonic intervals classify clicks; the host still validates order, button, count and context. Never compare raw phone and Mac monotonic timestamps as if they shared a clock.

Freshness must cover renewal packets too: delayed renewal of an old hold cannot extend it merely because it just arrived. Keep ended hold/generation identities closed, reject old-session packets and retain local host cleanup even when a cancellation cannot arrive. Reject stale actionable input as a coherent sequence: do not discard a movement prefix and then execute its queued click at a different position. End that input sequence, release if needed and require fresh user input.

Coalescing relative deltas requires more than preserving their sum. At a display edge, +20 then −20 with clamping after each move can end at a different location than one summed zero delta. Preserve reversal/path order where clamping or dragging makes it significant; bounded ordered batches are safer than blind summation. Coalescing must never cross button, click, key, mode, geometry or release boundaries. Diagnose pressure on the reliable channel before proposing a transport rewrite.

### Minimum review traces for S0–S3

These are future tests, not new tests run in this planning pass.

| Trace | Required result |
| --- | --- |
| Move, lift, touch down elsewhere | No teleport and no click; the new touch starts a new delta origin |
| Two independent taps delayed and delivered together | Two independent clicks, not an inferred double-click |
| Second tap candidate, then second finger arrives or controls open | No primary click leakage; any committed down gets one effective release |
| Hold stationary beyond two seconds, then release | Valid hold survives with fresh exact-hold renewals; release ends it; old renewals never resurrect it |
| Edge reversal while moving or dragging | Batching preserves the result and path semantics of ordered input |
| Old movement followed by queued click after congestion/resize | No click at an unintended target and no replay under the new mapping |
| Scroll, new gesture, late momentum packet | Old generation rejected; no retargeted tail in a different app |
| Captured cursor ↔ overlay while old video frames are buffered | No duplicate pointer; input unavailable during an untrusted composition transition |
| Host mouse leaves selected display, or app hides cursor | Overlay visibility matches established semantics; no speculative edge-follow |
| Keyboard/rotation/iPad resize during a hold | Safe release, same session, preserved/clamped focal anchor and no stale tap |

The first useful physical receipt remains one disposable edit/save/check task, plus click/drag/scroll/zoom and interruption cases on the phone. Follow it with the short tuning comparison. Broader thermal, repeated-connection and network matrices belong to later gates; they must not delay learning whether the basic interaction works.

## Build order and concrete gates

| Slice | Deliverable | Gate before moving on |
| --- | --- | --- |
| S0 · baseline and contract | Preserve checkout, record current native task, resolve cursor feasibility and freeze geometry/input/cursor interfaces and test fixtures | Baseline gaps and explicit S0 decisions recorded; cursor delivery supported or marked unresolved before promising S2 |
| S1 · unobstructed interaction | Full-screen relative input, compact chrome, local pinch/pan, click/scroll/drag arbiter | Real phone target/edit test; no phantom click, clutch jump or lost release |
| S2 · visible authoritative pointer | Negotiated cursor mode, large overlay, stable resize/keyboard transforms | One accurate cursor at all tested zoom/display positions; fresh telemetry; old-client fallback |
| S3 · native feel | Motion curve, fractional scroll, tested momentum, accepted-click haptics, basic keyboard improvements | Physical A/B against baseline and Mac trackpad; Roshan judges comfort; correctness suite passes |
| S4 · adaptive devices | iPad windowing/hardware input, Duo SDK/simulator adaptation, accessibility and theme polish | Resize/fold/input matrix; physical iPad; Duo physical status honestly labeled |
| S5 · away reliability | Built-in signaling/relay, route metrics, shaped-network recovery and real cellular use | Useful task off home Wi-Fi without Tailscale; separately forced relay; safe revoke/interruption |
| S6 · release | Installer/updater, onboarding, service operations, entitlements, privacy/support and review package | Release checklist, external tester usefulness and cost evidence; no unresolved blocking failures |

S5 service preparation can proceed independently after shared contracts settle; it cannot substitute for the early on-phone loop. The next coding job should stop after S0–S3 and a physical acceptance report. S4–S6 are the planned follow-on program, not automatic permission to deploy, purchase services or publish.

### Delegation without conflicting edits

Parent owns shared contracts, project generation, dependency versions, integration and final evidence. After extraction, assign disjoint files: viewport/input worker; host/cursor worker; adaptive chrome/keyboard worker. Each owns its behavior tests. Do not place multiple workers in RemotePhoneApp.swift or shared protocol files simultaneously. Use a fresh reviewer for cursor/input safety and protocol changes. Follow the repository's existing permitted-model routing and preserve signing identity through `script/build_and_run.sh`.

## How we will know it feels good

Run a short repeatable physical benchmark with the same Mac content before/after each tuning change: acquire small and large targets, select a word and a line, double-click a file, drag a disposable item, right-click, scroll a long page and stop on a marked line, then work for 20 minutes. Compare the Mac trackpad baseline and phone variants. Record errors, overshoot, repeated finger lifts, accidental clicks, completion time, hand fatigue and Roshan's preference. Do not log personal screen content or typed text in diagnostics.

Test slow/fast and diagonal movement, tiny tap jitter, staggered two-finger arrival, pinch with one finger lifted early, scroll reversal, controls opened mid-gesture, and interrupted drag. Deterministic event traces must produce zero unintended clicks, duplicated events or unreleased buttons. Input must stay at the intended target through zoom, letterboxing, negative-origin displays, rotation and keyboard changes.

Measure separately: touch processing/queue time; local visual/haptic feedback; host receipt/injection; capture/encode/decode/render stages; and physical input-to-visible application response. Render callbacks are not proof of actual panel presentation. Use an external high-frame-rate recording of a harmless visible response for true end-to-end timing, or describe the precise limits of software markers. Do not use iPhone Mirroring or ping as the end-to-end benchmark.

Retain PRODUCT's proposed future budgets: at least 19/20 connections usable within 10 seconds per declared supported condition; physical input-to-visible p95 ≤150 ms on reference LAN and ≤400 ms on the declared relay route, with at least 100 interactions per reported latency condition. These are proposed gates, not measurements and not a definition of satisfying feel. Report p50/p95, sample size and failures; p99 only with enough samples. Threshold changes require a documented reason before rerunning, not silent adjustment after failure.

| Network/test lane | Procedure and evidence |
| --- | --- |
| Healthy and busy home Wi-Fi | Baseline readability, click response, scroll stopping and input ordering |
| Cellular and unrelated Wi-Fi | Complete useful task; log actual selected ICE pair, codec, bitrate, resolution, fps and RTT |
| Forced relay | Enforce relay policy and verify selected relay route at both ends; a tunnel alone does not pass |
| Controlled impairments | Proposed lab profiles: add 50/100 ms RTT, 10/30 ms jitter, 1/3% loss; cap throughput at 2/5/10 Mbps, first separately then realistic combinations; record exact shaper settings and observed network |
| Outage and transition | Brief 1/5-second loss, Wi-Fi↔cellular, background/foreground, revoked authority, sleep/lock; no command replay or stuck hold |
| Sustained use | 30-minute reading/typing/scroll session, plus 50 connection cycles; record thermal state, power, frame pacing, memory trend and crashes |

Do not force 120 fps because a display supports it. Start from actual 30/60 fps results. Isolate rendering from SwiftUI chrome updates; bound queues and coalesce motion without crossing click/key/release barriers. Preserve accepted relative displacement and required path order when batching; stale-sequence cancellation follows the explicit recovery rule above. Do not use naive latest-wins relative movement or double-count UIKit coalesced samples. [Coalesced touch semantics](https://developer.apple.com/documentation/uikit/uievent/coalescedtouches(for:)), [Display pacing](https://developer.apple.com/documentation/quartzcore/cadisplaylink)

## Proposed calendar and release decision

Working public launch target: **Tuesday, 17 November 2026**. This is a planning target, not a guarantee of App Review timing or readiness. Keep it by limiting optional scope, never by hiding failures. Re-estimate after the first native slice; the previously discussed 5–8 hours/week of Roshan's testing time is a planning assumption, not verified delivery capacity.

| Date | Required result |
| --- | --- |
| 29 Sep–4 Oct | Baseline, interfaces and first full-screen native interaction slice |
| 5–11 Oct | Accurate visible pointer and physical trackpad-feel iteration |
| 12–18 Oct | iPad/keyboard/windowing; Duo simulator; public-service readiness preparation |
| 19–25 Oct | Real cellular and relay, external beta, regression/cost checks; physical Duo test if available |
| 26 Oct–1 Nov | Fix beta failures, final scope, entitlements, signed host delivery and support/review materials |
| 2 Nov | Go/no-go on submission; move launch if remote reliability, input safety or distribution fails |
| 3 Nov | Target App Store submission with manual release |
| 4–16 Nov | Review response and release-candidate verification |
| 17 Nov | Launch if approved and gates pass |

Free local / paid internet remains the proposed offer direction from the preceding discussion; exact price and limits should follow measured relay cost and willingness to pay. Do not promise unlimited relaying or pick a lifetime price before usage is known. Record direct-versus-relay hours, GB/session, hosting/support cost and spend caps. Resolve how free-local discovery/authentication works during service outages; do not imply offline independence without testing it. Payments need a separately scoped StoreKit/entitlement and restore/refund/offline-grace design.

Prepare a fresh-install Mac companion, stable signing/notarization and update/rollback route; unaided pairing and permission recovery; host readiness and awake/unlocked copy; service monitoring/revocation/abuse controls; privacy and support pages; accurate device screenshots; review access instructions and a demo arrangement. Keep owner-operated generic desktop access distinct from app-specific streaming. Apple's 4.2.7 has a conditional scope; recheck it and other relevant rules against the final app rather than treating it as a blanket ban on internet desktop access. [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [Submission guidance](https://developer.apple.com/app-store/submitting/)

## Deliberately outside this build

AI takeover/chat integration, virtual/headless displays, locked/FileVault login control, guaranteed wake or closed-lid operation, file transfer/clipboard sync, audio/microphone forwarding, new codecs/transport rewrites, predicted cursor, creative-tablet emulation and multi-controller sessions. Reopen only for a demonstrated user task or measured bottleneck.

## Read with this plan

- [Apple interaction research](APPLE-INTERACTION-RESEARCH-2026-09-28.md): dated Apple sources, trackpad behavior, iPad and Duo findings.
- [Native implementation handoff](NATIVE-INTERACTION-HANDOFF-2026-09-28.md): scoped instructions for the next coding job.
- The interaction lab in the preceding chat's outputs is a visual/interaction experiment; not a live remote client or native-feel validation.
- Repository PRODUCT.md, Docs/IMPLEMENTATION-PLAN.md and Docs/APPLE-API-REFERENCE.md remain the durable product, execution and platform records.

Unresolved until implementation: reliable cursor shape/visibility via public APIs, scroll phase injection fidelity, precise gesture/gain tuning, physical device availability, production relay access/cost, and measured performance. No test is marked passed merely because this plan specifies it.
