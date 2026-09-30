# Away continuation — 30 September 2026

Status: source checkpoint; **not yet built, tested or independently approved**. Based on `away/final-fix` / `edbcaa4` in isolated `codex/continue-away`. Root requested an early source handoff while serial integration checks occupy the shared Xcode slot. No Xcode job was queued by this worker.

Away remains experimental: `AwayModeGate.releaseDefault = false`, owner preference off by default, managed-Mac prohibition retained. Physical S1/S2 and gate enablement remain owner decisions. No app was launched, installed, deployed or submitted; no system settings, lock events, screen saver or IOPM assertions were changed. Regression tests use injected lockers, monitor backends, termination callbacks and tiny off-screen windows.

## Review findings addressed in source

- F1: disabling while present releases; disabling while covered requests a touched lock; disabling during locking or lock failure retains the phase and cover. The popover shows Turn off only while armed/present. The same rule applies to preference/gate loss through `update`.
- F2: AppKit's termination delegate defers Away quits until the session check reports locked or the two-second confirmation window ends. A covered timeout cancels quit and restores monitors; a later quit can retry. SIGTERM no longer cleans up before AppKit's termination decision. The popover no longer stops sharing before requesting termination. Clean exits preserve an unconfirmed Away-cover record, and a subsequent same-boot launch locks first even for that clean record.
- F3: local/global AppKit monitor callbacks act synchronously on main before target dispatch. Both monitors must install successfully before Away arms; partial installation is removed, reports unavailable and is logged. No fake test installs real input observers.
- F4: Away windows become opaque before asynchronous capture exclusion. Failed/stalled exclusion never lowers the Away cover. Away also takes over an in-flight sharing-curtain raise synchronously; the old async result cannot lower it.
- F5: automatic recovery eligibility is required for **Away only**, with explanatory UI; ordinary sharing still works with recovery off. Losing recovery while covered requests a lock while retaining the cover. A matching covered hang record requests the same public shortcut on the watchdog thread before its injected exit action. Tests supply both actions. Covered records are persisted synchronously before the cover is raised, and the helper uses the short hang timeout for Away records too.
- Related review minors: DEBUG-only lock-disable environment override, guarded XCTest refusal test, verified session lock check before uncovering, uncovered lock failures return to off after the confirmation window, synchronous screen-saver warning observers, and neutral lock-failed cover/readout copy that makes no display-sleep lock guarantee.
- Related display privacy: real display changes replace Away windows with opaque windows fitted to the current displays before notifying the lock callback; old windows are removed only after replacements are ordered. Capture excludes the replacements asynchronously. `refitAwayCover()` is available to the Big Text integration for intentional reconfiguration; that integration must call it without suppressing coverage maintenance.

## Historical rulings and arbitration

The final security review is the full recovered transcript at `work/farside-history/claude-agent-a4620af4a38b60fd8.txt` in the continuation chat. The old Claude ledger is read-only reference material at `.claude/worktrees/farside-away-mode/.superpowers/sdd/AWAY-MODE-IMPLEMENTATION-PLAN-2026-09-30/progress.md` (lines 64–72).

That ledger's coordinator rulings allowed covered release after synchronous input handling (F1), unconditional quit after two seconds (F2), and a warning rather than recovery eligibility (F5). No direct human override of the security findings appears in those lines. Root instructed this worker to prioritize verified lock-before-uncover behavior and make recovery an Away eligibility requirement only. The implementation follows that instruction. Root owns final arbitration and fresh sensitive independent GPT review before integration.

F6 remains a named residual requiring owner decision before enabling the feature: Siri/Voice Control/media/dictation activity can bypass key/pointer monitors; `.systemDefined` was not added without evidence of false-positive behavior. Local monitors also do not see events consumed by nested event-tracking loops, per Apple's current documentation. Secure Event Input, notification ordering, injected-event heuristics, crash exposure and real shortcut behavior remain physical acceptance concerns, not proven by mocks.

## Checks and pending acceptance

Passed, exit 0:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -frontend -parse RemoteHost/AwayLock.swift RemoteHost/AwayModeController.swift RemoteHost/AwayModeMachine.swift RemoteHost/HostAwayPresentation.swift RemoteHost/HostModel.swift RemoteHost/HostPopoverView.swift RemoteHost/HostTermination.swift RemoteHost/HostWatchdogReporter.swift RemoteHost/HostWatchdogState.swift RemoteHost/PrivacyCurtain.swift RemoteHost/RemoteHostApp.swift RemoteTests/AwayLockTests.swift RemoteTests/AwayModeControllerTests.swift RemoteTests/AwayModeMachineTests.swift RemoteTests/AwayCurtainTests.swift RemoteTests/AwayPresentationTests.swift RemoteTests/HostTerminationTests.swift
git diff --check
```

Output: no parse or whitespace diagnostics. This is syntax evidence, not typechecking. Stable Xcode toolchain query reports Apple Swift 6.4 / arm64-apple-macosx27.0.0. Disk preflight: `/` 36 GiB available; `/Volumes/Studio` 1.3 TiB available. An initial direct Swift path query used nonexistent `Developer/usr/bin/swiftc` and returned a path error; the corrected `DEVELOPER_DIR` / `xcrun` query succeeded.

Pending root-owned serial commands from the final integrated checkout (adjust DerivedData path if appropriate):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme RemoteCoreTests -destination platform=macOS -derivedDataPath /Volumes/Studio/Development/Caches/Xcode/DerivedData/continue-away CODE_SIGNING_ALLOWED=NO -collect-test-diagnostics never build-for-testing
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/lockf -k /tmp/farside-xcodebuild.lock xcrun xctest -XCTest AwayModeMachineTests /Volumes/Studio/Development/Caches/Xcode/DerivedData/continue-away/Build/Products/Debug/RemoteCoreTests.xctest
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemoteHost -destination platform=macOS -derivedDataPath /Volumes/Studio/Development/Caches/Xcode/DerivedData/continue-away CODE_SIGNING_ALLOWED=NO build
```

Repeat the wrapped class selection for `AwayModeControllerTests`, `AwayLockTests`, `AwayCurtainTests`, `AwayPresentationTests`, `HostTerminationTests`, `WatchdogPolicyTests`, `WatchdogReporterTests`, `PrivacyCurtainControllerTests`, `HostKeepAwakeTests`, `HostAvailabilityTests`, and `HangWatchdogTests`; verify actual class names in the bundle. Then root runs the complete core suite and required phone compile/tests on the integrated branch. **No pass counts are claimed here.** Physical harnesses in `script/away-feasibility/` must not run; any necessary changes there remain owner-run preparation.

Relevant Apple docs were refreshed through official Markdown endpoints on this date: [local monitors](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)), [termination delegate](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)), [CGEvent posting](https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:)), and [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes). The web reader could not parse Markdown, so system HTTPS retrieval was used without disabling TLS verification. The docs support pre-dispatch monitoring and delayed/cancelled termination; they do not establish physical lock success or shielding-window behavior. Snapshots are in the continuation chat's `work/away-api/`.
