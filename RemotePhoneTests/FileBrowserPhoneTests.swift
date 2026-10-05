import XCTest
@testable import PocketDeskRemote

@MainActor
final class FileBrowserPhoneTests: XCTestCase {
    func testReplyMustMatchExplicitCurrentRequestAndResetRetiresIt() throws {
        let browser = PhoneFileBrowser()
        var requests: [WorkspaceFrame] = []
        browser.send = { requests.append($0); return true }
        browser.query()
        let request = try XCTUnwrap(requests.first)
        let entry = FileBrowserEntry(id: InputCausalEnvelope.identity(), name: "Shared", kind: .folder, bytes: nil)
        browser.receive(try WorkspaceFrame(kind: .files, requestID: InputCausalEnvelope.identity(), value: FileBrowserReply(status: .ok, entries: [entry])))
        XCTAssertTrue(browser.entries.isEmpty); XCTAssertTrue(browser.busy)
        browser.receive(try WorkspaceFrame(kind: .files, requestID: request.requestID, value: FileBrowserReply(status: .ok, entries: [entry])))
        XCTAssertEqual(browser.entries, [entry]); XCTAssertFalse(browser.busy)
        browser.query(entry: entry.id); let older = try XCTUnwrap(requests.last)
        browser.reset()
        browser.receive(try WorkspaceFrame(kind: .files, requestID: older.requestID, value: FileBrowserReply(status: .ok, entries: [entry])))
        XCTAssertTrue(browser.entries.isEmpty); XCTAssertFalse(browser.busy)
    }
    func testMetadataWithPathNamesIsRejectedAndUnknownPeerCannotSend() throws {
        let browser = PhoneFileBrowser(); var request: WorkspaceFrame?
        browser.send = { request = $0; return true }; browser.query()
        let frame = try XCTUnwrap(request)
        let invalid = FileBrowserEntry(id: InputCausalEnvelope.identity(), name: "/private/item", kind: .file, bytes: 1)
        browser.receive(try WorkspaceFrame(kind: .files, requestID: frame.requestID, value: FileBrowserReply(status: .ok, entries: [invalid])))
        XCTAssertTrue(browser.entries.isEmpty); XCTAssertTrue(browser.busy)
        browser.reset(); browser.send = { _ in false }; browser.query()
        XCTAssertFalse(browser.busy); XCTAssertNotNil(browser.notice)
    }
    func testExplicitBrowserDownloadDoesNotSendLegacyPickerRequest() {
        let engine = FileTransferEngine(acceptsUnsolicitedOffers: false)
        var sent: [FileFrame] = []; engine.sendControl = { sent.append($0); return true }
        let id = FileTransferID.make()
        XCTAssertTrue(engine.requestBrowserDownload(id) { true })
        XCTAssertEqual(engine.pendingRequest, id); XCTAssertTrue(sent.isEmpty)
        engine.receive(.offer(FileTransferID.make(), name: "unsolicited", bytes: 1, type: nil))
        XCTAssertEqual(sent.last?.status, FileTransferStatus.notAllowed.rawValue)
        XCTAssertEqual(engine.pendingRequest, id)
        engine.reset(); XCTAssertNil(engine.pendingRequest)
    }
}
