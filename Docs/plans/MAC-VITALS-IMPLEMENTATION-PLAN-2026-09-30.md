# Mac Vitals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** During a session the phone shows the Mac's battery, temperature, Low Power Mode and a coarse "busy with other apps" level (Controls caption, notices, dock line, Diagnostics), and the Home card remembers a last-seen low battery for 12 h.

**Architecture:** The host samples IOKit power sources, `ProcessInfo` and whole-Mac CPU/memory pressure behind an injectable `MacVitalsSources` protocol, reduces them in a pure `MacVitalsMonitor`/`MacLoadPolicy`, and sends one optional, clamped `MacVitals` object on every `capture` status. Everything the phone decides (caption, spoken sentence, Diagnostics rows, notice policy, Home memory) lives in pure `RemoteShared` types tested on macOS without a simulator; the phone model and views only wire them in. A scaffold task pre-creates every new file and registers it in `project.yml`/the Xcode project so parallel agents never touch the generated project.

**Tech Stack:** Swift (language mode 5), SwiftUI, IOKit power sources (`IOKit.ps`), Mach `host_statistics(HOST_CPU_LOAD_INFO)`, `getrusage`, `DispatchSource.makeMemoryPressureSource`, XCTest, XcodeGen.

**Spec:** `Docs/plans/MAC-VITALS-DESIGN-2026-09-30.md` (revision 1, approved 30 Sep with every recommended answer: Q1-A caption, Q2-B coarse load, Q3-B Home last-seen, Q4-A 20 %/10 % plus unplug).

**Branch:** `farside-mac-vitals`, created from `farside-connection-health` at `84d871e` (unmerged; its own worktree is locked by another agent and must not be touched). **A rebase onto `pocketdesk-remote-chat` is required when connection-health lands.** Expected conflicts, all small: `RemoteHost/HostModel.swift` (`sendCaptureHealth` argument list), `RemoteShared/ControlProtocol.swift` (Big Text also appends fields after `busy`), `project.yml` (Big Text appends to the same `RemoteCoreTests` source line), `RemotePhone/NativeSessionView.swift` (Diagnostics page), `PRODUCT.md` decision rows.

## Global Constraints

- Deployment: iOS/iPadOS 26+, macOS 26+, Apple silicon only (D35). New `RemoteShared` files compile for iOS **and** macOS: Foundation only, no IOKit, AppKit or UIKit.
- Capability: `SessionFeature.macVitals = "vitals.1"`, added to `SessionFeature.host`. The phone sends nothing new.
- Wire field: `RemoteAction.macVitals: MacVitals?`, declared **after** `busy`, `capture` status only; validated before the display/extension early returns.
- Ranges: `batteryPercent` 0…100, `batteryWarning` 1…3, `thermal` 0…3; `power`, `load`, `loadCause` are 1…12 ASCII letters or digits. Host clamps before sending; phone maps unknown strings to nil.
- Load: busy when processor use **excluding Farside** averages ≥ 85 % over 10 s, or memory pressure is critical; clears when the 10 s average is < 70 % and pressure is not critical (normal clears memory; warning leaves it as it was). Only the level and cause (`processor`/`memory`) are sent, never a percentage, process name or PID.
- Host cadence: CPU sample every 2 s; power re-read only after an IOKit power notification, at most once per second; thermal and Low Power Mode read with each status. Sampling exists only between `beginLoadMonitor` and `endLoadMonitor`.
- Phone: vitals older than 3 s are treated as absent. Notices use the existing 6 s session notice via `announce(_:)`, at most one vitals notice per 6 s.
- Home memory: `UserDefaults` key `"macVitalsLastSeen"`, only `{percent, at}`, stored when a session ends on battery at ≤ 10 %, shown for 12 h, cleared by Forget This Mac.
- Exact copy (curly ’ as elsewhere in the app):
  - Captions: `Mac · on battery 64%`, `Mac · charging 82%`, `Mac · plugged in`, `Mac · running normally`, `Mac · on UPS 80%`; suffixes in order ` · hot` / ` · warm`, ` · Low Power Mode`, ` · busy`.
  - Spoken: `Your Mac: on battery, 12 percent, Low Power Mode, busy.`
  - Notices: `Your Mac is now on battery · 64%.` · `Your Mac is on battery · 18%. Plug it in to keep going.` · `Your Mac is at 9% and may sleep soon. Plug it in or save your work.` · `Your Mac is busy with other apps, so it may respond slowly.`
  - Dock: `Mac battery low · plug it in`, `Mac busy · other apps are using it`.
  - Older host: `Your Mac’s Farside is too old to report battery and load. Update it on your Mac.`
  - Home: `Last seen on battery · 4%` and, after a Mac-reported sleep, `It was on battery at 4%, which may be why.`
- Code comments only where the *why* is non-obvious; no docstrings restating names (repo and user rule).
- Repo rules: every `xcodebuild`/`xctest` wrapped in `lockf -k /tmp/farside-xcodebuild.lock`; never install to a phone or `/Applications`; never run `script/build_and_run.sh`; never touch other worktrees or `~/Developer/PocketDesk`; never merge into `pocketdesk-remote-chat`; only the simulator "Farside Vitals iPhone", shut down after each run; commit messages imperative, with a body, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. If a performance "quiet window" is announced, stop building until told it is over.

## Plan interpretations of the spec (decided here, recorded in PRODUCT at the end)

