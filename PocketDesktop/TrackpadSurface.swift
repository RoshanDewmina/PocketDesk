import SwiftUI
import UIKit

/// A relative-input surface. Movement is measured in local view points.
struct TrackpadSurface: UIViewRepresentable {
    var onMove: (CGSize) -> Void
    var onScroll: (CGSize) -> Void
    var onClick: () -> Void
    var onRightClick: () -> Void

    func makeUIView(context: Context) -> TrackpadInputView {
        let view = TrackpadInputView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: TrackpadInputView, context: Context) {
        view.onMove = onMove
        view.onScroll = onScroll
        view.onClick = onClick
        view.onRightClick = onRightClick
    }
}

final class TrackpadInputView: UIView {
    var onMove: (CGSize) -> Void = { _ in }
    var onScroll: (CGSize) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onRightClick: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true

        let movement = UIPanGestureRecognizer(target: self, action: #selector(movePointer(_:)))
        movement.minimumNumberOfTouches = 1
        movement.maximumNumberOfTouches = 1

        let scrolling = UIPanGestureRecognizer(target: self, action: #selector(scrollContent(_:)))
        scrolling.minimumNumberOfTouches = 2
        scrolling.maximumNumberOfTouches = 2

        let primaryTap = UITapGestureRecognizer(target: self, action: #selector(primaryClick(_:)))
        primaryTap.numberOfTouchesRequired = 1

        let secondaryTap = UITapGestureRecognizer(target: self, action: #selector(secondaryClick(_:)))
        secondaryTap.numberOfTouchesRequired = 2

        // A drag cannot finish as a click, and a two-finger tap takes priority.
        primaryTap.require(toFail: movement)
        primaryTap.require(toFail: scrolling)
        primaryTap.require(toFail: secondaryTap)
        secondaryTap.require(toFail: scrolling)
        secondaryTap.require(toFail: movement)

        [movement, scrolling, primaryTap, secondaryTap].forEach(addGestureRecognizer)

        isAccessibilityElement = true
        accessibilityLabel = "Mac trackpad"
        accessibilityHint = "Drag one finger to move the pointer. Drag two fingers to scroll. Tap to click, or tap with two fingers to right-click."
        accessibilityTraits = .button
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Right-click", target: self, selector: #selector(accessibilityRightClick))
        ]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func movePointer(_ recognizer: UIPanGestureRecognizer) {
        deliverDelta(from: recognizer, to: onMove)
    }

    @objc private func scrollContent(_ recognizer: UIPanGestureRecognizer) {
        deliverDelta(from: recognizer, to: onScroll)
    }

    private func deliverDelta(from recognizer: UIPanGestureRecognizer, to callback: (CGSize) -> Void) {
        // Reset on every event, including cancellation, so a later gesture has
        // no leftover translation. Ignore the recognition threshold at .began.
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        guard recognizer.state == .changed,
              translation.x.isFinite, translation.y.isFinite,
              translation != .zero else { return }
        callback(CGSize(width: translation.x, height: translation.y))
    }

    @objc private func primaryClick(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onClick()
    }

    @objc private func secondaryClick(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onRightClick()
    }

    override func accessibilityActivate() -> Bool {
        onClick()
        return true
    }

    @objc private func accessibilityRightClick() -> Bool {
        onRightClick()
        return true
    }
}
