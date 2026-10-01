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

    func testRealEngineCompletionAndResetReleaseOnlyTheirTransferOwnership() throws {
        let idle = PhoneIdleTimer { _ in }
        idle.setForeground(true)
        idle.updateSession(authenticated: true, paused: false, concealed: false)
        let files = PhoneFileTransfer(destination: { self.folder }, staging: folder,
                                      availableSpace: { _ in nil }, idleTimer: idle)
        files.engine.sendControl = { _ in true }
        let id = try files.engine.request().get()
        XCTAssertTrue(idle.isDisabled)
        files.engine.receive(.result(id, .cancelled))
        XCTAssertFalse(files.isBusy)
        XCTAssertTrue(idle.isDisabled, "Completion cannot release the session owner")
        _ = try files.engine.request().get()
        idle.endSession()
        XCTAssertTrue(idle.isDisabled)
        files.reset()
        XCTAssertFalse(idle.isDisabled)
    }
    func testBackgroundReleasesTransferAndShortLinkDoesNotOwnIdleTimer() throws {
        let idle = PhoneIdleTimer { _ in }
        idle.setForeground(true)
        let files = PhoneFileTransfer(destination: { self.folder }, staging: folder,
                                      availableSpace: { _ in nil }, idleTimer: idle)
        var sent: [FileFrame] = []
        files.engine.sendControl = { sent.append($0); return true }
        XCTAssertTrue(files.sendLink(try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertFalse(idle.isDisabled, "An unanswered short link cannot hold the screen indefinitely")
        files.engine.receive(.result(try XCTUnwrap(sent.last).transfer, .copied))
        XCTAssertFalse(idle.isDisabled)
        _ = try files.engine.request().get()
        XCTAssertTrue(idle.isDisabled)
        idle.setForeground(false)
        XCTAssertFalse(idle.isDisabled)
        idle.setForeground(true)
        files.refreshIdleTimer()
        XCTAssertTrue(idle.isDisabled, "Only a still-current engine may reacquire after temporary inactivity")
        files.stopForBackground()
        XCTAssertFalse(idle.isDisabled)
        XCTAssertFalse(files.isBusy)
        files.refreshIdleTimer()
        XCTAssertFalse(idle.isDisabled)
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
    private let target = SendToMacDestination(hostRecordID: String(repeating: "a", count: 64), ownerPairID: String(repeating: "b", count: 64))
    private let liveID = String(repeating: "c", count: 32)

    private func configuredInbox() -> SendToMacInbox {
        let inbox = SendToMacInbox(root: root)
        inbox.updateDestination(target, name: "Studio", liveSessionID: liveID)
        return inbox
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SendToMacTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func item(_ kind: SendToMacItem.Kind, immediate: Bool, created: Date = Date(), text: String? = nil) -> SendToMacItem {
        SendToMacItem(id: SendToMacOutbox.makeID(), kind: kind, name: kind == .file ? "a.txt" : nil, bytes: kind == .file ? 5 : nil,
                      text: text, created: created, expires: created.addingTimeInterval(SendToMacItem.lifetime), immediate: immediate,
                      destination: target, destinationName: "Studio", liveSessionID: liveID)
    }

    func testBeaconDistinguishesLiveConnectableAndStale() {
        let now = Date()
        var beacon = SendToMacBeacon(macName: "Studio", liveUntil: now.addingTimeInterval(10), lastConnected: now, filesSupported: true, destination: target, liveSessionID: liveID)
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
        let inbox = configuredInbox()
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
        let inbox = configuredInbox()
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
        let inbox = configuredInbox()
        inbox.canSendText = { true }
        var sentText: String?
        inbox.sendText = { sentText = $0; return true }
        inbox.check()
        inbox.confirm()
        XCTAssertEqual(sentText, "hello mac")
        XCTAssertEqual(SendToMacOutbox.loadReceipt(text.id, root: root)?.state, .sent)
    }

    func testSwitchToOtherMacBlocksImmediateAndOrdinaryConfirm() throws {
        let shared = item(.text, immediate: true, text: "private for A")
        try SendToMacOutbox.stage(shared, root: root)
        let inbox = configuredInbox()
        let other = SendToMacDestination(hostRecordID: String(repeating: "d", count: 64), ownerPairID: String(repeating: "e", count: 64))
        inbox.updateDestination(other, name: "Mac B", liveSessionID: liveID)
        inbox.canSendText = { true }
        var sent = 0
        inbox.sendText = { _ in sent += 1; return true }
        inbox.check()
        inbox.confirm()
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(inbox.offer?.id, shared.id)
        inbox.retargetAndConfirm(to: target)
        XCTAssertEqual(sent, 0, "a stale retarget button cannot substitute the current target")
        inbox.retargetAndConfirm(to: other)
        XCTAssertEqual(sent, 1, "only explicit retarget authorizes sending to B")
    }

    func testReturningToSameMacInNewSessionCannotAutoSend() throws {
        let shared = item(.text, immediate: true, text: "private")
        try SendToMacOutbox.stage(shared, root: root)
        let inbox = configuredInbox()
        inbox.updateDestination(nil, name: nil, liveSessionID: nil)
        inbox.updateDestination(target, name: "Studio", liveSessionID: String(repeating: "d", count: 32))
        inbox.canSendText = { true }
        var sent = 0
        inbox.sendText = { _ in sent += 1; return true }
        inbox.check()
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(inbox.offer?.id, shared.id)
        inbox.confirm()
        XCTAssertEqual(sent, 1, "same grant still allows an explicit confirmation")
    }

    func testReplacementGrantOnSameHostRequiresExplicitRetarget() throws {
        var shared = item(.text, immediate: true, text: "private")
        shared.destination?.ownerPairID = String(repeating: "f", count: 64)
        try SendToMacOutbox.stage(shared, root: root)
        let inbox = configuredInbox()
        inbox.canSendText = { true }
        var sent = 0
        inbox.sendText = { _ in sent += 1; return true }
        inbox.check()
        inbox.confirm()
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(inbox.offer?.id, shared.id)
    }

    func testLegacyDestinationlessItemNeverAutomaticallySends() throws {
        var shared = item(.text, immediate: true, text: "legacy")
        shared.destination = nil
        shared.liveSessionID = nil
        try SendToMacOutbox.stage(shared, root: root)
        let inbox = configuredInbox()
        inbox.canSendText = { true }
        var sent = 0
        inbox.sendText = { _ in sent += 1; return true }
        inbox.check()
        inbox.confirm()
        XCTAssertEqual(sent, 0)
        XCTAssertNotNil(inbox.offer)
        inbox.retargetAndConfirm(to: target)
        XCTAssertEqual(sent, 1)
    }

    func testMalformedDestinationAndFutureOrExpiredItemsAreNeverAutomatic() {
        let now = Date()
        var shared = item(.text, immediate: true, created: now.addingTimeInterval(1), text: "future")
        XCTAssertFalse(shared.canAutomaticallySend(to: target, liveSessionID: liveID, at: now))
        shared.destination?.hostRecordID = "../../escape"
        XCTAssertFalse(shared.isBound(to: shared.destination))
        let expired = item(.text, immediate: true, created: now.addingTimeInterval(-601), text: "expired")
        XCTAssertFalse(expired.canAutomaticallySend(to: target, liveSessionID: liveID, at: now))
    }

    func testLegacyBeaconDecodesButCannotAdvertiseAutomaticDestination() throws {
        let data = Data(#"{"macName":"Legacy","liveUntil":999999999,"lastConnected":999999999,"filesSupported":true}"#.utf8)
        let beacon = try JSONDecoder().decode(SendToMacBeacon.self, from: data)
        XCTAssertNil(beacon.destination)
        XCTAssertFalse(beacon.isLive(at: Date(timeIntervalSinceReferenceDate: 100)))
        XCTAssertFalse(beacon.isConnectable(at: Date(timeIntervalSinceReferenceDate: 100)))
    }

    func testSelectionChangesBeforePublishedBeaconRefreshCannotLeakItem() throws {
        let shared = item(.text, immediate: true, text: "only A")
        try SendToMacOutbox.stage(shared, root: root)
        let inbox = configuredInbox() // UI still displays A
        var actual: SendToMacDestination? = target
        inbox.destinationNow = { actual }
        inbox.liveSessionNow = { self.liveID }
        inbox.canSendText = { true }
        var sent = 0
        inbox.sendText = { _ in sent += 1; return true }
        actual = SendToMacDestination(hostRecordID: String(repeating: "d", count: 64), ownerPairID: String(repeating: "e", count: 64))
        inbox.check()
        inbox.confirm()
        inbox.retargetAndConfirm(to: target)
        XCTAssertEqual(sent, 0, "send boundary must read actual selected pair, even while the UI still shows A")
        actual = nil
        inbox.confirm()
        XCTAssertEqual(sent, 0, "missing current trust must not fall back to cached A")
    }

}
