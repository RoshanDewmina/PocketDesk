import XCTest
import ApplicationServices

final class HostAXWebAccessTests: XCTestCase {
    // MARK: Editability classifier

    func testWebTextRolesSeenInChromiumAndElectronAreEditable() {
        // Claude, Cursor and Codex composers and Chrome inputs: text role, settable value, no AXIsEditable.
        for role in [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"] as [String] {
            XCTAssertTrue(HostTextFocusPolicy.isEditable(role: role, enabled: true, editable: nil,
                                                         valueSettable: true, selectionSettable: true,
                                                         editableRoot: true), role)
        }
        XCTAssertTrue(HostTextFocusPolicy.isEditable(role: kAXTextFieldRole, subrole: kAXSearchFieldSubrole,
                                                     enabled: true, editable: nil, valueSettable: true))
    }

    func testSelectableReadOnlyTextIsNotEditable() {
        XCTAssertFalse(HostTextFocusPolicy.isEditable(role: kAXTextAreaRole, enabled: true, editable: nil,
                                                      valueSettable: false, selectionSettable: true))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(role: kAXTextAreaRole, enabled: true, editable: false,
                                                      valueSettable: true))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(role: kAXTextFieldRole, enabled: false, editable: nil,
                                                      valueSettable: true))
    }

    func testContentEditableContainerNeedsEditableRootAndSettableSelectionOrValue() {
        for role in [kAXGroupRole, "AXWebArea"] as [String] {
            XCTAssertTrue(HostTextFocusPolicy.isEditable(role: role, enabled: true, editable: nil, valueSettable: nil,
                                                         selectionSettable: true, editableRoot: true), role)
            XCTAssertTrue(HostTextFocusPolicy.isEditable(role: role, enabled: true, editable: nil, valueSettable: true,
                                                         selectionSettable: nil, editableRoot: true), role)
            XCTAssertFalse(HostTextFocusPolicy.isEditable(role: role, enabled: true, editable: nil, valueSettable: nil,
                                                          selectionSettable: true, editableRoot: false), role)
            XCTAssertFalse(HostTextFocusPolicy.isEditable(role: role, enabled: true, editable: nil, valueSettable: nil,
                                                          selectionSettable: true, editableRoot: nil), role)
            XCTAssertFalse(HostTextFocusPolicy.isEditable(role: role, enabled: true, editable: nil, valueSettable: false,
                                                          selectionSettable: false, editableRoot: true), role)
        }
        // A focused web button or link is never a text target, whatever else it reports.
        XCTAssertFalse(HostTextFocusPolicy.isEditable(role: kAXButtonRole, enabled: true, editable: true,
                                                      valueSettable: true, selectionSettable: true, editableRoot: true))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(role: nil, enabled: true, editable: true, valueSettable: true))
    }

    func testRoleClassNamesOnlyTheKind() {
        XCTAssertEqual(HostTextFocusPolicy.roleClass(role: kAXTextFieldRole, subrole: nil, editable: true), .textField)
        XCTAssertEqual(HostTextFocusPolicy.roleClass(role: kAXTextFieldRole, subrole: kAXSearchFieldSubrole, editable: true), .searchField)
        XCTAssertEqual(HostTextFocusPolicy.roleClass(role: kAXTextAreaRole, subrole: nil, editable: true), .textArea)
        XCTAssertEqual(HostTextFocusPolicy.roleClass(role: kAXComboBoxRole, subrole: nil, editable: false), .comboBox)
        XCTAssertEqual(HostTextFocusPolicy.roleClass(role: kAXGroupRole, subrole: nil, editable: true), .contentEditable)
        XCTAssertEqual(HostTextFocusPolicy.roleClass(role: kAXGroupRole, subrole: nil, editable: false), .other)
        XCTAssertEqual(HostTextFocusPolicy.roleClass(role: nil, subrole: nil, editable: false), .none)
    }

    // MARK: Engine classification

    private func bundle(_ layout: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axweb-\(UUID().uuidString).app")
        for path in layout {
            let url = root.appendingPathComponent(path)
            if path.hasSuffix(".asar") {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: Data())
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testEngineClassificationFromBundleLayout() throws {
        XCTAssertEqual(HostAppEngine.classify(bundleURL: try bundle(["Contents/Frameworks/Electron Framework.framework"])), .electron)
        // The Codex app renames its framework but still ships app.asar.
        XCTAssertEqual(HostAppEngine.classify(bundleURL: try bundle([
            "Contents/Resources/app.asar",
            "Contents/Frameworks/Codex Framework.framework/Versions/Current/Helpers/Codex (Renderer).app"])), .electron)
        XCTAssertEqual(HostAppEngine.classify(bundleURL: try bundle([
            "Contents/Frameworks/Google Chrome Framework.framework/Versions/Current/Helpers/Google Chrome Helper (Renderer).app"])), .chromium)
        XCTAssertEqual(HostAppEngine.classify(bundleURL: try bundle(["Contents/Frameworks/Sparkle.framework"])), .native)
        XCTAssertEqual(HostAppEngine.classify(bundleURL: nil), .native)
    }

    func testEngineIsCachedPerBundle() throws {
        var calls = 0
        let activator = HostAXWebActivator(classify: { _ in calls += 1; return .electron })
        let url = URL(fileURLWithPath: "/Applications/Example.app")
        XCTAssertEqual(activator.engine(for: url), .electron)
        XCTAssertEqual(activator.engine(for: url), .electron)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(activator.engine(for: nil), .native)
    }

    // MARK: Enable-once policy

    func testPolicyClaimsEachWebProcessOnceAndNeverNativeApps() {
        var policy = HostAXWebActivationPolicy()
        let claude = HostAXProcessKey(pid: 501, launched: 1000)
        XCTAssertFalse(policy.claim(HostAXProcessKey(pid: 77, launched: 1), engine: .native, now: 0) != nil)
        XCTAssertTrue(policy.claim(claude, engine: .electron, now: 0) != nil)
        XCTAssertFalse(policy.claim(claude, engine: .electron, now: 0) != nil, "At most once per process")
        XCTAssertTrue(policy.claim(HostAXProcessKey(pid: 501, launched: 2000), engine: .electron, now: 0) != nil,
                      "A relaunch that reuses the pid is a new process")
        XCTAssertTrue(policy.claim(HostAXProcessKey(pid: 900, launched: 5), engine: .chromium, now: 0) != nil)
        XCTAssertEqual(policy.attempted.count, 3)
    }

    func testPolicyMemoryIsBounded() {
        var policy = HostAXWebActivationPolicy()
        for pid in 0..<(HostAXWebActivationPolicy.capacity * 3) {
            _ = policy.claim(HostAXProcessKey(pid: pid_t(pid), launched: nil), engine: .electron, now: 0)
        }
        XCTAssertLessThanOrEqual(policy.attempted.count, HostAXWebActivationPolicy.capacity)
    }

    func testElectronGetsManualAccessibilityOnlyAndOnlyOnce() {
        let activator = HostAXWebActivator(classify: { _ in .electron })
        var writes: [HostAXWebAttribute] = []
        let key = HostAXProcessKey(pid: 42, launched: 10)
        let first = activator.activateIfNeeded(key, engine: .electron,
                                               set: { writes.append($0); return .applied }, isOn: { _ in .off })
        XCTAssertEqual(first, HostAXWebActivation(attribute: .manual, outcome: .applied))
        let second = activator.activateIfNeeded(key, engine: .electron,
                                                set: { writes.append($0); return .applied }, isOn: { _ in .off })
        XCTAssertNil(second)
        XCTAssertEqual(writes, [.manual], "Enhanced UI is never written when manual accessibility works")
    }

    func testChromeFallsBackToEnhancedUserInterfaceUnlessAlreadyOn() {
        let activator = HostAXWebActivator(classify: { _ in .chromium })
        var writes: [HostAXWebAttribute] = []
        let result = activator.activateIfNeeded(HostAXProcessKey(pid: 7, launched: 1), engine: .chromium,
            set: { writes.append($0); return $0 == .manual ? .unsupported : .applied }, isOn: { _ in .off })
        XCTAssertEqual(result, HostAXWebActivation(attribute: .enhanced, outcome: .applied))
        XCTAssertEqual(writes, [.manual, .enhanced])

        writes = []
        let alreadyOn = activator.activateIfNeeded(HostAXProcessKey(pid: 8, launched: 1), engine: .chromium,
            set: { writes.append($0); return $0 == .manual ? .unsupported : .applied }, isOn: { $0 == .enhanced ? .on : .off })
        XCTAssertEqual(alreadyOn, HostAXWebActivation(attribute: .manual, outcome: .unsupported))
        XCTAssertEqual(writes, [.manual], "An app that already has enhanced UI on is left alone")
    }

    func testFailedManualRequestIsNotEscalatedOrRepeated() {
        let activator = HostAXWebActivator(classify: { _ in .electron })
        var writes: [HostAXWebAttribute] = []
        let key = HostAXProcessKey(pid: 9, launched: 1)
        let result = activator.activateIfNeeded(key, engine: .electron,
                                                set: { writes.append($0); return .failed }, isOn: { _ in .off })
        XCTAssertEqual(result, HostAXWebActivation(attribute: .manual, outcome: .failed))
        XCTAssertNil(activator.activateIfNeeded(key, engine: .electron,
                                                set: { writes.append($0); return .applied }, isOn: { _ in .off }))
        XCTAssertEqual(writes, [.manual], "A timed-out or hung app is not asked again on every tap")
    }

    func testNativeAppIsNeverAsked() {
        let activator = HostAXWebActivator(classify: { _ in .native })
        var writes = 0
        XCTAssertNil(activator.activateIfNeeded(HostAXProcessKey(pid: 3, launched: 1), engine: .native,
                                                set: { _ in writes += 1; return .applied }, isOn: { _ in .off }))
        XCTAssertEqual(writes, 0)
    }

    func testSetOutcomeMapsAXErrors() {
        XCTAssertEqual(HostAXSetOutcome(.success), .applied)
        XCTAssertEqual(HostAXSetOutcome(.attributeUnsupported), .unsupported)
        XCTAssertEqual(HostAXSetOutcome(.cannotComplete), .failed)
        XCTAssertEqual(HostAXSetOutcome(.notImplemented), .failed)
    }

    // MARK: Prewarm on app activation

    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(HostAXWebAttribute, pid_t)] = []
        func add(_ attribute: HostAXWebAttribute, _ pid: pid_t) { lock.lock(); items.append((attribute, pid)); lock.unlock() }
        var attributes: [HostAXWebAttribute] { lock.lock(); defer { lock.unlock() }; return items.map(\.0) }
        var pids: [pid_t] { lock.lock(); defer { lock.unlock() }; return items.map(\.1) }
    }

    private func prewarm(engine: HostAppEngine, writes: Writes, manual: HostAXSetOutcome = .applied) -> HostAXWebPrewarm {
        HostAXWebPrewarm(activator: HostAXWebActivator(classify: { _ in engine }),
                         broker: HostAXBroker(label: "test.ax.prewarm.\(UUID().uuidString)"),
                         set: { attribute, _, pid, _ in writes.add(attribute, pid); return attribute == .manual ? manual : .applied },
                         isOn: { _, _, _ in .off }, trusted: { true })
    }

    private let app = URL(fileURLWithPath: "/Applications/Example.app")

    func testActivationDuringASessionRequestsTheTreeOnceForThatProcess() async {
        let writes = Writes()
        let warm = prewarm(engine: .electron, writes: writes)
        let first = await warm.appActivated(pid: 4242, launched: 100, bundleURL: app, sessionActive: true)
        XCTAssertEqual(first, .requested(HostAXWebActivation(attribute: .manual, outcome: .applied)))
        let again = await warm.appActivated(pid: 4242, launched: 100, bundleURL: app, sessionActive: true)
        XCTAssertEqual(again, .alreadyAsked, "Switching back to the same process asks nothing")
        XCTAssertEqual(writes.attributes, [.manual])
        XCTAssertEqual(writes.pids, [4242])
    }

    func testActivationOutsideASessionAsksNothing() async {
        let writes = Writes()
        let warm = prewarm(engine: .electron, writes: writes)
        let outcome = await warm.appActivated(pid: 4243, launched: 100, bundleURL: app, sessionActive: false)
        XCTAssertEqual(outcome, .noSession)
        XCTAssertEqual(writes.attributes, [])
        let later = await warm.appActivated(pid: 4243, launched: 100, bundleURL: app, sessionActive: true)
        XCTAssertEqual(later, .requested(HostAXWebActivation(attribute: .manual, outcome: .applied)),
                       "A skipped activation does not use up the process's one request")
    }

    func testNativeAppActivationAsksNothing() async {
        let writes = Writes()
        let warm = prewarm(engine: .native, writes: writes)
        let outcome = await warm.appActivated(pid: 4244, launched: 100, bundleURL: app, sessionActive: true)
        XCTAssertEqual(outcome, .native)
        XCTAssertEqual(writes.attributes, [])
    }

    func testChromeActivationFallsBackToEnhancedUserInterface() async {
        let writes = Writes()
        let warm = prewarm(engine: .chromium, writes: writes, manual: .unsupported)
        let outcome = await warm.appActivated(pid: 4245, launched: 100, bundleURL: app, sessionActive: true)
        XCTAssertEqual(outcome, .requested(HostAXWebActivation(attribute: .enhanced, outcome: .applied)))
        XCTAssertEqual(writes.attributes, [.manual, .enhanced])
    }

    func testPrewarmAndProbeShareTheOncePerProcessClaim() async {
        let writes = Writes()
        let activator = HostAXWebActivator(classify: { _ in .electron })
        let warm = HostAXWebPrewarm(activator: activator, broker: HostAXBroker(label: "test.ax.prewarm.shared"),
                                    set: { attribute, _, pid, _ in writes.add(attribute, pid); return .applied },
                                    isOn: { _, _, _ in .off }, trusted: { true })
        _ = await warm.appActivated(pid: 4246, launched: 7, bundleURL: app, sessionActive: true)
        XCTAssertNil(activator.activateIfNeeded(HostAXProcessKey(pid: 4246, launched: 7), engine: .electron,
                                                set: { _ in .applied }, isOn: { _ in .off }),
                     "A probe in the prewarmed app does not ask again")
    }

    func testBusyLaneDropsThePrewarmWithoutUsingTheClaim() async {
        let writes = Writes()
        let activator = HostAXWebActivator(classify: { _ in .electron })
        let broker = HostAXBroker(label: "test.ax.prewarm.busy")
        let hog = Task { await broker.run(budget: 0.05) { _ -> Int? in Thread.sleep(forTimeInterval: 0.6); return 1 } }
        _ = await hog.value
        let warm = HostAXWebPrewarm(activator: activator, broker: broker,
                                    set: { attribute, _, pid, _ in writes.add(attribute, pid); return .applied },
                                    isOn: { _, _, _ in .off }, trusted: { true })
        let outcome = await warm.appActivated(pid: 4247, launched: 1, bundleURL: app, sessionActive: true)
        XCTAssertEqual(outcome, .laneBusy)
        XCTAssertEqual(writes.attributes, [])
        XCTAssertNotNil(activator.activateIfNeeded(HostAXProcessKey(pid: 4247, launched: 1), engine: .electron,
                                                   set: { _ in .applied }, isOn: { _ in .off }))
    }

    func testControlStartPrewarmsTheFrontmostChromiumAppOnce() async {
        let writes = Writes()
        let warm = prewarm(engine: .chromium, writes: writes, manual: .applied)
        var edge = HostAXPrewarmEdge()
        var outcomes: [HostAXPrewarmOutcome] = []
        // Session starts with the app already frontmost, stays on, ends, then control starts again.
        for active in [false, true, true, true, false, true] where edge.update(active: active) {
            outcomes.append(await warm.appActivated(pid: 5150, launched: 9, bundleURL: app, sessionActive: true))
        }
        XCTAssertEqual(outcomes, [.requested(HostAXWebActivation(attribute: .manual, outcome: .applied)), .alreadyAsked])
        XCTAssertEqual(writes.attributes, [.manual], "Exactly one request for the process")
        XCTAssertEqual(writes.pids, [5150])
        let nobody = await warm.controlStarted(frontmost: nil)
        XCTAssertEqual(nobody, .native)
    }

    // MARK: Review fixes: unsent requests, session-end revert

    func testUnsentManualRequestLeavesTheProcessAskable() {
        let activator = HostAXWebActivator(classify: { _ in .electron })
        let key = HostAXProcessKey(pid: 61, launched: 1)
        XCTAssertNil(activator.activateIfNeeded(key, engine: .electron, set: { _ in .notAttempted }, isOn: { _ in .off }))
        XCTAssertFalse(activator.isClaimed(key), "A cancelled or out-of-time probe must not use up the one request")
        XCTAssertEqual(activator.activateIfNeeded(key, engine: .electron, set: { _ in .applied }, isOn: { _ in .off }),
                       HostAXWebActivation(attribute: .manual, outcome: .applied))
    }

    func testUnsentEnhancedFallbackLeavesTheProcessAskable() {
        let activator = HostAXWebActivator(classify: { _ in .chromium })
        let read = HostAXProcessKey(pid: 62, launched: 1)
        XCTAssertNil(activator.activateIfNeeded(read, engine: .chromium, set: { _ in .unsupported },
                                                isOn: { _ in .notAttempted }))
        XCTAssertFalse(activator.isClaimed(read))
        let write = HostAXProcessKey(pid: 63, launched: 1)
        XCTAssertNil(activator.activateIfNeeded(write, engine: .chromium,
                                                set: { $0 == .manual ? .unsupported : .notAttempted }, isOn: { _ in .off }))
        XCTAssertFalse(activator.isClaimed(write))
    }

    func testUnsentPrewarmLeavesTheProcessAskable() async {
        let activator = HostAXWebActivator(classify: { _ in .electron })
        let warm = HostAXWebPrewarm(activator: activator, broker: HostAXBroker(label: "test.ax.prewarm.unsent"),
                                    set: { _, _, _, _ in .notAttempted }, isOn: { _, _, _ in .off }, trusted: { true })
        let outcome = await warm.appActivated(pid: 64, launched: 1, bundleURL: app, sessionActive: true)
        XCTAssertEqual(outcome, .notSent)
        XCTAssertFalse(activator.isClaimed(HostAXProcessKey(pid: 64, launched: 1)))
    }

    private final class Flags: @unchecked Sendable {
        private let lock = NSLock()
        private var enhanced: [pid_t: Bool] = [:]
        private(set) var log: [(HostAXWebAttribute, Bool, pid_t)] = []
        func set(_ attribute: HostAXWebAttribute, _ value: Bool, _ pid: pid_t) -> HostAXSetOutcome {
            lock.lock(); defer { lock.unlock() }
            log.append((attribute, value, pid))
            if attribute == .manual { return .unsupported }
            enhanced[pid] = value
            return .applied
        }
        func read(_ pid: pid_t) -> HostAXFlagRead { lock.lock(); defer { lock.unlock() }; return enhanced[pid] == true ? .on : .off }
        func force(_ pid: pid_t, _ value: Bool) { lock.lock(); enhanced[pid] = value; lock.unlock() }
        var offWrites: [pid_t] { lock.lock(); defer { lock.unlock() }; return log.filter { $0.0 == .enhanced && !$0.1 }.map(\.2) }
    }

    func testSessionEndTurnsOffOnlyTheEnhancedUIFarsideTurnedOn() async {
        let flags = Flags()
        flags.force(71, true)
        let activator = HostAXWebActivator(classify: { _ in .chromium })
        let warm = HostAXWebPrewarm(activator: activator, broker: HostAXBroker(label: "test.ax.revert"),
                                    set: { attribute, value, pid, _ in flags.set(attribute, value, pid) },
                                    isOn: { _, pid, _ in flags.read(pid) }, trusted: { true }, isAlive: { _ in true })
        let ours = await warm.appActivated(pid: 70, launched: 1, bundleURL: app, sessionActive: true)
        XCTAssertEqual(ours, .requested(HostAXWebActivation(attribute: .enhanced, outcome: .applied)))
        let theirs = await warm.appActivated(pid: 71, launched: 1, bundleURL: app, sessionActive: true)
        XCTAssertEqual(theirs, .requested(HostAXWebActivation(attribute: .manual, outcome: .unsupported)),
                       "Already on: Farside writes nothing, so it owns nothing to undo")
        _ = await warm.appActivated(pid: 72, launched: 1, bundleURL: app, sessionActive: true)
        flags.force(72, false) // Something else turned it off during the session.

        let reverted = await warm.sessionEnded(voiceOverOn: false, stillCurrent: { true })
        XCTAssertEqual(reverted, .reverted([HostAXProcessKey(pid: 70, launched: 1)]))
        XCTAssertEqual(flags.offWrites, [70], "Only a process Farside turned on and still on is turned off")
        XCTAssertEqual(flags.read(71), .on)
        XCTAssertFalse(activator.isClaimed(HostAXProcessKey(pid: 70, launched: 1)), "The next session may ask again")
        XCTAssertFalse(activator.isClaimed(HostAXProcessKey(pid: 72, launched: 1)))
        XCTAssertTrue(activator.isClaimed(HostAXProcessKey(pid: 71, launched: 1)))
        let again = await warm.sessionEnded(voiceOverOn: false, stillCurrent: { true })
        XCTAssertEqual(again, .reverted([]))
        XCTAssertEqual(flags.offWrites, [70])
    }

    func testSessionEndLeavesManualAccessibilityAndKeepsUnreachedProcesses() {
        let activator = HostAXWebActivator(classify: { _ in .electron })
        let electron = HostAXProcessKey(pid: 80, launched: 1)
        _ = activator.activateIfNeeded(electron, engine: .electron, set: { _ in .applied }, isOn: { _ in .off })
        let chrome = HostAXProcessKey(pid: 81, launched: 1)
        _ = activator.activateIfNeeded(chrome, engine: .chromium, set: { $0 == .manual ? .unsupported : .applied },
                                       isOn: { _ in .off })
        var turnedOff: [HostAXProcessKey] = []
        XCTAssertEqual(activator.revertEnhanced(isAlive: { _ in true }, isOn: { _ in .notAttempted }, turnOff: { turnedOff.append($0); return .applied }), [])
        XCTAssertTrue(activator.isClaimed(chrome), "Out of budget: kept for the next session end")
        XCTAssertEqual(activator.revertEnhanced(isAlive: { _ in true }, isOn: { _ in .on }, turnOff: { turnedOff.append($0); return .applied }), [chrome])
        XCTAssertEqual(turnedOff, [chrome], "AXManualAccessibility on the Electron app is left on")
        XCTAssertTrue(activator.isClaimed(electron))
    }

    // MARK: Second review: retries after failure, trust, overrun

    func testFailedRequestRetriesOnlyAfterTheCooldownAndAtMostThreeTimes() {
        var now: TimeInterval = 1000
        let activator = HostAXWebActivator(classify: { _ in .electron }, clock: { now })
        let key = HostAXProcessKey(pid: 90, launched: 1)
        var writes = 0
        func ask() -> HostAXActivationAttempt {
            activator.request(key, engine: .electron, set: { _ in writes += 1; return .failed }, isOn: { _ in .off })
        }
        XCTAssertEqual(ask(), .sent(HostAXWebActivation(attribute: .manual, outcome: .failed)))
        now += 1
        XCTAssertEqual(ask(), .skipped, "A failed request is not repeated inside the cooldown")
        now += HostAXWebActivationPolicy.retryCooldown
        XCTAssertEqual(ask(), .sent(HostAXWebActivation(attribute: .manual, outcome: .failed)))
        now += HostAXWebActivationPolicy.retryCooldown
        XCTAssertEqual(ask(), .sent(HostAXWebActivation(attribute: .manual, outcome: .failed)))
        now += HostAXWebActivationPolicy.retryCooldown * 10
        XCTAssertEqual(ask(), .skipped, "The third failure stops retries for this process")
        XCTAssertEqual(writes, HostAXWebActivationPolicy.maxAttempts)
    }

    func testAppliedRequestIsNeverRepeatedAndUnsentAfterFailureKeepsTheCount() {
        var now: TimeInterval = 0
        let activator = HostAXWebActivator(classify: { _ in .electron }, clock: { now })
        let key = HostAXProcessKey(pid: 91, launched: 1)
        XCTAssertEqual(activator.request(key, engine: .electron, set: { _ in .failed }, isOn: { _ in .off }),
                       .sent(HostAXWebActivation(attribute: .manual, outcome: .failed)))
        now += HostAXWebActivationPolicy.retryCooldown
        XCTAssertEqual(activator.request(key, engine: .electron, set: { _ in .notAttempted }, isOn: { _ in .off }), .notSent)
        XCTAssertEqual(activator.request(key, engine: .electron, set: { _ in .applied }, isOn: { _ in .off }),
                       .sent(HostAXWebActivation(attribute: .manual, outcome: .applied)),
                       "An unsent retry does not use up the cooldown or an attempt")
        now += 100
        XCTAssertEqual(activator.request(key, engine: .electron, set: { _ in .applied }, isOn: { _ in .off }), .skipped)
    }

    func testPrewarmWithoutAccessibilityTrustAsksNothing() async {
        let writes = Writes()
        let activator = HostAXWebActivator(classify: { _ in .electron })
        let warm = HostAXWebPrewarm(activator: activator, broker: HostAXBroker(label: "test.ax.untrusted"),
                                    set: { attribute, _, pid, _ in writes.add(attribute, pid); return .failed },
                                    isOn: { _, _, _ in .off }, trusted: { false })
        let outcome = await warm.appActivated(pid: 92, launched: 1, bundleURL: app, sessionActive: true)
        XCTAssertEqual(outcome, .notTrusted)
        XCTAssertEqual(writes.attributes, [])
        XCTAssertFalse(activator.isClaimed(HostAXProcessKey(pid: 92, launched: 1)))
    }

    func testPrewarmThatOverrunsItsBudgetReportsTimedOutNotLaneBusy() async {
        let activator = HostAXWebActivator(classify: { _ in .electron })
        let warm = HostAXWebPrewarm(activator: activator, broker: HostAXBroker(label: "test.ax.overrun"),
                                    set: { _, _, _, _ in Thread.sleep(forTimeInterval: 0.4); return .failed },
                                    isOn: { _, _, _ in .off }, trusted: { true })
        let outcome = await warm.appActivated(pid: 93, launched: 1, bundleURL: app, sessionActive: true)
        XCTAssertEqual(outcome, .timedOut)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(activator.isClaimed(HostAXProcessKey(pid: 93, launched: 1)),
                      "The write that ran late was sent and counts as a failed attempt")
    }

    // MARK: Third review: VoiceOver, errors kept, reconnect

    private func chromeWithEnhancedByUs(_ flags: Flags, pid: pid_t, label: String) async -> (HostAXWebPrewarm, HostAXWebActivator) {
        let activator = HostAXWebActivator(classify: { _ in .chromium })
        let warm = HostAXWebPrewarm(activator: activator, broker: HostAXBroker(label: label),
                                    set: { attribute, value, pid, _ in flags.set(attribute, value, pid) },
                                    isOn: { _, pid, _ in flags.read(pid) }, trusted: { true }, isAlive: { _ in true })
        let outcome = await warm.appActivated(pid: pid, launched: 1, bundleURL: app, sessionActive: true)
        XCTAssertEqual(outcome, .requested(HostAXWebActivation(attribute: .enhanced, outcome: .applied)))
        return (warm, activator)
    }

    func testVoiceOverKeepsEnhancedUIOnAtSessionEnd() async {
        let flags = Flags()
        let (warm, activator) = await chromeWithEnhancedByUs(flags, pid: 100, label: "test.ax.voiceover")
        let skipped = await warm.sessionEnded(voiceOverOn: true, stillCurrent: { true })
        XCTAssertEqual(skipped, .voiceOver)
        XCTAssertEqual(flags.offWrites, [], "A VoiceOver user needs AXEnhancedUserInterface on")
        XCTAssertEqual(flags.read(100), .on)
        XCTAssertTrue(activator.isClaimed(HostAXProcessKey(pid: 100, launched: 1)))
        let later = await warm.sessionEnded(voiceOverOn: false, stillCurrent: { true })
        XCTAssertEqual(later, .reverted([HostAXProcessKey(pid: 100, launched: 1)]), "Still owned for a later session end")
    }

    func testReconnectBeforeTheRevertRunsLeavesEnhancedUIOn() async {
        let flags = Flags()
        let (warm, _) = await chromeWithEnhancedByUs(flags, pid: 101, label: "test.ax.reconnect")
        let generation = HostAXSessionGeneration()
        let ended = generation.current
        generation.advance() // The phone reconnected before the session-end work ran.
        let skipped = await warm.sessionEnded(voiceOverOn: false, stillCurrent: { generation.current == ended })
        XCTAssertEqual(skipped, .newSession)
        XCTAssertEqual(flags.offWrites, [])
        let next = generation.current
        let reverted = await warm.sessionEnded(voiceOverOn: false, stillCurrent: { generation.current == next })
        XCTAssertEqual(reverted, .reverted([HostAXProcessKey(pid: 101, launched: 1)]))
    }

    func testUnreadableOrFailedRevertIsKeptAndExitedProcessIsDropped() {
        let activator = HostAXWebActivator(classify: { _ in .chromium })
        let key = HostAXProcessKey(pid: 102, launched: 1)
        let gone = HostAXProcessKey(pid: 103, launched: 1)
        for pid in [key, gone] {
            _ = activator.activateIfNeeded(pid, engine: .chromium, set: { $0 == .manual ? .unsupported : .applied },
                                           isOn: { _ in .off })
        }
        let alive: (HostAXProcessKey) -> Bool = { $0 == key }
        XCTAssertEqual(activator.revertEnhanced(isAlive: alive, isOn: { _ in .unknown }, turnOff: { _ in .applied }), [])
        XCTAssertTrue(activator.isClaimed(key), "An unreadable state is kept for the next session end")
        XCTAssertFalse(activator.isClaimed(gone), "An exited process is forgotten, not kept forever")
        XCTAssertEqual(activator.revertEnhanced(isAlive: alive, isOn: { _ in .on }, turnOff: { _ in .failed }), [])
        XCTAssertTrue(activator.isClaimed(key), "A failed turn-off is kept too")
        XCTAssertEqual(activator.revertEnhanced(isAlive: alive, isOn: { _ in .on }, turnOff: { _ in .applied }), [key])
        XCTAssertFalse(activator.isClaimed(key))
        XCTAssertEqual(activator.revertEnhanced(isAlive: alive, isOn: { _ in .on }, turnOff: { _ in .applied }), [])
    }
}
