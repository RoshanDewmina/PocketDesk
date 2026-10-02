import AppKit
import ApplicationServices

/// A response may only describe the last accepted click in the current live input session.
struct HostTextFocusTicket {
    let epoch: UInt64
    let revision: UInt64
    let issuedAt: TimeInterval

    /// Map the posting clock to uptime before receipt delivery; a fast app can notify focus
    /// before the receipt reaches main. Starting at receipt delivery would discard that change.
    static func postedAt(receivedAt: TimeInterval, postingStartedMs: Double, clockNowMs: Double) -> TimeInterval {
        receivedAt - max(0, clockNowMs - postingStartedMs) / 1000
    }

    func isCurrent(epoch currentEpoch: UInt64, revision currentRevision: UInt64,
                   now: TimeInterval, active: Bool, connected: Bool,
                   controlEnabled: Bool, captureHealthy: Bool) -> Bool {
        epoch == currentEpoch && revision == currentRevision &&
            now >= issuedAt && now - issuedAt < 1 &&
            active && connected && controlEnabled && captureHealthy
    }
}

/// The focused element's kind, for logs. No label, title or value is ever part of it.
enum HostTextRoleClass: String, Sendable {
    case none, textField, searchField, textArea, comboBox, contentEditable, other
}

/// Uses metadata only. Neither the focused element's value nor its label is requested.
///
/// Native AppKit fields are text roles with a settable value. Chromium (Chrome, Electron) shows
/// `<input>`, `<textarea>` and, measured on Chrome 154 / Electron in Claude, Cursor and Codex, a
/// contenteditable composer as AXTextField / AXTextArea / AXComboBox with a settable AXValue, and marks
/// any editable root with AXEditableAncestor pointing at itself. A contenteditable root that still
/// presents as AXGroup or AXWebArea is accepted on that mark plus a settable value or selection.
/// `AXIsEditable` is listed under obsolete attributes in AXAttributeConstants.h and Chromium answers it
/// with kAXErrorNoValue; it is read only so an app that says false can veto. There is no `AXEditable`.
enum HostTextFocusPolicy {
    static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
    static let containerRoles: Set<String> = [kAXGroupRole, "AXWebArea"]
    // These have settable values too, but never accept typing. AXStaticText is read-only text.
    static let nonTextRoles: Set<String> = [kAXSliderRole, kAXCheckBoxRole, kAXRadioButtonRole,
        kAXButtonRole, kAXPopUpButtonRole, kAXMenuItemRole, kAXScrollBarRole, kAXProgressIndicatorRole,
        kAXStaticTextRole]

    static func isEditable(role: String?, subrole: String? = nil, enabled: Bool?, editable: Bool?,
                           valueSettable: Bool?, selectionSettable: Bool? = nil,
                           editableRoot: Bool? = nil, selectionPresent: Bool = false) -> Bool {
        editableAnswer(role: role, enabled: enabled, editable: editable, valueSettable: valueSettable,
                       selectionSettable: selectionSettable, editableRoot: editableRoot,
                       selectionPresent: selectionPresent) == true
    }

    /// Nil is an opaque canvas/window/tree, not a concrete non-text answer. Both focused-element
    /// and hit-target providers use this same tri-state policy before consulting the real cursor.
    static func editableAnswer(role: String?, enabled: Bool?, editable: Bool?, valueSettable: Bool?,
                               selectionSettable: Bool? = nil, editableRoot: Bool? = nil,
                               selectionPresent: Bool = false) -> Bool? {
        guard enabled != false, editable != false else { return false }
        if let role, nonTextRoles.contains(role) { return false }
        if role.map({ textRoles.contains($0) }) == true || valueSettable == true || selectionPresent ||
            (editableRoot == true && selectionSettable == true) { return true }
        return nil
    }

    static func isLegacyEditable(role: String?, subrole: String? = nil, enabled: Bool?, editable: Bool?,
                           valueSettable: Bool?, selectionSettable: Bool? = nil,
                           editableRoot: Bool? = nil) -> Bool {
        guard enabled == true, editable != false, let role else { return false }
        if textRoles.contains(role) {
            // A selectable read-only text view also has a settable selection, so it does not count here.
            return editable == true || valueSettable == true
        }
        if containerRoles.contains(role) {
            return editableRoot == true && (valueSettable == true || selectionSettable == true)
        }
        return false
    }

