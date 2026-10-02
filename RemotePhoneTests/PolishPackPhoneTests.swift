import XCTest
import UIKit
@testable import PocketDeskRemote

@MainActor
final class ExactTextTraitsTests: XCTestCase {
    func testExactTextTurnsOffEverythingThatRewritesTyping() {
        let view = UITextView()
        ExactTextTraits.apply(.exact, secure: false, to: view)
        XCTAssertEqual(view.autocapitalizationType, .none)
        XCTAssertEqual(view.autocorrectionType, .no)
        XCTAssertEqual(view.spellCheckingType, .no)
        XCTAssertEqual(view.smartQuotesType, .no, "No curly quotes in shell commands")
        XCTAssertEqual(view.smartDashesType, .no, "No em dashes in --flags")
        XCTAssertEqual(view.smartInsertDeleteType, .no)
        XCTAssertEqual(view.inlinePredictionType, .no, "No predicted text in paths")
        XCTAssertEqual(view.mathExpressionCompletionType, .no)
        XCTAssertEqual(view.writingToolsBehavior, .none)
        if #available(iOS 27.0, *) { XCTAssertEqual(view.grammarCheckingType, .no) }
        XCTAssertFalse(view.isSecureTextEntry)
    }

    func testProseKeepsSmartTyping() {
        let view = UITextView()
        ExactTextTraits.apply(.exact, secure: false, to: view)
        ExactTextTraits.apply(.prose, secure: false, to: view)
        XCTAssertEqual(view.autocorrectionType, .default)
        XCTAssertEqual(view.smartQuotesType, .default)
        XCTAssertEqual(view.smartDashesType, .default)
        XCTAssertEqual(view.inlinePredictionType, .default)
        XCTAssertEqual(view.writingToolsBehavior, .default)
        if #available(iOS 27.0, *) { XCTAssertEqual(view.grammarCheckingType, .default) }
    }

    func testPasswordFieldIsExactAndSecureEvenInProse() {
        let view = UITextView()
        ExactTextTraits.apply(.prose, secure: true, to: view)
        XCTAssertTrue(view.isSecureTextEntry, "iOS neither learns nor offers to copy it")
        XCTAssertEqual(view.autocorrectionType, .no)
        XCTAssertEqual(view.inlinePredictionType, .no)
        XCTAssertEqual(view.writingToolsBehavior, .none)
    }

    func testComposerMasksWhatIsTypedIntoAPasswordField() {
        let editor = CommittedTextField.InitialFocusTextView()
        editor.text = "hunter2"
        editor.concealed = true
        XCTAssertEqual(editor.textColor, .clear)
        XCTAssertEqual(editor.accessibilityValue, "7 hidden characters")
        editor.concealed = false
        XCTAssertNotEqual(editor.textColor, .clear)
        XCTAssertNil(editor.accessibilityValue)
    }
}

@MainActor
final class IndirectInputTests: XCTestCase {
    func testTheAppOptsIntoIndirectPointerTouches() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIApplicationSupportsIndirectInputEvents") as? Bool, true,
                       "Without it iPadOS turns mouse and trackpad clicks into finger touches")
    }

    func testTrackpadScrollAndPinchStillHaveTheirRecognizers() {
        let view = NativeTrackpadInputView()
        let recognizers = view.gestureRecognizers ?? []
        let scroll = recognizers.compactMap { $0 as? UIPanGestureRecognizer }.first
        XCTAssertEqual(scroll?.allowedScrollTypesMask, .all, "Two-finger trackpad scroll and wheels")
        XCTAssertEqual(scroll?.allowedTouchTypes, [], "Fingers stay with the gesture engine")
        XCTAssertEqual(recognizers.compactMap { $0 as? UIPinchGestureRecognizer }.first?.allowedTouchTypes, [])
        XCTAssertTrue(recognizers.contains { $0 is UIHoverGestureRecognizer })
        XCTAssertTrue(view.interactions.contains { $0 is UIPointerInteraction })
    }
}

@MainActor
final class SecureTextFocusTests: XCTestCase {
    func testOnlyASupportingMacCanTurnTheLockOn() {
        var state = SecureTextFocus()
        XCTAssertFalse(state.reply(secure: true, hostSupports: false))
        XCTAssertFalse(state.active)
        XCTAssertTrue(state.reply(secure: true, hostSupports: true))
        XCTAssertTrue(state.active)
        XCTAssertFalse(state.draftMayPersist)
        state.reply(secure: nil, hostSupports: true)
        XCTAssertFalse(state.active, "A reply without the flag clears it")
    }

    func testTextTypedIntoAPasswordFieldIsNeverKept() {
        var state = SecureTextFocus()
        state.draftChanged("ls -la")
        state.reply(secure: true, hostSupports: true)
        state.draftChanged("ls -lahunter2")
        XCTAssertFalse(state.draftMayPersist)
        XCTAssertEqual(state.end(draft: "ls -lahunter2"), "", "Mixed drafts are dropped whole")
        XCTAssertFalse(state.active)
        XCTAssertTrue(state.draftMayPersist)

        var clean = SecureTextFocus()
        clean.draftChanged("git status")
        XCTAssertEqual(clean.end(draft: "git status"), "git status", "Ordinary drafts survive")
    }

