import XCTest
@testable import PocketDeskRemote

@MainActor
final class PhoneFileTransferTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneFileTransferTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func offer(_ transfer: String, bytes: Int64) -> FileFrame {
        .offer(transfer, name: "photo.heic", bytes: bytes, type: nil)
    }

    func testLowSpaceRefusesWithOnlyAStatusCode() throws {
        let files = PhoneFileTransfer(destination: { self.folder }, staging: folder, availableSpace: { _ in 10_000_000 })
        var sent: [FileFrame] = []
        files.engine.sendControl = { sent.append($0); return true }
        let transfer = try files.engine.request().get()
        files.engine.receive(offer(transfer, bytes: 5_000_000))
        let result = try XCTUnwrap(sent.last)
        XCTAssertEqual(result.op, "result")
        XCTAssertEqual(result.status, FileTransferStatus.diskFull.rawValue)
        XCTAssertNil(result.bytes, "the free-space value never leaves the phone")
        XCTAssertEqual(files.notice?.message, PhoneFileTransfer.message(receiving: .diskFull))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testAcceptsTheRequestedFileWhenThereIsRoom() throws {
        let files = PhoneFileTransfer(destination: { self.folder }, staging: folder, availableSpace: { _ in nil })
        var sent: [FileFrame] = []
        files.engine.sendControl = { sent.append($0); return true }
        let transfer = try files.engine.request().get()
        XCTAssertTrue(files.waitingForMac)
        files.engine.receive(offer(transfer, bytes: 3))
        XCTAssertEqual(files.snapshot?.direction, .incoming)
        XCTAssertEqual(files.snapshot?.name, "photo.heic")
        files.reset()
    }

    func testUnrequestedOfferIsRefused() {
        let files = PhoneFileTransfer(destination: { self.folder }, staging: folder, availableSpace: { _ in nil })
        var sent: [FileFrame] = []
        files.engine.sendControl = { sent.append($0); return true }
        files.engine.receive(offer(FileTransferID.make(), bytes: 3))
        XCTAssertEqual(sent.last?.status, FileTransferStatus.notAllowed.rawValue)
        XCTAssertNil(files.snapshot)
    }

    func testBackgroundingCancelsAndExplains() throws {
        let files = PhoneFileTransfer(destination: { self.folder }, staging: folder, availableSpace: { _ in nil })
        var sent: [FileFrame] = []
        files.engine.sendControl = { sent.append($0); return true }
        let source = folder.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: source)
        var released = false
        XCTAssertNil(files.send(fileAt: source) { released = true })
        XCTAssertEqual(sent.last?.op, "offer")
        files.stopForBackground()
        XCTAssertEqual(sent.last?.op, "cancel")
        XCTAssertTrue(released)
        XCTAssertEqual(files.notice?.message, "Transfer stopped when Farside left the screen. Send again.")
        XCTAssertFalse(files.isBusy)
    }

    func testFoldersAreRefusedLocally() {
        let files = PhoneFileTransfer(destination: { self.folder }, staging: folder, availableSpace: { _ in nil })
        files.engine.sendControl = { _ in XCTFail("nothing is offered"); return true }
        XCTAssertEqual(files.send(fileAt: folder), .unsupported)
    }

    func testLinkResultIsReported() throws {
        let files = PhoneFileTransfer(destination: { self.folder }, staging: folder, availableSpace: { _ in nil })
        var sent: [FileFrame] = []
        files.engine.sendControl = { sent.append($0); return true }
        var reported: FileTransferStatus?
        files.onLinkResult = { reported = $0 }
        XCTAssertTrue(files.sendLink(try XCTUnwrap(URL(string: "https://example.com/page"))))
        XCTAssertFalse(files.sendLink(try XCTUnwrap(URL(string: "https://example.com/other"))), "one link at a time")
        let link = try XCTUnwrap(sent.last)
        XCTAssertNoThrow(try link.validate())
        files.engine.receive(.result(link.transfer, .offered))
        XCTAssertEqual(reported, .offered)
        XCTAssertEqual(files.notice?.tone, .success)
    }
}

