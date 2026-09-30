# Away Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One opt-in Mac setting that, while sharing is on, keeps the Mac awake and unlocked, covers the screen after 2 minutes without local use, and locks the Mac on any local touch, low battery, timeout, screen change, phone request or relaunch after a crash — plus the honest fallback (copy and a "your Mac locked while sharing" warning) that ships in 1.0 whether or not Away mode does.

**Architecture:** Pure, injectable units first (protocol fields, power/managed/lock-warning readers, the Away state machine, lock action and local-input classifier, curtain and watchdog additions), each with its own XCTest class; then a `@MainActor` controller that drives the machine through injected fakes; then `RemoteHostModel` wiring, the Mac UI and the phone UI. Task 0 (already done by the orchestrator) created every new file with its interface so parallel agents never edit the same file or the generated Xcode project. The whole feature sits behind `AwayModeGate` (default **off**) until Roshan's S1/S2 physical tests pass.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSEvent` monitors, `NSWindow`), IOKit power management (`IOPMAssertion*`, `IOPSCopyPowerSourcesInfo`), CoreGraphics events (`CGEvent`), `CFPreferencesAppValueIsForced`, XCTest, XcodeGen.

**Spec:** `Docs/plans/AWAY-MODE-DESIGN-2026-09-30.md` (commit `e5756ee` on `farside-feature-specs`, copied here), with Roshan's approved answers A1–A4 (Decisions section at its end).

## Global Constraints

- Deployment: iOS/iPadOS 26+, macOS 26+, Apple silicon only (D35). New `RemoteShared` code must compile for iOS **and** macOS (no AppKit there).
- **Safety (hard):** no agent — implementer, reviewer or orchestrator — may run the S1/S2 scripts, post the ⌃⌘Q lock event outside a unit-test fake, start the screen saver, change power/lock/screen-saver settings, or create IOPM assertions outside fakes. `HostLockShortcut.postingRefused` must be `true` in every test process. Scripts in `script/away-feasibility/` may only be type-checked (`xcrun swiftc -typecheck`), never run.
- Never store, type or ask for a password; never change the user's security settings; read only settings that need no password.
- Feature string `SessionFeature.away = "away.1"`, advertised only when `AwayModeGate.isEnabled()`; `capture` status field `away` with values `off|armed|covered`; phone action `"lockMac"`, gated exactly like `"curtain"`.
- Limits (exact): idle before cover 120 s; lock confirm 2 s; battery without a phone 5 min; battery floor with a phone 20 %; expiry 24 h without a phone; tick 0.5 s.
- Gate: `AwayModeGate.releaseDefault = false`; `UserDefaults` preview key `"FarsideAwayModePreview"`. Host preference keys `"awayModeWhileSharing"` (default `false`) and `"awayModeIntroShown"` (default `false`). Phone `UserDefaults` key `"awayLastKnownByMac"`.
- User-facing copy (exact, curly apostrophes): see Task 9 and Task 8 tables. Copy says "covered" and "locks if touched", never "locked" or "secure" for the armed state.
- Code comments only where the *why* is non-obvious (repo and user rule). No docstrings restating names.
- Repo rules (AGENTS.md): wrap every `xcodebuild`/`xctest` in `lockf -k /tmp/farside-xcodebuild.lock`; never install to the phone or `/Applications`; never run `script/build_and_run.sh`; shut down any simulator you boot; only simulator name `Farside Away iPhone`; commit messages: imperative subject, body, final line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Phone input must never look like local input.** Injected events carry `RemoteInputTag` or our PID; a false positive locks the owner's Mac mid-session. Test: Task 5 `testInjectedEventsAreNeverLocal`, Task 7 `testPhoneInputNeverLocksOrResetsIdle` (fake monitor only reports local).
2. **Internal stop/restart cycles must not lock the Mac** (display switch, capture failure retry, `stop()` from teardown): only `sharingWanted == false` (Stop Sharing / pause) ends Away mode. Test: Task 4 `testSharingBlipDoesNotEndAwayMode`.
3. **The cover must not drop while locking** (Stop Sharing lifts the sharing curtain today). Test: Task 4 `testLockingKeepsTheCoverOnlyWhenItWasCovered`, Task 10 wiring rule "liftCurtain never lowers a cover Away mode wants".
4. **A failed lock must fail closed**: assertions released, cover kept, retry on the next local touch, and the cover drops once macOS reports locked. Test: Task 4 `testLockTimeoutReleasesDisplayButKeepsCover`, `testTouchAfterFailedLockRetries`.
5. **Crash while covered relaunches locked first**, and an older watchdog record without the new field still decodes. Test: Task 6 `testOldRecordWithoutAwayFieldDecodes`, `testUnexpectedExitWhileCoveredLocksFirst`.

---

## Execution model (read first)

- **Waves.** Task 0 is done (orchestrator). **Wave 1:** Tasks 1, 2, 3, 4, 5, 6 in parallel. **Wave 2:** Tasks 7, 8, 9 in parallel. **Wave 3:** Task 10. **Wave 4:** whole-branch security review, full suites, ledger/PRODUCT (orchestrator).
- **One worktree per task:** `git worktree add -b away/<task> .claude/worktrees/away-<task> <farside-away-mode head>`. Work only there. Never touch other worktrees or the main checkout.
- **Never commit `PocketDesktop.xcodeproj` or `project.yml` in Tasks 1–10.** Task 0 registered every new file. If you must run `xcodegen generate`, run `git checkout -- PocketDesktop.xcodeproj` before committing.
- **Builds.** `DD=/Volumes/Studio/Development/Caches/Xcode/DerivedData/away-<task>`. Check `df -h / /Volumes/Studio` first; stop and report if either has under 20 GB free. The orchestrator deletes your DerivedData after merge.
- **Mac core test command** (Tasks 2–7, 9, 10):
  ```bash
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme RemoteCoreTests -destination platform=macOS -derivedDataPath "$DD" -collect-test-diagnostics never build-for-testing
  lockf -k /tmp/farside-xcodebuild.lock xcrun xctest -XCTest <ClassName> "$DD/Build/Products/Debug/RemoteCoreTests.xctest"
  ```
- **Mac app compile check** (Tasks 6, 7, 9, 10): `lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemoteHost -destination platform=macOS -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build`. Never launch the built app.
- **Phone test command** (Task 8):
  ```bash
  SIM=$(xcrun simctl list devices -j | python3 -c "import json,sys;print(([d['udid'] for r in json.load(sys.stdin)['devices'].values() for d in r if d['name']=='Farside Away iPhone']+[''])[0])")
  [ -z "$SIM" ] && SIM=$(xcrun simctl create "Farside Away iPhone" "iPhone 17 Pro")
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -destination "id=$SIM" -derivedDataPath "$DD" -parallel-testing-enabled NO -collect-test-diagnostics never -only-testing:RemotePhoneTests/<ClassName> test
  xcrun simctl shutdown "$SIM"
  ```
- **Report** exact pass/fail/skip counts. A failing pre-existing unrelated test is reported, not "fixed".

### Expected merge points with Big Text (`farside-big-text`) and other branches

Keep changes to these minimal and additive; the orchestrator resolves them at integration:
- `RemoteHost/PrivacyCurtain.swift`: Big Text adds `PrivacyCurtainInputs.displayReconfiguring` (last field), an early return in `desired`, and `followsScreenChanges` inside `observeScreenChanges`. Away adds `awayCovered` (last field), its own early return, and a `liftsOnScreenChange`/`onScreensChanged` pair in the same handler (Task 6). Resolution: keep both fields; Away's early return first; the handler lifts only when both `followsScreenChanges` and `liftsOnScreenChange` are true, else calls `onScreensChanged` when Away's flag is false.
- `RemoteHost/HostHangWatchdog.swift`: Away does **not** modify it (the cover sets `curtainUp`, so the 4 s threshold already applies).
- `RemoteShared/ControlProtocol.swift`: both append fields after `busy`. Keep both.
- `RemoteShared/SessionContinuity.swift` `SessionFeature`: both append a constant after `ladder`, neither is in `host`. Keep both.
- `RemoteHost/HostModel.swift`, `HostViewState.swift`, `HostSettingsView.swift`, `HostPopoverView.swift`, `RemoteHostApp.swift`, `HostReadiness.swift` (`HostPreferences`), `RemotePhone/RemotePhoneApp.swift`, `RemotePhone/NativeSessionView.swift`: independent additions in the same files.
- `project.yml` RemoteCoreTests `sources`: both append host files. Keep both lists.
- `PRODUCT.md` decision numbers: D38 is used twice (Big Text, motion lab) and D39 by motion lab; the orchestrator picks the next free number after re-checking every branch.

---

### Task 0: Scaffold, spec copy (orchestrator — done)

Created `RemoteShared/AwayModeProtocol.swift`, `RemoteHost/AwayModeMachine.swift`, `RemoteHost/HostAwayEnvironment.swift`, `RemoteHost/AwayLock.swift`, `RemoteHost/AwayModeController.swift`, `RemoteHost/HostAwayPresentation.swift` with the exact declarations below and stub bodies; empty test classes `RemoteTests/{AwayProtocolTests, AwayEnvironmentTests, AwayModeMachineTests, AwayLockTests, AwayCurtainTests, AwayModeControllerTests, AwayPresentationTests}.swift` and `RemotePhoneTests/AwayPhoneTests.swift`; `HostViewState` fields `awayMode`, `awayIntroShown`, `away: HostAwayReadout`, `lockWarning: HostLockWarning?`; `HostActions` closures `setAwayMode`, `coverNow`, `dismissLockWarning`, `openLockScreenSettings`; empty `RemoteHostModel.setAwayMode(_:)`, `coverNow()`, `dismissLockWarning()`, `openLockScreenSettings()` wired in `RemoteHostApp`; the new host files registered in `project.yml` RemoteCoreTests `sources`; project regenerated. Read the stub files in your worktree: **their declarations are the contract** — do not rename or change signatures; add private helpers freely.

---

### Task 1: S1/S2 feasibility harness and instructions for Roshan

**Files:**
- Create: `Docs/plans/AWAY-MODE-FEASIBILITY-TESTS.md`, `script/away-feasibility/away-hold-and-watch.swift`, `script/away-feasibility/away-lock-probe.swift`

**Interfaces:** Consumes nothing. Produces the go/no-go record for `AwayModeGate.releaseDefault`.

**You must not run either script, not even with `--help`.** Verification is type-checking only.

