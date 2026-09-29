import XCTest
import SwiftUI
import UIKit
@testable import PocketDeskRemote

@MainActor
final class CommittedTextTests: XCTestCase {
    func testKeyboardDockOnlyInterceptsTouchesInsideItsHostedPanel() {
        let dock = KeyboardDockPassthroughView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let panel = UIControl(frame: CGRect(x: 0, y: 520, width: 390, height: 290))
        dock.addSubview(panel)

        XCTAssertFalse(dock.point(inside: CGPoint(x: 195, y: 300), with: nil),
                       "Transparent dock space must leave the Mac canvas interactive")
        XCTAssertTrue(dock.point(inside: CGPoint(x: 195, y: 600), with: nil),
                      "The visible keyboard panel must keep its controls interactive")
        panel.isHidden = true
        XCTAssertFalse(dock.point(inside: CGPoint(x: 195, y: 600), with: nil))
    }

    func testVoiceAcknowledgmentNeverClearsTypedDraftEvenWhenIdentical() {
        let voice = PendingText(requestID: "voice", payload: "same words", origin: .voice, sentAt: 1)
        let typed = PendingText(requestID: "typed", payload: "same words", origin: .draft, sentAt: 1)
        XCTAssertEqual(voice.draftAfterAcknowledgment("same words", accepted: true), "same words")
        XCTAssertEqual(voice.draftAfterAcknowledgment("same words", accepted: false), "same words")
        XCTAssertEqual(typed.draftAfterAcknowledgment("same words", accepted: true), "")
        XCTAssertEqual(typed.draftAfterAcknowledgment("edited draft", accepted: true), "edited draft")
    }

    func testFinalizedVoiceCanWaitForExplicitRetryWhenControlIsUnavailable() {
        let model = PhoneRemoteModel()
        model.draft = "unsent typed draft"
        model.stageVoiceRetry("spoken text")
        XCTAssertEqual(model.voiceRetryTranscript, "spoken text")
        XCTAssertEqual(model.voiceDeliveryStatus, .notQueued)
        XCTAssertEqual(model.draft, "unsent typed draft")
        XCTAssertFalse(model.sendVoiceText("spoken text"), "A disconnected session cannot send")
        XCTAssertEqual(model.voiceRetryTranscript, "spoken text")
        XCTAssertEqual(model.draft, "unsent typed draft")
    }

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

@MainActor
private final class FakeVoiceBackend: VoiceRecognitionBackend {
    var authorizationCount = 0
    var started = 0
    var stopped = 0
    var cancelled = 0
    var result: (@MainActor (String, Bool) -> Void)?
    var failure: (@MainActor () -> Void)?
    var suspendAuthorization = false
    var authorizationStarted: XCTestExpectation?
    private var authorizationContinuation: CheckedContinuation<Void, Never>?

    func authorize(shouldContinue: @escaping @MainActor () -> Bool) async throws {
        authorizationCount += 1
        authorizationStarted?.fulfill()
        if suspendAuthorization {
            await withCheckedContinuation { authorizationContinuation = $0 }
        }
    }

    func finishAuthorization() {
        authorizationContinuation?.resume()
        authorizationContinuation = nil
    }

    func begin(onResult: @escaping @MainActor (String, Bool) -> Void,
               onFailure: @escaping @MainActor () -> Void) throws {
        started += 1
        result = onResult
        failure = onFailure
    }

    func stop() { stopped += 1 }
    func cancel() { cancelled += 1 }
}

@MainActor
final class VoiceInputTests: XCTestCase {
    func testDismissedSheetNeverRequestsPermission() async {
        let backend = FakeVoiceBackend()
        let controller = VoiceInputController(backend: backend)
        await controller.start(whileAllowed: { false })
        XCTAssertEqual(backend.authorizationCount, 0)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testFinalRecognitionWaitsForExplicitDoneAndOnlyCompletesOnce() async {
        let backend = FakeVoiceBackend()
        let controller = VoiceInputController(backend: backend)
        await controller.start(whileAllowed: { true })
        XCTAssertEqual(controller.phase, .listening)
        backend.result?("Hello Mac", false)
        backend.result?("Hello Mac.", true)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(backend.stopped, 1)
        var insertions: [String] = []
        controller.finish { value in if let value { insertions.append(value) } }
        backend.result?("late duplicate", true)
        controller.finish { value in if let value { insertions.append(value) } }
        XCTAssertEqual(insertions, ["Hello Mac."])
    }

    func testCancelDuringAuthorizationPreventsLateRecordingAndInsertion() async {
        let backend = FakeVoiceBackend()
        backend.suspendAuthorization = true
        backend.authorizationStarted = expectation(description: "authorization started")
        let controller = VoiceInputController(backend: backend)
        let request = Task { await controller.start(whileAllowed: { true }) }
        await fulfillment(of: [backend.authorizationStarted!], timeout: 2)
        controller.cancel()
        backend.finishAuthorization()
        await request.value
        XCTAssertEqual(backend.started, 0)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.transcript.isEmpty)
    }

    func testInterruptionRetainsPartialTextWithoutAutomaticInsertion() async {
        let backend = FakeVoiceBackend()
        let controller = VoiceInputController(backend: backend)
        await controller.start(whileAllowed: { true })
        backend.result?("partially spoken", false)
        controller.pauseForInterruption()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.transcript, "partially spoken")
        XCTAssertGreaterThan(backend.cancelled, 0)
        backend.result?("late result", true)
        XCTAssertEqual(controller.transcript, "partially spoken", "An interrupted recording ignores late recognition")
    }
}
