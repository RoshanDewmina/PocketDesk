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

enum HostTextFocusProbe {
    private static let queue = DispatchQueue.global(qos: .userInitiated)
    private static let inFlight = DispatchSemaphore(value: 1)
    private static let timeout: Float = 0.12

    private final class CancellationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    static func isValidID(_ id: String?) -> Bool {
        guard let id, id.utf8.count == 32 else { return false }
        return id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func editableAtClick(_ point: CGPoint) async -> Bool {
        let cancellation = CancellationBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled,
                          inFlight.wait(timeout: .now()) == .success else {
                        continuation.resume(returning: false)
                        return
                    }
                    defer { inFlight.signal() }
                    let result = cancellation.isCancelled ? false : inspect(point)
                    continuation.resume(returning: !cancellation.isCancelled && result)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func inspect(_ point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite, AXIsProcessTrusted() else { return false }

        let system = AXUIElementCreateSystemWide()
        // Apple documents that the system-wide timeout is process-wide; restore it before leaving.
        guard AXUIElementSetMessagingTimeout(system, timeout) == .success else { return false }
        defer { _ = AXUIElementSetMessagingTimeout(system, 0) }

        guard let focused = elementAttribute(system, kAXFocusedUIElementAttribute),
              AXUIElementSetMessagingTimeout(focused, timeout) == .success,
              let role = stringAttribute(focused, kAXRoleAttribute),
              let enabled = boolAttribute(focused, kAXEnabledAttribute),
              enabled else { return false }

        let editable = boolAttribute(focused, kAXIsEditableAttribute)
        let settable = valueSettable(focused)
        guard HostTextFocusPolicy.isEditable(role: role, enabled: enabled,
                                             editable: editable, valueSettable: settable) else { return false }

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return false }
        var candidate = hit
        // The hit-tested child may be a text run inside the focused editor.
        for _ in 0..<5 {
            if CFEqual(candidate, focused) { return true }
            guard let parent = elementAttribute(candidate, kAXParentAttribute) else { break }
            candidate = parent
        }
        return false
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
