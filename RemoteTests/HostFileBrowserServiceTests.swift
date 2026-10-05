import XCTest

@MainActor
final class HostFileBrowserServiceTests: XCTestCase {
    private func fixture() throws -> (FileBrowserAccess, String, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("host-browser-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let canonical = try fileBrowserTestCanonicalURL(url)
        try Data([1,2,3]).write(to: canonical.appendingPathComponent("file.txt"))
        let access = FileBrowserAccess(); return (access, try access.grant(canonical), canonical)
    }
    func testCurrentPolicyGateDeniesRootsAndDownload() throws {
        let (access, root, url) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let service = HostFileBrowserService(access: access), engine = FileTransferEngine(acceptsUnsolicitedOffers: true)
        service.engine = engine
        var replies: [WorkspaceFrame] = [], results: [FileFrame] = []
        service.reply = { replies.append($0) }; engine.sendControl = { results.append($0); return true }
        service.receive(try WorkspaceFrame(kind: .files, requestID: InputCausalEnvelope.identity(), value: FileBrowserRequest(operation: .roots)))
        XCTAssertEqual(try replies.first?.decode(FileBrowserReply.self).status, .notAllowed)
        XCTAssertEqual(try replies.first?.decode(FileBrowserReply.self).entries, [])
        let entry = try XCTUnwrap(access.list(root, offset: 0, filter: "").entries.first), transfer = FileTransferID.make()
        service.receive(try WorkspaceFrame(kind: .files, requestID: InputCausalEnvelope.identity(), value: FileBrowserRequest(operation: .download, entry: entry.id, transfer: transfer)))
        XCTAssertEqual(results.last?.transfer, transfer); XCTAssertEqual(results.last?.status, "notAllowed")
        XCTAssertNil(engine.outgoing)
    }
    func testAuthorityLostBeforeQueuedPublicationDropsEnumeration() async throws {
        let (access, root, url) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let service = HostFileBrowserService(access: access); var allowed = true, replies: [WorkspaceFrame] = []
        service.allowed = { allowed }; service.reply = { replies.append($0) }
        service.receive(try WorkspaceFrame(kind: .files, requestID: InputCausalEnvelope.identity(), value: FileBrowserRequest(operation: .list, entry: root)))
        allowed = false; service.reset()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(replies.isEmpty)
    }
    func testRootsAndQueuedListAreReachableUnderAuthority() async throws {
        let (access, root, url) = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let service = HostFileBrowserService(access: access); var replies: [WorkspaceFrame] = []
        service.allowed = { true }; service.reply = { replies.append($0) }
        service.receive(try WorkspaceFrame(kind: .files, requestID: InputCausalEnvelope.identity(), value: FileBrowserRequest(operation: .roots)))
        XCTAssertEqual(try replies.first?.decode(FileBrowserReply.self).entries.first?.id, root)
        service.receive(try WorkspaceFrame(kind: .files, requestID: InputCausalEnvelope.identity(), value: FileBrowserRequest(operation: .list, entry: root)))
        let deadline = Date().addingTimeInterval(2)
        while replies.count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(try replies.last?.decode(FileBrowserReply.self).entries.first?.name, "file.txt")
    }
}
