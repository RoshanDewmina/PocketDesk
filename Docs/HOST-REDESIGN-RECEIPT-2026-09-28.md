# PocketDesk Host redesign receipt — 28 September 2026

Branch: `worktree-agent-a70f056c626d35b29`. Base checkpoint: `13f26e9`. The interrupted Claude work is committed as `0177e28` (menu bar utility, guided setup, one Settings pane, host model split, readiness tests and offscreen screenshot tests). This continuation preserves that commit and its worktree.

## Result

- The host is a menu bar utility with a first-run setup window and native Settings scene. Its Dock icon appears while an app window is open. The menu identifies ready, viewing, controlling, paused, approval and error states, keeps Stop Sharing and Quit available, and caps item text at 30 characters.
- Setup checks Screen Recording and Accessibility automatically, opens the relevant System Settings panes, and requires local approval of a phone that scans the QR code. The default Allow Control preference still requires Accessibility permission and healthy capture before input is accepted.
- The browser management panel, routine service address field, display IDs, manual permission check buttons, app path and prototype text are absent from the regular Settings surface. A service address entry remains only as a conditional pairing recovery step when no saved or bundled service exists; removing it entirely would make this development build unable to pair a new phone. The underlying browser code remains available.
- This continuation makes Stop Sharing persist across app restarts. A user-initiated pairing or Resume Sharing explicitly enables sharing again. The old default remains on for users who have not stopped sharing, and control remains gated by pairing, permission, capture health and the phone approval protocol.

## Verification

- Xcode 27.0 (`27A266a`), deployment target macOS 26, WebRTC 153.0.0. Unsigned build for `PocketDeskRemoteHost` passed in this worktree's `outputs/HostRedesignBuild` directory. No app installation, restart, signing identity change or permission reset was performed.
- `RemoteCoreTests.xctest`: 105 tests passed. Focused host readiness and permission state tests: 14 passed. `HostUISnapshotTests.xctest`: 3 tests passed, producing 34 light/dark PNGs in `outputs/mac-redesign-2026-09-28/screens/`; see that directory's README. Representative setup, Settings and menu state images were visually reviewed.
- Xcode's `test` runner reported that it could not locate the test bundle executable, despite that executable existing in the built bundle. Direct `xcrun xctest` execution of that same bundle passed. This is a runner issue, not a test failure, but a normal `xcodebuild test` pass is unverified.
- `git diff --check` passed. The screenshots render SwiftUI views offscreen, including a stand-in for the native menu; they do not establish live menu behavior or installed-host permission continuity.

## Platform and design references

Apple's current [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) documentation describes utility menu bar apps and `LSUIElement`; [Settings](https://developer.apple.com/documentation/swiftui/settings) supplies the native Settings window. [Scene default launch behavior](https://developer.apple.com/documentation/swiftui/scene/defaultlaunchbehavior(_:)) supports suppressing the setup window after onboarding. [SMAppService registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register()) supports the optional Open at Login control. [AXIsProcessTrusted](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted) reports current Accessibility trust; the Core Graphics function reference lists `CGPreflightScreenCaptureAccess` and `CGRequestScreenCaptureAccess`. Xcode built the APIs with macOS 26 as the deployment target.

The interrupted design pass searched Mobbin for permission onboarding, QR pairing and compact status menus, including [Zoom permission flow](https://mobbin.com/screens/a1e635f3-8c4d-4fd1-b366-9ceb997ea27a), [Revolut Business QR layout](https://mobbin.com/screens/51e1e10a-5fad-4ba7-9ce6-b7b291c64c9b), and [Twingate status menu](https://mobbin.com/screens/d904c7ad-efff-4547-92b2-3db440005f69). These were inspiration, not copies. The host uses standard macOS controls with restrained sage/sand/clay accents. The `HostSettingsSection` compatibility wrapper avoids the documented computer-use helper crash caused by SwiftUI `GroupBox`.

## Remaining acceptance

The app has not been installed or opened here. The owner should use the identity-preserving build/install path in `Docs/MAC-PERMISSION-IDENTITY.md`, then verify first-run launch, menu reopen, Screen Recording and Accessibility grant detection, QR approval, viewing/controlling indicators, Stop Sharing persistence and real mouse/keyboard control with the paired phone. The `x-apple.systempreferences:` privacy-pane links are not a documented public Apple API and need that live check on the target OS. The paired phone's name is not stored by the current protocol, so the UI accurately says “Your iPhone” or “phone” rather than inventing a device name. Service availability and physical remote performance are outside this receipt.
