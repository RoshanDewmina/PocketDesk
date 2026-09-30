# Couch Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a proven same-network link, the phone can open a session with no picture where it is only the Mac's trackpad and keyboard, switch to the normal picture session and back in one tap, while the Mac tells anyone sitting at it that it is being steered.

**Architecture:** Pure, injectable units first (wire protocol, phone control gate and ack watchdog, host admission/health/token policy, multi-display clamp, Mac presentation), each with its own XCTest class. Two wiring tasks then connect them to `RemoteHostModel` and `PhoneRemoteModel`; a final UI task adds the Home entry and the Couch surface inside `NativeSessionView`. A scaffold task pre-creates every new file and registers it in `project.yml`/the generated Xcode project so parallel agents never edit the project file. One small backend change stops the staging developer relay pass from turning a Couch registration into a remote route.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSPanel`), CoreGraphics display list, WebRTC data channel, XCTest/XCUITest, XcodeGen; Backend: TypeScript Cloudflare Workers, vitest via `bun`.

**Spec:** `Docs/plans/COUCH-MODE-DESIGN-2026-09-30.md` (commit `e5756ee` on `farside-feature-specs`; Decisions section at the end: C1 everyone on proven LAN only; C2 no picture, one-tap switch to Picture; C3 3 s HUD + menu bar + popover; C4 Mac setup unchanged).

## Global Constraints

- Deployment: iOS/iPadOS 26+, macOS 26+, Apple silicon only (D35). New `RemoteShared` files compile for iOS **and** macOS and are built into every target that lists the `RemoteShared` folder (phone app, host, `RemoteCoreTests`, `PocketDeskBrowserFixture`, `E2EStubHost`): Foundation only, no AppKit/UIKit.
- `HostPresentation.swift`, `HostViewState.swift`, `HostPermissionState.swift` and `HostReadiness.swift` are also compiled by `HostUISnapshotTests`, which does **not** include `RemoteShared/CouchProtocol.swift` or `RemoteHost/CouchSessionPolicy.swift`. These four files must not reference any new Couch type (use plain `Bool`/`String`).
- Capability: `SessionFeature.couch = "couch.1"`; **not** in the static `SessionFeature.host` list; the host appends it in `advertisedFeatures`. The phone sends a `mode` action only after seeing `couch.1`.
- Wire: phone `acceptedAck` body `{"mode":"couch"}` (Picture sends **no body**, exactly as today); body read leniently, at most 256 bytes, anything unknown = Picture. Phone → host action `"mode"` with `mode` = `picture`|`couch`. Host `capture` status carries `mode` = `picture`|`couch`|`refused` and one-shot `modeReason` = `notLocal`|`controlOff`|`screenRecording`.
- Timings: host couch heartbeat limit 0.75 s; lifecycle tick 0.25 s (unchanged); tokens 1 s (unchanged) issued in Couch **only while couch-healthy**; Couch hold lease 1 s (Picture stays 2 s); phone Couch status age limit 1 s; ack watchdog 300 ms; Hold-click auto-drop 10 s (unchanged); Couch pointer gain `pointerScale = 1`, speed ×1.4.
- Input safety: a Picture session's host gate, token issue, lease and phone gate are **byte-for-byte unchanged in behaviour**. Any change that weakens Picture input safety is a blocker. Couch never starts `SCStream`, the encoder, the load monitor, viewport crop, cursor hiding, the privacy curtain or Big Text.
- Route rule (C1): Couch only on a proven directly attached link (`route.access == local` **and** `PeerMedia` local path authorized), for every user including Anywhere subscribers; never relay/internet. For a Couch connection the phone sends no entitlement token and does not list `remote.1`.
- Mac setup unchanged (C4): registration still requires Screen Recording and Accessibility.
- User-facing copy (exact, curly apostrophes as elsewhere in the app): "Couch mode", "Trackpad and keys. No picture.", "Checking you’re on the same network…", "Couch mode works on the same Wi-Fi or Ethernet network. Join your Mac’s network and try again.", "Control is off on your Mac. Turn on Allow control in Farside’s menu.", "Update Farside on your Mac to use Couch mode. Showing the picture instead.", "Your Mac isn’t answering. Input paused.", "Your Mac needs Screen Recording to show the picture.", "Showing your Mac’s screen…", "Look at your Mac. This is its trackpad.", "The picture is the one on your wall.", "iPhone is steering this Mac · Couch mode, no picture shared", "Connect with picture". Mac popover: headline "Couch mode · no picture shared" / title "Your iPhone is steering" (control off: "Couch mode · control is off" / "Your iPhone is connected").
- Code comments only where the *why* is non-obvious (repo and user rule). No docstrings restating names.
- Repo rules (AGENTS.md + orchestrator): wrap every `xcodebuild`/`xctest` in `lockf -k /tmp/farside-xcodebuild.lock`; per-task DerivedData `/Volumes/Studio/Development/Caches/Xcode/DerivedData/couch-<task>`; `df -h / /Volumes/Studio` before building, stop if < 20 GB free; never install to the phone or `/Applications`; never run `script/build_and_run.sh`, `wrangler deploy` or anything touching staging/production; only the simulator "Farside Couch iPhone", shut down after use; never touch other worktrees or the main checkout; backend uses `bun` only (never npm/yarn/pnpm); commit messages: imperative subject, body, final line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A Picture session must keep exactly today's input safety.** A new mode parameter threaded through the host gate, token issue and phone gate is the easiest place to widen Picture by accident. Tests: Task 4 `testPictureSessionGateIsExactlyTheOldPolicy`, `testTokensAndWireFields` (Picture keeps issuing as today), Task 3 `testPictureGateIsExactlyTheOldExpressionForEveryInput`, Task 5 `testAPictureConfigurationForgetsTheOtherDisplays`.
2. **Wi-Fi drops while a drag is held in Couch:** the Mac lets go within 1 s and the phone stops clicking. Tests: Task 4 `testCouchLeaseDropsAHeldButtonOneSecondAfterTheLastRenewal`, `testCouchHealthNeedsEveryTermAndAFreshHeartbeat`; Task 3 `testAMoveUnacknowledgedFor300msStallsUntilTheMacCatchesUp`; Task 8 `testAStaleCouchStatusStopsControl`.
3. **A late capture-health callback after switching Picture → Couch** must not enable input. Test: Task 4 `testCouchSessionUsesOnlyCouchHealthAndARefusedSessionNothing`.
4. **A paid phone, a VPN/cellular phone or a developer-pass staging room** must never get Couch over a relay/remote route. Tests: Task 2 `testACouchRegistrationListsNoRemoteAccessAndSendsNoEntitlement`, `testACouchRequestOnARemoteRouteStopsBeforeTheAcceptedAck`; Task 4 `testAdmissionRefusesAnythingButAProvenLocalLinkWithControlOn`; Task B `never gives a Couch registration the developer relay pass`.
5. **Pointer on an extended TV:** it can cross onto the TV but never escapes into the gap between displays, and a Picture session still clamps to the streamed display only. Tests: Task 5 `testMotionIntoTheGapLandsOnTheNearestDisplay`, `testAPictureConfigurationForgetsTheOtherDisplays`.

---

## Execution model (read first)

- **Waves.** Task 0 runs alone (orchestrator). Wave 1 in parallel: Tasks 1, 2, 3, 4, 5, 6, B. Wave 2 in parallel: Tasks 7 (host wiring) and 8 (phone model). Wave 3: Task 9 (phone UI). Then Task 10 (integration, reviews, ledger). Each task lists what it consumes.
- **One worktree per task:** `git -C /Users/roshansilva/Developer/PocketDesk worktree add -b couch/<task> .claude/worktrees/couch-<task> farside-couch-mode` (after the previous wave is merged into `farside-couch-mode`). Work only inside that directory, with absolute paths.
- **Never commit `PocketDesktop.xcodeproj` or `project.yml` in Tasks 1–9.** Task 0 registers every new file. If you ever run `xcodegen generate` locally, run `git checkout -- PocketDesktop.xcodeproj` before committing.
- **Builds.** `DD=/Volumes/Studio/Development/Caches/Xcode/DerivedData/couch-<task>`. Check `df -h / /Volumes/Studio` first; stop and report if under 20 GB free.
- **Mac core test command** (Tasks 1–7):
  ```bash
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme RemoteCoreTests -destination platform=macOS -derivedDataPath "$DD" -collect-test-diagnostics never build-for-testing
  lockf -k /tmp/farside-xcodebuild.lock xcrun xctest -XCTest <ClassName> "$DD/Build/Products/Debug/RemoteCoreTests.xctest"
  ```
- **Host app build** (Tasks 6, 7): `lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemoteHost -destination platform=macOS -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build`
- **Phone test command** (Tasks 8, 9), simulator created in Task 0:
  ```bash
  SIM=$(xcrun simctl list devices -j | python3 -c "import json,sys;print([d['udid'] for r in json.load(sys.stdin)['devices'].values() for d in r if d['name']=='Farside Couch iPhone'][0])")
  lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -destination "id=$SIM" -derivedDataPath "$DD" -parallel-testing-enabled NO -collect-test-diagnostics never -only-testing:RemotePhoneTests/<ClassName> test
  xcrun simctl shutdown "$SIM"
  ```
- **Report** exact pass/fail/skip counts. A failing unrelated pre-existing test is reported, not "fixed". Task 0 records the baseline.

---

### Task 0: Scaffold, simulator, baseline (orchestrator, alone)

**Files:**
- Create (stubs below): `RemoteShared/CouchProtocol.swift`, `RemoteShared/CouchPhoneGate.swift`, `RemoteHost/CouchSessionPolicy.swift`, `RemoteHost/CouchHUD.swift`
- Create (empty test classes): `RemoteTests/CouchProtocolTests.swift`, `RemoteTests/CouchHandshakeTests.swift`, `RemoteTests/CouchPhoneGateTests.swift`, `RemoteTests/CouchHostPolicyTests.swift`, `RemoteTests/CouchDisplayClampTests.swift`, `RemoteTests/CouchPresentationTests.swift`, `RemotePhoneTests/CouchPhoneModelTests.swift`, `RemotePhoneUITests/CouchModeUITests.swift`
- Modify: `RemoteShared/ControlProtocol.swift` (two fields + validate hook), `RemoteShared/SessionContinuity.swift` (feature constant), `project.yml` (`RemoteCoreTests` sources, line ~242), `PocketDesktop.xcodeproj` (regenerated)

**Interfaces:** Produces every type name below. Stub bodies return inert values so everything compiles and each task's new tests fail first.

- [ ] **Step 1: `RemoteShared/ControlProtocol.swift`.** Append two properties at the **end** of `RemoteAction`'s stored properties (after `busy`), so every existing memberwise call site still compiles:
  ```swift
      /// Couch mode: the phone's `mode` request, or the Mac's mode on `capture` status. Validated in CouchProtocol.swift.
      var mode: String? = nil
      /// One-shot reason the Mac did not switch, on `capture` status.
      var modeReason: String? = nil
  ```
  In `validate()`, directly before `if try validateDisplaySelection() { return }`, add `if try validateSessionMode() { return }`.
- [ ] **Step 2: `RemoteShared/SessionContinuity.swift`.** In `enum SessionFeature`, after `ladder`, add `static let couch = "couch.1"` with the comment `/// Couch mode: trackpad and keys with no picture, on a proven local link. Advertised by the host itself, not in \`host\`.` Do **not** add it to `host`.
- [ ] **Step 3: Stubs.**

`RemoteShared/CouchProtocol.swift`:
```swift
import Foundation

enum SessionMode: String, Codable, Equatable, CaseIterable {
    case picture, couch
}

enum SessionModeRefusal: String, Equatable, CaseIterable {
    case notLocal, controlOff, screenRecording
}

enum SessionModeStatus {
    static let refused = "refused"
}

/// The `acceptedAck` body, inside the pairing cipher. Picture sends no body, so an older Mac sees nothing new.
struct SessionModeRequest: Codable, Equatable {
    static let maximumBodyBytes = 256
    var mode: String

    static func body(for mode: SessionMode) -> Data? { nil }
    static func mode(fromAcceptedAckBody body: Data?) -> SessionMode { .picture }
}

enum CouchCopy {
    static let entryTitle = "Couch mode"
    static let entryCaption = "Trackpad and keys. No picture."
    static let checking = "Checking you’re on the same network…"
    static let notLocal = "Couch mode works on the same Wi-Fi or Ethernet network. Join your Mac’s network and try again."
    static let controlOff = "Control is off on your Mac. Turn on Allow control in Farside’s menu."
    static let updateMac = "Update Farside on your Mac to use Couch mode. Showing the picture instead."
    static let notAnswering = "Your Mac isn’t answering. Input paused."
    static let needsScreenRecording = "Your Mac needs Screen Recording to show the picture."
    static let showingPicture = "Showing your Mac’s screen…"
    static let restHeadline = "Look at your Mac. This is its trackpad."
    static let restDeadpan = "The picture is the one on your wall."
    static let hud = "iPhone is steering this Mac · Couch mode, no picture shared"
    static let connectWithPicture = "Connect with picture"
    /// Coordinator status when the phone itself stops a Couch attempt that did not get a local route.
    static let phoneRefusedStatus = "Couch mode needs the same network as your Mac."

    static func refusal(_ reason: SessionModeRefusal) -> String { "" }
}

extension RemoteAction {
    static let modeAction = "mode"

    func validateSessionMode() throws -> Bool { false }
}
```

