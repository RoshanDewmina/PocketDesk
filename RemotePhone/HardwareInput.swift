import SwiftUI
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

    private var repeatState: HardwareKeyRepeat
    private var repeatTimer: Timer?
    private let now: () -> TimeInterval
    private let schedulesRepeats: Bool
    private let repeatRechordEnabled: Bool
    private(set) var heldModifiers: [String] = []
    private var capsLockOn = false

    init(repeatRechordEnabled: Bool = PocketDeskRepeatRechordSwitch.isOn,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedulesRepeats: Bool = true) {
        self.repeatRechordEnabled = repeatRechordEnabled
        self.repeatState = HardwareKeyRepeat(rechordEnabled: repeatRechordEnabled)
        self.now = now
        self.schedulesRepeats = schedulesRepeats
    }

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
        capsLockOn = false
    }

    func updateModifiers(_ flags: UIKeyModifierFlags) {
        let names = Self.names(for: flags)
        let hasChanged = names != heldModifiers
        let capsLockChanged = flags.contains(.alphaShift) != capsLockOn
        capsLockOn = flags.contains(.alphaShift)

        if repeatRechordEnabled {
            guard hasChanged || capsLockChanged else { return }
            if let usage = repeatState.heldUsage, let name = HardwareKeyMap.name(forHIDUsage: usage) {
                let modifiers = HardwareKeyMap.modifiers(Set(names), capsLock: capsLockOn, for: name)
                let chord = ShortcutRemap.resolve(key: name, modifiers: modifiers, enabled: remapEnabled())
                repeatState.rechord(key: chord.key, modifiers: chord.modifiers, at: now())
            }
            if repeatState.isRepeating { startTimerIfNeeded() } else { stopTimerIfIdle() }
        } else {
            // Keep the exact legacy switch-off rule: only changes to reported modifier names
            // cancel repeat. Caps Lock was not part of heldModifiers before rechording existed.
            guard hasChanged else { return }
            repeatState.cancel()
            stopTimerIfIdle()
        }

        heldModifiers = names
        if hasChanged { modifiersChanged(names) }
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
        guard schedulesRepeats, repeatState.isRepeating, repeatTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireRepeat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    func fireRepeat(at time: TimeInterval? = nil) {
        if let due = repeatState.due(at: time ?? now()), !send(due.key, due.modifiers) {
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

/// iPadOS 26 gives Farside a menu bar whose Close Window (⌘W), Minimize (⌘M), Quit (⌘Q), New
/// Window (⌘N) and Settings (⌘,) shortcuts are resolved before any key command, so a Mac user's
/// ⌘W would close Farside. While a session canvas sends hardware keys to the Mac, those menu items
/// stay in the menu bar but give up their shortcuts, which then reach the canvas and the Mac.
@MainActor
enum MacShortcutMenu {
    static let inputs = ["w", "m", "q", "n", ","]
    static let modifierSets: [UIKeyModifierFlags] = [.command, [.command, .shift], [.command, .alternate]]

    private static var owners = Set<ObjectIdentifier>()
    private static var installed = false

    static var isActive: Bool { !owners.isEmpty }

    #if DEBUG
    /// Offline input probe: which of these shortcuts the built menu held, to verify on a simulator.
    static var debugNote: ((String) -> Void)?
    #endif

    static func set(_ active: Bool, for owner: AnyObject) {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let wasActive = isActive
        if active { owners.insert(ObjectIdentifier(owner)) } else { owners.remove(ObjectIdentifier(owner)) }
        guard isActive != wasActive else { return }
        if installed {
            UIMainMenuSystem.shared.setNeedsRebuild()
        } else if isActive {
            // Installed on first use only, so Farside's menus are untouched until a session wants keys.
            installed = true
            UIMainMenuSystem.shared.setBuildConfiguration(UIMainMenuSystem.Configuration()) { builder in
                MainActor.assumeIsolated {
                    // A build handler replaces the app's own buildMenu(with:); keep SwiftUI's.
                    (UIApplication.shared.delegate as? UIResponder)?.buildMenu(with: builder)
                    #if DEBUG
                    if let debugNote, let root = builder.menu(for: .root) {
                        let held = shortcuts(in: root).map {
                            "\($0.title) \($0.input ?? "") \($0.modifierFlags.rawValue) \($0.action.map(NSStringFromSelector) ?? "-")"
                        }
                        debugNote("menu \(isActive ? "releases" : "keeps") [\(held.joined(separator: "; "))]")
                    }
                    #endif
                    if isActive { releaseShortcuts(in: builder) }
                }
            }
        }
    }

    static func releasesShortcut(_ command: UIKeyCommand) -> Bool {
        guard let input = command.input?.lowercased() else { return false }
        return inputs.contains(input) && modifierSets.contains(command.modifierFlags)
    }

    /// Every command in a menu tree whose shortcut the Mac should get.
    static func shortcuts(in element: UIMenuElement) -> [UIKeyCommand] {
        if let menu = element as? UIMenu { return menu.children.flatMap(shortcuts) }
        guard let command = element as? UIKeyCommand, releasesShortcut(command) else { return [] }
        return [command]
    }

    /// The same menu with the Mac's shortcuts removed from its commands; everything else unchanged.
    static func releasing(_ element: UIMenuElement) -> UIMenuElement {
        if let menu = element as? UIMenu { return menu.replacingChildren(menu.children.map(releasing)) }
        guard let command = element as? UIKeyCommand, releasesShortcut(command), let action = command.action
        else { return element }
        return UICommand(title: command.title, image: command.image, action: action,
                         propertyList: command.propertyList, alternates: command.alternates,
                         discoverabilityTitle: command.discoverabilityTitle,
                         attributes: command.attributes, state: command.state)
    }

    private static func releaseShortcuts(in builder: any UIMenuBuilder) {
        guard let root = builder.menu(for: .root) else { return }
        for case let menu as UIMenu in root.children {
            builder.replaceChildren(ofMenu: menu.identifier) { $0.map(releasing) }
        }
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
    var onAuxiliaryButton: (_ button: AuxiliaryMouseButton, _ pressed: Bool) -> Void = { _, _ in }
    private var lockedOwner: ObjectIdentifier?
    private var lockedGeneration: UInt64 = 0
    private var lockedGate: () -> Bool = { false }
    private var lockedMove: (Double, Double) -> Void = { _, _ in }
    private var lockedButton: (String, Bool) -> Void = { _, _ in }
    private var lockedLost: () -> Void = {}
    private var lockedKeyboardOwner: ObjectIdentifier?
    private var lockedKeyboardDisconnect: () -> Void = {}
    func keyboardFocusAllowed(for owner: AnyObject) -> Bool { lockedOwner == nil || lockedKeyboardOwner == ObjectIdentifier(owner) }
    func deliverKeyboardDisconnect() { if lockedOwner != nil { lockedKeyboardDisconnect() } else { onKeyboardDisconnect() } }
    var pointerIsLocked: Bool { lockedOwner != nil && lockedGate() }
    @discardableResult
    func claimLockedMouse(owner: AnyObject, gate: @escaping () -> Bool,
                          move: @escaping (Double, Double) -> Void,
                          button: @escaping (String, Bool) -> Void, lost: @escaping () -> Void,
                          keyboardOwner: AnyObject? = nil, keyboardDisconnect: @escaping () -> Void = {}) -> UInt64 {
        lockedLost()
        lockedGeneration &+= 1; lockedOwner = ObjectIdentifier(owner)
        lockedGate = gate; lockedMove = move; lockedButton = button; lockedLost = lost
        lockedKeyboardOwner = keyboardOwner.map(ObjectIdentifier.init); lockedKeyboardDisconnect = keyboardDisconnect
        attachMice(); return lockedGeneration
    }
    func releaseLockedMouse(owner: AnyObject, generation: UInt64) {
        guard lockedOwner == ObjectIdentifier(owner), lockedGeneration == generation else { return }
        lockedGeneration &+= 1; lockedOwner = nil
        lockedGate = { false }; lockedMove = { _, _ in }; lockedButton = { _, _ in }; lockedLost = {}
        lockedKeyboardOwner = nil; lockedKeyboardDisconnect = {}
        attachMice()
    }
    func deliverLockedMove(x: Double, y: Double, generation: UInt64) {
        guard lockedGeneration == generation, pointerIsLocked else { return }
        lockedMove(x, y)
    }
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardConnected = true }
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyboardConnected = GCKeyboard.coalesced != nil
                self?.deliverKeyboardDisconnect()
            }
        })
        for name in [Notification.Name.GCMouseDidConnect, .GCMouseDidBecomeCurrent] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attachMice() }
            })
        }
        observers.append(center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseConnected = !GCMouse.mice().isEmpty; self?.lockedLost() }
        })
        attachMice()
    }

    private func attachMice() {
        mouseConnected = !GCMouse.mice().isEmpty
        for mouse in GCMouse.mice() {
            mouse.handlerQueue = .main
            let generation = lockedGeneration
            mouse.mouseInput?.mouseMovedHandler = { [weak self] _, x, y in
                MainActor.assumeIsolated {
                    self?.deliverLockedMove(x: Double(x), y: Double(y), generation: generation)
                }
            }
            mouse.mouseInput?.leftButton.pressedChangedHandler = { [weak self] _, _, down in
                MainActor.assumeIsolated {
                    guard let self, self.lockedGeneration == generation, self.pointerIsLocked else { return }
                    self.lockedButton("primary", down)
                }
            }
            mouse.mouseInput?.rightButton?.pressedChangedHandler = { [weak self] _, _, down in
                MainActor.assumeIsolated {
                    guard let self, self.lockedGeneration == generation, self.pointerIsLocked else { return }
                    self.lockedButton("secondary", down)
                }
            }
            mouse.mouseInput?.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated {
                    guard let self, self.lockedGeneration == generation else { return }
                    if self.pointerIsLocked { self.lockedButton("middle", pressed) }
                    else { self.onMiddleButton(pressed) }
                }
            }
            for (index, input) in (mouse.mouseInput?.auxiliaryButtons ?? []).enumerated() {
                guard let button = AuxiliaryMouseButton(auxiliaryIndex: index) else { continue }
                input.pressedChangedHandler = { [weak self] _, _, pressed in
                    MainActor.assumeIsolated {
                        guard let self, self.lockedGeneration == generation else { return }
                        if self.pointerIsLocked { self.lockedButton(button.rawValue, pressed) }
                        else { self.onAuxiliaryButton(button, pressed) }
                    }
                }
            }
        }
    }
}

/// Phone-side surfaces that own typing while they are on screen: a sheet's text field, the
/// recognized-text editor, a system picker's search. They live outside the session view's own
/// state, so without this the canvas keeps forwarding hardware keys and re-takes first responder
/// on every SwiftUI update, sending the user's typing to the Mac.
@MainActor
final class PhoneTypingClaims: ObservableObject {
    static let shared = PhoneTypingClaims()

    @Published private(set) var active = false
    private var owners: Set<UUID> = []

    func set(_ owns: Bool, owner: UUID) {
        if owns { owners.insert(owner) } else { owners.remove(owner) }
        if active != !owners.isEmpty { active = !owners.isEmpty }
    }
}

private struct PhoneTypingOwner: ViewModifier {
    let claims: PhoneTypingClaims
    let owns: Bool
    @State private var owner = UUID()
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; claims.set(owns, owner: owner) }
            .onChange(of: owns) { _, now in claims.set(now && visible, owner: owner) }
            .onDisappear { visible = false; claims.set(false, owner: owner) }
    }
}

extension View {
    func ownsPhoneTyping(_ owns: Bool = true, claims: PhoneTypingClaims = .shared) -> some View {
        modifier(PhoneTypingOwner(claims: claims, owns: owns))
    }
}
