import Foundation
import CoreGraphics

/// A mouse or trackpad on iPad, in "Follow" mode: the Mac pointer goes wherever the iPad pointer
/// is over the picture (the iPad's own pointer is hidden there). Buttons press where the pointer
/// is, scrolling passes through with its phases, and a trackpad pinch zooms the view locally.
///
/// Emits the same commands as touches, in canvas coordinates, so one path maps and sends them.
/// Deterministic and clock-injected so it can be tested without UIKit.
final class HardwarePointerRouter {
    enum Button: Equatable { case primary, secondary }
    enum ScrollPhase: Equatable { case began, changed, ended, cancelled }

    /// Pointer travel with the primary button down that turns a click into a drag.
    static let dragSlop: CGFloat = 3
    /// Holding the primary button still this long presses it on the Mac, so press-and-hold
    /// menus (Dock, toolbar buttons) open.
    static let holdDelay: TimeInterval = 0.35

    var onCommand: (NativeGestureCommand) -> Bool
    private(set) var enabled = false

    private var pressed: Button?
    private var pressPoint = CGPoint.zero
    private var pressTime: TimeInterval = 0
    private var pressCount = 1
    private var lastPoint: CGPoint?
    private var dragID: String?
    private var scrollID: String?
    private var zooming = false

    init(onCommand: @escaping (NativeGestureCommand) -> Bool) {
        self.onCommand = onCommand
    }

    var isPressed: Bool { pressed != nil }

    /// Losing control (view only, a sheet, background) ends anything held, exactly once.
    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        if !enabled { cancel() }
        self.enabled = enabled
    }

    /// The pointer moved with no button down.
    func hover(to point: CGPoint) {
        guard enabled, pressed == nil, point != lastPoint else { return }
        if onCommand(.pointTo(point)) { lastPoint = point }
    }

    /// `count` is UIKit's click count for this press (2 for the second click of a double click).
    func down(_ button: Button, at point: CGPoint, count: Int, time: TimeInterval) {
        guard enabled, pressed == nil else { return }
        // Put the pointer exactly under the press first; outside the picture nothing is pressed.
        guard onCommand(.pointTo(point)) else { return }
        lastPoint = point
        pressed = button
        pressPoint = point
        pressTime = time
        pressCount = min(max(count, 1), 3)
    }

    func moved(to point: CGPoint, time: TimeInterval) {
        guard enabled, let pressed else { return hover(to: point) }
        guard pressed == .primary else { return }
        if dragID == nil {
            guard hypot(point.x - pressPoint.x, point.y - pressPoint.y) > Self.dragSlop else { return }
            beginDrag()
        }
        guard dragID != nil, point != lastPoint else { return }
        lastPoint = point
        _ = onCommand(.pointTo(point))
    }

    func up(_ button: Button, at point: CGPoint, time: TimeInterval) {
        guard enabled, let pressed, pressed == button else { return }
        self.pressed = nil
        if let id = dragID {
            if point != lastPoint { lastPoint = point; _ = onCommand(.pointTo(point)) }
            dragID = nil
            _ = onCommand(.dragEnded(id: id))
            return
        }
        switch button {
        case .primary: _ = onCommand(.click(count: pressCount))
        case .secondary: _ = onCommand(.secondaryClick)
        }
    }

    /// Call while the primary button is held so a still press becomes a hold.
    func tick(at time: TimeInterval) {
        guard enabled, pressed == .primary, dragID == nil, time - pressTime >= Self.holdDelay else { return }
        beginDrag()
    }

    /// The middle button (from GameController): a middle click where the pointer is.
    func middleClick() {
        guard enabled, pressed == nil else { return }
        _ = onCommand(.middleClick)
    }

    func scroll(_ delta: CGSize, phase: ScrollPhase) {
        guard enabled, pressed == nil else { return }
        switch phase {
        case .began:
            finishScroll(cancelled: true)
            let id = UUID().uuidString
            if onCommand(.scroll(delta: delta, phase: "began", stream: id)) { scrollID = id }
        case .changed:
            guard let id = scrollID, delta != .zero else { return }
            _ = onCommand(.scroll(delta: delta, phase: "changed", stream: id))
        case .ended:
            finishScroll(cancelled: false)
        case .cancelled:
            finishScroll(cancelled: true)
        }
    }

    /// A trackpad pinch zooms the picture on the iPad, never the Mac app.
    func pinch(factor: CGFloat, at point: CGPoint, ended: Bool) {
        if factor.isFinite, factor > 0, abs(factor - 1) > 0.0001, !ended {
            zooming = true
            _ = onCommand(.zoom(factor: factor, anchor: point))
        }
        if ended && zooming {
            zooming = false
            _ = onCommand(.zoomEnded)
        }
    }

    func cancel() {
        finishScroll(cancelled: true)
        if let id = dragID {
            dragID = nil
            _ = onCommand(.dragEnded(id: id))
        }
        pressed = nil
        lastPoint = nil
        if zooming {
            zooming = false
            _ = onCommand(.zoomEnded)
        }
    }

    private func beginDrag() {
        let id = UUID().uuidString
        // The host continues a double click into a drag only at the same place, like a Mac.
        if onCommand(.dragBegan(id: id, count: min(pressCount, 2))) {
            dragID = id
        } else {
            pressed = nil
        }
    }

    private func finishScroll(cancelled: Bool) {
        guard let id = scrollID else { return }
        scrollID = nil
        _ = onCommand(.scroll(delta: .zero, phase: cancelled ? "cancelled" : "ended", stream: id))
    }
}