`RemoteShared/CouchPhoneGate.swift`:
```swift
import Foundation

enum CouchTuning {
    static let speed: Double = 1.4
}

enum PhoneControlGate {
    struct Inputs: Equatable {
        var mode: SessionMode = .picture
        var privacyShield = false
        var contentConcealed = false
        var connected = false
        var controlAllowed = false
        var fresh = false
        var captureHealthy = false
        var hostModeIsCouch = false
        var statusAge: TimeInterval = .infinity
        var geometryEpoch: UInt64 = 0
        var nativeInteractionSupported = false
        var hasToken = false
        var tokenAge: TimeInterval = .infinity
    }

    static let couchStatusLimit: TimeInterval = 1

    static func canControl(_ inputs: Inputs) -> Bool { false }
}

struct CouchAckWatchdog: Equatable {
    static let limit: TimeInterval = 0.3
    static let capacity = 128

    var pendingCount: Int { 0 }
    mutating func sent(ordinal: UInt64, at now: TimeInterval) {}
    mutating func acknowledged(through applied: UInt64) {}
    func stalled(at now: TimeInterval) -> Bool { false }
    mutating func reset() {}
}

enum PhoneModeOutcome: Equatable {
    case picture, couch, couchUnsupported
    case refused(SessionModeRefusal)
}

enum PhoneModeResolver {
    static func resolve(requested: SessionMode, features: Set<String>, statusMode: String?, reason: String?) -> PhoneModeOutcome {
        .picture
    }
}
```

`RemoteHost/CouchSessionPolicy.swift`:
```swift
import Foundation
import CoreGraphics

enum HostSessionState: Equatable {
    case picture, couch
    case refused(SessionModeRefusal)

    var wireMode: String { "picture" }
    var wireReason: String? { nil }
    func issuesTokens(healthy: Bool) -> Bool { false }
}

struct CouchAdmissionInputs: Equatable {
    var routeLocal = false
    var provenLinkActive = false
    var allowControl = false
    var accessibility: HostPermissionStatus = .unchecked
}

enum CouchAdmission {
    static func decide(_ inputs: CouchAdmissionInputs) -> SessionModeRefusal? { .notLocal }
}

struct CouchHealthInputs: Equatable {
    var routeLocal = false
    var provenLinkActive = false
    var heartbeatAge: TimeInterval?
    var screenLocked = false
    var consoleUserActive = true
    var allowControl = false
    var accessibility: HostPermissionStatus = .unchecked
    var phonePaused = false
}

enum CouchHealth {
    static let heartbeatLimit: TimeInterval = 0.75
    static func isHealthy(_ inputs: CouchHealthInputs) -> Bool { false }
}

extension HostControlPolicy {
    static func isEnabled(userConsent: Bool, accessibilityPermission: HostPermissionStatus,
                          session: HostSessionState, captureHealthy: Bool, couchHealthy: Bool) -> Bool { false }
}

extension RemoteInputLease {
    static let pictureDuration: TimeInterval = 2
    static let couchDuration: TimeInterval = 1
}

enum HostCouchDisplays {
    struct Display: Equatable {
        var id: UInt32
        var bounds: CGRect
        var mirrorsAnother: Bool
    }

    static func rects(_ displays: [Display], main: UInt32) -> [CGRect] { [] }
    static func current() -> [CGRect] { [] }
}
```

`RemoteHost/CouchHUD.swift`:
```swift
import AppKit

@MainActor
final class CouchHUD {
    static let duration: TimeInterval = 3

    func show() {}
    func hide() {}
}
```

Each empty test file: `import XCTest` then `final class <FileName>: XCTestCase {}` (phone files add `@testable import PocketDeskRemote` and `@MainActor`; the UI test file only `import XCTest`).

- [ ] **Step 4: Register.** In `project.yml`, `RemoteCoreTests.sources` (line ~242), add `RemoteHost/CouchSessionPolicy.swift` after `RemoteHost/RemoteInputDriver.swift`. Run `xcodegen generate`. Check `git diff --stat PocketDesktop.xcodeproj` shows only the new files.
- [ ] **Step 5: Simulator.** `xcrun simctl create "Farside Couch iPhone" "iPhone 17"` (if missing, `xcrun simctl list devicetypes` and pick the newest iPhone). Do not touch other simulators.
- [ ] **Step 6: Baseline.** With `DD=…/couch-task0`: core build-for-testing, then full `xcrun xctest "$DD/Build/Products/Debug/RemoteCoreTests.xctest"` (record counts); host build (`CODE_SIGNING_ALLOWED=NO`); phone app build-for-testing (`-scheme PocketDeskRemote … build-for-testing`). All must succeed before Wave 1.
- [ ] **Step 7: Commit** `Scaffold Couch mode files and test classes` (body lists the stub files and the one project.yml line). Push `farside-couch-mode`.

---

### Task 1: Wire protocol (Wave 1)

**Files:**
- Modify: `RemoteShared/CouchProtocol.swift`
- Test: `RemoteTests/CouchProtocolTests.swift`

**Interfaces:**
- Consumes: Task 0 stubs; `ClipboardFrame.isWellFormedStatus(_:)` (`RemoteShared/ClipboardTransfer.swift:79`), `RemoteError.invalidMessage`.
- Produces: `SessionModeRequest.body(for:) -> Data?`, `SessionModeRequest.mode(fromAcceptedAckBody:) -> SessionMode`, `RemoteAction.validateSessionMode() throws -> Bool`, `CouchCopy.refusal(_:) -> String`.

- [ ] **Step 1: Write the failing tests** in `RemoteTests/CouchProtocolTests.swift`:
```swift
import XCTest

final class CouchProtocolTests: XCTestCase {
    func testPictureSendsNoAcceptedAckBodySoOlderMacsSeeNothingNew() throws {
        XCTAssertNil(SessionModeRequest.body(for: .picture))
        let body = try XCTUnwrap(SessionModeRequest.body(for: .couch))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"mode":"couch"}"#)
    }

    func testTheMacReadsTheRequestLenientlyAndDefaultsToPicture() {
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: nil), .picture)
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: SessionModeRequest.body(for: .couch)), .couch)
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: Data(#"{"mode":"picture"}"#.utf8)), .picture)
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: Data(#"{"mode":"hologram"}"#.utf8)), .picture)
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: Data("not json".utf8)), .picture)
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: Data(#"{"mode":"couch","later":1}"#.utf8)), .couch)
        let padded = Data((#"{"mode":"couch","pad":""# + String(repeating: "x", count: 300) + #""}"#).utf8)
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: padded), .picture, "bodies over 256 bytes are ignored")
    }

    func testModeRequestValidatesOnlyAsABareActionWithAKnownMode() {
        XCTAssertNoThrow(try RemoteAction(action: "mode", epoch: 3, mode: "couch").validate())
        XCTAssertNoThrow(try RemoteAction(action: "mode", epoch: 3, mode: "picture").validate())
        let invalid: [RemoteAction] = [
            RemoteAction(action: "mode", epoch: 3),
            RemoteAction(action: "mode", epoch: 3, mode: "hologram"),
            RemoteAction(action: "mode", x: 1, epoch: 3, mode: "couch"),
            RemoteAction(action: "mode", key: "a", epoch: 3, mode: "couch"),
            RemoteAction(action: "mode", epoch: 3, interaction: NativeInteraction(token: "t"), mode: "couch"),
            RemoteAction(action: "mode", epoch: 3, features: [SessionFeature.couch], mode: "couch"),
            RemoteAction(action: "mode", epoch: 3, display: 7, mode: "couch"),
            RemoteAction(action: "mode", epoch: 3, mode: "couch", modeReason: "notLocal"),
            RemoteAction(action: "click", epoch: 3, mode: "couch"),
            RemoteAction(action: "heartbeat", epoch: 3, mode: "couch"),
            RemoteAction(action: "pause", epoch: 3, mode: "couch"),
            RemoteAction(action: "capture", x: 1, epoch: 3, modeReason: "notLocal"),
            RemoteAction(action: "capture", x: 1, epoch: 3, mode: "not a word!"),
            RemoteAction(action: "capture", x: 1, epoch: 3, mode: "couch", modeReason: String(repeating: "a", count: 40))
        ]
        for action in invalid {
            XCTAssertThrowsError(try action.validate(), "\(action.action) \(action.mode ?? "nil") \(action.modeReason ?? "nil")")
        }
    }

    func testCaptureStatusCarriesModeAndAWellFormedReason() throws {
        let status = RemoteAction(action: "capture", x: 0, epoch: 4, features: [SessionFeature.couch],
                                  mode: SessionModeStatus.refused, modeReason: SessionModeRefusal.notLocal.rawValue)
        XCTAssertNoThrow(try status.validate())
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded.mode, "refused")
        XCTAssertEqual(decoded.modeReason, "notLocal")
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, epoch: 4, mode: "couch").validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, epoch: 4, mode: "somethingNewer",
                                          modeReason: "futureReason").validate(),
                         "A newer Mac's words must not end an older phone's session")
    }

    func testCouchFeatureIsAdvertisableButNotInTheStaticList() {
        XCTAssertEqual(SessionFeature.couch, "couch.1")
        XCTAssertFalse(SessionFeature.host.contains(SessionFeature.couch))
        XCTAssertNoThrow(try RemoteAction(action: "capture", features: SessionFeature.host + [SessionFeature.couch]).validate())
    }

    func testRefusalCopyMatchesTheApprovedWording() {
        XCTAssertEqual(CouchCopy.refusal(.notLocal), CouchCopy.notLocal)
        XCTAssertEqual(CouchCopy.refusal(.controlOff), CouchCopy.controlOff)
        XCTAssertEqual(CouchCopy.refusal(.screenRecording), CouchCopy.needsScreenRecording)
        XCTAssertEqual(CouchCopy.notLocal, "Couch mode works on the same Wi-Fi or Ethernet network. Join your Mac’s network and try again.")
    }
}
```
- [ ] **Step 2: Run** the core test command with `-XCTest CouchProtocolTests`. Expected: FAIL (stub returns nil/false/"").
- [ ] **Step 3: Implement** in `CouchProtocol.swift`:
```swift
    static func body(for mode: SessionMode) -> Data? {
        guard mode != .picture else { return nil }
        return try? JSONEncoder().encode(SessionModeRequest(mode: mode.rawValue))
    }

    static func mode(fromAcceptedAckBody body: Data?) -> SessionMode {
        guard let body, body.count <= maximumBodyBytes,
              let request = try? JSONDecoder().decode(SessionModeRequest.self, from: body),
              let mode = SessionMode(rawValue: request.mode) else { return .picture }
        return mode
    }
```
```swift
    static func refusal(_ reason: SessionModeRefusal) -> String {
        switch reason {
        case .notLocal: notLocal
        case .controlOff: controlOff
        case .screenRecording: needsScreenRecording
        }
    }
```
```swift
    /// Returns true when this is a complete `mode` request, which bypasses the legacy action list.
    func validateSessionMode() throws -> Bool {
        if action == "capture" {
            if let mode, !ClipboardFrame.isWellFormedStatus(mode) { throw RemoteError.invalidMessage }
            if let modeReason {
                guard mode != nil, ClipboardFrame.isWellFormedStatus(modeReason) else { throw RemoteError.invalidMessage }
            }
            return false
        }
        guard action == Self.modeAction else {
            guard mode == nil, modeReason == nil else { throw RemoteError.invalidMessage }
            return false
        }
        guard let mode, SessionMode(rawValue: mode) != nil, modeReason == nil,
              x == 0, y == 0, text.isEmpty, key.isEmpty, modifiers.isEmpty,
              interaction == nil, pointerLocatorSupported == nil, pointerProbe == nil, pointerLocation == nil,
              pointerSync == nil, streamQuality == nil, textFocusProbe == nil, textFocusEditable == nil,
              clipboard == nil, features == nil, hostState == nil, hostStream == nil, curtain == nil, hostEvent == nil,
              displays == nil, display == nil, agentAlert == nil, clock == nil, screenPixels == nil, viewport == nil,
              phoneLoad == nil, captureRegion == nil, ladder == nil, busy == nil
        else { throw RemoteError.invalidMessage }
        return true
    }
```
- [ ] **Step 4: Run** `-XCTest CouchProtocolTests` → PASS. Then the full core suite (`xcrun xctest "$DD/Build/Products/Debug/RemoteCoreTests.xctest"`): no new failures versus the Task 0 baseline (`NativeProtocolTests`, `ClipboardTransferTests`, `DisplaySelectionTests`, `PrivacyCurtainTests` especially).
- [ ] **Step 5: Commit** `Define the Couch mode wire protocol` (body: acceptedAck body, `mode` action, capture `mode`/`modeReason`, leniency rules).

---

### Task 2: Coordinator and peer link (Wave 1)

**Files:**
- Modify: `RemoteShared/RemoteCoordinator.swift` (properties ~:41–48, `start(resetRetryBudget:)` :228–232, `resetSession()` :333–347, `"accepted"`/`"acceptedAck"` cases :489–504, `prepareMedia()` :529–539), `RemoteShared/PeerMedia.swift` (next to `localGateOpen()` ~:217)
- Test: `RemoteTests/CouchHandshakeTests.swift`