- [ ] **Step 1: `away-hold-and-watch.swift` (S1).** A self-contained Swift script (`#!/usr/bin/env swift`, imports Foundation, IOKit.pwr_mgt, CoreGraphics, AppKit) that:
  1. Prints what it will do and refuses to continue unless the person types exactly `HOLD` at a prompt (read from stdin). Also refuses if stdin is not a TTY (`isatty(0) == 0`), so no agent can pipe the answer.
  2. Takes `--minutes N` (default 30) and optional `--declare-activity-every S` (off by default; S1c).
  3. Creates the same two assertions the app holds while armed — `kIOPMAssertPreventUserIdleSystemSleep` and `kIOPMAssertionTypePreventUserIdleDisplaySleep` — named `"Farside Away S1 test"`, and releases both on exit, on `SIGINT` and on `SIGTERM` (install `signal` handlers via `DispatchSource.makeSignalSource`).
  4. If `--declare-activity-every` is set, calls `IOPMAssertionDeclareUserActivity("Farside Away S1 test", kIOPMUserActiveLocal, &id)` every S seconds.
  5. Every 10 s appends one line to `~/Library/Logs/Farside/away-s1-<yyyyMMdd-HHmmss>.log` and stdout: ISO time, elapsed seconds, `locked=` (`CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"] == true`), `screensaver=` (any running app with bundle id `com.apple.ScreenSaver.Engine` or process named `ScreenSaverEngine` via `NSWorkspace.shared.runningApplications`), `displayAsleep=` (`CGDisplayIsAsleep(CGMainDisplayID()) != 0`).
  6. Records the first time `locked` became true; at the end prints `S1 RESULT: NOT LOCKED during N min` or `S1 RESULT: LOCKED after X s (screensaver=…)`.
  7. Never changes any setting and never posts events.
- [ ] **Step 2: `away-lock-probe.swift` (S2).** Self-contained script that mirrors `HostLockShortcut.events(source:)` from `RemoteHost/AwayLock.swift` **exactly** (key code 12, flags `[.maskControl, .maskCommand]`, a key-down then key-up from `CGEventSource(stateID: .hidSystemState)`, each marked with `eventSourceUserData = 0x4641_5253_4944_4531`, posted to `.cghidEventTap`). It: requires a TTY and the typed word `LOCK`; checks `AXIsProcessTrusted()` and, if false, prints which app (Terminal/iTerm) needs Accessibility and exits 2 without posting; counts down 5 s; posts; polls `CGSSessionScreenIsLocked` every 0.1 s for 2 s; prints `S2 RESULT: LOCKED in X ms` or `S2 RESULT: NOT LOCKED within 2 s`; appends to `~/Library/Logs/Farside/away-s2-<timestamp>.log`. A header comment states it must stay identical to `HostLockShortcut` and that a reviewer must diff the two.
- [ ] **Step 3: `AWAY-MODE-FEASIBILITY-TESTS.md`.** For Roshan, plain language, sections:
  - *Why*: Away mode ships in 1.0 only if S1a and S2 pass by about 10 October (decision A1); otherwise 1.0 keeps the fallback copy and lock warning and Away mode moves to 1.1.
  - *Before you start*: pick a quiet time; save work; note your current Lock Screen settings (System Settings → Lock Screen: "Start Screen Saver when inactive", "Turn display off on battery/power adapter when inactive", "Require password after screen saver begins or display is turned off") so you can put them back; plug in power; quit Farside's host (so it does not hold its own assertions); keep your phone away from the Mac.
  - *S1a (required)*: screen saver **Never**, display off **2 min**, password **Immediately**. Run `swift script/away-feasibility/away-hold-and-watch.swift --minutes 30`, type `HOLD`, walk away without touching the Mac for 30 min. Pass = `NOT LOCKED`.
  - *S1b (informs A4 copy)*: same but screen saver **2 min**. Record LOCKED/NOT LOCKED and whether `screensaver=true` appeared. Expected: locks via the screen saver → Away mode detects and explains it (A4); not a blocker.
  - *S1c (record only)*: S1b plus `--declare-activity-every 60`. Record the result (option B was not chosen; this is for the record).
  - *S2 (required)*: give Terminal Accessibility temporarily, run `swift script/away-feasibility/away-lock-probe.swift`, type `LOCK`, keep hands off. Pass = `LOCKED in < 2000 ms`. Afterwards remove Terminal's Accessibility grant if you added it for this test.
  - *Afterwards*: restore your Lock Screen settings.
  - *Results table* to fill: test, macOS version (26 and 27 if possible), date, result, log file path, notes.
  - *Go/no-go rule*: S1a **and** S2 pass on macOS 26 and 27 → set `AwayModeGate.releaseDefault = true` in `RemoteHost/HostAwayEnvironment.swift` (one line) and run S3–S6 with the real app. Otherwise leave it `false`; 1.0 ships the fallback.
  - *Trying the real app before flipping the gate*: `defaults write com.roshan.PocketDesk.RemoteHost FarsideAwayModePreview -bool YES`, relaunch Farside; `defaults delete … FarsideAwayModePreview` to hide it again.
  - *Later physical checks with the real app (S3–S6)*, copied from spec §8: S3 local-event-to-lock latency (touch trackpad once while covered; measure time to lock screen), S4 `kill -9` the host while covered (count seconds exposed before the relaunched host locks; needs "Restart Farside if it quits" on), S5 unplug AC (Away mode ends after 5 min without a phone) and close the lid, S6 away 2 h then connect from cellular and use End and lock Mac.
  - *Safety*: the scripts change no settings, never ask for or store a password, and hold assertions only while running.
- [ ] **Step 4: Type-check only.** `xcrun swiftc -typecheck script/away-feasibility/away-hold-and-watch.swift` and the same for `away-lock-probe.swift`. Expected: no errors. Do **not** run them.
- [ ] **Step 5: Commit** `Add Away mode S1/S2 feasibility scripts and instructions` (the three files only).

---

### Task 2: Protocol (`away.1`, `away` status, `lockMac`)

**Files:**
- Modify: `RemoteShared/SessionContinuity.swift` (`SessionFeature` after `ladder`; `PhoneSessionNotice`; `sessionExtensionActions`; `validateSessionExtension`), `RemoteShared/ControlProtocol.swift` (field after `busy`), `RemoteShared/AwayModeProtocol.swift`
- Test: `RemoteTests/AwayProtocolTests.swift`

**Interfaces:**
- Consumes: `AwayModeState` (Task 0).
- Produces: `SessionFeature.away == "away.1"` (not in `SessionFeature.host`); `RemoteAction.away: String? = nil` (declared after `busy`); action name `"lockMac"` in `RemoteAction.sessionExtensionActions`; `AwayModeState.init(reported: String?)` returning `.off` for nil/unknown; `PhoneSessionNotice.awayCovered = "Mac covered · locks if touched"`, `PhoneSessionNotice.awayCantUnlock = "Away mode can’t unlock it."`.

- [ ] **Step 1: Write the failing tests** in `AwayProtocolTests`:
```swift
func testFeatureIsAdvertisedOnlyWhenTheMacAllowsIt() {
    XCTAssertEqual(SessionFeature.away, "away.1")
    XCTAssertFalse(SessionFeature.host.contains(SessionFeature.away))
}
func testAwayStateRoundTripsOnCaptureStatus() throws {
    let status = RemoteAction(action: "capture", away: AwayModeState.covered.rawValue)
    let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(status))
    XCTAssertNoThrow(try decoded.validate())
    XCTAssertEqual(AwayModeState(reported: decoded.away), .covered)
}
func testUnknownOrMissingAwayMeansOff() {
    XCTAssertEqual(AwayModeState(reported: nil), .off)
    XCTAssertEqual(AwayModeState(reported: "unlocked"), .off)
}
func testAwayRidesOnlyOnCapture() {
    XCTAssertThrowsError(try RemoteAction(action: "heartbeat", away: "armed").validate())
    XCTAssertThrowsError(try RemoteAction(action: "lockMac", away: "armed").validate())
}
func testLockMacCarriesNoPayload() {
    XCTAssertNoThrow(try RemoteAction(action: "lockMac").validate())
    XCTAssertThrowsError(try RemoteAction(action: "lockMac", text: "x").validate())
    XCTAssertThrowsError(try RemoteAction(action: "lockMac", curtain: "up").validate())
    XCTAssertThrowsError(try RemoteAction(action: "lockMac", x: 1).validate())
}
func testOversizedAwayValueIsRejected() {
    XCTAssertThrowsError(try RemoteAction(action: "capture", away: String(repeating: "a", count: 4096)).validate())
}
func testOlderDecoderIgnoresTheField() throws {
    let json = #"{"action":"capture","away":"armed","epoch":1,"x":0,"y":0,"text":"","key":"","modifiers":[]}"#
    XCTAssertNoThrow(try JSONDecoder().decode(RemoteAction.self, from: Data(json.utf8)))
}
func testNoticeCopy() {
    XCTAssertEqual(PhoneSessionNotice.awayCovered, "Mac covered · locks if touched")
    XCTAssertEqual(PhoneSessionNotice.awayCantUnlock, "Away mode can’t unlock it.")
}
```
(If the memberwise argument order differs because `away` is declared last, construct with `var a = RemoteAction(action: "capture"); a.away = "covered"`.)
- [ ] **Step 2: Run** `-XCTest AwayProtocolTests`; expect failures/compile errors.
- [ ] **Step 3: Implement.** `static let away = "away.1"` after `ladder` in `SessionFeature` (not in `host`). `var away: String? = nil` after `busy` with a one-line comment "Away mode on `capture` status (`SessionFeature.away`). Older phones ignore it." In `validateSessionExtension`: `if let away { guard action == "capture", ClipboardFrame.isWellFormedStatus(away) else { throw RemoteError.invalidMessage } }` beside the `hostEvent` check; add `"lockMac"` to `sessionExtensionActions` (the existing guard then rejects any payload field); make sure `lockMac` with a `curtain` or `clipboard` throws (existing branches already do). In `AwayModeProtocol.swift`: `init(reported: String?) { self = reported.flatMap(Self.init(rawValue:)) ?? .off }`. Add the two notice constants to `PhoneSessionNotice`. If `DisplaySelection.swift:51` lists every optional field to prove a displays message carries nothing else, add `away == nil` there.
- [ ] **Step 4: Run** `AwayProtocolTests`, then `NativeProtocolTests`, `SecurityTests`, `DisplaySelectionTests`. Expected: all pass.
- [ ] **Step 5: Commit** `Add the away.1 protocol: away status and lockMac action`.

---

### Task 3: Power, managed-Mac, idle and lock-warning readers; release gate; power policy

