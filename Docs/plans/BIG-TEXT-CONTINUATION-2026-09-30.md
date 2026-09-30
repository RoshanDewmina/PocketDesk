# Big Text continuation — 30 September 2026

Status: source fixes committed for author verification and fresh independent GPT review. **Feature incomplete: builds, tests and physical acceptance pending.** Worktree `/.codex/worktrees/continue-big-text`, branch `codex/continue-big-text`, baseline `9561760`. PRODUCT D50 on `farside-big-text` is the authorization record; the older feature snapshot still labels it D38. Global implementation ledger is owned by the parent.

## Recovery and changes

Read the complete historical whole-branch review `agent-abd4b474fbc592696` and follow-up briefs `agent-a525d59d94876009c`, `agent-a5650698448afacc2`, `agent-a3634994a68d6abb8` from session `df174eca-e701-4588-a461-5f5deef57c1f`. Recovered only tracked binary diffs from the original controller and phone fix worktrees; the host fix checkout had no diff. Original files remain untouched. Binary diff SHA256s, rechecked unchanged after recovery:

- Controller: `ae2b7446219b4f050240bd2913be63a09f53d631872f6fcde07ab54048aa3934`.
- Phone tests: `cebf4ec07534a3162b5fb2529bef7e9a3e01abe9c1530db5cee41d8385cdb700`.

No generated project was copied or changed. No external agent CLI, provider/deployment action, installation or real display switch ran.

| Review item | Source correction and regression evidence authored (not yet run) |
|---|---|
| 1: grow/restore curtain gaps | Controller exposes read-only `changeTarget` before every mode change; host prepares the curtain before apply, restore and synchronous quit restore. Each existing curtain window covers the current desktop union enlarged by twice the target/current size delta plus one point in every direction, retaining its excluded ID. Early CG and AppKit callbacks extend rather than shrink that envelope. Exact refit waits for AppKit frames to match current CG geometry; late own notifications finish refit. `CurtainDisplayCoverageTests`, `testPreparedGrowKeepsTheRaisedWindowsAndTheirExclusionIDs`. Actual physical coverage remains a gate. |
| 2: lost baseline on foreign restore | Keep baseline/current and mark restore pending while live mode is ours or temporarily unreadable during sleep. Forget only after a readable foreign choice or an already-restored baseline. Timeout, structural change and unreadable-mode tests in `BigTextControllerTests`. Successful apply followed by unreadable sleep also preserves ownership. |
| 3: half-raised curtain | `prepareForDisplayChange` cancels `.raising` before capture ownership expires; its awaiting exclusion returns `.cancelled`, allowing later re-raise. `testQuiescingDuringFailedExclusionCancelsInsteadOfPermanentlyFailing`. |
| 4: late screen notifications | Both observers consult the same completed snapshot of all online display IDs, CG mode IDs and verified SC frames. Duplicate notifications retain the curtain; a changed mode, topology or origin stays foreign. Tests in `BigTextScreenSnapshotTests`, `testLateOwnScreenNotificationKeepsTheSameExclusionWindows`. |
| 5: watchdog kills a healthy switch | Explicit `displayChanging` policy gives a bounded 12 s deadline during synchronous mode configuration, including with curtain up or Big Text engaged and recovery disabled. Normal engaged/up threshold returns to 4 s afterwards. This intentionally trades up to 12 s of curtain retention during a real hang for avoiding a 4 s kill during a healthy external-display switch; oversized coverage stays in place. `testDisplayConfigurationUsesBoundedRecoveryGraceEvenWithCurtainUp`. Physical duration remains unmeasured. |
| 6: stale capture frames / false success | Six fetch attempts spaced 200 ms (one second of retry spacing plus fetch duration); apply and session-continuing restore report failed when resume cannot verify geometry. Controller unverified-resume tests. |
| 7: capture-off card flashes | Phone view uses model predicate hiding the card only while pending. Timeout and reply restore normal card policy. Phone tests for pending/reply/timeout. |
| 8: another phone's inherited level | First applicable display list sends Off when this phone has no saved level or session Off and current differs from baseline. Wait for pending requests; cancel old-display debounce on a switch. Phone tests for inherited state, session Off, pending and older hosts. |
| 9: quit ignores in-flight target | Capture the recognizer target before cancellation and restore when live mode matches current or in-flight own mode. Termination tests cover first/later apply and foreign restore. |
| 10: awake restore never retried | Retry pending restore on next phone connection and a 30 s check in the existing permission timer, outside lock/changing states. Controller pending-retry tests remain the restoration authority. |
| 11: timeout followed by success / input | Remember timed-out display/width and clear only the corresponding timeout notice on a matching late success, preserving newer notices. Pending blocks `canControl`; sending a mode request first releases held input. Phone late-success, newer-notice and admission tests. |
| 12: callback / protocol forward compatibility | Callback is a private file-scope nonisolated C-compatible function. Accept bounded nonempty future `scaleError` tokens on `displays`; reject them elsewhere. This intentionally reverses the historical unknown-code rejection assertion. Phone ignores unknown codes without notice. Protocol and phone tests authored. |