1. **"running normally" with a suffix.** The spec says "running normally plus suffixes"; `Mac · running normally · hot` contradicts itself, so the base words are dropped when a suffix is present (`Mac · hot · busy`).
2. **UPS copy** (spec gives none): caption `Mac · on UPS 80%` / `Mac · on UPS`, spoken "on UPS power". No notices for UPS (they are about the Mac's own battery).
3. **Pill suppression.** A visible busy pill whose reason is `thermal` or `power` holds the unplug, 20 % and busy notices (they stay armed and show when the pill clears). The 10 %/final notice is never held: it warns of sleep. A held unplug notice is dropped if not shown within 10 s ("now on battery" would be stale).
4. **Unplug** means an observed adapter→battery change within the session; a session that starts on battery gets no unplug notice (the caption already says it). Unplugging at ≤ 20 % shows only the more severe notice.
5. **Re-arm.** 20 % re-arms at ≥ 25 % or on the adapter; 10 % re-arms at ≥ 15 % (and no final warning) or on the adapter; unplug re-arms on the adapter; busy is once per session. A session is one coordinator session: an automatic reconnect starts a new one.
6. **Battery-low health** (`.macBatteryLow`) is on battery at ≤ 10 % or macOS's final warning. It is *not* advisory, so it replaces "Controlling your Mac" in the dock; `.macUnderLoad` is advisory like a slow network (added to `isSlowOnly`). Both rank after Accessibility-off and before a slow network.
7. **Landscape/iPad** Controls is a one-row overlay with no header, so the caption appears only on the iPhone portrait panel; landscape and iPad get vitals through notices, the dock line and Diagnostics.
8. The caption is limited to one line (`minimumScaleFactor(0.75)`) and capped at `.xxxLarge` Dynamic Type so the fixed D36 panel height never changes; the full sentence is its VoiceOver label and Diagnostics shows everything at full size.
9. **Clearing uses the same rolling 10 s average as entering**, so a sharp drop in load clears sooner than 10 s (about 4–6 s); the spec's "about 10–15 s" is an inferred physical expectation, not a rule.
10. A session end records the last vitals to Home memory only if that session received at least one status, so a failed reconnect never erases what the Home card shows.

## Review Focus

1. **A failed reconnect erases the Home "last seen" battery** (the moment it matters most: the Mac slept). Test: Task 7 `testAFailedAttemptKeepsTheLastSeenBattery`.
2. **A malformed or future vitals value ends the session** (validation failure is fatal, `RemoteCoordinator.swift:599-604`). Tests: Task 1 `testClampedAlwaysValidates`, `testUnknownWordsBecomeNil`; Task 3 `testOutputAlwaysValidates`.
3. **Battery hovering at 20 % or 10 % repeats the notice.** Test: Task 5 `testHoveringAtTwentyNotifiesOnce`, `testHoveringAtTenNotifiesOnce`.
4. **Farside itself is the heavy process and the Mac is called "busy with other apps".** Test: Task 3 `testFarsidesOwnLoadIsSubtracted`.
5. **Two vitals notices in one moment overwrite each other, or a held one shows long after it stopped being true.** Tests: Task 5 `testNoticesAreSpacedSoNoneIsOverwritten`, `testAHeldUnplugNoticeExpires`.

---

## Execution model (read first)

- **Waves.** Task 0 alone. Wave 1: Tasks 1, 2, 3, 4, 5 in parallel (macOS core tests only). Wave 2: Tasks 6 and 7 in parallel. Wave 3: Task 8. Wave 4: Task 9 (orchestrator). Check `df -h / /Volumes/Studio` before each wave; stop if either has < 20 GB free.
- **One worktree per task:** `git -C /Users/roshansilva/Developer/PocketDesk worktree add -b vitals/<task> .claude/worktrees/vitals-<task> farside-mac-vitals` after the previous wave is merged. Work only there.
- **Never commit `PocketDesktop.xcodeproj` or `project.yml` in Tasks 1–8.** Task 0 registers every new file. Do not add new files beyond those listed; if one is truly needed, stop and report.
- **Builds.** `DD=/Volumes/Studio/Development/Caches/Xcode/DerivedData/vitals-<task>` and `SPM=/Volumes/Studio/Development/Caches/Xcode/SourcePackages/vitals` (shared package checkout). Delete `$DD` after the task is merged.
- **Mac core test command** (Tasks 1–6):
  ```bash
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme RemoteCoreTests -destination platform=macOS -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" -collect-test-diagnostics never build-for-testing
  lockf -k /tmp/farside-xcodebuild.lock xcrun xctest -XCTest <ClassName> "$DD/Build/Products/Debug/RemoteCoreTests.xctest"
  ```
- **Host app build** (Task 6): `lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemoteHost -destination platform=macOS -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" CODE_SIGNING_ALLOWED=NO build`
- **Phone test command** (Tasks 7–8):
  ```bash
  SIM=$(xcrun simctl list devices -j | python3 -c "import json,sys;print([d['udid'] for r in json.load(sys.stdin)['devices'].values() for d in r if d['name']=='Farside Vitals iPhone'][0])")
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -destination "id=$SIM" -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" -parallel-testing-enabled NO -collect-test-diagnostics never -only-testing:<Target>/<ClassName> test
  xcrun simctl shutdown "$SIM"
  ```
- **Report** exact pass/fail/skip counts and the commit SHA. A failing unrelated pre-existing test is reported, not "fixed".

---

### Task 0: Scaffold, feature flag, simulator (orchestrator, alone)

**Files:**
- Create (contents below): `RemoteShared/MacVitals.swift`, `RemoteShared/MacVitalsPresentation.swift`, `RemoteShared/MacVitalsNotices.swift`, `RemoteShared/MacVitalsMemory.swift`, `RemoteHost/MacVitalsSources.swift`, `RemoteHost/MacVitalsMonitor.swift`
- Create (empty test classes): `RemoteTests/MacVitalsProtocolTests.swift`, `RemoteTests/MacVitalsPowerTests.swift`, `RemoteTests/MacVitalsMonitorTests.swift`, `RemoteTests/MacVitalsPresentationTests.swift`, `RemoteTests/MacVitalsNoticeTests.swift`, `RemoteTests/MacVitalsMemoryTests.swift`, `RemotePhoneTests/MacVitalsPhoneTests.swift`, `RemotePhoneUITests/MacVitalsUITests.swift`
- Modify: `RemoteShared/ControlProtocol.swift` (field after `busy`, line 46), `project.yml` (RemoteCoreTests `sources`, line 245), `PocketDesktop.xcodeproj` (regenerated), `Docs/plans/MAC-VITALS-DESIGN-2026-09-30.md` (status line)

**Interfaces:** Produces every type used below. The typed accessors on `MacVitals` are real (other tasks rely on them); every other body is a stub so each task's tests fail first.

- [ ] **Step 1: Spec status.** Change the design's status sentence to: "Status: **approved 30 September 2026 (see Decisions); implemented on `farside-mac-vitals` per `MAC-VITALS-IMPLEMENTATION-PLAN-2026-09-30.md`.**"
- [ ] **Step 2: Stub sources.**

`RemoteShared/MacVitals.swift`:
```swift
import Foundation

extension SessionFeature {
    static let macVitals = "vitals.1"
}

/// The Mac's battery, temperature, Low Power Mode and whole-Mac load, on `capture` status. A field the
/// Mac could not read is omitted. Strings are checked by length and charset rather than by enum, so a
/// newer Mac's new word never ends a session (validation failures are fatal); the accessors map unknown words to nil.
struct MacVitals: Codable, Equatable {
    enum Power: String { case battery, ac, ups }
    enum Load: String { case ok, busy }
    enum LoadCause: String { case processor, memory }
    enum Thermal: Int { case nominal, fair, serious, critical }

    static let percentRange = 0...100
    static let warningRange = 1...3
    static let thermalRange = 0...3
    static let maxWordLength = 12

    var power: String? = nil
    var batteryPercent: Int? = nil
    var charging: Bool? = nil
    /// `IOPSGetBatteryWarningLevel`: 1 none, 2 early (about 20 minutes left), 3 final (about 10). Not guaranteed.
    var batteryWarning: Int? = nil
    /// `ProcessInfo.ThermalState` raw value.
    var thermal: Int? = nil
    var lowPowerMode: Bool? = nil
    var load: String? = nil
    var loadCause: String? = nil

    var powerSource: Power? { power.flatMap(Power.init(rawValue:)) }
    var loadLevel: Load? { load.flatMap(Load.init(rawValue:)) }
    var cause: LoadCause? { loadCause.flatMap(LoadCause.init(rawValue:)) }
    var thermalLevel: Thermal? { thermal.flatMap(Thermal.init(rawValue:)) }
    var onBattery: Bool { powerSource == .battery }

    func validate() throws {}
    func clamped() -> MacVitals { self }
}
```

`RemoteShared/MacVitalsPresentation.swift`:
```swift
import Foundation

struct MacVitalsPresentation: Equatable {
    struct Row: Equatable {
        var title: String
        var value: String
    }

    static let tooOld = "Your Mac’s Farside is too old to report battery and load. Update it on your Mac."
    static let waiting = "Waiting for your Mac to report."

    let caption: String
    let spoken: String
    let isWarning: Bool
    let rows: [Row]

    init(_ vitals: MacVitals) {
        caption = ""
        spoken = ""
        isWarning = false
        rows = []
    }

    #if DEBUG
    static func preview(_ name: String) -> MacVitals? { nil }
    #endif
}
```

`RemoteShared/MacVitalsNotices.swift`:
```swift
import Foundation

enum MacVitalsNotice {
    static let busy = "Your Mac is busy with other apps, so it may respond slowly."
    static func unplugged(_ percent: Int?) -> String { "" }
    static func low(_ percent: Int) -> String { "" }
    static func critical(_ percent: Int?) -> String { "" }
}

struct MacVitalsNoticePolicy {
    static let lowPercent = 20
    static let criticalPercent = 10
    static let rearmRise = 5
    static let spacing: TimeInterval = 6
    static let unplugWindow: TimeInterval = 10

    init() {}

    mutating func observe(_ vitals: MacVitals?, pill: BusyState?, now: TimeInterval) -> String? { nil }
}
```

`RemoteShared/MacVitalsMemory.swift`:
```swift
import Foundation

struct MacVitalsMemory {
    struct LastSeen: Codable, Equatable {
        var percent: Int
        var at: Date
    }

    static let defaultsKey = "macVitalsLastSeen"
    static let lifetime: TimeInterval = 12 * 60 * 60
    static let threshold = 10
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func record(_ vitals: MacVitals?, at date: Date) {}
    func lastSeen(now: Date) -> LastSeen? { nil }
    func forget() {}
    static func homeNote(_ seen: LastSeen) -> String { "" }
    static func sleepNote(_ seen: LastSeen) -> String { "" }
}
```

`RemoteHost/MacVitalsSources.swift`:
```swift
import Foundation

struct MacPowerReading: Equatable {
    var power: String? = nil
    var batteryPercent: Int? = nil
    var charging: Bool? = nil
}

enum MacMemoryPressure: Equatable { case normal, warning, critical }

struct CPUTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

@MainActor
protocol MacVitalsSources: AnyObject {
    var powerGeneration: Int { get }
    var memoryPressure: MacMemoryPressure { get }
    func start()
    func stop()
    func readPower() -> MacPowerReading?
    func batteryWarningLevel() -> Int
    func thermalState() -> Int
    func lowPowerMode() -> Bool
    func cpuTicks() -> CPUTicks?
    func ownCPUSeconds() -> Double
    func processorCount() -> Int
}

enum MacPowerParser {
    static func reading(descriptions: [[String: Any]], providingType: String?) -> MacPowerReading? { nil }
}

@MainActor
final class LiveMacVitalsSources: MacVitalsSources {
    private(set) var powerGeneration = 0
    private(set) var memoryPressure: MacMemoryPressure = .normal

    init() {}

    func start() {}
    func stop() {}
    func readPower() -> MacPowerReading? { nil }
    func batteryWarningLevel() -> Int { 1 }
    func thermalState() -> Int { 0 }
    func lowPowerMode() -> Bool { false }
    func cpuTicks() -> CPUTicks? { nil }
    func ownCPUSeconds() -> Double { 0 }
    func processorCount() -> Int { 1 }
}
```

`RemoteHost/MacVitalsMonitor.swift`:
```swift
import Foundation

enum MacCPU {
    static func othersFraction(previous: CPUTicks, current: CPUTicks, ownCPUSeconds: Double,
                               wallSeconds: TimeInterval, processors: Int) -> Double? { nil }
}

struct MacLoadPolicy {
    static let window: TimeInterval = 10
    static let busyAt = 0.85
    static let clearBelow = 0.70

    init() {}

    var level: MacVitals.Load { .ok }
    var cause: MacVitals.LoadCause? { nil }
    mutating func observe(processorFraction: Double, over duration: TimeInterval) {}
    mutating func observe(memoryPressure: MacMemoryPressure) {}
}

@MainActor
final class MacVitalsMonitor {
    static let processorInterval: TimeInterval = 2
    static let powerInterval: TimeInterval = 1

    private let sources: MacVitalsSources
    private(set) var isRunning = false

    init(sources: MacVitalsSources) { self.sources = sources }

    func start(now: TimeInterval) {}
    func stop() {}
    func current(now: TimeInterval) -> MacVitals? { nil }
}
```

`RemoteShared/ControlProtocol.swift`, after `var busy: BusyState? = nil`:
```swift
    /// Battery, temperature, Low Power Mode and whole-Mac load, on `capture` status (`SessionFeature.macVitals`).
    var macVitals: MacVitals? = nil
```

Each empty test file (`import XCTest` + `final class <Name>: XCTestCase {}`): `MacVitalsProtocolTests`, `MacVitalsPowerTests`, `MacVitalsMonitorTests`, `MacVitalsPresentationTests`, `MacVitalsNoticeTests`, `MacVitalsMemoryTests`. The phone files add `@testable import PocketDeskRemote`; `MacVitalsPhoneTests` is `@MainActor`; `MacVitalsUITests` imports only XCTest.

- [ ] **Step 3: Register host files for core tests.** In `project.yml` RemoteCoreTests `sources`, after `RemoteHost/HostLoadMonitor.swift` add `RemoteHost/MacVitalsSources.swift, RemoteHost/MacVitalsMonitor.swift`. (`RemoteShared`, `RemoteTests`, `RemotePhoneTests`, `RemotePhoneUITests` and the host app's `RemoteHost` are folder sources.)
- [ ] **Step 4: Regenerate and build all three products once.**
  ```bash
  xcodegen generate
  git diff --stat PocketDesktop.xcodeproj   # expect only the new files; revert unrelated churn if any
  DD=/Volumes/Studio/Development/Caches/Xcode/DerivedData/vitals-scaffold
  SPM=/Volumes/Studio/Development/Caches/Xcode/SourcePackages/vitals
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme RemoteCoreTests -destination platform=macOS -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" -collect-test-diagnostics never build-for-testing
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemoteHost -destination platform=macOS -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" CODE_SIGNING_ALLOWED=NO build
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" build-for-testing
  ```
  Expected: all three succeed.
- [ ] **Step 5: Simulator.** `xcrun simctl create "Farside Vitals iPhone" "iPhone 17" com.apple.CoreSimulator.SimRuntime.iOS-27-0`. Touch no other simulator.
- [ ] **Step 6: Commit** "Scaffold Mac vitals interfaces and tests" (includes `project.yml`, `PocketDesktop.xcodeproj`), push `farside-mac-vitals`.

---

### Task 1: Wire format and validation (Wave 1)

**Files:**
- Modify: `RemoteShared/MacVitals.swift` (`validate`, `clamped`), `RemoteShared/ControlProtocol.swift` (`validate()`, lines 60–65), `RemoteShared/SessionContinuity.swift` (`SessionFeature.host`, lines 24–25)
- Test: `RemoteTests/MacVitalsProtocolTests.swift`

**Interfaces:**
- Consumes: scaffold `MacVitals`, `RemoteAction.macVitals`, `SessionFeature.macVitals`.
- Produces: `MacVitals.validate() throws`, `MacVitals.clamped() -> MacVitals` (never throws on validate afterwards); `SessionFeature.host` contains `"vitals.1"`.

- [ ] **Step 1: Write the failing tests.**
```swift
import XCTest

final class MacVitalsProtocolTests: XCTestCase {
    private let laptop = MacVitals(power: "battery", batteryPercent: 64, charging: false, batteryWarning: 1,
                                   thermal: 0, lowPowerMode: false, load: "ok")

    func testCaptureStatusCarriesVitals() {
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, epoch: 2, macVitals: laptop).validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, epoch: 2, macVitals: MacVitals()).validate(),
                         "A Mac that read nothing sends an empty object")
        let busy = MacVitals(power: "ac", load: "busy", loadCause: "memory")
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, epoch: 2, macVitals: busy).validate())
    }

    func testVitalsRideOnlyOnCaptureStatus() {
        let valid = [
            RemoteAction(action: "heartbeat", epoch: 2),
            RemoteAction(action: "displays", epoch: 2),
            RemoteAction(action: "display", epoch: 2, display: 1),
            RemoteAction(action: "pause", epoch: 2),
            RemoteAction(action: "click", epoch: 2),
        ]
        for base in valid {
            XCTAssertNoThrow(try base.validate(), "\(base.action) must be valid on its own")
            var carrying = base
            carrying.macVitals = laptop
            XCTAssertThrowsError(try carrying.validate(), "\(base.action) must not carry vitals")
        }
    }

    func testOutOfRangeValuesAreRejected() {
        let invalid = [
            MacVitals(batteryPercent: 101), MacVitals(batteryPercent: -1),
            MacVitals(batteryWarning: 0), MacVitals(batteryWarning: 4),
            MacVitals(thermal: -1), MacVitals(thermal: 4),
            MacVitals(power: ""), MacVitals(power: "batterybattery"), MacVitals(power: "b@ttery"),
            MacVitals(power: "on battery"), MacVitals(load: "busy\n"), MacVitals(loadCause: "prøcessor"),
        ]
        for vitals in invalid {
            XCTAssertThrowsError(try vitals.validate(), "\(vitals)")
            XCTAssertThrowsError(try RemoteAction(action: "capture", epoch: 2, macVitals: vitals).validate(), "\(vitals)")
        }
    }

    func testUnknownWordsBecomeNil() throws {
        let future = MacVitals(power: "solar", thermal: 2, load: "melting", loadCause: "gpu")
        XCTAssertNoThrow(try future.validate(), "A newer Mac's word must not end the session")
        XCTAssertNil(future.powerSource)
        XCTAssertNil(future.loadLevel)
        XCTAssertNil(future.cause)
        XCTAssertEqual(future.thermalLevel, .serious)
    }

    func testClampedAlwaysValidates() {
        let wild = MacVitals(power: "averyveryverylongword", batteryPercent: 250, charging: true, batteryWarning: 9,
                             thermal: -3, lowPowerMode: true, load: "b u s y", loadCause: "")
        let clamped = wild.clamped()
        XCTAssertNoThrow(try clamped.validate())
        XCTAssertEqual(clamped.batteryPercent, 100)
        XCTAssertEqual(clamped.batteryWarning, 3)
        XCTAssertEqual(clamped.thermal, 0)
        XCTAssertNil(clamped.power, "A word that fails the charset or length check is dropped, not truncated")
        XCTAssertNil(clamped.load)
        XCTAssertNil(clamped.loadCause)
        XCTAssertEqual(clamped.charging, true)
        XCTAssertEqual(clamped.lowPowerMode, true)
        XCTAssertEqual(laptop.clamped(), laptop, "Valid vitals are unchanged")
        XCTAssertEqual(MacVitals(batteryPercent: -4).clamped().batteryPercent, 0)
    }

    func testOlderPhonesIgnoreTheField() throws {
        struct OldAction: Decodable { var action: String; var epoch: UInt64 }
        let data = try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 5, macVitals: laptop))
        XCTAssertEqual(try JSONDecoder().decode(OldAction.self, from: data).epoch, 5)
        let json = #"{"action":"capture","x":1,"y":0,"text":"","key":"","modifiers":[],"epoch":5}"#
        XCTAssertNil(try JSONDecoder().decode(RemoteAction.self, from: Data(json.utf8)).macVitals,
                     "An older Mac's status decodes with no vitals")
    }

    func testRoundTrip() throws {
        let action = RemoteAction(action: "capture", x: 1, epoch: 5, macVitals: laptop)
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(action))
        XCTAssertEqual(decoded.macVitals, laptop)
        XCTAssertNoThrow(try decoded.validate())
    }

    func testFeatureIsAdvertised() {
        XCTAssertEqual(SessionFeature.macVitals, "vitals.1")
        XCTAssertTrue(SessionFeature.host.contains(SessionFeature.macVitals))
        XCTAssertLessThanOrEqual(SessionFeature.host.count, 16, "The phone rejects more than 16 features")
    }
}
```
- [ ] **Step 2: Run to verify failure.** Core test command with `-XCTest MacVitalsProtocolTests`. Expected: failures in `testVitalsRideOnlyOnCaptureStatus`, `testOutOfRangeValuesAreRejected`, `testClampedAlwaysValidates`, `testFeatureIsAdvertised`.
- [ ] **Step 3: Implement.** In `MacVitals.swift` replace the two stubs:
```swift
    func validate() throws {
        guard batteryPercent.map(Self.percentRange.contains) ?? true,
              batteryWarning.map(Self.warningRange.contains) ?? true,
              thermal.map(Self.thermalRange.contains) ?? true,
              [power, load, loadCause].allSatisfy({ $0.map(Self.isWord) ?? true })
        else { throw RemoteError.invalidMessage }
    }

    func clamped() -> MacVitals {
        var copy = self
        copy.batteryPercent = batteryPercent.map { min(max($0, Self.percentRange.lowerBound), Self.percentRange.upperBound) }
        copy.batteryWarning = batteryWarning.map { min(max($0, Self.warningRange.lowerBound), Self.warningRange.upperBound) }
        copy.thermal = thermal.map { min(max($0, Self.thermalRange.lowerBound), Self.thermalRange.upperBound) }
        copy.power = power.flatMap { Self.isWord($0) ? $0 : nil }
        copy.load = load.flatMap { Self.isWord($0) ? $0 : nil }
        copy.loadCause = loadCause.flatMap { Self.isWord($0) ? $0 : nil }
        return copy
    }

    private static func isWord(_ value: String) -> Bool {
        (1...maxWordLength).contains(value.utf8.count)
            && value.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }
```
  In `ControlProtocol.swift` `validate()`, after `try busy?.validate()`, add `try macVitals?.validate()`, and extend the guard to `guard (captureRegion == nil && ladder == nil && busy == nil && macVitals == nil) || action == "capture" else { … }` (it already precedes `validateDisplaySelection()`).
  In `SessionContinuity.swift`, append `macVitals` to `SessionFeature.host` (it is declared in `MacVitals.swift`).
- [ ] **Step 4: Run** `MacVitalsProtocolTests`, then the neighbours that pin the protocol: `NativeProtocolTests`, `DisplaySelectionTests`, `SecurityTests`. Expected: all pass.
- [ ] **Step 5: Commit** "Validate Mac vitals on capture status and advertise vitals.1".

---

### Task 2: Host power sources (Wave 1)

**Files:**
- Modify: `RemoteHost/MacVitalsSources.swift`
- Test: `RemoteTests/MacVitalsPowerTests.swift`

**Interfaces:**
- Consumes: scaffold types in the same file.
- Produces: `MacPowerParser.reading(descriptions:providingType:) -> MacPowerReading?`; a working `LiveMacVitalsSources` (IOKit, Mach, `getrusage`, memory-pressure source). `powerGeneration` increments on each IOKit power notification between `start()` and `stop()`; `memoryPressure` follows the dispatch source and returns to `.normal` on `stop()`.

API facts verified on this Mac and SDK 27.0 (`IOKit/ps/IOPowerSources.h`, `IOPSKeys.h`): `IOPSCopyPowerSourcesInfo()`, `IOPSCopyPowerSourcesList(_:)` and `IOPSNotificationCreateRunLoopSource(_:_:)` return `Unmanaged` (+1, use `takeRetainedValue()`); `IOPSGetPowerSourceDescription(_:_:)` and `IOPSGetProvidingPowerSourceType(_:)` return `Unmanaged` (+0, `takeUnretainedValue()`); providing types are `"AC Power"`, `"Battery Power"`, `"UPS Power"`; description keys `"Type"` (`"InternalBattery"`, `"UPS"`), `"Current Capacity"`, `"Max Capacity"`, `"Is Charging"`, `"Power Source State"`, `"Is Present"`; values arrive as `NSNumber`. `IOPSGetBatteryWarningLevel().rawValue` is 1…3. `HOST_CPU_LOAD_INFO_COUNT` is unavailable in Swift: use `mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)`; `cpu_ticks` is a 4-tuple (user, system, idle, nice). This M4 Air reported `"AC Power"`, one `InternalBattery` at 100/100, not charging.

- [ ] **Step 1: Write the failing tests.**
```swift
import XCTest

final class MacVitalsPowerTests: XCTestCase {
    private func battery(_ current: Any?, max: Any? = 100, charging: Bool? = false,
                         state: String = "Battery Power", present: Bool = true) -> [String: Any] {
        var description: [String: Any] = ["Type": "InternalBattery", "Power Source State": state, "Is Present": present]
        if let current { description["Current Capacity"] = current }
        if let max { description["Max Capacity"] = max }
        if let charging { description["Is Charging"] = charging }
        return description
    }

    private func read(_ descriptions: [[String: Any]], _ providing: String?) -> MacPowerReading? {
        MacPowerParser.reading(descriptions: descriptions, providingType: providing)
    }

    func testLaptopOnBattery() {
        XCTAssertEqual(read([battery(64)], "Battery Power"), MacPowerReading(power: "battery", batteryPercent: 64, charging: false))
    }

    func testLaptopChargingAndHeld() {
        XCTAssertEqual(read([battery(82, charging: true, state: "AC Power")], "AC Power"),
                       MacPowerReading(power: "ac", batteryPercent: 82, charging: true))
        XCTAssertEqual(read([battery(80, charging: false, state: "AC Power")], "AC Power"),
                       MacPowerReading(power: "ac", batteryPercent: 80, charging: false), "Optimised charging holds at 80 %")
    }

    func testDesktopHasNoBatteryFields() {
        XCTAssertEqual(read([], "AC Power"), MacPowerReading(power: "ac"))
    }

    func testUPSReportsAPercentOnlyWhenItHasOne() {
        let ups: [String: Any] = ["Type": "UPS", "Current Capacity": 80, "Max Capacity": 100, "Power Source State": "Battery Power"]
        XCTAssertEqual(read([ups], "UPS Power"), MacPowerReading(power: "ups", batteryPercent: 80))
        XCTAssertEqual(read([["Type": "UPS"]], "UPS Power"), MacPowerReading(power: "ups"))
    }

    func testInternalBatteryWinsOverAUPS() {
        let ups: [String: Any] = ["Type": "UPS", "Current Capacity": 30, "Max Capacity": 100]
        XCTAssertEqual(read([ups, battery(70, state: "AC Power")], "AC Power")?.batteryPercent, 70)
    }

    func testMissingKeysOmitOnlyWhatIsMissing() {
        XCTAssertEqual(read([battery(nil, max: nil, charging: nil)], "Battery Power"), MacPowerReading(power: "battery"))
    }

    func testCapacityIsARatioNotAssumedPercent() {
        XCTAssertEqual(read([battery(4200, max: 5000)], "Battery Power")?.batteryPercent, 84)
        XCTAssertEqual(read([battery(1, max: 3)], "Battery Power")?.batteryPercent, 33)
        XCTAssertNil(read([battery(50, max: 0)], "Battery Power")?.batteryPercent)
        XCTAssertNil(read([battery(-5, max: 100)], "Battery Power")?.batteryPercent)
        XCTAssertEqual(read([battery(120, max: 100)], "Battery Power")?.batteryPercent, 100)
        XCTAssertNil(read([battery("64", max: 100)], "Battery Power")?.batteryPercent, "Only numbers count")
    }

    func testProvidingTypeFallsBackToTheBatterysState() {
        XCTAssertEqual(read([battery(50)], nil)?.power, "battery")
        XCTAssertEqual(read([battery(50, state: "AC Power")], "Solar")?.power, "ac")
        XCTAssertNil(read([battery(50, state: "Off Line")], nil)?.power)
    }

    func testAnAbsentBatteryIsIgnored() {
        XCTAssertEqual(read([battery(50, present: false)], "AC Power"), MacPowerReading(power: "ac"))
    }

    func testNothingKnownIsNil() {
        XCTAssertNil(read([], nil))
        XCTAssertNil(read([["Type": "Unknown"]], "Mystery"))
    }

    func testBridgedNumbersFromIOKit() {
        let bridged: [String: Any] = ["Type": "InternalBattery", "Current Capacity": NSNumber(value: 37),
                                      "Max Capacity": NSNumber(value: 100), "Is Charging": NSNumber(value: false),
                                      "Power Source State": "Battery Power"]
        XCTAssertEqual(read([bridged], "Battery Power"), MacPowerReading(power: "battery", batteryPercent: 37, charging: false))
    }

    @MainActor
    func testLiveSourcesReadThisMac() {
        let live = LiveMacVitalsSources()
        live.start()
        defer { live.stop() }
        XCTAssertNotNil(live.cpuTicks())
        XCTAssertGreaterThan(live.processorCount(), 0)
        XCTAssertGreaterThan(live.ownCPUSeconds(), 0)
        XCTAssertTrue(MacVitals.thermalRange.contains(live.thermalState()))
        XCTAssertTrue(MacVitals.warningRange.contains(live.batteryWarningLevel()))
        if let power = live.readPower() {
            XCTAssertTrue(power.power.map { ["battery", "ac", "ups"].contains($0) } ?? true)
            XCTAssertTrue(power.batteryPercent.map(MacVitals.percentRange.contains) ?? true)
            print("MacVitalsPowerTests live reading: \(power)")
        }
    }

    @MainActor
    func testLiveReadsAreCheap() {
        let live = LiveMacVitalsSources()
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 {
            _ = live.readPower()
            _ = live.cpuTicks()
            _ = live.ownCPUSeconds()
        }
        let perRead = (ProcessInfo.processInfo.systemUptime - start) / 200
        print("MacVitalsPowerTests one power + CPU read: \(String(format: "%.3f", perRead * 1000)) ms")
        XCTAssertLessThan(perRead, 0.01, "A read that runs at most once a second must stay far under 10 ms")
    }

    @MainActor
    func testStopIsSafeTwiceAndWithoutStart() {
        let live = LiveMacVitalsSources()
        live.stop()
        live.start()
        live.start()
        live.stop()
        live.stop()
        XCTAssertEqual(live.memoryPressure, .normal)
    }
}
```
- [ ] **Step 2: Run to verify failure** (`-XCTest MacVitalsPowerTests`): parser tests and live tests fail against the stubs.
- [ ] **Step 3: Implement** in `MacVitalsSources.swift` (add `import IOKit.ps` and `import Darwin`):
```swift
enum MacPowerParser {
    private static let providing = ["AC Power": "ac", "Battery Power": "battery", "UPS Power": "ups"]

    static func reading(descriptions: [[String: Any]], providingType: String?) -> MacPowerReading? {
        let present = descriptions.filter { ($0["Is Present"] as? Bool) ?? true }
        let internal = present.first { $0["Type"] as? String == "InternalBattery" }
        let ups = present.first { $0["Type"] as? String == "UPS" }
        let source = internal ?? ups
        let stated = (source?["Power Source State"] as? String).flatMap { $0 == "Off Line" ? nil : providing[$0] }
        let power = providingType.flatMap { providing[$0] } ?? stated
        let reading = MacPowerReading(power: power, batteryPercent: source.flatMap(percent),
                                      charging: internal?["Is Charging"] as? Bool)
        return reading == MacPowerReading() ? nil : reading
    }

    private static func percent(_ description: [String: Any]) -> Int? {
        guard let current = (description["Current Capacity"] as? NSNumber)?.doubleValue,
              let maximum = (description["Max Capacity"] as? NSNumber)?.doubleValue,
              maximum > 0, current >= 0 else { return nil }
        return min(100, Int((current / maximum * 100).rounded(.down)))
    }
}
```
  (`"64" as? NSNumber` is nil, so string values are ignored; Swift `Int` literals in the tests bridge to `NSNumber`. If the UPS-percent rounding or charset tests disagree with this sketch, the tests are the contract.)

  `LiveMacVitalsSources`:
  - `start()`: if not started, create the IOKit run-loop source with a non-capturing callback that recovers `self` from the context (`Unmanaged.passUnretained(self).toOpaque()`) and increments `powerGeneration` inside `MainActor.assumeIsolated`; add it to `CFRunLoopGetMain()` in `.commonModes`. Create `DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)` whose handler maps `source.data` to `.critical`/`.warning`/`.normal`, then `resume()`. The context is unretained, so `stop()` must run before release; `MacVitalsMonitor.stop()` guarantees it.
  - `stop()`: remove and drop the run-loop source, `cancel()` the pressure source, set `memoryPressure = .normal`. Idempotent.
  - `readPower()`: `IOPSCopyPowerSourcesInfo()?.takeRetainedValue()`, list via `IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]`, descriptions via `IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any]`, providing via `IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?`, then `MacPowerParser.reading`.
  - `batteryWarningLevel()`: `Int(IOPSGetBatteryWarningLevel().rawValue)`. `thermalState()`: `ProcessInfo.processInfo.thermalState.rawValue`. `lowPowerMode()`: `ProcessInfo.processInfo.isLowPowerModeEnabled`. `processorCount()`: `ProcessInfo.processInfo.activeProcessorCount`.
  - `cpuTicks()`: `host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, …)` with the explicit count above; nil unless `KERN_SUCCESS`.
  - `ownCPUSeconds()`: `getrusage(RUSAGE_SELF, &usage)` user + system seconds, as in `E2EProcessMetrics.sample()` (`RemoteShared/E2ESupport.swift:295-299`).
- [ ] **Step 4: Run** `MacVitalsPowerTests`. Expected: all pass; copy the two printed lines (live reading, per-read cost) into your report.
- [ ] **Step 5: Commit** "Read the Mac's power sources, CPU ticks and memory pressure for vitals".

---

### Task 3: Load policy and vitals monitor (Wave 1)

**Files:**
- Modify: `RemoteHost/MacVitalsMonitor.swift`
- Test: `RemoteTests/MacVitalsMonitorTests.swift`

**Interfaces:**
- Consumes: `MacVitalsSources`, `MacPowerReading`, `CPUTicks`, `MacMemoryPressure` (scaffold); `MacVitals.clamped()` (Task 1; a stub until Wave 1 merges, so `testOutputAlwaysValidates` is only meaningful after the merge — the orchestrator reruns it).
- Produces: `MacCPU.othersFraction(...)`, `MacLoadPolicy` (`level`, `cause`, two `observe` methods), `MacVitalsMonitor.start(now:)`, `.stop()`, `.current(now:) -> MacVitals?`, `.isRunning`.

Behaviour: `start` calls `sources.start()` once, takes the CPU baseline and reads power. `current` returns nil unless running; samples the processor when ≥ 2 s since the last sample (fraction = whole-Mac busy ticks share minus Farside's `Δown / (Δwall × processors)`, clamped 0…1); feeds memory pressure every call; re-reads power when `powerGeneration` changed and ≥ 1 s since the last read; attaches `batteryWarning` only when the reading has a battery percentage; always returns `.clamped()`. `stop` calls `sources.stop()` and forgets everything.

- [ ] **Step 1: Write the failing tests.**
```swift
import XCTest

@MainActor
private final class FakeVitalsSources: MacVitalsSources {
    var powerGeneration = 0
    var memoryPressure: MacMemoryPressure = .normal
    var power: MacPowerReading? = MacPowerReading(power: "battery", batteryPercent: 64, charging: false)
    var warning = 1
    var thermal = 0
    var lowPower = false
    var ticks = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
    var own = 0.0
    var processors = 10
    private(set) var started = 0
    private(set) var stopped = 0
    private(set) var powerReads = 0
    private(set) var tickReads = 0

    func start() { started += 1 }
    func stop() { stopped += 1 }
    func readPower() -> MacPowerReading? { powerReads += 1; return power }
    func batteryWarningLevel() -> Int { warning }
    func thermalState() -> Int { thermal }
    func lowPowerMode() -> Bool { lowPower }
    func cpuTicks() -> CPUTicks? { tickReads += 1; return ticks }
    func ownCPUSeconds() -> Double { own }
    func processorCount() -> Int { processors }

    /// `busy` of every processor ran for `seconds`; `ownShare` of all capacity was Farside.
    func run(seconds: Double, busy: Double, ownShare: Double = 0) {
        let total = UInt32(seconds * 100 * Double(processors))
        let busyTicks = UInt32((Double(total) * busy).rounded())
        ticks.user &+= busyTicks
        ticks.idle &+= total - busyTicks
        own += seconds * Double(processors) * ownShare
    }
}

@MainActor
final class MacVitalsMonitorTests: XCTestCase {
    // MARK: Processor arithmetic

    func testOthersFractionSubtractsFarside() throws {
        let a = CPUTicks(user: 1000, system: 500, idle: 8500, nice: 0)
        let b = CPUTicks(user: 1800, system: 1000, idle: 8700, nice: 0)
        let whole = try XCTUnwrap(MacCPU.othersFraction(previous: a, current: b, ownCPUSeconds: 0, wallSeconds: 2, processors: 10))
        XCTAssertEqual(whole, 1300.0 / 1500.0, accuracy: 0.0001)
        let others = try XCTUnwrap(MacCPU.othersFraction(previous: a, current: b, ownCPUSeconds: 6, wallSeconds: 2, processors: 10))
        XCTAssertEqual(others, 1300.0 / 1500.0 - 0.3, accuracy: 0.0001, "6 CPU-seconds of 20 available were Farside's")
    }

    func testNiceTicksCountAsBusy() throws {
        let a = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let b = CPUTicks(user: 0, system: 0, idle: 100, nice: 100)
        XCTAssertEqual(try XCTUnwrap(MacCPU.othersFraction(previous: a, current: b, ownCPUSeconds: 0, wallSeconds: 2, processors: 1)), 0.5, accuracy: 0.0001)
    }

    func testTickCountersWrap() throws {
        let a = CPUTicks(user: UInt32.max - 99, system: 0, idle: 0, nice: 0)
        let b = CPUTicks(user: 100, system: 0, idle: 200, nice: 0)
        XCTAssertEqual(try XCTUnwrap(MacCPU.othersFraction(previous: a, current: b, ownCPUSeconds: 0, wallSeconds: 2, processors: 4)), 0.5, accuracy: 0.0001)
    }

    func testNoElapsedTimeIsNoSample() {
        let a = CPUTicks(user: 10, system: 10, idle: 10, nice: 0)
        XCTAssertNil(MacCPU.othersFraction(previous: a, current: a, ownCPUSeconds: 0, wallSeconds: 2, processors: 4))
        let b = CPUTicks(user: 20, system: 10, idle: 20, nice: 0)
        XCTAssertNil(MacCPU.othersFraction(previous: a, current: b, ownCPUSeconds: 0, wallSeconds: 0, processors: 4))
        XCTAssertNil(MacCPU.othersFraction(previous: a, current: b, ownCPUSeconds: 0, wallSeconds: 2, processors: 0))
    }

    func testFractionIsClamped() throws {
        let a = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let b = CPUTicks(user: 10, system: 0, idle: 90, nice: 0)
        XCTAssertEqual(try XCTUnwrap(MacCPU.othersFraction(previous: a, current: b, ownCPUSeconds: 5, wallSeconds: 1, processors: 1)), 0)
    }

    // MARK: Policy

    func testBusyNeedsTenSecondsAtEightyFivePercent() {
        var policy = MacLoadPolicy()
        for _ in 0..<4 { policy.observe(processorFraction: 0.9, over: 2) }
        XCTAssertEqual(policy.level, .ok, "8 s is not enough")
        policy.observe(processorFraction: 0.9, over: 2)
        XCTAssertEqual(policy.level, .busy)
        XCTAssertEqual(policy.cause, .processor)
    }

    func testExactlyEightyFiveCounts() {
        var policy = MacLoadPolicy()
        for _ in 0..<5 { policy.observe(processorFraction: 0.85, over: 2) }
        XCTAssertEqual(policy.level, .busy)
    }

    func testBetweenThresholdsKeepsTheLevel() {
        var calm = MacLoadPolicy()
        for _ in 0..<10 { calm.observe(processorFraction: 0.8, over: 2) }
        XCTAssertEqual(calm.level, .ok)
        var busy = MacLoadPolicy()
        for _ in 0..<5 { busy.observe(processorFraction: 0.95, over: 2) }
        for _ in 0..<10 { busy.observe(processorFraction: 0.75, over: 2) }
        XCTAssertEqual(busy.level, .busy, "70–85 % holds whichever level it had")
    }

    func testClearsOnceTheTenSecondAverageDropsBelowSeventy() {
        var policy = MacLoadPolicy()
        for _ in 0..<5 { policy.observe(processorFraction: 0.95, over: 2) }
        for _ in 0..<2 { policy.observe(processorFraction: 0.5, over: 2) }
        XCTAssertEqual(policy.level, .busy, "Rolling mean (3 × 95 % + 2 × 50 %) / 5 = 77 %")
        policy.observe(processorFraction: 0.5, over: 2)
        XCTAssertEqual(policy.level, .ok, "(2 × 95 % + 3 × 50 %) / 5 = 68 %")
        XCTAssertNil(policy.cause)
    }

    func testTimerJitterStillFillsTheWindow() {
        var policy = MacLoadPolicy()
        for _ in 0..<4 { policy.observe(processorFraction: 0.9, over: 2.25) }
        policy.observe(processorFraction: 0.9, over: 2.0)
        XCTAssertEqual(policy.level, .busy)
    }

    func testMemoryPressure() {
        var policy = MacLoadPolicy()
        policy.observe(memoryPressure: .warning)
        XCTAssertEqual(policy.level, .ok)
        policy.observe(memoryPressure: .critical)
        XCTAssertEqual(policy.level, .busy)
        XCTAssertEqual(policy.cause, .memory)
        policy.observe(memoryPressure: .warning)
        XCTAssertEqual(policy.level, .busy, "Warning neither sets nor clears")
        policy.observe(memoryPressure: .normal)
        XCTAssertEqual(policy.level, .ok)
    }

    func testMemoryNamesTheCauseWhenBoth() {
        var policy = MacLoadPolicy()
        for _ in 0..<5 { policy.observe(processorFraction: 0.95, over: 2) }
        policy.observe(memoryPressure: .critical)
        XCTAssertEqual(policy.cause, .memory)
        policy.observe(memoryPressure: .normal)
        XCTAssertEqual(policy.cause, .processor)
    }

    func testNonsenseSamplesAreIgnored() {
        var policy = MacLoadPolicy()
        policy.observe(processorFraction: .nan, over: 2)
        policy.observe(processorFraction: 0.9, over: -1)
        policy.observe(processorFraction: 0.9, over: 0)
        for _ in 0..<4 { policy.observe(processorFraction: 0.9, over: 2) }
        XCTAssertEqual(policy.level, .ok, "Ignored samples fill no part of the window")
    }

    // MARK: Monitor

    func testNothingIsSampledOutsideASession() {
        let fake = FakeVitalsSources()
        let monitor = MacVitalsMonitor(sources: fake)
        XCTAssertNil(monitor.current(now: 0))
        XCTAssertEqual(fake.started, 0)
        XCTAssertEqual(fake.tickReads + fake.powerReads, 0)
        monitor.start(now: 0)
        monitor.start(now: 0.1)
        XCTAssertEqual(fake.started, 1, "A second start is a no-op")
        XCTAssertTrue(monitor.isRunning)
        XCTAssertNotNil(monitor.current(now: 0.25))
        monitor.stop()
        XCTAssertEqual(fake.stopped, 1)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertNil(monitor.current(now: 1))
    }

    func testProcessorIsSampledEveryTwoSeconds() {
        let fake = FakeVitalsSources()
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        XCTAssertEqual(fake.tickReads, 1, "Baseline")
        for step in 1...7 { _ = monitor.current(now: Double(step) * 0.25) }
        XCTAssertEqual(fake.tickReads, 1)
        _ = monitor.current(now: 2)
        XCTAssertEqual(fake.tickReads, 2)
        _ = monitor.current(now: 2.25)
        XCTAssertEqual(fake.tickReads, 2)
    }

    func testPowerIsReadOnChangeAtMostOncePerSecond() {
        let fake = FakeVitalsSources()
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        XCTAssertEqual(fake.powerReads, 1)
        _ = monitor.current(now: 0.5)
        XCTAssertEqual(fake.powerReads, 1, "No notification, no read")
        fake.powerGeneration += 1
        fake.power = MacPowerReading(power: "ac", batteryPercent: 64, charging: true)
        XCTAssertEqual(monitor.current(now: 0.75)?.power, "battery", "Too soon after the last read")
        XCTAssertEqual(monitor.current(now: 1.0)?.power, "ac")
        XCTAssertEqual(fake.powerReads, 2)
        _ = monitor.current(now: 1.25)
        XCTAssertEqual(fake.powerReads, 2)
    }

    func testReportsBatteryThermalAndLowPowerMode() throws {
        let fake = FakeVitalsSources()
        fake.thermal = 2
        fake.lowPower = true
        fake.warning = 2
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        let vitals = try XCTUnwrap(monitor.current(now: 0.25))
        XCTAssertEqual(vitals, MacVitals(power: "battery", batteryPercent: 64, charging: false, batteryWarning: 2,
                                         thermal: 2, lowPowerMode: true, load: "ok", loadCause: nil))
    }

    func testFailedPowerReadOmitsOnlyBatteryFields() throws {
        let fake = FakeVitalsSources()
        fake.power = nil
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        let vitals = try XCTUnwrap(monitor.current(now: 0.25))
        XCTAssertNil(vitals.power)
        XCTAssertNil(vitals.batteryPercent)
        XCTAssertNil(vitals.batteryWarning)
        XCTAssertEqual(vitals.thermal, 0)
        XCTAssertEqual(vitals.load, "ok")
    }

    func testWarningLevelNeedsABattery() throws {
        let fake = FakeVitalsSources()
        fake.power = MacPowerReading(power: "ac")
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        XCTAssertNil(try XCTUnwrap(monitor.current(now: 0.25)).batteryWarning)
    }

    func testBusyAfterTenSecondsOfOtherApps() {
        let fake = FakeVitalsSources()
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        var levels: [Double: String] = [:]
        for step in 1...48 {
            let now = Double(step) * 0.25
            fake.run(seconds: 0.25, busy: 0.95)
            levels[now] = monitor.current(now: now)?.load
        }
        XCTAssertEqual(levels[9.75], "ok")
        XCTAssertEqual(levels[10], "busy")
        XCTAssertEqual(monitor.current(now: 12)?.loadCause, "processor")
    }

    func testFarsidesOwnLoadIsSubtracted() {
        let fake = FakeVitalsSources()
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        for step in 1...120 {
            fake.run(seconds: 0.25, busy: 0.95, ownShare: 0.3)
            XCTAssertEqual(monitor.current(now: Double(step) * 0.25)?.load, "ok", "Farside's own 30 % must not count")
        }
    }

    func testMemoryPressureMakesTheMacBusy() {
        let fake = FakeVitalsSources()
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        fake.memoryPressure = .critical
        XCTAssertEqual(monitor.current(now: 0.25)?.load, "busy")
        XCTAssertEqual(monitor.current(now: 0.5)?.loadCause, "memory")
        fake.memoryPressure = .normal
        XCTAssertEqual(monitor.current(now: 0.75)?.load, "ok")
    }

    func testStopForgetsTheLoad() {
        let fake = FakeVitalsSources()
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        fake.memoryPressure = .critical
        _ = monitor.current(now: 0.25)
        monitor.stop()
        fake.memoryPressure = .normal
        monitor.start(now: 10)
        XCTAssertEqual(monitor.current(now: 10.25)?.load, "ok")
    }

    func testOutputAlwaysValidates() throws {
        let fake = FakeVitalsSources()
        fake.power = MacPowerReading(power: "a power word far too long", batteryPercent: 250, charging: nil)
        fake.thermal = 9
        fake.warning = 0
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        let vitals = try XCTUnwrap(monitor.current(now: 0.25))
        XCTAssertNoThrow(try vitals.validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, epoch: 1, macVitals: vitals).validate())
    }
}
```
- [ ] **Step 2: Run to verify failure** (`-XCTest MacVitalsMonitorTests`).
- [ ] **Step 3: Implement.**
```swift
enum MacCPU {
    static func othersFraction(previous: CPUTicks, current: CPUTicks, ownCPUSeconds: Double,
                               wallSeconds: TimeInterval, processors: Int) -> Double? {
        let busy = Double(current.user &- previous.user) + Double(current.system &- previous.system)
            + Double(current.nice &- previous.nice)
        let total = busy + Double(current.idle &- previous.idle)
        guard total > 0, wallSeconds > 0, processors > 0, ownCPUSeconds.isFinite else { return nil }
        // Ticks give the whole Mac's share; Farside's share comes from wall time so the tick unit never matters.
        let own = ownCPUSeconds / (wallSeconds * Double(processors))
        return min(1, max(0, busy / total - own))
    }
}

struct MacLoadPolicy {
    static let window: TimeInterval = 10
    static let busyAt = 0.85
    static let clearBelow = 0.70
    private static let jitter: TimeInterval = 0.5

    private var samples: [(duration: TimeInterval, fraction: Double)] = []
    private var processorBusy = false
    private var memoryCritical = false

    init() {}

    var level: MacVitals.Load { processorBusy || memoryCritical ? .busy : .ok }
    var cause: MacVitals.LoadCause? { memoryCritical ? .memory : processorBusy ? .processor : nil }

    mutating func observe(processorFraction: Double, over duration: TimeInterval) {
        guard processorFraction.isFinite, duration.isFinite, duration > 0 else { return }
        samples.append((duration, min(1, max(0, processorFraction))))
        while samples.count > 1, covered - samples[0].duration >= Self.window { samples.removeFirst() }
        guard covered >= Self.window - Self.jitter else { return }
        let mean = samples.reduce(0) { $0 + $1.duration * $1.fraction } / covered
        if !processorBusy, mean >= Self.busyAt { processorBusy = true }
        if processorBusy, mean < Self.clearBelow { processorBusy = false }
    }

    mutating func observe(memoryPressure: MacMemoryPressure) {
        switch memoryPressure {
        case .critical: memoryCritical = true
        case .normal: memoryCritical = false
        case .warning: break
        }
    }

    private var covered: TimeInterval { samples.reduce(0) { $0 + $1.duration } }
}
```
  `MacVitalsMonitor`: private state `policy`, `lastTicks: CPUTicks?`, `lastOwn: Double`, `lastSampleAt: TimeInterval`, `power: MacPowerReading?`, `powerReadAt: TimeInterval`, `powerGenerationRead: Int`. `start(now:)` guards `!isRunning`, calls `sources.start()`, sets the CPU baseline and reads power. `current(now:)` as described in the behaviour paragraph above. `stop()` calls `sources.stop()` only when running and resets every field (`policy = MacLoadPolicy()`).
- [ ] **Step 4: Run** `MacVitalsMonitorTests`. Expected: all pass (`testOutputAlwaysValidates` passes trivially until Task 1 merges; say so in the report).
- [ ] **Step 5: Commit** "Decide whole-Mac load from CPU and memory pressure, excluding Farside".

---

### Task 4: Caption, spoken sentence and Diagnostics rows (Wave 1)

**Files:**
- Modify: `RemoteShared/MacVitalsPresentation.swift`
- Test: `RemoteTests/MacVitalsPresentationTests.swift`

**Interfaces:**
- Consumes: `MacVitals` and its typed accessors (real in the scaffold).
- Produces: `MacVitalsPresentation(_:)` with `caption`, `spoken`, `isWarning`, `rows: [Row]`; `MacVitalsPresentation.preview(_:)` (DEBUG) for `"battery12"`, `"battery64"`, `"charging82"`, `"desktop"`; `tooOld`, `waiting`.

Rules: base words per the Global Constraints (unknown or missing power → "running normally"); suffixes hot/warm (critical/serious; nominal and fair show nothing), "Low Power Mode", "busy"; "running normally" is dropped when any suffix is present. Spoken: `"Your Mac: " + parts.joined(", ") + "."`, parts "on battery", "12 percent", "charging", "plugged in", "running normally", "on UPS power", "warm", "hot", "Low Power Mode", "busy". `isWarning`: on battery at ≤ 20 %, or on battery with warning ≥ 2, or thermal ≥ serious, or load busy (Low Power Mode alone is not a warning). Rows, in order: Power, Temperature, Low Power Mode, Load; a missing value is "Not reported".

- [ ] **Step 1: Write the failing tests.**
```swift
import XCTest

final class MacVitalsPresentationTests: XCTestCase {
    private typealias Row = MacVitalsPresentation.Row
    private let heavy = MacVitals(power: "battery", batteryPercent: 12, charging: false, batteryWarning: 2,
                                  thermal: 2, lowPowerMode: true, load: "busy", loadCause: "processor")

    private func caption(_ vitals: MacVitals) -> String { MacVitalsPresentation(vitals).caption }
    private func spoken(_ vitals: MacVitals) -> String { MacVitalsPresentation(vitals).spoken }
    private func warning(_ vitals: MacVitals) -> Bool { MacVitalsPresentation(vitals).isWarning }

    func testBaseCaptions() {
        XCTAssertEqual(caption(MacVitals(power: "battery", batteryPercent: 64, charging: false)), "Mac · on battery 64%")
        XCTAssertEqual(caption(MacVitals(power: "ac", batteryPercent: 82, charging: true)), "Mac · charging 82%")
        XCTAssertEqual(caption(MacVitals(power: "ac", batteryPercent: 80, charging: false)), "Mac · plugged in")
        XCTAssertEqual(caption(MacVitals(power: "ac", batteryPercent: 100)), "Mac · plugged in")
        XCTAssertEqual(caption(MacVitals(power: "ac")), "Mac · running normally")
        XCTAssertEqual(caption(MacVitals()), "Mac · running normally")
        XCTAssertEqual(caption(MacVitals(power: "battery")), "Mac · on battery")
        XCTAssertEqual(caption(MacVitals(power: "ups", batteryPercent: 80)), "Mac · on UPS 80%")
        XCTAssertEqual(caption(MacVitals(power: "ups")), "Mac · on UPS")
    }

    func testSuffixesInOrder() {
        XCTAssertEqual(caption(heavy), "Mac · on battery 12% · warm · Low Power Mode · busy")
        XCTAssertEqual(caption(MacVitals(power: "ac", batteryPercent: 90, charging: true, thermal: 3)), "Mac · charging 90% · hot")
        XCTAssertEqual(caption(MacVitals(power: "ac", batteryPercent: 90, charging: false, thermal: 1)), "Mac · plugged in",
                       "Fair is not shown")
    }

    func testRunningNormallyGivesWayToASuffix() {
        XCTAssertEqual(caption(MacVitals(power: "ac", thermal: 3, load: "busy")), "Mac · hot · busy")
        XCTAssertEqual(caption(MacVitals(lowPowerMode: true)), "Mac · Low Power Mode")
    }

    func testSpokenSentence() {
        XCTAssertEqual(spoken(MacVitals(power: "battery", batteryPercent: 12, thermal: 0, lowPowerMode: true, load: "busy")),
                       "Your Mac: on battery, 12 percent, Low Power Mode, busy.")
        XCTAssertEqual(spoken(heavy), "Your Mac: on battery, 12 percent, warm, Low Power Mode, busy.")
        XCTAssertEqual(spoken(MacVitals(power: "ac", batteryPercent: 82, charging: true)), "Your Mac: charging, 82 percent.")
        XCTAssertEqual(spoken(MacVitals(power: "ac", batteryPercent: 80)), "Your Mac: plugged in.")
        XCTAssertEqual(spoken(MacVitals(power: "ac")), "Your Mac: running normally.")
        XCTAssertEqual(spoken(MacVitals(power: "ups", batteryPercent: 80, thermal: 3)), "Your Mac: on UPS power, 80 percent, hot.")
    }

    func testWarningTone() {
        XCTAssertFalse(warning(MacVitals(power: "battery", batteryPercent: 64)))
        XCTAssertTrue(warning(MacVitals(power: "battery", batteryPercent: 20)))
        XCTAssertTrue(warning(MacVitals(power: "battery", batteryPercent: 40, batteryWarning: 2)))
        XCTAssertFalse(warning(MacVitals(power: "ac", batteryPercent: 15, charging: true)))
        XCTAssertTrue(warning(MacVitals(thermal: 2)))
        XCTAssertFalse(warning(MacVitals(thermal: 1)))
        XCTAssertTrue(warning(MacVitals(load: "busy")))
        XCTAssertFalse(warning(MacVitals(lowPowerMode: true)))
        XCTAssertFalse(warning(MacVitals()))
    }

    func testDiagnosticsRows() {
        XCTAssertEqual(MacVitalsPresentation(heavy).rows, [
            Row(title: "Power", value: "Battery · 12% · macOS low-battery warning"),
            Row(title: "Temperature", value: "Warm"),
            Row(title: "Low Power Mode", value: "On"),
            Row(title: "Load", value: "Busy · processor"),
        ])
        XCTAssertEqual(MacVitalsPresentation(MacVitals(power: "ac", thermal: 0, lowPowerMode: false, load: "ok")).rows, [
            Row(title: "Power", value: "Power adapter"),
            Row(title: "Temperature", value: "Normal"),
            Row(title: "Low Power Mode", value: "Off"),
            Row(title: "Load", value: "Normal"),
        ])
        XCTAssertEqual(MacVitalsPresentation(MacVitals()).rows.map(\.value), Array(repeating: "Not reported", count: 4))
    }

    func testPowerRowVariants() {
        func power(_ vitals: MacVitals) -> String? { MacVitalsPresentation(vitals).rows.first?.value }
        XCTAssertEqual(power(MacVitals(power: "ac", batteryPercent: 82, charging: true)), "Power adapter · charging · 82%")
        XCTAssertEqual(power(MacVitals(power: "ac", batteryPercent: 80, charging: false)), "Power adapter · 80%")
        XCTAssertEqual(power(MacVitals(power: "battery", batteryPercent: 4, batteryWarning: 3)), "Battery · 4% · macOS final battery warning")
        XCTAssertEqual(power(MacVitals(power: "ups", batteryPercent: 80)), "UPS · 80%")
        XCTAssertEqual(power(MacVitals(power: "ups")), "UPS")
        XCTAssertEqual(MacVitalsPresentation(MacVitals(thermal: 3)).rows[1].value, "Hot")
        XCTAssertEqual(MacVitalsPresentation(MacVitals(load: "busy", loadCause: "memory")).rows[3].value, "Busy · memory")
        XCTAssertEqual(MacVitalsPresentation(MacVitals(load: "busy")).rows[3].value, "Busy")
    }

    func testUnknownWordsReadAsNotReported() {
        let future = MacVitals(power: "solar", load: "melting", loadCause: "gpu")
        XCTAssertEqual(caption(future), "Mac · running normally")
        XCTAssertEqual(MacVitalsPresentation(future).rows[0].value, "Not reported")
        XCTAssertEqual(MacVitalsPresentation(future).rows[3].value, "Not reported")
    }

    func testFixedCopy() {
        XCTAssertEqual(MacVitalsPresentation.tooOld, "Your Mac’s Farside is too old to report battery and load. Update it on your Mac.")
    }

    #if DEBUG
    func testPreviewsForLayoutChecks() throws {
        XCTAssertEqual(caption(try XCTUnwrap(MacVitalsPresentation.preview("battery12"))),
                       "Mac · on battery 12% · warm · Low Power Mode · busy")
        XCTAssertEqual(caption(try XCTUnwrap(MacVitalsPresentation.preview("battery64"))), "Mac · on battery 64%")
        XCTAssertEqual(caption(try XCTUnwrap(MacVitalsPresentation.preview("charging82"))), "Mac · charging 82%")
        XCTAssertEqual(caption(try XCTUnwrap(MacVitalsPresentation.preview("desktop"))), "Mac · running normally")
        XCTAssertNil(MacVitalsPresentation.preview("nonsense"))
        for name in ["battery12", "battery64", "charging82", "desktop"] {
            XCTAssertNoThrow(try MacVitalsPresentation.preview(name)?.validate())
        }
    }
    #endif
}
```
- [ ] **Step 2: Run to verify failure** (`-XCTest MacVitalsPresentationTests`).
- [ ] **Step 3: Implement** the initializer from the rules above: build `base: (caption: String?, spoken: [String])` from `powerSource`/`batteryPercent`/`charging`, build suffixes `[(caption, spoken)]` from `thermalLevel`, `lowPowerMode`, `loadLevel`, drop "running normally" when suffixes exist, and join. The `battery12` preview is exactly `heavy` above; `battery64` is `MacVitals(power: "battery", batteryPercent: 64, charging: false, batteryWarning: 1, thermal: 0, lowPowerMode: false, load: "ok")`; `charging82` is `MacVitals(power: "ac", batteryPercent: 82, charging: true, thermal: 0, lowPowerMode: false, load: "ok")`; `desktop` is `MacVitals(power: "ac", thermal: 0, lowPowerMode: false, load: "ok")`.
- [ ] **Step 4: Run** `MacVitalsPresentationTests` and `BusyPresentationTests`. Expected: all pass.
- [ ] **Step 5: Commit** "Word the Mac's vitals for the Controls caption, VoiceOver and Diagnostics".

---

### Task 5: Notice policy and Home memory (Wave 1)

**Files:**
- Modify: `RemoteShared/MacVitalsNotices.swift`, `RemoteShared/MacVitalsMemory.swift`
- Test: `RemoteTests/MacVitalsNoticeTests.swift`, `RemoteTests/MacVitalsMemoryTests.swift`

**Interfaces:**
- Consumes: `MacVitals` accessors, `BusyState`, `LadderReason` (`RemoteShared/LadderPolicy.swift:5`).
- Produces: `MacVitalsNotice.unplugged/low/critical/busy`; `MacVitalsNoticePolicy.observe(_:pill:now:) -> String?` (a new instance is a new session); `MacVitalsMemory.record(_:at:)`, `.lastSeen(now:)`, `.forget()`, `.homeNote(_:)`, `.sleepNote(_:)`.

Policy (see "Plan interpretations" 3–5): per call, in this order — plugged in (`power` ac/ups) or `charging == true` re-arms unplug, low and critical; on battery, a percentage ≥ 25 re-arms low and ≥ 15 without a final warning re-arms critical; an adapter→battery change marks an unplug pending (it expires 10 s after it was seen). A pill is *holding* when visible with reason `thermal` or `power`. Nothing is shown within 6 s of the last shown notice. Then at most one, most severe first: critical (on battery, ≤ 10 % or warning 3; never held) → low (≤ 20 %, not held) → pending unplug (not held) → busy (load busy, once per session, not held). Showing critical also disarms low and clears a pending unplug; showing low clears a pending unplug.

Memory: `record` stores `{percent, at}` when the vitals are on battery with a percentage ≤ 10; any other input (including nil) removes the entry. `lastSeen(now:)` returns nil (and removes it) when older than 12 h, dated more than 5 min in the future, or unreadable.

- [ ] **Step 1: Write the failing tests.** `RemoteTests/MacVitalsNoticeTests.swift`:
```swift
import XCTest

final class MacVitalsNoticeTests: XCTestCase {
    private var policy = MacVitalsNoticePolicy()
    private let warmPill = BusyState(level: .busy, fps: 30, longEdge: 1440, reason: "thermal")
    private let powerPill = BusyState(level: .strained, fps: 60, longEdge: 1920, reason: "power")
    private let encodingPill = BusyState(level: .busy, fps: 30, longEdge: 1440, reason: "encoding")

    private func battery(_ percent: Int?, warning: Int = 1, load: String = "ok") -> MacVitals {
        MacVitals(power: "battery", batteryPercent: percent, charging: false, batteryWarning: warning, load: load)
    }
    private func adapter(_ percent: Int = 80, charging: Bool = true) -> MacVitals {
        MacVitals(power: "ac", batteryPercent: percent, charging: charging, batteryWarning: 1, load: "ok")
    }
    private func see(_ vitals: MacVitals?, at now: TimeInterval, pill: BusyState? = nil) -> String? {
        policy.observe(vitals, pill: pill, now: now)
    }

    func testCopy() {
        XCTAssertEqual(MacVitalsNotice.unplugged(64), "Your Mac is now on battery · 64%.")
        XCTAssertEqual(MacVitalsNotice.unplugged(nil), "Your Mac is now on battery.")
        XCTAssertEqual(MacVitalsNotice.low(18), "Your Mac is on battery · 18%. Plug it in to keep going.")
        XCTAssertEqual(MacVitalsNotice.critical(9), "Your Mac is at 9% and may sleep soon. Plug it in or save your work.")
        XCTAssertEqual(MacVitalsNotice.critical(nil), "Your Mac’s battery is almost empty and it may sleep soon. Plug it in or save your work.")
        XCTAssertEqual(MacVitalsNotice.busy, "Your Mac is busy with other apps, so it may respond slowly.")
    }

    func testUnplugIsAnnouncedOnceUntilPluggedInAgain() {
        XCTAssertNil(see(adapter(), at: 0))
        XCTAssertEqual(see(battery(64), at: 10), MacVitalsNotice.unplugged(64))
        XCTAssertNil(see(battery(63), at: 20))
        XCTAssertNil(see(adapter(), at: 30))
        XCTAssertEqual(see(battery(62), at: 40), MacVitalsNotice.unplugged(62))
    }

    func testStartingOnBatteryIsNotAnUnplug() {
        XCTAssertNil(see(battery(64), at: 0))
        XCTAssertNil(see(battery(64), at: 10))
    }

    func testLowThenCriticalOncePerSession() {
        XCTAssertNil(see(battery(40), at: 0))
        XCTAssertEqual(see(battery(20), at: 10), MacVitalsNotice.low(20))
        XCTAssertNil(see(battery(19), at: 20))
        XCTAssertEqual(see(battery(10), at: 30), MacVitalsNotice.critical(10))
        XCTAssertNil(see(battery(9), at: 40))
        XCTAssertNil(see(battery(5), at: 50))
    }

    func testStartingLowNotifiesAtOnce() {
        XCTAssertEqual(see(battery(15), at: 0), MacVitalsNotice.low(15))
    }

    func testHoveringAtTwentyNotifiesOnce() {
        XCTAssertEqual(see(battery(20), at: 0), MacVitalsNotice.low(20))
        for (index, percent) in [21, 20, 22, 19, 24, 20].enumerated() {
            XCTAssertNil(see(battery(percent), at: Double(index + 1) * 10), "\(percent)%")
        }
        XCTAssertNil(see(battery(25), at: 100), "25 % re-arms without a notice")
        XCTAssertEqual(see(battery(20), at: 110), MacVitalsNotice.low(20))
    }

    func testHoveringAtTenNotifiesOnce() {
        XCTAssertEqual(see(battery(10), at: 0), MacVitalsNotice.critical(10))
        for (index, percent) in [11, 10, 12, 9, 14, 10].enumerated() {
            XCTAssertNil(see(battery(percent), at: Double(index + 1) * 10), "\(percent)%")
        }
        XCTAssertNil(see(battery(15), at: 100))
        XCTAssertEqual(see(battery(10), at: 110), MacVitalsNotice.critical(10))
    }

    func testPluggingInReArms() {
        XCTAssertEqual(see(battery(18), at: 0), MacVitalsNotice.low(18))
        XCTAssertNil(see(adapter(18), at: 10))
        XCTAssertEqual(see(battery(18), at: 20), MacVitalsNotice.low(18), "Low outranks the unplug it came with")
        XCTAssertNil(see(battery(18), at: 30), "…and the unplug is not shown afterwards")
    }

    func testTheMostSevereWins() {
        XCTAssertNil(see(adapter(8), at: 0))
        XCTAssertEqual(see(battery(8), at: 10), MacVitalsNotice.critical(8))
        XCTAssertNil(see(battery(8), at: 20))
        XCTAssertNil(see(battery(7), at: 30), "Critical also disarms the milder 20 % notice")
    }

    func testMacOSFinalWarningIsCritical() {
        XCTAssertEqual(see(battery(30, warning: 3), at: 0), MacVitalsNotice.critical(30))
        var fresh = MacVitalsNoticePolicy()
        XCTAssertEqual(fresh.observe(battery(nil, warning: 3), pill: nil, now: 0), MacVitalsNotice.critical(nil))
    }

    func testBusyIsOncePerSession() {
        XCTAssertEqual(see(adapter().withLoad("busy"), at: 0), MacVitalsNotice.busy)
        XCTAssertNil(see(adapter(), at: 10))
        XCTAssertNil(see(adapter().withLoad("busy"), at: 20))
        var next = MacVitalsNoticePolicy()
        XCTAssertEqual(next.observe(adapter().withLoad("busy"), pill: nil, now: 30), MacVitalsNotice.busy, "A new session announces it again")
    }

    func testNoticesAreSpacedSoNoneIsOverwritten() {
        XCTAssertNil(see(adapter(), at: 0))
        XCTAssertEqual(see(battery(64, load: "busy"), at: 1), MacVitalsNotice.unplugged(64))
        XCTAssertNil(see(battery(64, load: "busy"), at: 2))
        XCTAssertNil(see(battery(64, load: "busy"), at: 6.9))
        XCTAssertEqual(see(battery(64, load: "busy"), at: 7), MacVitalsNotice.busy)
    }

    func testCriticalWaitsForSpacingButNotForAPill() {
        XCTAssertNil(see(adapter(), at: 0))
        XCTAssertEqual(see(battery(30), at: 1), MacVitalsNotice.unplugged(30))
        XCTAssertNil(see(battery(9), at: 3, pill: warmPill), "Still inside the 6 s of the last notice")
        XCTAssertEqual(see(battery(9), at: 7, pill: warmPill), MacVitalsNotice.critical(9))
    }

    func testThermalOrPowerPillHoldsTheMilderNotices() {
        XCTAssertNil(see(adapter(), at: 0))
        XCTAssertNil(see(battery(64), at: 1, pill: powerPill))
        XCTAssertEqual(see(battery(64), at: 3), MacVitalsNotice.unplugged(64), "Shown once the pill clears")
        XCTAssertNil(see(battery(18), at: 20, pill: warmPill))
        XCTAssertEqual(see(battery(18), at: 21, pill: encodingPill), MacVitalsNotice.low(18), "Only thermal or power pills hold")
        XCTAssertNil(see(battery(18).withLoad("busy"), at: 40, pill: warmPill))
        XCTAssertEqual(see(battery(18).withLoad("busy"), at: 41), MacVitalsNotice.busy)
    }

    func testAHeldUnplugNoticeExpires() {
        XCTAssertNil(see(adapter(), at: 0))
        XCTAssertNil(see(battery(64), at: 1, pill: warmPill))
        XCTAssertNil(see(battery(64), at: 12), "10 s after the unplug, 'now on battery' is no longer news")
    }

    func testMissingOrUnknownVitalsSayNothing() {
        XCTAssertNil(see(nil, at: 0))
        XCTAssertNil(see(MacVitals(power: "solar", batteryPercent: 3), at: 10))
    }
}

private extension MacVitals {
    func withLoad(_ load: String) -> MacVitals {
        var copy = self
        copy.load = load
        return copy
    }
}
```
  `RemoteTests/MacVitalsMemoryTests.swift`:
```swift
import XCTest

final class MacVitalsMemoryTests: XCTestCase {
    private let suite = "MacVitalsMemoryTests"
    private var defaults: UserDefaults!
    private var memory: MacVitalsMemory!
    private let noon = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        memory = MacVitalsMemory(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func battery(_ percent: Int?) -> MacVitals { MacVitals(power: "battery", batteryPercent: percent, charging: false) }

    func testALowBatteryIsRememberedWithItsWords() throws {
        memory.record(battery(4), at: noon)
        let seen = try XCTUnwrap(memory.lastSeen(now: noon.addingTimeInterval(3600)))
        XCTAssertEqual(seen, MacVitalsMemory.LastSeen(percent: 4, at: noon))
        XCTAssertEqual(MacVitalsMemory.homeNote(seen), "Last seen on battery · 4%")
        XCTAssertEqual(MacVitalsMemory.sleepNote(seen), "It was on battery at 4%, which may be why.")
        XCTAssertNotNil(memory.lastSeen(now: noon.addingTimeInterval(3600)), "Reading does not consume it")
    }

    func testTenCountsElevenDoesNot() {
        memory.record(battery(10), at: noon)
        XCTAssertEqual(memory.lastSeen(now: noon)?.percent, 10)
        memory.record(battery(11), at: noon)
        XCTAssertNil(memory.lastSeen(now: noon))
    }

    func testExpiresAfterTwelveHours() {
        memory.record(battery(4), at: noon)
        XCTAssertNotNil(memory.lastSeen(now: noon.addingTimeInterval(12 * 3600 - 1)))
        XCTAssertNil(memory.lastSeen(now: noon.addingTimeInterval(12 * 3600 + 1)))
        XCTAssertNil(defaults.object(forKey: MacVitalsMemory.defaultsKey), "An expired entry is removed")
    }

    func testPluggedInUnknownOrMissingClears() {
        for other in [MacVitals(power: "ac", batteryPercent: 4, charging: true), MacVitals(power: "ups", batteryPercent: 4),
                      battery(nil), MacVitals()] {
            memory.record(battery(4), at: noon)
            memory.record(other, at: noon)
            XCTAssertNil(memory.lastSeen(now: noon), "\(other)")
        }
        memory.record(battery(4), at: noon)
        memory.record(nil, at: noon)
        XCTAssertNil(memory.lastSeen(now: noon))
    }

    func testFutureDatedEntryIsDiscarded() {
        memory.record(battery(4), at: noon.addingTimeInterval(7200))
        XCTAssertNil(memory.lastSeen(now: noon), "A clock change must not keep a note forever")
        memory.record(battery(4), at: noon.addingTimeInterval(60))
        XCTAssertNotNil(memory.lastSeen(now: noon), "A minute of skew is tolerated")
    }

    func testForget() {
        memory.record(battery(4), at: noon)
        memory.forget()
        XCTAssertNil(memory.lastSeen(now: noon))
    }

    func testCorruptStorageIsIgnored() {
        defaults.set(Data("not json".utf8), forKey: MacVitalsMemory.defaultsKey)
        XCTAssertNil(memory.lastSeen(now: noon))
        defaults.set("text", forKey: MacVitalsMemory.defaultsKey)
        XCTAssertNil(memory.lastSeen(now: noon))
    }

    func testOnlyPercentAndTimeAreStored() throws {
        memory.record(MacVitals(power: "battery", batteryPercent: 3, charging: false, batteryWarning: 3,
                                thermal: 2, lowPowerMode: true, load: "busy", loadCause: "memory"), at: noon)
        let data = try XCTUnwrap(defaults.data(forKey: MacVitalsMemory.defaultsKey))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["percent", "at"])
    }
}
```
- [ ] **Step 2: Run to verify failure** (`-XCTest MacVitalsNoticeTests` and `-XCTest MacVitalsMemoryTests`).
- [ ] **Step 3: Implement.** Copy: `unplugged` → `"Your Mac is now on battery · \(p)%."` / `"Your Mac is now on battery."`; `low` → `"Your Mac is on battery · \(p)%. Plug it in to keep going."`; `critical` → `"Your Mac is at \(p)% and may sleep soon. Plug it in or save your work."` / `"Your Mac’s battery is almost empty and it may sleep soon. Plug it in or save your work."`. Policy state: `wasExternal: Bool`, `lowArmed = true`, `criticalArmed = true`, `unplugSeenAt: TimeInterval?`, `busyShown = false`, `lastShownAt: TimeInterval?`; logic exactly as the paragraph above. Memory: JSON-encode `LastSeen` (`JSONEncoder` with default date strategy) into `defaults` under `defaultsKey`; `homeNote` → `"Last seen on battery · \(percent)%"`, `sleepNote` → `"It was on battery at \(percent)%, which may be why."`; the future tolerance is 5 minutes.
- [ ] **Step 4: Run** both classes. Expected: all pass.
- [ ] **Step 5: Commit** "Decide when the phone mentions the Mac's battery and load, and remember a low battery".

---

### Task 6: Host wiring (Wave 2)

**Files:**
- Modify: `RemoteHost/HostModel.swift` (properties near line 122; `beginLoadMonitor` 1593; `endLoadMonitor` 1601; `sendCaptureHealth` 1645–1670)

**Interfaces:**
- Consumes: `MacVitalsMonitor`, `LiveMacVitalsSources` (Tasks 2–3), `RemoteAction.macVitals`, `SessionFeature.host` including `vitals.1` (Task 1).
- Produces: every host `capture` status carries `macVitals` while a capture session is live; nothing is sampled otherwise.

- [ ] **Step 1: Wire it.**
  - Add `private var vitalsMonitor: MacVitalsMonitor?` next to `loadMonitor`.
  - End of `beginLoadMonitor(peer:)` (independent of `StreamTuning.current.ladder`):
    ```swift
    vitalsMonitor?.stop()
    let vitals = MacVitalsMonitor(sources: LiveMacVitalsSources())
    vitals.start(now: ProcessInfo.processInfo.systemUptime)
    vitalsMonitor = vitals
    ```
  - `endLoadMonitor()`: `vitalsMonitor?.stop()` then `vitalsMonitor = nil`.
  - `sendCaptureHealth`: pass `macVitals: vitalsMonitor?.current(now: ProcessInfo.processInfo.systemUptime)` as the last `RemoteAction` argument, after `busy: busyState`.
  - `advertisedFeatures` needs no change: it filters `SessionFeature.host`, which now includes `vitals.1`.
- [ ] **Step 2: Check every exit path.** Confirm by reading that each path ending a capture session calls `endLoadMonitor()` (today lines 1361, 1766, 1845) and that `beginLoadMonitor` runs on each capture start, including a display switch; report the line numbers you checked. If any path that stops capture skips `endLoadMonitor()`, report it instead of adding new teardown.
- [ ] **Step 3: Build and test.** Host app build command, then the core build and `-XCTest MacVitalsProtocolTests`, `-XCTest MacVitalsMonitorTests`, `-XCTest MacVitalsPowerTests`, `-XCTest HostLifecycleTests`. Expected: build succeeds; all pass.
- [ ] **Step 4: Commit** "Send the Mac's vitals on capture status during a session".

---

### Task 7: Phone model and Connection Health (Wave 2)

**Files:**
- Modify: `RemotePhone/RemotePhoneApp.swift` (published state near line 137; `receive` `"capture"` near line 1171; `end()` near line 1365), `RemotePhone/ConnectionHealth.swift`
- Test: `RemotePhoneTests/MacVitalsPhoneTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 4, 5.
- Produces on `PhoneRemoteModel`:
  - `@Published private(set) var macVitals: MacVitals?` (last received, raw)
  - `var macVitalsSupported: Bool` (host lists `vitals.1`, or a DEBUG preview says so)
  - `func currentMacVitals(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> MacVitals?` (nil when unsupported or older than `PhoneRemoteModel.macVitalsMaxAge = 3`, unless previewing)
  - `var vitalsMemory = MacVitalsMemory()` (internal, replaceable in tests)
  - `var previewingVitals: Bool` (always false in Release)
  - DEBUG only: `func previewVitalsForTesting(_ vitals: MacVitals?, supported: Bool)`
- Produces on `ConnectionHealth`: states `.macBatteryLow`, `.macUnderLoad`; `SessionEvidence.vitals: MacVitals? = nil` (declared last); `isSlowOnly` includes `.macUnderLoad`; `sessionLine` returns exactly `"Mac battery low · plug it in"` and `"Mac busy · other apps are using it"`.

- [ ] **Step 1: Write the failing tests.**
```swift
import XCTest
@testable import PocketDeskRemote

@MainActor
final class MacVitalsPhoneTests: XCTestCase {
    private let suite = "MacVitalsPhoneTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func model() -> PhoneRemoteModel {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.vitalsMemory = MacVitalsMemory(defaults: defaults)
        return model
    }

    private func send(_ vitals: MacVitals?, to model: PhoneRemoteModel, features: [String] = SessionFeature.host,
                      busy: BusyState? = nil) throws {
        let action = RemoteAction(action: "capture", x: 1, epoch: 1, features: features, busy: busy, macVitals: vitals)
        model.connection.onControl?(try JSONEncoder().encode(action))
    }

    private func battery(_ percent: Int, load: String = "ok") -> MacVitals {
        MacVitals(power: "battery", batteryPercent: percent, charging: false, batteryWarning: 1, thermal: 0,
                  lowPowerMode: false, load: load)
    }

    // MARK: Model

    func testVitalsNeedTheFeature() throws {
        let model = model()
        try send(battery(64), to: model, features: SessionFeature.host.filter { $0 != SessionFeature.macVitals })
        XCTAssertFalse(model.macVitalsSupported)
        XCTAssertNil(model.currentMacVitals())
        XCTAssertNil(model.macVitals)
    }

    func testVitalsLastOnlyWhileStatusIsFresh() throws {
        let model = model()
        try send(battery(64), to: model)
        XCTAssertTrue(model.macVitalsSupported)
        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(model.currentMacVitals(now: now), battery(64))
        XCTAssertNil(model.currentMacVitals(now: now + PhoneRemoteModel.macVitalsMaxAge + 1))
    }

    func testAStatusWithoutVitalsClearsThem() throws {
        let model = model()
        try send(battery(64), to: model)
        try send(nil, to: model)
        XCTAssertNil(model.currentMacVitals())
    }

    func testUnplugNoticeReachesTheSession() throws {
        let model = model()
        try send(MacVitals(power: "ac", batteryPercent: 64, charging: true, load: "ok"), to: model)
        try send(battery(64), to: model)
        XCTAssertEqual(model.sessionNotice, "Your Mac is now on battery · 64%.")
    }

    func testAPowerPillHoldsTheUnplugNotice() throws {
        let model = model()
        let pill = BusyState(level: .busy, fps: 30, longEdge: 1440, reason: "power")
        try send(MacVitals(power: "ac", batteryPercent: 64, charging: true, load: "ok"), to: model, busy: pill)
        try send(battery(64), to: model, busy: pill)
        XCTAssertNil(model.sessionNotice)
    }

    func testSessionEndRemembersALowBattery() throws {
        let model = model()
        try send(battery(4), to: model)
        model.connection.onEnded?()
        XCTAssertEqual(model.vitalsMemory.lastSeen(now: Date())?.percent, 4)
        XCTAssertNil(model.macVitals)
        XCTAssertFalse(model.macVitalsSupported)
    }

    func testAFailedAttemptKeepsTheLastSeenBattery() {
        let model = model()
        model.vitalsMemory.record(battery(4), at: Date())
        model.connection.onEnded?()
        XCTAssertEqual(model.vitalsMemory.lastSeen(now: Date())?.percent, 4,
                       "An attempt that never got a status knows nothing new about the battery")
    }

    func testAHealthySessionClearsTheLastSeen() throws {
        let model = model()
        model.vitalsMemory.record(battery(4), at: Date())
        try send(MacVitals(power: "ac", batteryPercent: 30, charging: true, load: "ok"), to: model)
        model.connection.onEnded?()
        XCTAssertNil(model.vitalsMemory.lastSeen(now: Date()))
    }

    func testANewSessionAnnouncesAgain() throws {
        let model = model()
        try send(battery(15), to: model)
        XCTAssertEqual(model.sessionNotice, MacVitalsNotice.low(15))
        model.connection.onEnded?()
        try send(battery(14), to: model)
        XCTAssertEqual(model.sessionNotice, MacVitalsNotice.low(14), "Ending the session resets the once-per-session notices")
    }

    #if DEBUG
    func testPreviewForLayoutChecks() {
        let model = model()
        model.previewVitalsForTesting(MacVitalsPresentation.preview("battery12"), supported: true)
        XCTAssertTrue(model.previewingVitals)
        XCTAssertTrue(model.macVitalsSupported)
        XCTAssertEqual(model.currentMacVitals(now: .greatestFiniteMagnitude), MacVitalsPresentation.preview("battery12"))
        model.previewVitalsForTesting(nil, supported: false)
        XCTAssertFalse(model.macVitalsSupported)
    }
    #endif

    // MARK: Connection Health

    private func evidence(fresh: Bool = true, rtt: Int? = nil, blocker: MacShareBlocker? = nil,
                          vitals: MacVitals?) -> ConnectionHealth.SessionEvidence {
        ConnectionHealth.SessionEvidence(connected: true, fresh: fresh, captureHealthy: true, hostPresence: nil,
                                         route: "Direct", roundTripMs: rtt, blocker: blocker, vitals: vitals)
    }

    func testLowBatteryRanksAfterPictureAndAccessibilityAndBeforeTheNetwork() throws {
        XCTAssertEqual(ConnectionHealth.session(evidence(fresh: false, vitals: battery(8)))?.state, .pictureStalled)
        XCTAssertEqual(ConnectionHealth.session(evidence(blocker: .accessibilityOff, vitals: battery(8)))?.state, .accessibilityOff)
        let low = try XCTUnwrap(ConnectionHealth.session(evidence(rtt: 400, vitals: battery(8))))
        XCTAssertEqual(low.state, .macBatteryLow)
        XCTAssertEqual(low.title, "Mac battery low")
        XCTAssertEqual(low.sessionLine, "Mac battery low · plug it in")
        XCTAssertTrue(low.detail.contains("8%"))
        XCTAssertFalse(low.isSlowOnly, "A battery about to run out outranks 'Controlling your Mac'")
    }

    func testBusyMacIsAdvisoryAndBeatsASlowNetwork() throws {
        let busy = try XCTUnwrap(ConnectionHealth.session(evidence(rtt: 400, vitals: battery(64, load: "busy"))))
        XCTAssertEqual(busy.state, .macUnderLoad)
        XCTAssertEqual(busy.title, "Mac busy")
        XCTAssertEqual(busy.sessionLine, "Mac busy · other apps are using it")
        XCTAssertTrue(busy.isSlowOnly)
        XCTAssertFalse(busy.detail.isEmpty)
        XCTAssertFalse(busy.nextStep.isEmpty)
        var memory = battery(64, load: "busy")
        memory.loadCause = "memory"
        XCTAssertTrue(try XCTUnwrap(ConnectionHealth.session(evidence(vitals: memory))).detail.contains("memory"))
    }

    func testOnlyALowBatteryOnBatteryIsAProblem() {
        XCTAssertNil(ConnectionHealth.session(evidence(vitals: battery(11))))
        XCTAssertNil(ConnectionHealth.session(evidence(vitals: MacVitals(power: "ac", batteryPercent: 5, charging: true))))
        var final = battery(30)
        final.batteryWarning = 3
        XCTAssertEqual(ConnectionHealth.session(evidence(vitals: final))?.state, .macBatteryLow)
        XCTAssertNil(ConnectionHealth.session(evidence(vitals: MacVitals(thermal: 3, lowPowerMode: true))),
                     "Heat and Low Power Mode are the pill's and the caption's to say")
    }

    func testNoVitalsKeepsTodaysOrder() {
        XCTAssertEqual(ConnectionHealth.session(evidence(rtt: 400, vitals: nil))?.state, .networkSlow)
        XCTAssertNil(ConnectionHealth.session(evidence(vitals: nil)))
    }
}
```
- [ ] **Step 2: Run to verify failure** (phone test command, `-only-testing:RemotePhoneTests/MacVitalsPhoneTests`). Expected: compile errors for the new members.
- [ ] **Step 3: Implement.**
  - `ConnectionHealth.swift`: add the two states to `State`; add `var vitals: MacVitals? = nil` as the **last** `SessionEvidence` property; in `session(_:)` after the `accessibilityOff` check:
    ```swift
    if let vitals = evidence.vitals {
        if vitals.onBattery, (vitals.batteryPercent.map { $0 <= MacVitalsNoticePolicy.criticalPercent } ?? false) || vitals.batteryWarning == 3 {
            let detail = vitals.batteryPercent.map { "Your Mac reported it’s on battery at \($0)%." }
                ?? "Your Mac reported its battery is almost empty."
            return ConnectionHealth(state: .macBatteryLow, title: "Mac battery low", detail: detail,
                                    nextStep: "Plug your Mac in, or save your work.")
        }
        if vitals.loadLevel == .busy {
            let detail = vitals.cause == .memory
                ? "Your Mac reported that other apps are using most of its memory."
                : "Your Mac reported that other apps are using most of its processor."
            return ConnectionHealth(state: .macUnderLoad, title: "Mac busy", detail: detail,
                                    nextStep: "Quitting apps you don’t need on your Mac can help.")
        }
    }
    ```
    `isSlowOnly`: `state == .relaySlow || state == .networkSlow || state == .macUnderLoad`. `sessionLine`: add `case .macBatteryLow: "Mac battery low · plug it in"` and `case .macUnderLoad: "Mac busy · other apps are using it"`.
  - `RemotePhoneApp.swift`:
    - State: the members listed under Interfaces, plus `private var macVitalsReceivedAt: TimeInterval = 0`, `private var vitalsNotices = MacVitalsNoticePolicy()`, `static let macVitalsMaxAge: TimeInterval = 3`, and DEBUG `private var vitalsPreview: (supported: Bool, active: Bool) = (false, false)`.
    - `receive` `"capture"`, directly after `if action.busy != busy { busy = action.busy }`:
      ```swift
      let now = ProcessInfo.processInfo.systemUptime
      let vitals = hostFeatures.contains(SessionFeature.macVitals) ? action.macVitals : nil
      if vitals != macVitals { macVitals = vitals }
      if vitals != nil { macVitalsReceivedAt = now }
      if let notice = vitalsNotices.observe(vitals, pill: busy, now: now) { announce(notice) }
      ```
    - `end()`, **first line** (before `hostFeatures` is cleared): `if !hostFeatures.isEmpty { vitalsMemory.record(macVitals, at: Date()) }`; with the other resets: `macVitals = nil`, `macVitalsReceivedAt = 0`, `vitalsNotices = MacVitalsNoticePolicy()`. (Plan interpretation 10: `hostFeatures` is non-empty only after a status arrived.)
    - `previewVitalsForTesting(_:supported:)` (DEBUG) sets the preview flags and `macVitals`; `previewingVitals` returns the DEBUG flag or `false`.
- [ ] **Step 4: Run** `MacVitalsPhoneTests`, `ConnectionHealthTests`, `AgentAlertFromMacTests`, `SessionLifecycleTests` (phone command, one `-only-testing` per class). Expected: all pass.
- [ ] **Step 5: Commit** "Keep the Mac's vitals on the phone, announce battery and load, and rank them in Connection Health".

---

### Task 8: Phone UI — Controls caption, Diagnostics, Home card (Wave 3)

**Files:**
- Modify: `RemotePhone/NativeSessionView.swift` (Controls header ~1300; `sessionHealth` ~771; Diagnostics page ~1561; debug `onAppear` ~238–275), `RemotePhone/HomeView.swift` (`MacCard` ~565; `homeColumn` ~238; Forget Mac ~183; `applyDebugState` ~466)
- Test: `RemotePhoneUITests/MacVitalsUITests.swift`

**Interfaces:**
- Consumes: Task 7 model members; `MacVitalsPresentation`; `MacVitalsMemory`.
- Produces: accessibility identifiers `remote.controls.vitals`, `remote.vitals`, `home.vitals`, `home.vitals.cause`; launch options `--ui-vitals=<battery12|battery64|charging82|desktop|old>` (offline layout check only) and `--ui-last-battery=<percent>` (Home, DEBUG).

- [ ] **Step 1: Write the failing UI tests.**
```swift
import XCTest

final class MacVitalsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill"] + arguments
        app.launch()
        let returnButton = app.buttons["Return to Farside"]
        if returnButton.waitForExistence(timeout: 3) { returnButton.tap() }
        return app
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testControlsCaptionSpeaksTheWholeState() {
        let app = launch(["--ui-controls-check", "--ui-vitals=battery12"])
        let caption = app.staticTexts["remote.controls.vitals"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertEqual(caption.label, "Your Mac: on battery, 12 percent, warm, Low Power Mode, busy.")
        XCTAssertTrue(app.buttons["Hold click"].isHittable, "The caption must not push the keys out of the fixed panel")
        attach("Controls caption · battery 12%")
    }

    @MainActor
    func testCaptionFitsAtTheLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill", "--ui-controls-check", "--ui-vitals=battery12",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let returnButton = app.buttons["Return to Farside"]
        if returnButton.waitForExistence(timeout: 3) { returnButton.tap() }
        let caption = app.staticTexts["remote.controls.vitals"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Hold click"].isHittable)
        XCTAssertTrue(app.buttons["remote.controls.settings"].firstMatch.isHittable)
        XCTAssertLessThan(caption.frame.height, 40, "One line, not a wrapped paragraph")
        attach("Controls caption · largest text")
    }

    @MainActor
    func testOlderMacShowsNoCaptionAndExplainsInDiagnostics() {
        let app = launch(["--ui-controls-settings", "--ui-controls-page=diagnostics", "--ui-vitals=old"])
        let section = app.descendants(matching: .any)["remote.vitals"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your Mac’s Farside is too old to report battery and load. Update it on your Mac."].exists)
        XCTAssertFalse(app.staticTexts["remote.controls.vitals"].exists)
    }

    @MainActor
    func testDiagnosticsListsTheMac() {
        let app = launch(["--ui-controls-settings", "--ui-controls-page=diagnostics", "--ui-vitals=battery12"])
        XCTAssertTrue(app.descendants(matching: .any)["remote.vitals"].firstMatch.waitForExistence(timeout: 5))
        for text in ["Battery · 12% · macOS low-battery warning", "Warm", "Busy · processor"] {
            XCTAssertTrue(app.staticTexts[text].exists || app.descendants(matching: .any)
                .containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists, text)
        }
        attach("Diagnostics · Mac")
    }

    @MainActor
    func testHomeRemembersALowBattery() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-demo-mac", "--ui-last-battery=4"]
        app.launch()
        let note = app.staticTexts["home.vitals"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(note.label, "Last seen on battery · 4%")
        attach("Home · last seen battery")
    }
}
```
- [ ] **Step 2: Run to verify failure** (phone command, `-only-testing:RemotePhoneUITests/MacVitalsUITests`).
- [ ] **Step 3: Implement.**
  - Controls header: replace the lone `Text("Controls")` with
    ```swift
    VStack(alignment: .leading, spacing: 2) {
        Text("Controls")
            .font(.headline)
            .foregroundStyle(Farside.Palette.bone)
            .accessibilityAddTraits(.isHeader)
        if let vitals = model.currentMacVitals() {
            let words = MacVitalsPresentation(vitals)
            Text(words.caption)
                .font(Farside.Typeface.caption(.caption2))
                .foregroundStyle(words.isWarning ? Farside.Palette.bone : Farside.Palette.ash)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityLabel(words.spoken)
                .accessibilityIdentifier("remote.controls.vitals")
        }
    }
    ```
    Keep `.frame(minHeight: 44)` and `panelHeight` unchanged. Never use ember here.
  - `sessionHealth`: pass `vitals: model.currentMacVitals()` as the last evidence argument.
  - Diagnostics page: `connectionHealthSection`, then `macVitalsSection`, then `diagnosticsSection`. `macVitalsSection` is shown when `!offlineLayoutCheck || model.previewingVitals`; header `sectionHeader("Mac")`; body is one row, a `VStack(alignment: .leading, spacing: 6)` carrying `.accessibilityIdentifier("remote.vitals")` and `listRowBackground(Farside.Palette.panel)`, containing: `Text(MacVitalsPresentation.tooOld)` (footnote, `ash`) when `!model.macVitalsSupported`; else one `LabeledContent(row.title, value: row.value)` per row when `model.currentMacVitals()` is non-nil; else `Text(MacVitalsPresentation.waiting)` (footnote, `ash`).
  - Debug `onAppear`, **before** the `--ui-controls-check` line: `if offlineLayoutCheck, let name = LaunchOptions.value("--ui-vitals=") { model.previewVitalsForTesting(name == "old" ? nil : MacVitalsPresentation.preview(name), supported: name != "old") }`.
  - `HomeView`: add `@State private var lastBattery: MacVitalsMemory.LastSeen?`, refreshed by a `refreshLastBattery()` (`lastBattery = connection.connected ? nil : MacVitalsMemory().lastSeen(now: Date())`) called at the end of `.onAppear` (after `applyDebugState()`), in `.onChange(of: connection.connected)` and after Forget Mac; pass `vitalsNote: lastBattery.map(MacVitalsMemory.homeNote)` and `vitalsCause: model.lastDeparture == .sleeping ? lastBattery.map(MacVitalsMemory.sleepNote) : nil` to `MacCard` (two new optional `String?` properties defaulting to nil). `MacCard` shows them under the status block as `.footnote` in `Farside.Palette.ash`, identifiers `home.vitals` and `home.vitals.cause`, `fixedSize(horizontal: false, vertical: true)`. Forget Mac: add `MacVitalsMemory().forget()` next to `connection.revoke()`. `applyDebugState`: `if let raw = LaunchOptions.value("--ui-last-battery="), let percent = Int(raw) { MacVitalsMemory().record(MacVitals(power: "battery", batteryPercent: percent, charging: false), at: Date()) }` (it runs before `refreshLastBattery()` in `.onAppear`).
- [ ] **Step 4: Run** `MacVitalsUITests`, then regression `-only-testing:RemotePhoneUITests/SessionLayoutTests/testOfflineControlsPortraitLandscapeAndKeyboard`, `-only-testing:RemotePhoneUITests/SessionLayoutTests/testHomeKeepsPairingAndRecoveryDiscoverable`, and `-only-testing:RemotePhoneTests/MacVitalsPhoneTests`. Expected: all pass. Save the four screenshots from the `.xcresult` to `~/Downloads/farside-mac-vitals-<name>.png` (`xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>`) and list them in the report.
- [ ] **Step 5: Commit** "Show the Mac's vitals in Controls, Diagnostics and the Home card".

---

### Task 9: Integration, whole-branch review, records (orchestrator, Wave 4)

- [ ] **Step 1: Full suites** on `farside-mac-vitals` with `DD=…/vitals-final`: `RemoteCoreTests` full (`xcodebuild … -scheme RemoteCoreTests -destination platform=macOS test`), host app build, `RemotePhoneTests` full on "Farside Vitals iPhone", `RemotePhoneUITests/MacVitalsUITests`. Record exact counts. Any failure outside Mac vitals is rechecked on `farside-connection-health` (`84d871e`) before being called pre-existing.
- [ ] **Step 2: Whole-branch review** by a fresh reviewer sub-agent over `git diff 84d871e...farside-mac-vitals`, against the spec, this plan's interpretations and Review Focus. Fix Critical/Important findings through a fix sub-agent and re-review.
- [ ] **Step 3: Records.** Check every branch for the next free decision number (`git grep -F "| D4" $(git for-each-ref --format='%(refname:short)' refs/heads) -- PRODUCT.md`; D38/D39 are taken by `farside-big-text` and `farside-motion-lab`). Add the PRODUCT row and a dated status section (approved decisions, plan interpretations 1–10, evidence levels, the rebase note), and a ledger entry at the end of `Docs/IMPLEMENTATION-PLAN.md` (branch, SHAs per task, test counts, what is unverified).
- [ ] **Step 4: Cleanup.** Remove the task worktrees and `vitals/*` branches after merge, delete every `vitals-*` DerivedData, shut down "Farside Vitals iPhone". Push `farside-mac-vitals`.

**Physically unverified by design** (needs a quiet window and an installed build; not authorized here): unplug/replug caption flip within about 2 s, Low Power Mode toggle, `yes > /dev/null` busy and clear timing, host CPU cost with `top -l`, 20 %/10 % notices and thermal in real use.