    static func roleClass(role: String?, subrole: String?, editable: Bool) -> HostTextRoleClass {
        guard let role else { return .none }
        switch role {
        case kAXTextFieldRole: return subrole == kAXSearchFieldSubrole ? .searchField : .textField
        case "AXSearchField": return .searchField
        case kAXTextAreaRole: return .textArea
        case kAXComboBoxRole: return .comboBox
        default: return editable && containerRoles.contains(role) ? .contentEditable : .other
        }
    }
}

/// What the focus probe learned, in global CoreGraphics points. Geometry only.
struct HostTextFocusResult: Equatable, Sendable {
    var editable: Bool
    var frame: CGRect? = nil
    /// The insertion point when the app exposes it, otherwise the click.
    var anchor: CGPoint? = nil
    /// Diagnostics for logs: kinds and booleans only.
    var role: HostTextRoleClass = .none
    var engine: HostAppEngine = .native
    var activation: HostAXWebActivation? = nil
    var retried = false
    /// The AX lane was busy or the budget ran out, so nothing was learned.
    var dropped = false
    /// Nil means AX could not classify the focused element; false is a real non-text answer.
    var axEditable: Bool? = nil
    var tapHitsFocused = false
    var tapTargetEditable: Bool? = nil
    var focusChangedAt: TimeInterval? = nil

    static let unfocused = HostTextFocusResult(editable: false)
}

/// Tap correlation is independent of AX/cursor I/O, so tests inject both providers.
enum HostTextFocusTapPolicy {
    static let window: TimeInterval = 0.4
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "keyboard.tapFocusEnabled") as? Bool ?? true
    }

    static func shouldOpen(tapIssuedAt: TimeInterval?, now: TimeInterval,
                           ax: () -> HostTextFocusResult, cursor: () -> PointerShape?) -> Bool {
        guard let tapIssuedAt, now >= tapIssuedAt, now <= tapIssuedAt + window else { return false }
        let evidence = ax()
        if let editable = evidence.axEditable {
            guard editable else { return false }
            if evidence.tapHitsFocused || evidence.focusChangedAt.map({
                $0 >= tapIssuedAt && $0 <= now && $0 <= tapIssuedAt + window
            }) == true { return true }
            // Monaco/xterm can retain a hidden textarea while the visible canvas cannot be
            // related to it by AX. A known non-text target vetoes; an opaque target may use
            // the real I-beam, including after the user manually dismisses the keyboard.
            guard evidence.tapTargetEditable == nil else { return false }
            let shape = cursor()
            return shape == .iBeam || shape == .iBeamVertical
        }
        guard evidence.tapTargetEditable != false else { return false }
        let shape = cursor()
        return shape == .iBeam || shape == .iBeamVertical
    }
}

/// Only the frontmost app during a controlled session is observed. No field content is read.
/// Notifications timestamp focus changes; repeated post-tap queries also notice changes on apps
/// that do not implement notifications. A first sample alone never invents a focus change.
final class HostTextFocusChanges: @unchecked Sendable {
    static let shared = HostTextFocusChanges()
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var sessionActive = false

    var sessionIsActive: Bool { lock.lock(); defer { lock.unlock() }; return sessionActive }

    func setSessionActive(_ active: Bool) {
        lock.lock(); sessionActive = active; lock.unlock()
        if !active { stop() }
    }
    private var generation: UInt64 = 0
    private var observer: AXObserver?
    private var focused: AXUIElement?
    private var sampledAt: TimeInterval? = nil
    private var changedAt: TimeInterval? = nil

    func watch(pid newPID: pid_t, budget: HostAXBudget) {
        lock.lock()
        guard sessionActive else { lock.unlock(); return }
        if pid == newPID, observer != nil { lock.unlock(); return }
        removeSource()
        pid = newPID; generation &+= 1
        let token = generation
        focused = nil; sampledAt = nil; changedAt = nil
        lock.unlock()
        var created: AXObserver?
        guard AXObserverCreate(newPID, { observer, _, _, _ in
            HostTextFocusChanges.shared.note(observer: observer)
        }, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(newPID)
        guard budget.arm(app), AXObserverAddNotification(created, app,
                kAXFocusedUIElementChangedNotification as CFString, nil) == .success else { return }
        lock.lock(); defer { lock.unlock() }
        guard sessionActive, pid == newPID, generation == token, !budget.isCancelled else { return }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), kCFRunLoopCommonModes)
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        removeSource(); sessionActive = false; pid = 0; generation &+= 1
        focused = nil; sampledAt = nil; changedAt = nil
    }

    private func removeSource() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes)
        }
        observer = nil
    }

    private func note(observer eventObserver: AXObserver) {
        lock.lock(); defer { lock.unlock() }
        guard sessionActive, let observer, CFEqual(observer, eventObserver) else { return }
        changedAt = ProcessInfo.processInfo.systemUptime
    }

    func sample(_ element: AXUIElement?, pid samplePID: pid_t, tapIssuedAt: TimeInterval?,
                now: TimeInterval) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard pid == samplePID else { return nil }
        let same = focused == nil && element == nil || focused.flatMap { old in
            element.map { CFEqual(old, $0) }
        } == true
        if let sampledAt, let tapIssuedAt, sampledAt >= tapIssuedAt, !same { changedAt = now }
        focused = element; sampledAt = now
        return changedAt
    }
}