**Files:**
- Modify: `RemoteHost/HostAwayEnvironment.swift`, `RemoteHost/HostKeepAwake.swift` (`HostPowerPolicy` :32–38 only)
- Test: `RemoteTests/AwayEnvironmentTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (bodies for Task 0 stubs): `AwayModeGate.isEnabled(defaults:)`; `HostPowerSourceParser.snapshot(providingType:sources:lowPowerMode:)`; `SystemPowerSource.snapshot()`; `ManagedLockPolicy.isManaged(isForced:)` and `systemIsForced`; `HostIdle.systemIdleSeconds()`; `HostLockWarningTracker` methods; and `HostPowerPolicy.assertions(keepAwake:sharing:phoneConnected:awayArmed: Bool = false)`.

- [ ] **Step 1: Write the failing tests** in `AwayEnvironmentTests`:
```swift
func testGateIsOffByDefaultAndPreviewKeyTurnsItOn() {
    let defaults = UserDefaults(suiteName: "away-gate-\(UUID())")!
    XCTAssertFalse(AwayModeGate.releaseDefault)
    XCTAssertFalse(AwayModeGate.isEnabled(defaults: defaults))
    defaults.set(true, forKey: AwayModeGate.previewKey)
    XCTAssertTrue(AwayModeGate.isEnabled(defaults: defaults))
}
func testPowerParsing() {
    let battery: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 42, "Max Capacity": 100]
    XCTAssertEqual(HostPowerSourceParser.snapshot(providingType: "AC Power", sources: [battery], lowPowerMode: false),
                   HostPowerSnapshot(onACPower: true, batteryPercent: 42, lowPowerMode: false))
    XCTAssertEqual(HostPowerSourceParser.snapshot(providingType: "Battery Power", sources: [battery], lowPowerMode: true),
                   HostPowerSnapshot(onACPower: false, batteryPercent: 42, lowPowerMode: true))
    XCTAssertEqual(HostPowerSourceParser.snapshot(providingType: nil, sources: [], lowPowerMode: false),
                   HostPowerSnapshot(onACPower: true, batteryPercent: nil, lowPowerMode: false), "Desktop Macs have no battery")
    let odd: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 5000, "Max Capacity": 5000]
    XCTAssertEqual(HostPowerSourceParser.snapshot(providingType: "Battery Power", sources: [odd], lowPowerMode: false).batteryPercent, 100)
    let zeroMax: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 10, "Max Capacity": 0]
    XCTAssertNil(HostPowerSourceParser.snapshot(providingType: "Battery Power", sources: [zeroMax], lowPowerMode: false).batteryPercent)
    let ups: [String: Any] = ["Type": "UPS", "Current Capacity": 1, "Max Capacity": 100]
    XCTAssertNil(HostPowerSourceParser.snapshot(providingType: "AC Power", sources: [ups], lowPowerMode: false).batteryPercent,
                 "Only the internal battery counts")
}
func testManagedWhenAnyLockKeyIsForced() {
    XCTAssertFalse(ManagedLockPolicy.isManaged(isForced: { _, _ in false }))
    for key in ManagedLockPolicy.keys {
        XCTAssertTrue(ManagedLockPolicy.isManaged(isForced: { k, d in k == key && d == ManagedLockPolicy.domain }), key)
    }
}
func testLiveReadersDoNotCrash() {
    _ = SystemPowerSource().snapshot()
    _ = ManagedLockPolicy.isManaged()
    XCTAssertGreaterThanOrEqual(HostIdle.systemIdleSeconds(), 0)
}
func testPowerPolicyTruthTable() {
    typealias P = HostPowerPolicy
    XCTAssertTrue(P.assertions(keepAwake: true, sharing: true, phoneConnected: false) == (true, false), "Unchanged without Away")
    XCTAssertTrue(P.assertions(keepAwake: true, sharing: true, phoneConnected: true) == (true, true))
    XCTAssertTrue(P.assertions(keepAwake: true, sharing: true, phoneConnected: false, awayArmed: true) == (true, true),
                  "Armed holds the display on with no phone, so display-off never locks")
    XCTAssertTrue(P.assertions(keepAwake: false, sharing: true, phoneConnected: false, awayArmed: true) == (true, true),
                  "Away mode is its own keep-awake request")
    XCTAssertTrue(P.assertions(keepAwake: true, sharing: false, phoneConnected: false, awayArmed: true) == (false, false),
                  "Nothing is held while sharing is not running")
    XCTAssertTrue(P.assertions(keepAwake: false, sharing: true, phoneConnected: true, awayArmed: false) == (false, false))
}
func testLockWarnings() {
    var t = HostLockWarningTracker()
    let at = Date(timeIntervalSince1970: 1_000)
    XCTAssertNil(t.screenLocked(at: at, uptime: 100, sharingWanted: false, awayArmed: false, lockRequestedByFarside: false, idleSeconds: 999),
                 "Not sharing: nothing to warn about")
    XCTAssertNil(t.screenLocked(at: at, uptime: 100, sharingWanted: true, awayArmed: true, lockRequestedByFarside: true, idleSeconds: 999),
                 "Away mode's own lock is expected")
    XCTAssertNil(t.screenLocked(at: at, uptime: 100, sharingWanted: true, awayArmed: false, lockRequestedByFarside: false, idleSeconds: 2),
                 "Someone at the Mac chose to lock it")
    XCTAssertEqual(t.screenLocked(at: at, uptime: 100, sharingWanted: true, awayArmed: false, lockRequestedByFarside: false, idleSeconds: 600),
                   .lockedWhileSharing(at: at))
    t.screenSaverStarted(uptime: 95)
    XCTAssertEqual(t.screenLocked(at: at, uptime: 100, sharingWanted: true, awayArmed: true, lockRequestedByFarside: false, idleSeconds: 0),
                   .screenSaverLocked(at: at, awayArmed: true), "The screen saver is the cause even though idle was reset")
    t.screenSaverStopped()
    t.screenSaverStarted(uptime: 10)
    XCTAssertEqual(t.screenLocked(at: at, uptime: 100, sharingWanted: true, awayArmed: false, lockRequestedByFarside: false, idleSeconds: 600),
                   .screenSaverLocked(at: at, awayArmed: false), "Still running, so still the cause")
}
```
- [ ] **Step 2: Run** `-XCTest AwayEnvironmentTests`; expect failures.
- [ ] **Step 3: Implement.**
  - Gate: `releaseDefault || defaults.bool(forKey: previewKey)`.
  - Parser: `onACPower = providingType != "Battery Power"` (compare against `kIOPMBatteryPowerKey`'s value `"Battery Power"`; nil → AC). Battery: first source with `kIOPSTypeKey == kIOPSInternalBatteryType` ("InternalBattery"); percent = `Int((Double(current) / Double(max) * 100).rounded())` clamped to 0…100, nil when max ≤ 0 or either key missing.
  - `SystemPowerSource.snapshot()`: `IOPSCopyPowerSourcesInfo()?.takeRetainedValue()`, `IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?`, `IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]`, each via `IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any]`; `lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled`. Read-only.
  - `systemIsForced`: `CFPreferencesAppValueIsForced(key as CFString, domain as CFString)`. `isManaged`: any of `keys` forced in `domain`.
  - `HostIdle.systemIdleSeconds()`: `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)`, clamped to ≥ 0.
  - Tracker: `screenSaverStarted` sets `screenSaverStartedAt = uptime`; `screenSaverStopped` clears it. `screenLocked`: nil when `!sharingWanted` or `lockRequestedByFarside`; `.screenSaverLocked(at:awayArmed:)` when `screenSaverStartedAt != nil` (running, or started within `screenSaverWindow` — a stopped screen saver clears the field, so non-nil means running or just started); else `.lockedWhileSharing` when `idleSeconds >= idleForAutomaticLock`; else nil.
  - `HostPowerPolicy.assertions`: add `awayArmed: Bool = false`; return `(sharing && (keepAwake || awayArmed), sharing && ((keepAwake && phoneConnected) || awayArmed))`. Update its doc comment in one line.
- [ ] **Step 4: Run** `AwayEnvironmentTests`, `HostKeepAwakeTests`, `HostAvailabilityTests`. Expected: pass.
- [ ] **Step 5: Commit** `Read power, managed lock policy and idle time for Away mode`.

---

### Task 4: Away mode state machine

**Files:**
- Modify: `RemoteHost/AwayModeMachine.swift` (bodies only; `HostAwayReadout` unchanged)
- Test: `RemoteTests/AwayModeMachineTests.swift`

**Interfaces:**
- Consumes: `AwayModeState` (Task 0).
- Produces: behaviour of `AwayModeMachine` exactly as the rules below; later tasks rely on `phase`, `wantsCover`, `holdsDisplayAwake`, `protocolState`, `coversIn`, `batteryEndsIn`, `lockRequestedAt`, `lastLocalInputAt`.

**Rules (the contract):**

| Call | From | Result |
|---|---|---|
| `unavailableReason(c)` | — | First match: `!sharingWanted \|\| !sharingActive` → `.sharingOff`; `screenLocked` → `.macLocked`; `!accessibility` → `.needsAccessibility`; `managed` → `.managed`; `!onACPower` → `.onBattery`; `safeMode` → `.safeMode`; else nil. Ignores `enabled`. |
| `update(c, now)` (always first) | any | If `c.phoneConnected` **or the stored conditions had `phoneConnected`** (a phone just left) → `lastPhoneAt = now`. Then store `c`. `onBatterySince = c.onACPower ? nil : (onBatterySince ?? now)`. |
| `update` | `.off` | If `c.enabled && unavailableReason(c) == nil` → `.armedPresent`, `lastLocalInputAt = now`, `lastPhoneAt = now`. |
| `update` | armed | In order: `screenLocked` → `.off` (already safe); `!enabled` → `.off` (release only); `!sharingWanted` → `end(.stopSharing)`; `!accessibility \|\| managed \|\| safeMode` → `end(.lostRequirement)`; battery rule → `end(.battery)`. `!sharingActive` alone changes nothing. |
| `update` | `.locking`/`.lockFailed` | `screenLocked` → `.off`. Nothing else. |
| battery rule | armed | `onBatterySince != nil` and (`phoneConnected ? (batteryPercent ?? 100) <= 20 : now - onBatterySince >= 300`). |
| `tick(now)` | `.locking(r)` | `now - lockRequestedAt >= 2` → `.lockFailed(r)`. |
| `tick` | armed | If `phoneConnected` → `lastPhoneAt = now`. Then: `!phoneConnected && now - lastPhoneAt >= 86_400` → `end(.expiry)`; battery rule → `end(.battery)`; `.armedPresent && now - lastLocalInputAt >= 120` → `.armedCovered`. |
| `localInput(now)` | `.armedPresent` | `lastLocalInputAt = now`. |
| `localInput` | `.armedCovered` | `end(.touched)`. |
| `localInput` | `.lockFailed(r)` | Retry: `.locking(r)`, `lockRequestedAt = now`, return `.lock(r)`. |
| `coverNow(now)` | `.armedPresent` | `.armedCovered`. |
| `end(r, now)` | armed | `lockCovers = (phase == .armedCovered)`; `.locking(r)`; `lockRequestedAt = now`; return `.lock(r)`. |
| `end(r, now)` | `.off` | Only for `.phoneRequest` (`lockCovers = false`) and `.relaunchedAfterExit` (`lockCovers = true`): `.locking(r)` + `.lock(r)`. Others: nil. |
| `end(r, now)` | `.lockFailed` | Retry as above with reason `r`, keeping `lockCovers`. |
| `end` | `.locking` | nil. |
| `turnOffAtMac()` | any | `.off`, `lockCovers = false`. |
| `lockConfirmed()` | `.locking`/`.lockFailed` | `.off`, `lockCovers = false`. |

Derived: `wantsCover` = `.armedCovered`, or `.locking`/`.lockFailed` with `lockCovers`. `holdsDisplayAwake` = `.armedPresent`, `.armedCovered`, `.locking`. `protocolState`: `.off` → `.off`; `.armedPresent` → `.armed`; `.armedCovered` → `.covered`; `.locking`/`.lockFailed` → `lockCovers ? .covered : .armed`. `coversIn(now)` = `.armedPresent ? max(0, 120 - (now - lastLocalInputAt)) : nil`. `batteryEndsIn(now)` = armed, `onBatterySince != nil`, `!phoneConnected` → `max(0, 300 - (now - onBatterySince))`, else nil.

- [ ] **Step 1: Write the failing tests** in `AwayModeMachineTests` (add a helper `ready` = `AwayConditions(enabled: true, sharingWanted: true, sharingActive: true, accessibility: true)`):
```swift
func testArmsOnlyWhenEveryRequirementHolds() {
    for (name, change, reason) in [
        ("sharing off", { (c: inout AwayConditions) in c.sharingWanted = false }, AwayUnavailableReason.sharingOff),
        ("not running", { $0.sharingActive = false }, .sharingOff),
        ("locked", { $0.screenLocked = true }, .macLocked),
        ("no Accessibility", { $0.accessibility = false }, .needsAccessibility),
        ("managed", { $0.managed = true }, .managed),
        ("battery", { $0.onACPower = false }, .onBattery),
        ("safe mode", { $0.safeMode = true }, .safeMode)
    ] as [(String, (inout AwayConditions) -> Void, AwayUnavailableReason)] {
        var c = ready; change(&c)
        var m = AwayModeMachine()
        m.update(c, now: 0)
        XCTAssertEqual(m.phase, .off, name)
        XCTAssertEqual(AwayModeMachine.unavailableReason(c), reason, name)
    }
    var m = AwayModeMachine(); var off = ready; off.enabled = false
    m.update(off, now: 0); XCTAssertEqual(m.phase, .off, "Opt-in")
    m.update(ready, now: 0); XCTAssertEqual(m.phase, .armedPresent)
    XCTAssertTrue(m.holdsDisplayAwake); XCTAssertFalse(m.wantsCover); XCTAssertEqual(m.protocolState, .armed)
}
func testCoversAfterTwoIdleMinutesAndLocalInputResetsTheTimer() {
    var m = AwayModeMachine(); m.update(ready, now: 0)
    m.tick(now: 119); XCTAssertEqual(m.phase, .armedPresent); XCTAssertEqual(m.coversIn(now: 119), 1)
    m.localInput(now: 100); m.tick(now: 219); XCTAssertEqual(m.phase, .armedPresent)
    m.tick(now: 220); XCTAssertEqual(m.phase, .armedCovered); XCTAssertTrue(m.wantsCover); XCTAssertEqual(m.protocolState, .covered)
}
func testAnyLocalTouchWhileCoveredLocks() {
    var m = AwayModeMachine(); m.update(ready, now: 0); m.coverNow(now: 1)
    XCTAssertEqual(m.localInput(now: 2), .lock(.touched))
    XCTAssertEqual(m.phase, .locking(.touched)); XCTAssertTrue(m.wantsCover); XCTAssertTrue(m.holdsDisplayAwake)
    XCTAssertNil(m.localInput(now: 2.5), "One lock request at a time")
}
func testLockConfirmedByLockedScreenEndsAwayMode() {
    var m = AwayModeMachine(); m.update(ready, now: 0); m.coverNow(now: 1); m.localInput(now: 2)
    var locked = ready; locked.screenLocked = true
    m.update(locked, now: 3)
    XCTAssertEqual(m.phase, .off); XCTAssertFalse(m.wantsCover); XCTAssertFalse(m.holdsDisplayAwake)
    m.update(ready, now: 100); XCTAssertEqual(m.phase, .armedPresent, "Re-arms after the owner unlocks")
}
func testLockTimeoutReleasesDisplayButKeepsCover() {
    var m = AwayModeMachine(); m.update(ready, now: 0); m.coverNow(now: 1); m.localInput(now: 10)
    m.tick(now: 11.9); XCTAssertEqual(m.phase, .locking(.touched))
    m.tick(now: 12); XCTAssertEqual(m.phase, .lockFailed(.touched))
    XCTAssertTrue(m.wantsCover); XCTAssertFalse(m.holdsDisplayAwake, "Let the Mac's own display-sleep lock apply")
}
func testTouchAfterFailedLockRetries() {
    var m = AwayModeMachine(); m.update(ready, now: 0); m.coverNow(now: 1); m.localInput(now: 10); m.tick(now: 12)
    XCTAssertEqual(m.localInput(now: 20), .lock(.touched)); XCTAssertEqual(m.phase, .locking(.touched))
}
func testLockingKeepsTheCoverOnlyWhenItWasCovered() {
    var present = AwayModeMachine(); present.update(ready, now: 0)
    XCTAssertEqual(present.end(.stopSharing, now: 1), .lock(.stopSharing))
    XCTAssertFalse(present.wantsCover, "Someone was using the Mac; don't black it out")
    var covered = AwayModeMachine(); covered.update(ready, now: 0); covered.coverNow(now: 1)
    covered.end(.stopSharing, now: 2); XCTAssertTrue(covered.wantsCover)
}
func testEveryExitLocksExceptTurningItOffAtTheMac() {
    for reason in [AwayEndReason.stopSharing, .quit, .expiry, .battery, .phoneRequest, .screensChanged] {
        var m = AwayModeMachine(); m.update(ready, now: 0)
        XCTAssertEqual(m.end(reason, now: 1), .lock(reason), reason.rawValue)
    }
    var m = AwayModeMachine(); m.update(ready, now: 0); m.coverNow(now: 1)
    m.turnOffAtMac(); XCTAssertEqual(m.phase, .off); XCTAssertFalse(m.wantsCover)
}
func testStopSharingIsSeenThroughConditions() {
    var m = AwayModeMachine(); m.update(ready, now: 0)
    var stopped = ready; stopped.sharingWanted = false; stopped.sharingActive = false
    XCTAssertEqual(m.update(stopped, now: 1), .lock(.stopSharing))
}
func testSharingBlipDoesNotEndAwayMode() {
    var m = AwayModeMachine(); m.update(ready, now: 0); m.coverNow(now: 1)
    var blip = ready; blip.sharingActive = false
    XCTAssertNil(m.update(blip, now: 2)); XCTAssertEqual(m.phase, .armedCovered)
}
func testLosingARequirementLocks() {
    for change in [{ (c: inout AwayConditions) in c.accessibility = false }, { $0.managed = true }, { $0.safeMode = true }] {
        var m = AwayModeMachine(); m.update(ready, now: 0)
        var c = ready; change(&c)
        XCTAssertEqual(m.update(c, now: 1), .lock(.lostRequirement))
    }
}
func testMacLockedElsewhereJustEnds() {
    var m = AwayModeMachine(); m.update(ready, now: 0); m.coverNow(now: 1)
    var locked = ready; locked.screenLocked = true
    XCTAssertNil(m.update(locked, now: 2)); XCTAssertEqual(m.phase, .off)
}
func testBatteryWithoutAPhoneEndsAfterFiveMinutes() {
    var m = AwayModeMachine(); m.update(ready, now: 0)
    var battery = ready; battery.onACPower = false; battery.batteryPercent = 90
    XCTAssertNil(m.update(battery, now: 10)); XCTAssertEqual(m.batteryEndsIn(now: 10), 300)
    XCTAssertNil(m.tick(now: 309))
    XCTAssertEqual(m.tick(now: 310), .lock(.battery))
}
func testBatteryWithAPhoneEndsAtTwentyPercent() {
    var m = AwayModeMachine(); m.update(ready, now: 0)
    var c = ready; c.onACPower = false; c.phoneConnected = true; c.batteryPercent = 21
    XCTAssertNil(m.update(c, now: 1)); XCTAssertNil(m.tick(now: 10_000)); XCTAssertNil(m.batteryEndsIn(now: 10))
    c.batteryPercent = 20
    XCTAssertEqual(m.update(c, now: 10_001), .lock(.battery))
}
func testPowerReturningCancelsTheBatteryClock() {
    var m = AwayModeMachine(); m.update(ready, now: 0)
    var b = ready; b.onACPower = false; m.update(b, now: 10)
    m.update(ready, now: 200); XCTAssertNil(m.tick(now: 400)); XCTAssertNil(m.batteryEndsIn(now: 400))
}
func testExpiresAfterADayWithoutAPhone() {
    var m = AwayModeMachine(); m.update(ready, now: 0)
    var phone = ready; phone.phoneConnected = true
    m.update(phone, now: 1_000); m.update(ready, now: 2_000)
    XCTAssertNil(m.tick(now: 2_000 + 86_399))
    XCTAssertEqual(m.tick(now: 2_000 + 86_400), .lock(.expiry))
}
func testPhoneRequestLocksEvenWhenOff() {
    var m = AwayModeMachine()
    XCTAssertEqual(m.end(.phoneRequest, now: 0), .lock(.phoneRequest)); XCTAssertFalse(m.wantsCover)
    var n = AwayModeMachine(); XCTAssertNil(n.end(.stopSharing, now: 0))
}
func testRelaunchAfterACrashLocksFirstBehindTheCover() {
    var m = AwayModeMachine()
    XCTAssertEqual(m.end(.relaunchedAfterExit, now: 0), .lock(.relaunchedAfterExit))
    XCTAssertTrue(m.wantsCover); XCTAssertEqual(m.protocolState, .covered)
    m.update(ready, now: 0.5); XCTAssertEqual(m.phase, .locking(.relaunchedAfterExit), "Does not re-arm before the lock")
}
func testClockGoingBackwardsNeverCoversOrLocksEarly() {
    var m = AwayModeMachine(); m.update(ready, now: 100)
    XCTAssertNil(m.tick(now: 50)); XCTAssertEqual(m.phase, .armedPresent)
}
```
- [ ] **Step 2: Run** `-XCTest AwayModeMachineTests`; expect failures.
- [ ] **Step 3: Implement** the rules table with a private `beginLock(_ reason:, now:, covers:)` helper. Guard every elapsed-time check with `now >= start` so a backwards clock never triggers.
- [ ] **Step 4: Run** `AwayModeMachineTests`. Expected: all pass.
- [ ] **Step 5: Commit** `Add the Away mode state machine`.

---

### Task 5: Lock action and local-input classifier

**Files:**
- Modify: `RemoteHost/AwayLock.swift` (bodies only)
- Test: `RemoteTests/AwayLockTests.swift`

**Interfaces:**
- Consumes: `RemoteInputTag` (`RemoteHost/RemoteInputDriver.swift:69`), `HostScreenLock.isLocked()` (`HostKeepAwake.swift:73`).
- Produces: `HostLockShortcut.events(source:)`, `.postingRefused`; `SystemScreenLocker.requestLock()`; `AwayInputClassifier.eventMask`, `kind(of:)`, `isLocal(_:)`; `SystemAwayInputMonitor` start/stop.

- [ ] **Step 1: Write the failing tests** in `AwayLockTests` (`@MainActor`). **Never call `SystemScreenLocker().requestLock()` except in the refusal test below, and never post any event.**
```swift
func testTestProcessesCanNeverLockTheMac() {
    XCTAssertTrue(HostLockShortcut.postingRefused, "Safety: XCTest must never post the lock shortcut")
    XCTAssertFalse(SystemScreenLocker().requestLock(), "Refused before any event is created")
}
func testShortcutIsControlCommandQTaggedAsOurs() throws {
    let events = HostLockShortcut.events(source: CGEventSource(stateID: .privateState))
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events.map { $0.type }, [.keyDown, .keyUp])
    for event in events {
        XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 12)
        XCTAssertTrue(event.flags.contains(.maskControl) && event.flags.contains(.maskCommand))
        XCTAssertFalse(event.flags.contains(.maskShift) || event.flags.contains(.maskAlternate))
        XCTAssertTrue(RemoteInputTag.isInjected(event), "Our own monitor must not read the lock keystroke as a touch")
    }
}
func testEveryKindOfLocalInputIsWatched() {
    let expected: [(NSEvent.EventType, AwayInputEvent.Kind)] = [
        (.keyDown, .key), (.flagsChanged, .modifier), (.mouseMoved, .pointerMove),
        (.leftMouseDragged, .pointerMove), (.rightMouseDragged, .pointerMove), (.otherMouseDragged, .pointerMove),
        (.leftMouseDown, .click), (.rightMouseDown, .click), (.otherMouseDown, .click),
        (.scrollWheel, .scroll), (.magnify, .gesture), (.swipe, .gesture), (.rotate, .gesture), (.smartMagnify, .gesture)
    ]
    for (type, kind) in expected {
        XCTAssertEqual(AwayInputClassifier.kind(of: type), kind, "\(type)")
        XCTAssertTrue(AwayInputClassifier.eventMask.contains(NSEvent.EventTypeMask(type: type)), "\(type)")
    }
    XCTAssertNil(AwayInputClassifier.kind(of: .appKitDefined))
}
func testInjectedEventsAreNeverLocal() {
    for kind in [AwayInputEvent.Kind.key, .modifier, .pointerMove, .click, .scroll, .gesture] {
        XCTAssertFalse(AwayInputClassifier.isLocal(AwayInputEvent(kind: kind, injected: true)))
        XCTAssertTrue(AwayInputClassifier.isLocal(AwayInputEvent(kind: kind, injected: false)))
    }
}
func testMonitorStartStopIsIdempotent() {
    let monitor = SystemAwayInputMonitor()
    monitor.start { }
    monitor.start { }
    XCTAssertTrue(monitor.isRunning)
    monitor.stop(); monitor.stop()
    XCTAssertFalse(monitor.isRunning)
}
```
- [ ] **Step 2: Run** `-XCTest AwayLockTests`; expect failures.
- [ ] **Step 3: Implement.**
  - `postingRefused`: `let env = ProcessInfo.processInfo.environment; return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || env["FARSIDE_AWAY_LOCK_DISABLED"] == "1" || NSClassFromString("XCTestCase") != nil`.
  - `events(source:)`: `CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true/false)`, set `flags = Self.flags`, `RemoteInputTag.mark(event)`; return `[]` if either is nil.
  - `SystemScreenLocker.requestLock()`: `guard !HostLockShortcut.postingRefused else { return false }`; `let events = HostLockShortcut.events(source: CGEventSource(stateID: .hidSystemState))`; `guard events.count == 2 else { return false }`; post each to `.cghidEventTap`; return true. A comment explains why a public shortcut is used instead of the private `SACLockScreenImmediate`.
  - Classifier: `eventMask` is the union of the types in the test; `kind(of:)` maps them; `isLocal` = `!event.injected`.
  - `SystemAwayInputMonitor`: `start` is a no-op when running; installs `NSEvent.addGlobalMonitorForEvents(matching: AwayInputClassifier.eventMask)` and a local monitor (return the event unchanged). Handler computes, off the main actor, `kind(of: event.type)` and `RemoteInputTag.isInjected(event.cgEvent)`; if `isLocal`, hop with `Task { @MainActor in onLocalInput() }`. `stop` removes both monitors.
- [ ] **Step 4: Run** `AwayLockTests`, `PrivacyCurtainControllerTests`. Expected: pass.
- [ ] **Step 5: Commit** `Add the Away mode lock shortcut and local-input monitor`.

---

### Task 6: Sessionless cover and fail-closed relaunch record

**Files:**
- Modify: `RemoteHost/PrivacyCurtain.swift` (`PrivacyCurtainInputs` :27, `desired` :50, controller :161–322, view :324), `RemoteHost/HostWatchdogState.swift` (`HostRunRecord` :55, `HostLaunchAssessment` :190), `RemoteHost/HostWatchdogReporter.swift` (:58, :73)
- Test: `RemoteTests/AwayCurtainTests.swift`

**Interfaces:**
- Produces: `PrivacyCurtainInputs.awayCovered: Bool = false` (last field); `enum PrivacyCurtainStyle: Equatable { case sharing, away, awayLockFailed }`; `PrivacyCurtainController.style: PrivacyCurtainStyle` (get) and `func setStyle(_:)`; `var escapeLiftEnabled = true`; `var liftsOnScreenChange = true`; `var onScreensChanged: (() -> Void)?`; `func handleScreenParametersChanged()`; `PrivacyCurtainView(style:)`; `HostRunRecord.awayCoverUp: Bool?`; `HostLaunchAssessment.lockFirst: Bool`; `HostWatchdogReporter.setAwayCoverUp(_:)`.

- [ ] **Step 1: Write the failing tests** in `AwayCurtainTests` (`@MainActor` where the controller is used; build test windows the way `PrivacyCurtainControllerTests` does — tiny off-screen windows, never shown):
```swift
func testAwayCoverNeedsNoSessionAndSurvivesEveryLiftTrigger() {
    var inputs = PrivacyCurtainInputs(); inputs.awayCovered = true
    XCTAssertEqual(PrivacyCurtainPolicy.desired(inputs, currentlyUp: false), .up, "No phone, no preference")
    for change in [{ (i: inout PrivacyCurtainInputs) in i.captureHealthy = false; i.unhealthyFor = 99 },
                   { $0.locallyDismissed = true }, { $0.raiseFailed = true }, { $0.phonePaused = true },
                   { $0.accessibilityGranted = false }] {
        var i = inputs; change(&i)
        XCTAssertEqual(PrivacyCurtainPolicy.desired(i, currentlyUp: true), .up)
    }
    inputs.screenLocked = true
    XCTAssertEqual(PrivacyCurtainPolicy.desired(inputs, currentlyUp: true), .down, "macOS's own lock covers the Mac")
}
func testSharingCurtainBehaviourIsUnchangedWithoutAway() {
    XCTAssertEqual(PrivacyCurtainPolicy.desired(PrivacyCurtainInputs(), currentlyUp: true), .down)
}
func testEscapeCannotLiftTheAwayCover() async {
    let curtain = PrivacyCurtainController(makeWindows: { [Self.testWindow()] })
    _ = await curtain.raise(hooks: .init(exclude: { _ in true }, signature: { nil }), settle: .zero, verifyAfter: .zero)
    curtain.escapeLiftEnabled = false
    for t in [0.0, 0.1, 0.2] { XCTAssertFalse(curtain.handleKeyDown(keyCode: 53, timestamp: t, isRepeat: false, injected: false)) }
    XCTAssertEqual(curtain.phase, .up)
    curtain.lift()
}
func testScreenChangeNotifiesInsteadOfLiftingWhenAsked() async {
    let curtain = PrivacyCurtainController(makeWindows: { [Self.testWindow()] })
    _ = await curtain.raise(hooks: .init(exclude: { _ in true }, signature: { nil }), settle: .zero, verifyAfter: .zero)
    var notified = 0
    curtain.liftsOnScreenChange = false
    curtain.onScreensChanged = { notified += 1 }
    curtain.handleScreenParametersChanged()
    XCTAssertEqual(curtain.phase, .up); XCTAssertEqual(notified, 1)
    curtain.liftsOnScreenChange = true
    curtain.handleScreenParametersChanged()
    XCTAssertEqual(curtain.phase, .down)
}
func testStyleChangesWithoutReraising() async {
    let curtain = PrivacyCurtainController(makeWindows: { [Self.testWindow()] })
    _ = await curtain.raise(hooks: .init(exclude: { _ in true }, signature: { nil }), settle: .zero, verifyAfter: .zero)
    let ids = curtain.windowIDs
    curtain.setStyle(.away)
    XCTAssertEqual(curtain.style, .away); XCTAssertEqual(curtain.windowIDs, ids); XCTAssertEqual(curtain.phase, .up)
    curtain.lift()
}
func testOldRecordWithoutAwayFieldDecodes() throws {
    let record = HostRunRecord(pid: 1, launchID: "a", bootSession: "b", executablePath: "/x", startedAt: Date(),
                               heartbeatUptime: 1, heartbeatAt: Date())
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
    json.removeValue(forKey: "awayCoverUp")
    let decoded = try JSONDecoder().decode(HostRunRecord.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertNil(decoded.awayCoverUp)
}
func testUnexpectedExitWhileCoveredLocksFirst() {
    var previous = HostRunRecord(pid: 1, launchID: "a", bootSession: "boot", executablePath: "/x", startedAt: Date(),
                                 heartbeatUptime: 1, heartbeatAt: Date())
    previous.awayCoverUp = true
    XCTAssertTrue(HostLaunchAssessment.assess(previous: previous, ledger: nil, hangNote: nil, bootSession: "boot",
                                              previousProcessAlive: false, safeModeArgument: false).lockFirst)
    var clean = previous; clean.cleanExit = true
    XCTAssertFalse(HostLaunchAssessment.assess(previous: clean, ledger: nil, hangNote: nil, bootSession: "boot",
                                               previousProcessAlive: false, safeModeArgument: false).lockFirst)
    XCTAssertFalse(HostLaunchAssessment.assess(previous: previous, ledger: nil, hangNote: nil, bootSession: "other",
                                               previousProcessAlive: false, safeModeArgument: false).lockFirst,
                   "After a restart macOS asks for the password anyway")
    XCTAssertFalse(HostLaunchAssessment.assess(previous: previous, ledger: nil, hangNote: nil, bootSession: "boot",
                                               previousProcessAlive: true, safeModeArgument: false).lockFirst)
    var uncovered = previous; uncovered.awayCoverUp = false
    XCTAssertFalse(HostLaunchAssessment.assess(previous: uncovered, ledger: nil, hangNote: nil, bootSession: "boot",
                                               previousProcessAlive: false, safeModeArgument: false).lockFirst)
}
func testReporterPersistsTheAwayCoverAndClearsItOnCleanExit() throws { /* temp directory + WatchdogFiles(directory:) exactly as WatchdogReporterTests (RemoteTests/WatchdogTests.swift:212–270);
    setAwayCoverUp(true) → record.awayCoverUp == true and the heartbeat interval becomes the 1 s curtain interval;
    markCleanExit() → the written record has awayCoverUp == false and cleanExit == true */ }
static func testWindow() -> NSWindow { /* same as offscreenWindows() in RemoteTests/PrivacyCurtainTests.swift:145: an 8×8 borderless window at x -30 000 that is never ordered front by the test */ }
```
(Write the last two bodies fully by copying the fixtures in `RemoteTests/PrivacyCurtainTests.swift` and `RemoteTests/WatchdogTests.swift`; if an `assess` parameter name differs, follow the real signature at `HostWatchdogState.swift:197`.)
- [ ] **Step 2: Run** `-XCTest AwayCurtainTests`; expect failures.
- [ ] **Step 3: Implement (additive only).**
  - `PrivacyCurtainInputs`: `var awayCovered = false` as the last field. `desired`: first statement `if inputs.awayCovered { return inputs.screenLocked ? .down : .up }`.
  - Controller: keep `init(makeWindows:)` unchanged; when `makeWindows` is nil, build windows with `NSScreen.screens.map { Self.makeWindow(for: $0, style: self.style) }` at raise time (store the optional custom closure; resolve lazily). `setStyle(_:)` stores it and, for each window whose `contentView` is `NSHostingView<PrivacyCurtainView>`, sets `rootView = PrivacyCurtainView(style:)`. `handleKeyDown`: add `escapeLiftEnabled` to the guard. Screen observer calls `handleScreenParametersChanged()`, which lifts when `liftsOnScreenChange` else calls `onScreensChanged?()`. `makeWindow(for:style:)` with `style` defaulting to `.sharing` so existing callers compile.
  - `PrivacyCurtainView(style: PrivacyCurtainStyle = .sharing)`. Copy: `.sharing` unchanged; `.away` title "Away mode is on", line "Touching the keyboard, mouse or trackpad locks this Mac"; `.awayLockFailed` title "Away mode is on", line "Farside couldn’t lock this Mac. It locks when the display sleeps".
  - `HostRunRecord`: `var awayCoverUp: Bool?` (optional so older records and the helper still decode). `HostLaunchAssessment`: `var lockFirst = false`; in `assess`, set it inside the same "previous run ended unexpectedly in this boot" condition: `previous.awayCoverUp == true`.
  - Reporter: `setAwayCoverUp(_ up: Bool)` mirrors `setCurtainUp` (guard unchanged; `beat()`; `scheduleHeartbeat()`); heartbeat interval is the curtain interval when `curtainUp || awayCoverUp == true`; `markCleanExit` also sets `awayCoverUp = false`.
  - Do **not** touch `HostHangWatchdog.swift`.
- [ ] **Step 4: Run** `AwayCurtainTests`, `PrivacyCurtainPolicyTests`, `PrivacyCurtainControllerTests`, `CurtainCaptureExclusionTests` (if present), `WatchdogTests`, `HangWatchdogTests`; then the Mac app compile check (the helper target shares `HostWatchdogState.swift`). Expected: pass.
- [ ] **Step 5: Commit** `Let the privacy curtain cover the Mac for Away mode and record it for relaunch`.

---

### Task 7: Away mode controller

**Files:**
- Modify: `RemoteHost/AwayModeController.swift` (bodies; private helpers)
- Test: `RemoteTests/AwayModeControllerTests.swift`

**Interfaces:**
- Consumes: Task 3 (`HostPowerSourceReading`, `ManagedLockPolicy`), Task 4 (`AwayModeMachine`), Task 5 (`HostScreenLocking`, `AwayInputMonitoring`).
- Produces: `AwayModeController` behaviour below; `TimerAwayTicker` (a repeating `Timer` on the main run loop, `.common` mode, tolerance 10 %, `MainActor.assumeIsolated` in the block).

**Behaviour:**
- `refresh()`: `var c = host?.awayConditions() ?? AwayConditions()`; merge `onACPower`, `batteryPercent` from `power.snapshot()`, `managed = isManaged()`, `screenLocked = c.screenLocked || locker.isScreenLocked()`; `apply(machine.update(c, now: now()))`; then `settle()`.
- `tick()`: `refresh()` then `apply(machine.tick(now: now()))`; `settle()`.
- `localInput()` → `apply(machine.localInput(now:))`, `settle()`. `coverNow()`, `turnOffAtMac()`, `end(_:)` likewise.
- `apply(.lock(r))`: `lockRequested = true`; `host?.awayRecord("Locking this Mac: \(r.rawValue)")`; if `!locker.requestLock()` → `host?.awayRecord("Couldn’t send the lock shortcut")`.
- `lockRequestedByFarside`: true from a lock request until the machine leaves `.locking`/`.lockFailed` **and** one refresh has seen `screenLocked` (so the host's lock notification, which may arrive after the machine went `.off`, is still classified as ours); reset when the machine re-arms.
- `settle()`: input monitor runs iff `machine.phase != .off`; ticker runs iff `machine.phase != .off || lastConditions.enabled` (interval `tickInterval`); calls `host?.awayStateChanged()` only when the signature `(phase, wantsCover, holdsDisplayAwake, protocolState, unavailableReason, lowPowerMode, coversAt rounded down to 5 s, batteryEndsAt rounded to 5 s)` changed. Local input alone therefore notifies at most once per 5 s.
- `readout(available:)`: `enabled` from last conditions; `phase` mapped (`.armedPresent`→`.armed`, `.armedCovered`→`.covered`, `.locking`→`.locking`, `.lockFailed`→`.lockFailed`); `unavailable = enabled && phase == .off ? unavailableReason(last conditions) : nil`; `coversAt`/`batteryEndsAt` = `wallClock() + interval`; `lowPowerMode` from the last snapshot.
- `lockForQuit()`: if `machine.phase != .off` → `apply(machine.end(.quit, now:))` (a synchronous post; no waiting), then stop the monitor and ticker. Nothing when off.
- `lockFirstAfterRelaunch()`: `apply(machine.end(.relaunchedAfterExit, now:))`, `settle()`.

- [ ] **Step 1: Write the failing tests** with fakes: `FakeLocker` (records `requestLock` count, settable `locked`, settable `postSucceeds`), `FakePower` (settable snapshot), `FakeMonitor` (stores the callback, `isRunning`), `FakeTicker` (records start/stop), `FakeHost` (settable conditions, counts `awayStateChanged`, records messages), `var clock: TimeInterval`. Tests:
  - `testArmsAndStartsWatchingLocalInput` — ready conditions → `refresh()` → `wantsCover == false`, `holdsDisplayAwake`, monitor running, ticker running, host notified once.
  - `testCoversAfterIdleThenLocksOnTouchAndDropsTheCoverOnceLocked` — clock 121 → `tick()` → `wantsCover`; `monitor.fire()` → one `requestLock`; `locker.locked = true`, `tick()` → phase `.off`, `wantsCover == false`, monitor stopped, `lockRequestedByFarside == true`.
  - `testPhoneInputNeverLocksOrResetsIdle` — the fake monitor is never fired while the host reports `phoneConnected = true`; after 121 s → covered, 0 lock requests (phone input reaches the controller only through the monitor, which drops injected events — Task 5).
  - `testFailedPostStillTimesOutToLockFailedAndReleasesDisplay` — `postSucceeds = false`, touch while covered, clock +2 → `holdsDisplayAwake == false`, `wantsCover == true`, readout phase `.lockFailed`, host messages contain "Couldn’t send the lock shortcut".
  - `testBatteryReadFromPowerSource` — `FakePower` on battery, no phone, 300 s of ticks → one lock request with reason battery.
  - `testManagedMacNeverArms` — `isManaged` true → phase `.off`, readout `unavailable == .managed` when enabled.
  - `testTurningOffAtTheMacReleasesWithoutLocking` — covered → `turnOffAtMac()` → 0 lock requests, `wantsCover == false`, monitor stopped.
  - `testQuitLocksOnlyWhenArmed` — off → `lockForQuit()` → 0 requests; armed → 1 request; monitor and ticker stopped.
  - `testRelaunchLocksFirst` — `lockFirstAfterRelaunch()` → 1 request, `wantsCover`, `protocolState == .covered`.
  - `testLocalInputNotifiesAtMostOncePerFiveSeconds` — armed, fire the monitor 50 times across 4.9 s of clock with a tick each 0.5 s → `awayStateChanged` count grows by at most 1.
  - `testTickerStopsWhenDisabledAndOff` — enabled false → `refresh()` → ticker stopped.
  - `testReadoutCountdownUsesTheWallClock` — `wallClock` fixed at `Date(timeIntervalSince1970: 0)`, armed at clock 0, clock 20 → `readout(available: true).coversAt == Date(timeIntervalSince1970: 100)`.
- [ ] **Step 2: Run** `-XCTest AwayModeControllerTests`; expect failures.
- [ ] **Step 3: Implement** per the behaviour list.
- [ ] **Step 4: Run** `AwayModeControllerTests`, `AwayModeMachineTests`, `AwayLockTests`; Mac app compile check. Expected: pass.
- [ ] **Step 5: Commit** `Add the Away mode controller`.

---

### Task 8: Phone — status, End and lock Mac, last-known Away state

**Files:**
- Modify: `RemotePhone/RemotePhoneApp.swift` (`PhoneRemoteModel`: near `curtainSupported` :593, `capture` handling :1109–1125, `notice(for:at:)` :1189, session end/`disconnect`), `RemotePhone/NativeSessionView.swift` (controls near "End session" :703; the pills/notice area), `RemotePhone/HomeView.swift` (Mac list row caption and the forget-this-Mac action)
- Create: `RemotePhone/AwayMemory.swift` (target membership: the `RemotePhone` folder is a folder source — confirm it is picked up; if not, report to the orchestrator instead of editing `project.yml`)
- Test: `RemotePhoneTests/AwayPhoneTests.swift`

**Interfaces:**
- Consumes (Task 2): `SessionFeature.away`, `RemoteAction.away`, `AwayModeState(reported:)`, `PhoneSessionNotice.awayCovered`, `.awayCantUnlock`.
- Produces: `PhoneRemoteModel.awaySupported: Bool`, `awayState: AwayModeState?`, `canLockMac: Bool`, `@discardableResult func endAndLockMac() -> Bool`; `struct AwayMemory { static let defaultsKey = "awayLastKnownByMac"; init(defaults:); func wasOn(forRoom:) -> Bool; func remember(_ state: AwayModeState, forRoom:); func forget(room:) }` keyed by `String(SecureRandom.digest("farside-away|" + room).prefix(24))` (never store the raw room).

Copy (exact): button "End and lock Mac" (accessibility id `remote.endAndLockMac`); chip "Mac covered · locks if touched"; Mac list caption "Away mode was on when you last connected"; locked departure notice gains " Away mode can’t unlock it." when the last-known state for this Mac was armed or covered.

- [ ] **Step 1: Write the failing tests** in `AwayPhoneTests`, using the fixture pattern in `RemotePhoneTests/MacParityPhoneTests.swift` (deliver `geometry` then `capture` through `model.connection.onControl?(try JSONEncoder().encode(action))`, capture outgoing messages the way that file does):
  - `testAwayStateIsReadOnlyFromAMacThatAdvertisesIt` — capture without the feature but with `away: "covered"` → `awayState == nil`; with `features: [SessionFeature.away]` → `.covered`; unknown value → `.off`.
  - `testEndAndLockSendsLockMacOnlyWithControl` — feature + control allowed → `endAndLockMac()` returns true and the sent action is exactly `lockMac` with the current epoch and no other fields; control not allowed (`viewing` x = 0) → false, nothing sent; feature absent → false.
  - `testSessionEndsLocallyIfTheMacDoesNotWithinFiveSeconds` — after `endAndLockMac()`, with no host reply, the model disconnects after ≤ 5 s (inject or shorten the delay via an internal `static var lockEndGrace: TimeInterval = 5` set to 0.1 in the test).
  - `testLockedNoticeMentionsAwayOnlyWhenItWasOn` — `PhoneRemoteModel.notice(for: .locked, at: date, awayWasOn: true)` ends with "Away mode can’t unlock it."; `awayWasOn: false` equals today's text.
  - `testAwayMemoryIsPerMacAndForgettable` — isolated `UserDefaults(suiteName:)`; remember `.covered` for room A → `wasOn(A)`, not B; remember `.off` → false; `forget(A)` → false; stored keys never contain the raw room string.
- [ ] **Step 2: Run** the phone test command with `AwayPhoneTests`; expect failures.
- [ ] **Step 3: Implement.** Mirror `curtainSupported`/`canChangeCurtain`/`setMacCurtain` for `awaySupported`/`canLockMac`/`endAndLockMac` (send `RemoteAction(action: "lockMac", epoch: geometryEpoch)`, then schedule the local disconnect after `lockEndGrace` unless the session already ended). In `capture` handling set `awayState = awaySupported ? AwayModeState(reported: action.away) : nil` and remember it in `AwayMemory` for the current room whenever it changes. Add `awayWasOn: Bool = false` to `notice(for:at:)` and pass `AwayMemory().wasOn(forRoom:)` where the departure notice is built. UI: an "End and lock Mac" button beside "End session" when `awaySupported` (disabled with 0.45 opacity unless `canLockMac`, as the curtain toggle does); a small chip with `PhoneSessionNotice.awayCovered` while `awayState == .covered` in the existing top-pill area (follow the existing pill style; keep it out of the D36 panel height math); a caption under a Mac's row in the Mac list when `AwayMemory().wasOn(forRoom:)`; call `AwayMemory().forget(room:)` wherever the phone forgets a Mac.
- [ ] **Step 4: Run** `AwayPhoneTests`, `MacParityPhoneTests`, `SessionLifecycleTests`, `PhoneParityTests`. Build the app for the simulator (the test run does). Shut down the simulator. Expected: pass.
- [ ] **Step 5: Commit** `Show Away mode on the phone and add End and lock Mac`.

---

### Task 9: Mac UI — setting, turn-on sheet, popover, warnings, fallback copy

**Files:**
- Modify: `RemoteHost/HostAwayPresentation.swift` (bodies + constants), `RemoteHost/HostSettingsView.swift` (`sharingSection` :57–89), `RemoteHost/HostPopoverView.swift` (the toggles area near :85), `RemoteHost/HostPresentation.swift` only if a shared helper is needed
- Test: `RemoteTests/AwayPresentationTests.swift`

**Interfaces:**
- Consumes (Task 0): `HostViewState.awayMode`, `.awayIntroShown`, `.away: HostAwayReadout`, `.lockWarning: HostLockWarning?`; `HostActions.setAwayMode`, `.coverNow`, `.dismissLockWarning`, `.openLockScreenSettings`, `.openSystemSettings(.accessibility)`.
- Produces: `HostAwayCopy` constants/functions below (Task 10 uses `lockScreenSettingsURL`).

Copy (exact):

| Key | Text |
|---|---|
| `settingTitle` | "Away mode" |
| `settingSubtitle` | "Keep this Mac unlocked for your iPhone while you’re away. The screen is covered and the Mac locks if anyone touches it." |
| `introTitle` | "Turn on Away mode?" |
| `introBody` | the three paragraphs of spec §2 "Turn-on sheet", verbatim, as an array of three strings |
| `introConfirm` / `introCancel` | "Turn On Away Mode" / "Cancel" |
| `statusLine` armed | "Away mode · covers in 1:40" (`countdown` of `coversAt - now`, m:ss, never negative) |
| `statusLine` covered | "Away · covered, locks if touched" |
| `statusLine` locking | "Away · locking this Mac…" |
| `statusLine` lockFailed | "Away · couldn’t lock this Mac. It locks when the display sleeps." |
| `statusLine` off/unavailable/!available | nil |
| `warningLine` battery | "On battery — Away mode ends in 4:12" (when `batteryEndsAt` set) |
| `warningLine` `.managed` | "Your organisation manages this Mac’s lock settings — Away mode unavailable" |
| `warningLine` `.needsAccessibility` | "Needs Accessibility" |
| `warningLine` `.onBattery` | "Connect power to use Away mode" |
| `warningLine` `.sharingOff` | "Starts when sharing is on" |
| `warningLine` `.safeMode` | "Paused after repeated crashes" |
| `warningLine` `.macLocked` | nil |
| `warningLine` low power (lowest priority) | "Low Power Mode is on" |
| `coverNowTitle` / `turnOffTitle` | "Cover now" / "Turn off" |
| `lockWarningText(.lockedWhileSharing(at))` | "Your Mac locked at 11:48 PM while sharing, so your iPhone couldn’t reach it. Farside can’t unlock it. To stay reachable, keep this Mac awake and unlocked" + (awayAvailable ? ", or turn on Away mode." : ".") |
| `lockWarningText(.screenSaverLocked(at, awayArmed))` | "Your Mac’s screen saver locked it at 11:48 PM" + (awayArmed ? " while Away mode was on" : "") + ". To stay reachable, change when the screen saver starts or when a password is required in Lock Screen settings." |
| `lockScreenSettingsTitle` | "Lock Screen Settings…" |
| `dismissTitle` | "Dismiss" |
| `keepAwakeSubtitle` | "While sharing is on. Your iPhone can reach this Mac only while it’s awake and unlocked." |

Times use `date.formatted(date: .omitted, time: .shortened)`; tests pass a fixed date and compare against the same formatter output.

- [ ] **Step 1: Write the failing tests** in `AwayPresentationTests`: one assertion per table row (build `HostAwayReadout` values and `now`), plus `testCountdownFormatting` (0 → "0:00", 100 → "1:40", 252 → "4:12", 3600 → "60:00", −5 → "0:00"), `testNothingShowsWhenTheGateIsOff` (`available: false` → both lines nil even if enabled/armed), `testCopyNeverClaimsLockedOrSecureWhileArmed` (armed and covered status lines contain neither "locked" nor "secure", case-insensitive), `testLockScreenLinkIsTheLockScreenPane` (`lockScreenSettingsURL.absoluteString == "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"`).
- [ ] **Step 2: Run** `-XCTest AwayPresentationTests`; expect failures.
- [ ] **Step 3: Implement** `HostAwayCopy`, then the views (use `HostSettingsSection`/`HostSettingsRow`/`HostSwitch`/`HostToggleRow` — never `GroupBox`, per AGENTS.md):
  - Settings `sharingSection`: Keep-awake subtitle becomes `HostAwayCopy.keepAwakeSubtitle`. Directly under it, only when `state.away.available`: an "Away mode" row with `settingSubtitle` and a `HostSwitch` (id `farside.settings.awayMode`). Turning it on when `!state.awayIntroShown` presents a sheet/`confirmationDialog` with `introTitle`, the three paragraphs and the two buttons; only Confirm calls `actions.setAwayMode(true)`. Turning it on when the intro was seen calls `setAwayMode(true)` directly; off calls `setAwayMode(false)`. Below the row, `warningLine` (secondary text) and, for `.needsAccessibility`, an "Open Settings" button calling `actions.openSystemSettings(.accessibility)`.
  - Popover: when `state.away.available && state.awayMode`: a line with `statusLine` rendered in a `TimelineView(.periodic(from: .now, by: 1))` so the countdown ticks; buttons "Cover now" (only when armed; id `farside.popover.awayCoverNow`) and "Turn off" (`setAwayMode(false)`; id `farside.popover.awayTurnOff`); `warningLine` below.
  - Both surfaces: when `state.lockWarning` is set, a warning block with `lockWarningText(_, awayAvailable: state.away.available)`, a "Lock Screen Settings…" button (`actions.openLockScreenSettings`) for the screen-saver case, and "Dismiss" (`actions.dismissLockWarning`). This block shows **regardless of the gate** — it is the 1.0 fallback.
- [ ] **Step 4: Run** `AwayPresentationTests`, `HostPresentationTests`; Mac app compile check; and compile the `HostUISnapshotTests` target (`-scheme HostUISnapshotTests build-for-testing`), which also compiles the settings and popover views with only the files Task 0 registered for it (`AwayModeMachine.swift`, `HostAwayEnvironment.swift`, `HostAwayPresentation.swift`, `AwayModeProtocol.swift`) — the views may use only types from those files and the target's existing sources. If `HostUISnapshotTests` has snapshot fixtures that now differ because of the new Keep-awake subtitle, report it; do not re-record snapshots.
- [ ] **Step 5: Commit** `Add the Away mode setting, popover status and lock warning to the Mac`.

---

### Task 10: Wire Away mode into the Mac host

**Files:**
- Modify: `RemoteHost/HostModel.swift`, `RemoteHost/HostReadiness.swift` (`HostPreferences` :210)
- Test: `RemoteTests/AwayModeControllerTests.swift` (add `AwayPreferencesTests` class in the same file), plus full core suite

**Interfaces:**
- Consumes: everything above.
- Produces: the working feature (behind the gate).

- [ ] **Step 1: Write the failing test** (`AwayPreferencesTests`): isolated `UserDefaults(suiteName:)` → `HostPreferences(defaults:).awayMode == false`, `.awayIntroShown == false`; set both → read back; keys are `"awayModeWhileSharing"` and `"awayModeIntroShown"`. Run; expect a compile failure.
- [ ] **Step 2: Preferences.** Add `awayMode` and `awayIntroShown` to `HostPreferences` (plain `bool(forKey:)`, default false, one-line comment "Off unless the person turns it on at the Mac").
- [ ] **Step 3: Model wiring in `HostModel.swift`** (keep the Away code together under `// MARK: Away mode`; keep edits elsewhere to single lines):
  1. State: `@Published private(set) var awayModeEnabled: Bool`, `@Published private(set) var awayIntroShown: Bool`, `@Published private(set) var lockWarning: HostLockWarning?`, `private var lockWarnings = HostLockWarningTracker()`, `private let awayAvailable = AwayModeGate.isEnabled()`, and `private lazy var away: AwayModeController` built with `SystemScreenLocker()`, `SystemPowerSource()`, `{ ManagedLockPolicy.isManaged() }`, `SystemAwayInputMonitor()`, `TimerAwayTicker()`, `{ ProcessInfo.processInfo.systemUptime }`, `{ Date() }`. Under `#if DEBUG`, when `HostE2E.active != nil`, use a private recording locker whose `requestLock()` returns true without posting (E2E must never lock a real Mac).
  2. `init`: read both preferences; set `away.host = self`; **immediately after `startWatchdog()`**, `if watchdog?.assessment.lockFirst == true { events.record(.recovery, "Locking after an unexpected exit while Away mode covered the screen"); away.lockFirstAfterRelaunch() }` — this runs even if the gate is now off (fail closed); then `away.refresh()`.
  3. `AwayModeHost` conformance (extension in `HostModel.swift`): `awayConditions()` = `AwayConditions(enabled: awayAvailable && awayModeEnabled, sharingWanted: wantsSharing, sharingActive: active, accessibility: accessibilityPermission.isGranted, screenLocked: screenLocked, phoneConnected: connection.connected && !phonePause.isPaused, safeMode: crashLoopStopped)`; `awayStateChanged()` → `reconcileCurtain(); updatePowerAssertions(); watchdog?.setAwayCoverUp(away.wantsCover); sendCaptureHealth(captureHealthy); objectWillChange.send()`; `awayRecord` → `events.record(.curtain, "Away mode: " + message)`.
  4. Call `away.refresh()` at the end of: `start(display:)`, `stop()`, `stopSharing()` (see 6), `resumeSharing()`, `phoneConnected()`, `endCapture()`, `handleAvailability(_:)`, the Accessibility branch of `pollPermissions()` and `applyPermissionRefresh`, and where `crashLoopStopped` changes.
  5. `setAwayMode(_ enabled:)`: `awayModeEnabled = enabled; preferences.awayMode = enabled`; if enabled, `awayIntroShown = true; preferences.awayIntroShown = true`; if not, `away.turnOffAtMac()`; record "Away mode on/off"; `away.refresh()`. `coverNow()` → `away.coverNow()`. `dismissLockWarning()` → `lockWarning = nil`. `openLockScreenSettings()` → `NSWorkspace.shared.open(HostAwayCopy.lockScreenSettingsURL)`.
  6. Exits: in `stopSharing()`, call `away.end(.stopSharing)` **before** `stop()` (the refresh inside sees `wantsSharing == false` anyway; the explicit call keeps the order obvious). In `stopForTermination()`, first line: `away.lockForQuit()`. `pauseSharing` goes through `stopSharing` (locks, per spec "every exit").
  7. Curtain: `reconcileCurtain()` sets `awayCovered: away.wantsCover` on the inputs, and before acting sets `curtain.escapeLiftEnabled = !away.wantsCover`, `curtain.liftsOnScreenChange = !away.wantsCover`, and `curtain.setStyle(away.wantsCover ? (away.readout(available: true).phase == .lockFailed ? .awayLockFailed : .away) : .sharing)`. `raiseCurtain()`: when `away.wantsCover`, use hooks `exclude: { ids in if session live { _ = await capture.excludeWindows(ids) }; return true }`, `signature: { nil }` (the Away cover never waits on or is undone by the stream). `liftCurtain()`: do not call `curtain.lift()` when `away.wantsCover` (sharing teardown must never uncover a Mac Away mode is covering). `capture.onExclusionLost`: return early when `away.wantsCover`. In `init`: `curtain.onScreensChanged = { [weak self] in self?.away.end(.screensChanged) }`.
  8. Phone connects while covered: where capture start succeeds in `beginCapture()`, if `curtain.phase != .down`, `Task { _ = await capture.excludeWindows(curtain.windowIDs) }` so the phone sees the desktop rather than the cover; the cover itself is never lowered or re-raised.
  9. Power: `updatePowerAssertions()` passes `awayArmed: away.holdsDisplayAwake`. Note `stop()` calls `releaseKeepAwake()` directly — after it, `away.refresh()` → `awayStateChanged()` → `updatePowerAssertions()` re-evaluates (with `sharing: active == false` nothing is held, which is correct).
  10. Protocol: `advertisedFeatures` appends `SessionFeature.away` when `awayAvailable`; `sendCaptureHealth` passes `away: awayAvailable ? away.protocolState.rawValue : nil`. In `receiveSessionExtension`, add `case "lockMac":` with the same guard as `"curtain"` (`current, controlEffective, !phonePause.isPaused`, else `sendCaptureHealth` and return), then `events.record(.curtain, "Phone asked to lock this Mac")` and `away.end(.phoneRequest)`. Only honour it when `awayAvailable`.
  11. Lock warning: observe `DistributedNotificationCenter` `"com.apple.screensaver.didstart"` / `"com.apple.screensaver.didstop"` → `lockWarnings.screenSaverStarted(uptime:)` / `screenSaverStopped()`. In `handleAvailability`, on `.screenLocked` (only the first transition), compute `lockWarnings.screenLocked(at: Date(), uptime: …, sharingWanted: wantsSharing, awayArmed: away.machine.isArmed, lockRequestedByFarside: away.lockRequestedByFarside, idleSeconds: HostIdle.systemIdleSeconds())` **before** `away.refresh()`; if non-nil, set `lockWarning` and record it.
  12. View state: pass `awayMode: awayModeEnabled`, `awayIntroShown: awayIntroShown`, `away: away.readout(available: awayAvailable)`, `lockWarning: lockWarning` wherever `HostViewState` is built.
  13. Diagnostics: add one line to the event log on each phase change is enough (via `awayRecord`); do not add fields to `HostDiagnosticsReport`.
- [ ] **Step 4: Build and run.** Mac app compile check; core `build-for-testing`; run the **whole** core bundle: `lockf -k /tmp/farside-xcodebuild.lock xcrun xctest "$DD/Build/Products/Debug/RemoteCoreTests.xctest"`. Expected: all Away classes pass; no new failures elsewhere (report counts; compare with the pre-change baseline the orchestrator gives you). Never launch the app.
- [ ] **Step 5: Self-check the wiring against the Review Focus list** and write down, in the commit body, how each item is handled in `HostModel.swift` (line numbers).
- [ ] **Step 6: Commit** `Wire Away mode into the Mac host behind its release gate`.

---

### Wave 4: whole-branch review and records (orchestrator)

- Fresh security-focused reviewer over `git diff pocketdesk-remote-chat...farside-away-mode`: lock can't be bypassed by injected events; no path posts the lock shortcut from tests/E2E; no password/setting writes; the cover can't be lifted by Esc, capture loss or teardown while Away wants it; relaunch fails closed; `lockMac` needs control authority; gate off means no `away.1`, no `away` field, no UI except the lock warning and fallback copy.
- Full suites: core bundle, host app build, `RemotePhoneTests` on "Farside Away iPhone", iOS app build.
- `Docs/IMPLEMENTATION-PLAN.md` ledger entry at the top; `PRODUCT.md` decision row (next free D number after checking every branch) and status: built behind the gate, physically unverified, S1/S2 pending Roshan.