**Interfaces:**
- Consumes: Task 0/1 `SessionMode`, `SessionModeRequest`, `CouchCopy.phoneRefusedStatus`. (Task 1 fills `SessionModeRequest`; this task's tests need its real `body`/`mode` functions. If Task 1 is not merged yet, temporarily paste Task 1's two function bodies into your worktree's `CouchProtocol.swift` so tests run, then **revert that file** before committing; the orchestrator merges Task 1 first.)
- Produces (all `@MainActor` on `RemoteCoordinator`):
  - `var sessionModeRequest: SessionMode = .picture` — phone only; read by `start()` and when sending `acceptedAck`.
  - `private(set) var peerRequestedMode: SessionMode = .picture` — host only; set from the `acceptedAck` body; reset to `.picture` in `resetSession()`.
  - `var routeIsLocal: Bool` — `routeArmed && routePolicy?.access == .local && routePolicy expires in the future`.
  - `var provenLocalLinkActive: Bool` — `media?.provenLocalLinkActive == true`.
  - `PeerMedia.provenLocalLinkActive: Bool` — `localLink != nil && localGateOpen()`.

- [ ] **Step 1: Write the failing tests** in `RemoteTests/CouchHandshakeTests.swift`:
```swift
import XCTest
import Foundation

@MainActor
private struct Peer {
    let cipher: SignalCipher
    let role: String

    init(invitation: PairInvitation, plays role: String) throws {
        cipher = try SignalCipher(key: invitation.key, room: invitation.room)
        self.role = role
    }

    func seal(_ kind: String, request: String, session: String = "", sequence: UInt64 = 0, body: Data? = nil) throws -> RelayMessage {
        RelayMessage(type: "signal", payload: try cipher.seal(
            ProtectedMessage(kind: kind, request: request, session: session, sequence: sequence, body: body), sender: role))
    }

    func open(_ message: RelayMessage) throws -> ProtectedMessage {
        try cipher.open(try XCTUnwrap(message.payload), sender: role == "client" ? "host" : "client")
    }
}

@MainActor
private final class RecordingSignaling: SignalingTransport {
    struct Connect { let features: [String]; let entitlement: String? }
    var onMessage: ((RelayMessage) -> Void)?
    var onClose: (() -> Void)?
    private(set) var connects: [Connect] = []
    private(set) var sent: [RelayMessage] = []
    var lastCloseReason: String? { nil }

    func connect(invitation: PairInvitation, hostToken: String?, features: [String]) throws {
        try connect(invitation: invitation, hostToken: hostToken, features: features, entitlement: nil)
    }
    func connect(invitation: PairInvitation, hostToken: String?, features: [String], entitlement: String?) throws {
        connects.append(Connect(features: features, entitlement: entitlement))
    }
    func send(_ message: RelayMessage) { sent.append(message) }
    func close() {}
    func checkLiveness() {}
    func deliver(_ message: RelayMessage) { onMessage?(message) }
}

private func routeMessage(room: String, access: String) throws -> RelayMessage {
    let deadline = Int64((Date().timeIntervalSince1970 + 60) * 1000)
    let json = """
    {"type":"route","version":1,"room":"\(room)","epoch":"\(String(repeating: "c", count: 32))","revision":1,"access":"\(access)","expiresAt":\(deadline)}
    """
    return try JSONDecoder().decode(RelayMessage.self, from: Data(json.utf8))
}

@MainActor
private final class HostRig {
    let signaling = RecordingSignaling()
    let host: RemoteCoordinator
    let phone: Peer
    let invitation: PairInvitation

    init() throws {
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair)
        invitation = pair.invitation
        host = RemoteCoordinator(isHost: true, store: store, retryLimit: 2, retryBaseNanoseconds: 10_000_000,
                                 registrationStableNanoseconds: 50_000_000, signaling: signaling,
                                 renewalScheduler: ManualScheduler())
        host.allowLegacyPrivateRoute = true
        phone = try Peer(invitation: pair.invitation, plays: "client")
        host.restore()
        host.start()
        signaling.deliver(RelayMessage(type: "registered", role: "host"))
        signaling.deliver(RelayMessage(type: "ice", servers: []))
    }

    /// Request, challenge and proof; returns (request, session). The paired Mac then sends `accepted`.
    func authenticate() throws -> (String, String) {
        let request = try SecureRandom.token()
        signaling.deliver(RelayMessage(type: "peer", online: true))
        signaling.deliver(try phone.seal("request", request: request))
        let challenge = try phone.open(try XCTUnwrap(signaling.sent.last))
        signaling.deliver(try phone.seal("proof", request: request, session: challenge.session))
        XCTAssertEqual(host.status, "Connecting live desktop…")
        return (request, challenge.session)
    }
}

@MainActor
final class CouchHandshakeTests: XCTestCase {
    func testTheMacRecordsTheCouchRequestFromTheAcceptedAckAndForgetsItWithTheSession() throws {
        let rig = try HostRig()
        let (request, session) = try rig.authenticate()
        XCTAssertEqual(rig.host.peerRequestedMode, .picture)
        rig.signaling.deliver(try rig.phone.seal("acceptedAck", request: request, session: session, sequence: 1,
                                                 body: SessionModeRequest.body(for: .couch)))
        XCTAssertEqual(rig.host.peerRequestedMode, .couch)
        XCTAssertNotNil(rig.host.media, "the Mac still prepares media exactly as before")
        rig.signaling.deliver(RelayMessage(type: "peer", online: false))
        XCTAssertEqual(rig.host.peerRequestedMode, .picture)
        rig.host.stop()
    }

    func testAnAcceptedAckWithoutOrWithAnUnknownBodyIsAPictureSession() throws {
        let bodies: [Data?] = [nil, Data(#"{"mode":"hologram"}"#.utf8), Data("garbage".utf8)]
        for body in bodies {
            let rig = try HostRig()
            let (request, session) = try rig.authenticate()
            rig.signaling.deliver(try rig.phone.seal("acceptedAck", request: request, session: session, sequence: 1, body: body))
            XCTAssertEqual(rig.host.peerRequestedMode, .picture)
            XCTAssertNotNil(rig.host.media)
            XCTAssertTrue(rig.host.isRunning, "an unreadable body never ends the session")
            rig.host.stop()
        }
    }

    func testRouteIsLocalOnlyWhileTheServerPublishedALocalRoute() throws {
        let rig = try HostRig()
        XCTAssertFalse(rig.host.routeIsLocal)
        rig.signaling.deliver(try routeMessage(room: rig.invitation.room, access: "local"))
        XCTAssertTrue(rig.host.routeIsLocal)
        XCTAssertFalse(rig.host.provenLocalLinkActive, "a route alone is not a proven link")
        rig.signaling.deliver(RelayMessage(type: "peer", online: false))
        XCTAssertFalse(rig.host.routeIsLocal)
        rig.host.stop()

        let remote = try HostRig()
        remote.signaling.deliver(try routeMessage(room: remote.invitation.room, access: "remote"))
        XCTAssertFalse(remote.host.routeIsLocal)
        remote.host.stop()
    }

    func testAPeerWithoutAProvenLinkIsNeverLocal() {
        XCTAssertFalse(PeerMedia(isHost: true, servers: []).provenLocalLinkActive)
    }

    private func pairedPhone(_ signaling: RecordingSignaling) throws -> (RemoteCoordinator, PairInvitation) {
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair.invitation)
        let phone = RemoteCoordinator(isHost: false, store: store, retryLimit: 0, signaling: signaling,
                                      renewalScheduler: ManualScheduler())
        phone.restore()
        return (phone, pair.invitation)
    }

    func testACouchRegistrationListsNoRemoteAccessAndSendsNoEntitlement() throws {
        for mode in SessionMode.allCases {
            let signaling = RecordingSignaling()
            let (phone, _) = try pairedPhone(signaling)
            phone.advertisesRemoteAccess = true
            phone.entitlementToken = { "paid-token" }
            phone.sessionModeRequest = mode
            phone.start()
            let connect = try XCTUnwrap(signaling.connects.last)
            XCTAssertTrue(connect.features.contains(SignalingFeature.route))
            if mode == .couch {
                XCTAssertFalse(connect.features.contains(SignalingFeature.remoteAccess))
                XCTAssertNil(connect.entitlement)
            } else {
                XCTAssertTrue(connect.features.contains(SignalingFeature.remoteAccess))
                XCTAssertEqual(connect.entitlement, "paid-token")
            }
            phone.stop()
        }
    }

    /// Plays the Mac up to `accepted`; returns the counterpart so the caller can read what the phone sent.
    private func acceptPhone(_ phone: RemoteCoordinator, _ signaling: RecordingSignaling,
                             invitation: PairInvitation, access: String) throws -> Peer {
        let mac = try Peer(invitation: invitation, plays: "host")
        phone.start()
        signaling.deliver(try routeMessage(room: invitation.room, access: access))
        signaling.deliver(RelayMessage(type: "peer", online: true))
        let request = try mac.open(try XCTUnwrap(signaling.sent.last))
        XCTAssertEqual(request.kind, "request")
        let session = try SecureRandom.token()
        signaling.deliver(try mac.seal("challenge", request: request.request, session: session))
        XCTAssertEqual(try mac.open(try XCTUnwrap(signaling.sent.last)).kind, "proof")
        signaling.deliver(try mac.seal("accepted", request: request.request, session: session, sequence: 1))
        return mac
    }

    func testThePhonePutsItsModeInTheAcceptedAck() throws {
        for mode in SessionMode.allCases {
            let signaling = RecordingSignaling()
            let (phone, invitation) = try pairedPhone(signaling)
            phone.sessionModeRequest = mode
            let mac = try acceptPhone(phone, signaling, invitation: invitation, access: "local")
            let ack = try mac.open(try XCTUnwrap(signaling.sent.last))
            XCTAssertEqual(ack.kind, "acceptedAck")
            XCTAssertEqual(ack.body == nil, mode == .picture, "Picture sends no body, exactly as before")
            XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: ack.body), mode)
            phone.stop()
        }
    }

    func testACouchRequestOnARemoteRouteStopsBeforeTheAcceptedAck() throws {
        let signaling = RecordingSignaling()
        let (phone, invitation) = try pairedPhone(signaling)
        phone.sessionModeRequest = .couch
        let mac = try acceptPhone(phone, signaling, invitation: invitation, access: "remote")
        let kinds = signaling.sent.compactMap { try? mac.open($0).kind }
        XCTAssertFalse(kinds.contains("acceptedAck"))
        XCTAssertEqual(phone.status, CouchCopy.phoneRefusedStatus)
        XCTAssertFalse(phone.isRunning)
    }
}
```
- [ ] **Step 2: Run** `-XCTest CouchHandshakeTests` → FAIL to compile (missing properties).
- [ ] **Step 3: Implement.**
  - `PeerMedia.swift`, next to `localGateOpen()`:
    ```swift
    /// The media path is the proven one-hop local link and is still selected.
    var provenLocalLinkActive: Bool { localLink != nil && localGateOpen() }
    ```
  - `RemoteCoordinator.swift` properties (after `allowLegacyPrivateRoute`):
    ```swift
    /// Phone: the mode this connection asks for. Couch lists no `remote.1` and sends no entitlement,
    /// so the service publishes a local route and both peers run the one-hop proof.
    var sessionModeRequest: SessionMode = .picture
    /// Host: the mode the phone asked for in this session's `acceptedAck`.
    private(set) var peerRequestedMode: SessionMode = .picture
    var routeIsLocal: Bool {
        guard routeArmed, let routePolicy, routePolicy.expiresAt > Date() else { return false }
        return routePolicy.access == .local
    }
    var provenLocalLinkActive: Bool { media?.provenLocalLinkActive == true }
    ```
  - `start(resetRetryBudget:)`: `if !isHost && advertisesRemoteAccess && sessionModeRequest != .couch { features.append(SignalingFeature.remoteAccess) }` and `entitlement: isHost || sessionModeRequest == .couch ? nil : entitlementToken?()`.
  - `resetSession()`: add `peerRequestedMode = .picture`.
  - `case "accepted" where !isHost:` → `send(kind: "acceptedAck", body: SessionModeRequest.body(for: sessionModeRequest))` (and only if `prepareMedia()` did not fail: guard with `guard !stopped else { return }` after `prepareMedia()`).
  - `case "acceptedAck" where isHost:` → after the existing guard, `peerRequestedMode = SessionModeRequest.mode(fromAcceptedAckBody: message.body)` then `prepareMedia()`.
  - `prepareMedia()`: after the authorization guard, add
    ```swift
    if !isHost, sessionModeRequest == .couch, routePolicy?.access != .local {
        fail(CouchCopy.phoneRefusedStatus)
        return
    }
    ```
- [ ] **Step 4: Run** `-XCTest CouchHandshakeTests` → PASS; then `-XCTest StaleSignalTests`, `-XCTest SessionRenewalIntegrationTests`, `-XCTest LocalRoutePolicyTests`, `-XCTest HostSignalingRecoveryTests`, then the full core suite: no new failures.
- [ ] **Step 5: Commit** `Carry the Couch request through the handshake and keep it on a local route`.

---

### Task 3: Phone control gate, ack watchdog, mode resolver (Wave 1)

**Files:**
- Modify: `RemoteShared/CouchPhoneGate.swift`
- Test: `RemoteTests/CouchPhoneGateTests.swift`

**Interfaces:**
- Consumes: Task 0 stubs, `SessionFeature.couch`, `SessionModeStatus.refused`.
- Produces: `PhoneControlGate.canControl(_:) -> Bool`; `CouchAckWatchdog.sent(ordinal:at:)`, `.acknowledged(through:)`, `.stalled(at:) -> Bool`, `.reset()`, `.pendingCount`; `PhoneModeResolver.resolve(requested:features:statusMode:reason:) -> PhoneModeOutcome`.

- [ ] **Step 1: Write the failing tests:**
```swift
import XCTest

final class CouchPhoneGateTests: XCTestCase {
    /// The phone's gate before Couch mode, copied from `PhoneRemoteModel.canControl` at a65e864.
    private func oldPictureGate(_ i: PhoneControlGate.Inputs) -> Bool {
        !i.privacyShield && !i.contentConcealed && i.connected && i.controlAllowed && i.fresh && i.captureHealthy
            && i.geometryEpoch > 0 && (!i.nativeInteractionSupported || (i.hasToken && i.tokenAge < 1))
    }

    func testPictureGateIsExactlyTheOldExpressionForEveryInput() {
        let flags = [false, true]
        var checked = 0
        for shield in flags { for concealed in flags { for connected in flags { for allowed in flags {
        for fresh in flags { for healthy in flags { for native in flags { for token in flags { for hostCouch in flags {
            for epoch: UInt64 in [0, 3] { for tokenAge in [-0.5, 0.2, 1.0, 5.0] { for statusAge in [0.1, 3.0] {
                let inputs = PhoneControlGate.Inputs(
                    mode: .picture, privacyShield: shield, contentConcealed: concealed, connected: connected,
                    controlAllowed: allowed, fresh: fresh, captureHealthy: healthy, hostModeIsCouch: hostCouch,
                    statusAge: statusAge, geometryEpoch: epoch, nativeInteractionSupported: native,
                    hasToken: token, tokenAge: tokenAge)
                XCTAssertEqual(PhoneControlGate.canControl(inputs), oldPictureGate(inputs), "\(inputs)")
                checked += 1
            }}}
        }}}}}}}}}
        XCTAssertEqual(checked, 512 * 16)
    }

    private let liveCouch = PhoneControlGate.Inputs(
        mode: .couch, connected: true, controlAllowed: true, fresh: false, captureHealthy: true, hostModeIsCouch: true,
        statusAge: 0.3, geometryEpoch: 2, nativeInteractionSupported: true, hasToken: true, tokenAge: 0.3)

    func testCouchNeedsNoPictureButEveryOtherTerm() {
        XCTAssertTrue(PhoneControlGate.canControl(liveCouch))
        let breaks: [(inout PhoneControlGate.Inputs) -> Void] = [
            { $0.connected = false }, { $0.controlAllowed = false }, { $0.captureHealthy = false },
            { $0.hostModeIsCouch = false }, { $0.statusAge = 1.0 }, { $0.statusAge = .infinity }, { $0.statusAge = -0.5 },
            { $0.geometryEpoch = 0 }, { $0.nativeInteractionSupported = false }, { $0.hasToken = false },
            { $0.tokenAge = 1.0 }, { $0.tokenAge = -0.5 }, { $0.privacyShield = true }, { $0.contentConcealed = true }
        ]
        for (index, mutate) in breaks.enumerated() {
            var inputs = liveCouch
            mutate(&inputs)
            XCTAssertFalse(PhoneControlGate.canControl(inputs), "term \(index)")
        }
    }

    func testAMoveUnacknowledgedFor300msStallsUntilTheMacCatchesUp() {
        var dog = CouchAckWatchdog()
        XCTAssertFalse(dog.stalled(at: 0))
        dog.sent(ordinal: 1, at: 10.0)
        dog.sent(ordinal: 2, at: 10.1)
        XCTAssertFalse(dog.stalled(at: 10.29))
        XCTAssertTrue(dog.stalled(at: 10.31))
        dog.acknowledged(through: 1)
        XCTAssertFalse(dog.stalled(at: 10.39), "ordinal 2 was sent at 10.1")
        XCTAssertTrue(dog.stalled(at: 10.41))
        dog.acknowledged(through: 2)
        XCTAssertFalse(dog.stalled(at: 99))
        XCTAssertEqual(dog.pendingCount, 0)
    }

    func testOldAcksAndResetAreHarmless() {
        var dog = CouchAckWatchdog()
        dog.sent(ordinal: 5, at: 1)
        dog.acknowledged(through: 4)
        XCTAssertTrue(dog.stalled(at: 1.5))
        dog.reset()
        XCTAssertFalse(dog.stalled(at: 1.5))
    }

    func testTheQueueIsBoundedButKeepsTheOldestMove() {
        var dog = CouchAckWatchdog()
        for n in 1...1000 { dog.sent(ordinal: UInt64(n), at: Double(n) * 0.001) }
        XCTAssertLessThanOrEqual(dog.pendingCount, CouchAckWatchdog.capacity)
        XCTAssertTrue(dog.stalled(at: 0.302), "the first move, sent at 1 ms, is still the oldest")
    }

    func testModeResolution() {
        let couchMac = Set(SessionFeature.host + [SessionFeature.couch])
        let oldMac = Set(SessionFeature.host)
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .couch, features: oldMac, statusMode: nil, reason: nil), .couchUnsupported)
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .couch, features: oldMac, statusMode: "couch", reason: nil), .couchUnsupported,
                       "Couch without couch.1 is never trusted")
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .picture, features: oldMac, statusMode: nil, reason: nil), .picture)
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .couch, features: couchMac, statusMode: "couch", reason: nil), .couch)
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .picture, features: couchMac, statusMode: "couch", reason: nil), .couch,
                       "a switch inside the session follows the Mac")
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .couch, features: couchMac, statusMode: "picture", reason: nil), .picture)
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .couch, features: couchMac, statusMode: "refused", reason: "controlOff"),
                       .refused(.controlOff))
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .couch, features: couchMac, statusMode: "refused", reason: "future"),
                       .refused(.notLocal))
        XCTAssertEqual(PhoneModeResolver.resolve(requested: .couch, features: couchMac, statusMode: "somethingNew", reason: nil), .picture)
    }
}
```
- [ ] **Step 2: Run** `-XCTest CouchPhoneGateTests` → FAIL.
- [ ] **Step 3: Implement:**
```swift
    static func canControl(_ i: Inputs) -> Bool {
        guard !i.privacyShield, !i.contentConcealed, i.connected, i.controlAllowed, i.geometryEpoch > 0 else { return false }
        switch i.mode {
        case .picture:
            return i.fresh && i.captureHealthy && (!i.nativeInteractionSupported || (i.hasToken && i.tokenAge < 1))
        case .couch:
            // No picture: the Mac's own fresh, couch-mode health report stands in for the frame.
            return i.captureHealthy && i.hostModeIsCouch && (0..<couchStatusLimit).contains(i.statusAge)
                && i.nativeInteractionSupported && i.hasToken && (0..<1).contains(i.tokenAge)
        }
    }
```
```swift
struct CouchAckWatchdog: Equatable {
    static let limit: TimeInterval = 0.3
    static let capacity = 128

    private struct Sent: Equatable { let ordinal: UInt64; let at: TimeInterval }
    private var pending: [Sent] = []

    var pendingCount: Int { pending.count }

    mutating func sent(ordinal: UInt64, at now: TimeInterval) {
        guard pending.count < Self.capacity else { return }
        pending.append(Sent(ordinal: ordinal, at: now))
    }

    mutating func acknowledged(through applied: UInt64) {
        pending.removeAll { $0.ordinal <= applied }
    }

    func stalled(at now: TimeInterval) -> Bool {
        guard let oldest = pending.first else { return false }
        return now - oldest.at > Self.limit
    }

    mutating func reset() { pending.removeAll() }
}
```
```swift
    static func resolve(requested: SessionMode, features: Set<String>, statusMode: String?, reason: String?) -> PhoneModeOutcome {
        guard features.contains(SessionFeature.couch) else { return requested == .couch ? .couchUnsupported : .picture }
        switch statusMode {
        case SessionMode.couch.rawValue: return .couch
        case SessionModeStatus.refused: return .refused(reason.flatMap(SessionModeRefusal.init(rawValue:)) ?? .notLocal)
        default: return .picture
        }
    }
```
- [ ] **Step 4: Run** `-XCTest CouchPhoneGateTests` → PASS; full core suite: no new failures.
- [ ] **Step 5: Commit** `Add the phone's Couch control gate, ack watchdog and mode resolver`.

---

### Task 4: Host admission, health, gate and display list (Wave 1)

**Files:**
- Modify: `RemoteHost/CouchSessionPolicy.swift`
- Test: `RemoteTests/CouchHostPolicyTests.swift`

**Interfaces:**
- Consumes: Task 0 stubs; `HostControlPolicy.isEnabled(userConsent:accessibilityPermission:captureHealthy:)` (unchanged, `HostPermissionState.swift:92`); `RemoteInputLease`.
- Produces: real `HostSessionState.wireMode/wireReason/issuesTokens(healthy:)`, `CouchAdmission.decide(_:) -> SessionModeRefusal?` (nil = admit), `CouchHealth.isHealthy(_:)`, `HostControlPolicy.isEnabled(userConsent:accessibilityPermission:session:captureHealthy:couchHealthy:)`, `HostCouchDisplays.rects(_:main:)`, `HostCouchDisplays.current()`.
- **Do not edit `HostPermissionState.swift`** (it is compiled by `HostUISnapshotTests`, which lacks the Couch types).

- [ ] **Step 1: Write the failing tests:**
```swift
import XCTest
import CoreGraphics

final class CouchHostPolicyTests: XCTestCase {
    private func enabled(_ session: HostSessionState, capture: Bool, couch: Bool,
                         consent: Bool = true, access: HostPermissionStatus = .granted) -> Bool {
        HostControlPolicy.isEnabled(userConsent: consent, accessibilityPermission: access, session: session,
                                    captureHealthy: capture, couchHealthy: couch)
    }

    func testPictureSessionGateIsExactlyTheOldPolicy() {
        for consent in [false, true] { for access in [HostPermissionStatus.unchecked, .granted, .denied] {
            for capture in [false, true] { for couch in [false, true] {
                XCTAssertEqual(enabled(.picture, capture: capture, couch: couch, consent: consent, access: access),
                               HostControlPolicy.isEnabled(userConsent: consent, accessibilityPermission: access,
                                                           captureHealthy: capture))
            }}
        }}
    }

    func testCouchSessionUsesOnlyCouchHealthAndARefusedSessionNothing() {
        XCTAssertTrue(enabled(.couch, capture: false, couch: true))
        XCTAssertFalse(enabled(.couch, capture: true, couch: false), "a late capture callback must not enable Couch input")
        XCTAssertFalse(enabled(.couch, capture: true, couch: true, consent: false))
        XCTAssertFalse(enabled(.couch, capture: true, couch: true, access: .denied))
        XCTAssertFalse(enabled(.couch, capture: true, couch: true, access: .unchecked))
        for reason in SessionModeRefusal.allCases {
            XCTAssertFalse(enabled(.refused(reason), capture: true, couch: true))
        }
    }

    func testTokensAndWireFields() {
        XCTAssertTrue(HostSessionState.picture.issuesTokens(healthy: false), "Picture keeps today's behaviour")
        XCTAssertTrue(HostSessionState.picture.issuesTokens(healthy: true))
        XCTAssertTrue(HostSessionState.couch.issuesTokens(healthy: true))
        XCTAssertFalse(HostSessionState.couch.issuesTokens(healthy: false))
        XCTAssertFalse(HostSessionState.refused(.notLocal).issuesTokens(healthy: true))
        XCTAssertEqual(HostSessionState.picture.wireMode, "picture")
        XCTAssertEqual(HostSessionState.couch.wireMode, "couch")
        XCTAssertEqual(HostSessionState.refused(.controlOff).wireMode, SessionModeStatus.refused)
        XCTAssertEqual(HostSessionState.refused(.controlOff).wireReason, "controlOff")
        XCTAssertNil(HostSessionState.couch.wireReason)
        XCTAssertNil(HostSessionState.picture.wireReason)
        let refused = HostSessionState.refused(.notLocal)
        XCTAssertNoThrow(try RemoteAction(action: "capture", epoch: 1, mode: refused.wireMode, modeReason: refused.wireReason).validate())
    }

    func testAdmissionRefusesAnythingButAProvenLocalLinkWithControlOn() {
        let ok = CouchAdmissionInputs(routeLocal: true, provenLinkActive: true, allowControl: true, accessibility: .granted)
        XCTAssertNil(CouchAdmission.decide(ok))
        var remote = ok; remote.routeLocal = false
        XCTAssertEqual(CouchAdmission.decide(remote), .notLocal)
        var unproven = ok; unproven.provenLinkActive = false
        XCTAssertEqual(CouchAdmission.decide(unproven), .notLocal)
        var off = ok; off.allowControl = false
        XCTAssertEqual(CouchAdmission.decide(off), .controlOff)
        var noAX = ok; noAX.accessibility = .denied
        XCTAssertEqual(CouchAdmission.decide(noAX), .controlOff)
        var both = off; both.routeLocal = false
        XCTAssertEqual(CouchAdmission.decide(both), .notLocal, "the network reason wins: fixing control would not help")
    }

    func testCouchHealthNeedsEveryTermAndAFreshHeartbeat() {
        let healthy = CouchHealthInputs(routeLocal: true, provenLinkActive: true, heartbeatAge: 0.2, screenLocked: false,
                                        consoleUserActive: true, allowControl: true, accessibility: .granted, phonePaused: false)
        XCTAssertTrue(CouchHealth.isHealthy(healthy))
        var edge = healthy; edge.heartbeatAge = 0.749
        XCTAssertTrue(CouchHealth.isHealthy(edge))
        let breaks: [(inout CouchHealthInputs) -> Void] = [
            { $0.routeLocal = false }, { $0.provenLinkActive = false }, { $0.heartbeatAge = nil },
            { $0.heartbeatAge = 0.75 }, { $0.heartbeatAge = 3 }, { $0.heartbeatAge = -1 },
            { $0.screenLocked = true }, { $0.consoleUserActive = false }, { $0.allowControl = false },
            { $0.accessibility = .denied }, { $0.accessibility = .unchecked }, { $0.phonePaused = true }
        ]
        for (index, mutate) in breaks.enumerated() {
            var inputs = healthy
            mutate(&inputs)
            XCTAssertFalse(CouchHealth.isHealthy(inputs), "term \(index)")
        }
    }

    func testCouchLeaseDropsAHeldButtonOneSecondAfterTheLastRenewal() {
        var lease = RemoteInputLease(duration: RemoteInputLease.couchDuration)
        lease.record(action: "dragDown", accepted: true, at: 10)
        lease.record(action: "holdRenew", accepted: true, at: 10.5)
        XCTAssertFalse(lease.isExpired(at: 11.49))
        XCTAssertTrue(lease.isExpired(at: 11.5))
        XCTAssertEqual(RemoteInputLease().duration, RemoteInputLease.pictureDuration, "Picture keeps its 2 s lease")
    }

    func testCouchDisplaysDropMirrorsAndPutTheMainDisplayFirst() {
        let main = HostCouchDisplays.Display(id: 1, bounds: CGRect(x: 0, y: 0, width: 1470, height: 956), mirrorsAnother: false)
        let tv = HostCouchDisplays.Display(id: 2, bounds: CGRect(x: 1470, y: -300, width: 1920, height: 1080), mirrorsAnother: false)
        let mirror = HostCouchDisplays.Display(id: 3, bounds: main.bounds, mirrorsAnother: true)
        let broken = HostCouchDisplays.Display(id: 4, bounds: CGRect(x: 0, y: 0, width: 0, height: 900), mirrorsAnother: false)
        let duplicate = HostCouchDisplays.Display(id: 5, bounds: main.bounds, mirrorsAnother: false)
        let infinite = HostCouchDisplays.Display(id: 6, bounds: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10), mirrorsAnother: false)
        XCTAssertEqual(HostCouchDisplays.rects([tv, mirror, broken, main, duplicate, infinite], main: 1), [main.bounds, tv.bounds])
        XCTAssertEqual(HostCouchDisplays.rects([tv], main: 1), [tv.bounds], "a missing main display keeps the order it was given")
        XCTAssertEqual(HostCouchDisplays.rects([], main: 1), [])
    }
}
```
- [ ] **Step 2: Run** `-XCTest CouchHostPolicyTests` → FAIL.
- [ ] **Step 3: Implement** in `CouchSessionPolicy.swift`:
```swift
    var wireMode: String {
        switch self {
        case .picture: SessionMode.picture.rawValue
        case .couch: SessionMode.couch.rawValue
        case .refused: SessionModeStatus.refused
        }
    }

    var wireReason: String? {
        if case .refused(let reason) = self { return reason.rawValue }
        return nil
    }

    /// Picture keeps issuing on every status as before; Couch only while healthy; a refused session never.
    func issuesTokens(healthy: Bool) -> Bool {
        switch self {
        case .picture: true
        case .couch: healthy
        case .refused: false
        }
    }
```
```swift
    static func decide(_ inputs: CouchAdmissionInputs) -> SessionModeRefusal? {
        guard inputs.routeLocal, inputs.provenLinkActive else { return .notLocal }
        guard inputs.allowControl, inputs.accessibility.isGranted else { return .controlOff }
        return nil
    }
```
```swift
    static func isHealthy(_ i: CouchHealthInputs) -> Bool {
        guard let age = i.heartbeatAge, (0..<heartbeatLimit).contains(age) else { return false }
        return i.routeLocal && i.provenLinkActive && !i.screenLocked && i.consoleUserActive
            && i.allowControl && i.accessibility.isGranted && !i.phonePaused
    }
```
```swift
    static func isEnabled(userConsent: Bool, accessibilityPermission: HostPermissionStatus,
                          session: HostSessionState, captureHealthy: Bool, couchHealthy: Bool) -> Bool {
        switch session {
        case .picture:
            isEnabled(userConsent: userConsent, accessibilityPermission: accessibilityPermission, captureHealthy: captureHealthy)
        case .couch:
            userConsent && accessibilityPermission.isGranted && couchHealthy
        case .refused:
            false
        }
    }
```
```swift
    static func rects(_ displays: [Display], main: UInt32) -> [CGRect] {
        let usable = displays.filter { d in
            !d.mirrorsAnother && d.bounds.width > 0 && d.bounds.height > 0 &&
                [d.bounds.origin.x, d.bounds.origin.y, d.bounds.width, d.bounds.height].allSatisfy(\.isFinite)
        }
        var result: [CGRect] = []
        for display in usable.filter({ $0.id == main }) + usable.filter({ $0.id != main })
        where !result.contains(display.bounds) {
            result.append(display.bounds)
        }
        return result
    }

    /// Needs no Screen Recording: CoreGraphics display geometry only.
    static func current() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let displays = ids.prefix(Int(count)).map {
            Display(id: $0, bounds: CGDisplayBounds($0), mirrorsAnother: CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay)
        }
        return rects(Array(displays), main: CGMainDisplayID())
    }
```
- [ ] **Step 4: Run** `-XCTest CouchHostPolicyTests` → PASS; `-XCTest HostPermissionStateTests`, `-XCTest NativeInputSafetyTests`; full core suite: no new failures.
- [ ] **Step 5: Commit** `Add host Couch admission, health and input policy`.

---

### Task 5: Multi-display clamp in the input driver (Wave 1)

**Files:**
- Modify: `RemoteHost/RemoteInputDriver.swift` (`configure(_:)` :233–243, `configure(bounds:)` :245–250, `clamped(_:to:)` :589–596)
- Test: `RemoteTests/CouchDisplayClampTests.swift`

**Interfaces:**
- Produces: `RemoteInputDriver.configure(displays: [CGRect])`, `private(set) var displayRects: [CGRect]`, `static func clamp(_ point: CGPoint, toNearestOf rects: [CGRect]) -> CGPoint`.
- Rule: both existing `configure` methods set `displayRects = []`, so a Picture session always clamps to its one display.

- [ ] **Step 1: Write the failing tests:**
```swift
import XCTest
import AppKit
import CoreGraphics

private final class ClampRecorder {
    var pointer: CGPoint
    var events: [RemoteInputEventSink.MouseEvent] = []
    init(start: CGPoint) { pointer = start }

    var sink: RemoteInputEventSink {
        RemoteInputEventSink(
            pointerLocation: { [weak self] in self?.pointer ?? .zero },
            mouseSequence: { [weak self] events in
                self?.events.append(contentsOf: events)
                if let last = events.last { self?.pointer = last.point }
                return true
            },
            scroll: { _, _, _ in true },
            scrollDetailed: { _, _, _, _ in true },
            text: { _ in true },
            key: { _, _ in true }
        )
    }
}

final class CouchDisplayClampTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1470, height: 956)
    /// A TV to the right, raised so there is a gap below it next to the laptop.
    private let tv = CGRect(x: 1470, y: -300, width: 1920, height: 1080)

    private func driver(_ recorder: ClampRecorder, displays: [CGRect]) -> RemoteInputDriver {
        let driver = RemoteInputDriver(eventSink: recorder.sink, isTrusted: { true })
        driver.enabled = true
        driver.configure(displays: displays)
        return driver
    }

    func testNearestDisplayClamp() {
        let rects = [main, tv]
        XCTAssertEqual(RemoteInputDriver.clamp(CGPoint(x: 100, y: 100), toNearestOf: rects), CGPoint(x: 100, y: 100))
        XCTAssertEqual(RemoteInputDriver.clamp(CGPoint(x: 2000, y: 0), toNearestOf: rects), CGPoint(x: 2000, y: 0))
        let gap = RemoteInputDriver.clamp(CGPoint(x: 1600, y: 900), toNearestOf: rects)
        XCTAssertEqual(gap, CGPoint(x: 1600, y: tv.maxY.nextDown), "120 pt to the TV beats 130 pt to the laptop")
        XCTAssertEqual(RemoteInputDriver.clamp(CGPoint(x: -2000, y: -2000), toNearestOf: rects), .zero)
        XCTAssertEqual(RemoteInputDriver.clamp(CGPoint(x: CGFloat.nan, y: 5), toNearestOf: rects), CGPoint(x: main.midX, y: main.midY))
    }

    func testRelativeMotionCrossesOntoTheTVAndStopsAtItsFarEdge() {
        let recorder = ClampRecorder(start: CGPoint(x: 1400, y: 500))
        let driver = driver(recorder, displays: [main, tv])
        XCTAssertTrue(driver.handle(RemoteAction(action: "move", x: 200, y: 0), now: 1).accepted)
        XCTAssertEqual(recorder.events.last?.point, CGPoint(x: 1600, y: 500))
        XCTAssertTrue(driver.handle(RemoteAction(action: "move", x: 5000, y: 0), now: 2).accepted)
        XCTAssertEqual(recorder.events.last?.point, CGPoint(x: tv.maxX.nextDown, y: 500))
    }

    func testMotionIntoTheGapLandsOnTheNearestDisplay() {
        let recorder = ClampRecorder(start: CGPoint(x: 1400, y: 900))
        let driver = driver(recorder, displays: [main, tv])
        XCTAssertTrue(driver.handle(RemoteAction(action: "move", x: 200, y: 0), now: 1).accepted)
        XCTAssertEqual(recorder.events.last?.point, CGPoint(x: 1600, y: tv.maxY.nextDown))
    }

    func testAPictureConfigurationForgetsTheOtherDisplays() {
        let recorder = ClampRecorder(start: CGPoint(x: 100, y: 100))
        let driver = driver(recorder, displays: [main, tv])
        driver.configure(bounds: main)
        XCTAssertEqual(driver.displayRects, [])
        XCTAssertTrue(driver.handle(RemoteAction(action: "move", x: 5000, y: 0), now: 1).accepted)
        XCTAssertEqual(recorder.events.last?.point.x, main.maxX.nextDown)
    }

    func testASingleDisplayBehavesLikeBounds() {
        let recorder = ClampRecorder(start: CGPoint(x: 100, y: 100))
        let driver = driver(recorder, displays: [main])
        XCTAssertTrue(driver.handle(RemoteAction(action: "move", x: -500, y: 5000), now: 1).accepted)
        XCTAssertEqual(recorder.events.last?.point, CGPoint(x: 0, y: main.maxY.nextDown))
    }

    func testConfiguringDisplaysReleasesAHeldButton() {
        let recorder = ClampRecorder(start: CGPoint(x: 100, y: 100))
        let driver = driver(recorder, displays: [main, tv])
        XCTAssertTrue(driver.handle(RemoteAction(action: "dragDown"), now: 1).accepted)
        XCTAssertTrue(driver.held)
        driver.configure(displays: [main])
        XCTAssertFalse(driver.held)
        XCTAssertEqual(recorder.events.last?.type, .leftMouseUp)
    }

    func testNoUsableDisplayRefusesMotion() {
        let recorder = ClampRecorder(start: CGPoint(x: 100, y: 100))
        let driver = driver(recorder, displays: [CGRect(x: 0, y: 0, width: 0, height: 10)])
        XCTAssertFalse(driver.handle(RemoteAction(action: "move", x: 5, y: 5), now: 1).accepted)
        XCTAssertTrue(recorder.events.isEmpty)
    }
}
```
- [ ] **Step 2: Run** `-XCTest CouchDisplayClampTests` → FAIL to compile.
- [ ] **Step 3: Implement** in `RemoteInputDriver`:
```swift
    /// Couch mode only: every display the pointer may use. Empty for Picture, which clamps to `displayBounds`.
    private(set) var displayRects: [CGRect] = []

    func configure(displays: [CGRect]) {
        release()
        resetNativeSequence()
        let usable = displays.filter {
            $0.width > 0 && $0.height > 0 && [$0.origin.x, $0.origin.y, $0.width, $0.height].allSatisfy(\.isFinite)
        }
        displayRects = usable
        displayBounds = usable.dropFirst().reduce(usable.first) { $0?.union($1) }
        windowID = nil
    }

    static func clamp(_ point: CGPoint, toNearestOf rects: [CGRect]) -> CGPoint {
        guard let first = rects.first else { return point }
        guard point.x.isFinite, point.y.isFinite else { return CGPoint(x: first.midX, y: first.midY) }
        var best = point
        var bestDistance = CGFloat.infinity
        for rect in rects {
            let candidate = CGPoint(x: min(rect.maxX.nextDown, max(rect.minX, point.x)),
                                    y: min(rect.maxY.nextDown, max(rect.minY, point.y)))
            let distance = hypot(candidate.x - point.x, candidate.y - point.y)
            if distance < bestDistance { bestDistance = distance; best = candidate }
        }
        return best
    }
```
  Add `displayRects = []` to both `configure(_ filter:)` and `configure(bounds:)`. At the top of `clamped(_:to:)`: `if displayRects.count > 1 { return Self.clamp(point, toNearestOf: displayRects) }`.
- [ ] **Step 4: Run** `-XCTest CouchDisplayClampTests` → PASS; then `-XCTest AbsolutePointerDriverTests`, `-XCTest NativeInputSafetyTests`, `-XCTest HardwareInputTests`, `-XCTest DragAutoPanTests`; full core suite: no new failures.
- [ ] **Step 5: Commit** `Let Couch mode move the pointer across every display`.

---

### Task B: Backend — no developer relay pass for Couch (Wave 1, `bun` only, no deploy)

**Why:** `Backend/src/room.ts:542` grants an unentitled phone a relay (`entitled: true`, route `remote`) in a staging developer-pass room even when it sent no token. A Couch registration (no token, no `remote.1`) there would get `access: remote`, skip the proof and be refused by both peers, so Couch could never be tested on staging. Production is unaffected (the pass is refused in production), but the rule belongs in code.

**Files:**
- Modify: `Backend/src/room.ts` (`checkEntitlement` :540–542, `unentitledRelayAllowed` :557–563, `stillEntitled` :572, `registerPeer` call :805)
- Test: `Backend/test/route.test.ts`

**Interfaces:** Produces `export function unentitledRelayPass(config: { allowUnentitledRelay: boolean; devRelayRooms: Set<string> }, room: string | undefined, remoteAware: boolean): boolean`.

- [ ] **Step 1:** `cd Backend && bun install` (lockfile only; never npm/yarn/pnpm).
- [ ] **Step 2: Write the failing test** in `route.test.ts` (import `unentitledRelayPass` from `"../src/room"` in the existing import line) inside `describe("route.1 server policy", …)`:
```ts
  it("never gives a Couch registration (no remote.1, no token) the developer relay pass", () => {
    const room = "b".repeat(64);
    const config = { allowUnentitledRelay: false, devRelayRooms: new Set([room]) };
    expect(unentitledRelayPass(config, room, true)).toBe(true);
    expect(unentitledRelayPass(config, room, false)).toBe(false);
    expect(unentitledRelayPass(config, "c".repeat(64), true)).toBe(false);
    expect(unentitledRelayPass(config, undefined, true)).toBe(false);
    expect(unentitledRelayPass({ allowUnentitledRelay: true, devRelayRooms: new Set() }, room, false)).toBe(true);
  });
```
- [ ] **Step 3: Run** `bun run test -- test/route.test.ts` → FAIL (not exported).
- [ ] **Step 4: Implement** in `room.ts` (module level, exported):
```ts
/** A registration that did not ask for remote access (Couch mode) must stay on the proven local route. */
export function unentitledRelayPass(config: { allowUnentitledRelay: boolean; devRelayRooms: Set<string> },
  room: string | undefined, remoteAware: boolean): boolean {
  if (config.allowUnentitledRelay) return true;
  return remoteAware && room !== undefined && config.devRelayRooms.has(room);
}
```
  `unentitledRelayAllowed(remoteAware: boolean)` becomes `if (!unentitledRelayPass(this.config, this.state().room ?? undefined, remoteAware)) return false;` then the existing `log("dev_relay_pass_used", …)` only when the pass (not `allowUnentitledRelay`) applied, and `return true`. `checkEntitlement(token, remoteAware)` passes it through; the call in `registerPeer` becomes `this.checkEntitlement(msg.entitlement, remoteAware)`; `stillEntitled` passes `attachment.remoteAware`.
- [ ] **Step 5: Run** `bun run test` (whole backend suite) and `bun run typecheck`. Expected: all pass. Never run `wrangler deploy` or `bun run check`.
- [ ] **Step 6: Commit** `Keep Couch registrations off the developer relay pass` (body: why; staging needs a separate, human-approved deploy before physical Couch tests there).

---

### Task 6: Mac popover line and HUD (Wave 1)

**Files:**
- Modify: `RemoteHost/HostViewState.swift` (add field), `RemoteHost/HostPresentation.swift` (`.controlling, .viewing` case ~:179–191), `RemoteHost/CouchHUD.swift`
- Test: `RemoteTests/CouchPresentationTests.swift`

**Interfaces:**
- Produces: `HostViewState.couchMode: Bool` (default `false`); `CouchHUD.show()` (3 s, non-activating, click-through, all Spaces), `CouchHUD.hide()`.
- `HostViewState.swift`/`HostPresentation.swift` must use literal strings, not `CouchCopy` (see Global Constraints).

- [ ] **Step 1: Write the failing tests:**
```swift
import XCTest

final class CouchPresentationTests: XCTestCase {
    private func state(_ status: HostStatus, couch: Bool) -> HostViewState {
        var state = HostViewState()
        state.status = status
        state.couchMode = couch
        return state
    }

    func testCouchPopoverSaysNoPictureIsSharedAndKeepsStopSharing() {
        let presentation = HostPopoverPresentation.make(for: state(.controlling, couch: true))
        XCTAssertEqual(presentation.mood, .live)
        XCTAssertEqual(presentation.headline, "Couch mode · no picture shared")
        XCTAssertEqual(presentation.title, "Your iPhone is steering")
        XCTAssertEqual(presentation.actions, [.pause, .stopSharing])
        XCTAssertEqual(presentation.emphasis(of: .stopSharing), .ember)
    }

    func testCouchWithControlOffSaysSo() {
        let presentation = HostPopoverPresentation.make(for: state(.viewing, couch: true))
        XCTAssertEqual(presentation.headline, "Couch mode · control is off")
        XCTAssertEqual(presentation.title, "Your iPhone is connected")
    }

    func testPictureSessionsAreUnchanged() {
        let steering = HostPopoverPresentation.make(for: state(.controlling, couch: false))
        XCTAssertEqual(steering.headline, "Connected · sharing this Mac")
        XCTAssertEqual(steering.title, "Your iPhone is steering")
        let watching = HostPopoverPresentation.make(for: state(.viewing, couch: false))
        XCTAssertEqual(watching.headline, "Connected · view only")
        XCTAssertEqual(watching.title, "Your iPhone is watching")
    }

    func testTheMenuBarTipIsEmberWhileAnyPhoneIsConnected() {
        XCTAssertEqual(HostMarkState(status: .controlling), .live)
        XCTAssertEqual(HostMarkState(status: .viewing), .live)
        XCTAssertEqual(CouchCopy.hud, "iPhone is steering this Mac · Couch mode, no picture shared")
    }
}
```
- [ ] **Step 2: Run** `-XCTest CouchPresentationTests` → FAIL (no `couchMode`).
- [ ] **Step 3: Implement.**
  - `HostViewState`: after `curtainStatus`, `/// A Couch-mode session: the phone steers with no picture.` `var couchMode = false`.
  - `HostPopoverPresentation.make`, `.controlling, .viewing` case: when `state.couchMode`, headline `viewOnly ? "Couch mode · control is off" : "Couch mode · no picture shared"`, title `viewOnly ? "Your iPhone is connected" : "Your iPhone is steering"`; everything else identical to the Picture branch.
  - `CouchHUD`: an `NSPanel` (`styleMask: [.borderless, .nonactivatingPanel]`, `level = .statusBar`, `ignoresMouseEvents = true`, `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `backgroundColor = .clear`, `isOpaque = false`), content an `NSHostingView` with `CouchCopy.hud` in the host's existing style tokens (`HostStyle.swift`: dark plate, bone text, ember dot), centred horizontally ~15 % below the top of `NSScreen.main`. `show()` cancels any pending hide, orders the panel front **without** activating the app (`orderFrontRegardless()`), posts `NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: CouchCopy.hud, .priority: NSAccessibilityPriorityLevel.high.rawValue])`, and hides after `CouchHUD.duration` via a cancellable `Task`. `hide()` cancels and orders out. Never read screen contents.
- [ ] **Step 4: Run** `-XCTest CouchPresentationTests` and `-XCTest HostPresentationTests` → PASS; host app build (`CODE_SIGNING_ALLOWED=NO`) succeeds; build `-scheme HostUISnapshotTests build-for-testing` succeeds (proves the snapshot target still compiles).
- [ ] **Step 5: Commit** `Tell the Mac's owner when a phone steers it in Couch mode`.

