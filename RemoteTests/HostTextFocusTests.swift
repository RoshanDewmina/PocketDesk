import XCTest
import AppKit
import ApplicationServices

final class HostTextFocusTests: XCTestCase {
    func testEditableClassificationUsesRolesOrEditableAttributes() {
        XCTAssertTrue(HostTextFocusPolicy.isEditable(
            role: kAXTextFieldRole as String, enabled: true, editable: true, valueSettable: nil))
        XCTAssertTrue(HostTextFocusPolicy.isEditable(
            role: kAXTextAreaRole as String, enabled: true, editable: nil, valueSettable: true))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(
            role: kAXTextFieldRole as String, enabled: false, editable: true, valueSettable: true))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(
            role: kAXTextFieldRole as String, enabled: true, editable: false, valueSettable: true))
        XCTAssertTrue(HostTextFocusPolicy.isEditable(
            role: kAXTextFieldRole as String, enabled: true, editable: nil, valueSettable: nil))
        XCTAssertTrue(HostTextFocusPolicy.isEditable(
            role: kAXGroupRole as String, enabled: true, editable: true, valueSettable: true))
        XCTAssertTrue(HostTextFocusPolicy.isEditable(
            role: nil, enabled: true, editable: true, valueSettable: true))
    }

    func testAllTextRolesAndSelectionMetadataAreAcceptedWithoutReadingValues() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertTrue(HostTextFocusPolicy.isEditable(role: role, enabled: nil, editable: nil, valueSettable: nil))
        }
        XCTAssertTrue(HostTextFocusPolicy.isEditable(role: "AXGroup", enabled: true, editable: nil,
                                                    valueSettable: nil, selectionPresent: true))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(role: "AXButton", enabled: true, editable: nil,
                                                     valueSettable: false))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(role: "AXTextArea", enabled: true, editable: false,
                                                     valueSettable: true, selectionPresent: true))
    }

    func testTapFocusChangeOpensHiddenEditorAnywhereInAppWithinWindow() {
        let focused = HostTextFocusResult(editable: true, axEditable: true,
                                          tapHitsFocused: false, focusChangedAt: 100.3)
        XCTAssertTrue(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.35,
                                                       ax: { focused }, cursor: { .arrow }))
        XCTAssertTrue(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.4,
                                                       ax: { focused }, cursor: { nil }))
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.401,
                                                        ax: { focused }, cursor: { .iBeam }))
    }

    func testAlreadyFocusedFieldNeedsMatchingTapAndNonTextTapDoesNotOpen() {
        var focused = HostTextFocusResult(editable: true, axEditable: true, tapHitsFocused: true)
        XCTAssertTrue(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                       ax: { focused }, cursor: { nil }))
        focused.tapHitsFocused = false
        focused.tapTargetEditable = false
        focused.focusChangedAt = 99.9
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                        ax: { focused }, cursor: { .iBeam }))
        focused.focusChangedAt = 100.2
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                        ax: { focused }, cursor: { .iBeam }))
    }

    func testRealIBeamFallbackOnlyWhenAXHasNoAnswer() {
        for shape in [PointerShape.iBeam, .iBeamVertical] {
            XCTAssertTrue(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                           ax: { .unfocused }, cursor: { shape }))
        }
        let button = HostTextFocusResult(editable: false, axEditable: false, focusChangedAt: 100.05)
        var cursorRead = false
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
            ax: { button }, cursor: { cursorRead = true; return .iBeam }))
        XCTAssertFalse(cursorRead, "An AX non-text answer must veto selectable-text I-beams")
        for shape: PointerShape? in [.arrow, .unknown, nil] {
            XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                            ax: { .unfocused }, cursor: { shape }))
        }
    }

    func testRetappingAlreadyFocusedHiddenEditorUsesRealIBeamOnlyForOpaqueHit() {
        var hidden = HostTextFocusResult(editable: true, axEditable: true,
                                         tapHitsFocused: false, focusChangedAt: 99)
        XCTAssertTrue(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                       ax: { hidden }, cursor: { .iBeam }))
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                        ax: { hidden }, cursor: { .arrow }))
        hidden.tapTargetEditable = false // A selectable label/button is a concrete AX answer.
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                        ax: { hidden }, cursor: { .iBeam }))
    }

    func testNoTapFocusChangeIsIgnoredWithoutConsultingProviders() {
        var reads = 0
        let ax = { reads += 1; return HostTextFocusResult(editable: true, axEditable: true, focusChangedAt: 100.1) }
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: nil, now: 100.2,
                                                        ax: ax, cursor: { reads += 1; return .iBeam }))
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 101, now: 100.2,
                                                        ax: ax, cursor: { reads += 1; return .iBeam }))
        XCTAssertEqual(reads, 0)
    }

    func testPollingDetectsDelayedFocusButDoesNotInventAChangeOnFirstSample() {
        let changes = HostTextFocusChanges()
        let budget = HostAXBudget(total: 0.2)
        // A harmless nonexistent pid avoids subscribing to a real application in this fixture.
        changes.setSessionActive(true)
        changes.watch(pid: 999999, budget: budget)
        let first = AXUIElementCreateApplication(999999)
        let next = AXUIElementCreateApplication(999998)
        XCTAssertNil(changes.sample(first, pid: 999999, tapIssuedAt: 100, now: 100.05))
        XCTAssertEqual(changes.sample(next, pid: 999999, tapIssuedAt: 100, now: 100.2), 100.2)
        changes.stop()
        XCTAssertNil(changes.sample(next, pid: 999999, tapIssuedAt: 100, now: 100.3))
    }

    func testNonTextControlsWithSettableValuesNeverCountAsEditors() {
        for role in ["AXSlider", "AXCheckBox", "AXRadioButton", "AXButton", "AXStaticText"] {
            XCTAssertFalse(HostTextFocusPolicy.isEditable(role: role, enabled: true, editable: nil,
                valueSettable: true, selectionPresent: true), role)
        }
    }

    func testAXTargetProviderDistinguishesOpaqueCanvasFromConcreteNonTextAnswer() {
        for role in ["AXGroup", "AXWebArea", "AXWindow", "AXUnknown"] {
            XCTAssertNil(HostTextFocusPolicy.editableAnswer(role: role, enabled: nil, editable: nil,
                                                           valueSettable: false), role)
        }
        XCTAssertEqual(HostTextFocusPolicy.editableAnswer(role: "AXStaticText", enabled: true,
            editable: nil, valueSettable: false, selectionPresent: true), false)
        XCTAssertEqual(HostTextFocusPolicy.editableAnswer(role: "AXGroup", enabled: true,
            editable: false, valueSettable: false), false)
        XCTAssertEqual(HostTextFocusPolicy.editableAnswer(role: "AXGroup", enabled: true,
            editable: nil, valueSettable: true), true)
    }

    func testPostingTimestampKeepsFocusEventBeforeReceiptInsideTapWindow() {
        let posted = HostTextFocusTicket.postedAt(receivedAt: 100.12, postingStartedMs: 100000, clockNowMs: 100120)
        XCTAssertEqual(posted, 100, accuracy: 0.0001)
        let focus = HostTextFocusResult(editable: true, axEditable: true, focusChangedAt: 100.04)
        XCTAssertTrue(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: posted, now: 100.2,
                                                       ax: { focus }, cursor: { nil }))
    }

    func testTicketExpiresOnNewInputEpochAndLostControl() {
        let ticket = HostTextFocusTicket(epoch: 7, revision: 13, issuedAt: 100)
        func current(epoch: UInt64 = 7, revision: UInt64 = 13, now: TimeInterval = 100.2,
                     active: Bool = true, connected: Bool = true,
                     control: Bool = true, healthy: Bool = true) -> Bool {
            ticket.isCurrent(epoch: epoch, revision: revision, now: now, active: active,
                             connected: connected, controlEnabled: control, captureHealthy: healthy)
        }
        XCTAssertTrue(current())
        XCTAssertFalse(current(revision: 14), "A newer input invalidates the click")
        XCTAssertFalse(current(epoch: 8), "A new capture/session cannot reuse focus")
        XCTAssertFalse(current(now: 101), "Late AX results must not pop the keyboard")
        XCTAssertFalse(current(now: 99.9))
        XCTAssertFalse(current(active: false))
        XCTAssertFalse(current(connected: false))
        XCTAssertFalse(current(control: false))
        XCTAssertFalse(current(healthy: false))
    }

    func testOnlyCanonicalClickProbeIDIsAccepted() {
        XCTAssertTrue(HostTextFocusProbe.isValidID(String(repeating: "a", count: 32)))
        XCTAssertFalse(HostTextFocusProbe.isValidID(nil))
        XCTAssertFalse(HostTextFocusProbe.isValidID(String(repeating: "a", count: 31)))
        XCTAssertFalse(HostTextFocusProbe.isValidID(String(repeating: "A", count: 32)))
        XCTAssertFalse(HostTextFocusProbe.isValidID(String(repeating: "g", count: 32)))
    }

    func testAcceptedClickKeepsExactPointAndFailedClickHasNoPoint() {
        var point = CGPoint(x: 130, y: 145)
        var accept = true
        let sink = RemoteInputEventSink(
            pointerLocation: { point },
            mouseSequence: { _ in accept },
            scroll: { _, _, _ in true },
            text: { _ in true },
            key: { _, _ in true }
        )
        let driver = RemoteInputDriver(eventSink: sink, isTrusted: { true })
        driver.enabled = true
        driver.configure(bounds: CGRect(x: 0, y: 0, width: 500, height: 400))
        let click = RemoteAction(action: "click", interaction: NativeInteraction(clickCount: 1))
        let first = driver.handle(click, upgraded: true)
        point = CGPoint(x: 300, y: 300)
        XCTAssertTrue(first.accepted)
        XCTAssertEqual(first.clickPoint, CGPoint(x: 130, y: 145))

        accept = false
        let failed = driver.handle(click, upgraded: true)
        XCTAssertFalse(failed.accepted)
        XCTAssertNil(failed.clickPoint)
    }

    func testInvalidClickCoordinatesFailClosedWithoutAXAccess() async {
        let editable = await HostTextFocusProbe.editableAtClick(CGPoint(x: CGFloat.nan, y: 1))
        XCTAssertFalse(editable)
    }
}