BigTextHost protocol and existing controller method signatures remain unchanged. Watchdog `update` gains defaulted optional policy parameters; controller adds read-only change-target state. All window snapshot privacy and held-input release/epoch machinery remain in their existing paths.

## Actual checks

- Stable toolchain observed: `/Applications/Xcode.app`, Xcode **27.0 / 27A266a**, Swift **6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)**, target arm64-apple-macosx27.0.0. No deployment-target change.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -frontend -parse` over all 14 changed Swift files: **passed, exit 0**, after final source edits. Parsing is not typechecking or a build.
- `git diff --check`: **passed, exit 0**.
- Partial `swiftc -typecheck RemoteHost/BigTextModes.swift RemoteShared/BigTextProtocol.swift RemoteShared/DisplaySelection.swift RemoteHost/BigTextDisplaySwitcher.swift`: **failed, exit 1** because this partial file set omitted `RemoteError` and its full shared dependency closure. This is not a complete target build receipt; no typecheck success is claimed.
- Recovered original diffs compared with fresh diffs using `cmp`: **passed, exit 0**. Parent must recheck if old Claude sessions resume.
- External SSD free space: **1.3 TiB**, above the 20 GB floor.
- Core tests, host build, phone tests, phone UI and host snapshots: **not_run**. Parent requested committing source while its integrated build occupies the shared slot.
- Fresh independent GPT review of this revision: **not_run**. The historical Opus review covered the original implementation only.

## Pending acceptance commands

Run in this worktree, with pinned stable Xcode and the shared lock. Use a bounded terminal timeout and report actual status/counts. Do not install; serialize all commands. Parent may instead run equivalent checks on the reviewed integrated feature revision.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD=/Volumes/Studio/Development/Caches/Xcode/DerivedData/codex-continue-big-text
/usr/bin/lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme RemoteCoreTests -destination platform=macOS -derivedDataPath "$DD" -collect-test-diagnostics never build-for-testing
/usr/bin/lockf -k /tmp/farside-xcodebuild.lock xcrun xctest "$DD/Build/Products/Debug/RemoteCoreTests.xctest"
/usr/bin/lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemoteHost -destination platform=macOS -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build
```

Phone/UI require a separately allocated simulator slot; use the existing `Farside BigText iPhone` from the approved plan (resolve its actual UUID before running), disable parallel testing, and shut down the allocated simulator afterwards:

```sh
/usr/bin/lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -destination "id=$SIM" -derivedDataPath "$DD" -parallel-testing-enabled NO -collect-test-diagnostics never -only-testing:RemotePhoneTests test
/usr/bin/lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -destination "id=$SIM" -derivedDataPath "$DD" -parallel-testing-enabled NO -collect-test-diagnostics never -only-testing:RemotePhoneUITests/BigTextUITests -only-testing:RemotePhoneUITests/SessionLayoutTests -only-testing:RemotePhoneUITests/PhoneParityUITests/testDisplayPickerListsDisplaysAndSwitchesTheStream test
/usr/bin/lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme HostUISnapshotTests -destination platform=macOS -derivedDataPath "$DD" -collect-test-diagnostics never build-for-testing
/usr/bin/lockf -k /tmp/farside-xcodebuild.lock xcrun xctest "$DD/Build/Products/Debug/HostUISnapshotTests.xctest"
```

Apple's live CGCompleteDisplayConfiguration page was reached during continuation but the web reader returned a JavaScript shell; the app-only enum page was unavailable. No refreshed platform guarantee is asserted from those responses. SDK compilation and physical tests remain necessary.

## Remaining physical gates

During an explicitly authorized quiet window on the integrated checkout: curtain coverage for grow/shrink/Off on one and two displays; duplicate notifications and AppKit/SC frame lag; built-in/external mode-switch blocking time; SIGKILL/watchdog app-only restoration; lock/sleep/end/wake recovery with and without an external monitor; held drag release and immediate click alignment; full-screen refusal; System Settings choice preserved; window restoration including Stage Manager; curtain preference plus saved auto-apply on connect; readability and encode/fps/bitrate comparison against viewport capture. No performance, physical privacy or successful crash-revert claim is made.
