import AppKit
import ApplicationServices
import Darwin

/// Whether typing now would go into a password: the focused element is a secure text field, or
/// some app has turned on secure event input (a password prompt, Terminal's Secure Keyboard Entry).
/// Metadata only; the field's value, label and title are never requested.
enum HostSecureFocusPolicy {
    static func isSecure(subrole: String?, secureEventInput: Bool) -> Bool {
        secureEventInput || subrole == kAXSecureTextFieldSubrole
    }

    /// The system-wide focus query intermittently answers cannotComplete (-25204) while the frontmost
    /// app itself answers, so that app is asked next. When neither can say, the field is treated as a
    /// password: a lock shown by mistake costs less than a password revealed or kept in a draft.
    static func resolve(secureEventInput: Bool, systemWide: () -> HostFocusSubrole,
                        frontmost: () -> HostFocusSubrole) -> Bool {
        if secureEventInput { return true }
        var read = systemWide()
        if case .unknown = read { read = frontmost() }
        switch read {
        case .unknown: return true
        case .known(let subrole): return isSecure(subrole: subrole, secureEventInput: false)
        }
    }
}

/// What a focus query learned about the focused element's subrole. Nothing focused, or an element
/// without a subrole, is known; an AX error or timeout is not.
enum HostFocusSubrole: Equatable, Sendable {
    case known(String?)
    case unknown
}

enum HostSecureFocus {
    private static let queue = DispatchQueue(label: "farside.secure-focus", qos: .userInitiated)
    private static let nativeQueryLock = NSLock()
    /// One deadline for every call of a check, so the reply still meets the focus ticket's 1 s window
    /// after the 100 ms settle and the 250 ms probe. Out of time is unknown, and unknown is secure.
    static let budget: TimeInterval = 0.25

    static func isSecureNow() async -> Bool {
        await resolveFocus(secureEventInput: { secureEventInputEnabled() })
    }

    private static func resolveFocus(secureEventInput: @escaping @Sendable () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let budget = HostAXBudget(total: budget)
                continuation.resume(returning: HostSecureFocusPolicy.resolve(
                    secureEventInput: secureEventInput(),
                    systemWide: { focusedSubrole(of: AXUIElementCreateSystemWide(), budget: budget) },
                    frontmost: {
                        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return .unknown }
                        return focusedSubrole(of: AXUIElementCreateApplication(pid), budget: budget)
                    }))
            }
        }
    }

    /// Public CarbonEventsCore.h declares this API "Not thread safe", not main-thread-only.
    static func secureEventInputEnabled() -> Bool {
        guard let function = isSecureEventInputEnabled else { return false }
        return querySecureEventInput { function() != 0 }
    }

    /// The native API is not thread safe. Busy means conservatively secure for this check;
    /// never block a direct caller behind an earlier native query with no completion deadline.
    /// Only the native call owns this lock, so cancellation cannot admit an overlapping query.
    private static func querySecureEventInput(_ query: () -> Bool) -> Bool {
        guard nativeQueryLock.try() else { return true }
        defer { nativeQueryLock.unlock() }
        return query()
    }

    #if DEBUG
    /// Per-call fixtures share the production queue, policy and query boundary without replacing
    /// process-global state. True fixture answers short-circuit real Accessibility inspection.
    static func isSecureNow(query: @escaping @Sendable () -> Bool) async -> Bool {
        await resolveFocus(secureEventInput: { secureEventInputEnabled(query: query) })
    }

    static func secureEventInputEnabled(query: () -> Bool) -> Bool {
        querySecureEventInput(query)
    }

    #endif

    private typealias SecureEventInputQuery = @convention(c) () -> UInt8

    private static let isSecureEventInputEnabled: SecureEventInputQuery? = {
        let symbol = "IsSecureEventInputEnabled"
        let path = "/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox"
        let address = dlopen(path, RTLD_LAZY | RTLD_LOCAL).flatMap { dlsym($0, symbol) }
            ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol)
        return address.map { unsafeBitCast($0, to: SecureEventInputQuery.self) }
    }()

    /// Chromium password fields also turn on secure event input, which covers a web app whose tree
    /// is not built yet and so reports nothing focused.
    private static func focusedSubrole(of owner: AXUIElement, budget: HostAXBudget) -> HostFocusSubrole {
        guard AXIsProcessTrusted() else { return .unknown }
        guard budget.arm(owner) else { return .unknown }
        // The system-wide element's timeout is process-wide; restore it before leaving.
        defer { _ = AXUIElementSetMessagingTimeout(owner, 0) }
        var focused: CFTypeRef?
        switch AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &focused) {
        case .success: break
        case .noValue: return .known(nil)
        default: return .unknown
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unknown }
        let element = focused as! AXUIElement
        guard budget.arm(element) else { return .unknown }
        var subrole: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) {
        case .success: return .known(subrole as? String)
        case .noValue, .attributeUnsupported: return .known(nil)
        default: return .unknown
        }
    }
}
