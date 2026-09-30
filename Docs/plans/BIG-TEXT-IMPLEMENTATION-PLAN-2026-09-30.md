# Big Text Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While a phone is connected, the Mac switches the streamed display to a larger "looks like" mode that the phone chose and saved for this phone–Mac pair, and puts everything back when the session ends.

**Architecture:** Pure, injectable units first (protocol fields, step builder, phone memory, own-change recogniser, window restore planner, controller state machine), each with its own XCTest class; then two integration tasks wire them into `RemoteHostModel` and `PhoneRemoteModel`; then UI. A scaffold task pre-creates every new file with its interface so parallel agents never edit the same file or the generated Xcode project.

**Tech Stack:** Swift 6, SwiftUI, CoreGraphics display configuration (`CGConfigureDisplayWithDisplayMode`, `.forAppOnly`, `CGDisplayRegisterReconfigurationCallback`), ScreenCaptureKit, Accessibility (`AXUIElement`), XCTest, XcodeGen.

**Spec:** `Docs/plans/BIG-TEXT-DESIGN-2026-09-30.md` (revision 2, commit `494a009`), as amended by Task 0.

## Global Constraints

- Deployment: iOS/iPadOS 26+, macOS 26+, Apple silicon only (D35). New `RemoteShared` files must compile for iOS **and** macOS (no AppKit/CoreGraphics display APIs there).
- Capability string: `SessionFeature.displayScale = "display.scale.1"`; not in the static `SessionFeature.host` list; advertised only when the Mac setting allows it and Accessibility is granted.
- At most 4 steps; widths/heights 1…20 000 points; nearest-step tolerance 10 %; phone debounce 0.6 s; phone pending timeout 8 s; host own-change timeout 10 s; settle 0.3 s; poll 0.1 s; disconnect grace 20 s.
- Mode changes use `CGCompleteDisplayConfiguration(config, .forAppOnly)` only. Never `.permanently`, never `.forSession`.
- Window restore reads position, size, subrole, minimised and full-screen attributes only. **Never read window titles or contents**; nothing is written to disk.
- Phone storage key prefix `"farside-bigtext|"`; `UserDefaults` key `"bigTextByMac"`; host preference key `"allowBigTextFromPhone"` default `true`.
- User-facing copy (exact): "Making text bigger…", "Restoring text size…", "Couldn't change text size", "Big Text needs Accessibility permission on your Mac.", "This display doesn't offer larger sizes.", "Big Text is turned off on this Mac.", "Couldn't change text size. If an app is full screen on your Mac, exit full screen and try again.", "Already at the largest size", "Restore normal size", "Allow a connected phone to change text size".
- Code comments only where the *why* is non-obvious (repo and user rule). No docstrings restating names.
- Repo rules (AGENTS.md): wrap every `xcodebuild`/`xctest` in `lockf -k /tmp/farside-xcodebuild.lock`; never install to the phone or `/Applications` from a worktree; never use `script/build_and_run.sh` here; shut down simulators you boot; commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Clicks immediately after a size change** must land where the pointer is, not at the old coordinates (stale `SCDisplay.frame`). Test: Task 7b `BigTextRefreshTests.testRejectsAFrameThatDisagreesWithCoreGraphics`, plus the physical gate in Task 11.
2. **The person changes resolution in System Settings mid-session**: their choice is kept, never overwritten on session end. Tests: Task 4 `testAddedDisplayIsForeign`/`testTimeoutIsForeign`, Task 5 `testForeignChangeForgetsBaselineAndStopsTheSession`.
3. **The Mac is locked or asleep when the session ends**: the normal size comes back after unlock/wake. Test: Task 5 `testFailedRestoreStaysPendingUntilRetried`.
4. **Several quick step taps**: one debounced request on the phone, latest-wins on the host, one visible change. Tests: Task 5 `testLatestRequestWins`, Task 9 `testRapidChoicesSendOnlyTheLast`.
5. **A saved level for one monitor is never applied to another** (IDs change after reboot; two monitors share a name). Test: Task 3 `testAmbiguousNamesNeverGuess`.

---

## Execution model (read first)

- **Waves.** Task 0 runs alone. Wave 1: Tasks 1, 2, 3, 4, 6, 7a in parallel. Wave 2: Tasks 5 and 9 in parallel. Wave 3: Tasks 7b and 10 in parallel. Wave 4: Task 8, then Task 11. Each task lists what it consumes.
- **One worktree per task.** The orchestrator creates `git worktree add -b bigtext/<task> .claude/worktrees/bigtext-<task> <farside-big-text head>` for each task after the previous wave is merged into `farside-big-text`.
- **Never commit `PocketDesktop.xcodeproj` or `project.yml` in Tasks 1–10.** Task 0 registers every new file. If `xcodegen generate` is needed locally, run it, then `git checkout -- PocketDesktop.xcodeproj` before committing.
- **Builds.** Each task uses its own DerivedData: `DD=/Volumes/Studio/Development/Caches/Xcode/DerivedData/bigtext-<task>`. Check `df -h /Volumes/Studio` first; stop and report if under 20 GB free. Delete your DerivedData when the task is merged.
- **Mac core test command** (used by Tasks 1–7b):
  ```bash
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme RemoteCoreTests -destination platform=macOS -derivedDataPath "$DD" -collect-test-diagnostics never build-for-testing
  lockf -k /tmp/farside-xcodebuild.lock xcrun xctest -XCTest <ClassName> "$DD/Build/Products/Debug/RemoteCoreTests.xctest"
  ```
- **Phone test command** (Tasks 9–10), simulator created in Task 0:
  ```bash
  SIM=$(xcrun simctl list devices -j | python3 -c "import json,sys;print([d['udid'] for r in json.load(sys.stdin)['devices'].values() for d in r if d['name']=='Farside BigText iPhone'][0])")
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -destination "id=$SIM" -derivedDataPath "$DD" -parallel-testing-enabled NO -collect-test-diagnostics never -only-testing:RemotePhoneTests/<ClassName> test
  xcrun simctl shutdown "$SIM"
  ```
- **Report** exact pass/fail/skip counts. A failing unrelated pre-existing test is reported, not "fixed".

---

### Task 0: Scaffold, spec amendments, simulator (orchestrator, alone)

**Files:**
- Create (stubs, contents below): `RemoteShared/BigTextProtocol.swift`, `RemoteShared/BigTextMemory.swift`, `RemoteHost/BigTextModes.swift`, `RemoteHost/BigTextDisplaySwitcher.swift`, `RemoteHost/BigTextWindows.swift`, `RemoteHost/BigTextController.swift`
- Create (empty test classes): `RemoteTests/BigTextProtocolTests.swift`, `RemoteTests/BigTextStepsTests.swift`, `RemoteTests/BigTextMemoryTests.swift`, `RemoteTests/BigTextRecognizerTests.swift`, `RemoteTests/BigTextWindowTests.swift`, `RemoteTests/BigTextControllerTests.swift`, `RemoteTests/BigTextHostWiringTests.swift`, `RemotePhoneTests/BigTextPhoneTests.swift`, `RemotePhoneUITests/BigTextUITests.swift`
- Modify: `project.yml` (RemoteCoreTests `sources` list, line ~242), `PocketDesktop.xcodeproj` (regenerated), `Docs/plans/BIG-TEXT-DESIGN-2026-09-30.md`

**Interfaces:** Produces every type name used below. Stub bodies return empty values so everything compiles and each task's new tests fail first.

- [ ] **Step 1: Amend the spec** (source-verified contradictions from the 30 Sep code maps). Edit `BIG-TEXT-DESIGN-2026-09-30.md`:
  - §2 "Session-only off": replace the Display-key paragraph with: "There is no Display key (Display is a panel row shown only on multi-display Macs). The fixed D36 panel gains a **Big Text** toggle row, shown only when the Mac supports Big Text and this phone has a saved level; the panel height grows by one row when it is shown. Settings → Picture also has **Off for this session**, which is how landscape and iPad (one-row overlay → gear → Settings) reach it."
  - §2 "When it cannot apply": replace the full-screen bullet with "Couldn't change text size. If an app is full screen on your Mac, exit full screen and try again." (CoreGraphics does not report *why* a configuration failed.)
  - §4.5: "On an unexpected disconnect" → "On any phone disconnect (the host cannot tell a phone's End from a lost network)".
  - §4.6 Normal quit: "window restore is skipped on quit (quit must stay prompt)".
  - §5 Snapshot: identity is the retained `AXUIElement` reference (CF equality); a window that no longer answers position/size is gone. Drop the `CGWindowID` pairing (it needs a private API).
  - §6: `scaleError` values are `noAccessibility, unsupported, disabled, busy, failed` (no `fullScreen`).
  - §7: add "`BigTextMemory.forget(room:)` is called from the phone's Forget-this-Mac path; `DisplayMemory` has no such hook today."
- [ ] **Step 2: Write the stub sources.**

`RemoteShared/BigTextProtocol.swift`:
```swift
import Foundation

enum BigTextLimits {
    static let maxSteps = 4
    static let widthRange: ClosedRange<Double> = 1...20_000
}

struct ScaleStep: Codable, Equatable {
    var width: Double
    var height: Double

    func validate(below baselineWidth: Double) throws {}
}

enum BigTextError: String, Codable, CaseIterable {
    case noAccessibility, unsupported, disabled, busy, failed
}
```

`RemoteShared/BigTextMemory.swift`:
```swift
import Foundation

struct BigTextMemory {
    struct Entry: Codable, Equatable {
        var display: DisplayMemory.Choice
        var looksLikeWidth: Double
    }

    static let defaultsKey = "bigTextByMac"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func macKey(room: String) -> String { String(SecureRandom.digest("farside-bigtext|" + room).prefix(24)) }

    func width(forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) -> Double? { nil }
    func remember(_ width: Double?, forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) {}
    func forget(room: String) {}
}
```

`RemoteHost/BigTextModes.swift`:
```swift
import CoreGraphics

struct DisplayModeInfo: Equatable {
    let ioModeID: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let usableForDesktopGUI: Bool

    var isHiDPI: Bool { pixelWidth == width * 2 && pixelHeight == height * 2 }
    var aspect: Double { Double(width) / Double(height) }
    var step: ScaleStep { ScaleStep(width: Double(width), height: Double(height)) }
}

enum BigTextSteps {
    static let nearestTolerance = 0.10
    static func steps(baseline: DisplayModeInfo, modes: [DisplayModeInfo]) -> [DisplayModeInfo] { [] }
    static func spread<T>(_ items: [T], count: Int) -> [T] { [] }
    static func nearest(to width: Double, in steps: [DisplayModeInfo]) -> DisplayModeInfo? { nil }
}
```

`RemoteHost/BigTextDisplaySwitcher.swift`:
```swift
import CoreGraphics
import Foundation

enum DisplayModeApplyResult: Equatable { case applied, failed(Int32) }

@MainActor
protocol DisplayModeSwitching: AnyObject {
    func currentMode(of display: CGDirectDisplayID) -> DisplayModeInfo?
    func modes(of display: CGDirectDisplayID) -> [DisplayModeInfo]
    func apply(_ mode: DisplayModeInfo, to display: CGDirectDisplayID) -> DisplayModeApplyResult
    func onlineDisplays() -> Set<CGDirectDisplayID>
}

struct DisplayReconfigurationEvent: Equatable {
    let display: CGDirectDisplayID
    let flags: CGDisplayChangeSummaryFlags
}

struct OwnChangeRecognizer {
    enum Verdict: Equatable { case pending, ours, foreign }
    static let timeout: TimeInterval = 10

    let display: CGDirectDisplayID
    let target: DisplayModeInfo
    let onlineBefore: Set<CGDirectDisplayID>
    let startedAt: TimeInterval

    mutating func observe(_ event: DisplayReconfigurationEvent) {}
    func verdict(now: TimeInterval, online: Set<CGDirectDisplayID>, current: DisplayModeInfo?) -> Verdict { .pending }
}
```

`RemoteHost/BigTextWindows.swift`:
```swift
import AppKit
import ApplicationServices

final class WindowRef: Hashable, @unchecked Sendable {
    let pid: pid_t
    let element: AnyObject

    init(pid: pid_t, element: AnyObject) {
        self.pid = pid
        self.element = element
    }

    static func == (lhs: WindowRef, rhs: WindowRef) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

protocol WindowAccess: AnyObject, Sendable {
    func standardWindows(within bounds: CGRect, pids: [pid_t]) -> [WindowRef]
    func frame(of window: WindowRef) -> CGRect?
    func setFrame(_ frame: CGRect, of window: WindowRef) -> Bool
    var stageManagerEnabled: Bool { get }
}

enum WindowRestorePlan {
    static let tolerance: CGFloat = 2
    static func moves(before: [WindowRef: CGRect], after: [WindowRef: CGRect], now: [WindowRef: CGRect]) -> [(WindowRef, CGRect)] { [] }
}

protocol BigTextWindowKeeping: AnyObject {
    var hasSnapshot: Bool { get }
    func snapshot(within bounds: CGRect, pids: [pid_t]) async
    func recordSettled() async
    @discardableResult func restore() async -> Int
    func discard()
}
```

