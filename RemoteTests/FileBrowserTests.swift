import XCTest
import Darwin

func fileBrowserTestCanonicalURL(_ url: URL) throws -> URL {
    guard let path = realpath(url.path, nil) else { throw FileTransferStatus.unreadable }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path))
}

final class FileBrowserTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("file-browser-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return try fileBrowserTestCanonicalURL(url)
    }
    func testProtocolRejectsPathsAndMalformedDownload() throws {
        XCTAssertThrowsError(try FileBrowserRequest(operation: .list, entry: "../../private").validate())
        XCTAssertThrowsError(try FileBrowserRequest(operation: .download, entry: InputCausalEnvelope.identity()).validate())
        XCTAssertThrowsError(try FileBrowserRequest(operation: .roots, filter: "name").validate())
        XCTAssertNoThrow(try FileBrowserRequest(operation: .list, entry: InputCausalEnvelope.identity(), filter: "résumé").validate())
        let injected = try WorkspaceFrame(kind: .files, requestID: InputCausalEnvelope.identity(), value: ["operation": "roots", "path": "/private"])
        XCTAssertThrowsError(try FileBrowserRequest.decode(injected))
    }
    func testGrantBrowseFilterAndDescriptorRead() throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try Data("hello".utf8).write(to: folder.appendingPathComponent("résumé.txt"))
        try Data([1]).write(to: folder.appendingPathComponent("other.txt"))
        let access = FileBrowserAccess(), root = try access.grant(folder)
        let page = try access.list(root, offset: 0, filter: "résumé")
        XCTAssertEqual(page.entries.map(\.name), ["résumé.txt"])
        let (source, name) = try access.source(XCTUnwrap(page.entries.first?.id)); defer { source.close() }
        XCTAssertEqual(name, "résumé.txt"); XCTAssertEqual(try source.read(upTo: 100), Data("hello".utf8))
        XCTAssertEqual(try source.read(upTo: 100), Data())
    }
    func testSymlinksPackagesAliasesAndSpecialFilesAreUnavailable() throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("escape").path, withDestinationPath: "/etc")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Secret.app"), withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("alias"))
        var finderInfo = [UInt8](repeating: 0, count: 32); finderInfo[8] = 0x80
        XCTAssertEqual(finderInfo.withUnsafeBytes { setxattr(folder.appendingPathComponent("alias").path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, 0) }, 0)
        XCTAssertEqual(mkfifo(folder.appendingPathComponent("pipe").path, 0o600), 0)
        try Data([1]).write(to: folder.appendingPathComponent("cloud.icloud"))
        let access = FileBrowserAccess(), root = try access.grant(folder)
        let page = try access.list(root, offset: 0, filter: "")
        XCTAssertEqual(page.entries.count, 5); XCTAssertTrue(page.entries.allSatisfy { $0.kind == .unsupported })
        for item in page.entries { XCTAssertThrowsError(try access.source(item.id)) }
        XCTAssertThrowsError(try access.grant(folder.appendingPathComponent("escape")))
    }
    func testFileReplacementBetweenListingAndOpenIsRejected() throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("item.txt"); try Data([1]).write(to: file)
        let access = FileBrowserAccess(), root = try access.grant(folder)
        let entry = try XCTUnwrap(access.list(root, offset: 0, filter: "").entries.first)
        try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent("old.txt")); try Data([2]).write(to: file)
        XCTAssertThrowsError(try access.source(entry.id))
    }
    func testDirectoryComponentSubstitutionIsRejected() throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let child = folder.appendingPathComponent("child"); try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data([1]).write(to: child.appendingPathComponent("item.txt"))
        let access = FileBrowserAccess(), root = try access.grant(folder)
        let childEntry = try XCTUnwrap(access.list(root, offset: 0, filter: "").entries.first)
        let file = try XCTUnwrap(access.list(childEntry.id, offset: 0, filter: "").entries.first)
        try FileManager.default.moveItem(at: child, to: folder.appendingPathComponent("old"))
        try FileManager.default.createSymbolicLink(atPath: child.path, withDestinationPath: "/etc")
        XCTAssertThrowsError(try access.list(childEntry.id, offset: 0, filter: "")); XCTAssertThrowsError(try access.source(file.id))
    }
    func testRetainedDescriptorDoesNotReadReplacementAndEditsFail() throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("item.txt"); try Data("original".utf8).write(to: file)
        let access = FileBrowserAccess(), root = try access.grant(folder)
        let entry = try XCTUnwrap(access.list(root, offset: 0, filter: "").entries.first)
        let (source, _) = try access.source(entry.id)
        try Data("different".utf8).write(to: file) // edit same inode
        XCTAssertThrowsError(try source.read(upTo: 100)); source.close()
    }
    func testRevocationAndSessionResetCloseSourcesAndEntryAuthority() throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try Data([1]).write(to: folder.appendingPathComponent("item.txt"))
        let access = FileBrowserAccess(), root = try access.grant(folder)
        let entry = try XCTUnwrap(access.list(root, offset: 0, filter: "").entries.first)
        let (source, _) = try access.source(entry.id)
        access.resetEntries(); XCTAssertTrue(source.isClosed); XCTAssertThrowsError(try access.source(entry.id))
        let next = try XCTUnwrap(access.list(root, offset: 0, filter: "").entries.first)
        let (second, _) = try access.source(next.id)
        access.revoke(root); XCTAssertTrue(second.isClosed); XCTAssertThrowsError(try second.read(upTo: 1))
        XCTAssertThrowsError(try access.list(root, offset: 0, filter: "")); XCTAssertTrue(access.rootEntries().isEmpty)
    }
    func testRetiredOperationLeaseFencesQueuedEnumerationAndReads() throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try Data([1]).write(to: folder.appendingPathComponent("item.txt"))
        let access = FileBrowserAccess(), root = try access.grant(folder), lease = TransferEffectLease()
        let entry = try XCTUnwrap(access.list(root, offset: 0, filter: "").entries.first)
        let (source, _) = try access.source(entry.id, authorized: { lease.isActive })
        lease.closeAdmission()
        XCTAssertThrowsError(try access.list(root, offset: 0, filter: "", authorized: { lease.isActive }))
        XCTAssertThrowsError(try source.read(upTo: 1)); source.close()
    }

    func testWorstCaseMetadataFitsEightKiBPayloadAndControlEnvelope() throws {
        let entries = (0..<16).map { _ in FileBrowserEntry(id: InputCausalEnvelope.identity(), name: String(repeating: "\"", count: 128), kind: .unsupported, bytes: Int64.max, modified: Double.greatestFiniteMagnitude) }
        let reply = FileBrowserReply(status: .ok, entries: entries, nextOffset: 100_000)
        XCTAssertLessThan(try JSONEncoder().encode(reply).count, 8 * 1024)
        let frame = try WorkspaceFrame(kind: .files, requestID: InputCausalEnvelope.identity(), value: reply)
        let packet = ControlPacket(session: String(repeating: "S", count: 64), sequence: .max, action: .workspace(frame, epoch: .max))
        XCTAssertLessThan(try JSONEncoder().encode(packet).count, 16 * 1024)
    }

    func testPaginationIsBoundedAndEnumerationCancellationStopsResults() throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<100 { try Data([1]).write(to: folder.appendingPathComponent("item-\(index).txt")) }
        let access = FileBrowserAccess(), root = try access.grant(folder)
        let first = try access.list(root, offset: 0, filter: ""); XCTAssertEqual(first.entries.count, 16)
        XCTAssertLessThan(try JSONEncoder().encode(first).count, WorkspaceUtilities.maximumPayloadBytes)
        let second = try access.list(root, offset: XCTUnwrap(first.nextOffset), filter: "")
        XCTAssertTrue(Set(first.entries.map(\.name)).isDisjoint(with: second.entries.map(\.name)))
        access.cancelEnumeration(); XCTAssertThrowsError(try access.list(root, offset: 0, filter: ""))
    }
}
