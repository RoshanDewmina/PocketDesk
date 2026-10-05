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
        var dismantling = false
        var synchronousPublications = 0
        let coordinator = CommittedTextField.Coordinator(
            text: Binding(get: { draft }, set: { if dismantling { synchronousPublications += 1 }; draft = $0 }),
            isComposing: Binding(get: { composing }, set: { if dismantling { synchronousPublications += 1 }; composing = $0 }))
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
        dismantling = true
        CommittedTextField.dismantleUIView(editor, coordinator: coordinator)
        dismantling = false
        XCTAssertEqual(synchronousPublications, 0, "UIKit may finalize marked text but cannot publish during SwiftUI teardown")
        XCTAssertEqual(draft, "prefix ", "Final native text is published only after teardown returns")
        await drainMainQueue()
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertFalse(composing)
        XCTAssertEqual(draft, editor.text, "Dismissal must preserve the local native editor contents")
        XCTAssertTrue(draft.hasSuffix("かな"))
        window.isHidden = true
    }

    func testTeardownCannotOverwriteNewerDraftBeforeDeferredPublication() async {
        var draft = "before"
        var composing = true
        let owner = NSObject()
        let coordinator = CommittedTextField.Coordinator(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isComposing: Binding(get: { composing }, set: { composing = $0 }), draftOwner: owner)
        coordinator.beginTeardown()
        coordinator.finishTeardown(finalText: "old final composition")
        draft = "new draft"
        await drainMainQueue()
        XCTAssertEqual(draft, "new draft")
        XCTAssertTrue(composing, "A stale teardown must not change the newer draft's composition flag")
    }

    func testReplacementEditorRetiresOldTeardownEvenWithIdenticalDraftAndComposition() async {
        var draft = "same"
        var composing = true
        let owner = NSObject()
        let text = Binding(get: { draft }, set: { draft = $0 })
        let composition = Binding(get: { composing }, set: { composing = $0 })
        let old = CommittedTextField.Coordinator(text: text, isComposing: composition, draftOwner: owner)
        old.beginTeardown()
        old.finishTeardown(finalText: "retired native composition")
        let replacement = CommittedTextField.Coordinator(text: text, isComposing: composition, draftOwner: owner)
        await drainMainQueue()
        XCTAssertEqual(draft, "same", "Value equality alone cannot identify the current editor")
        XCTAssertTrue(composing)
        withExtendedLifetime(replacement) {}
    }

    func testTeardownSuppressesAllDelegateCallbacksAndQueuesOnlyOneFinalPublication() async {
        var draft = "prefix"
        var composing = true
        var publications = 0
        let coordinator = CommittedTextField.Coordinator(
            text: Binding(get: { draft }, set: { publications += 1; draft = $0 }),
            isComposing: Binding(get: { composing }, set: { publications += 1; composing = $0 }))
        let view = UITextView(); view.text = "prefix finalized"
        coordinator.beginTeardown()
        coordinator.textViewDidChange(view)
        coordinator.textViewDidChangeSelection(view)
        coordinator.textViewDidEndEditing(view)
        coordinator.finishTeardown(finalText: view.text)
        coordinator.finishTeardown(finalText: "duplicate")
        XCTAssertEqual(publications, 0)
        await drainMainQueue()
        XCTAssertEqual(draft, "prefix finalized")
        XCTAssertFalse(composing)
        XCTAssertEqual(publications, 2)
    }

    private func secureComposerModel() throws -> PhoneRemoteModel {
        let model = PhoneRemoteModel(coordinator: RemoteCoordinator(isHost: false, store: MemoryStore()))
        model.prepareConnection(mode: .picture)
        model.connection.startInputFixtureForTesting(session: "local-secure-composition")
        let receive = try XCTUnwrap(model.connection.onControl)
        try receive(JSONEncoder().encode(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 3)))
        try receive(JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 3, features: [SessionFeature.secureFocus])))
        model.receiveSecureFocus(secure: true)
        XCTAssertTrue(model.passwordFieldFocused)
        return model
    }

    func testSecureFocusEndRetiresDeferredNativeSecretWithUnchangedBindingValues() async throws {
        let model = try secureComposerModel()
        defer { model.connection.stop() }
        model.isComposingText = true
        let coordinator = CommittedTextField.Coordinator(
            text: Binding(get: { model.draft }, set: { model.draft = $0 }),
            isComposing: Binding(get: { model.isComposingText }, set: { model.isComposingText = $0 }), draftOwner: model)
        coordinator.beginTeardown()
        coordinator.finishTeardown(finalText: "native secret")
        model.endSecureFocus()
        XCTAssertEqual(model.draft, "")
        XCTAssertFalse(model.isComposingText, "The owner retires composition without waiting for its old editor")
        // A new-context composition may restore identical binding values. Identity must still reject the old text.
        model.isComposingText = true
        XCTAssertTrue(model.secureTextFocus.draftMayPersist)
        await drainMainQueue()
        XCTAssertEqual(model.draft, "", "A retired native secret cannot become an ordinary persistable draft")
        XCTAssertTrue(model.isComposingText, "Old teardown cannot clear a new-context composition")
    }

    func testSecureLeaveAndReenterCannotReviveDeferredComposition() async throws {
        let model = try secureComposerModel()
        defer { model.connection.stop() }
        model.isComposingText = true
        let original = model.draftPublicationIdentity
        let coordinator = CommittedTextField.Coordinator(
            text: Binding(get: { model.draft }, set: { model.draft = $0 }),
            isComposing: Binding(get: { model.isComposingText }, set: { model.isComposingText = $0 }), draftOwner: model)
        coordinator.beginTeardown(); coordinator.finishTeardown(finalText: "old native secret")
        model.receiveSecureFocus(secure: false); model.receiveSecureFocus(secure: true)
        XCTAssertTrue(model.passwordFieldFocused)
        XCTAssertFalse(model.isComposingText)
        XCTAssertNotEqual(model.draftPublicationIdentity, original)
        model.isComposingText = true // A new composition restores the same values across secure leave/reenter.
        await drainMainQueue()
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.isComposingText)
    }

    func testSessionRetirementRejectsDeferredDraftWithoutBindingChanges() async {
        let model = PhoneRemoteModel()
        model.isComposingText = true
        let original = model.draftPublicationIdentity
        let coordinator = CommittedTextField.Coordinator(
            text: Binding(get: { model.draft }, set: { model.draft = $0 }),
            isComposing: Binding(get: { model.isComposingText }, set: { model.isComposingText = $0 }), draftOwner: model)
        coordinator.beginTeardown(); coordinator.finishTeardown(finalText: "retired draft")
        model.connection.stop()
        XCTAssertNotEqual(model.draftPublicationIdentity.session, original.session)
        XCTAssertFalse(model.isComposingText, "Session stop reaches the owner's composition retirement")
        model.isComposingText = true // New-context state must survive the old editor's queued publication.
        await drainMainQueue()
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.isComposingText)
    }

    private func markedEditor(for model: PhoneRemoteModel) -> (CommittedTextField.Coordinator, UITextView) {
        let coordinator = CommittedTextField.Coordinator(
            text: Binding(get: { model.draft }, set: { model.draft = $0 }),
            isComposing: Binding(get: { model.isComposingText }, set: { model.isComposingText = $0 }), draftOwner: model)
        let editor = UITextView()
        editor.text = model.draft
        editor.delegate = coordinator
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        coordinator.textViewDidChange(editor)
        XCTAssertNotNil(editor.markedTextRange)
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.isComposingText)
        return (coordinator, editor)
    }

    private func assertRetiredEditorCannotPublish(_ editor: UITextView,
                                                 coordinator: CommittedTextField.Coordinator,
                                                 model: PhoneRemoteModel) async {
        let currentComposition = model.isComposingText
        // Exercise all delegate paths before SwiftUI gets an opportunity to update or dismantle.
        coordinator.textViewDidChange(editor)
        coordinator.textViewDidChangeSelection(editor)
        editor.unmarkText()
        coordinator.textViewDidEndEditing(editor)
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.isComposingText, currentComposition, "Retired callbacks cannot change current binding state")
        CommittedTextField.dismantleUIView(editor, coordinator: coordinator)
        await drainMainQueue()
        XCTAssertEqual(model.draft, "", "Teardown cannot enroll retired native text in the current context")
        XCTAssertEqual(model.isComposingText, currentComposition)
    }

    func testSecureFocusEndBeforeTeardownRetiresPendingNativeText() async throws {
        let model = try secureComposerModel()
        defer { model.connection.stop() }
        let (coordinator, editor) = markedEditor(for: model)
        model.endSecureFocus()
        XCTAssertEqual(model.draft, "")
        XCTAssertFalse(model.isComposingText)
        XCTAssertTrue(model.secureTextFocus.draftMayPersist)
        await assertRetiredEditorCannotPublish(editor, coordinator: coordinator, model: model)
    }

    func testSecureLeaveAndReenterBeforeTeardownRetiresPendingNativeText() async throws {
        let model = try secureComposerModel()
        defer { model.connection.stop() }
        let (coordinator, editor) = markedEditor(for: model)
        model.receiveSecureFocus(secure: false)
        model.receiveSecureFocus(secure: true)
        XCTAssertTrue(model.passwordFieldFocused)
        XCTAssertFalse(model.isComposingText)
        await assertRetiredEditorCannotPublish(editor, coordinator: coordinator, model: model)
    }

    func testSessionRetirementBeforeTeardownRetiresPendingNativeText() async {
        let model = PhoneRemoteModel()
        let (coordinator, editor) = markedEditor(for: model)
        model.connection.stop()
        XCTAssertFalse(model.isComposingText)
        await assertRetiredEditorCannotPublish(editor, coordinator: coordinator, model: model)
    }

    func testContextUpdateReplacesRetiredMarkedTextWithoutSynchronousPublication() async throws {
        let model = try secureComposerModel()
        defer { model.connection.stop() }
        var updating = false
        var synchronousPublications = 0
        let text = Binding(get: { model.draft }, set: {
            if updating { synchronousPublications += 1 }
            model.draft = $0
        })
        let composition = Binding(get: { model.isComposingText }, set: {
            if updating { synchronousPublications += 1 }
            model.isComposingText = $0
        })
        let coordinator = CommittedTextField.Coordinator(text: text, isComposing: composition, draftOwner: model)
        let editor = UITextView()
        editor.delegate = coordinator
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        coordinator.textViewDidChange(editor)
        XCTAssertTrue(model.isComposingText)
        XCTAssertEqual(model.draft, "")
        model.endSecureFocus()
        model.draft = "current draft"
        updating = true
        coordinator.update(text: text, isComposing: composition, draftOwner: model, in: editor)
        updating = false
        XCTAssertEqual(synchronousPublications, 0)
        XCTAssertNil(editor.markedTextRange)
        XCTAssertEqual(editor.text, "current draft", "The model, not retired native composition, owns the new context")
        XCTAssertFalse(model.isComposingText, "The owner already retired composition before the representable update")
        await drainMainQueue()
        XCTAssertFalse(model.isComposingText)
        XCTAssertEqual(model.draft, "current draft")
    }

    func testNewCompositionAfterContextUpdateSurvivesDeferredResetAndSameContextHide() async throws {
        let model = try secureComposerModel()
        defer { model.connection.stop() }
        let (coordinator, editor) = markedEditor(for: model)
        let text = Binding(get: { model.draft }, set: { model.draft = $0 })
        let composition = Binding(get: { model.isComposingText }, set: { model.isComposingText = $0 })
        model.endSecureFocus()
        coordinator.update(text: text, isComposing: composition, draftOwner: model, in: editor)
        XCTAssertNil(editor.markedTextRange)
        XCTAssertEqual(editor.text, "")
        editor.setMarkedText("新しい", selectedRange: NSRange(location: 3, length: 0))
        coordinator.textViewDidChange(editor)
        coordinator.update(text: text, isComposing: composition, draftOwner: model, in: editor)
        await drainMainQueue()
        XCTAssertNotNil(editor.markedTextRange, "Same-context updates must leave the new IME composition intact")
        XCTAssertTrue(model.isComposingText, "The prior context reset cannot clear a new composition")
        XCTAssertEqual(model.draft, "")
        CommittedTextField.dismantleUIView(editor, coordinator: coordinator)
        await drainMainQueue()
        XCTAssertEqual(model.draft, "新しい")
        XCTAssertFalse(model.isComposingText)
    }

    func testSecureFocusRetirementClearsCompositionWithoutAnEditor() throws {
        let model = try secureComposerModel()
        defer { model.connection.stop() }
        model.isComposingText = true
        let initial = model.draftPublicationIdentity
        model.endSecureFocus()
        XCTAssertFalse(model.isComposingText, "Removed editors cannot leave the shared auto-keyboard/voice composition gate blocked")
        XCTAssertNotEqual(model.draftPublicationIdentity, initial)
        model.draft = "ordinary local draft"
        XCTAssertTrue(model.textCanSend, "The composition gate is cleared; sending still requires separate control authority")
        XCTAssertTrue(model.textEditable)
        let ended = model.draftPublicationIdentity
        model.isComposingText = true
        model.endSecureFocus()
        XCTAssertFalse(model.isComposingText, "Every end retires composition even when secure focus was already inactive")
        XCTAssertNotEqual(model.draftPublicationIdentity, ended)
        XCTAssertEqual(model.draft, "ordinary local draft")
    }

    func testRepeatedSecureFocusReplyPreservesCurrentComposition() throws {
        let model = try secureComposerModel()
        defer { model.connection.stop() }
        model.isComposingText = true
        let secure = model.draftPublicationIdentity
        model.receiveSecureFocus(secure: true)
        XCTAssertTrue(model.isComposingText)
        XCTAssertEqual(model.draftPublicationIdentity, secure)
        model.receiveSecureFocus(secure: false)
        XCTAssertFalse(model.isComposingText, "An actual secure-state change retires the old composition")
        let ordinary = model.draftPublicationIdentity
        model.isComposingText = true
        model.receiveSecureFocus(secure: false)
        XCTAssertTrue(model.isComposingText, "A repeated ordinary focus reply also leaves current IME intact")
        XCTAssertEqual(model.draftPublicationIdentity, ordinary)
        model.receiveSecureFocus(secure: true)
        XCTAssertFalse(model.isComposingText)
        XCTAssertNotEqual(model.draftPublicationIdentity, ordinary)
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
