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
}

enum HostSecureFocus {
    private static let queue = DispatchQueue(label: "farside.secure-focus", qos: .userInitiated)
    private static let timeout: Float = 0.12

    static func isSecureNow() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: HostSecureFocusPolicy.isSecure(subrole: focusedSubrole(),
                                                                              secureEventInput: secureEventInputEnabled()))
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

    private static func focusedSubrole() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementSetMessagingTimeout(system, timeout) == .success else { return nil }
        defer { _ = AXUIElementSetMessagingTimeout(system, 0) }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        guard AXUIElementSetMessagingTimeout(element, timeout) == .success else { return nil }
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success else { return nil }
        return subrole as? String
    }
}
