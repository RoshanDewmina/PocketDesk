import SwiftUI
import UIKit

/// Hosts SwiftUI keyboard chrome above UIKit's keyboard layout guide. The guide updates in the same
/// layout pass that presents the software keyboard, avoiding a stale SwiftUI keyboard safe-area
/// proposal when the contained editor becomes first responder immediately after insertion.
struct KeyboardLayoutDock<Content: View>: UIViewControllerRepresentable {
    private let content: Content
    private let containerOnlySafeArea: Bool
    /// The panel's frame in window coordinates, after each layout pass that moves it with the keyboard.
    private let onFrame: ((CGRect) -> Void)?

    init(containerOnlySafeArea: Bool = false, onFrame: ((CGRect) -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.containerOnlySafeArea = containerOnlySafeArea
        self.onFrame = onFrame
    }

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(content: content)
        controller.setContainerOnlySafeArea(containerOnlySafeArea)
        controller.onFrame = onFrame
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onFrame = onFrame
        controller.setContainerOnlySafeArea(containerOnlySafeArea)
        controller.update(content)
    }

    @MainActor
    final class Controller: UIViewController {
        private let host: UIHostingController<Content>
        var onFrame: ((CGRect) -> Void)?
        private var reportedFrame: CGRect?
        #if DEBUG
        private var probedFrame: CGRect?
        #endif

        init(content: Content) {
            host = UIHostingController(rootView: content)
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            view = KeyboardDockPassthroughView()
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.sizingOptions = .intrinsicContentSize
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)

            let safe = view.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            ])
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            #if DEBUG
            recordHitTestProbe()
            #endif
            guard let onFrame, view.window != nil else { return }
            let frame = host.view.convert(host.view.bounds, to: nil)
            guard frame != reportedFrame else { return }
            reportedFrame = frame
            DispatchQueue.main.async { onFrame(frame) }
        }

        #if DEBUG
        /// Opt-in fixture diagnostics; no editor contents or remote input is recorded or sent.
        private func recordHitTestProbe() {
            guard LaunchOptions.layoutCheck, LaunchOptions.has("--ui-keyboard-hit-probe"), let window = view.window else { return }
            let frame = host.view.convert(host.view.bounds, to: window)
            guard frame != probedFrame else { return }
            probedFrame = frame
            NSLog("%@", "[B7 keyboardHit] parent=\(view.bounds) host=\(host.view.bounds) frame=\(frame) enabled=\(host.view.isUserInteractionEnabled) alpha=\(host.view.alpha)")
            for fraction in [CGFloat(0.5), 0.7, 0.83, 0.96] {
                let local = CGPoint(x: host.view.bounds.width * fraction, y: min(24, host.view.bounds.height / 2))
                let parent = host.view.convert(local, to: view)
                let global = host.view.convert(local, to: window)
                let target = window.hitTest(global, with: nil)
                let targetClass = target.map { String(describing: type(of: $0)) } ?? "nil"
                let keyboardTarget = target === host.view || target?.isDescendant(of: host.view) == true
                NSLog("%@", "[B7 keyboardHit] point=\(global) hostInside=\(host.view.point(inside: local, with: nil)) parentInside=\(view.point(inside: parent, with: nil)) keyboardTarget=\(keyboardTarget) parentTarget=\(target === view) target=\(targetClass.prefix(100))")
            }
        }
        #endif

        func update(_ content: Content) {
            host.rootView = content
            host.view.invalidateIntrinsicContentSize()
        }

        func setContainerOnlySafeArea(_ enabled: Bool) {
            let regions: SafeAreaRegions = enabled ? .container : .all
            guard host.safeAreaRegions != regions else { return }
            host.safeAreaRegions = regions
        }
    }
}

/// The dock's controller covers the session so its keyboard guide sees the window. Only the hosted
/// panel itself accepts touches; the rest of that transparent view passes through to the Mac canvas.
final class KeyboardDockPassthroughView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return false }
        return subviews.reversed().contains { child in
            guard !child.isHidden, child.alpha > 0.01, child.isUserInteractionEnabled else { return false }
            return child.point(inside: child.convert(point, from: self), with: event)
        }
    }
}

