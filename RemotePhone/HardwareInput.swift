import UIKit
import GameController

/// Physical key presses from a keyboard attached to the iPhone or iPad, sent to the Mac by key
/// position with the held modifiers. Only while the session canvas is the first responder: when
/// the keyboard bar's text field is focused, typing goes into the local draft instead, so a key
/// never reaches the Mac twice.
@MainActor
final class HardwareKeyboardRouter {
    /// Sends one key press (down and up) to the Mac. Returns false if it was not sent.
    var send: (_ key: String, _ modifiers: [String]) -> Bool = { _, _ in false }
    /// Hardware modifiers currently held, for ⌘-click and friends.
    var modifiersChanged: (_ modifiers: [String]) -> Void = { _ in }
    var remapEnabled: () -> Bool = { true }

    private var repeatState = HardwareKeyRepeat()
    private var repeatTimer: Timer?
    private(set) var heldModifiers: [String] = []

    /// Returns true when the press was for the Mac (handled), false to let UIKit have it.
    func pressBegan(usage: Int, flags: UIKeyModifierFlags, at time: TimeInterval) -> Bool {
        updateModifiers(flags)
        if HardwareKeyMap.isModifier(usage) || usage == HardwareKeyMap.capsLock { return true }
        guard let name = HardwareKeyMap.name(forHIDUsage: usage) else { return false }
        let modifiers = HardwareKeyMap.modifiers(Set(heldModifiers), capsLock: flags.contains(.alphaShift), for: name)
        let chord = ShortcutRemap.resolve(key: name, modifiers: modifiers, enabled: remapEnabled())
        guard send(chord.key, chord.modifiers) else {
            repeatState.cancel()
            stopTimerIfIdle()
            return true
        }
        repeatState.pressed(usage: usage, key: chord.key, modifiers: chord.modifiers, at: time)
        startTimerIfNeeded()
        return true
    }

    /// A key UIKit hands over as a key command (Escape) rather than a press: sent once, never
    /// repeated, because its release may never be reported.
    func commandPressed(usage: Int, flags: UIKeyModifierFlags) {
        guard let name = HardwareKeyMap.name(forHIDUsage: usage) else { return }
        let modifiers = HardwareKeyMap.modifiers(Set(Self.names(for: flags)), capsLock: false, for: name)
        let chord = ShortcutRemap.resolve(key: name, modifiers: modifiers, enabled: remapEnabled())
        _ = send(chord.key, chord.modifiers)
    }

    func pressEnded(usage: Int, flags: UIKeyModifierFlags) -> Bool {
        updateModifiers(flags)
        repeatState.released(usage: usage)
        stopTimerIfIdle()
        return HardwareKeyMap.isModifier(usage) || usage == HardwareKeyMap.capsLock
            || HardwareKeyMap.name(forHIDUsage: usage) != nil
    }

    /// Focus moved away, the keyboard disconnected, the app resigned: nothing may keep repeating.
    func releaseAll() {
        repeatState.cancel()
        stopTimerIfIdle()
        if !heldModifiers.isEmpty {
            heldModifiers = []
            modifiersChanged([])
        }
    }

    func updateModifiers(_ flags: UIKeyModifierFlags) {
        let names = Self.names(for: flags)
        guard names != heldModifiers else { return }
        heldModifiers = names
        modifiersChanged(names)
    }

    static func names(for flags: UIKeyModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.alternate) { names.append("option") }
        if flags.contains(.control) { names.append("control") }
        return names
    }

    private func startTimerIfNeeded() {
        guard repeatState.isRepeating, repeatTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireRepeat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func fireRepeat() {
        if let due = repeatState.due(at: ProcessInfo.processInfo.systemUptime), !send(due.key, due.modifiers) {
            repeatState.cancel()
        }
        stopTimerIfIdle()
    }

    private func stopTimerIfIdle() {
        guard !repeatState.isRepeating else { return }
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

/// Keyboard and mouse connection state from GameController, which also carries the mouse's
/// middle button (UIKit reports only primary and secondary). One instance, because each mouse
/// has a single middle-button handler.
@MainActor
final class HardwarePeripherals: ObservableObject {
    static let shared = HardwarePeripherals()

    @Published private(set) var keyboardConnected = GCKeyboard.coalesced != nil
    @Published private(set) var mouseConnected = !GCMouse.mice().isEmpty
    var onKeyboardDisconnect: () -> Void = {}
    var onMiddleButton: (_ pressed: Bool) -> Void = { _ in }
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardConnected = true }
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyboardConnected = GCKeyboard.coalesced != nil
                self?.onKeyboardDisconnect()
            }
        })
        for name in [Notification.Name.GCMouseDidConnect, .GCMouseDidBecomeCurrent] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attachMice() }
            })
        }
        observers.append(center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseConnected = !GCMouse.mice().isEmpty }
        })
        attachMice()
    }

    private func attachMice() {
        mouseConnected = !GCMouse.mice().isEmpty
        for mouse in GCMouse.mice() {
            mouse.handlerQueue = .main
            mouse.mouseInput?.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { self?.onMiddleButton(pressed) }
            }
        }
    }
}