@MainActor
final class SendToMacTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SendToMacTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func item(_ kind: SendToMacItem.Kind, immediate: Bool, created: Date = Date(), text: String? = nil) -> SendToMacItem {
        SendToMacItem(id: SendToMacOutbox.makeID(), kind: kind, name: kind == .file ? "a.txt" : nil, bytes: kind == .file ? 5 : nil,
                      text: text, created: created, expires: created.addingTimeInterval(SendToMacItem.lifetime), immediate: immediate)
    }

    func testBeaconDistinguishesLiveConnectableAndStale() {
        let now = Date()
        var beacon = SendToMacBeacon(macName: "Studio", liveUntil: now.addingTimeInterval(10), lastConnected: now, filesSupported: true)
        XCTAssertTrue(beacon.isLive(at: now))
        beacon.liveUntil = nil
        XCTAssertFalse(beacon.isLive(at: now))
        XCTAssertTrue(beacon.isConnectable(at: now.addingTimeInterval(14 * 60)))
        XCTAssertFalse(beacon.isConnectable(at: now.addingTimeInterval(16 * 60)), "an unreachable Mac gets a message, not a queue")
        SendToMacOutbox.storeBeacon(beacon, root: root)
        XCTAssertEqual(SendToMacOutbox.loadBeacon(root: root), beacon)
        SendToMacOutbox.storeBeacon(nil, root: root)
        XCTAssertNil(SendToMacOutbox.loadBeacon(root: root))
    }

    func testOutboxDropsExpiredItemsAndRejectsForeignIDs() throws {
        let old = item(.text, immediate: false, created: Date().addingTimeInterval(-SendToMacItem.lifetime - 1), text: "x")
        let fresh = item(.text, immediate: false, text: "y")
        try SendToMacOutbox.stage(old, root: root)
        try SendToMacOutbox.stage(fresh, root: root)
        XCTAssertEqual(SendToMacOutbox.pending(root: root).map(\.id), [fresh.id])
        let bad = SendToMacItem(id: "../../escape", kind: .text, text: "z", created: Date(), expires: Date().addingTimeInterval(60), immediate: false)
        XCTAssertThrowsError(try SendToMacOutbox.stage(bad, root: root))
    }

    func testImmediateFileSendsAndReportsProgress() throws {
        let staged = root.appendingPathComponent("incoming.txt")
        try Data("hello".utf8).write(to: staged)
        let file = item(.file, immediate: true)
        try SendToMacOutbox.stage(file, payload: staged, root: root)
        let inbox = SendToMacInbox(root: root)
        inbox.canSend = { true }
        var sentURL: URL?
        var release: (() -> Void)?
        inbox.sendFile = { url, _, done in sentURL = url; release = done; return nil }
        inbox.pendingTransfer = { "0123456789abcdef0123456789abcdef" }
        inbox.check()
        XCTAssertEqual(sentURL?.lastPathComponent, "payload")
        XCTAssertNil(inbox.offer, "staged while live: no second question")
        release?()
        inbox.transferChanged("0123456789abcdef0123456789abcdef", nil,
                              FileTransferFinish(transfer: "0123456789abcdef0123456789abcdef", direction: .outgoing,
                                                 name: "a.txt", status: .stored, savedURL: nil))
        XCTAssertEqual(SendToMacOutbox.loadReceipt(file.id, root: root)?.state, .sent)
        XCTAssertTrue(SendToMacOutbox.pending(root: root).isEmpty)
    }

    func testDeferredItemAsksFirstAndCanBeDiscarded() throws {
        let link = item(.link, immediate: false, text: "https://example.com")
        try SendToMacOutbox.stage(link, root: root)
        let inbox = SendToMacInbox(root: root)
        inbox.canSend = { false }
        inbox.check()
        XCTAssertNil(inbox.offer, "nothing is offered until a session can send")
        inbox.canSend = { true }
        var links: [URL] = []
        inbox.sendLink = { links.append($0); return true }
        inbox.check()
        XCTAssertEqual(inbox.offer?.id, link.id)
        XCTAssertTrue(links.isEmpty, "a deferred item waits for Send")
        inbox.discard()
        XCTAssertNil(inbox.offer)
        XCTAssertTrue(SendToMacOutbox.pending(root: root).isEmpty)
    }

    func testConfirmedTextGoesToTheClipboardPath() throws {
        let text = item(.text, immediate: false, text: "hello mac")
        try SendToMacOutbox.stage(text, root: root)
        let inbox = SendToMacInbox(root: root)
        inbox.canSendText = { true }
        var sentText: String?
        inbox.sendText = { sentText = $0; return true }
        inbox.check()
        inbox.confirm()
        XCTAssertEqual(sentText, "hello mac")
        XCTAssertEqual(SendToMacOutbox.loadReceipt(text.id, root: root)?.state, .sent)
    }
}
