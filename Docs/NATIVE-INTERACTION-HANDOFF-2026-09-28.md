# PocketDesk implementation handoff

Prepared 28 September 2026. This prompt is for the next coding job. The current conversation authorizes research and planning only. Execute when Roshan hands this off with an instruction to implement.

---

Continue the existing PocketDesk native app in `/Users/roshansilva/Documents/ChatGPT/Saas/PocketDesk`. Implement the first native interaction milestone, S0–S3 in `Docs/NATIVE-EXPERIENCE-BUILD-PLAN-2026-09-28.md`, then stop for a physical acceptance report. Do not rebuild the app or transport from scratch. The goal is a clear, unobstructed desktop with a readable pointer and a precise, satisfying trackpad experience on Roshan's iPhone.

## Recover and preserve

Read AGENTS.md, PRODUCT.md, Docs/IMPLEMENTATION-PLAN.md, Docs/APPLE-API-REFERENCE.md, Docs/MAC-PERMISSION-IDENTITY.md, the new build plan and `Docs/APPLE-INTERACTION-RESEARCH-2026-09-28.md`. PRODUCT owns scope. Latest user decisions supersede old floating-pad and browser-first proposals. Preserve browser/MCP functionality and all dirty/untracked work; do not assume a fresh default-branch worktree contains the current app.

The 28 September physical receipt shows the native app installed/paired and displaying Mac video with Control enabled. It does not prove native editing, physical latency, cellular or relay performance. Services and private test routes are temporary; inspect live state without modifying unrelated routes. Do not reset trust, permissions or signing identities. Host updates go through `script/build_and_run.sh`.

Use the Build iOS Apps plugin's relevant UI, debugging and performance skills. Retain the native interpretation of Paperwash: warm surfaces, restrained semantic colors, functional system typography, sparse glass for controls. The HTML lab at `/Users/roshansilva/Documents/Codex/2026-09-28/we/outputs/pocketdesk-interaction-lab/index.html` is an interaction reference, not implementation code or proof of native behavior. Previous Mobbin references are recorded in `pocketdesk-design-exploration.md` in that outputs folder; use actual reference images if further design comparison is necessary.

## S0: current baseline and shared contracts

Record current branch/working changes, installed toolchain, target minimums and available devices. Run relevant existing checks and build the affected native targets. Record failures honestly. Capture a harmless native remote-control task if possible; if device access is unavailable, continue independent work but leave physical gates pending.

Inspect `RemotePhone/RemotePhoneApp.swift`, `PocketDesktop/TrackpadSurface.swift`, `RemoteHost/RemoteCapture.swift`, `RemoteHost/RemoteInputDriver.swift`, `RemoteHost/RemoteHostApp.swift`, `RemoteShared/ControlProtocol.swift`, `RemoteShared/PeerMedia.swift` and existing behavior tests. The trackpad surface is shared with an older target, which must keep working.

Parent owns the contract: selected display origin/logical size, encoded size/content rect/scale, host geometry epoch, separate client transform revision, cursor sequence/freshness/visibility/hotspot/composition capabilities, semantic click sequence, active drag identity/renewal and scroll generation/expiry. Freeze these before parallel edits. Use supported public APIs and check exact availability; do not guess a cross-app cursor-image API.

Complete the build plan's S0 decision table and minimum event traces first. `NSCursor.currentSystem` is public but deprecated; the installed 27.0 header warns of future nil results, and `NSCursor.current` is application-local. Resolve position, visibility, hotspot and composition feasibility before promising S2. If unresolved, continue independent S1/S3 work with the captured cursor and explicitly leave the larger-pointer gate incomplete. Record queue age/size and remote stopping budgets before tuning. Raw client/host monotonic times are not directly comparable; fresh arrival is not proof a queued action or renewal is fresh.

## S1: the streamed desktop is the trackpad

Remove the large central trackpad overlay from the default experience. Whole-canvas finger motion moves the existing pointer relatively; lifting/repositioning causes no jump. Keep compact, recoverable native controls for keyboard, Fit/zoom, Pan view, secondary/double click, Drag/Release and End. Chrome consumes its own input and never leaks remote actions. Preserve truthful control/view-only/stale states.

Use the build plan's state table: retained Controls affordance, no canvas tap-to-reveal, explicit Pan view/Done, and a reserved always-visible Release slot during holds. Define an accessible command-based drag separately from the physical gesture hold: it cannot truthfully depend on a finger remaining down. Do not enable it until visible engagement, bounded renewal and cancellation are specified and tested.

Extract a dedicated viewport transform and input arbiter rather than stacking unrelated SwiftUI gestures. Pinch zoom anchors at its midpoint; pan is bounded. Two-finger translation scrolls the remote app, pinch zooms locally, and explicit Pan view moves the viewport. A second finger invalidates pending primary taps. Gesture identity remains stable after recognition until end/cancel. No click on pinch release, canceled motion, background or resize.

First completed tap sends an ordinary click promptly. The next touch has an explicit second-touch candidate before any remote down. Validate ordinary double-click, Finder dragging and double-click-and-drag word selection before finalizing count policy; keep down/move/up consistent, no extra click. Current host arrival-time counting across buttons/positions needs correction. Delayed singles must not become a double-click when delivered together.

Use release-to-drop first and retain a visible Release alternative. Current two-second drag lease renews only on movement, so add bounded authenticated renewal tied to the actual held gesture/session/epoch for stationary holds. Generic heartbeat must not preserve a forgotten drag. Stop renewals on cancellation, stale state, background or authority loss; reject late old-hold messages and keep host expiry/release-all.