`RemoteHost/BigTextController.swift`:
```swift
import CoreGraphics
import Foundation

struct BigTextOffer: Equatable {
    let baseline: DisplayModeInfo
    let steps: [DisplayModeInfo]
    let current: DisplayModeInfo
}

@MainActor
protocol BigTextHost: AnyObject {
    func bigTextQuiesce()
    func bigTextResume(display: CGDirectDisplayID) async -> Bool
    func bigTextReply(display: CGDirectDisplayID, error: BigTextError?)
    func bigTextForeignChange()
    func bigTextStateChanged()
    func bigTextDisplayBounds(_ display: CGDirectDisplayID) -> CGRect
    func bigTextRunningAppPIDs() -> [pid_t]
}

@MainActor
final class BigTextController {
    enum Phase: Equatable { case idle, changing, applied, restoring }
    enum RestoreReason: String { case sessionEnded, displaySwitched, sessionOff, restoreButton }

    private(set) var phase: Phase = .idle
    private(set) var display: CGDirectDisplayID?
    private(set) var baseline: DisplayModeInfo?
    private(set) var current: DisplayModeInfo?
    private(set) var restorePending = false
    weak var host: BigTextHost?

    var isEngaged: Bool { phase != .idle || current != nil || restorePending }
    var isChanging: Bool { phase == .changing || phase == .restoring }

    init(switcher: DisplayModeSwitching, windows: BigTextWindowKeeping,
         now: @escaping () -> TimeInterval, sleep: @escaping (TimeInterval) async -> Void) {}

    func offer(for display: CGDirectDisplayID) -> BigTextOffer? { nil }
    func request(display: CGDirectDisplayID, looksLikeWidth: Double, allowed: Bool, accessibilityGranted: Bool) {}
    func observe(_ event: DisplayReconfigurationEvent) {}
    func sessionEnded(_ reason: RestoreReason) {}
    func connectionLost() {}
    func sessionResumed() {}
    func retryPendingRestore() {}
    func restoreForTermination() {}
    func drain() async {}

    static func describe(_ descriptor: DisplayDescriptor, offer: BigTextOffer?) -> DisplayDescriptor { descriptor }
}
```

Each empty test file:
```swift
import XCTest

final class BigTextProtocolTests: XCTestCase {}
```
(Class names: `BigTextProtocolTests`, `BigTextStepsTests`, `BigTextMemoryTests`, `BigTextRecognizerTests`, `BigTextWindowTests`, `BigTextControllerTests`, `BigTextHostWiringTests`. The phone files use `@testable import PocketDeskRemote` and classes `BigTextPhoneTests` (`@MainActor`) and `BigTextUITests`.)

- [ ] **Step 3: Register host files for core tests.** In `project.yml` RemoteCoreTests `sources`, append after `RemoteHost/HostLoadMonitor.swift`: `RemoteHost/BigTextModes.swift, RemoteHost/BigTextDisplaySwitcher.swift, RemoteHost/BigTextWindows.swift, RemoteHost/BigTextController.swift`. (`RemoteShared`, `RemoteTests`, `RemotePhoneTests`, `RemotePhoneUITests` are folder sources and pick up new files automatically.)
- [ ] **Step 4: Regenerate and build everything once.**
  ```bash
  xcodegen generate
  git diff --stat PocketDesktop.xcodeproj   # if two CopyFiles block IDs swapped, revert that noise per the ledger note
  DD=/Volumes/Studio/Development/Caches/Xcode/DerivedData/bigtext-scaffold
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme RemoteCoreTests -destination platform=macOS -derivedDataPath "$DD" -collect-test-diagnostics never build-for-testing
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemoteHost -destination platform=macOS -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" build-for-testing
  ```
  Expected: all three succeed.
- [ ] **Step 5: Create the phone simulator.** `xcrun simctl create "Farside BigText iPhone" "iPhone 17"` (if that device type is missing, list with `xcrun simctl list devicetypes` and pick the newest iPhone). Do not touch other simulators.
- [ ] **Step 6: Commit** `Scaffold Big Text interfaces, tests and spec amendments` (includes `project.yml` and `PocketDesktop.xcodeproj`), push `farside-big-text`.

---

### Task 1: Protocol (Wave 1)

**Files:**
- Modify: `RemoteShared/BigTextProtocol.swift`, `RemoteShared/DisplaySelection.swift` (DisplayDescriptor fields + `validate()` at :14; `displayActions` :32; `validateDisplaySelection()` :39–59), `RemoteShared/ControlProtocol.swift` (RemoteAction fields after `busy` :46; `validate()` pre-checks before :67), `RemoteShared/SessionContinuity.swift` (:6–26)
- Test: `RemoteTests/BigTextProtocolTests.swift`

**Interfaces:**
- Produces: `SessionFeature.displayScale`; `DisplayDescriptor.scaleSteps: [ScaleStep]?`, `.scaleBaselineWidth: Double?`, `.scaleCurrentWidth: Double?` (all `= nil`, declared **after** `main`); `RemoteAction.looksLikeWidth: Double?`, `.scaleError: String?` (both `= nil`, declared **after** `busy`, in that order); action name `"displayScale"`.

- [ ] **Step 1: Write the failing tests** in `RemoteTests/BigTextProtocolTests.swift`:
```swift
import XCTest

final class BigTextProtocolTests: XCTestCase {
    func testDisplayScaleRequestsValidate() {
        XCTAssertNoThrow(try RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: 1280).validate())
        XCTAssertNoThrow(try RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: 0).validate(),
                         "0 asks for the Mac's own size")
    }

    func testMalformedScaleActionsAreRejected() {
        let invalid: [RemoteAction] = [
            RemoteAction(action: "displayScale", epoch: 3, display: 1),
            RemoteAction(action: "displayScale", epoch: 3, looksLikeWidth: 1280),
            RemoteAction(action: "displayScale", epoch: 3, display: 0, looksLikeWidth: 1280),
            RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: .nan),
            RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: 25_000),
            RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: -5),
            RemoteAction(action: "displayScale", text: "x", epoch: 3, display: 1, looksLikeWidth: 1280),
            RemoteAction(action: "click", epoch: 3, looksLikeWidth: 1280),
            RemoteAction(action: "displays", epoch: 3, scaleError: "nonsense"),
            RemoteAction(action: "capture", epoch: 3, scaleError: "failed"),
        ]
        for action in invalid { XCTAssertThrowsError(try action.validate(), "\(action.action) must be rejected") }
    }

    func testDescriptorScaleFields() {
        var display = DisplayDescriptor(id: 1, name: "Built-in Retina Display", width: 1470, height: 956)
        display.scaleSteps = [ScaleStep(width: 1280, height: 832), ScaleStep(width: 1024, height: 665)]
        display.scaleBaselineWidth = 1470
        display.scaleCurrentWidth = 1280
        XCTAssertNoThrow(try display.validate())

        display.scaleCurrentWidth = 1111
        XCTAssertThrowsError(try display.validate(), "current must be the baseline or an offered step")
        display.scaleCurrentWidth = nil
        display.scaleSteps = [ScaleStep(width: 1600, height: 1040)]
        XCTAssertThrowsError(try display.validate(), "steps are bigger text, so narrower than the baseline")
        display.scaleSteps = Array(repeating: ScaleStep(width: 1000, height: 650), count: 5)
        XCTAssertThrowsError(try display.validate(), "at most four steps")
        display.scaleSteps = [ScaleStep(width: 1280, height: 832)]
        display.scaleBaselineWidth = nil
        XCTAssertThrowsError(try display.validate(), "steps need a baseline")
        display.scaleSteps = []
        display.scaleBaselineWidth = 1470
        XCTAssertNoThrow(try display.validate(), "already at the largest size offers no steps")
    }

    func testOlderDecodersIgnoreTheNewDescriptorFields() {
        struct OldDescriptor: Decodable { var id: UInt32; var name: String; var width: Double; var height: Double }
        let json = #"{"id":1,"name":"Built-in","width":1470,"height":956,"main":true,"scaleSteps":[{"width":1280,"height":832}],"scaleBaselineWidth":1470}"#
        XCTAssertNoThrow(try JSONDecoder().decode(OldDescriptor.self, from: Data(json.utf8)))
    }

    func testErrorReplyRoundTrips() throws {
        let reply = RemoteAction(action: "displays", epoch: 4, displays: [], display: 1, scaleError: BigTextError.failed.rawValue)
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(reply))
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertEqual(decoded.scaleError, "failed")
    }

    func testCapabilityIsOptIn() {
        XCTAssertEqual(SessionFeature.displayScale, "display.scale.1")
        XCTAssertFalse(SessionFeature.host.contains(SessionFeature.displayScale), "advertised only when the Mac allows it")
    }
}
```
- [ ] **Step 2: Run to verify failure.** Core test command with `-XCTest BigTextProtocolTests`. Expected: compile errors (missing `looksLikeWidth`, `scaleSteps`, `displayScale`).
- [ ] **Step 3: Implement.**
  - `SessionContinuity.swift`, inside `enum SessionFeature` after `ladder`: `static let displayScale = "display.scale.1"` (do **not** add it to `host`).
  - `DisplaySelection.swift`, `DisplayDescriptor` after `var main: Bool = false`:
    ```swift
    var scaleSteps: [ScaleStep]? = nil
    var scaleBaselineWidth: Double? = nil
    var scaleCurrentWidth: Double? = nil
    ```
    and at the end of `validate()`: `try validateScale()`.
  - `BigTextProtocol.swift`: implement `ScaleStep.validate` and add the descriptor extension:
    ```swift
    func validate(below baselineWidth: Double) throws {
        guard width.isFinite, height.isFinite, BigTextLimits.widthRange.contains(width),
              BigTextLimits.widthRange.contains(height), width < baselineWidth else { throw RemoteError.invalidMessage }
    }
    ```
    ```swift
    extension DisplayDescriptor {
        func validateScale() throws {
            guard scaleSteps != nil || scaleBaselineWidth != nil || scaleCurrentWidth != nil else { return }
            guard let baseline = scaleBaselineWidth, baseline.isFinite, BigTextLimits.widthRange.contains(baseline),
                  let steps = scaleSteps, steps.count <= BigTextLimits.maxSteps else { throw RemoteError.invalidMessage }
            try steps.forEach { try $0.validate(below: baseline) }
            if let current = scaleCurrentWidth, current != baseline, !steps.contains(where: { $0.width == current }) {
                throw RemoteError.invalidMessage
            }
        }
    }
    ```
  - `ControlProtocol.swift`, after `var busy: BusyState? = nil`:
    ```swift
    var looksLikeWidth: Double? = nil
    var scaleError: String? = nil
    ```
    In `validate()`, next to the other checks that run before the early returns (before `if try validateDisplaySelection() { return }`):
    ```swift
    if looksLikeWidth != nil, action != "displayScale" { throw RemoteError.invalidMessage }
    if let scaleError, action != "displays" || BigTextError(rawValue: scaleError) == nil { throw RemoteError.invalidMessage }
    ```
  - `DisplaySelection.swift`: `displayActions = ["displays", "display", "displayScale"]`; in the `if let display` guard add `"displayScale"` to the allowed actions array; after the existing `if action == "display" { … }` block add:
    ```swift
    if action == "displayScale" {
        guard let width = looksLikeWidth, display != nil, displays == nil,
              width == 0 || (width.isFinite && BigTextLimits.widthRange.contains(width)) else { throw RemoteError.invalidMessage }
    }
    ```
- [ ] **Step 4: Run** `BigTextProtocolTests` and `DisplaySelectionProtocolTests`. Expected: all pass.
- [ ] **Step 5: Commit** `Add Big Text protocol fields and validation`.

---

### Task 2: Step builder (Wave 1)

**Files:**
- Modify: `RemoteHost/BigTextModes.swift`
- Test: `RemoteTests/BigTextStepsTests.swift`

**Interfaces:**
- Consumes: `BigTextLimits.maxSteps` (Task 0 stub, value 4).
- Produces: `BigTextSteps.steps(baseline:modes:)`, `.spread(_:count:)`, `.nearest(to:in:)`.

