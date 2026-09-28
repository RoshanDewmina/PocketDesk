import XCTest
import SwiftUI
import UIKit
@testable import PocketDeskRemote

@MainActor
final class CommittedTextTests: XCTestCase {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testInitialFocusWaitsForAttachmentAndDoesNotStealFocusBack() async {
        let editor = CommittedTextField.InitialFocusTextView()
        editor.focusOnAppear = true
        editor.requestInitialFocus()
        await drainMainQueue()
        XCTAssertFalse(editor.isFirstResponder)

        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = host
        window.makeKeyAndVisible()
        XCTAssertTrue(window.isKeyWindow, "Focus fixture must have a scene-backed key window")
        host.view.addSubview(editor)
        editor.frame = host.view.bounds
        let focused = expectation(for: NSPredicate { _, _ in editor.isFirstResponder }, evaluatedWith: editor)
        await fulfillment(of: [focused], timeout: 2)
        XCTAssertTrue(editor.isFirstResponder)
        editor.resignFirstResponder()
        editor.requestInitialFocus()
        await drainMainQueue()
        XCTAssertFalse(editor.isFirstResponder, "Draft updates must not reopen a dismissed keyboard")
        window.isHidden = true
    }

    func testDisabledOrRemovedEditorCannotTakeInitialFocus() async {
        let editor = CommittedTextField.InitialFocusTextView()
        editor.focusOnAppear = true
        editor.isEditable = false
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = host
        window.makeKeyAndVisible()
        XCTAssertTrue(window.isKeyWindow, "Focus fixture must have a scene-backed key window")
        host.view.addSubview(editor)
        editor.requestInitialFocus()
        await drainMainQueue()
        XCTAssertFalse(editor.isFirstResponder)
        editor.isEditable = true
        editor.requestInitialFocus()
        editor.removeFromSuperview()
        await drainMainQueue()
        XCTAssertFalse(editor.isFirstResponder, "A queued focus request must not revive a hidden panel")
        window.isHidden = true
    }

    func testDismissalRetainsNativeCompositionInLocalDraft() async {
        var draft = "prefix "
        var composing = false
        let coordinator = CommittedTextField.Coordinator(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isComposing: Binding(get: { composing }, set: { composing = $0 }))
        let editor = CommittedTextField.InitialFocusTextView()
        editor.delegate = coordinator
        editor.text = draft
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = host
        window.makeKeyAndVisible()
        XCTAssertTrue(window.isKeyWindow, "Focus fixture must have a scene-backed key window")
        host.view.addSubview(editor)
        editor.frame = host.view.bounds
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.selectedRange = NSRange(location: draft.utf16.count, length: 0)
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        coordinator.textViewDidChange(editor)
        XCTAssertTrue(composing)
        XCTAssertEqual(draft, "prefix ")
        CommittedTextField.dismantleUIView(editor, coordinator: coordinator)
        await drainMainQueue()
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertFalse(composing)
        XCTAssertEqual(draft, editor.text, "Dismissal must preserve the local native editor contents")
        XCTAssertTrue(draft.hasSuffix("かな"))
        window.isHidden = true
    }

    func testMarkedTextStaysLocalUntilCommitted() {
        var draft = "sent draft"
        var composing = false
        let coordinator = CommittedTextField.Coordinator(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isComposing: Binding(get: { composing }, set: { composing = $0 }))
        let view = UITextView()
        view.text = draft
        view.selectedRange = NSRange(location: draft.utf16.count, length: 0)
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        coordinator.textViewDidChange(view)
        XCTAssertTrue(composing)
        XCTAssertEqual(draft, "sent draft")
        view.unmarkText()
        coordinator.textViewDidChange(view)
        XCTAssertFalse(composing)
        XCTAssertTrue(draft.hasSuffix("かな"))
    }

    func testAcknowledgedDraftClearDoesNotRestoreOldText() {
        var draft = "old\nmultiline draft"
        var composing = false
        let coordinator = CommittedTextField.Coordinator(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isComposing: Binding(get: { composing }, set: { composing = $0 }))
        let view = UITextView()
        view.delegate = coordinator
        view.text = draft
        view.selectedRange = NSRange(location: draft.utf16.count, length: 0)
        draft = ""
        coordinator.applyModelText(draft, to: view)
        XCTAssertEqual(view.text, "")
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 0))
        view.text = "new draft"
        coordinator.textViewDidChange(view)
        XCTAssertEqual(draft, "new draft")
    }

    func testPendingSendDisabledEnvironmentMakesNativeEditorReadOnly() {
        let root = CommittedTextField(text: .constant("pending"), isComposing: .constant(false)).disabled(true)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        func textView(in view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            return view.subviews.compactMap { textView(in: $0) }.first
        }
        let editor = textView(in: host.view)
        XCTAssertNotNil(editor)
        XCTAssertFalse(editor?.isEditable ?? true, "In-flight draft must reject new composition until acknowledgment")
        XCTAssertTrue(editor?.isSelectable ?? false)
        window.isHidden = true
    }
}