---

### Task 7: Host wiring (Wave 2; consumes Tasks 1, 2, 4, 5, 6)

**Files:**
- Modify: `RemoteHost/HostModel.swift`
- Test: none new (the host model is not in `RemoteCoreTests`); verification is the full core suite, the host build and the review checklist below.

**Interfaces:**
- Consumes: `connection.peerRequestedMode`, `connection.routeIsLocal`, `connection.provenLocalLinkActive` (Task 2); `SessionMode`, `SessionModeRefusal`, `RemoteAction.mode/.modeReason` (Tasks 0–1); `HostSessionState`, `CouchAdmission`, `CouchHealth`, `HostControlPolicy.isEnabled(…session:…)`, `RemoteInputLease.couchDuration/pictureDuration`, `HostCouchDisplays.current()` (Task 4); `RemoteInputDriver.configure(displays:)` (Task 5); `CouchHUD`, `HostViewState.couchMode` (Task 6).
- Produces: host behaviour only.

- [ ] **Step 1: State.** Add to `RemoteHostModel`:
  ```swift
  private var sessionState: HostSessionState = .picture
  private var couchHealthy = false
  private var lastPhoneHeartbeatAt: TimeInterval?
  private var pendingModeReason: SessionModeRefusal?
  private let couchHUD = CouchHUD()
  private var refusalTeardown: Task<Void, Never>?
  private var sessionHealthy: Bool { sessionState == .couch ? couchHealthy : captureHealthy }
  ```
  Change `private var inputLease = RemoteInputLease()` to stay as is; `beginCapture()` sets `inputLease = RemoteInputLease(duration: RemoteInputLease.pictureDuration)` and `beginCouch()` sets `RemoteInputLease(duration: RemoteInputLease.couchDuration)` (both after releasing input).
