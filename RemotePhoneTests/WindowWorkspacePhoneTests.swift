import XCTest
@testable import PocketDeskRemote

@MainActor
final class WindowWorkspacePhoneTests: XCTestCase {
    func testOldSessionReplyAndRetiredReplyCannotPublishTitles() throws {
        let controller = WindowWorkspaceController()
        var session = UUID()
        var epoch: UInt64 = 7
        var frame: WorkspaceFrame?
        controller.authority = { (session, epoch) }
        controller.transport = { sent, _ in frame = sent; return true }
        controller.list()
        let sent = try XCTUnwrap(frame)
        let row = WindowWorkspaceEntry(id: InputCausalEnvelope.identity(), app: "App", title: "Private document", exactWindow: true)
        let reply = try WorkspaceFrame(kind: .windows, requestID: sent.requestID, value: WindowWorkspaceReply(operation: .list, outcome: .confirmed, revision: InputCausalEnvelope.identity(), entries: [row]))
        session = UUID()
        controller.receive(reply, epoch: epoch)
        XCTAssertTrue(controller.entries.isEmpty)
        controller.retire()
        controller.receive(reply, epoch: epoch)
        XCTAssertTrue(controller.entries.isEmpty)
        controller.list()
        let second = try XCTUnwrap(frame)
        epoch = 8
        controller.receive(try WorkspaceFrame(kind: .windows, requestID: second.requestID, value: WindowWorkspaceReply(operation: .list, outcome: .confirmed, revision: InputCausalEnvelope.identity(), entries: [row])), epoch: 7)
        XCTAssertTrue(controller.entries.isEmpty)
        controller.retire()
    }
    func testCloseFlushesTitlesAndActivationOutcomeIsRequested() throws {
        let controller = WindowWorkspaceController(), session = UUID()
        var frame: WorkspaceFrame?
        controller.authority = { (session, 7) }
        controller.transport = { sent, _ in frame = sent; return true }
        controller.list()
        let row = WindowWorkspaceEntry(id: InputCausalEnvelope.identity(), app: "App", title: "Window", exactWindow: true)
        let revision = InputCausalEnvelope.identity()
        controller.receive(try WorkspaceFrame(kind: .windows, requestID: XCTUnwrap(frame).requestID, value: WindowWorkspaceReply(operation: .list, outcome: .confirmed, revision: revision, entries: [row])), epoch: 7)
        XCTAssertEqual(controller.entries, [row])
        controller.activate(row)
        let activation = try XCTUnwrap(frame)
        XCTAssertEqual(try activation.decode(WindowWorkspaceRequest.self).handle, row.id)
        controller.receive(try WorkspaceFrame(kind: .windows, requestID: activation.requestID, value: WindowWorkspaceReply(operation: .activate, outcome: .requested)), epoch: 7)
        XCTAssertTrue(controller.message.contains("Check the Mac picture"))
        controller.close()
        XCTAssertTrue(controller.entries.isEmpty)
        XCTAssertEqual(try XCTUnwrap(frame).decode(WindowWorkspaceRequest.self).operation, .close)
    }
    func testFocusReplyRequiresMatchingRequestAndCurrentAuthority() throws {
        let controller = WindowWorkspaceController(), session = UUID()
        var frame: WorkspaceFrame?, allowed = true
        controller.authority = { allowed ? (session, 7) : nil }
        controller.transport = { sent, _ in frame = sent; return true }
        controller.focusCurrent()
        let sent = try XCTUnwrap(frame)
        let geometry = FocusGeometry(displayWidth: 1440, displayHeight: 900, x: 10, y: 20, width: 700, height: 600)
        let reply = WindowWorkspaceReply(operation: .focusCurrent, outcome: .confirmed, geometry: geometry, display: 1)
        controller.receive(try WorkspaceFrame(kind: .windows, requestID: InputCausalEnvelope.identity(), value: reply), epoch: 7)
        XCTAssertNil(controller.focus)
        controller.receive(try WorkspaceFrame(kind: .windows, requestID: sent.requestID, value: reply), epoch: 7)
        XCTAssertEqual(controller.focus?.geometry, geometry)
        controller.retire()
        controller.focusCurrent()
        let next = try XCTUnwrap(frame)
        allowed = false
        controller.receive(try WorkspaceFrame(kind: .windows, requestID: next.requestID, value: reply), epoch: 7)
        XCTAssertNil(controller.focus)
        controller.retire()
    }
}
