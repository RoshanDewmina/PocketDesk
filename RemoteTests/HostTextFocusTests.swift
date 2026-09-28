import XCTest
import AppKit
import ApplicationServices

final class HostTextFocusTests: XCTestCase {
    func testEditableClassificationRequiresEnabledEditableTextRole() {
        XCTAssertTrue(HostTextFocusPolicy.isEditable(
            role: kAXTextFieldRole as String, enabled: true, editable: true, valueSettable: nil))
        XCTAssertTrue(HostTextFocusPolicy.isEditable(
            role: kAXTextAreaRole as String, enabled: true, editable: nil, valueSettable: true))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(
            role: kAXTextFieldRole as String, enabled: false, editable: true, valueSettable: true))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(
            role: kAXTextFieldRole as String, enabled: true, editable: false, valueSettable: true))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(
            role: kAXTextFieldRole as String, enabled: true, editable: nil, valueSettable: nil))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(
            role: kAXStaticTextRole as String, enabled: true, editable: true, valueSettable: true))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(
            role: nil, enabled: true, editable: true, valueSettable: true))
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