/// A draft-only text view that exposes completed IME text without forwarding keystrokes.
struct CommittedTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isComposing: Bool
    var focusOnAppear = false
    var style: TextEntryStyle = .exact
    /// The Mac's focused field takes a password: mask it and keep it out of the keyboard's memory.
    var secure = false
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isComposing: $isComposing)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = InitialFocusTextView()
        view.focusOnAppear = focusOnAppear
        view.accessibilityLabel = "Text for your Mac"
        view.accessibilityIdentifier = "remote.text"
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        ExactTextTraits.apply(style, secure: secure, to: view)
        view.appliedEntry = (style, secure)
        view.concealed = secure
        view.textContainerInset = UIEdgeInsets(top: 11, left: 16, bottom: 11, right: 12)
        view.textContainer.lineFragmentPadding = 0
        view.backgroundColor = .clear
        view.isScrollEnabled = true
        view.isEditable = isEnabled
        view.isSelectable = true
        view.text = text
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.update(text: $text, isComposing: $isComposing)
        // A pending remote text request disables editing, preventing a new composition from
        // racing an acknowledgement that clears the corresponding draft.
        view.isEditable = isEnabled
        view.isSelectable = true
        if let editor = view as? InitialFocusTextView {
            editor.focusOnAppear = focusOnAppear
            if editor.appliedEntry != (style, secure) {
                ExactTextTraits.apply(style, secure: secure, to: editor)
                editor.appliedEntry = (style, secure)
                editor.concealed = secure
                if editor.isFirstResponder { editor.reloadInputViews() }
            }
            editor.requestInitialFocus()
        }

        // Setting text while an IME owns marked text discards that composition. A completed
        // model update, such as an acknowledged send clearing the draft, must still reach an
        // active field so its old draft cannot be sent again.
        guard view.markedTextRange == nil, view.text != text else { return }
        context.coordinator.applyModelText(text, to: view)
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        // Let UIKit finish the active composition into the local draft before detaching.
        view.resignFirstResponder()
        view.delegate = nil
        coordinator.clearCompositionAsynchronously()
    }

    /// Focus once after attachment, without stealing it back on subsequent draft updates.
    final class InitialFocusTextView: UITextView {
        // The session canvas owns three-finger copy/paste even while this draft has focus.
        override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
        var focusOnAppear = false
        var appliedEntry: (style: TextEntryStyle, secure: Bool) = (.exact, false)
        private var didFocus = false
        private var keyWindowObserver: NSObjectProtocol?
        private var visibleTextColor: UIColor?
        private lazy var maskLabel: UILabel = {
            let label = UILabel()
            label.isAccessibilityElement = false
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingHead
            addSubview(label)
            return label
        }()

        /// Draws bullets over transparent text; the caret and selection still work normally.
        var concealed = false {
            didSet {
                guard concealed != oldValue else { return }
                if concealed {
                    visibleTextColor = textColor
                    textColor = .clear
                } else {
                    textColor = visibleTextColor
                }
                refreshMask()
            }
        }

        func refreshMask() {
            maskLabel.isHidden = !concealed
            maskLabel.font = font
            maskLabel.textColor = visibleTextColor ?? .label
            maskLabel.text = concealed ? String(repeating: "•", count: text.count) : nil
            accessibilityValue = concealed ? "\(text.count) hidden characters" : nil
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard concealed else { return }
            let frame = bounds.inset(by: textContainerInset)
            maskLabel.frame = CGRect(x: frame.minX, y: frame.minY + contentOffset.y,
                                     width: frame.width, height: font?.lineHeight ?? frame.height)
        }

        deinit {
            if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stopObservingKeyWindow()
            if let window, focusOnAppear, !didFocus {
                keyWindowObserver = NotificationCenter.default.addObserver(
                    forName: UIWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self] _ in self?.requestInitialFocus() }
            }
            requestInitialFocus()
        }

        private func stopObservingKeyWindow() {
            if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
            keyWindowObserver = nil
        }

        func requestInitialFocus() {
            guard focusOnAppear, !didFocus, isEditable, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusOnAppear, !self.didFocus,
                      self.isEditable, self.window?.isKeyWindow == true else { return }
                self.didFocus = self.becomeFirstResponder()
                if self.didFocus { self.stopObservingKeyWindow() }
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>
        private var isComposing: Binding<Bool>
        private var isApplyingViewUpdate = false

        init(text: Binding<String>, isComposing: Binding<Bool>) {
            self.text = text
            self.isComposing = isComposing
        }

        func update(text: Binding<String>, isComposing: Binding<Bool>) {
            self.text = text
            self.isComposing = isComposing
        }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? InitialFocusTextView)?.refreshMask()
            updateCompositionState(from: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            updateCompositionState(from: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isComposing.wrappedValue = false
            commit(textView.text)
        }

        func clearCompositionAsynchronously() {
            let isComposing = isComposing
            DispatchQueue.main.async {
                isComposing.wrappedValue = false
            }
        }

        func applyModelText(_ value: String, to view: UITextView) {
            let selectedRange = view.selectedRange
            isApplyingViewUpdate = true
            defer { isApplyingViewUpdate = false }

            view.text = value
            (view as? InitialFocusTextView)?.refreshMask()
            let length = value.utf16.count
            let originalStart = selectedRange.location == NSNotFound ? length : selectedRange.location
            let originalEnd = selectedRange.location == NSNotFound ? length : originalStart + selectedRange.length
            let start = min(max(originalStart, 0), length)
            let end = min(max(originalEnd, start), length)
            view.selectedRange = NSRange(location: start, length: end - start)
        }

        private func updateCompositionState(from view: UITextView) {
            guard !isApplyingViewUpdate else { return }
            let composing = view.markedTextRange != nil
            isComposing.wrappedValue = composing
            if !composing {
                commit(view.text)
            }
        }

        private func commit(_ value: String) {
            guard text.wrappedValue != value else { return }
            text.wrappedValue = value
        }
    }
}
