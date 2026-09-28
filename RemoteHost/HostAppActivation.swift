import AppKit

enum HostWindowID {
    static let setup = "setup"
    static let setupTitle = "Set Up PocketDesk"
}

/// PocketDesk Host is an LSUIElement menu bar utility. It becomes a regular app (Dock icon,
/// Command-Tab) only while its setup or Settings window is open, so those windows can take focus.
@MainActor
final class HostAppActivation {
    static let shared = HostAppActivation()
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in HostAppActivation.shared.updatePolicy() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = note.object as? NSWindow
            Task { @MainActor in HostAppActivation.shared.updatePolicy(excluding: closing) }
        })
    }

    func bringForward() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    func updatePolicy(excluding closing: NSWindow? = nil) {
        let hasAppWindow = NSApp.windows.contains { window in
            window !== closing && window.isVisible && Self.isAppWindow(window)
        }
        let policy: NSApplication.ActivationPolicy = hasAppWindow ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// Used when the app is reopened from Finder or Spotlight and no SwiftUI view is on screen
    /// to provide openWindow or openSettings.
    func showSetupOrSettings(needsSetup: Bool) {
        bringForward()
        let menu = NSApp.mainMenu
        if needsSetup, let item = Self.item(in: menu, where: { $0.title == HostWindowID.setupTitle }) {
            item.menu?.performActionForItem(at: item.menu?.index(of: item) ?? 0)
        } else if let item = Self.item(in: menu, where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
            item.menu?.performActionForItem(at: item.menu?.index(of: item) ?? 0)
        }
    }

    private static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel) && window.level == .normal
    }

    private static func item(in menu: NSMenu?, where matches: (NSMenuItem) -> Bool) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if matches(item) { return item }
            if let found = self.item(in: item.submenu, where: matches) { return found }
        }
        return nil
    }
}