    func testModelDropsTheSecretDraftWhenTheFieldIsLeft() {
        let model = PhoneRemoteModel()
        model.secureTextFocus.reply(secure: true, hostSupports: true)
        model.draft = "hunter2"
        XCTAssertTrue(model.passwordFieldFocused)
        model.endSecureFocus()
        XCTAssertEqual(model.draft, "")
        XCTAssertFalse(model.passwordFieldFocused)
    }
}

@MainActor
final class LocalNetworkDeniedTests: XCTestCase {
    func testDeniedStatusBecomesAFixableError() throws {
        let error = try XCTUnwrap(FriendlyError.from(status: LocalNetworkAccess.deniedStatus, previous: nil, macName: "Mac"))
        XCTAssertEqual(error.kind, .localNetworkOff)
        XCTAssertEqual(error.action, .openSettings)
        XCTAssertEqual(error.secondary, .retry)
        XCTAssertEqual(error.headline, LocalNetworkAccess.deniedTitle)
        XCTAssertTrue(error.fix.contains("Local Network"))
        XCTAssertEqual(FriendlyError.Action.openSettings.title, "Open Settings")
        XCTAssertEqual(FriendlyError.forLocalOnly(error, serviceAskedForAnywhere: true, hasPlan: false).kind,
                       .localNetworkOff, "Never blamed on the plan")
    }

    func testPrimingTriggersTheAlertInTheForeground() {
        let defaults = UserDefaults(suiteName: "LocalNetworkDeniedTests")!
        defaults.removePersistentDomain(forName: "LocalNetworkDeniedTests")
        let flow = OnboardingFlow(defaults: defaults)
        var started = false
        flow.beforeConnect { started = true }
        XCTAssertEqual(flow.step, .priming(.localNetwork))
        let before = ProcessInfo.processInfo.systemUptime
        flow.primingFinished()
        XCTAssertGreaterThan(LocalNetworkAccess.settleDelay(now: before + 0.01), 0,
                             "The proof waits for the alert that Continue just brought up")
        XCTAssertFalse(started, "Connecting starts after the alert, not with it")
        defaults.removePersistentDomain(forName: "LocalNetworkDeniedTests")
    }
}

@MainActor
final class First60PhonePairingTests: XCTestCase {
    private func fixture() -> (PhoneRemoteModel, UserDefaults) {
        let name = "First60PhonePairingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        return (PhoneRemoteModel(background: FakeBackgroundExecution(), preferences: defaults,
                coordinator: RemoteCoordinator(isHost: false, store: MemoryStore())), defaults)
    }

    func testEnrollmentCannotStartBeforeExactCodeNetworkApproval() throws {
        let (model, _) = fixture()
        defer { model.disconnect() }
        let first = try TestPairing.invitation()
        let second = try TestPairing.invitation()
        XCTAssertFalse(model.enroll(try first.code()))
        XCTAssertFalse(model.connection.isRunning)
        model.approvePairingLocalAccess(try first.code())
        XCTAssertFalse(model.enroll(try second.code()))
        XCTAssertFalse(model.connection.isRunning)
        model.cancelPairingLocalAccess()
        XCTAssertFalse(model.enroll(try first.code()))
        XCTAssertFalse(model.connection.isRunning)
    }

    func testExternalCameraLinkOnlyStagesReviewAndCannotRetargetOpenSheet() throws {
        let (model, _) = fixture()
        defer { model.disconnect() }
        let first = try TestPairing.invitation()
        let second = try TestPairing.invitation()
        let cameraCode = try first.cameraCode()
        let expectedCode = try PairInvitation.normalizedCode(cameraCode)
        model.stagePairingLink(try XCTUnwrap(URL(string: cameraCode)))
        XCTAssertEqual(model.pairingEntry, .paste)
        XCTAssertEqual(model.pairingCode, expectedCode)
        XCTAssertEqual(try PairInvitation.parse(model.pairingCode), first)
        XCTAssertFalse(model.connection.isRunning)
        model.stagePairingLink(try XCTUnwrap(URL(string: second.cameraCode())))
        XCTAssertEqual(model.pairingCode, expectedCode)
        XCTAssertFalse(model.enroll(expectedCode))
        XCTAssertFalse(model.connection.isRunning)
    }

    func testDisabledFlowDoesNotAdmitExternalPairingLinks() throws {
        let (model, defaults) = fixture()
        defaults.set(true, forKey: First60.disabledDefaultsKey)
        defer { model.disconnect() }
        let invitation = try TestPairing.invitation()
        model.stagePairingLink(try XCTUnwrap(URL(string: invitation.cameraCode())))
        XCTAssertNil(model.pairingEntry)
        XCTAssertEqual(model.pairingCode, "")
        XCTAssertFalse(model.connection.isRunning)
    }
}
