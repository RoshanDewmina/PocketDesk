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

/// Uses metadata only. Neither the focused element's value nor its label is requested.
enum HostTextFocusPolicy {
    static func isEditable(role: String?, enabled: Bool?, editable: Bool?, valueSettable: Bool?) -> Bool {
        guard enabled == true, editable != false else { return false }
        switch role {
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole:
            return editable == true || valueSettable == true
        default:
            return false
        }
    }
}

/// What the focus probe learned, in global CoreGraphics points. Geometry only.
struct HostTextFocusResult: Equatable, Sendable {
    var editable: Bool
    var frame: CGRect? = nil
    /// The insertion point when the app exposes it, otherwise the click.
    var anchor: CGPoint? = nil

    static let unfocused = HostTextFocusResult(editable: false)
}

enum HostTextFocusProbe {
    static func isValidID(_ id: String?) -> Bool {
        guard let id, id.utf8.count == 32 else { return false }
        return id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func editableAtClick(_ point: CGPoint) async -> Bool {
        await focus(at: point, geometry: false).editable
    }

    /// `point` is an admitted click, which must land on the focused element. Nil re-checks the focus
    /// after typing, when there is no click to compare.
    static func focus(at point: CGPoint?, geometry: Bool,
                      broker: HostAXBroker = .shared) async -> HostTextFocusResult {
        if let point, !(point.x.isFinite && point.y.isFinite) { return .unfocused }
        return await broker.run { budget in inspect(point, geometry: geometry, budget: budget) } ?? .unfocused
    }

    private static func inspect(_ point: CGPoint?, geometry: Bool, budget: HostAXBudget) -> HostTextFocusResult {
        guard AXIsProcessTrusted() else { return .unfocused }

        let system = AXUIElementCreateSystemWide()
        // Apple documents that the system-wide timeout is process-wide; restore it before leaving.
        guard budget.arm(system) else { return .unfocused }
        defer { _ = AXUIElementSetMessagingTimeout(system, 0) }

        guard let focused = elementAttribute(system, kAXFocusedUIElementAttribute),
              budget.arm(focused),
              let role = stringAttribute(focused, kAXRoleAttribute),
              let enabled = boolAttribute(focused, kAXEnabledAttribute),
              enabled else { return .unfocused }

        let editable = boolAttribute(focused, kAXIsEditableAttribute)
        let settable = valueSettable(focused)
        guard HostTextFocusPolicy.isEditable(role: role, enabled: enabled,
                                             editable: editable, valueSettable: settable) else { return .unfocused }

        if let point {
            var hit: AXUIElement?
            guard budget.arm(system),
                  AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { return .unfocused }
            var candidate = hit
            var matched = false
            // The hit-tested child may be a text run inside the focused editor.
            for _ in 0..<5 {
                if CFEqual(candidate, focused) { matched = true; break }
                guard budget.arm(candidate), let parent = elementAttribute(candidate, kAXParentAttribute) else { break }
                candidate = parent
            }
            guard matched else { return .unfocused }
        }

        guard geometry, budget.arm(focused), let frame = frame(of: focused) else {
            return HostTextFocusResult(editable: true)
        }
        let secure = stringAttribute(focused, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
        let caret = secure || !budget.arm(focused) ? nil : insertionPoint(of: focused, budget: budget)
        return HostTextFocusResult(editable: true, frame: frame, anchor: caret ?? point)
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

    private static func valueSettable(_ element: AXUIElement) -> Bool? {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
        else { return nil }
        return settable.boolValue
    }
}
