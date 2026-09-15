# PocketDesk

**Start here: [Product and design source of truth](PRODUCT.md), then [implementation record](Docs/IMPLEMENTATION-PLAN.md).** MVP implementation is active. The current pass completes work that does not require the physical phone; real capture/control, cellular, and forced-relay acceptance remain unproven.

The next delivery is a small private feasibility MVP. The handoff uses swarm-orchestrator with efficient GPT workers, no Astra workers/reviewers, and parent-led integration and verification. Broader beta and commercial features remain follow-up scope.

## Browser feasibility implementation

The browser viewer and separate Mac browser enrollment are implemented, with an isolated synthetic native sender and loopback service. Run `./scripts/verify-browser.sh interactive` and `./scripts/verify-browser.sh view` for saved automated receipts. See [browser testing and tonight's physical checks](Docs/BROWSER-TESTING.md) for dependencies, preview commands and boundaries. Native phone pairing remains separate. Public code delivery, real phone capture/control and cellular/TURN are not validated by the local harness.

## Current native MVP

- `./script/build_and_run.sh --verify` builds, verifies the development signature, preserves the previous app, and launches the stable `/Applications/PocketDesk Host.app` copy. `--build` only builds. Neither command grants system permissions.
- `./scripts/verify-remote.sh` runs service tests, Mac/phone simulator builds, and native integration tests. Set `POCKETDESK_RECEIPTS` to a fresh directory to preserve earlier evidence.
- `./scripts/preflight-remote.sh` reports local readiness without changing settings or opening private configuration files.
- [Device test checklist](Docs/DEVICE-TEST-CHECKLIST.md) records the remaining live gates. [Standalone networking](Docs/STANDALONE-NETWORK-READINESS.md) describes the prepared deployment path; Cloudflare account setup is deferred.

Do not launch older host copies from build folders when checking permissions. Successful signing, a visible Settings switch, and real runtime permission are separate checks. The host must enumerate a display and report control permission before a live session can be claimed.

The material below is the preserved earlier prototype README. Its test results and paths describe that historical workspace, not verification of the new remote-access application. Use PRODUCT.md for current scope and status.

## Historical prototype README

**12 September update:** A Mac companion and a real-stream client path have now been implemented. Read the [streaming implementation and current validation boundary](../streaming-mvp/README.md). Transport and codec components have been tested; selected-window streaming and remote control still require end-to-end verification.

The sections below describe the original local demo, built on 11 September with Xcode 27 RC (27A266a) using the iPad mini (A17 Pro) reference simulator. Choose Connect to Mac for the new path.

## Try it

The app is installed as **Pocket Desktop** on **Pocket Desktop — iPad mini** in Device Hub. The live browser preview is at http://localhost:3200 while its local server is running.

1. Drag across the lower trackpad to move the pointer above; tap or use **Click** to select a document in the sidebar.
2. **Right click** opens a small desktop menu. **Centre pointer** brings the cursor back to the middle.
3. Switch to **Keyboard**, clear the sample document and type. Shift, Delete, Return and Command-A work within this local editor.
4. The **AA** menu changes the logical desktop width: Comfortable (800), Balanced (1040), More Space (1280). Comfortable is the default for readability.
5. The arrows beside AA focus the document window. **Unfold / Laptop** switches between a larger desktop and the upper-desktop/lower-controls layout.

In the browser preview, hold a click briefly if an instant click does not register. Automated input worked reliably with a 0.2-second press/release; Apple's UI test runner also activated the controls successfully.

## Build or run again

Open `PocketDesktop.xcodeproj`, choose the **PocketDesktop** scheme and the **Pocket Desktop — iPad mini** destination, then Run. The generated project is included; XcodeGen is only required after changing `project.yml`.

The simulator UDID used for verification is `75FDFB97-27A7-403E-B7E0-0819FB2A8AFD`. It currently uses the previously installed iOS 27 runtime, build `24A5355p`. Physical-device signing is not configured.

## Implementation

- `PocketDesktopView.swift`: controls, manual layouts and observable demo session.
- `DesktopPreview.swift`: scaled desktop, document window, pointer and hit targets.
- `TrackpadSurface.swift`: UIKit one-finger pointer movement, tap and two-finger gesture handlers.
- `PocketDesktopTests/`: five model tests for input and hit-testing edge cases.
- `PocketDesktopUITests/`: an actual launch, keyboard input and layout transition test.

The sample editor is intentionally basic: typing appends text, there is no caret placement or full macOS text editing, and changes disappear when the app restarts. The dock and menu-bar labels are decorative. This local demo does not use networking or remote input. The new connection path is separate; clipboard sharing and persistent storage remain unimplemented.

## Verification and boundaries

**Six tests passed, zero failures.** Additional simulator checks confirmed pointer movement, opening the context menu, focusing the window, changing scale and unfolding. See [verification evidence](../mvp-evidence/verification.md) and the [screenshots](../mvp-evidence/laptop.jpg).

This validates the control concept on an iPad reference surface. It does not validate physical Duo sizing, automatic hinge transitions, Duo reserved regions, real streaming latency, touch ergonomics or two-finger scrolling on hardware. A normal mouse drag verified pointer movement; the two-finger handler still needs physical multitouch testing.

## Next acceptance milestone

Verify the newly implemented live stream from the Mac companion. The companion needs explicit screen-capture permission, a paired connection and remote-input permission. Keep the lower controls native, map pointer positions into the actual streamed viewport, and negotiate a readable host resolution instead of merely enlarging a captured image. Measure text readability and input latency before investing in polish.

When Apple's Duo toolchain is available, replace the manual layout switch with documented arrangement regions and test open/closed/laptop transitions in the actual Duo simulator. See the [Apple API review](../mvp-apple-api-review.md).
