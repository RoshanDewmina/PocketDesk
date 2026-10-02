import SwiftUI
import UIKit

/// Transparent input layer placed over the remote desktop, beneath native chrome. Fingers go to
/// the gesture engine; a mouse or trackpad on iPad and a hardware keyboard go to their routers.
struct NativeTrackpadSurface: UIViewRepresentable {
    var enabled: Bool
    var panMode: Bool
    var direct: Bool = false
    var precision: PrecisionTapTrigger = .off
    var revision: UInt64
    var sensitivity: CGFloat
    var pointerScale: CGFloat
    var doubleClickInterval: TimeInterval
    var middleClickAvailable: Bool = false
    var momentumScroll: Bool = false
    var hostMomentum: Bool = false
    /// Physical key presses go to the Mac.
    var hardwareKeys: Bool = false
    /// A mouse or trackpad on iPad places the Mac pointer and clicks.
    var hardwarePointer: Bool = false
    var pencilEnabled: Bool = false
    var onPencil: (CGPoint, PencilFrame) -> Bool = { _, _ in false }
    /// Hold first responder so hardware keys arrive without the on-screen keyboard.
    var keyboardFocus: Bool = false
    var remapShortcuts: Bool = true
    var onCommand: (NativeGestureCommand) -> Bool
    var onPointerMotionEnded: () -> Void
    var onHardwareKey: (String, [String]) -> Bool = { _, _ in false }
    var onHardwareModifiers: ([String]) -> Void = { _ in }
    /// DEBUG probe only: every raw key UIKit delivers, to diagnose keys that never arrive.
    var onKeyDiagnostic: ((String) -> Void)? = nil

    func makeUIView(context: Context) -> NativeTrackpadInputView {
        let view = NativeTrackpadInputView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: NativeTrackpadInputView, context: Context) {
        // Release an old hold against its prior admission context before the
        // callback begins using the new session/geometry state.
        view.engine.configure(enabled: enabled, panMode: panMode, revision: revision,
                              sensitivity: sensitivity, pointerScale: pointerScale,
                              doubleClickInterval: doubleClickInterval, direct: direct,
                              precision: direct ? precision : .off)
        view.pencilInputEnabled = pencilEnabled && enabled
        view.pencil.configure(enabled: view.pencilInputEnabled, revision: revision)
        view.pencil.send = onPencil
        view.engine.onCommand = onCommand
        view.engine.onPointerMotionEnded = onPointerMotionEnded
        view.engine.momentumEnabled = momentumScroll
        view.engine.hostMomentumEnabled = hostMomentum
        view.pointer.onCommand = onCommand
        view.pointer.setEnabled(hardwarePointer)
        view.hardwareKeys = hardwareKeys
        view.keyboard.send = onHardwareKey
        view.keyboard.modifiersChanged = onHardwareModifiers
        view.keyboard.remapEnabled = { remapShortcuts }
        view.keyDiagnostic = onKeyDiagnostic
        view.setHidesSystemPointer(hardwarePointer)
        view.setKeyboardFocus(keyboardFocus)
        if view.window != nil { view.bindPeripheralHandlers() }
        view.updateAccessibility(panMode: panMode, direct: direct, middleClick: middleClickAvailable)
    }
}

