# Draft bug report: native computer use crashes on SwiftUI GroupBox

Status: reproduced locally and sent to OpenAI Help Center support chat on 13 September 2026. Authenticated support conversation received the sanitized report and follow-up client details. Human/engineering routing and a case reference are not yet confirmed. Whether this is already known upstream is unknown.

## Impact

The native computer-use helper exits when asked to inspect a macOS SwiftUI window containing a GroupBox. The target app remains running. The caller receives `Sky Computer Use native pipe closed before response`, preventing inspection and subsequent automated interaction. Finder and a simple SwiftUI label/button window remain controllable.

## Environment

- macOS 27.0; Xcode 27.0.
- ChatGPT/Codex desktop app version 26.908.40834 (build 8881); reproduced from a Codex task. Work view not tested.
- Codex native computer use, `SkyComputerUseService`, helper version 26.902.1000968 (build 1000968).
- The real target app's Screen Recording and Accessibility checks both return true. A separate minimal app without capture, networking, or input injection reproduces the crash.

## Minimal target app

```swift
import SwiftUI

@main struct Probe: App {
    var body: some Scene {
        WindowGroup("Group Probe") {
            GroupBox("Section") {
                Button("Check") {}
            }
            .padding()
            .frame(width: 500, height: 300)
        }
    }
}
```

Build this as a macOS app, then inspect it using native computer use (`cua.getApp` with the app's full path). This consistently terminates the helper in the local reproduction. A fresh computer-use session and a fresh target launch do not resolve it.

Expected: a section heading and separately reachable Check button. Actual: helper process crashes and the tool returns a closed-pipe error.

## Controlled comparisons

| Target | Observed result |
| --- | --- |
| Finder | Native inspection succeeds |
| SwiftUI VStack with Label and Button | Native inspection succeeds |
| One GroupBox with Button, shown above | Helper crashes |
| PocketDesk-like ScrollView with two GroupBoxes | Helper crashes |
| Same layout with heading/VStack containers | Native inspection succeeds |
| Replacement styled container with semantic headings and `.accessibilityElement(children: .contain)` | Native inspection succeeds; headings and button exposed separately |

## Crash evidence

The helper crash reports `EXC_BREAKPOINT` / `SIGTRAP` in Swift's assertion failure and `Array.remove(at:)`. Independent local symbol mapping places the caller in `ComputerUseCore.UIElementTreeTransformation.transform(...)`, followed by recursive `compactMap` tree transformations. This points to an unsafe tree transformation in the helper. The precise invalid-index mechanism has not been established; the evidence does not establish a SwiftUI framework defect.

## App-side workaround

Replace the GroupBox wrapper with a styled VStack containing a semantic heading and the original controls. Keep children individually accessible. This changes presentation/accessibility structure only; it does not grant permissions or bypass host approval. PocketDesk's integrated workaround and validation are recorded in the implementation ledger.

## Privacy

This draft includes only the minimal invented UI and sanitized crash findings. It excludes screen images, app state, device identifiers, signing identities, paths containing personal names, enrollment codes, and full crash dumps. Attach this draft and the minimal source rather than raw diagnostics by default.

## Support submission

Sent the reproduction, comparisons, version details and sanitized crash frames through the authenticated OpenAI Help Center chat, following the [official support contact route](https://help.openai.com/en/articles/6614161-how-can-i-c). At support's request, provided the crash incident reference and clarified that helper symbols were independently mapped rather than present in the stripped raw stack. Support stated it cannot directly route to engineering or generate a case ID from this chat. Report delivery in the support conversation is confirmed; engineering acceptance is not.