enum HostTextFocusProbe {
    static func isValidID(_ id: String?) -> Bool {
        guard let id, id.utf8.count == 32 else { return false }
        return id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The second tap of a double cancels the first tap's probe, whose AX call may still hold the
    /// lane; dropping the new probe answered "not editable" and the keyboard never opened.
    static let lanePatience: TimeInterval = 0.25

    static func editableAtClick(_ point: CGPoint) async -> Bool {
        await focus(at: point, geometry: false).editable
    }

    /// After asking a Chromium app for its tree, look again for at most this long, within the budget.
    static let activationRetry: TimeInterval = 0.15

    /// `point` is an admitted click, which must land on the focused element. Nil re-checks the focus
    /// after typing, when there is no click to compare.
    static func focus(at point: CGPoint?, geometry: Bool,
                      broker: HostAXBroker = .shared,
                      activator: HostAXWebActivator = .shared,
                      tapIssuedAt: TimeInterval? = nil, tapFocus: Bool = false,
                      budget total: TimeInterval = HostAXBroker.defaultBudget) async -> HostTextFocusResult {
        if let point, !(point.x.isFinite && point.y.isFinite) { return .unfocused }
        return await broker.run(budget: total, waitForLane: tapFocus ? 0 : lanePatience) { budget in
            if tapFocus { return inspectTap(point, geometry: geometry, tapIssuedAt: tapIssuedAt,
                                           budget: budget, activator: activator) }
            return inspect(point, geometry: geometry, budget: budget, activator: activator)
        } ?? HostTextFocusResult(editable: false, dropped: true)
    }

    private struct Candidate {
        let element: AXUIElement
        let editable: Bool
        let role: HostTextRoleClass
        let secure: Bool
    }

    /// Focus anywhere in the frontmost app can answer a tap; hit-testing only distinguishes an
    /// already-focused field from a non-text click that leaves that old field focused.
    private static func inspectTap(_ point: CGPoint?, geometry: Bool, tapIssuedAt: TimeInterval?,
                                   budget: HostAXBudget, activator: HostAXWebActivator) -> HostTextFocusResult {
        guard AXIsProcessTrusted(), let running = NSWorkspace.shared.frontmostApplication else { return .unfocused }
        let pid = running.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        let system = AXUIElementCreateSystemWide()
        guard budget.arm(system) else { return .unfocused }
        defer { _ = AXUIElementSetMessagingTimeout(system, 0) }
        // Prefer the system-wide focus, but some apps only answer on their application element.
        var focused = elementAttribute(system, kAXFocusedUIElementAttribute)
        if focused == nil, budget.arm(app) { focused = elementAttribute(app, kAXFocusedUIElementAttribute) }
        if let element = focused {
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return .unfocused }
        }
        let changedAt = HostTextFocusChanges.shared.sample(focused, pid: pid, tapIssuedAt: tapIssuedAt,
                                                          now: ProcessInfo.processInfo.systemUptime)
        let candidate = focused.flatMap { classify($0, budget: budget, legacy: false) }
        var result = HostTextFocusResult(editable: candidate?.editable == true, role: candidate?.role ?? .none,
                                        engine: activator.engine(for: running.bundleURL),
                                        axEditable: candidate?.editable, focusChangedAt: changedAt)
        let changedByTap = tapIssuedAt.flatMap { tap in changedAt.map { $0 >= tap && $0 <= tap + HostTextFocusTapPolicy.window } } == true
        if !changedByTap, let point, budget.arm(system) {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
               let hit {
                if let candidate, candidate.editable {
                    result.tapHitsFocused = landsOn(candidate.element, hit: hit, budget: budget)
                }
                if !result.tapHitsFocused {
                    result.tapTargetEditable = classify(hit, budget: budget, legacy: false)?.editable
                }
            }
        }
        guard geometry, let candidate, candidate.editable, budget.arm(candidate.element),
              let frame = frame(of: candidate.element) else { return result }
        result.frame = frame
        result.anchor = candidate.secure || !budget.arm(candidate.element)
            ? point : insertionPoint(of: candidate.element, budget: budget) ?? point
        return result
    }

