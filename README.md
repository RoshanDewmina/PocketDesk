# Pocket Desktop — native app

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