- [ ] **Step 1: Capture the real mode list** (read-only CoreGraphics call; safe on the shared Mac). Save this as a scratch script outside the repo and run it:
```swift
import CoreGraphics
let id = CGMainDisplayID()
let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
let current = CGDisplayCopyDisplayMode(id)!
print("// current: \(current.width)x\(current.height) px \(current.pixelWidth)x\(current.pixelHeight) @\(current.refreshRate)")
for m in (CGDisplayCopyAllDisplayModes(id, options) as! [CGDisplayMode]) {
    print("mode(\(m.width), \(m.height), px: (\(m.pixelWidth), \(m.pixelHeight)), hz: \(m.refreshRate), gui: \(m.isUsableForDesktopGUI()), id: \(m.ioDisplayModeID)),")
}
```
`swift /path/to/capture-modes.swift > /tmp/air-modes.txt`. Paste the output into the test as `capturedAirModes` (Step 2) with its `// current:` line as the baseline.
- [ ] **Step 2: Write the failing tests:**
```swift
import XCTest

final class BigTextStepsTests: XCTestCase {
    private func mode(_ w: Int, _ h: Int, px: (Int, Int)? = nil, hz: Double = 60, gui: Bool = true, id: Int32? = nil) -> DisplayModeInfo {
        let pixels = px ?? (w * 2, h * 2)
        return DisplayModeInfo(ioModeID: id ?? Int32(w * 10_000 + h), width: w, height: h, pixelWidth: pixels.0,
                               pixelHeight: pixels.1, refreshRate: hz, usableForDesktopGUI: gui)
    }

    private var airBaseline: DisplayModeInfo { mode(1470, 956) }
    private var airModes: [DisplayModeInfo] {
        [mode(1710, 1112), mode(1470, 956), mode(1280, 832), mode(1024, 665),
         mode(1280, 832, px: (1280, 832)), mode(1280, 832, id: 99), mode(800, 520, gui: false),
         mode(1440, 900), mode(1280, 832, hz: 120)]
    }

    func testOnlyBiggerTextHiDPIStepsOfTheSameShapeAndRate() {
        let steps = BigTextSteps.steps(baseline: airBaseline, modes: airModes)
        XCTAssertEqual(steps.map(\.width), [1280, 1024], "no More Space, no 1x, no other aspect, rate or non-GUI mode")
    }

    func testDuplicatesCollapseAndLongListsSpreadToFour() {
        let many = (0..<9).map { mode(1400 - $0 * 100, Int((Double(1400 - $0 * 100) / airBaseline.aspect).rounded())) }
        let steps = BigTextSteps.steps(baseline: airBaseline, modes: many + many)
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(steps.first?.width, 1400, "the step closest to the Mac's size stays")
        XCTAssertEqual(steps.last?.width, 600, "the largest text stays")
    }

    func testSpreadKeepsEndsAndOrder() {
        XCTAssertEqual(BigTextSteps.spread([1, 2, 3, 4, 5, 6, 7], count: 4), [1, 3, 5, 7])
        XCTAssertEqual(BigTextSteps.spread([1, 2], count: 4), [1, 2])
    }

    func testNearestWithinTenPercentElseNil() {
        let steps = BigTextSteps.steps(baseline: airBaseline, modes: airModes)
        XCTAssertEqual(BigTextSteps.nearest(to: 1300, in: steps)?.width, 1280)
        XCTAssertEqual(BigTextSteps.nearest(to: 1000, in: steps)?.width, 1024)
        XCTAssertNil(BigTextSteps.nearest(to: 700, in: steps), "a saved size from another display is refused, not guessed")
        XCTAssertNil(BigTextSteps.nearest(to: 0, in: steps))
    }

    func testAlreadyAtTheLargestOffersNothing() {
        XCTAssertEqual(BigTextSteps.steps(baseline: mode(1024, 665), modes: airModes), [])
    }

    func testPanelsReportingZeroHertzStillMatch() {
        let steps = BigTextSteps.steps(baseline: mode(1470, 956, hz: 0), modes: [mode(1280, 832, hz: 0)])
        XCTAssertEqual(steps.map(\.width), [1280])
    }

    func testCapturedAirList() {
        // Paste the Step 1 output here as `let capturedAirModes: [DisplayModeInfo] = [ … ]` and its baseline.
        // Assert: every step is HiDPI, narrower than the baseline, at most four, sorted widest first.
    }
}
```
Replace the body of `testCapturedAirList` with the pasted literal plus these assertions (the comment above is an instruction to the implementer, not code to keep):
```swift
let steps = BigTextSteps.steps(baseline: capturedBaseline, modes: capturedAirModes)
XCTAssertFalse(steps.isEmpty, "the built-in display offers larger text")
XCTAssertLessThanOrEqual(steps.count, 4)
XCTAssertTrue(steps.allSatisfy { $0.isHiDPI && $0.width < capturedBaseline.width })
XCTAssertEqual(steps.map(\.width), steps.map(\.width).sorted(by: >))
```
- [ ] **Step 3: Run to verify failure** (`-XCTest BigTextStepsTests`). Expected: assertion failures (stubs return `[]`/`nil`).
- [ ] **Step 4: Implement** in `BigTextModes.swift`:
```swift
static func steps(baseline: DisplayModeInfo, modes: [DisplayModeInfo]) -> [DisplayModeInfo] {
    var seen = Set<[Int]>()
    let candidates = modes
        .filter { $0.usableForDesktopGUI && $0.isHiDPI && $0.width < baseline.width }
        .filter { abs($0.aspect - baseline.aspect) <= baseline.aspect * 0.005 }
        .filter { abs($0.refreshRate - baseline.refreshRate) < 0.5 }
        .sorted { $0.width > $1.width }
        .filter { seen.insert([$0.width, $0.height]).inserted }
    return spread(candidates, count: BigTextLimits.maxSteps)
}

static func spread<T>(_ items: [T], count: Int) -> [T] {
    guard items.count > count, count > 1 else { return Array(items.prefix(count)) }
    let last = items.count - 1
    return (0..<count).map { items[Int((Double($0) * Double(last) / Double(count - 1)).rounded())] }
}

static func nearest(to width: Double, in steps: [DisplayModeInfo]) -> DisplayModeInfo? {
    guard width > 0, let best = steps.min(by: { abs(Double($0.width) - width) < abs(Double($1.width) - width) })
    else { return nil }
    return abs(Double(best.width) - width) <= width * nearestTolerance ? best : nil
}
```
- [ ] **Step 5: Run** `BigTextStepsTests`. Expected: 7 pass.
- [ ] **Step 6: Commit** `Build Big Text steps from the Mac's display modes`.

---

### Task 3: Phone memory (Wave 1)

**Files:**
- Modify: `RemoteShared/BigTextMemory.swift`
- Test: `RemoteTests/BigTextMemoryTests.swift`

**Interfaces:**
- Consumes: `DisplayMemory.Choice(id:name:)`, `DisplayMemory.match(_:in:) -> DisplayDescriptor?` (exact id first, else a *unique* name), `SecureRandom.digest(_:)`.
- Produces: `BigTextMemory.width(forRoom:display:among:)`, `.remember(_:forRoom:display:among:)`, `.forget(room:)`.

- [ ] **Step 1: Write the failing tests:**
```swift
import XCTest

final class BigTextMemoryTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "BigTextMemoryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private let builtIn = DisplayDescriptor(id: 1, name: "Built-in Retina Display", width: 1470, height: 956)
    private let studio = DisplayDescriptor(id: 7, name: "Studio Display", width: 2560, height: 1440)

    func testRememberedPerMacAndPerDisplay() {
        let memory = BigTextMemory(defaults: defaults)
        memory.remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn, studio])
        memory.remember(2048, forRoom: "room-a", display: studio, among: [builtIn, studio])
        XCTAssertEqual(memory.width(forRoom: "room-a", display: builtIn, among: [builtIn, studio]), 1280)
        XCTAssertEqual(memory.width(forRoom: "room-a", display: studio, among: [builtIn, studio]), 2048)
        XCTAssertNil(memory.width(forRoom: "room-b", display: builtIn, among: [builtIn]), "another Mac has its own level")
    }

    func testRenumberedDisplayMatchesByUniqueName() {
        let memory = BigTextMemory(defaults: defaults)
        memory.remember(2048, forRoom: "room-a", display: studio, among: [builtIn, studio])
        let renumbered = DisplayDescriptor(id: 9, name: "Studio Display", width: 2560, height: 1440)
        XCTAssertEqual(memory.width(forRoom: "room-a", display: renumbered, among: [builtIn, renumbered]), 2048)
    }

    func testAmbiguousNamesNeverGuess() {
        let memory = BigTextMemory(defaults: defaults)
        let left = DisplayDescriptor(id: 3, name: "DELL U2720Q", width: 2560, height: 1440)
        memory.remember(2048, forRoom: "room-a", display: left, among: [left])
        let twinA = DisplayDescriptor(id: 11, name: "DELL U2720Q", width: 2560, height: 1440)
        let twinB = DisplayDescriptor(id: 12, name: "DELL U2720Q", width: 2560, height: 1440)
        XCTAssertNil(memory.width(forRoom: "room-a", display: twinA, among: [twinA, twinB]))
    }

    func testOffForgetsOneDisplayAndForgetClearsTheMac() {
        let memory = BigTextMemory(defaults: defaults)
        memory.remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn, studio])
        memory.remember(2048, forRoom: "room-a", display: studio, among: [builtIn, studio])
        memory.remember(nil, forRoom: "room-a", display: builtIn, among: [builtIn, studio])
        XCTAssertNil(memory.width(forRoom: "room-a", display: builtIn, among: [builtIn, studio]))
        XCTAssertEqual(memory.width(forRoom: "room-a", display: studio, among: [builtIn, studio]), 2048)
        memory.forget(room: "room-a")
        XCTAssertNil(memory.width(forRoom: "room-a", display: studio, among: [builtIn, studio]))
        XCTAssertNil(defaults.data(forKey: BigTextMemory.defaultsKey), "nothing left behind after the last Mac is forgotten")
    }

    func testReplacingALevelKeepsOneEntry() {
        let memory = BigTextMemory(defaults: defaults)
        memory.remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn])
        memory.remember(1024, forRoom: "room-a", display: builtIn, among: [builtIn])
        XCTAssertEqual(memory.width(forRoom: "room-a", display: builtIn, among: [builtIn]), 1024)
    }

    func testRoomIsHashed() {
        XCTAssertFalse(BigTextMemory.macKey(room: "room-a").contains("room-a"))
        XCTAssertNotEqual(BigTextMemory.macKey(room: "room-a"), DisplayMemory.macKey(room: "room-a"))
    }
}
```
- [ ] **Step 2: Run to verify failure** (`-XCTest BigTextMemoryTests`).
- [ ] **Step 3: Implement** in `BigTextMemory.swift` (replace the three stub methods, add private storage):
```swift
func width(forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) -> Double? {
    entries(room).first { DisplayMemory.match($0.display, in: displays)?.id == display.id }?.looksLikeWidth
}

func remember(_ width: Double?, forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) {
    var all = load()
    let key = Self.macKey(room: room)
    var kept = (all[key] ?? []).filter {
        $0.display.id != display.id && DisplayMemory.match($0.display, in: displays)?.id != display.id
    }
    if let width, width > 0 {
        kept.append(Entry(display: DisplayMemory.Choice(id: display.id, name: display.name), looksLikeWidth: width))
    }
    all[key] = kept.isEmpty ? nil : kept
    save(all)
}

func forget(room: String) {
    var all = load()
    all[Self.macKey(room: room)] = nil
    save(all)
}

private func entries(_ room: String) -> [Entry] { load()[Self.macKey(room: room)] ?? [] }

private func load() -> [String: [Entry]] {
    guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
    return (try? JSONDecoder().decode([String: [Entry]].self, from: data)) ?? [:]
}

private func save(_ all: [String: [Entry]]) {
    guard !all.isEmpty, let data = try? JSONEncoder().encode(all) else {
        defaults.removeObject(forKey: Self.defaultsKey)
        return
    }
    defaults.set(data, forKey: Self.defaultsKey)
}
```
- [ ] **Step 4: Run** `BigTextMemoryTests` and `DisplayMemoryTests`. Expected: pass.
- [ ] **Step 5: Commit** `Remember Big Text per phone, Mac and display`.

---

### Task 4: Display switcher and own-change recogniser (Wave 1)

**Files:**
- Modify: `RemoteHost/BigTextDisplaySwitcher.swift`
- Test: `RemoteTests/BigTextRecognizerTests.swift`

**Interfaces:**
- Consumes: `DisplayModeInfo` (Task 0).
- Produces: `LiveDisplayModeSwitcher: DisplayModeSwitching`, `OwnChangeRecognizer` (implemented), `DisplayReconfigurationMonitor(handler:)` with `start()`/`stop()`.

