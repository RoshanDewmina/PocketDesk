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
    private static let timeout: Float = 0.12

    static func isSecureNow() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: HostSecureFocusPolicy.resolve(
                    secureEventInput: secureEventInputEnabled(),
                    systemWide: { focusedSubrole(of: AXUIElementCreateSystemWide()) },
                    frontmost: {
                        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return .unknown }
                        return focusedSubrole(of: AXUIElementCreateApplication(pid))
                    }))
            }
        }
    }

    /// Carbon's `IsSecureEventInputEnabled` is exported by HIToolbox, but the SDK ships no header for it.
    static func secureEventInputEnabled() -> Bool {
        guard let function = isSecureEventInputEnabled else { return false }
        return function() != 0
    }

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
    private static func focusedSubrole(of owner: AXUIElement) -> HostFocusSubrole {
        guard AXIsProcessTrusted() else { return .unknown }
        guard AXUIElementSetMessagingTimeout(owner, timeout) == .success else { return .unknown }
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
        guard AXUIElementSetMessagingTimeout(element, timeout) == .success else { return .unknown }
        var subrole: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) {
        case .success: return .known(subrole as? String)
        case .noValue, .attributeUnsupported: return .known(nil)
        default: return .unknown
        }
    }
}
