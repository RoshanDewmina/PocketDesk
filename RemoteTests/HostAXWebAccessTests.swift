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
        XCTAssertFalse(policy.claim(HostAXProcessKey(pid: 77, launched: 1), engine: .native))
        XCTAssertTrue(policy.claim(claude, engine: .electron))
        XCTAssertFalse(policy.claim(claude, engine: .electron), "At most once per process")
        XCTAssertTrue(policy.claim(HostAXProcessKey(pid: 501, launched: 2000), engine: .electron),
                      "A relaunch that reuses the pid is a new process")
        XCTAssertTrue(policy.claim(HostAXProcessKey(pid: 900, launched: 5), engine: .chromium))
        XCTAssertEqual(policy.attempted.count, 3)
    }

    func testPolicyMemoryIsBounded() {
        var policy = HostAXWebActivationPolicy()
        for pid in 0..<(HostAXWebActivationPolicy.capacity * 3) {
            _ = policy.claim(HostAXProcessKey(pid: pid_t(pid), launched: nil), engine: .electron)
        }
        XCTAssertLessThanOrEqual(policy.attempted.count, HostAXWebActivationPolicy.capacity)
    }

    func testElectronGetsManualAccessibilityOnlyAndOnlyOnce() {
        let activator = HostAXWebActivator(classify: { _ in .electron })
        var writes: [HostAXWebAttribute] = []
        let key = HostAXProcessKey(pid: 42, launched: 10)
        let first = activator.activateIfNeeded(key, engine: .electron,
                                               set: { writes.append($0); return .applied }, isOn: { _ in false })
        XCTAssertEqual(first, HostAXWebActivation(attribute: .manual, outcome: .applied))
        let second = activator.activateIfNeeded(key, engine: .electron,
                                                set: { writes.append($0); return .applied }, isOn: { _ in false })
        XCTAssertNil(second)
        XCTAssertEqual(writes, [.manual], "Enhanced UI is never written when manual accessibility works")
    }

    func testChromeFallsBackToEnhancedUserInterfaceUnlessAlreadyOn() {
        let activator = HostAXWebActivator(classify: { _ in .chromium })
        var writes: [HostAXWebAttribute] = []
        let result = activator.activateIfNeeded(HostAXProcessKey(pid: 7, launched: 1), engine: .chromium,
            set: { writes.append($0); return $0 == .manual ? .unsupported : .applied }, isOn: { _ in false })
        XCTAssertEqual(result, HostAXWebActivation(attribute: .enhanced, outcome: .applied))
        XCTAssertEqual(writes, [.manual, .enhanced])

        writes = []
        let alreadyOn = activator.activateIfNeeded(HostAXProcessKey(pid: 8, launched: 1), engine: .chromium,
            set: { writes.append($0); return $0 == .manual ? .unsupported : .applied }, isOn: { $0 == .enhanced })
        XCTAssertEqual(alreadyOn, HostAXWebActivation(attribute: .manual, outcome: .unsupported))
        XCTAssertEqual(writes, [.manual], "An app that already has enhanced UI on is left alone")
    }

    func testFailedManualRequestIsNotEscalatedOrRepeated() {
        let activator = HostAXWebActivator(classify: { _ in .electron })
        var writes: [HostAXWebAttribute] = []
        let key = HostAXProcessKey(pid: 9, launched: 1)
        let result = activator.activateIfNeeded(key, engine: .electron,
                                                set: { writes.append($0); return .failed }, isOn: { _ in false })
        XCTAssertEqual(result, HostAXWebActivation(attribute: .manual, outcome: .failed))
        XCTAssertNil(activator.activateIfNeeded(key, engine: .electron,
                                                set: { writes.append($0); return .applied }, isOn: { _ in false }))
        XCTAssertEqual(writes, [.manual], "A timed-out or hung app is not asked again on every tap")
    }

    func testNativeAppIsNeverAsked() {
        let activator = HostAXWebActivator(classify: { _ in .native })
        var writes = 0
        XCTAssertNil(activator.activateIfNeeded(HostAXProcessKey(pid: 3, launched: 1), engine: .native,
                                                set: { _ in writes += 1; return .applied }, isOn: { _ in false }))
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
                         set: { attribute, pid, _ in writes.add(attribute, pid); return attribute == .manual ? manual : .applied },
                         isOn: { _, _, _ in false })
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
                                    set: { attribute, pid, _ in writes.add(attribute, pid); return .applied },
                                    isOn: { _, _, _ in false })
        _ = await warm.appActivated(pid: 4246, launched: 7, bundleURL: app, sessionActive: true)
        XCTAssertNil(activator.activateIfNeeded(HostAXProcessKey(pid: 4246, launched: 7), engine: .electron,
                                                set: { _ in .applied }, isOn: { _ in false }),
                     "A probe in the prewarmed app does not ask again")
    }

    func testBusyLaneDropsThePrewarmWithoutUsingTheClaim() async {
        let writes = Writes()
        let activator = HostAXWebActivator(classify: { _ in .electron })
        let broker = HostAXBroker(label: "test.ax.prewarm.busy")
        let hog = Task { await broker.run(budget: 0.05) { _ -> Int? in Thread.sleep(forTimeInterval: 0.6); return 1 } }
        _ = await hog.value
        let warm = HostAXWebPrewarm(activator: activator, broker: broker,
                                    set: { attribute, pid, _ in writes.add(attribute, pid); return .applied },
                                    isOn: { _, _, _ in false })
        let outcome = await warm.appActivated(pid: 4247, launched: 1, bundleURL: app, sessionActive: true)
        XCTAssertEqual(outcome, .laneBusy)
        XCTAssertEqual(writes.attributes, [])
        XCTAssertNotNil(activator.activateIfNeeded(HostAXProcessKey(pid: 4247, launched: 1), engine: .electron,
                                                   set: { _ in .applied }, isOn: { _ in false }))
    }
}