- [ ] **Step 1: Write the failing tests:**
```swift
import CoreGraphics
import XCTest

final class BigTextRecognizerTests: XCTestCase {
    private let target = DisplayModeInfo(ioModeID: 42, width: 1280, height: 832, pixelWidth: 2560, pixelHeight: 1664,
                                         refreshRate: 60, usableForDesktopGUI: true)
    private let other = DisplayModeInfo(ioModeID: 7, width: 1470, height: 956, pixelWidth: 2940, pixelHeight: 1912,
                                        refreshRate: 60, usableForDesktopGUI: true)

    private func recognizer() -> OwnChangeRecognizer {
        OwnChangeRecognizer(display: 1, target: target, onlineBefore: [1, 2], startedAt: 100)
    }

    func testSetModeOnOurDisplayReachingTheTargetIsOurs() {
        var r = recognizer()
        r.observe(DisplayReconfigurationEvent(display: 1, flags: [.beginConfigurationFlag]))
        XCTAssertEqual(r.verdict(now: 100.2, online: [1, 2], current: target), .pending, "before-change callbacks do not count")
        r.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag, .desktopShapeChangedFlag]))
        r.observe(DisplayReconfigurationEvent(display: 2, flags: [.movedFlag]))
        XCTAssertEqual(r.verdict(now: 100.4, online: [1, 2], current: target), .ours, "neighbours moving is part of our change")
    }

    func testModeNotYetAtTargetIsPending() {
        var r = recognizer()
        r.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag]))
        XCTAssertEqual(r.verdict(now: 101, online: [1, 2], current: other), .pending)
    }

    func testSetModeOnAnotherDisplayDoesNotCount() {
        var r = recognizer()
        r.observe(DisplayReconfigurationEvent(display: 2, flags: [.setModeFlag]))
        XCTAssertEqual(r.verdict(now: 101, online: [1, 2], current: target), .pending)
    }

    func testAddedDisplayIsForeign() {
        var r = recognizer()
        r.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag]))
        r.observe(DisplayReconfigurationEvent(display: 3, flags: [.addFlag]))
        XCTAssertEqual(r.verdict(now: 101, online: [1, 2, 3], current: target), .foreign)
    }

    func testOnlineListChangeIsForeign() {
        var r = recognizer()
        r.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag]))
        XCTAssertEqual(r.verdict(now: 101, online: [1], current: target), .foreign)
    }

    func testTimeoutIsForeign() {
        let r = recognizer()
        XCTAssertEqual(r.verdict(now: 100 + OwnChangeRecognizer.timeout + 0.1, online: [1, 2], current: other), .foreign)
    }

    @MainActor
    func testLiveSwitcherReadsTheMainDisplayWithoutChangingIt() {
        let switcher = LiveDisplayModeSwitcher()
        let main = CGMainDisplayID()
        let before = switcher.currentMode(of: main)
        XCTAssertNotNil(before)
        XCTAssertTrue(switcher.modes(of: main).contains { $0.ioModeID == before?.ioModeID })
        XCTAssertTrue(switcher.onlineDisplays().contains(main))
    }
}
```
- [ ] **Step 2: Run to verify failure** (`-XCTest BigTextRecognizerTests`).
- [ ] **Step 3: Implement** in `BigTextDisplaySwitcher.swift`. Give `OwnChangeRecognizer` stored flags and an explicit init, and add the live types:
```swift
struct OwnChangeRecognizer {
    enum Verdict: Equatable { case pending, ours, foreign }
    static let timeout: TimeInterval = 10
    private static let structural: CGDisplayChangeSummaryFlags =
        [.addFlag, .removeFlag, .enabledFlag, .disabledFlag, .mirrorFlag, .unMirrorFlag]

    let display: CGDirectDisplayID
    let target: DisplayModeInfo
    let onlineBefore: Set<CGDirectDisplayID>
    let startedAt: TimeInterval
    private(set) var sawSetMode = false
    private(set) var sawStructuralChange = false

    init(display: CGDirectDisplayID, target: DisplayModeInfo, onlineBefore: Set<CGDirectDisplayID>, startedAt: TimeInterval) {
        self.display = display
        self.target = target
        self.onlineBefore = onlineBefore
        self.startedAt = startedAt
    }

    mutating func observe(_ event: DisplayReconfigurationEvent) {
        guard !event.flags.contains(.beginConfigurationFlag) else { return }
        if !event.flags.isDisjoint(with: Self.structural) { sawStructuralChange = true }
        if event.display == display, event.flags.contains(.setModeFlag) { sawSetMode = true }
    }

    func verdict(now: TimeInterval, online: Set<CGDirectDisplayID>, current: DisplayModeInfo?) -> Verdict {
        if sawStructuralChange || online != onlineBefore { return .foreign }
        if sawSetMode, current?.ioModeID == target.ioModeID { return .ours }
        return now - startedAt > Self.timeout ? .foreign : .pending
    }
}

@MainActor
final class LiveDisplayModeSwitcher: DisplayModeSwitching {
    func currentMode(of display: CGDirectDisplayID) -> DisplayModeInfo? { CGDisplayCopyDisplayMode(display).map(Self.info) }

    func modes(of display: CGDirectDisplayID) -> [DisplayModeInfo] { raw(display).map(Self.info) }

    func apply(_ mode: DisplayModeInfo, to display: CGDirectDisplayID) -> DisplayModeApplyResult {
        guard let target = raw(display).first(where: { $0.ioDisplayModeID == mode.ioModeID }) else {
            return .failed(CGError.illegalArgument.rawValue)
        }
        var config: CGDisplayConfigRef?
        let begun = CGBeginDisplayConfiguration(&config)
        guard begun == .success, let config else { return .failed(begun.rawValue) }
        let configured = CGConfigureDisplayWithDisplayMode(config, display, target, nil)
        guard configured == .success else {
            CGCancelDisplayConfiguration(config)
            return .failed(configured.rawValue)
        }
        // Scope matters: macOS returns to the login-session configuration when this process exits,
        // so a crash or watchdog kill cannot leave the Mac on Big Text.
        let completed = CGCompleteDisplayConfiguration(config, .forAppOnly)
        return completed == .success ? .applied : .failed(completed.rawValue)
    }

    func onlineDisplays() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Set(ids.prefix(Int(count)))
    }

    private func raw(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
    }

    nonisolated static func info(_ mode: CGDisplayMode) -> DisplayModeInfo {
        DisplayModeInfo(ioModeID: mode.ioDisplayModeID, width: mode.width, height: mode.height,
                        pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                        refreshRate: mode.refreshRate, usableForDesktopGUI: mode.isUsableForDesktopGUI())
    }
}

@MainActor
final class DisplayReconfigurationMonitor {
    private let handler: (DisplayReconfigurationEvent) -> Void
    private var registered = false

    init(handler: @escaping (DisplayReconfigurationEvent) -> Void) { self.handler = handler }

    func start() {
        guard !registered else { return }
        registered = CGDisplayRegisterReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque()) == .success
    }

    func stop() {
        guard registered else { return }
        CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
        registered = false
    }

    fileprivate func deliver(_ event: DisplayReconfigurationEvent) { handler(event) }

    private static let callback: CGDisplayReconfigurationCallBack = { display, flags, context in
        guard let context else { return }
        let event = DisplayReconfigurationEvent(display: display, flags: flags)
        nonisolated(unsafe) let monitor = Unmanaged<DisplayReconfigurationMonitor>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { MainActor.assumeIsolated { monitor.deliver(event) } }
    }
}
```
If the compiler rejects `nonisolated(unsafe) let` inside the closure, move the `Unmanaged` → object conversion into `MainActor.assumeIsolated` (pass `context` as `UInt(bitPattern:)`) — keep behaviour identical. The monitor lives for the host's lifetime (Task 7b stores it), so the unretained pointer stays valid.
- [ ] **Step 4: Run** `BigTextRecognizerTests`. Expected: 7 pass (the live test only reads modes).
- [ ] **Step 5: Commit** `Recognise the host's own display mode changes`.

---

### Task 6: Window restore (Wave 1)

**Files:**
- Modify: `RemoteHost/BigTextWindows.swift`
- Test: `RemoteTests/BigTextWindowTests.swift`

**Interfaces:**
- Consumes: `WindowRef`, `WindowAccess`, `BigTextWindowKeeping` (Task 0).
- Produces: `WindowRestorePlan.moves(before:after:now:)`, `final class BigTextWindowKeeper: BigTextWindowKeeping` with `init(access: WindowAccess, queue: DispatchQueue = …)`, `final class LiveWindowAccess: WindowAccess`.

- [ ] **Step 1: Write the failing tests:**
```swift
import AppKit
import XCTest

final class FakeWindowAccess: WindowAccess, @unchecked Sendable {
    var windows: [WindowRef] = []
    var frames: [WindowRef: CGRect] = [:]
    var set: [(WindowRef, CGRect)] = []
    var refuse: Set<WindowRef> = []
    var stageManagerEnabled = false

    func standardWindows(within bounds: CGRect, pids: [pid_t]) -> [WindowRef] { windows.filter { pids.contains($0.pid) } }
    func frame(of window: WindowRef) -> CGRect? { frames[window] }
    func setFrame(_ frame: CGRect, of window: WindowRef) -> Bool {
        guard !refuse.contains(window) else { return false }
        set.append((window, frame))
        frames[window] = frame
        return true
    }
}

final class BigTextWindowTests: XCTestCase {
    private func window(_ pid: pid_t = 10) -> WindowRef { WindowRef(pid: pid, element: NSObject()) }

    func testOnlyWindowsStillWhereMacOSLeftThemAreRestoredLargestFirst() {
        let small = window(), big = window(), moved = window(), closed = window()
        let before = [small: CGRect(x: 0, y: 0, width: 400, height: 300), big: CGRect(x: 0, y: 0, width: 1400, height: 900),
                      moved: CGRect(x: 0, y: 0, width: 1400, height: 900), closed: CGRect(x: 0, y: 0, width: 1400, height: 900)]
        let after = [small: before[small]!, big: CGRect(x: 0, y: 0, width: 1280, height: 800),
                     moved: CGRect(x: 0, y: 0, width: 1280, height: 800), closed: CGRect(x: 0, y: 0, width: 1280, height: 800)]
        let now = [small: before[small]!, big: after[big]!, moved: CGRect(x: 50, y: 50, width: 900, height: 600)]
        let plan = WindowRestorePlan.moves(before: before, after: after, now: now)
        XCTAssertEqual(plan.map(\.0), [big], "unchanged windows, windows the person moved and closed windows are left alone")
        XCTAssertEqual(plan.first?.1, before[big])
    }

    func testKeeperSnapshotsSettlesAndRestores() async {
        let access = FakeWindowAccess()
        let a = window(), b = window(99)
        access.windows = [a, b]
        access.frames = [a: CGRect(x: 0, y: 0, width: 1400, height: 900), b: CGRect(x: 0, y: 0, width: 800, height: 600)]
        let keeper = BigTextWindowKeeper(access: access)
        await keeper.snapshot(within: CGRect(x: 0, y: 0, width: 1470, height: 956), pids: [10])
        XCTAssertTrue(keeper.hasSnapshot)
        access.frames[a] = CGRect(x: 0, y: 0, width: 1280, height: 800)
        await keeper.recordSettled()
        let restored = await keeper.restore()
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(access.frames[a], CGRect(x: 0, y: 0, width: 1400, height: 900))
        XCTAssertTrue(access.set.allSatisfy { $0.0 !== b }, "windows of apps not listed are never touched")
        XCTAssertFalse(keeper.hasSnapshot, "a restore consumes the snapshot")
    }

    func testStageManagerSkipsRestoreAndRefusalsAreIgnored() async {
        let access = FakeWindowAccess()
        let a = window()
        access.windows = [a]
        access.frames = [a: CGRect(x: 0, y: 0, width: 1400, height: 900)]
        let keeper = BigTextWindowKeeper(access: access)
        await keeper.snapshot(within: .infinite, pids: [10])
        access.frames[a] = CGRect(x: 0, y: 0, width: 1280, height: 800)
        await keeper.recordSettled()
        access.refuse = [a]
        let refusedCount = await keeper.restore()
        XCTAssertEqual(refusedCount, 0)

        await keeper.snapshot(within: .infinite, pids: [10])
        await keeper.recordSettled()
        access.stageManagerEnabled = true
        access.refuse = []
        let stageCount = await keeper.restore()
        XCTAssertEqual(stageCount, 0)
        XCTAssertTrue(access.set.isEmpty)
    }

    func testDiscardForgetsWithoutMoving() async {
        let access = FakeWindowAccess()
        let a = window()
        access.windows = [a]
        access.frames = [a: CGRect(x: 0, y: 0, width: 1400, height: 900)]
        let keeper = BigTextWindowKeeper(access: access)
        await keeper.snapshot(within: .infinite, pids: [10])
        keeper.discard()
        XCTAssertFalse(keeper.hasSnapshot)
        let count = await keeper.restore()
        XCTAssertEqual(count, 0)
    }
}
```
- [ ] **Step 2: Run to verify failure** (`-XCTest BigTextWindowTests`).
- [ ] **Step 3: Implement** in `BigTextWindows.swift`:
```swift
enum WindowRestorePlan {
    static let tolerance: CGFloat = 2

    static func moves(before: [WindowRef: CGRect], after: [WindowRef: CGRect], now: [WindowRef: CGRect]) -> [(WindowRef, CGRect)] {
        before.compactMap { window, original -> (WindowRef, CGRect)? in
            guard let settled = after[window], let current = now[window],
                  close(settled, current), !close(original, current) else { return nil }
            return (window, original)
        }
        .sorted { $0.1.width * $0.1.height > $1.1.width * $1.1.height }
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

final class BigTextWindowKeeper: BigTextWindowKeeping, @unchecked Sendable {
    private let access: WindowAccess
    private let queue: DispatchQueue
    private var before: [WindowRef: CGRect] = [:]
    private var after: [WindowRef: CGRect] = [:]

    init(access: WindowAccess, queue: DispatchQueue = DispatchQueue(label: "farside.bigtext.windows")) {
        self.access = access
        self.queue = queue
    }

    var hasSnapshot: Bool { queue.sync { !before.isEmpty } }

    func snapshot(within bounds: CGRect, pids: [pid_t]) async {
        await run {
            self.after = [:]
            self.before = Dictionary(uniqueKeysWithValues: self.access.standardWindows(within: bounds, pids: pids)
                .compactMap { window in self.access.frame(of: window).map { (window, $0) } })
        }
    }

    func recordSettled() async {
        await run {
            self.after = Dictionary(uniqueKeysWithValues: self.before.keys.compactMap { window in
                self.access.frame(of: window).map { (window, $0) } })
        }
    }

    @discardableResult
    func restore() async -> Int {
        await run {
            defer { self.before = [:]; self.after = [:] }
            guard !self.access.stageManagerEnabled else { return 0 }
            let now = Dictionary(uniqueKeysWithValues: self.before.keys.compactMap { window in
                self.access.frame(of: window).map { (window, $0) } })
            return WindowRestorePlan.moves(before: self.before, after: self.after, now: now)
                .filter { self.access.setFrame($0.1, of: $0.0) }.count
        }
    }

    func discard() { queue.sync { before = [:]; after = [:] } }

    private func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: work()) } }
    }
}

final class LiveWindowAccess: WindowAccess, @unchecked Sendable {
    private static let timeout: Float = 0.1

    var stageManagerEnabled: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }

    func standardWindows(within bounds: CGRect, pids: [pid_t]) -> [WindowRef] {
        pids.flatMap { pid -> [WindowRef] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.timeout)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return [] }
            return windows.compactMap { window in
                AXUIElementSetMessagingTimeout(window, Self.timeout)
                guard Self.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
                      Self.bool(window, kAXMinimizedAttribute) != true, Self.bool(window, "AXFullScreen") != true,
                      let frame = Self.frame(window), bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
                else { return nil }
                return WindowRef(pid: pid, element: window)
            }
        }
    }

    func frame(of window: WindowRef) -> CGRect? { Self.frame(window.element as! AXUIElement) }

    func setFrame(_ frame: CGRect, of window: WindowRef) -> Bool {
        let element = window.element as! AXUIElement
        var size = frame.size
        var origin = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let originValue = AXValueCreate(.cgPoint, &origin) else { return false }
        let sized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, originValue)
        return sized == .success && moved == .success
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}
```
Verify by reading: the file contains no `kAXTitleAttribute`, no `kAXValueAttribute`, and no disk writes.
- [ ] **Step 4: Run** `BigTextWindowTests`. Expected: 4 pass.
- [ ] **Step 5: Commit** `Restore windows Big Text shrank, by identity and only if untouched`.

---

### Task 7a: Curtain, capture and hang-policy hooks (Wave 1)

**Files:**
- Modify: `RemoteHost/PrivacyCurtain.swift` (`PrivacyCurtainInputs` :27, `PrivacyCurtainPolicy.desired` :50, `observeScreenChanges` :294, controller :161), `RemoteHost/RemoteCapture.swift` (`start(display:peer:)` :198, `stop()` :277, `RemoteCaptureSession.init` :550), `RemoteHost/HostHangWatchdog.swift` (:36)
- Test: `RemoteTests/PrivacyCurtainTests.swift` (`PrivacyCurtainPolicyTests`), `RemoteTests/WatchdogTests.swift` (`HangWatchdogTests`)

