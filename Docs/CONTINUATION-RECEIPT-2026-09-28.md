# PocketDesk continuation receipt — 28 September 2026

Continued Claude Code’s “Codex conversations on Pocket Desk” (`c208998b-b486-4ca8-90bd-fbcc457e7b9b`) from main checkpoint `3410a0a`. The interrupted Claude worktrees were preserved. The user then requested natural phone gestures and delegated the mapping of Mac trackpad actions.

## Delivered behavior

- **Streaming:** native H.264 level 5.2 is advertised only after a bounded, cached hardware decode probe. Older/default receivers receive frames within their negotiated codec budget; browser fixed-pixel freshness markers retain their original capture path. Diagnostics distinguish encoder/decoder reports and renderer callbacks from physical display latency.
- **Phone:** native home/pairing and compact session controls; safe Fit and edge-reachable Fill; a recoverable dock; pointer ring removed; brief inactive interruptions conceal the picture and cancel input while retaining the session. Full backgrounding still ends it.
- **Mac:** menu-bar companion, setup and Settings; local approval and permission gates retained; Stop Sharing persists across restarts; display failures offer retry and “controlling” requires healthy capture. Browser/service implementation details are removed from the routine UI.
- **Gestures:** Control is the default. One finger points, taps click, two fingers scroll/right-click, and double-tap-and-hold drags. Three-finger directional swipes use standard Control+arrow Mac shortcuts. View mode uses one/two-finger pan, combined pinch/pan, and double-tap zoom toward the tapped content; another double-tap returns to Fit. Mode changes cancel held input. A held drag blocks workspace switching. Buttons and accessible actions supplement gestures.

| Gesture | Control | View |
|---|---|---|
| One-finger drag | Move the Mac pointer | Pan the picture |
| Tap / double-tap | Click / double-click | Double-tap zooms, then returns to Fit |
| Two-finger drag | Scroll the Mac | Pan the picture |
| Pinch | Zoom the local picture | Zoom and pan together |
| Two-finger tap | Right-click | No Mac action |
| Double-tap and hold | Drag an item | No Mac action |
| Three-finger left/right | Next/previous Space or full-screen app | No Mac action |
| Three-finger up/down | Mission Control / App Exposé | No Mac action |

These workspace actions use existing keyboard equivalents, not private trackpad-event injection or continuous Space-animation scrubbing. Customized Mac shortcuts can differ. Pressure-based Force Click, universal app rotation/zoom, four-finger system gestures and exact three-finger data detectors are not implemented. See [gesture feasibility](research/2026-09-28/GESTURE-MAP.md).

## Verification

- Xcode 27.0 (27A266a), WebRTC 153.0.0; native deployment targets iOS/macOS 26.
- **141 native core tests, 1 opt-in benchmark skipped, 0 failures.** Covers gesture ownership, cancellation, local pan/pinch/tap, workspace direction/coherence, viewport bounds, admission/freshness, input release, codec compatibility and actual local media. Original 3840×2160 → 1920×1080 quality-change assertion passes.
- **197 service/browser unit tests passed** (710 assertions). **18 interactive browser checks passed**, including Unicode acknowledgements, admission rejection, stale-frame release and reconnect. An earlier run recorded an input rejection and timed out because the synthetic fixture does not acknowledge rejected text; the exact cause was not logged. A clean unchanged rerun passed. No freshness or authentication gate was weakened.
- **15 phone component tests passed** in the author’s redesign worktree, including composition/focus and inactive/background lifecycle. **Three focused phone UI checks passed:** landscape Controls/zoom reachability, View-mode double-tap zoom and return to Control, and exact deliberately typed multiline keyboard entry. A previous broad flow lost one character during automated typing, so that run is retained as failed; high-speed typing is not validated by the slower focused check.
- Host author’s **3 offscreen snapshot checks** produced 34 light/dark images. These are synthetic state renderings. Fresh independent code review found and verified corrections to display recovery, truthful status, sheet input isolation and held-drag workspace switching.
- **Signed Mac and iPhone device builds passed.** Host installed/launched through the required identity-preserving script at `/Applications/PocketDesk Host.app`; the Settings UI was observed Ready with the existing paired phone and both Screen Recording/Accessibility Allowed. No permission reset occurred. Phone build **20260928.6** installed and launched on the paired iPhone 17, preserving stored trust.

### Local streaming measurements

| Synthetic source | Negotiated level / implementation | Encoded / sent / decoded median fps |
|---|---|---|
| 2940×1912 | H.264 5.2 / VideoToolbox | 60 / 60 / 60 |
| 1920×1248 | H.264 5.2 / VideoToolbox | 60 / 60 / 57 |
| 1920×1248 → default receiver at 720×468 | H.264 3.1 / VideoToolbox | 58.8 / 58.8 / 59 |

The first two use 8-second measurement windows; compatibility uses 6 seconds. Claude’s baseline fell back to software VP8 at 3–4 fps. These are same-Mac diagnostic loopbacks with synthetic content, not controlled Workbench comparisons, readable-text scores, physical iPhone throughput or end-to-end latency. Detailed metrics and qualifications are in [encoder research](research/2026-09-28/ENCODER.md).

## Research and next gates

Completed encoder, network/session, phone UX, Mac host and agent-integration reports, plus a [prioritized build sequence](research/2026-09-28/BUILD-PRIORITIES.md). Preserve the hardware video path and measure a useful physical task before considering HEVC or a text/tile layer. A full custom codec is research, not the next launch prerequisite. Chat/agent access routes remain unmounted/unimplemented as described in the integration report.

Physical edit/save/check, pointer and haptic feel, Control Center recovery, actual three-finger routing and iOS gesture conflicts still need a device trial. iPhone Mirroring reported “iPhone in Use” during this continuation; no physical gesture pass is claimed. Cellular/forced relay, iPad/Duo, authoritative larger pointer, dynamic caret zoom and Workbench parity remain open. No public endpoint, paid service or store submission was created.

Engineering receipts remain in repository `work/continuation/`; source and docs are the durable handoff. App install success, local tests and physical acceptance are separate results.