    private static func inspect(_ point: CGPoint?, geometry: Bool, budget: HostAXBudget,
                                activator: HostAXWebActivator) -> HostTextFocusResult {
        guard AXIsProcessTrusted() else { return .unfocused }

        let system = AXUIElementCreateSystemWide()
        // Apple documents that the system-wide timeout is process-wide; restore it before leaving.
        guard budget.arm(system) else { return .unfocused }
        defer { _ = AXUIElementSetMessagingTimeout(system, 0) }

        // The system-wide element can answer cannotComplete while the frontmost app itself answers.
        let app = elementAttribute(system, kAXFocusedApplicationAttribute)
            ?? NSWorkspace.shared.frontmostApplication.map { AXUIElementCreateApplication($0.processIdentifier) }
        var pid: pid_t = 0
        let running = app.flatMap { AXUIElementGetPid($0, &pid) == .success && pid > 0
            ? NSRunningApplication(processIdentifier: pid) : nil }
        let engine = activator.engine(for: running?.bundleURL)
        let owner = app ?? system

        var candidate = focusedCandidate(owner, point: point, system: system, web: engine.isWeb, budget: budget)
        var activation: HostAXWebActivation?
        var retried = false
        if candidate?.editable != true, !budget.isExhausted, let app, let running, engine.isWeb {
            let key = HostAXProcessKey(pid: running.processIdentifier, launched: running.launchDate?.timeIntervalSince1970)
            activation = activator.activateIfNeeded(key, engine: engine,
                set: { HostAXWebActivator.set($0, on: app, budget: budget) },
                isOn: { HostAXWebActivator.isOn($0, on: app, budget: budget) })
            if let activation, activation.outcome != .unsupported {
                retried = true
                // The tree is built asynchronously (about 2 s for a cold Electron app), so this one
                // short retry catches only a fast build; the next tap finds it ready.
                let until = ProcessInfo.processInfo.systemUptime + min(activationRetry, max(0, budget.remaining - 0.06))
                while candidate?.editable != true, !budget.isCancelled,
                      ProcessInfo.processInfo.systemUptime + 0.05 <= until {
                    Thread.sleep(forTimeInterval: 0.05)
                    candidate = focusedCandidate(owner, point: point, system: system, web: engine.isWeb, budget: budget)
                }
            }
        }

        var result = HostTextFocusResult(editable: false, role: candidate?.role ?? .none, engine: engine,
                                         activation: activation, retried: retried)
        guard let candidate, candidate.editable else { return result }
        result.editable = true

        guard geometry, budget.arm(candidate.element), let frame = frame(of: candidate.element) else { return result }
        let caret = candidate.secure || !budget.arm(candidate.element)
            ? nil : insertionPoint(of: candidate.element, budget: budget)
        result.frame = frame
        result.anchor = caret ?? point
        return result
    }

    /// The owner's focused element, which a click must have landed on. When a Chromium-based app
    /// reports no focus, the editable element under the click stands in for it; a native app that
    /// reports no focus has none.
    private static func focusedCandidate(_ owner: AXUIElement, point: CGPoint?, system: AXUIElement,
                                         web: Bool, budget: HostAXBudget) -> Candidate? {
        guard budget.arm(owner) else { return nil }
        let focused = elementAttribute(owner, kAXFocusedUIElementAttribute)
        guard let point else { return focused.flatMap { classify($0, budget: budget) } }
        guard focused != nil || web else { return nil }

        var hit: AXUIElement?
        guard budget.arm(system),
              AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }

        guard let focused else {
            let root = budget.arm(hit) ? elementAttribute(hit, "AXEditableAncestor") : nil
            return classify(root ?? hit, budget: budget)
        }
        guard let classified = classify(focused, budget: budget) else { return nil }
        guard classified.editable else { return classified }
        return landsOn(focused, hit: hit, budget: budget) ? classified : nil
    }

    private static func landsOn(_ focused: AXUIElement, hit: AXUIElement, budget: HostAXBudget) -> Bool {
        if CFEqual(hit, focused) { return true }
        // Web text sits several levels below its editable root, which Chromium names directly.
        if budget.arm(hit), let root = elementAttribute(hit, "AXEditableAncestor"), CFEqual(root, focused) {
            return true
        }
        var candidate = hit
        // The hit-tested child may be a text run inside the focused editor.
        for _ in 0..<5 {
            guard budget.arm(candidate), let parent = elementAttribute(candidate, kAXParentAttribute) else { return false }
            if CFEqual(parent, focused) { return true }
            candidate = parent
        }
        return false
    }

    private static func classify(_ element: AXUIElement, budget: HostAXBudget, legacy: Bool = true) -> Candidate? {
        guard budget.arm(element), let role = stringAttribute(element, kAXRoleAttribute) else { return nil }
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        let secure = subrole == kAXSecureTextFieldSubrole
        func reject() -> Candidate {
            Candidate(element: element, editable: false,
                      role: HostTextFocusPolicy.roleClass(role: role, subrole: subrole, editable: false), secure: secure)
        }
        let isText = HostTextFocusPolicy.textRoles.contains(role)
        if !legacy, HostTextFocusPolicy.nonTextRoles.contains(role) { return reject() }
        guard !legacy || isText || HostTextFocusPolicy.containerRoles.contains(role) else { return reject() }
        guard budget.arm(element) else { return nil }
        let enabled = boolAttribute(element, kAXEnabledAttribute)
        if enabled == false || (legacy && enabled == nil) { return reject() }
        let editable = boolAttribute(element, kAXIsEditableAttribute)
        let settable = isSettable(element, kAXValueAttribute)
        var selection: Bool?
        var root: Bool?
        if !isText, budget.arm(element) {
            root = elementAttribute(element, "AXEditableAncestor").map { CFEqual($0, element) }
            if root == true, settable != true { selection = isSettable(element, kAXSelectedTextRangeAttribute) }
        }
        let accepted: Bool
        if legacy {
            accepted = HostTextFocusPolicy.isLegacyEditable(role: role, subrole: subrole, enabled: enabled,
                editable: editable, valueSettable: settable, selectionSettable: selection, editableRoot: root)
        } else {
            let selectionPresent = budget.arm(element) && attribute(element, kAXSelectedTextRangeAttribute) != nil
            guard !budget.isExhausted else { return nil }
            guard let answer = HostTextFocusPolicy.editableAnswer(role: role, enabled: enabled,
                editable: editable, valueSettable: settable, selectionSettable: selection,
                editableRoot: root, selectionPresent: selectionPresent) else { return nil }
            accepted = answer
        }
        return Candidate(element: element, editable: accepted,
                         role: HostTextFocusPolicy.roleClass(role: role, subrole: subrole, editable: accepted),
                         secure: secure)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = attribute(element, kAXPositionAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              let extent = attribute(element, kAXSizeAttribute),
              CFGetTypeID(extent) == AXValueGetTypeID(),
              AXValueGetValue(extent as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Reads only the selection's indices and the bounds of an empty or one-character range at it.
    private static func insertionPoint(of element: AXUIElement, budget: HostAXBudget) -> CGPoint? {
        var range = CFRange()
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0 else { return nil }
        let end = range.location + max(0, range.length)
        if budget.arm(element), let caret = bounds(of: element, CFRange(location: end, length: 0)),
           caret.height > 0 {
            return CGPoint(x: caret.minX, y: caret.midY)
        }
        guard end > 0, budget.arm(element),
              let previous = bounds(of: element, CFRange(location: end - 1, length: 1)),
              previous.height > 0 else { return nil }
        return CGPoint(x: previous.maxX, y: previous.midY)
    }

    private static func bounds(of element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        var rect = CGRect.zero
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        return rect
    }

    static func appReportsFocus(pid: pid_t, budget: HostAXBudget) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard budget.arm(app), let focus = elementAttribute(app, kAXFocusedUIElementAttribute),
              budget.arm(focus), let role = stringAttribute(focus, kAXRoleAttribute) else { return false }
        // An application/window placeholder is not an editor's accessible tree.
        return role != kAXApplicationRole && role != kAXWindowRole
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool? {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
        else { return nil }
        return settable.boolValue
    }
}