**Interfaces:**
- Produces: `PrivacyCurtainInputs.displayReconfiguring: Bool = false`; `PrivacyCurtainController.followsScreenChanges: Bool` (default `true`) and `func refitToScreens()`; `RemoteCapture.start(display:peer:keepingExclusions: Bool = false)`; `RemoteCapture.stop(keepingExclusions: Bool) -> Task<Void, Never>?`; `HangWatchdogPolicy.threshold(curtainUp:recoveryEnabled:bigTextEngaged: Bool = false)`.

- [ ] **Step 1: Write the failing tests.** Add to `PrivacyCurtainPolicyTests`:
```swift
func testReconfiguringKeepsARaisedCurtainUpThroughLostPicture() {
    var inputs = PrivacyCurtainInputs(preference: true, sessionLive: true, captureHealthy: false, unhealthyFor: 9,
                                      accessibilityGranted: true)
    inputs.displayReconfiguring = true
    XCTAssertEqual(PrivacyCurtainPolicy.desired(inputs, currentlyUp: true), .up, "Big Text changes never uncover the Mac")
}

func testReconfiguringNeverRaisesACurtainThatIsDown() {
    var inputs = PrivacyCurtainInputs(preference: true, sessionLive: true, captureHealthy: false, accessibilityGranted: true)
    inputs.displayReconfiguring = true
    XCTAssertEqual(PrivacyCurtainPolicy.desired(inputs, currentlyUp: false), .down)
}
```
Add to `HangWatchdogTests`:
```swift
func testBigTextUsesTheShortThresholdEvenWithoutCurtainOrRecovery() {
    XCTAssertEqual(HangWatchdogPolicy.threshold(curtainUp: false, recoveryEnabled: false, bigTextEngaged: true),
                   HangWatchdogPolicy.curtainThreshold, "a hung host must not keep the Mac on Big Text")
    XCTAssertNil(HangWatchdogPolicy.threshold(curtainUp: false, recoveryEnabled: false))
}
```
(If `PrivacyCurtainInputs`' memberwise init argument order differs from the calls above, build the value with `var inputs = PrivacyCurtainInputs()` and assign fields, as the existing tests at PrivacyCurtainTests.swift:6–17 do.)
- [ ] **Step 2: Run to verify failure** (`-XCTest PrivacyCurtainPolicyTests` then `HangWatchdogTests`).
- [ ] **Step 3: Implement.**
  - `PrivacyCurtainInputs`: add `var displayReconfiguring = false` (last field). In `desired`, directly after the opening `guard … else { return .down }`: `if currentlyUp && inputs.displayReconfiguring { return .up }`.
  - `HangWatchdogPolicy.threshold`: add parameter `bigTextEngaged: Bool = false`; first line `if curtainUp || bigTextEngaged { return curtainThreshold }`.
  - `PrivacyCurtainController`: add `var followsScreenChanges = true`; in `observeScreenChanges()` change the handler body to `MainActor.assumeIsolated { guard self?.followsScreenChanges ?? false else { return }; self?.lift() }`; add:
    ```swift
    func refitToScreens() {
        let screens = NSScreen.screens
        guard windows.count == screens.count else { return lift() }
        for (window, screen) in zip(windows, screens) { window.setFrame(screen.frame, display: true) }
    }
    ```
    Before relying on `zip`, confirm in `raise` that `windows` is built in `NSScreen.screens` order; if it is built differently, pair each window with its screen by the same key `raise` uses.
  - `RemoteCapture`: add a `keepingExclusions` path. In `start(display:peer:keepingExclusions: Bool = false)`, call `dropExclusions()` only when `!keepingExclusions`; when keeping, resolve the current excluded IDs to `[SCWindow]` with the same lookup `applyExclusion` (:322) uses and pass them to a new `RemoteCaptureSession.init(..., excluding: [SCWindow] = [])` parameter used in `SCContentFilter(display: display, excludingWindows: excluding)` (:550). Add `@discardableResult func stop(keepingExclusions: Bool) -> Task<Void, Never>?` that performs `stop()` without `dropExclusions()`; keep the existing `stop()` behaviour unchanged (`stop()` = `stop(keepingExclusions: false)`).
- [ ] **Step 4: Run** `PrivacyCurtainPolicyTests`, `CurtainCaptureExclusionTests`, `PrivacyCurtainControllerTests`, `HangWatchdogTests`. Expected: all pass (existing ones unchanged).
- [ ] **Step 5: Commit** `Let the curtain and capture survive a planned display change`.

---

### Task 5: Controller state machine (Wave 2; consumes Tasks 2, 4, 6)

**Files:**
- Modify: `RemoteHost/BigTextController.swift`
- Test: `RemoteTests/BigTextControllerTests.swift`

**Interfaces:**
- Consumes: `BigTextSteps.steps/nearest` (Task 2), `OwnChangeRecognizer`, `DisplayModeSwitching` (Task 4), `BigTextWindowKeeping` (Task 6), `ScaleStep`, `BigTextError`, `DisplayDescriptor` scale fields (Task 1).
- Produces: the implemented `BigTextController` API declared in Task 0, and `BigTextController.describe(_:offer:)` which fills `scaleSteps`/`scaleBaselineWidth`/`scaleCurrentWidth`.

- [ ] **Step 1: Write the failing tests:**
```swift
import CoreGraphics
import XCTest

@MainActor
final class FakeSwitcher: DisplayModeSwitching {
    var modesByDisplay: [CGDirectDisplayID: [DisplayModeInfo]] = [:]
    var currentByDisplay: [CGDirectDisplayID: DisplayModeInfo] = [:]
    var online: Set<CGDirectDisplayID> = [1, 2]
    var applied: [(DisplayModeInfo, CGDirectDisplayID)] = []
    var result: DisplayModeApplyResult = .applied
    var onApply: ((DisplayModeInfo, CGDirectDisplayID) -> Void)?

    func currentMode(of display: CGDirectDisplayID) -> DisplayModeInfo? { currentByDisplay[display] }
    func modes(of display: CGDirectDisplayID) -> [DisplayModeInfo] { modesByDisplay[display] ?? [] }
    func onlineDisplays() -> Set<CGDirectDisplayID> { online }
    func apply(_ mode: DisplayModeInfo, to display: CGDirectDisplayID) -> DisplayModeApplyResult {
        applied.append((mode, display))
        if result == .applied { currentByDisplay[display] = mode; onApply?(mode, display) }
        return result
    }
}

final class FakeKeeper: BigTextWindowKeeping {
    var hasSnapshot = false
    var snapshots = 0, settled = 0, restores = 0, discards = 0
    func snapshot(within bounds: CGRect, pids: [pid_t]) async { snapshots += 1; hasSnapshot = true }
    func recordSettled() async { settled += 1 }
    func restore() async -> Int { restores += 1; hasSnapshot = false; return 1 }
    func discard() { discards += 1; hasSnapshot = false }
}

@MainActor
final class FakeBigTextHost: BigTextHost {
    var quiesces = 0, resumes: [CGDirectDisplayID] = [], replies: [(CGDirectDisplayID, BigTextError?)] = []
    var foreign = 0, stateChanges = 0
    func bigTextQuiesce() { quiesces += 1 }
    func bigTextResume(display: CGDirectDisplayID) async -> Bool { resumes.append(display); return true }
    func bigTextReply(display: CGDirectDisplayID, error: BigTextError?) { replies.append((display, error)) }
    func bigTextForeignChange() { foreign += 1 }
    func bigTextStateChanged() { stateChanges += 1 }
    func bigTextDisplayBounds(_ display: CGDirectDisplayID) -> CGRect { CGRect(x: 0, y: 0, width: 1470, height: 956) }
    func bigTextRunningAppPIDs() -> [pid_t] { [10] }
}

@MainActor
final class BigTextControllerTests: XCTestCase {
    private func mode(_ w: Int, _ h: Int, id: Int32) -> DisplayModeInfo {
        DisplayModeInfo(ioModeID: id, width: w, height: h, pixelWidth: w * 2, pixelHeight: h * 2, refreshRate: 60, usableForDesktopGUI: true)
    }
    private lazy var base = mode(1470, 956, id: 1)
    private lazy var large = mode(1280, 832, id: 2)
    private lazy var larger = mode(1024, 665, id: 3)

    private var clock: TimeInterval = 0
    private var switcher: FakeSwitcher!
    private var keeper: FakeKeeper!
    private var host: FakeBigTextHost!
    private var controller: BigTextController!

    override func setUp() async throws {
        clock = 0
        switcher = FakeSwitcher()
        switcher.modesByDisplay = [1: [base, large, larger], 2: [base, large]]
        switcher.currentByDisplay = [1: base, 2: base]
        switcher.onApply = { [unowned self] _, display in
            controller.observe(DisplayReconfigurationEvent(display: display, flags: [.setModeFlag]))
        }
        keeper = FakeKeeper()
        host = FakeBigTextHost()
        controller = BigTextController(switcher: switcher, windows: keeper, now: { [unowned self] in clock },
                                       sleep: { [unowned self] seconds in clock += seconds; await Task.yield() })
        controller.host = host
    }

    private func apply(_ width: Double, display: CGDirectDisplayID = 1) async {
        controller.request(display: display, looksLikeWidth: width, allowed: true, accessibilityGranted: true)
        await controller.drain()
    }

    func testApplyQuiescesChangesSnapshotsAndResumes() async {
        await apply(1300)
        XCTAssertEqual(switcher.applied.map(\.0), [large], "the nearest offered step")
        XCTAssertEqual(host.quiesces, 1)
        XCTAssertEqual(host.resumes, [1])
        XCTAssertEqual(host.replies.map(\.1), [nil])
        XCTAssertEqual(controller.phase, .applied)
        XCTAssertEqual(controller.baseline, base)
        XCTAssertEqual(controller.current, large)
        XCTAssertEqual(keeper.snapshots, 1)
        XCTAssertEqual(keeper.settled, 1)
    }

    func testChangingIsReportedWhileTheModeSwitches() async {
        var sawChanging = false
        switcher.onApply = { [unowned self] _, display in
            sawChanging = controller.isChanging
            controller.observe(DisplayReconfigurationEvent(display: display, flags: [.setModeFlag]))
        }
        await apply(1280)
        XCTAssertTrue(sawChanging, "the screen observers defer to Big Text during its own change")
        XCTAssertFalse(controller.isChanging)
    }

    func testUnsupportedWidthIsRefusedWithoutTouchingTheDisplay() async {
        await apply(700)
        XCTAssertTrue(switcher.applied.isEmpty)
        XCTAssertEqual(host.quiesces, 0)
        XCTAssertEqual(host.replies.map(\.1), [.unsupported])
    }

    func testSavedWidthAtOrAboveTheMacsSizeIsASilentNoOp() async {
        await apply(1470)
        XCTAssertTrue(switcher.applied.isEmpty)
        XCTAssertEqual(host.replies.map(\.1), [nil])
    }

    func testDisabledAndMissingAccessibilityRefuse() async {
        controller.request(display: 1, looksLikeWidth: 1280, allowed: false, accessibilityGranted: true)
        controller.request(display: 1, looksLikeWidth: 1280, allowed: true, accessibilityGranted: false)
        await controller.drain()
        XCTAssertEqual(host.replies.map(\.1), [.disabled, .noAccessibility])
        XCTAssertTrue(switcher.applied.isEmpty)
    }

    func testForeignChangeForgetsBaselineAndStopsTheSession() async {
        switcher.onApply = { [unowned self] _, display in
            controller.observe(DisplayReconfigurationEvent(display: 3, flags: [.addFlag]))
        }
        await apply(1280)
        XCTAssertEqual(host.foreign, 1)
        XCTAssertTrue(host.resumes.isEmpty, "the session stops as it does today")
        XCTAssertNil(controller.baseline)
        XCTAssertNil(controller.current)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(keeper.discards, 1)
    }

    func testTimeoutIsTreatedAsForeign() async {
        switcher.onApply = { [unowned self] _, _ in switcher.currentByDisplay[1] = base }
        await apply(1280)
        XCTAssertEqual(host.foreign, 1)
        XCTAssertGreaterThan(clock, OwnChangeRecognizer.timeout)
    }

    func testApplyFailureRepliesFailedAndKeepsTheMacsSize() async {
        switcher.result = .failed(1001)
        await apply(1280)
        XCTAssertEqual(host.replies.map(\.1), [.failed])
        XCTAssertEqual(host.resumes, [1], "the stream comes back at the unchanged size")
        XCTAssertNil(controller.current)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(keeper.discards, 1)
    }

    func testLatestRequestWins() async {
        controller.request(display: 1, looksLikeWidth: 1280, allowed: true, accessibilityGranted: true)
        controller.request(display: 1, looksLikeWidth: 1024, allowed: true, accessibilityGranted: true)
        controller.request(display: 1, looksLikeWidth: 1280, allowed: true, accessibilityGranted: true)
        await controller.drain()
        XCTAssertEqual(switcher.applied.map(\.0), [large], "the superseded 1024 never ran and 1280 is already current")
        XCTAssertEqual(host.replies.filter { $0.1 == .busy }.count, 1)
    }

    func testSessionEndRestoresModeAndWindowsWithoutResuming() async {
        await apply(1280)
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertEqual(switcher.applied.last?.0, base)
        XCTAssertEqual(keeper.restores, 1)
        XCTAssertEqual(host.resumes, [1], "only the apply resumed; the session is over")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.isEngaged)
    }

    func testOffForThisSessionRestoresAndResumes() async {
        await apply(1280)
        await apply(0)
        XCTAssertEqual(switcher.applied.last?.0, base)
        XCTAssertEqual(host.resumes, [1, 1])
        XCTAssertEqual(host.replies.last?.1, nil)
    }

    func testFailedRestoreStaysPendingUntilRetried() async {
        await apply(1280)
        switcher.result = .failed(1001)
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertTrue(controller.restorePending)
        XCTAssertTrue(controller.isEngaged)
        switcher.result = .applied
        controller.retryPendingRestore()
        await controller.drain()
        XCTAssertEqual(switcher.currentByDisplay[1], base)
        XCTAssertFalse(controller.restorePending)
    }

    func testDisconnectGraceRestoresUnlessTheSessionResumes() async {
        await apply(1280)
        controller.connectionLost()
        controller.sessionResumed()
        await controller.drain()
        XCTAssertEqual(controller.current, large, "a quick reconnect keeps Big Text")
        controller.connectionLost()
        await controller.drain()
        XCTAssertEqual(switcher.currentByDisplay[1], base)
        XCTAssertGreaterThanOrEqual(clock, BigTextController.disconnectGrace)
    }

    func testTerminationRestoresSynchronously() async {
        await apply(1280)
        controller.restoreForTermination()
        XCTAssertEqual(switcher.applied.last?.0, base, "no await: quit must stay prompt")
    }

    func testApplyingOnAnotherDisplayRestoresTheFirst() async {
        await apply(1280, display: 1)
        await apply(1280, display: 2)
        XCTAssertEqual(switcher.currentByDisplay[1], base)
        XCTAssertEqual(switcher.currentByDisplay[2], large)
        XCTAssertEqual(controller.display, 2)
    }

    func testDescribeFillsScaleFields() async {
        await apply(1280)
        let described = BigTextController.describe(DisplayDescriptor(id: 1, name: "Built-in", width: 1280, height: 832),
                                                   offer: controller.offer(for: 1))
        XCTAssertEqual(described.scaleBaselineWidth, 1470, "the baseline stays the Mac's own size while applied")
        XCTAssertEqual(described.scaleCurrentWidth, 1280)
        XCTAssertEqual(described.scaleSteps?.map(\.width), [1280, 1024])
        XCTAssertNoThrow(try described.validate())
    }
}
```
`testTimeoutIsTreatedAsForeign` models "the switch reports success but the display never reaches the target mode". If Swift 6 strict concurrency rejects passing `FakeKeeper`/`BigTextWindowKeeper` across the main actor, make `BigTextWindowKeeping` inherit `Sendable` and mark `FakeKeeper` `@unchecked Sendable`; do not change behaviour.
- [ ] **Step 2: Run to verify failure** (`-XCTest BigTextControllerTests`).
- [ ] **Step 3: Implement** `BigTextController` (replace the stub body; keep the Task 0 public surface):
```swift
@MainActor
final class BigTextController {
    enum Phase: Equatable { case idle, changing, applied, restoring }
    enum RestoreReason: String { case sessionEnded, displaySwitched, sessionOff, restoreButton }

    static let settle: TimeInterval = 0.3
    static let poll: TimeInterval = 0.1
    static let disconnectGrace: TimeInterval = 20

    private enum Request: Equatable {
        case apply(CGDirectDisplayID, Double)
        case restore(RestoreReason, reply: CGDirectDisplayID?)
    }
    private enum Outcome { case ours, foreign, failed }

    private(set) var phase: Phase = .idle
    private(set) var display: CGDirectDisplayID?
    private(set) var baseline: DisplayModeInfo?
    private(set) var current: DisplayModeInfo?
    private(set) var restorePending = false
    weak var host: BigTextHost?

    var isEngaged: Bool { phase != .idle || current != nil || restorePending }
    var isChanging: Bool { phase == .changing || phase == .restoring }

    private let switcher: DisplayModeSwitching
    private let windows: BigTextWindowKeeping
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async -> Void
    private var recognizer: OwnChangeRecognizer?
    private var pending: Request?
    private var worker: Task<Void, Never>?
    private var grace: Task<Void, Never>?

    init(switcher: DisplayModeSwitching, windows: BigTextWindowKeeping,
         now: @escaping () -> TimeInterval, sleep: @escaping (TimeInterval) async -> Void) {
        self.switcher = switcher
        self.windows = windows
        self.now = now
        self.sleep = sleep
    }

    func offer(for display: CGDirectDisplayID) -> BigTextOffer? {
        guard let live = switcher.currentMode(of: display) else { return nil }
        let base = (self.display == display ? baseline : nil) ?? live
        return BigTextOffer(baseline: base, steps: BigTextSteps.steps(baseline: base, modes: switcher.modes(of: display)), current: live)
    }

    static func describe(_ descriptor: DisplayDescriptor, offer: BigTextOffer?) -> DisplayDescriptor {
        guard let offer else { return descriptor }
        var described = descriptor
        described.scaleSteps = offer.steps.map(\.step)
        described.scaleBaselineWidth = Double(offer.baseline.width)
        described.scaleCurrentWidth = Double(offer.current.width)
        return described
    }

    func request(display: CGDirectDisplayID, looksLikeWidth: Double, allowed: Bool, accessibilityGranted: Bool) {
        guard allowed else { return reply(display, .disabled) }
        guard accessibilityGranted else { return reply(display, .noAccessibility) }
        enqueue(looksLikeWidth == 0 ? .restore(.sessionOff, reply: display) : .apply(display, looksLikeWidth))
    }

    func observe(_ event: DisplayReconfigurationEvent) { recognizer?.observe(event) }

    func sessionEnded(_ reason: RestoreReason) {
        grace?.cancel()
        grace = nil
        guard current != nil || restorePending || isChanging else { return }
        enqueue(.restore(reason, reply: reason == .restoreButton ? display : nil))
    }

    func connectionLost() {
        grace?.cancel()
        guard current != nil else { return }
        grace = Task { [weak self] in
            guard let self else { return }
            await self.sleep(Self.disconnectGrace)
            guard !Task.isCancelled else { return }
            self.grace = nil
            self.sessionEnded(.sessionEnded)
        }
    }

    func sessionResumed() {
        grace?.cancel()
        grace = nil
    }

    func retryPendingRestore() {
        guard restorePending else { return }
        enqueue(.restore(.sessionEnded, reply: nil))
    }

    func restoreForTermination() {
        worker?.cancel()
        grace?.cancel()
        guard let display, let baseline, current != nil else { return }
        _ = switcher.apply(baseline, to: display)
        current = nil
    }

    func drain() async {
        while grace != nil || worker != nil {
            if let grace { await grace.value }
            if let worker { await worker.value }
        }
    }

    private func enqueue(_ request: Request) {
        guard worker != nil else { return start(request) }
        if case .apply(let superseded, _)? = pending { reply(superseded, .busy) }
        pending = request
    }

    private func start(_ first: Request) {
        worker = Task { [weak self] in
            var next: Request? = first
            while let request = next, let self, !Task.isCancelled {
                await self.perform(request)
                next = self.pending
                self.pending = nil
            }
            self?.worker = nil
        }
    }

    private func perform(_ request: Request) async {
        switch request {
        case .apply(let target, let width): await apply(width, on: target)
        case .restore(let reason, let replyTo): await restore(reason, replyTo: replyTo)
        }
    }

    private func apply(_ width: Double, on target: CGDirectDisplayID) async {
        if let display, display != target, current != nil { await restore(.displaySwitched, replyTo: nil) }
        guard let offer = offer(for: target) else { return reply(target, .failed) }
        guard let mode = BigTextSteps.nearest(to: width, in: offer.steps) else {
            return reply(target, width >= Double(offer.baseline.width) ? nil : .unsupported)
        }
        guard mode.ioModeID != offer.current.ioModeID else { return reply(target, nil) }

        let first = current == nil
        phase = .changing
        host?.bigTextStateChanged()
        host?.bigTextQuiesce()
        if first {
            display = target
            baseline = offer.baseline
            await windows.snapshot(within: host?.bigTextDisplayBounds(target) ?? .null, pids: host?.bigTextRunningAppPIDs() ?? [])
        }
        switch await change(to: mode, on: target) {
        case .ours:
            current = mode
            if first { await windows.recordSettled() }
            phase = .applied
            _ = await host?.bigTextResume(display: target)
            reply(target, nil)
        case .failed:
            if first { forget() } else { phase = .applied }
            _ = await host?.bigTextResume(display: target)
            reply(target, .failed)
        case .foreign:
            forget()
            host?.bigTextForeignChange()
        }
        host?.bigTextStateChanged()
    }

    private func restore(_ reason: RestoreReason, replyTo: CGDirectDisplayID?) async {
        guard let target = display, let baseline, current != nil || restorePending else {
            if let replyTo { reply(replyTo, nil) }
            return
        }
        let sessionContinues = reason == .sessionOff || reason == .restoreButton
        phase = .restoring
        host?.bigTextStateChanged()
        if sessionContinues { host?.bigTextQuiesce() }
        switch await change(to: baseline, on: target) {
        case .ours:
            restorePending = false
            await windows.restore()
            current = nil
            self.baseline = nil
            display = nil
            phase = .idle
        case .failed:
            restorePending = true
            phase = .idle
        case .foreign:
            forget()
            if !sessionContinues { break }
            host?.bigTextForeignChange()
            host?.bigTextStateChanged()
            return
        }
        if sessionContinues { _ = await host?.bigTextResume(display: target) }
        if let replyTo { reply(replyTo, restorePending ? .failed : nil) }
        host?.bigTextStateChanged()
    }

    private func change(to mode: DisplayModeInfo, on target: CGDirectDisplayID) async -> Outcome {
        if switcher.currentMode(of: target)?.ioModeID == mode.ioModeID { return .ours }
        recognizer = OwnChangeRecognizer(display: target, target: mode, onlineBefore: switcher.onlineDisplays(), startedAt: now())
        defer { recognizer = nil }
        guard switcher.apply(mode, to: target) == .applied else { return .failed }
        while let recognizer {
            switch recognizer.verdict(now: now(), online: switcher.onlineDisplays(), current: switcher.currentMode(of: target)) {
            case .ours:
                await sleep(Self.settle)
                return .ours
            case .foreign:
                return .foreign
            case .pending:
                await sleep(Self.poll)
            }
        }
        return .foreign
    }

    private func forget() {
        windows.discard()
        current = nil
        baseline = nil
        display = nil
        restorePending = false
        phase = .idle
    }

    private func reply(_ display: CGDirectDisplayID, _ error: BigTextError?) {
        host?.bigTextReply(display: display, error: error)
    }
}
```
- [ ] **Step 4: Run** `BigTextControllerTests`. Expected: 16 pass. Fix the implementation, not the assertions; if an assertion is genuinely wrong against the spec, stop and report it.
- [ ] **Step 5: Commit** `Drive Big Text changes and restores through one state machine`.

---

### Task 9: Phone model (Wave 2; consumes Tasks 1, 3)

**Files:**
- Modify: `RemotePhone/RemotePhoneApp.swift` (`PhoneRemoteModel` :87; `receiveDisplays` :367; `tick()` ~:1264; `end()` ~:1291; `transmit` :514; `showSessionNotice` :615), `RemotePhone/HomeView.swift` (forget action :180–185)
- Test: `RemotePhoneTests/BigTextPhoneTests.swift`

**Interfaces:**
- Consumes: `SessionFeature.displayScale`, `RemoteAction.looksLikeWidth/scaleError`, `DisplayDescriptor.scale*` (Task 1); `BigTextMemory` (Task 3).
- Produces (for Task 10): `struct BigTextState: Equatable` (below), `@Published private(set) var bigText: BigTextState`, `var bigTextSupported: Bool`, `func chooseBigText(_ width: Double?)`, `func setBigTextOffForSession(_ off: Bool)`, `static func bigTextMessage(_:) -> String`, `var lastBigTextRequest: (display: UInt32, width: Double)?`, test seams `var bigTextRoomOverride: String?`, `var bigTextMemory: BigTextMemory`, `var bigTextClock: () -> TimeInterval`, `func checkBigTextTimeout()`.

- [ ] **Step 1: Write the failing tests.** Build the host-message helpers from the existing fixture pattern in `RemotePhoneTests/MacParityPhoneTests.swift` (`model.connection.onControl?(try JSONEncoder().encode(action))`), sending `geometry` (epoch 1), then `capture` with `features: [SessionFeature.displayScale]` and `display: 1`, then `displays`:
```swift
import XCTest
@testable import PocketDeskRemote

@MainActor
final class BigTextPhoneTests: XCTestCase {
    private var defaults: UserDefaults!
    private var model: PhoneRemoteModel!
    private let builtIn = DisplayDescriptor(id: 1, name: "Built-in Retina Display", width: 1470, height: 956)

    override func setUp() async throws {
        defaults = makeTestDefaults()
        model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.bigTextMemory = BigTextMemory(defaults: defaults)
        model.bigTextRoomOverride = "room-a"
    }

    private func described(current: Double = 1470) -> DisplayDescriptor {
        var d = builtIn
        d.scaleSteps = [ScaleStep(width: 1280, height: 832), ScaleStep(width: 1024, height: 665)]
        d.scaleBaselineWidth = 1470
        d.scaleCurrentWidth = current
        return d
    }

    private func connect(features: [String] = [SessionFeature.displayScale], current: Double = 1470) throws {
        // geometry + capture exactly as MacParityPhoneTests does, with `features` and `display: 1` on capture
        try sendSessionStart(features: features)
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(current: current)], display: 1))
    }

    func testSavedLevelAppliesOnceWhenTheMacSupportsIt() throws {
        BigTextMemory(defaults: defaults).remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn])
        try connect()
        XCTAssertEqual(model.lastBigTextRequest?.width, 1280)
        XCTAssertEqual(model.bigText.savedWidth, 1280)
        model.lastBigTextRequest = nil
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1))
        XCTAssertNil(model.lastBigTextRequest, "applied once per session")
    }

    func testNothingIsSentToAnOlderMac() throws {
        BigTextMemory(defaults: defaults).remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn])
        try connect(features: [])
        XCTAssertNil(model.lastBigTextRequest)
        XCTAssertFalse(model.bigTextSupported)
    }

    func testRapidChoicesSendOnlyTheLast() async throws {
        try connect()
        model.chooseBigText(1280)
        model.chooseBigText(1024)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(model.lastBigTextRequest?.width, 1024)
        XCTAssertEqual(BigTextMemory(defaults: defaults).width(forRoom: "room-a", display: builtIn, among: [builtIn]), 1024)
    }

    func testOffForThisSessionKeepsTheSavedLevel() async throws {
        BigTextMemory(defaults: defaults).remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn])
        try connect(current: 1280)
        model.setBigTextOffForSession(true)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(model.lastBigTextRequest?.width, 0)
        XCTAssertEqual(model.bigText.savedWidth, 1280)
    }

    func testPendingTimesOutWithAMessage() throws {
        try connect()
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1280)
        XCTAssertNotNil(model.bigText.pendingTarget)
        now += 8.5
        model.checkBigTextTimeout()
        XCTAssertNil(model.bigText.pendingTarget)
        XCTAssertEqual(model.sessionNotice, "Couldn't change text size")
    }

    func testErrorsBecomeFriendlyNotices() throws {
        try connect()
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described()], display: 1, scaleError: "disabled"))
        XCTAssertEqual(model.sessionNotice, "Big Text is turned off on this Mac.")
    }

    func testEndClearsSessionState() throws {
        try connect()
        model.end()
        XCTAssertEqual(model.bigText, BigTextState())
    }
}
```
Implement `send(_:)` and `sendSessionStart(features:)` as private helpers in this file by copying the geometry/capture fixtures from `MacParityPhoneTests` (same fields, add `features` and `display: 1` to the capture action). `chooseBigTextNow(_:)` is an internal (non-debounced) variant used by tests and auto-apply. If `end()` has a different name or is private, call the model's public end/disconnect entry point used by existing tests.
- [ ] **Step 2: Run to verify failure** (phone command, `-only-testing:RemotePhoneTests/BigTextPhoneTests`).
- [ ] **Step 3: Implement** in `PhoneRemoteModel`:
```swift
struct BigTextState: Equatable {
    var steps: [ScaleStep] = []
    var baselineWidth: Double?
    var currentWidth: Double?
    var savedWidth: Double?
    var pendingTarget: Double?
    var pendingSince: TimeInterval?
    var sessionOff = false
    var autoApplied = false
}
```
(file scope, next to the model). Inside the model:
```swift
@Published private(set) var bigText = BigTextState()
var lastBigTextRequest: (display: UInt32, width: Double)?
var bigTextMemory = BigTextMemory()
var bigTextRoomOverride: String?
var bigTextClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
private var bigTextSendTask: Task<Void, Never>?
static let bigTextDebounce: Duration = .milliseconds(600)
static let bigTextTimeout: TimeInterval = 8

var bigTextSupported: Bool { supports(SessionFeature.displayScale) }
private var bigTextRoom: String? { bigTextRoomOverride ?? connection.invitation?.room }
private var currentDescriptor: DisplayDescriptor? { displays.first { $0.id == currentDisplayID } }

func chooseBigText(_ width: Double?) {
    guard bigTextSupported, let id = currentDisplayID, let descriptor = currentDescriptor else { return }
    if let room = bigTextRoom { bigTextMemory.remember(width, forRoom: room, display: descriptor, among: displays) }
    bigText.savedWidth = width
    bigText.sessionOff = false
    scheduleBigText(display: id, width: width ?? 0)
}

func setBigTextOffForSession(_ off: Bool) {
    guard bigTextSupported, let id = currentDisplayID else { return }
    bigText.sessionOff = off
    scheduleBigText(display: id, width: off ? 0 : (bigText.savedWidth ?? 0))
}

func chooseBigTextNow(_ width: Double) {
    guard let id = currentDisplayID else { return }
    sendBigText(display: id, width: width)
}

func checkBigTextTimeout() {
    guard let since = bigText.pendingSince, bigTextClock() - since > Self.bigTextTimeout else { return }
    bigText.pendingTarget = nil
    bigText.pendingSince = nil
    showSessionNotice("Couldn't change text size")
}

static func bigTextMessage(_ error: BigTextError) -> String? {
    switch error {
    case .noAccessibility: "Big Text needs Accessibility permission on your Mac."
    case .unsupported: "This display doesn't offer larger sizes."
    case .disabled: "Big Text is turned off on this Mac."
    case .failed: "Couldn't change text size. If an app is full screen on your Mac, exit full screen and try again."
    case .busy: nil
    }
}

private func scheduleBigText(display: UInt32, width: Double) {
    bigTextSendTask?.cancel()
    bigTextSendTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: Self.bigTextDebounce)
        guard let self, !Task.isCancelled else { return }
        self.sendBigText(display: display, width: width)
    }
}

private func sendBigText(display: UInt32, width: Double) {
    lastBigTextRequest = (display, width)
    // Pending even if the send failed: the 8 s timeout then tells the person, instead of silence.
    _ = transmit(RemoteAction(action: "displayScale", epoch: geometryEpoch, display: display, looksLikeWidth: width))
    bigText.pendingTarget = width
    bigText.pendingSince = bigTextClock()
}

private func updateBigText(from action: RemoteAction) {
    guard let descriptor = currentDescriptor else { return }
    bigText.steps = descriptor.scaleSteps ?? []
    bigText.baselineWidth = descriptor.scaleBaselineWidth
    bigText.currentWidth = descriptor.scaleCurrentWidth
    if let room = bigTextRoom { bigText.savedWidth = bigTextMemory.width(forRoom: room, display: descriptor, among: displays) }
    let error = action.scaleError.flatMap(BigTextError.init(rawValue:))
    if error != .busy {
        bigText.pendingTarget = nil
        bigText.pendingSince = nil
    }
    if let error, let message = Self.bigTextMessage(error) { showSessionNotice(message) }
    applySavedBigText()
}

private func applySavedBigText() {
    guard bigTextSupported, !bigText.autoApplied, !bigText.sessionOff,
          let saved = bigText.savedWidth, let id = currentDisplayID else { return }
    bigText.autoApplied = true
    guard saved != bigText.currentWidth else { return }
    sendBigText(display: id, width: saved)
}
```
Wire-ups: call `updateBigText(from: action)` at the end of `receiveDisplays(_:)`; call `checkBigTextTimeout()` in `tick()`; in `end()` add `bigTextSendTask?.cancel(); bigText = BigTextState(); lastBigTextRequest = nil`. If the model is not `@MainActor`, keep the `Task { @MainActor … }` as written. `lastBigTextRequest` is internal and settable so tests can reset it.

In `HomeView.swift` forget action (:180–185), before `connection.revoke()`: `if let room = connection.invitation?.room { BigTextMemory().forget(room: room) }`.
- [ ] **Step 4: Run** `BigTextPhoneTests` and `MacParityPhoneTests`. Expected: pass.
- [ ] **Step 5: Commit** `Apply and remember Big Text from the phone`.

---

### Task 7b: Host wiring (Wave 3; consumes Tasks 1, 4, 5, 6, 7a)

**Files:**
- Modify: `RemoteHost/HostModel.swift`, `RemoteHost/HostReadiness.swift` (`HostPreferences` :210), `RemoteHost/HostViewState.swift` (:30), `RemoteHost/BigTextController.swift` (add `BigTextRefresh` only)
- Test: `RemoteTests/BigTextHostWiringTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces (for Task 8): `HostPreferences.allowBigText: Bool`; `HostViewState.allowBigText: Bool = true`, `HostViewState.bigTextStatus: String? = nil`; `RemoteHostModel.setAllowBigText(_:)`, `RemoteHostModel.restoreNormalSize()`; `HostFeatureList.features(base:allowBigText:accessibility:)`; `BigTextRefresh.matches(frame:coreGraphicsBounds:)`.

- [ ] **Step 1: Write the failing tests** (pure pieces of the wiring):
```swift
import XCTest

final class BigTextHostWiringTests: XCTestCase {
    func testFeatureIsAdvertisedOnlyWhenAllowedAndAccessible() {
        let base = ["curtain.1"]
        XCTAssertEqual(HostFeatureList.features(base: base, allowBigText: true, accessibility: true), base + [SessionFeature.displayScale])
        XCTAssertEqual(HostFeatureList.features(base: base, allowBigText: false, accessibility: true), base)
        XCTAssertEqual(HostFeatureList.features(base: base, allowBigText: true, accessibility: false), base)
    }

    func testPreferenceDefaultsOn() {
        let suite = "BigTextHostWiringTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HostPreferences(defaults: defaults)
        XCTAssertTrue(preferences.allowBigText)
        preferences.allowBigText = false
        XCTAssertFalse(HostPreferences(defaults: defaults).allowBigText)
    }
}

final class BigTextRefreshTests: XCTestCase {
    func testAcceptsTheRefreshedFrame() {
        XCTAssertTrue(BigTextRefresh.matches(frame: CGRect(x: 0, y: 0, width: 1280, height: 832),
                                            coreGraphicsBounds: CGRect(x: 0, y: 0, width: 1280, height: 832)))
    }

    func testRejectsAFrameThatDisagreesWithCoreGraphics() {
        XCTAssertFalse(BigTextRefresh.matches(frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                             coreGraphicsBounds: CGRect(x: 0, y: 0, width: 1280, height: 832)),
                       "a stale SCDisplay would map clicks to the old size")
    }
}
```
- [ ] **Step 2: Run to verify failure** (`-XCTest BigTextHostWiringTests`, then `BigTextRefreshTests`).
- [ ] **Step 3: Implement the pure pieces.**
  - `HostPreferences`: `static let allowBigText = "allowBigTextFromPhone"` in `Key`; add `Key.allowBigText: true` to `register(defaults:)`; property:
    ```swift
    var allowBigText: Bool {
        get { defaults.bool(forKey: Key.allowBigText) }
        nonmutating set { defaults.set(newValue, forKey: Key.allowBigText) }
    }
    ```
  - In `HostModel.swift` at file scope:
    ```swift
    enum HostFeatureList {
        static func features(base: [String], allowBigText: Bool, accessibility: Bool) -> [String] {
            allowBigText && accessibility ? base + [SessionFeature.displayScale] : base
        }
    }
    ```
  - In `BigTextController.swift`:
    ```swift
    enum BigTextRefresh {
        static func matches(frame: CGRect, coreGraphicsBounds: CGRect) -> Bool {
            abs(frame.width - coreGraphicsBounds.width) < 1 && abs(frame.height - coreGraphicsBounds.height) < 1 &&
                abs(frame.minX - coreGraphicsBounds.minX) < 1 && abs(frame.minY - coreGraphicsBounds.minY) < 1
        }
    }
    ```
- [ ] **Step 4: Run** those tests. Expected: pass.
- [ ] **Step 5: Wire `RemoteHostModel`** (each edit named by the function it touches; line numbers from the 30 Sep map):
  1. Properties next to `capture` (:127):
     ```swift
     private lazy var bigText = BigTextController(
         switcher: LiveDisplayModeSwitcher(), windows: BigTextWindowKeeper(access: LiveWindowAccess()),
         now: { ProcessInfo.processInfo.systemUptime }, sleep: { try? await Task.sleep(for: .seconds($0)) })
     private lazy var reconfigurationMonitor = DisplayReconfigurationMonitor { [weak self] in self?.bigText.observe($0) }
     ```
     In `init`, after the observers are registered: `bigText.host = self; reconfigurationMonitor.start()`.
  2. `advertisedFeatures` (:1641): change from `private static var` to an instance `private var advertisedFeatures: [String]` returning `HostFeatureList.features(base: <existing static list expression>, allowBigText: preferences.allowBigText, accessibility: accessibilityPermission.isGranted)`; update `sendCaptureHealth` to use `advertisedFeatures`.
  3. Screen observer (:352): first line in the `Task { @MainActor in … }` body after `guard let self`: `guard !self.bigText.isChanging else { return }`.
  4. `beginCapture()` (:1231) → `beginCapture(keepingExclusions: Bool = false)`: pass `keepingExclusions` to `capture.start(display:peer:keepingExclusions:)`; call `bigText.sessionResumed()` once the new capture is current.
  5. Curtain inputs (where `PrivacyCurtainInputs` is built in `reconcileCurtain`, :971): set `displayReconfiguring: bigText.isChanging`. Every `HangWatchdogPolicy`/watchdog `update(curtainUp:recoveryEnabled:)` call (:750, :916, :923, :932, :996, :1036): pass `bigTextEngaged: bigText.isEngaged` (add the parameter to `update` in `HostHangWatchdog.swift`, forwarding to `threshold`).
  6. `receiveDisplaySelection(_:)` (:1703): before the existing `guard … action.epoch == inputEpoch.value …`, add `if action.action == "displayScale", action.epoch != inputEpoch.value { return sendDisplayList() }` (stale requests get the current epoch, never silence); add a case:
     ```swift
     case "displayScale":
         guard let requested = action.display, let width = action.looksLikeWidth else { return }
         bigText.request(display: requested, looksLikeWidth: width, allowed: preferences.allowBigText,
                         accessibilityGranted: accessibilityPermission.isGranted)
     ```
  7. `sendDisplayList()` (:1734) → `sendDisplayList(scaleError: BigTextError? = nil)`: after `HostDisplayCatalog.descriptors(entries)`, when `preferences.allowBigText && accessibilityPermission.isGranted`, map each descriptor through `BigTextController.describe($0, offer: bigText.offer(for: $0.id))`; add `scaleError: scaleError?.rawValue` to the `RemoteAction`.
  8. Session-end points: `stop()` (:1061) first line `bigText.sessionEnded(.sessionEnded)`; `stopForTermination()` (:1073) first line `bigText.restoreForTermination()`; `connection.onEnded` handler (:293) add `bigText.connectionLost()` before `endCapture()`; `switchSessionDisplay(to:)` (:1727) first line `bigText.sessionEnded(.displaySwitched)`; `handleAvailability(_:)` `.recover` path (:1809–1818) add `bigText.retryPendingRestore()`. (`selectDisplay`, `captureFailed`, `revoke`, `removeServerRoom`, Screen Recording loss and lock/sleep teardown all route through `stop()`.)
  9. Conform to `BigTextHost` in an extension **in `HostModel.swift`** (same file, so it can assign the `private(set)` `displays` and call private helpers):
     ```swift
     extension RemoteHostModel: BigTextHost {
         func bigTextQuiesce() {
             releaseRemoteInput(notifyPhone: true)
             inputFreshness.invalidate()
             input.enabled = false
             captureHealthy = false
             captureAttempt &+= 1
             captureTask?.cancel()
             _ = capture.stop(keepingExclusions: true)
             curtain.followsScreenChanges = false
             reconcileCurtain()
         }

         func bigTextResume(display: CGDirectDisplayID) async -> Bool {
             defer { curtain.followsScreenChanges = true }
             for attempt in 0..<2 {
                 if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
                 guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                       let refreshed = content.displays.first(where: { $0.displayID == display }),
                       BigTextRefresh.matches(frame: refreshed.frame, coreGraphicsBounds: CGDisplayBounds(display))
                 else { continue }
                 displays = content.displays
                 curtain.refitToScreens()
                 beginCapture(keepingExclusions: curtain.phase == .up)
                 return true
             }
             bigTextForeignChange()
             return false
         }

         func bigTextReply(display: CGDirectDisplayID, error: BigTextError?) { sendDisplayList(scaleError: error) }

         func bigTextForeignChange() {
             curtain.followsScreenChanges = true
             stop()
             invalidateDisplays(status: .notChecked)
             loadDisplays()
         }

         func bigTextStateChanged() {
             reconcileCurtain()
             objectWillChange.send()
         }

         func bigTextDisplayBounds(_ display: CGDirectDisplayID) -> CGRect { CGDisplayBounds(display) }

         func bigTextRunningAppPIDs() -> [pid_t] {
             NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)
         }
     }
     ```
     Use the model's real names where they differ (`inputFreshness.invalidate()` vs `expireTokens()`, the curtain phase enum, `selected`'s `didSet` side effects — do **not** assign `selected` here). `displays` must be assigned directly because `loadDisplays()` returns early while `active`.
  10. View state for Task 8: add to `HostViewState` `var allowBigText = true` and `var bigTextStatus: String? = nil`; set both where `viewState` is built (:222, :247): `allowBigText: preferences.allowBigText`, and `bigTextStatus` = `"Restoring normal size…"` when `bigText.restorePending || bigText.phase == .restoring`, else `"Big Text on · looks like \(w) × \(h)"` from `bigText.current`, else `nil`. Add:
      ```swift
      func setAllowBigText(_ allowed: Bool) {
          preferences.allowBigText = allowed
          if !allowed { bigText.sessionEnded(.restoreButton) }
          sendCaptureHealth(captureHealthy)
          objectWillChange.send()
      }

      func restoreNormalSize() { bigText.sessionEnded(.restoreButton) }
      ```
      (Match `sendCaptureHealth`'s real signature; it re-advertises features.)
- [ ] **Step 6: Build and run the full core suite.** Core build command, then `lockf -k /tmp/farside-xcodebuild.lock xcrun xctest "$DD/Build/Products/Debug/RemoteCoreTests.xctest"`. Expected: all previous tests still pass (record the count; the 30 Sep baseline was 694 with 3 optional skips) plus the new Big Text classes. Also build `PocketDeskRemoteHost` with `CODE_SIGNING_ALLOWED=NO`.
- [ ] **Step 7: Commit** `Wire Big Text into the Mac host session lifecycle`.

---

### Task 10: Phone UI (Wave 3; consumes Task 9)

**Files:**
- Modify: `RemotePhone/NativeSessionView.swift` (`pictureSection` :1914–1932; `sessionRows` :1404; `panelHeight` :1242–1248; `topPills` :433–494; `centerNotices` :402), `RemotePhone/RemotePhoneApp.swift` (input-probe fakes :340–380 only)
- Test: `RemotePhoneUITests/BigTextUITests.swift`

**Interfaces:**
- Consumes: Task 9's `bigText`, `bigTextSupported`, `chooseBigText`, `setBigTextOffForSession`.
- Produces: accessibility identifiers `remote.bigText.off`, `remote.bigText.step.<index>`, `remote.bigText.sessionOff`, `remote.bigTextRow`, `remote.bigText.pill`.

- [ ] **Step 1: Write the failing UI test,** reusing the helpers in `RemotePhoneUITests/PhoneParityUITests.swift` (`openSettingsPage` :729) and the launch arguments `--ui-layout-check --ui-input-probe` used by `testDisplayPickerListsDisplaysAndSwitchesTheStream` (:395):
```swift
import XCTest

