import SwiftUI
import UIKit

/// A draft-only text view that exposes completed IME text without forwarding keystrokes.
struct CommittedTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isComposing: Bool
    var focusOnAppear = false
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
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        view.textContainer.lineFragmentPadding = 0
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 10
        view.layer.masksToBounds = true
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
        var focusOnAppear = false
        private var didFocus = false
        private var keyWindowObserver: NSObjectProtocol?

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
