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

    /// Batch-5 review: an older Mac drops its transfer on a new capture geometry without saying so.
    func testAMacGeometryChangeStopsTheTransferAndSaysWhy() throws {
        let files = PhoneFileTransfer(destination: { self.folder }, staging: folder, availableSpace: { _ in nil })
        var sent: [FileFrame] = []
        files.engine.sendControl = { sent.append($0); return true }
        files.stopForMacChange()
        XCTAssertTrue(sent.isEmpty, "nothing to stop, nothing sent")
        let request = try files.engine.request().get()
        files.stopForMacChange()
        XCTAssertFalse(files.isBusy)
        XCTAssertEqual(sent.last?.op, "cancel"); XCTAssertEqual(sent.last?.transfer, request)
        XCTAssertEqual(files.notice?.message, "Your Mac changed what it’s sharing, so the transfer stopped. Send it again.")
    }
    /// 1 Oct device report: File, Photo and From Mac all said only "isn't accepting files". A newer Mac says why.
    func testAMacRefusalSaysWhichConditionRefused() throws {
        let files = PhoneFileTransfer(destination: { self.folder }, staging: folder, availableSpace: { _ in nil })
        files.engine.sendControl = { _ in true }
        let request = try files.engine.request().get()
        files.engine.receive(.result(request, .notAllowed, reason: "viewOnly"))
        XCTAssertEqual(files.notice?.message, "Files are off in live view only (Picture in Picture). Return to control, then try again.")
        let older = try files.engine.request().get()
        files.engine.receive(.result(older, .notAllowed))
        XCTAssertEqual(files.notice?.message, "Your Mac isn’t sharing files right now.", "an older Mac keeps the old copy")
        for reason in ["noSession", "notSharing", "controlDisabled", "paused", "viewOnly", "locking", "lockFailed"] {
            XCTAssertNotNil(PhoneFileTransfer.message(refusal: reason, status: .notAllowed), reason)
        }
        XCTAssertNil(PhoneFileTransfer.message(refusal: "paused", status: .busy))
    }

    func testMidTransferStallSaysTheMacStoppedSending() throws {
        var now: TimeInterval = 1_000
        let files = PhoneFileTransfer(destination: { self.folder }, staging: folder, availableSpace: { _ in nil }, clock: { now })
        files.engine.sendControl = { _ in true }
        let transfer = try files.engine.request().get()
        files.engine.receive(offer(transfer, bytes: 3))
        XCTAssertEqual(files.snapshot?.direction, .incoming)
        now += FileTransferLimits.acceptTimeout + 1
        files.engine.checkTimeouts()
        XCTAssertNil(files.snapshot)
        XCTAssertEqual(files.notice?.message, "Your Mac stopped sending the file. Try again.")
    }

    func testUnansweredRequestSaysNothingWasChosen() throws {
        var now: TimeInterval = 1_000
        let files = PhoneFileTransfer(destination: { self.folder }, staging: folder, availableSpace: { _ in nil }, clock: { now })
        files.engine.sendControl = { _ in true }
        _ = try files.engine.request().get()
        now += FileTransferLimits.pickTimeout + 1
        files.engine.checkTimeouts()
        XCTAssertEqual(files.notice?.message, "Nothing was chosen on your Mac in time.")
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
        // Keep the existing synchronous semantic checks as coverage of the rollback path.
        let inbox = SendToMacInbox(root: root, useBackgroundIO: false)
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

    private func flush(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    func testBackgroundFilesystemLaneAndMainActorCompletion() async {
        let queue = DispatchQueue(label: "SendToMacTests.io", qos: .utility)
        let testRoot = root
        let io = SendToMacFileIO(rootProvider: {
            XCTAssertFalse(Thread.isMainThread, "App Group lookup must also stay off main")
            return testRoot
        }, useBackgroundIO: true, queue: queue)
        let finished = expectation(description: "main completion")
        io.read({ root in
            XCTAssertFalse(Thread.isMainThread, "container resolution and file operations run on the utility lane")
            return SendToMacOutbox.pending(root: root)
        }) { items in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(items.isEmpty)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
    }

    func testBackgroundBeaconUpdatesRemainOrderedAndPreserveRecentConnection() async {
        let queue = DispatchQueue(label: "SendToMacTests.beacon", qos: .utility)
        let io = SendToMacFileIO(root: root, useBackgroundIO: true, queue: queue)
        let connected = Date()
        io.updateBeacon(SendToMacBeacon(macName: "Studio", liveUntil: connected.addingTimeInterval(15),
                                       lastConnected: connected, filesSupported: true,
                                       destination: target, liveSessionID: liveID))
        io.updateBeacon(SendToMacBeacon(macName: "Renamed", filesSupported: false, destination: target))
        let stored = expectation(description: "beacon disconnected")
        io.read({ SendToMacOutbox.loadBeacon(root: $0) }) { beacon in
            XCTAssertEqual(beacon?.macName, "Renamed")
            XCTAssertEqual(beacon?.lastConnected, connected)
            XCTAssertEqual(beacon?.filesSupported, true)
            XCTAssertNil(beacon?.liveUntil)
            XCTAssertNil(beacon?.liveSessionID)
            stored.fulfill()
        }
        await fulfillment(of: [stored], timeout: 2)
        io.updateBeacon(nil)
        let cleared = expectation(description: "beacon cleared after queued writes")
        io.read({ SendToMacOutbox.loadBeacon(root: $0) }) { beacon in
            XCTAssertNil(beacon)
            cleared.fulfill()
        }
        await fulfillment(of: [cleared], timeout: 2)
    }

    func testBackgroundBurstSendsOnceAndPersistsReceiptBeforeRemoval() async throws {
        let shared = item(.text, immediate: true, text: "hello")
        try SendToMacOutbox.stage(shared, root: root)
        let queue = DispatchQueue(label: "SendToMacTests.burst", qos: .utility)
        let inbox = SendToMacInbox(root: root, useBackgroundIO: true, ioQueue: queue)
        inbox.updateDestination(target, name: "Studio", liveSessionID: liveID)
        inbox.canSendText = { true }
        let sent = expectation(description: "sent once")
        sent.assertForOverFulfill = true
        var sends = 0
        inbox.sendText = { _ in
            XCTAssertTrue(Thread.isMainThread)
            sends += 1
            sent.fulfill()
            return true
        }
        queue.suspend()
        for _ in 0..<50 { inbox.check() }
        XCTAssertEqual(sends, 0, "check must return while the filesystem queue is blocked")
        queue.resume()
        await fulfillment(of: [sent], timeout: 2)
        await flush(queue)
        await flush(queue)
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(SendToMacOutbox.loadReceipt(shared.id, root: root)?.state, .sent)
        XCTAssertTrue(SendToMacOutbox.pending(root: root).isEmpty)
    }

    func testBackgroundScanRevalidatesActualDestinationAndSession() async throws {
        let shared = item(.text, immediate: true, text: "private for A")
        try SendToMacOutbox.stage(shared, root: root)
        let queue = DispatchQueue(label: "SendToMacTests.staleScan", qos: .utility)
        let inbox = SendToMacInbox(root: root, useBackgroundIO: true, ioQueue: queue)
        inbox.updateDestination(target, name: "Studio", liveSessionID: liveID)
        var actual: SendToMacDestination? = target
        var session: String? = liveID
        inbox.destinationNow = { actual }
        inbox.liveSessionNow = { session }
        inbox.canSendText = { true }
        var sends = 0
        inbox.sendText = { _ in sends += 1; return true }
        queue.suspend()
        inbox.check()
        actual = SendToMacDestination(hostRecordID: String(repeating: "d", count: 64), ownerPairID: String(repeating: "e", count: 64))
        queue.resume()
        await flush(queue)
        XCTAssertEqual(inbox.offer?.id, shared.id)
        inbox.confirm()
        XCTAssertEqual(sends, 0)
        queue.suspend()
        inbox.check()
        actual = target
        session = String(repeating: "f", count: 32)
        queue.resume()
        await flush(queue)
        XCTAssertEqual(sends, 0, "returning to A in a new session during I/O requires confirmation")
        XCTAssertEqual(inbox.offer?.id, shared.id)
        XCTAssertEqual(SendToMacOutbox.pending(root: root).map(\.id), [shared.id])
    }

    func testBackgroundRetargetCannotSendAfterSessionChangesOrDiscard() async throws {
        let shared = item(.text, immediate: false, text: "private")
        try SendToMacOutbox.stage(shared, root: root)
        let queue = DispatchQueue(label: "SendToMacTests.retarget", qos: .utility)
        let inbox = SendToMacInbox(root: root, useBackgroundIO: true, ioQueue: queue)
        inbox.updateDestination(target, name: "Studio", liveSessionID: liveID)
        inbox.canSendText = { true }
        var sends = 0
        inbox.sendText = { _ in sends += 1; return true }
        inbox.check()
        await flush(queue)
        XCTAssertEqual(inbox.offer?.id, shared.id)
        queue.suspend()
        inbox.retargetAndConfirm(to: target)
        inbox.updateDestination(target, name: "Studio", liveSessionID: String(repeating: "d", count: 32))
        queue.resume()
        await flush(queue)
        await flush(queue)
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(inbox.offer?.id, shared.id)
        queue.suspend()
        inbox.retargetAndConfirm(to: target)
        inbox.discard()
        queue.resume()
        await flush(queue)
        await flush(queue)
        XCTAssertEqual(sends, 0, "discard invalidates the in-flight explicit confirmation")
        XCTAssertNil(inbox.offer)
        XCTAssertTrue(SendToMacOutbox.pending(root: root).isEmpty)
    }

    func testBackgroundFilePreparationRevalidatesSessionBeforeEngineSend() async throws {
        let payload = root.appendingPathComponent("incoming.txt")
        try Data("hello".utf8).write(to: payload)
        let shared = item(.file, immediate: true)
        try SendToMacOutbox.stage(shared, payload: payload, root: root)
        let queue = DispatchQueue(label: "SendToMacTests.filePreparation", qos: .utility)
        let inbox = SendToMacInbox(root: root, useBackgroundIO: true, ioQueue: queue)
        inbox.updateDestination(target, name: "Studio", liveSessionID: liveID)
        let closed = expectation(description: "abandoned prepared descriptor closed off main")
        let destination = target
        inbox.prepareFile = { [weak inbox] url in
            XCTAssertFalse(Thread.isMainThread, "payload stat and open must stay off main")
            let source = try FileHandleByteSource(url: url, onClose: {
                XCTAssertFalse(Thread.isMainThread)
                closed.fulfill()
            })
            // The open/stat completed, then authority changes before its result reaches main.
            DispatchQueue.main.async {
                inbox?.updateDestination(destination, name: "Studio", liveSessionID: String(repeating: "d", count: 32))
            }
            return source
        }
        inbox.canSend = { true }
        var sends = 0
        inbox.sendFile = { _, _, _ in sends += 1; return nil }
        inbox.check()
        for _ in 0..<4 { await flush(queue) }
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(inbox.offer?.id, shared.id)
        XCTAssertEqual(SendToMacOutbox.pending(root: root).map(\.id), [shared.id], "stale preparation must retain the payload")
    }

    func testBackgroundPreparedFileEntersRealEngineOnMainAndClosesOffMain() async throws {
        let payload = root.appendingPathComponent("prepared.txt")
        try Data("hello".utf8).write(to: payload)
        let shared = item(.file, immediate: true)
        try SendToMacOutbox.stage(shared, payload: payload, root: root)
        let queue = DispatchQueue(label: "SendToMacTests.preparedEngine", qos: .utility)
        let inbox = SendToMacInbox(root: root, useBackgroundIO: true, ioQueue: queue)
        let idle = PhoneIdleTimer { _ in }
        let files = PhoneFileTransfer(idleTimer: idle)
        files.engine.sendControl = { _ in true }
        files.receipts = { [weak inbox] in inbox?.transferChanged($0, $1, $2) }
        inbox.updateDestination(target, name: "Studio", liveSessionID: liveID)
        inbox.canSend = { true }
        let admitted = expectation(description: "prepared payload admitted on main")
        let closed = expectation(description: "engine closes descriptor off main")
        inbox.prepareFile = { url in
            XCTAssertFalse(Thread.isMainThread)
            return try FileHandleByteSource(url: url, onClose: {
                XCTAssertFalse(Thread.isMainThread)
                closed.fulfill()
            })
        }
        inbox.sendPreparedFile = { source, url, name, release in
            XCTAssertTrue(Thread.isMainThread)
            let status = files.send(prepared: source, url: url, name: name, release: release)
            XCTAssertNil(status)
            admitted.fulfill()
            return status
        }
        inbox.pendingTransfer = { files.engine.outgoing?.transfer }
        inbox.check()
        await fulfillment(of: [admitted], timeout: 2)
        XCTAssertEqual(files.snapshot?.total, 5)
        files.reset()
        await fulfillment(of: [closed], timeout: 2)
        await flush(queue)
        XCTAssertNil(files.snapshot)
        XCTAssertTrue(SendToMacOutbox.pending(root: root).isEmpty)
    }

    func testPreparedEmptyFileRefusalClosesOffMainAndStoresFailure() async throws {
        let payload = root.appendingPathComponent("empty.txt")
        try Data().write(to: payload)
        let shared = item(.file, immediate: true)
        try SendToMacOutbox.stage(shared, payload: payload, root: root)
        let queue = DispatchQueue(label: "SendToMacTests.preparedRefusal", qos: .utility)
        let inbox = SendToMacInbox(root: root, useBackgroundIO: true, ioQueue: queue)
        let files = PhoneFileTransfer(idleTimer: PhoneIdleTimer { _ in })
        inbox.updateDestination(target, name: "Studio", liveSessionID: liveID)
        inbox.canSend = { true }
        let refused = expectation(description: "empty payload refused on main")
        let closed = expectation(description: "refused descriptor closed off main")
        inbox.prepareFile = { url in
            XCTAssertFalse(Thread.isMainThread)
            return try FileHandleByteSource(url: url, onClose: {
                XCTAssertFalse(Thread.isMainThread)
                closed.fulfill()
            })
        }
        inbox.sendPreparedFile = { source, url, name, release in
            XCTAssertTrue(Thread.isMainThread)
            let status = files.send(prepared: source, url: url, name: name, release: release)
            XCTAssertEqual(status, .empty)
            refused.fulfill()
            return status
        }
        inbox.check()
        await fulfillment(of: [refused, closed], timeout: 2)
        await flush(queue)
        XCTAssertEqual(SendToMacOutbox.loadReceipt(shared.id, root: root)?.state, .failed)
        XCTAssertTrue(SendToMacOutbox.pending(root: root).isEmpty)
    }

    func testPayloadOpenFailureReportsOnMainAndRemovesItem() async throws {
        let shared = item(.file, immediate: true)
        try SendToMacOutbox.stage(shared, root: root) // Missing payload, as after a failed extension handoff.
        let queue = DispatchQueue(label: "SendToMacTests.failedOpen", qos: .utility)
        let inbox = SendToMacInbox(root: root, useBackgroundIO: true, ioQueue: queue)
        inbox.updateDestination(target, name: "Studio", liveSessionID: liveID)
        inbox.canSend = { true }
        inbox.prepareFile = { url in
            XCTAssertFalse(Thread.isMainThread)
            return try FileHandleByteSource(url: url)
        }
        let failed = expectation(description: "payload error reported on main")
        inbox.preparationFailed = { status in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(status, .unreadable)
            failed.fulfill()
        }
        inbox.sendPreparedFile = { _, _, _, _ in XCTFail("unopened payload cannot enter the engine"); return .unreadable }
        inbox.check()
        await fulfillment(of: [failed], timeout: 2)
        await flush(queue)
        XCTAssertEqual(SendToMacOutbox.loadReceipt(shared.id, root: root)?.state, .failed)
        XCTAssertTrue(SendToMacOutbox.pending(root: root).isEmpty)
    }

}