final class BigTextUITests: XCTestCase {
    func testChoosingAStepShowsProgressThenSelection() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-layout-check", "--ui-input-probe"]
        app.launch()
        openSettingsPage(app, "picture")   // copy the helper body from PhoneParityUITests.openSettingsPage
        let step = app.buttons["remote.bigText.step.0"]
        XCTAssertTrue(step.waitForExistence(timeout: 5))
        step.tap()
        XCTAssertTrue(app.otherElements["remote.bigText.pill"].waitForExistence(timeout: 3))
        XCTAssertTrue(step.waitForSelected(timeout: 5))
        XCTAssertTrue(app.switches["remote.bigText.sessionOff"].exists)
    }
}

private extension XCUIElement {
    func waitForSelected(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isSelected == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}
```
- [ ] **Step 2: Extend the input-probe fake** (`RemotePhoneApp.swift` :340–380): give `probeDisplays[0]` `scaleSteps` `[1280×832, 1024×665]`, `scaleBaselineWidth: 1470`, `scaleCurrentWidth: 1470`; when the probe transmits `displayScale`, after 0.3 s deliver a `displays` reply with `scaleCurrentWidth` set to the requested width (or 1470 for 0). Under the probe `supports(_:)` already returns true.
- [ ] **Step 3: Run to verify failure** (`-only-testing:RemotePhoneUITests/BigTextUITests`).
- [ ] **Step 4: Implement the views** in `NativeSessionView.swift`:
```swift
@ViewBuilder private var bigTextSection: some View {
    if model.bigTextSupported {
        Section {
            bigTextOption(title: "Off", caption: "Your Mac's own size", width: nil, id: "remote.bigText.off")
            ForEach(Array(model.bigText.steps.enumerated()), id: \.offset) { index, step in
                bigTextOption(title: Self.bigTextNames[min(index, Self.bigTextNames.count - 1)],
                              caption: "looks like \(Int(step.width)) × \(Int(step.height))",
                              width: step.width, id: "remote.bigText.step.\(index)")
            }
            if model.bigText.steps.isEmpty {
                Text("Already at the largest size").font(.footnote).foregroundStyle(.secondary)
            }
            if model.bigText.savedWidth != nil {
                Toggle("Off for this session", isOn: Binding(get: { model.bigText.sessionOff },
                                                             set: { model.setBigTextOffForSession($0) }))
                    .accessibilityIdentifier("remote.bigText.sessionOff")
            }
        } header: {
            sectionHeader("Big Text")
        } footer: {
            Text("Makes everything on your Mac bigger while this phone is connected. Saved for this Mac.")
        }
    }
}

private static let bigTextNames = ["Large", "Larger", "Very large", "Largest"]

private func bigTextOption(title: String, caption: String, width: Double?, id: String) -> some View {
    let selected = model.bigText.savedWidth == width
    return Button { model.chooseBigText(width) } label: {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(caption).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if selected { Image(systemName: "checkmark") }
        }
    }
    .accessibilityIdentifier(id)
    .accessibilityAddTraits(selected ? .isSelected : [])
}
```
  - Append `bigTextSection` after the existing Section inside `pictureSection`.
  - Panel row: `private var showsBigTextRow: Bool { model.bigTextSupported && model.bigText.savedWidth != nil }`; in `sessionRows` add, styled like the "Hide Mac screen" toggle row:
    ```swift
    if showsBigTextRow {
        Toggle("Big Text", isOn: Binding(get: { !model.bigText.sessionOff }, set: { model.setBigTextOffForSession(!$0) }))
            .accessibilityIdentifier("remote.bigTextRow")
    }
    ```
    and in `panelHeight` add the same per-row height the display row adds when `showsBigTextRow` is true.
  - Pill in `topPills`, modelled on `clipboardStatus` (:496):
    ```swift
    if let target = model.bigText.pendingTarget {
        HStack(spacing: 8) {
            ProgressView()
            Text(target == 0 ? "Restoring text size…" : "Making text bigger…")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("remote.bigText.pill")
    }
    ```
    using the same background/padding modifiers as `clipboardStatus`.
  - `centerNotices` (:402): do not show "Waiting for your Mac's screen…" while `model.bigText.pendingTarget != nil`.
- [ ] **Step 5: Run** `BigTextUITests`, `SessionLayoutTests/testPictureQualityCanSwitchWithoutOpeningKeyboard`, `PhoneParityUITests/testDisplayPickerListsDisplaysAndSwitchesTheStream`. Expected: pass. Shut down the simulator.
- [ ] **Step 6: Commit** `Add Big Text controls, panel toggle and progress pill on the phone`.

---

### Task 8: Mac UI (Wave 4; consumes Task 7b)

**Files:**
- Modify: `RemoteHost/HostViewState.swift` (`HostActions` :79/:103), `RemoteHost/HostSettingsView.swift` (`sharingSection` :57–89), `RemoteHost/HostPopoverView.swift` (`sessionToggles` :65–102), `RemoteHost/RemoteHostApp.swift` (bindings :148)
- Test: existing `HostUISnapshotTests` scheme

**Interfaces:**
- Consumes: `HostViewState.allowBigText`, `.bigTextStatus`, `RemoteHostModel.setAllowBigText(_:)`, `.restoreNormalSize()` (Task 7b).

- [ ] **Step 1: Add actions.** `HostActions`: `var setAllowBigText: (Bool) -> Void = { _ in }` and `var restoreNormalSize: () -> Void = {}` (follow the existing declaration style; if actions are non-defaulted `let`s, add them the same way and update every construction site). Bind in `RemoteHostApp.swift` next to the privacy-curtain binding: `setAllowBigText: model.setAllowBigText`, `restoreNormalSize: model.restoreNormalSize`.
- [ ] **Step 2: Settings row.** In `sharingSection`, directly after the "Hide this Mac's screen" row (:73–77), add a row built exactly like it: title "Allow a connected phone to change text size", detail "Big Text. Your Mac's size comes back when the phone disconnects. Windows on other Spaces may stay smaller.", switch bound to `state.allowBigText` / `actions.setAllowBigText`.
- [ ] **Step 3: Popover.** In `sessionToggles`, when `let status = state.bigTextStatus`: a status line with `status` and, unless it starts with "Restoring", a bordered button **Restore normal size** calling `actions.restoreNormalSize`.
- [ ] **Step 4: Build and run** `HostUISnapshotTests` (`-scheme HostUISnapshotTests`, same build-for-testing/xctest pattern). If a reference differs only by the new Settings row, re-record using that suite's documented record mode (see `HostUITests/`) and state this in the commit body; any other difference is a failure to fix.
- [ ] **Step 5: Commit** `Show Big Text status and controls on the Mac`.

---

### Task 11: Integration, review and ledger (orchestrator)

- [ ] **Step 1:** Merge waves into `farside-big-text` in order (0 → 1 → 2 → 3 → 4). Run `xcodegen generate`; the project file must have no diff (Task 0 registered everything); if it does, commit it with the reason.
- [ ] **Step 2:** Full verification, one build at a time under the lock: `RemoteCoreTests` (all), `PocketDeskRemoteHost` build (`CODE_SIGNING_ALLOWED=NO`), `RemotePhoneTests` (all), `RemotePhoneUITests` targeted (`BigTextUITests`, `SessionLayoutTests`, `PhoneParityUITests/testDisplayPickerListsDisplaysAndSwitchesTheStream`), `HostUISnapshotTests`. Record exact counts. Shut down simulators.
- [ ] **Step 3:** Whole-branch independent review (fresh Opus agent, read-only) against the spec and this plan's Review Focus; fix confirmed findings with bounded follow-up tasks.
- [ ] **Step 4:** Add a ledger section to `Docs/IMPLEMENTATION-PLAN.md` (`# Big Text — <date>`, package/write-set/evidence table, counts, commit SHAs, "physical acceptance pending"). Update PRODUCT.md D38 status to "Implemented on `farside-big-text`; physical acceptance pending". Push `farside-big-text`. Do **not** merge into `pocketdesk-remote-chat` or install anything without Roshan's go-ahead.

### Task 12: Physical gates (Roshan + orchestrator, quiet window only)

Not executable by subagents. Requires the integrated main checkout, `script/build_and_run.sh`, the iPhone, and no other agents running:
- [ ] Readability/cost comparison first (spec §10): same text sample at Off, middle Big Text step, and viewport zoom; record encode ms, fps, bitrate from stream statistics.
- [ ] Spec §9 physical list: each step applies ≤ ~1 s without ending the session; clicks land correctly right after a change; drag held across a change is released; curtain stays covering; `kill -9` host → mode reverts; full-screen app → friendly refusal; System Settings resolution change mid-session → session stops and the person's choice is kept; End restores mode and windows; external monitor if available.