- [ ] **Step 2: Health.** Add
  ```swift
  private var couchHealthInputs: CouchHealthInputs {
      let now = ProcessInfo.processInfo.systemUptime
      return CouchHealthInputs(
          routeLocal: connection.routeIsLocal, provenLinkActive: connection.provenLocalLinkActive,
          heartbeatAge: lastPhoneHeartbeatAt.map { now - $0 },
          screenLocked: screenLocked || HostScreenLock.isLocked(), consoleUserActive: Self.consoleUserActive(),
          allowControl: allowControl, accessibility: accessibilityPermission, phonePaused: phonePause.isPaused)
  }

  /// Returns the fresh value; on a healthy → unhealthy edge input stops and tokens expire at once.
  @discardableResult
  private func refreshCouchHealth() -> Bool {
      guard sessionState == .couch else { couchHealthy = false; return false }
      let healthy = CouchHealth.isHealthy(couchHealthInputs)
      if couchHealthy && !healthy {
          invalidateTextFocus()
          releaseRemoteInput(notifyPhone: true)
          inputFreshness.expireTokens()
      }
      couchHealthy = healthy
      input.enabled = HostControlPolicy.isEnabled(userConsent: allowControl, accessibilityPermission: accessibilityPermission,
                                                  session: sessionState, captureHealthy: captureHealthy, couchHealthy: healthy)
      return healthy
  }

  private static func consoleUserActive() -> Bool {
      guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
      return session[kCGSessionOnConsoleKey as String] as? Bool ?? false
  }
  ```
