import AppKit
import ApplicationServices

/// A response may only describe the last accepted click in the current live input session.
struct HostTextFocusTicket {
    let epoch: UInt64
    let revision: UInt64
    let issuedAt: TimeInterval

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

    static func isEditable(role: String?, subrole: String? = nil, enabled: Bool?, editable: Bool?,
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

    static let unfocused = HostTextFocusResult(editable: false)
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
                      activator: HostAXWebActivator = .shared) async -> HostTextFocusResult {
        if let point, !(point.x.isFinite && point.y.isFinite) { return .unfocused }
        return await broker.run(waitForLane: lanePatience) { budget in
            inspect(point, geometry: geometry, budget: budget, activator: activator)
        } ?? HostTextFocusResult(editable: false, dropped: true)
    }

    private struct Candidate {
        let element: AXUIElement
        let editable: Bool
        let role: HostTextRoleClass
        let secure: Bool
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

    private static func classify(_ element: AXUIElement, budget: HostAXBudget) -> Candidate? {
        guard budget.arm(element), let role = stringAttribute(element, kAXRoleAttribute) else { return nil }
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        let secure = subrole == kAXSecureTextFieldSubrole
        func reject() -> Candidate {
            Candidate(element: element, editable: false,
                      role: HostTextFocusPolicy.roleClass(role: role, subrole: subrole, editable: false), secure: secure)
        }
        let isText = HostTextFocusPolicy.textRoles.contains(role)
        guard isText || HostTextFocusPolicy.containerRoles.contains(role) else { return reject() }
        guard budget.arm(element), let enabled = boolAttribute(element, kAXEnabledAttribute), enabled else { return reject() }
        let editable = boolAttribute(element, kAXIsEditableAttribute)
        let settable = isSettable(element, kAXValueAttribute)
        var selection: Bool?
        var root: Bool?
        if !isText, budget.arm(element) {
            root = elementAttribute(element, "AXEditableAncestor").map { CFEqual($0, element) }
            if root == true, settable != true { selection = isSettable(element, kAXSelectedTextRangeAttribute) }
        }
        let accepted = HostTextFocusPolicy.isEditable(role: role, subrole: subrole, enabled: enabled, editable: editable,
                                                      valueSettable: settable, selectionSettable: selection,
                                                      editableRoot: root)
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
