# Mac host feature research

Checked 28 September 2026. Proposed work, subordinate to PRODUCT.md. The menu-bar/setup-window implementation is tracked separately in the current build receipt.

## Prioritize trust and recovery

A small menu-bar companion should expose Ready/Connected/Stopped, the paired phone, Start/Stop Sharing, setup and Quit. Hide browser development machinery from the ordinary setup window without deleting its existing capability. Closing setup must leave the companion available; choosing Stop must remain stopped after relaunch. First pairing and enabling input still require the existing permission/consent boundary.

### Launch at login and watchdog

Use public SMAppService.mainApp for an explicit launch-at-login preference. The installed macOS27 SDK header marks it available since macOS13 and distinguishes enabled, unregistered, requiresApproval and missing states. Registration and actual process health are separate. A user-controlled launch agent can support recovery, but automatic crash restart must respect Stop Sharing and an intentional Quit. Never create a supervisor that immediately defeats Quit, retries permission dialogs or restarts a crash loop indefinitely. Add bounded backoff and a visible recovery failure. [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).

Proposed effort: 1–2 engineer-days for login preference/status and tests; 3–5 for restart policy and crash/hang fault injection. No login item or background daemon was registered in this continuation.

### Privacy curtain

Separate display dimming from actual privacy. A black window can obscure the screen yet also be captured, fail on another Space/display, or leave content exposed during crashes and transitions. An overlay is not a lock, and blocking local input can remove the owner's escape route. Prototype only with explicit engagement, persistent indication and local emergency release; verify all displays/Spaces, sleep, monitor hotplug, app crash and disconnect restoration. Prefer keeping this feature pending rather than branding cosmetic dimming as privacy. Workbench's curtain demonstrates vendor intent, not the public API or implementation available to us. [Workbench features](https://support.astropad.com/en/collections/18729715-workbench-features).

### Cursor

ScreenCaptureKit can include or omit the cursor in frames. That does not supply trustworthy shape, hotspot, visibility and composition-boundary metadata for a second pointer. Keep the captured pointer until the negotiated overlay protocol handles stale position, display origins, shape changes, capture transition and old-client fallback. The deprecated NSCursor.currentSystem issue is documented in the existing CURSOR-RESEARCH report. Never alter the user's global pointer size. [Apple ScreenCaptureKit guidance](https://developer.apple.com/videos/play/wwdc2022/10155/).

### Clipboard, sleep and virtual displays

Start clipboard with explicit bounded plain-text Send/Paste, not background synchronization. NSPasteboard.changeCount tracks ownership changes, not user consent to transmit content. Tag transfers to avoid loops, reject excessive data, avoid logging payloads and cancel on disconnect. [Apple changeCount](https://developer.apple.com/documentation/appkit/nspasteboard/changecount).

Keep-awake can hold a scoped assertion during a user-requested session; it does not defeat lock, FileVault, lid closure or loss of power. Remote login is a separate unsupported security boundary.

A phone-shaped virtual display would help layout and headless use, but this pass has not established a supported distribution-safe public API. Do not adopt private CGVirtualDisplay declarations based on competitor behavior or a community snippet. Require a public API/entitlement path, crash restoration test and target distribution decision before implementation. Multi-display selection with the existing capture APIs is a smaller first experiment.

## Acceptance sequence

Verify paired reconnect and permission truthfulness first, then Stop/relaunch, close-window/reopen, clean Quit, interrupted drag release, lock/sleep recovery, and permission revocation. Add each broader host capability only after its failure restoration is demonstrated. No privacy-curtain, watchdog, clipboard or virtual-display implementation is claimed here.