final class NativeTrackpadInputView: UIView, UIPointerInteractionDelegate {
    let engine = NativeGestureEngine(enabled: false, panMode: false, revision: 0,
                                     sensitivity: 1, pointerScale: 1,
                                     doubleClickInterval: 0.5, onCommand: { _ in false })
    let pointer = HardwarePointerRouter(onCommand: { _ in false })
    let keyboard = HardwareKeyboardRouter()
    let pencil = PencilContactRouter()
    private var pencilTouch: ObjectIdentifier?
    var pencilInputEnabled = false
    var hardwareKeys = false {
        didSet {
            if !hardwareKeys { keyboard.releaseAll() }
            MacShortcutMenu.set(hardwareKeys && window != nil, for: self)
        }
    }
    var keyDiagnostic: ((String) -> Void)?
    private struct Contact { let id: UInt64; var point: CGPoint }
    private var contacts: [ObjectIdentifier: Contact] = [:]
    private var pointerButtons: [ObjectIdentifier: HardwarePointerRouter.Button] = [:]
    private var nextID: UInt64 = 1
    private var holdTimer: Timer?
    private var wantsKeyboardFocus = false
    private var hidesSystemPointer = false
    private var pointerInteraction: UIPointerInteraction?
    private var lastScrollTranslation = CGPoint.zero
    private var lastPinchScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "Remote desktop trackpad"
        accessibilityHint = "One finger moves the pointer. Two fingers scroll or pinch to zoom. Double tap and hold to drag."
        accessibilityTraits = .button
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Right-click", target: self,
                                        selector: #selector(accessibilityRightClick)),
            UIAccessibilityCustomAction(name: "Double-click", target: self,
                                        selector: #selector(accessibilityDoubleClick))
        ]
        installHardwarePointer()
        NotificationCenter.default.addObserver(self, selector: #selector(interruptInput),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interruptInput),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateAccessibility(panMode: Bool, direct: Bool = false, middleClick: Bool = false) {
        accessibilityLabel = panMode ? "Remote desktop view" : (direct ? "Remote desktop, direct touch" : "Remote desktop trackpad")
        if panMode {
            accessibilityHint = "Drag to move the view. Pinch to zoom. Double-tap to zoom in or fit the whole display."
        } else if direct {
            accessibilityHint = "Tap to click where you touch. Drag, or touch and hold, to click and drag. Two fingers scroll or pinch to zoom."
        } else {
            accessibilityHint = "One finger moves the pointer. Two fingers scroll or pinch to zoom. Three fingers switch Mac workspaces."
        }
        if !panMode && engine.clipboardGesturesEnabled() {
            accessibilityHint = (accessibilityHint ?? "") + " Pinch three fingers to copy from your Mac. Spread three fingers to paste to your Mac."
        }
        var actions = panMode
            ? [UIAccessibilityCustomAction(name: "Zoom view", target: self,
                                           selector: #selector(accessibilityDoubleClick))]
            : [UIAccessibilityCustomAction(name: "Right-click", target: self,
                                           selector: #selector(accessibilityRightClick)),
               UIAccessibilityCustomAction(name: "Double-click", target: self,
                                           selector: #selector(accessibilityDoubleClick))]
        if !panMode && middleClick {
            actions.append(UIAccessibilityCustomAction(name: "Middle-click", target: self,
                                                       selector: #selector(accessibilityMiddleClick)))
        }
        accessibilityCustomActions = actions
    }

    deinit {
        holdTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        MacShortcutMenu.set(hardwareKeys && window != nil, for: self)
        if window == nil {
            interruptInput()
        } else {
            bindPeripheralHandlers()
            claimKeyboardFocus()
        }
    }

    func bindPeripheralHandlers() {
        guard HardwarePeripherals.shared.keyboardFocusAllowed(for: self) else { return }
            HardwarePeripherals.shared.onMiddleButton = { [weak self] pressed in
                guard let self, !pressed else { return }
                self.pointer.middleClick()
            }
            HardwarePeripherals.shared.onAuxiliaryButton = { [weak self] button, pressed in
                guard let self, !pressed else { return }
                self.pointer.auxiliaryClick(button)
            }
            HardwarePeripherals.shared.onKeyboardDisconnect = { [weak self] in self?.keyboard.releaseAll() }
    }

    // MARK: - Hardware keyboard

    override var canBecomeFirstResponder: Bool { HardwarePeripherals.shared.keyboardFocusAllowed(for: self) }

    /// iOS reads this from the first responder. Its three-finger undo/redo swipes, copy/paste
    /// pinches and editing-bar tap would otherwise compete with the Mac's three-finger gestures.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    func setKeyboardFocus(_ wanted: Bool) {
        wantsKeyboardFocus = wanted
        if wanted {
            claimKeyboardFocus()
        } else if isFirstResponder {
            keyboard.releaseAll()
            releaseKeyboardFocus()
        }
    }

    /// Asynchronously too: resigning inside SwiftUI's update asks the hosting view whether it can
    /// become first responder, which re-enters the update graph (20260930.8 scene-update hangs).
    private func releaseKeyboardFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.wantsKeyboardFocus, self.isFirstResponder else { return }
            _ = self.resignFirstResponder()
        }
    }

    /// Asynchronously, so SwiftUI finishes the update (a closing text field) before focus moves.
    private func claimKeyboardFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsKeyboardFocus, self.window != nil, !self.isFirstResponder,
                  HardwarePeripherals.shared.keyboardFocusAllowed(for: self) else { return }
            _ = self.becomeFirstResponder()
        }
    }

    override func resignFirstResponder() -> Bool {
        keyboard.releaseAll()
        return super.resignFirstResponder()
    }

    /// iOS gives Escape to the focus and dismissal systems before any press handler; key commands
    /// with priority on the first responder get it first. The same goes for ⌘W, ⌘M, ⌘Q, ⌘N and ⌘,
    /// once `MacShortcutMenu` has taken them off Farside's iPad menu bar, so they reach the Mac
    /// instead of closing Farside. Shortcuts the system keeps (⌘Tab, ⌘Space, ⌘H) use the ⌃⌥ stand-ins.
    override var keyCommands: [UIKeyCommand]? {
        hardwareKeys ? Self.priorityCommands : nil
    }

    static let priorityCommands: [UIKeyCommand] = {
        let modifiers: [UIKeyModifierFlags] = [.command, .shift, .alternate, .control]
        var combinations: [UIKeyModifierFlags] = [[]]
        for modifier in modifiers { combinations += combinations.map { $0.union(modifier) } }
        var commands = combinations.map { flags in
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: flags, action: #selector(priorityKeyCommand(_:)))
        }
        for input in NativeTrackpadInputView.windowCommandInputs {
            commands.append(UIKeyCommand(input: input, modifierFlags: .command, action: #selector(priorityKeyCommand(_:))))
            commands.append(UIKeyCommand(input: input, modifierFlags: [.command, .shift], action: #selector(priorityKeyCommand(_:))))
            commands.append(UIKeyCommand(input: input, modifierFlags: [.command, .alternate], action: #selector(priorityKeyCommand(_:))))
        }
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }()

    static let windowCommandInputs = ["w", "m", "q", "n", ","]

    /// iPadOS 26's File ▸ Close Window (⌘W) is `performClose:`, sent up the responder chain before
    /// UIKit closes the window. While keys go to the Mac the canvas takes it, so ⌘W closes the Mac's
    /// window, and the menu item says so; otherwise it passes on and closes Farside's window.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        #if DEBUG
        if let command = sender as? UIKeyCommand, let input = command.input?.lowercased(),
           MacShortcutMenu.inputs.contains(input) {
            keyDiagnostic?("can \(NSStringFromSelector(action)) \(input) \(command.modifierFlags.rawValue)")
        }
        #endif
        if action == #selector(UIResponderStandardEditActions.performClose(_:)) { return hardwareKeys }
        return super.canPerformAction(action, withSender: sender)
    }

    override func performClose(_ sender: Any?) {
        keyDiagnostic?("performClose")
        guard hardwareKeys, let usage = HardwareKeyMap.usage(forCharacter: "w") else { return }
        keyboard.commandPressed(usage: usage, flags: (sender as? UIKeyCommand)?.modifierFlags ?? .command)
    }

    override func validate(_ command: UICommand) {
        super.validate(command)
        if command.action == #selector(UIResponderStandardEditActions.performClose(_:)), hardwareKeys {
            command.title = "Close Mac Window"
        }
    }

    @objc private func priorityKeyCommand(_ command: UIKeyCommand) {
        keyDiagnostic?("command \(command.input ?? "nil")")
        guard hardwareKeys, let input = command.input,
              let usage = input == UIKeyCommand.inputEscape ? HardwareKeyMap.escape : HardwareKeyMap.usage(forCharacter: input)
        else { return }
        keyboard.commandPressed(usage: usage, flags: command.modifierFlags)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key, let keyDiagnostic, HardwareKeyMap.name(forHIDUsage: key.keyCode.rawValue) == nil,
               !HardwareKeyMap.isModifier(key.keyCode.rawValue) {
                keyDiagnostic("unmapped 0x\(String(key.keyCode.rawValue, radix: 16)) \(key.charactersIgnoringModifiers.unicodeScalars.map { String($0.value, radix: 16) })")
            }
            guard hardwareKeys, let key = press.key,
                  keyboard.pressBegan(usage: key.keyCode.rawValue, flags: key.modifierFlags, at: press.timestamp)
            else { unhandled.insert(press); continue }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, keyboard.pressEnded(usage: key.keyCode.rawValue, flags: key.modifierFlags)
            else { unhandled.insert(press); continue }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { keyboard.updateModifiers(key.modifierFlags) } }
        super.pressesChanged(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        keyboard.releaseAll()
        super.pressesCancelled(presses, with: event)
    }

    // MARK: - Hardware pointer (iPad)

    private func installHardwarePointer() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(hover)
        let pencilHover = UIHoverGestureRecognizer(target: self, action: #selector(pencilHovered(_:)))
        pencilHover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        addGestureRecognizer(pencilHover)

        // Scroll wheels and two-finger trackpad scrolls only; touches never reach it.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        scroll.cancelsTouchesInView = false
        addGestureRecognizer(scroll)

        // Trackpad pinch arrives as transform events; finger pinches stay with the engine.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.allowedTouchTypes = []
        pinch.cancelsTouchesInView = false
        addGestureRecognizer(pinch)

        let interaction = UIPointerInteraction(delegate: self)
        addInteraction(interaction)
        pointerInteraction = interaction
    }

    func setHidesSystemPointer(_ hidden: Bool) {
        guard hidden != hidesSystemPointer else { return }
        hidesSystemPointer = hidden
        pointerInteraction?.invalidate()
    }

    /// While controlling, only the Mac pointer is visible over the picture.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        hidesSystemPointer ? .hidden() : nil
    }

    @objc private func pencilHovered(_ recognizer: UIHoverGestureRecognizer) {
        guard !engine.hasActiveTouches, !pointer.isPressed, recognizer.state == .began || recognizer.state == .changed else { return }
        let tilt = Self.pencilTilt(altitude: recognizer.altitudeAngle, azimuth: recognizer.azimuthAngle(in: self))
        pencil.hover(at: recognizer.location(in: self), tiltX: tilt.x, tiltY: tilt.y)
    }
    private static func pencilTilt(altitude: CGFloat, azimuth: CGFloat) -> (x: Double, y: Double) {
        (Double(cos(azimuth) * cos(altitude)), Double(sin(azimuth) * cos(altitude)))
    }
    private func pencilValues(_ touch: UITouch) -> (pressure: Double, x: Double, y: Double) {
        let tilt = Self.pencilTilt(altitude: touch.altitudeAngle, azimuth: touch.azimuthAngle(in: self))
        let pressure = touch.maximumPossibleForce > 0 ? min(1, max(0, touch.force / touch.maximumPossibleForce)) : 0
        return (Double(pressure), tilt.x, tilt.y)
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        keyboard.updateModifiers(recognizer.modifierFlags)
        // Apple Pencil hover reports a height above the glass; only a pointer moves the Mac.
        guard recognizer.zOffset == 0, !HardwarePeripherals.shared.pointerIsLocked, pencil.active == nil else { return }
        switch recognizer.state {
        case .began, .changed: pointer.hover(to: recognizer.location(in: self))
        default: break
        }
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        keyboard.updateModifiers(recognizer.modifierFlags)
        let translation = recognizer.translation(in: self)
        switch recognizer.state {
        case .began:
            lastScrollTranslation = translation
            pointer.scroll(CGSize(width: translation.x, height: translation.y), phase: .began)
        case .changed:
            let delta = CGSize(width: translation.x - lastScrollTranslation.x,
                               height: translation.y - lastScrollTranslation.y)
            lastScrollTranslation = translation
            pointer.scroll(delta, phase: .changed)
        case .ended:
            pointer.scroll(.zero, phase: .ended)
        default:
            pointer.scroll(.zero, phase: .cancelled)
        }
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            lastPinchScale = 1
            fallthrough
        case .changed:
            let factor = recognizer.scale / max(lastPinchScale, 0.001)
            lastPinchScale = recognizer.scale
            pointer.pinch(factor: factor, at: point, ended: false)
        default:
            pointer.pinch(factor: 1, at: point, ended: true)
        }
    }

    private func pointerButton(_ event: UIEvent?) -> HardwarePointerRouter.Button {
        event?.buttonMask.contains(.secondary) == true ? .secondary : .primary
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        VideoPresentationProbe.noteUserActivity()
        if let event { keyboard.updateModifiers(event.modifierFlags) }
        for touch in touches where touch.type == .pencil && pencilInputEnabled {
            guard pencilTouch == nil else { continue }
            contacts.removeAll(); engine.update([], at: touch.timestamp, cancelled: true); pointer.cancel()
            let values = pencilValues(touch)
            if pencil.begin(at: touch.location(in: self), pressure: values.pressure, tiltX: values.x, tiltY: values.y) {
                pencilTouch = ObjectIdentifier(touch)
            }
        }
        guard pencil.active == nil, !HardwarePeripherals.shared.pointerIsLocked else { return }
        for touch in touches where touch.type == .indirectPointer {
            let button = pointerButton(event)
            pointerButtons[ObjectIdentifier(touch)] = button
            pointer.down(button, at: touch.location(in: self), count: touch.tapCount, time: touch.timestamp)
        }
        for touch in touches where touch.type == .direct {
            let key = ObjectIdentifier(touch)
            guard contacts[key] == nil else { continue }
            contacts[key] = Contact(id: nextID, point: touch.location(in: self))
            nextID &+= 1
        }
        publish(at: timestamp(touches))
        if (!contacts.isEmpty || pointer.isPressed) && holdTimer == nil {
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
                let now = ProcessInfo.processInfo.systemUptime
                self?.engine.tick(at: now)
                self?.pointer.tick(at: now)
                self?.stopTimerIfIdle()
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        VideoPresentationProbe.noteUserActivity()
        for touch in touches where touch.type == .pencil && ObjectIdentifier(touch) == pencilTouch {
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            // At most24 source samples per callback; the final actual touch is always included.
            let bounded = samples.count <= 24 ? samples : Array(samples.prefix(23)) + [touch]
            for sample in bounded {
                let values = pencilValues(sample)
                _ = pencil.move(to: sample.location(in: self), pressure: values.pressure, tiltX: values.x, tiltY: values.y)
            }
        }
        guard pencil.active == nil, !HardwarePeripherals.shared.pointerIsLocked else { return }
        for touch in touches where touch.type == .indirectPointer {
            pointer.moved(to: touch.location(in: self), time: touch.timestamp)
        }
        refresh(touches)
        publish(at: timestamp(touches))
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        guard pencil.active != nil,
              let touch = touches.first(where: { $0.type == .pencil && ObjectIdentifier($0) == pencilTouch }) else { return }
        let values = pencilValues(touch)
        // An estimated old sample cannot warp the contact back to an earlier position.
        pencil.updatePressure(pressure: values.pressure, tiltX: values.x, tiltY: values.y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first(where: { $0.type == .pencil && ObjectIdentifier($0) == pencilTouch }) {
            pencil.end(at: touch.location(in: self)); pencilTouch = nil
        }
        guard !HardwarePeripherals.shared.pointerIsLocked else { return }
        for touch in touches where touch.type == .indirectPointer {
            let button = pointerButtons.removeValue(forKey: ObjectIdentifier(touch)) ?? .primary
            pointer.up(button, at: touch.location(in: self), time: touch.timestamp)
        }
        refresh(touches)
        let time = timestamp(touches)
        publish(at: time)
        for touch in touches { contacts.removeValue(forKey: ObjectIdentifier(touch)) }
        publish(at: time)
        stopTimerIfIdle()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        pencil.cancel(); pencilTouch = nil
        if touches.contains(where: { $0.type == .indirectPointer }) {
            pointerButtons.removeAll()
            pointer.cancel()
        }
        contacts.removeAll()
        engine.update([], at: timestamp(touches), cancelled: true)
        stopTimerIfIdle()
    }

    override func accessibilityActivate() -> Bool {
        guard !engine.hasActiveTouches else { return false }
        if engine.panMode {
            return engine.onCommand(.zoomToggle(anchor: CGPoint(x: bounds.midX, y: bounds.midY)))
        }
        guard engine.enabled else { return false }
        return engine.onCommand(.click(count: 1))
    }

    @objc private func accessibilityRightClick() -> Bool {
        guard engine.enabled, !engine.panMode, !engine.hasActiveTouches else { return false }
        return engine.onCommand(.secondaryClick)
    }

    @objc private func accessibilityMiddleClick() -> Bool {
        guard engine.enabled, !engine.panMode, !engine.hasActiveTouches else { return false }
        return engine.onCommand(.middleClick)
    }

    @objc private func accessibilityDoubleClick() -> Bool {
        guard !engine.hasActiveTouches else { return false }
        if engine.panMode {
            return engine.onCommand(.zoomToggle(anchor: CGPoint(x: bounds.midX, y: bounds.midY)))
        }
        guard engine.enabled else { return false }
        guard engine.onCommand(.click(count: 1)) else { return false }
        return engine.onCommand(.click(count: 2))
    }

    @objc private func interruptInput() {
        pencil.cancel(); pencilTouch = nil
        contacts.removeAll()
        pointerButtons.removeAll()
        engine.update([], at: ProcessInfo.processInfo.systemUptime, cancelled: true)
        pointer.cancel()
        keyboard.releaseAll()
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func refresh(_ touches: Set<UITouch>) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            if var contact = contacts[key] {
                contact.point = touch.location(in: self)
                contacts[key] = contact
            }
        }
    }

    private func publish(at time: TimeInterval) {
        engine.update(contacts.values.map { .init(id: $0.id, point: $0.point) }, at: time)
    }

    private func timestamp(_ touches: Set<UITouch>) -> TimeInterval {
        touches.map(\.timestamp).max() ?? ProcessInfo.processInfo.systemUptime
    }

    private func stopTimerIfIdle() {
        if contacts.isEmpty && !pointer.isPressed && !engine.hasMomentum {
            holdTimer?.invalidate()
            holdTimer = nil
        }
    }
}
