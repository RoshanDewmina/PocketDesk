# Phone redesign receipt — 2026-09-28

The unfinished Claude phone redesign was completed in the existing `agent-ab3a195db8d977833` worktree. The native phone now opens to a quiet home and pairing flow, uses an immersive screen with a reachable glass dock, and offers Fit/Fill plus a separate View/Control gesture mode. Control is the default. View permits local drag, pinch and double-tap zoom without sending pointer or workspace input to the Mac. Three-finger Control swipes and accessible Controls-sheet buttons address Spaces, Mission Control and App Exposé through the existing key route. No transport or protocol change was made for phone UI.

The source work is in `RemotePhone/{CommittedTextField,DesktopPreview,HomeView,NativeSessionView,NativeTrackpadSurface,PairingSheet,PhoneTheme,PointerLocator,RemotePhoneApp,ScannerView,ViewportPreference}.swift`. `RemotePhoneTests/SessionLifecycleTests.swift` and `RemotePhoneUITests/SessionLayoutTests.swift` contain focused lifecycle/layout evidence. Shared gesture/viewport and codec/stream changes are owned by the main integration, not by this receipt. The earlier ringed locator is hidden while the existing cursor-follow and edge reveal behavior remains; no replacement cursor overlay was invented.

Safety: an inactive phone scene immediately cancels held input and shields the picture while preserving the session for a short Control Center interruption. Backgrounding ends the session. Controls-sheet and privacy states block the touch surface and deferred local zoom completion. Switching View/Control cancels held input. Scanner parsing keeps the camera running after malformed codes or a recoverable enrollment failure.

Verification on iPhone 17 simulator with a separate derived-data directory:

- `PocketDeskRemote` simulator build passed: `/tmp/pocketdesk-phone-mode-build.log`.
- `RemotePhoneTests`: 15/15 passed, including lifecycle interruption tests: `/tmp/pocketdesk-phone-all-test.log`.
- Focused landscape Controls zoom reachability passed (54.2 s): `/tmp/pocketdesk-phone-focused-ui.log`.
- Focused exact multiline keyboard draft passed (32.3 s) and View-mode double-tap zoom/return to Control passed (17.0 s): `/tmp/pocketdesk-phone-focused-followup.log`.

An earlier broad UI flow lost one character during high-speed XCTest typing; the focused deliberate-typing check passed without loosening the exact-text assertion. The first View-mode test reached and verified zoom, then failed an off-screen lazy Form query; the corrected focused test passed. These intermediate failures are test automation limits, not claimed product passes.

Curated simulator images are in `outputs/phone-redesign-2026-09-28/`: `home-light-iphone17.png`, `pairing-paste-light-iphone17.png`, `session-fill-hidden-light-iphone17.png`, `session-fill-dock-light-iphone17.png`, and `landscape-controls-zoom-iphone17.png`. The latest View-mode image is exported separately after its screenshot rerun.

Physical gates remain: no direct iPhone touch check of two-/three-finger navigation, Control Center recovery, external Mac display capture, or real pairing/input on hardware. iPhone mirroring was in use during this pass. Simulator layout and shared gesture unit tests do not prove physical gesture feel or end-to-end remote behavior.

Design references checked: [Apple Home](https://mobbin.com/screens/f10cdf0f-4694-4496-9bec-45f3957d784d), [Apple TV](https://mobbin.com/screens/f984918a-ea84-45d4-bc78-09ed3e11b133), [Apple scene phases](https://developer.apple.com/documentation/swiftui/scenephase), and [UIKit safe area insets](https://developer.apple.com/documentation/uikit/uiview/safeareainsets).