## S2: one readable and accurate pointer

Capture currently burns the cursor into video. Implement negotiated authoritative cursor telemetry before drawing a second pointer. Disable captured cursor only for a capable client session with verified telemetry; preserve old/browser client fallback. Never change the user's global cursor setting or globally hide the Mac cursor.

Coordinate overlay enable/fallback with a confirmed video composition boundary; old buffered frames must not duplicate or erase the pointer. Suspend input during an untrusted transition. Isolate capture mode per compatible stream, or keep captured cursor when peers share an incompatible stream.

Keep the overlay at a readable constant screen size with contrast and precise hotspot. The lab's 34×46 CSS pixels is a visual starting reference, not a fixed native requirement. Verify source scale, aspect-fit bars, negative display origins, local host mouse movement, cursor visibility and stale metadata. Captured-cursor fallback is usable but does not pass the larger-pointer feature; report the gap rather than faking it.

Preserve normalized source focal anchor and zoom intention through rotation, keyboard and window changes. Cancel/release active input safely before invalidating the old transform; distinguish client layout revision from host geometry epoch. Add optional bounded edge-follow only after cursor correctness. Manual pan wins, scrolling does not trigger follow, and default follow pauses during drag until tested. Do not add prediction in this milestone.

## S3: tune native trackpad feel

Replace fixed 1.6× gain with a measured bounded velocity curve: slow precise motion, fast travel, fractional accumulation, no pointer inertia or decorative smoothing. Use elapsed time, explicitly define zoom sensitivity and avoid gain changes during a gesture. Compare two or three tuning variants on the physical phone rather than building a giant settings page.

Preserve fractional scroll deltas and continuous/discrete distinction, apply natural direction once, and give momentum one owner. Prototype supported phase-aware injection across Finder, Safari, editor and spreadsheet. Stop local generation on cancellation/new input; bound queued age and use host scroll generation/expiry to reject stale tails. A reliable channel cannot promise instantaneous remote cancellation during congestion. Do not simply drop relative motion deltas or send them latest-wins: position and click ordering must remain correct. Coalescing cannot cross click/key/release barriers.

Preserve path order across direction reversals and clipping, especially while dragging; equal summed displacement does not guarantee equivalent behavior at display edges. Expire stale motion and dependent clicks coherently, requiring fresh input instead of applying a click after its motion prefix was dropped. Delayed renewals must not revive ended holds or extend a hold based only on receipt time.

Play one prepared light native haptic only after a gesture is locally accepted in an active control session. Return send/admission status instead of discarding it. Feedback confirms acceptance, not remote completion. No haptic for view-only, stale or disconnected commands. Provide Off and visual fallback; no Force Touch pressure emulation or iPad device-haptic promise.

Keep native text composition separate from keys/modifiers. No duplicated text or premature IME commits. Preserve task visibility above keyboard and compact Escape/Tab/arrows/modifier controls. Hardware pointer and full iPad keyboard breadth belong to S4, but interfaces must distinguish direct/indirect input now.

## Architecture, delegation and scope

Keep video/cursor update frequency isolated from SwiftUI chrome. Retain bounded resources, authentication, replay protection, host consent, fresh video gates and cleanup. New cursor/input protocol changes need a fresh independent safety review.

Use bounded native subagents with disjoint write sets per repository routing; do not put several agents in RemotePhoneApp.swift or shared protocol files. Parent integrates, owns target membership/project generation and reviews actual evidence. Honor the existing no-Astra worker/reviewer preference and recheck available models. Each implementer owns meaningful behavior tests, not decorative snapshots alone.

Maintain iOS/macOS26 compatibility. Installed SDK was27.0 on the planning date. iPad and Duo should shape interfaces, but S4–S6 are follow-on jobs: Duo27.1 toolchain/layout validation, hardware peripherals, production signaling/relay, billing, distribution and App Store work. Do not install/replace toolchains, buy services, expose public endpoints, publish or submit as an incidental UI change. No virtual displays, AI takeover, audio/files/clipboard sync, login/FileVault or closed-lid guarantees.

## Acceptance and delivery

Add focused tests for transform/inverse/clamp, anchor preservation, gesture state traces, click ordering/counts under delayed transport, stationary drag renewal, exactly-once release, cursor epoch/freshness/composition and stale momentum. Preserve old native/browser compatibility. Build affected targets and run relevant checks; fix actual regressions without destructive cleanup.

On a physical iPhone: small-target acquisition, tap/double/right click, text selection, disposable drag with stationary hold, interrupted drag, scroll stopping/reversal, pinch/pan/Fit, typing and keyboard/rotation. Test light/dark, contrast, accessible native controls, Reduce Motion/Transparency, control rejection and no double cursor. Record which cases passed, failed or were unavailable. Simulator and iPhone Mirroring cannot validate tactile feel or physical end-to-end latency.

Measure local input/cue timing separately from host injection and remote visible change. Log route/device/network/sample size. Use the existing build plan's predeclared performance methodology; do not turn ping, local cursor animation or a render callback into a latency claim. S0–S3 can be delivered as physically unvalidated if access is unavailable, but cannot be called native-feel accepted.

Update PRODUCT and implementation ledger with implemented/proposed/untested status. Deliver reviewable code, fresh review findings/resolution, build/test results, native screenshots without credentials, physical tuning observations and the next smallest task. Stop at the S0–S3 acceptance report; do not automatically execute the release roadmap.