- [ ] **Step 3: Every host gate uses the session-aware overload.** Replace each `HostControlPolicy.isEnabled(userConsent:accessibilityPermission:captureHealthy:)` call (in `applyControlState`, `receive(_:)`, `captureHealthChanged`) with the `session:` overload passing `sessionState`, `captureHealthy`, and `couchHealthy` — in `receive(_:)` call `refreshCouchHealth()` first when `sessionState == .couch` so admission uses the value **at this moment**. Replace every `sendCaptureHealth(captureHealthy)` / `sendCaptureHealth(self.captureHealthy)` with `sendCaptureHealth(sessionHealthy)`. `status.controlEffective`, `snapshot.controlEffective` and `textFocusIsCurrent(captureHealthy:)` use `sessionHealthy`. `captureHealthChanged(_:)` starts with `guard sessionState == .picture else { return }` (a stopping stream's late callback must not touch a Couch session).
- [ ] **Step 4: Status.** In `sendCaptureHealth`: `let capability = sessionState.issuesTokens(healthy: healthy) ? inputFreshness.capability(…) : nil` (Picture unchanged); add `mode: sessionState.wireMode, modeReason: pendingModeReason?.rawValue ?? sessionState.wireReason` to the `RemoteAction`; after a successful send clear `pendingModeReason`. `advertisedFeatures` appends `SessionFeature.couch`.
- [ ] **Step 5: Connect.** `phoneConnected()`:
  ```swift
  switch connection.peerRequestedMode {
  case .picture: beginCapture()
  case .couch:
      if let refusal = CouchAdmission.decide(couchAdmissionInputs) { beginRefused(refusal) } else { beginCouch() }
  }
  ```
  with `couchAdmissionInputs` built from `connection.routeIsLocal`, `connection.provenLocalLinkActive`, `allowControl`, `accessibilityPermission`. The chime stays as it is (applies to Couch too).
- [ ] **Step 6: `beginCouch()`** (mirror `beginCapture()`'s bookkeeping; **no** `CGPreflightScreenCaptureAccess`, `SCContentFilter`, `capture.start`, `beginLoadMonitor`, curtain raise, viewport or cursor hiding):
  ```swift
  private func beginCouch() {
      guard connection.connected, connection.media != nil else { stop(); return }
      if HostScreenLock.isLocked() { handleAvailability(.screenLocked); return }
      if sessionStartedAt == nil { sessionStartedAt = Date(); sessionsThisLaunch += 1; events.record(.session, "Phone connected in Couch mode") }
      refusalTeardown?.cancel(); refusalTeardown = nil
      liftCurtain()
      wakeDisplayForRemoteSession()
      updatePowerAssertions()
      captureAttempt &+= 1
      captureTask?.cancel(); captureTask = nil
      endLoadMonitor()
      _ = capture.stop()
      phonePause.clear()
      capturedDisplayID = nil
      pointerLocator.reset()
      releaseRemoteInput(notifyPhone: true)
      let rects = HostCouchDisplays.current()
      guard let main = rects.first else { stop(); return }
      input.configure(displays: rects)
      inputLease = RemoteInputLease(duration: RemoteInputLease.couchDuration)
      captureHealthy = false
      couchHealthy = false
      input.enabled = false
      sessionState = .couch
      advanceEpoch()
      pointerTelemetry.begin(displayFrame: main, epoch: inputEpoch.value)
      startLifecycleTimer()
      _ = connection.sendControl(RemoteAction(action: "geometry", x: main.width, y: main.height, epoch: inputEpoch.value))
      _ = connection.sendControl(RemoteAction(action: "viewing", x: allowControl && accessibilityPermission.isGranted ? 1 : 0, epoch: inputEpoch.value))
      refreshCouchHealth()
      sendCaptureHealth(couchHealthy)
      couchHUD.show()
      #if DEBUG
      HostE2E.active?.event("couch.begin", ["displays": rects.count])
      #endif
  }
  ```
  Extract the existing 0.25 s timer body from `beginCapture()` into `startLifecycleTimer()` (same body), with one change: `self.sendCaptureHealth(self.captureHealthy)` becomes `if self.sessionState == .couch { self.refreshCouchHealth() }; self.sendCaptureHealth(self.sessionHealthy)`. `beginCapture()` calls `startLifecycleTimer()`; it also sets `sessionState = .picture`, `couchHealthy = false`, `inputLease = RemoteInputLease(duration: RemoteInputLease.pictureDuration)` right after `releaseRemoteInput(notifyPhone: true)`, and calls `couchHUD.hide()`.
- [ ] **Step 7: `beginRefused(_:)`:** set `sessionState = .refused(reason)`, `advanceEpoch()`, `input.enabled = false`, send `capture` via `sendCaptureHealth(false)` (no token by `issuesTokens`), record the event, and `refusalTeardown = Task { try? await Task.sleep(for: .seconds(2)); guard !Task.isCancelled, case .refused = sessionState else { return }; connection.dropPeerSession() }`.
- [ ] **Step 8: Heartbeats and inputs.** In `receive(_:)`'s heartbeat branch, first line: `lastPhoneHeartbeatAt = ProcessInfo.processInfo.systemUptime`. Guard the capture setters (`setQuality`, `setClientPixels`, `setViewport`, `phoneLoad`) with `sessionState == .picture`. Before the session-extension branch add `if action.action == RemoteAction.modeAction { receiveModeRequest(action); return }`. In Couch, refuse `moveTo` (`if sessionState == .couch, action.action == "moveTo" { countInput("rejected-couch-moveTo"); return }`) and any input while `sessionState` is `.refused`.
- [ ] **Step 9: Switching.**
  ```swift
  private func receiveModeRequest(_ action: RemoteAction) {
      guard connection.connected, active, action.epoch == inputEpoch.value, !phonePause.isPaused,
            let requested = action.mode.flatMap(SessionMode.init(rawValue:)) else { return }
      switch (sessionState, requested) {
      case (.couch, .picture):
          guard CGPreflightScreenCaptureAccess() else { pendingModeReason = .screenRecording; sendCaptureHealth(sessionHealthy); return }
          events.record(.session, "Phone switched to the picture")
          beginCapture()
      case (.picture, .couch):
          if let refusal = CouchAdmission.decide(couchAdmissionInputs) {
              pendingModeReason = refusal
              sendCaptureHealth(sessionHealthy)
              return
          }
          events.record(.session, "Phone switched to Couch mode")
          beginCouch()
      default:
          sendCaptureHealth(sessionHealthy)
      }
  }
  ```
  `beginCouch()` already stops capture, load monitor and curtain (Picture → Couch quiesce). `resumeAfterPhoneBackground()` calls `sessionState == .couch ? beginCouch() : beginCapture()`. `receiveDisplaySelection` `"display"` case: when `sessionState != .picture`, only `sendDisplayList()`. `receiveSessionExtension` `"curtain"`: when `sessionState != .picture`, `sendCaptureHealth(sessionHealthy)` and return.
- [ ] **Step 10: Teardown and displays.** (Big Text is not on this base. When the branches meet, Big Text must skip Couch sessions; leave a one-line note in the commit body.) `endCapture()`: `couchHUD.hide()`, `sessionState = .picture`, `couchHealthy = false`, `lastPhoneHeartbeatAt = nil`, `pendingModeReason = nil`, `refusalTeardown?.cancel()`. `pauseForPhoneBackground()` also sets `couchHealthy = false`. `pointerTelemetry.setCaptureShowsCursor` closure: only forwards when `sessionState == .picture`. The `didChangeScreenParametersNotification` handler: when `sessionState == .couch && connection.connected`, do **not** `stop()`; instead `releaseRemoteInput(notifyPhone: true)` then `input.configure(displays: HostCouchDisplays.current())` (stop the session if that is empty) and return; Picture keeps today's behaviour.
- [ ] **Step 11: View state and diagnostics.** `viewState` passes `couchMode: sessionState == .couch && connection.connected`. `e2eSnapshot()` adds `"sessionMode": sessionState.wireMode`, `"couchHealthy": couchHealthy`.
- [ ] **Step 12: Verify.** Host build (`CODE_SIGNING_ALLOWED=NO`) → succeeds with no new warnings in `HostModel.swift`. Full core suite → no new failures. Then self-check with `grep -n "isEnabled(userConsent" RemoteHost/HostModel.swift` (every hit uses `session:`), `grep -n "sendCaptureHealth(captureHealthy\|sendCaptureHealth(self.captureHealthy" RemoteHost/HostModel.swift` (no hits), and read `beginCouch()` top to bottom confirming no call reaches `capture.start`, `beginLoadMonitor`, `raiseCurtain`, `setViewport` or cursor hiding.
- [ ] **Step 13: Commit** `Run Couch sessions on the Mac without capturing the screen`.

---

### Task 8: Phone model wiring (Wave 2; consumes Tasks 1, 2, 3)

**Files:**
- Modify: `RemotePhone/RemotePhoneApp.swift` (`PhoneRemoteModel`)
- Test: `RemotePhoneTests/CouchPhoneModelTests.swift`

**Interfaces:**
- Consumes: `connection.sessionModeRequest`, `connection.provenLocalLinkActive` (Task 2); `PhoneControlGate`, `CouchAckWatchdog`, `PhoneModeResolver`, `PhoneModeOutcome`, `CouchTuning` (Task 3); `SessionFeature.couch`, `CouchCopy` (Task 0/1).
- Produces on `PhoneRemoteModel`:
  - `@Published private(set) var sessionMode: SessionMode = .picture`
  - `@Published private(set) var requestedMode: SessionMode = .picture`
  - `@Published private(set) var pendingModeSwitch: SessionMode?`
  - `@Published private(set) var couchRefusal: SessionModeRefusal?`
  - `@Published private(set) var couchStalled = false`
  - `var couchSwitchAvailable: Bool` (`connection.connected && hostFeatures.contains(SessionFeature.couch) && connection.provenLocalLinkActive && sessionMode == .picture`)
  - `func prepareConnection(mode: SessionMode)` (sets `requestedMode`, `connection.sessionModeRequest`, clears `couchRefusal`)
  - `@discardableResult func requestMode(_ mode: SessionMode) -> Bool`
  - `func clearCouchRefusal()`

- [ ] **Step 1: Write the failing tests:**
```swift
import XCTest
@testable import PocketDeskRemote

@MainActor
final class CouchPhoneModelTests: XCTestCase {
    private let couchFeatures = SessionFeature.host + [SessionFeature.couch]

    private func deliver(_ action: RemoteAction, to model: PhoneRemoteModel) throws {
        model.connection.onControl?(try JSONEncoder().encode(action))
    }

    private func connected(mode: SessionMode) -> PhoneRemoteModel {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.prepareConnection(mode: mode)
        model.connection.connected = true
        return model
    }

    private func status(_ healthy: Bool, epoch: UInt64 = 2, mode: String?, reason: String? = nil,
                        features: [String]) -> RemoteAction {
        RemoteAction(action: "capture", x: healthy ? 1 : 0, epoch: epoch,
                     interaction: healthy ? NativeInteraction(token: "t", doubleClickInterval: 0.5) : nil,
                     features: features, mode: mode, modeReason: reason)
    }

    private func liveCouch() throws -> PhoneRemoteModel {
        let model = connected(mode: .couch)
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 2), to: model)
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 2), to: model)
        try deliver(status(true, mode: "couch", features: couchFeatures), to: model)
        return model
    }

    func testCouchControlsWithoutAPicture() throws {
        let model = try liveCouch()
        XCTAssertEqual(model.sessionMode, .couch)
        XCTAssertFalse(model.fresh)
        XCTAssertTrue(model.canControl)
        XCTAssertEqual(model.connection.sessionModeRequest, .couch)
    }

    func testThePictureSessionStillNeedsAFreshFrame() throws {
        let model = connected(mode: .picture)
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 2), to: model)
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 2), to: model)
        try deliver(status(true, mode: "picture", features: couchFeatures), to: model)
        XCTAssertEqual(model.sessionMode, .picture)
        XCTAssertFalse(model.canControl, "no frame yet")
        model.frameReceived()
        XCTAssertTrue(model.canControl)
    }

    func testAnOlderMacKeepsThePictureAndSaysSo() throws {
        let model = connected(mode: .couch)
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 2), to: model)
        try deliver(status(true, mode: nil, features: SessionFeature.host), to: model)
        XCTAssertEqual(model.sessionMode, .picture)
        XCTAssertEqual(model.sessionNotice, CouchCopy.updateMac)
        XCTAssertEqual(model.connection.sessionModeRequest, .picture, "a reconnect asks for what is on screen")
        XCTAssertFalse(model.canControl, "still needs a picture frame")
    }

    func testARefusalEndsTheAttemptAndSaysWhy() throws {
        let model = connected(mode: .couch)
        try deliver(status(false, mode: SessionModeStatus.refused, reason: "controlOff", features: couchFeatures), to: model)
        XCTAssertEqual(model.couchRefusal, .controlOff)
        XCTAssertFalse(model.canControl)
        XCTAssertFalse(model.connection.isRunning)
        model.clearCouchRefusal()
        XCTAssertNil(model.couchRefusal)
    }

    func testAnUnhealthyCouchStatusStopsControl() throws {
        let model = try liveCouch()
        try deliver(status(false, mode: "couch", features: couchFeatures), to: model)
        XCTAssertFalse(model.canControl)
    }

    func testAStaleCouchStatusStopsControl() throws {
        let model = try liveCouch()
        model.ageCouchStatusForTesting(by: 1.01)
        XCTAssertFalse(model.canControl, "no Mac status for over 1 s in Couch mode")
    }

    func testAPictureStatusInsideACouchSessionSwitchesBack() throws {
        let model = try liveCouch()
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 3), to: model)
        try deliver(status(true, epoch: 3, mode: "picture", features: couchFeatures), to: model)
        XCTAssertEqual(model.sessionMode, .picture)
        XCTAssertFalse(model.canControl, "the picture path needs its first frame again")
        XCTAssertEqual(model.connection.sessionModeRequest, .picture)
    }

    func testAModeReasonIsShownOnceAsANotice() throws {
        let model = try liveCouch()
        try deliver(status(true, mode: "couch", reason: "screenRecording", features: couchFeatures), to: model)
        XCTAssertEqual(model.sessionMode, .couch, "Couch continues when the picture is refused")
        XCTAssertEqual(model.sessionNotice, CouchCopy.needsScreenRecording)
    }

    func testModeRequestsNeedACouchCapableConnectedMac() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        XCTAssertFalse(model.requestMode(.couch))
        XCTAssertNil(model.pendingModeSwitch)
        XCTAssertFalse(model.couchSwitchAvailable)
    }
}
```
- [ ] **Step 2: Run** the phone test command with `-only-testing:RemotePhoneTests/CouchPhoneModelTests` → FAIL to compile.
- [ ] **Step 3: Implement.**
  - State: the published properties above plus `private var couchAck = CouchAckWatchdog()`, `private var lastModeReason: String?`.
  - `canControl` (keep the DEBUG `inputProbe` early return):
    ```swift
    let now = ProcessInfo.processInfo.systemUptime
    return PhoneControlGate.canControl(.init(
        mode: sessionMode, privacyShield: privacyShield, contentConcealed: contentConcealed,
        connected: connection.connected, controlAllowed: controlAllowed, fresh: fresh, captureHealthy: captureHealthy,
        hostModeIsCouch: sessionMode == .couch, statusAge: lastCaptureHealth > 0 ? now - lastCaptureHealth : .infinity,
        geometryEpoch: geometryEpoch, nativeInteractionSupported: nativeInteractionSupported,
        hasToken: inputToken != nil, tokenAge: now - tokenReceivedAt))
    ```
    (`hostModeIsCouch` is true only after the Mac's status said `couch`, because `sessionMode` is set only from the resolver.)
  - In `receive(_:)`, `"capture"` case, after the existing token/health handling:
    ```swift
    switch PhoneModeResolver.resolve(requested: requestedMode, features: hostFeatures, statusMode: action.mode, reason: action.modeReason) {
    case .couch: setSessionMode(.couch)
    case .picture: setSessionMode(.picture)
    case .couchUnsupported:
        if requestedMode == .couch { requestedMode = .picture; showSessionNotice(CouchCopy.updateMac) }
        setSessionMode(.picture)
    case .refused(let reason):
        couchRefusal = reason
        sessionEndReason = .error
        release()
        connection.stop()
        return
    }
    if let reason = action.modeReason.flatMap(SessionModeRefusal.init(rawValue:)), action.mode != SessionModeStatus.refused {
        pendingModeSwitch = nil
        showSessionNotice(CouchCopy.refusal(reason))
    }
    ```
    `setSessionMode(_ mode:)`: if it changes, `couchAck.reset()`, `couchStalled = false`, `cancelInput()`; always `sessionMode = mode`, `connection.sessionModeRequest = mode`, and `pendingModeSwitch = nil` when it equals `pendingModeSwitch`.
  - `"pointer"` case: also `if let applied = action.pointerSync?.applied { couchAck.acknowledged(through: applied) }`.
  - `"geometry"` case: `couchAck.reset()`, `couchStalled = false`.
  - `gesture(.move)`: when `sessionMode == .couch`, `accepted`, and `ordinal != nil`, call `couchAck.sent(ordinal:at:)`.
  - `sendInput`: when `sessionMode == .couch && couchAck.stalled(at: now)` and `name` is one of `click, double, right, middle, dragDown`, return false (moves still go, so the Mac can catch up).
  - `tick()`: in Couch, `if captureHealthy && now - lastCaptureHealth > PhoneControlGate.couchStatusLimit { captureHealthy = false; pointerLocator.clear(); release() }`; `let stalled = couchAck.stalled(at: now)`; on a false → true edge `cancelInput()` and `showSessionNotice(CouchCopy.notAnswering)`; `couchStalled = stalled`. Picture keeps its 2 s checks unchanged.
  - `prepareConnection(mode:)`, `clearCouchRefusal()`, `couchSwitchAvailable` as in Interfaces.
  - `requestMode(_ mode: SessionMode) -> Bool`: guard `connection.connected`, `hostFeatures.contains(SessionFeature.couch)`, `mode != sessionMode`, `pendingModeSwitch == nil`, and for `.couch` `couchSwitchAvailable`; `cancelInput()`; send `RemoteAction(action: RemoteAction.modeAction, epoch: geometryEpoch, mode: mode.rawValue)` with `connection.sendControl`; on success set `pendingModeSwitch = mode`, show `CouchCopy.showingPicture` when `mode == .picture`, and clear `pendingModeSwitch` after 5 s if still pending (cancellable `Task`, cancelled in `end()`).
  - `end()`: reset `sessionMode = .picture`, `pendingModeSwitch = nil`, `couchStalled = false`, `couchAck.reset()`; **keep** `couchRefusal` and `requestedMode` (Home reads them).
  - `#if DEBUG` test hook: `func ageCouchStatusForTesting(by seconds: TimeInterval) { lastCaptureHealth -= seconds; tokenReceivedAt -= min(seconds, 0.5) }` (token stays valid so the test isolates the status age).
- [ ] **Step 4: Run** `CouchPhoneModelTests` → PASS; then `-only-testing:RemotePhoneTests/SessionLifecycleTests`, `MacParityPhoneTests`, `PhoneParityTests`, `PointerOverlayTests`, `PhoneClipboardTests` → no new failures. Shut down the simulator.
- [ ] **Step 5: Commit** `Let the phone control the Mac in Couch mode without a picture`.

---

### Task 9: Phone UI (Wave 3; consumes Task 8)

**Files:**
- Modify: `RemotePhone/NativeSessionView.swift`, `RemotePhone/HomeView.swift`, `RemotePhone/FriendlyErrors.swift`
- Test: `RemotePhoneUITests/CouchModeUITests.swift`, `RemotePhoneTests/CouchPhoneModelTests.swift` (add the FriendlyError test)

**Interfaces:**
- Consumes: everything Task 8 produces; `CouchCopy`, `CouchTuning.speed`.
- Accessibility identifiers (exact): `home.couch`, `remote.couch.rest`, `remote.couch.keys`, `remote.couch.mic`, `remote.couch.clip`, `remote.couch.picture`, `remote.couch.controls`, `remote.mode.couch`.

- [ ] **Step 1: Write the failing tests.** Append to `CouchPhoneModelTests`:
```swift
    func testCouchFailuresOfferThePictureInstead() {
        let proof = FriendlyError.forCouch(status: "The devices could not verify a directly attached local link.", requestedCouch: true)
        XCTAssertEqual(proof?.kind, .couchNotLocal)
        XCTAssertEqual(proof?.action, .connectWithPicture)
        XCTAssertEqual(proof?.message, CouchCopy.notLocal)
        XCTAssertEqual(FriendlyError.forCouch(status: CouchCopy.phoneRefusedStatus, requestedCouch: true)?.kind, .couchNotLocal)
        XCTAssertNil(FriendlyError.forCouch(status: CouchCopy.phoneRefusedStatus, requestedCouch: false))
        XCTAssertEqual(FriendlyError.couch(.controlOff).message, CouchCopy.controlOff)
        XCTAssertEqual(FriendlyError.Action.connectWithPicture.title, "Connect with picture")
        XCTAssertEqual(MacStatus("Connecting live desktop…", couch: true).text, CouchCopy.checking)
        XCTAssertEqual(MacStatus("Connecting live desktop…").text, FriendlyError.cardStatus("Connecting live desktop…"))
    }
```
  `RemotePhoneUITests/CouchModeUITests.swift`:
```swift
import XCTest

final class CouchModeUITests: XCTestCase {
    @MainActor
    func testCouchSurfaceShowsTheTrackpadCardAndKeyRow() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-couch", "--ui-demo-mac"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Look at your Mac. This is its trackpad."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["The picture is the one on your wall."].exists)
        for id in ["remote.couch.keys", "remote.couch.mic", "remote.couch.clip", "remote.couch.picture", "remote.couch.controls"] {
            XCTAssertTrue(app.buttons[id].exists, id)
        }
        XCTAssertFalse(app.buttons["Fit whole display"].exists, "Couch has no picture to fit")
        XCTAssertTrue(app.buttons["End session"].exists)
        app.buttons["remote.couch.controls"].tap()
        XCTAssertTrue(app.buttons["Double-click"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["remote.displayRow"].exists)
        XCTAssertFalse(app.switches["remote.macCurtain"].exists)
    }

    @MainActor
    func testHomeOffersCouchModeUnderConnect() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-demo-mac"]
        app.launch()
        let couch = app.buttons["home.couch"]
        XCTAssertTrue(couch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Trackpad and keys. No picture."].exists)
    }
}
```
- [ ] **Step 2: Run** the new unit test and `-only-testing:RemotePhoneUITests/CouchModeUITests` → FAIL.
- [ ] **Step 3: Implement.**
  - **FriendlyErrors.swift:** `Kind` gains `couchNotLocal, couchControlOff`; `Action` gains `connectWithPicture` (title "Connect with picture"); update `scene` (`FarsideArt.unreachable` for couchNotLocal, `FarsideArt.locked` for couchControlOff) and `shortStatus` ("Not on your Mac’s network", "Control is off on the Mac"). Add
    ```swift
    static func couch(_ reason: SessionModeRefusal) -> FriendlyError {
        switch reason {
        case .controlOff:
            FriendlyError(kind: .couchControlOff, headline: "Control is off", accent: "off", message: CouchCopy.controlOff,
                          fix: "Or connect with the picture to watch.", action: .connectWithPicture, secondary: .retry)
        case .notLocal, .screenRecording:
            FriendlyError(kind: .couchNotLocal, headline: "Not on the same network", accent: "same",
                          message: CouchCopy.notLocal, fix: "Or connect with the picture instead.",
                          action: .connectWithPicture, secondary: .retry)
        }
    }

    static let couchProofFailures: Set<String> = [
        "No directly attached Wi-Fi or Ethernet link is available.",
        "The devices could not verify a directly attached local link.",
        "The local network changed. Reconnect to verify the route again.",
        "Local link proof could not start.",
        CouchCopy.phoneRefusedStatus
    ]

    static func forCouch(status: String, requestedCouch: Bool) -> FriendlyError? {
        requestedCouch && couchProofFailures.contains(status) ? couch(.notLocal) : nil
    }
    ```
    (Match the existing `FriendlyError(...)` memberwise argument order; add missing labels as the struct requires.)
  - **HomeView.swift:** `MacStatus.init(_ raw: String, couch: Bool = false)`: when `couch && raw.hasPrefix("Connecting live desktop")` → text `CouchCopy.checking` (same tone/progress as today); every existing caller unchanged. `connect()` becomes `connect(mode: SessionMode = .picture)`: `model.prepareConnection(mode:)`, skip `AnywhereAccess.shared.prepareForConnection()` for `.couch` (no token is sent), keep the `phoneConnectionAllowed` guard. Under the Connect pill in `connectControl` (only when not busy): a secondary button (`FarsideSecondaryButtonStyle(height: 52)`) titled `CouchCopy.entryTitle`, with caption `CouchCopy.entryCaption` beneath it (`.farsideCaption()`), `accessibilityIdentifier("home.couch")`, action `connect(mode: .couch)`. The card status uses `MacStatus(connection.status, couch: model.requestedMode == .couch)`. In `statusChanged`, before the generic mapping: `if let couch = FriendlyError.forCouch(status: new, requestedCouch: model.requestedMode == .couch) { lastFailure = couch; friendlyError = couch; return }`. Observe `model.couchRefusal`: when non-nil, show `FriendlyError.couch(reason)` and call `model.clearCouchRefusal()`. `resolve(_:action:)` handles `.connectWithPicture` → `connect(mode: .picture)` after 0.3 s; `.retry` repeats the last requested mode.
  - **NativeSessionView.swift** (Couch presentation inside the existing session view; no new file):
    - `private var couch: Bool { model.sessionMode == .couch || (offlineLayoutCheck && LaunchOptions.has("--ui-couch")) }`.
    - `stage`: when `couch`, replace `videoLayer` and the resolution lock with a rest card: `RoundedRectangle(cornerRadius: 20, style: .continuous)` stroked with `Farside.Palette.line`, filling the stage inset by 12 pt, containing `CouchCopy.restHeadline` (bone, `.title3`) and `CouchCopy.restDeadpan` (ash, footnote), `accessibilityIdentifier("remote.couch.rest")`; the text fades out (`opacity`, 0.25 s, respect Reduce Motion) after the first `model.inputRevision`/`acceptedClicks` change; an ember `ContactRipple` (existing `PointerAccents.swift`) at the card centre on each `model.acceptedClicks` change.
    - `inputSurface` when `couch`: `direct: false`, `panMode: false`, `pointerScale: 1`, `sensitivity: CGFloat(sensitivity * CouchTuning.speed)`, `hardwarePointer: false` (relative motion only), everything else as today. Never show the pointer overlay, mini-map, zoom badge or resolution lock in Couch.
    - Top line in Couch: `LiveDot(state: liveState)` + `"\(macName) · Couch · \(rtt) ms"` (omit the rtt part until `model.link?.roundTripMs` exists) in `.farsideCaption`, SF Mono as the existing caption style; `liveState`/`status`/`handleLive` treat Couch as live when `model.canControl` (not `fresh`).
    - Dock in Couch: always expanded (`collapseControls()` returns early in Couch; set `controlsCollapsed = false` when entering Couch), no `grabHandle`, no `segmentsRow`; `tilesRow` in Couch is **Keys · Mic · Clip · Picture · Controls** (Picture: `Label("Picture", systemImage: "photo")`, action `model.requestMode(.picture)`, disabled while `model.pendingModeSwitch != nil`; Controls: `openControls()`), identifiers as listed. `dockFooter` in Couch omits the Controls round button (it is in the row) and keeps End. On `compactHeight || horizontalSizeClass == .regular`, the Couch tiles render as a `VStack` overlay on the trailing edge instead of the bottom.
    - Controls panel in Couch: `showsCurtainRow` and `showsDisplayRow` are false; everything else (keys, Settings) unchanged.
    - Picture sessions: the **Mode** tile becomes `Menu { Button("Couch mode", systemImage: "sofa") { model.requestMode(.couch) }.accessibilityIdentifier("remote.mode.couch") } label: { Label("Mode", …) } primaryAction: { setInteractionMode(!panMode) }` only when `model.couchSwitchAvailable`; otherwise exactly today's button.
    - A pending switch to Picture shows `CouchCopy.showingPicture` through the existing `sessionNotice` path (Task 8 already posts it).
  - `PhoneRemoteView` needs no change (Couch stays inside `NativeSessionView`, which `showsSession` already presents while connected).
- [ ] **Step 4: Run** `CouchPhoneModelTests`, `-only-testing:RemotePhoneUITests/CouchModeUITests`, `-only-testing:RemotePhoneUITests/SessionLayoutTests`, `-only-testing:RemotePhoneUITests/FarsideRedesignUITests`, `-only-testing:RemotePhoneTests/FarsideDesignTests` → PASS / no new failures. Take one simulator screenshot of `--ui-layout-check --ui-couch --ui-demo-mac` (portrait) to `~/Downloads/couch-mode-surface-2026-09-30.png` for the report. Shut down the simulator.
- [ ] **Step 5: Commit** `Add Couch mode to Home and the session view`.

---

### Task 10: Integration, reviews and ledger (orchestrator)

- [ ] **Step 1:** Merge waves into `farside-couch-mode` in order (0 → Wave 1 → Wave 2 → Wave 3). Run `xcodegen generate`; the project file must have no diff.
- [ ] **Step 2: Full verification**, one build at a time under the lock: `RemoteCoreTests` (all), `PocketDeskRemoteHost` build (`CODE_SIGNING_ALLOWED=NO`), `HostUISnapshotTests` build-for-testing, `RemotePhoneTests` (all), `RemotePhoneUITests` targeted (`CouchModeUITests`, `SessionLayoutTests`, `FarsideRedesignUITests`), backend `bun run test` + `bun run typecheck`. Record exact counts against the Task 0 baseline. Shut down the simulator; delete per-task DerivedData.
- [ ] **Step 2b: E2E.** The spec's HostE2E scenario (legacy route with an injected proven link) needs an installed Debug host from `script/build_and_run.sh`, which this branch may not run. Record it as a follow-up for the integrated checkout; do not add a DEBUG link-injection path here.
- [ ] **Step 3: Whole-branch review** (fresh Opus agent, read-only) against the spec and this plan's Review Focus, plus an **input-safety adversarial pass**: try to find any path where (a) a Picture session admits input it would not have admitted at `a65e864`, (b) a Couch session admits input without a proven local link, fresh heartbeat, consent and Accessibility, (c) a token is issued in Couch while unhealthy, (d) a held button survives > 1 s of silence in Couch, (e) capture/curtain/Big Text can start from a Couch path, (f) an old-epoch action lands after a mode switch. Fix confirmed findings with bounded follow-up tasks (fresh implementer + reviewer).
- [ ] **Step 4:** Ledger section in `Docs/IMPLEMENTATION-PLAN.md` (`### Couch mode — 30 September 2026`: packages, write-sets, SHAs, counts, review findings, "compiled / unit-tested / physically verified (none)"). PRODUCT.md: next free decision row after checking every branch (`D38` = Big Text) — "Couch mode (C1–C4 as approved 30 Sep); implemented on `farside-couch-mode`; physical acceptance pending". Commit and push `farside-couch-mode`. Do **not** merge into `pocketdesk-remote-chat`, install, deploy or submit.

### Task 11: Physical gates (Roshan + orchestrator, quiet window only)

Not executable by subagents. Needs the integrated main checkout, `script/build_and_run.sh`, the iPhone 17 and the M4 Air with nothing else running. If the phone's room uses the staging developer relay pass, Task B must be deployed to staging first (human-approved).
- [ ] Tap-to-click latency, Couch vs Picture, with the 240 fps method in `POINTER-REPORT.md`.
- [ ] 30 min battery: phone % and host CPU, Couch vs Picture.
- [ ] Cellular, VPN and a paid phone off-LAN are refused with the network copy and "Connect with picture" works.
- [ ] The Mac HUD shows for 3 s without taking focus; the popover line and ember tip show; Stop Sharing and lock end the session.
- [ ] A drag held while Wi-Fi drops is released on the Mac within 1 s; the phone shows "Your Mac isn’t answering. Input paused."
- [ ] Pointer crosses onto an extended TV and stops at its edges; plugging a display in/out keeps the Couch session.
- [ ] Picture ↔ Couch switches both ways in one session; no click lands on the wrong display.
- [ ] Pointer speed ×1.4 feels right (tune `CouchTuning.speed`).
