import SwiftUI
import UIKit

/// Transparent input layer placed over the remote desktop, beneath native chrome.
struct NativeTrackpadSurface: UIViewRepresentable {
    var enabled: Bool
    var panMode: Bool
    var revision: UInt64
    var sensitivity: CGFloat
    var pointerScale: CGFloat
    var doubleClickInterval: TimeInterval
    var onCommand: (NativeGestureCommand) -> Bool
    var onPointerMotionEnded: () -> Void

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
                              doubleClickInterval: doubleClickInterval)
        view.engine.onCommand = onCommand
        view.engine.onPointerMotionEnded = onPointerMotionEnded
        view.updateAccessibility(panMode: panMode)
    }
}

final class NativeTrackpadInputView: UIView {
    let engine = NativeGestureEngine(enabled: false, panMode: false, revision: 0,
                                     sensitivity: 1, pointerScale: 1,
                                     doubleClickInterval: 0.5, onCommand: { _ in false })
    private struct Contact { let id: UInt64; var point: CGPoint }
    private var contacts: [ObjectIdentifier: Contact] = [:]
    private var nextID: UInt64 = 1
    private var holdTimer: Timer?

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
        NotificationCenter.default.addObserver(self, selector: #selector(interruptInput),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interruptInput),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateAccessibility(panMode: Bool) {
        accessibilityLabel = panMode ? "Remote desktop view" : "Remote desktop trackpad"
        accessibilityHint = panMode
            ? "Drag to move the view. Pinch to zoom. Double-tap to zoom in or fit the whole display."
            : "One finger moves the pointer. Two fingers scroll or pinch to zoom. Three fingers switch Mac workspaces."
        accessibilityCustomActions = panMode
            ? [UIAccessibilityCustomAction(name: "Zoom view", target: self,
                                           selector: #selector(accessibilityDoubleClick))]
            : [UIAccessibilityCustomAction(name: "Right-click", target: self,
                                           selector: #selector(accessibilityRightClick)),
               UIAccessibilityCustomAction(name: "Double-click", target: self,
                                           selector: #selector(accessibilityDoubleClick))]
    }

    deinit {
        holdTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { interruptInput() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .direct {
            let key = ObjectIdentifier(touch)
            guard contacts[key] == nil else { continue }
            contacts[key] = Contact(id: nextID, point: touch.location(in: self))
            nextID &+= 1
        }
        publish(at: timestamp(touches))
        if !contacts.isEmpty && holdTimer == nil {
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
                self?.engine.tick(at: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        refresh(touches)
        publish(at: timestamp(touches))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        refresh(touches)
        let time = timestamp(touches)
        publish(at: time)
        for touch in touches { contacts.removeValue(forKey: ObjectIdentifier(touch)) }
        publish(at: time)
        stopTimerIfIdle()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
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
        contacts.removeAll()
        engine.update([], at: ProcessInfo.processInfo.systemUptime, cancelled: true)
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
        if contacts.isEmpty {
            holdTimer?.invalidate()
            holdTimer = nil
        }
    }
}
