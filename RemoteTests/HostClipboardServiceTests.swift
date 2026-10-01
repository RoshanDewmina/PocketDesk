import XCTest
import AppKit

private final class FakePasteboard: HostPasteboardAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var result: HostPasteboardRead = .refused(.empty)
    private var stored: [ClipboardPayload] = []
    private var readCount = 0
    private var countReadCount = 0
    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
    var countReads: Int { lock.lock(); defer { lock.unlock() }; return countReadCount }
    var readGate: DispatchSemaphore?

    var changeCount: Int { lock.lock(); defer { lock.unlock() }; countReadCount += 1; return count }
    var writes: [ClipboardPayload] { lock.lock(); defer { lock.unlock() }; return stored }

    func set(_ next: HostPasteboardRead) { lock.lock(); result = next; lock.unlock() }
    func bump() { lock.lock(); count += 1; lock.unlock() }

    func read(limit: Int) -> HostPasteboardRead {
        lock.lock(); readCount += 1; lock.unlock()
        readGate?.wait()
        lock.lock(); defer { lock.unlock() }
        return result
    }

    func write(_ payload: ClipboardPayload) -> Bool {
        lock.lock(); stored.append(payload); result = .text(payload); count += 1; lock.unlock()
        return true
    }
}

@MainActor
final class HostClipboardServiceTests: XCTestCase {
    private let transfer = "fedcba9876543210fedcba9876543210"
    private var sent: [ClipboardFrame] = []
    private var buffered: UInt64 = 0

    private func service(_ pasteboard: FakePasteboard, readTimeout: TimeInterval = 5, copyWait: TimeInterval = 0.3) -> HostClipboardService {
        sent = []
        let service = HostClipboardService(pasteboard: pasteboard, readTimeout: readTimeout, copyWait: copyWait,
                                           automaticPollInterval: 0.02)
        service.transport = { [unowned self] frame in
            XCTAssertNotNil(try? RemoteAction(action: "clipboard", clipboard: frame).validate())
            self.sent.append(frame)
            return true
        }
        service.bufferedAmount = { [unowned self] in self.buffered }
        return service
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) {
        let done = expectation(description: description)
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() { done.fulfill(); return }
            guard Date() < deadline else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
        }
        poll()
        wait(for: [done], timeout: timeout + 0.5)
    }

    private var results: [String] { sent.filter { $0.op == "result" }.compactMap(\.status) }

    private func settle(_ interval: TimeInterval = 0.1) {
        let done = expectation(description: "clipboard settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { done.fulfill() }
        wait(for: [done], timeout: interval + 1)
    }

    func testAutomaticWatchBaselinesThenExportsOnlyChangedTextWithEveryChunkMarked() {
        let pasteboard = FakePasteboard()
        pasteboard.set(.text(ClipboardPayload(text: "before session")))
        let clipboard = service(pasteboard)
        clipboard.reconcileAutomaticSync(allowed: true, peerSupports: true)
        waitUntil("baseline sampled") { pasteboard.countReads > 0 }
        XCTAssertEqual(pasteboard.reads, 0)
        XCTAssertTrue(sent.isEmpty)
        let text = String(repeating: "new copy", count: 2_000)
        pasteboard.set(.text(ClipboardPayload(text: text))); pasteboard.bump()
        waitUntil("automatic transfer") { self.sent.count == ClipboardLimits.chunkCount(forBytes: text.utf8.count) }
        XCTAssertTrue(sent.allSatisfy { $0.op == "data" && $0.automatic == true })
        var assembler = ClipboardAssembler()
        var outcome = ClipboardAssembler.Outcome.progress
        for frame in sent { outcome = assembler.accept(frame, at: 0) }
        XCTAssertEqual(outcome, .complete(transfer: sent[0].transfer, payload: ClipboardPayload(text: text)))
        clipboard.reset()
    }

    func testAutomaticWatchSilentlyRefusesConcealedAndOversizedItems() {
        let pasteboard = FakePasteboard()
        let watcher = service(pasteboard)
        watcher.reconcileAutomaticSync(allowed: true, peerSupports: true)
        waitUntil("baseline sampled") { pasteboard.countReads > 0 }
        pasteboard.set(.refused(.concealed)); pasteboard.bump()
        waitUntil("concealed observed") { pasteboard.reads == 1 }
        settle()
        XCTAssertTrue(sent.isEmpty)
        pasteboard.set(.text(ClipboardPayload(text: String(repeating: "x", count: ClipboardLimits.maximumBytes + 1))))
        pasteboard.bump()
        waitUntil("oversized observed") { pasteboard.reads == 2 }
        settle()
        XCTAssertTrue(sent.isEmpty)
        watcher.reset()
    }

    func testAutomaticWatchDeduplicatesAndDoesNotEchoPhoneWrites() throws {
        let pasteboard = FakePasteboard()
        let watcher = service(pasteboard)
        watcher.reconcileAutomaticSync(allowed: true, peerSupports: true)
        waitUntil("baseline sampled") { pasteboard.countReads > 0 }
        pasteboard.set(.text(ClipboardPayload(text: "host copy"))); pasteboard.bump()
        waitUntil("first copy delivered") { self.sent.count == 1 }
        pasteboard.bump()
        waitUntil("duplicate observed") { pasteboard.reads == 2 }
        settle()
        XCTAssertEqual(sent.count, 1)
        sent = []
        for frame in try ClipboardChunker.frames(for: ClipboardPayload(text: "phone copy"), operation: "push", transfer: transfer) {
            watcher.receive(frame, allowed: true)
        }
        waitUntil("phone copy stored") { self.results == ["stored"] }
        pasteboard.bump() // A later ownership change still containing the same phone copy.
        waitUntil("echo observed") { pasteboard.reads == 3 }
        settle()
        XCTAssertFalse(sent.contains { $0.op == "data" })
        watcher.reset()
    }

    func testAutomaticWatchNeedsCurrentAuthorityAndNewPeerCapability() {
        let pasteboard = FakePasteboard(), clipboard = service(pasteboard)
        clipboard.reconcileAutomaticSync(allowed: true, peerSupports: false)
        pasteboard.bump(); settle()
        XCTAssertEqual(pasteboard.countReads, 0)
        clipboard.reconcileAutomaticSync(allowed: false, peerSupports: true)
        pasteboard.bump(); settle()
        XCTAssertEqual(pasteboard.countReads, 0)
        clipboard.reset()
    }

    func testAutomaticRevocationCancelsQueuedReadAndAlreadyReadChunksAndRebaselines() {
        let pasteboard = FakePasteboard(), queue = DispatchQueue(label: "fixture.clipboard-automatic")
        let clipboard = HostClipboardService(pasteboard: pasteboard, queue: queue, automaticPollInterval: 0.02)
        sent = []; clipboard.transport = { self.sent.append($0); return true }
        clipboard.bufferedAmount = { self.buffered }
        clipboard.reconcileAutomaticSync(allowed: true, peerSupports: true)
        waitUntil("baseline sampled") { pasteboard.countReads > 0 }
        let queueGate = DispatchSemaphore(value: 0)
        queue.async { queueGate.wait() }; defer { queueGate.signal() }
        pasteboard.set(.text(ClipboardPayload(text: "queued secret"))); pasteboard.bump()
        settle()
        clipboard.reconcileAutomaticSync(allowed: false, peerSupports: true)
        queueGate.signal(); queue.sync {}; settle()
        XCTAssertEqual(pasteboard.reads, 0)
        clipboard.reconcileAutomaticSync(allowed: true, peerSupports: true)
        let baselineReads = pasteboard.countReads
        waitUntil("new baseline sampled") { pasteboard.countReads > baselineReads }
        buffered = ClipboardLimits.bufferedHighWater
        pasteboard.set(.text(ClipboardPayload(text: "blocked chunks"))); pasteboard.bump()
        waitUntil("read completed") { pasteboard.reads == 1 }
        settle()
        clipboard.reconcileAutomaticSync(allowed: false, peerSupports: true)
        buffered = 0; settle()
        XCTAssertTrue(sent.isEmpty)
        clipboard.reset()
    }

    func testAutomaticBlockedReadDoesNotAccumulateAndResetDiscardsLateResult() {
        let pasteboard = FakePasteboard(), clipboard = service(pasteboard)
        clipboard.reconcileAutomaticSync(allowed: true, peerSupports: true)
        waitUntil("baseline sampled") { pasteboard.countReads > 0 }
        let gate = DispatchSemaphore(value: 0); pasteboard.readGate = gate; defer { gate.signal() }
        pasteboard.set(.text(ClipboardPayload(text: "late secret"))); pasteboard.bump()
        waitUntil("automatic read entered") { pasteboard.reads == 1 }
        settle(0.15)
        XCTAssertEqual(pasteboard.reads, 1)
        let countReads = pasteboard.countReads
        for _ in 0..<4 {
            clipboard.reset()
            clipboard.reconcileAutomaticSync(allowed: true, peerSupports: true)
        }
        settle()
        XCTAssertEqual(pasteboard.countReads, countReads, "A replacement session must not queue polling behind a blocked provider")
        clipboard.reset(); gate.signal(); settle()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(clipboard.isIdle)
    }

    func testAutomaticPumpChecksLivePolicyBeforeReleasingBackpressuredChunks() {
        let pasteboard = FakePasteboard(), clipboard = service(pasteboard)
        var allowed = true
        clipboard.automaticPolicy = { allowed }
        clipboard.reconcileAutomaticSync(allowed: true, peerSupports: true)
        waitUntil("baseline sampled") { pasteboard.countReads > 0 }
        buffered = ClipboardLimits.bufferedHighWater
        pasteboard.set(.text(ClipboardPayload(text: "revoked after read"))); pasteboard.bump()
        waitUntil("automatic read completed") { pasteboard.reads == 1 }
        settle()
        allowed = false; buffered = 0; settle()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(clipboard.isIdle)
        clipboard.reset()
    }

    func testStoppingAutomaticSyncPreservesAnExplicitPullOutbox() {
        let pasteboard = FakePasteboard(), clipboard = service(pasteboard)
        buffered = ClipboardLimits.bufferedHighWater
        pasteboard.set(.text(ClipboardPayload(text: "explicit request")))
        clipboard.receive(.pull(transfer), allowed: true)
        waitUntil("explicit read completed") { pasteboard.reads == 1 }
        settle()
        clipboard.reconcileAutomaticSync(allowed: false, peerSupports: false)
        buffered = 0
        waitUntil("explicit data still delivered") { self.sent.count == 1 }
        XCTAssertEqual(sent.first?.transfer, transfer)
        XCTAssertNil(sent.first?.automatic)
        clipboard.reset()
    }

    func testIncomingPhonePushFencesAnAlreadyStartedAutomaticRead() throws {
        let pasteboard = FakePasteboard(), clipboard = service(pasteboard)
        clipboard.reconcileAutomaticSync(allowed: true, peerSupports: true)
        waitUntil("baseline sampled") { pasteboard.countReads > 0 }
        let gate = DispatchSemaphore(value: 0); pasteboard.readGate = gate; defer { gate.signal() }
        pasteboard.set(.text(ClipboardPayload(text: "old host copy"))); pasteboard.bump()
        waitUntil("old automatic read entered") { pasteboard.reads == 1 }
        let text = String(repeating: "phone paste", count: 900)
        let frames = try ClipboardChunker.frames(for: ClipboardPayload(text: text), operation: "push", transfer: transfer)
        clipboard.receive(frames[0], allowed: true)
        gate.signal(); settle()
        XCTAssertFalse(sent.contains { $0.automatic == true }, "The first valid phone chunk supersedes an older automatic read")
        for frame in frames.dropFirst() { clipboard.receive(frame, allowed: true) }
        waitUntil("phone paste stored") { self.results == ["stored"] }
        XCTAssertEqual(pasteboard.writes, [ClipboardPayload(text: text)])
        XCTAssertFalse(sent.contains { $0.automatic == true })
        clipboard.reset()
    }

    func testIncomingPhonePushCancelsBackpressuredAutomaticChunks() throws {
        let pasteboard = FakePasteboard(), clipboard = service(pasteboard)
        clipboard.reconcileAutomaticSync(allowed: true, peerSupports: true)
        waitUntil("baseline sampled") { pasteboard.countReads > 0 }
        buffered = ClipboardLimits.bufferedHighWater
        pasteboard.set(.text(ClipboardPayload(text: String(repeating: "old host", count: 2_000)))); pasteboard.bump()
        waitUntil("automatic read completed") { pasteboard.reads == 1 }
        settle()
        let text = String(repeating: "phone paste", count: 900)
        let frames = try ClipboardChunker.frames(for: ClipboardPayload(text: text), operation: "push", transfer: transfer)
        clipboard.receive(frames[0], allowed: true)
        buffered = 0; settle()
        XCTAssertFalse(sent.contains { $0.automatic == true }, "Queued host chunks must not overwrite the phone's newer clipboard")
        for frame in frames.dropFirst() { clipboard.receive(frame, allowed: true) }
        waitUntil("phone paste stored") { self.results == ["stored"] }
        XCTAssertFalse(sent.contains { $0.automatic == true })
        clipboard.reset()
    }

    func testHostCopyRepeatingAnEarlierExportAfterPhonePushIsSentAgain() throws {
        let pasteboard = FakePasteboard(), clipboard = service(pasteboard)
        clipboard.reconcileAutomaticSync(allowed: true, peerSupports: true)
        waitUntil("baseline sampled") { pasteboard.countReads > 0 }
        pasteboard.set(.text(ClipboardPayload(text: "A"))); pasteboard.bump()
        waitUntil("A exported") { self.sent.contains { $0.automatic == true } }
        for frame in try ClipboardChunker.frames(for: ClipboardPayload(text: "B"), operation: "push", transfer: transfer) {
            clipboard.receive(frame, allowed: true)
        }
        waitUntil("B stored") { self.results == ["stored"] }
        sent = []
        pasteboard.set(.text(ClipboardPayload(text: "A"))); pasteboard.bump()
        waitUntil("new A exported again") { self.sent.count == 1 }
        XCTAssertEqual(sent.first?.data, Data("A".utf8))
        XCTAssertEqual(sent.first?.automatic, true)
        clipboard.reset()
    }

    func testAutomaticCopyPreparationDoesNotWaitForABlockedPasteboardProvider() {
        let pasteboard = FakePasteboard(), clipboard = service(pasteboard)
        clipboard.reconcileAutomaticSync(allowed: true, peerSupports: true)
        waitUntil("baseline sampled") { pasteboard.countReads > 0 }
        let gate = DispatchSemaphore(value: 0); pasteboard.readGate = gate; defer { gate.signal() }
        pasteboard.set(.text(ClipboardPayload(text: "blocked old copy"))); pasteboard.bump()
        waitUntil("automatic provider blocked") { pasteboard.reads == 1 }
        XCTAssertNil(clipboard.prepareForCopyShortcut(automatic: true), "Automatic Copy must post input without waiting for clipboard work")
        let explicit = clipboard.prepareForCopyShortcut(automatic: false)
        XCTAssertNotNil(explicit)
        XCTAssertEqual(explicit?.wait(timeout: .now()), .timedOut, "Legacy afterCopy still needs its ordered baseline")
        clipboard.reset(); gate.signal()
        waitUntil("explicit baseline eventually completes") { explicit?.wait(timeout: .now()) == .success }
    }

    func testHealthyCouchAuthorityExportsWithoutPictureAndStaleHeartbeatCancelsChunks() {
        let pasteboard = FakePasteboard(), clipboard = service(pasteboard)
        var health = CouchHealthInputs(routeLocal: true, provenLinkActive: true, heartbeatAge: 0.2,
            screenLocked: false, consoleUserActive: true, allowControl: true, accessibility: .granted, phonePaused: false)
        clipboard.automaticPolicy = { CouchHealth.isHealthy(health) }
        let enabled = HostControlPolicy.isEnabled(userConsent: true, accessibilityPermission: .granted,
            session: .couch, captureHealthy: false, couchHealthy: CouchHealth.isHealthy(health))
        XCTAssertTrue(enabled, "Couch control does not require a Picture capture")
        clipboard.reconcileAutomaticSync(allowed: enabled, peerSupports: true)
        waitUntil("Couch baseline sampled") { pasteboard.countReads > 0 }
        pasteboard.set(.text(ClipboardPayload(text: "Couch copy"))); pasteboard.bump()
        waitUntil("Couch copy exported") { self.sent.count == 1 }
        XCTAssertEqual(sent.first?.automatic, true)
        sent = []; buffered = ClipboardLimits.bufferedHighWater
        pasteboard.set(.text(ClipboardPayload(text: "queued Couch copy"))); pasteboard.bump()
        waitUntil("second Couch read completed") { pasteboard.reads == 2 }
        settle()
        health.heartbeatAge = CouchHealth.heartbeatLimit
        // No lifecycle reconciliation: the send path must recheck live Couch authority.
        buffered = 0; settle()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(clipboard.isIdle, "Use-time heartbeat expiry cancels queued chunks before the next health tick")
        clipboard.reset()
    }

    func testPushStoresTextOnlyAfterTheWholeTransferVerifies() throws {
        let pasteboard = FakePasteboard()
        let clipboard = service(pasteboard)
        let text = String(repeating: "línea 🙂\n", count: 900)
        let frames = try ClipboardChunker.frames(for: ClipboardPayload(text: text), operation: "push", transfer: transfer)
        for frame in frames.dropLast() { clipboard.receive(frame, allowed: true) }
        XCTAssertTrue(pasteboard.writes.isEmpty, "Nothing partial reaches the pasteboard")
        clipboard.receive(frames.last!, allowed: true)
        waitUntil("stored acknowledgment") { self.results == ["stored"] }
        XCTAssertEqual(pasteboard.writes, [ClipboardPayload(text: text)])
    }

    func testRefusedWhenControlIsNotAllowedAndOnBrokenSequences() throws {
        let pasteboard = FakePasteboard()
        let clipboard = service(pasteboard)
        let frames = try ClipboardChunker.frames(for: ClipboardPayload(text: String(repeating: "x", count: 9000)),
                                                 operation: "push", transfer: transfer)
        clipboard.receive(frames[0], allowed: false)
        XCTAssertEqual(results, ["notAllowed"])
        clipboard.receive(frames[1], allowed: true)
        XCTAssertEqual(results, ["notAllowed", "invalid"], "A chunk without its predecessor is refused")
        clipboard.receive(ClipboardFrame(op: "data", transfer: transfer, kind: "text", index: 0, count: 1, bytes: 1,
                                         digest: String(repeating: "0", count: 64), data: Data([0x41])), allowed: true)
        XCTAssertEqual(results.last, "invalid", "The host only accepts push frames and requests from the phone")
        XCTAssertTrue(pasteboard.writes.isEmpty)
    }

    func testPullSendsPacedChunksOnlyWhileTheControlBufferIsLow() throws {
        let pasteboard = FakePasteboard()
        let text = String(repeating: "0123456789", count: 2_000)
        pasteboard.set(.text(ClipboardPayload(text: text)))
        buffered = ClipboardLimits.bufferedHighWater
        let clipboard = service(pasteboard)
        clipboard.receive(.pull(transfer), allowed: true)
        let stalled = expectation(description: "held back by a full buffer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { stalled.fulfill() }
        wait(for: [stalled], timeout: 1)
        XCTAssertTrue(sent.isEmpty, "A busy control channel must not receive clipboard data")

        buffered = 0
        waitUntil("all chunks delivered") { self.sent.count == 5 }
        var assembler = ClipboardAssembler()
        var outcome = ClipboardAssembler.Outcome.progress
        for frame in sent { outcome = assembler.accept(frame, at: 0) }
        XCTAssertEqual(outcome, .complete(transfer: transfer, payload: ClipboardPayload(text: text)))
        XCTAssertTrue(clipboard.isIdle)
    }

    func testPullReportsRefusalsWithoutSendingData() {
        for status in [ClipboardStatus.concealed, .denied, .tooLarge, .unsupported, .empty] {
            let pasteboard = FakePasteboard()
            pasteboard.set(.refused(status))
            let clipboard = service(pasteboard)
            clipboard.receive(.pull(transfer), allowed: true)
            waitUntil("refusal \(status)") { self.results == [status.rawValue] }
            XCTAssertTrue(sent.allSatisfy { $0.data == nil })
        }
    }

    func testCopyShortcutPullWaitsForTheNewCopyOrReportsUnchanged() throws {
        let pasteboard = FakePasteboard()
        pasteboard.set(.text(ClipboardPayload(text: "fresh selection")))
        let clipboard = service(pasteboard, copyWait: 0.3)
        clipboard.prepareForCopyShortcut()
        clipboard.receive(.pull(transfer, afterCopy: true), allowed: true)
        waitUntil("unchanged pasteboard") { self.results == ["unchanged"] }

        sent = []
        clipboard.prepareForCopyShortcut()
        clipboard.receive(.pull(transfer, afterCopy: true), allowed: true)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { pasteboard.bump() }
        waitUntil("copied text delivered") { self.sent.contains { $0.op == "data" } }
        XCTAssertTrue(results.isEmpty)
    }

    func testBlockedPasteboardReadTimesOutWithoutBlockingTheMainThread() {
        let pasteboard = FakePasteboard()
        pasteboard.set(.text(ClipboardPayload(text: "late")))
        let gate = DispatchSemaphore(value: 0)
        pasteboard.readGate = gate
        defer { gate.signal(); gate.signal() }
        let clipboard = service(pasteboard, readTimeout: 0.3)
        clipboard.receive(.pull(transfer), allowed: true)
        clipboard.receive(.pull("0000000011111111"), allowed: true)
        XCTAssertEqual(results, ["busy"], "A second request while a read is outstanding is refused at once")
        waitUntil("read timeout") { self.results == ["busy", "busy"] }
        gate.signal()
        let settle = expectation(description: "late result ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 1)
        XCTAssertFalse(sent.contains { $0.op == "data" }, "A read that finishes after its timeout is discarded")
    }

    func testResetDiscardsInFlightWork() throws {
        let pasteboard = FakePasteboard()
        pasteboard.set(.text(ClipboardPayload(text: String(repeating: "z", count: 20_000))))
        buffered = ClipboardLimits.bufferedHighWater
        let clipboard = service(pasteboard)
        clipboard.receive(.pull(transfer), allowed: true)
        let queued = expectation(description: "read finished")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { queued.fulfill() }
        wait(for: [queued], timeout: 1)
        clipboard.reset()
        buffered = 0
        let settle = expectation(description: "nothing sent after reset")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 1)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(clipboard.isIdle)
    }
    func testQueuedCompletePushCannotWriteAfterResetAndSameIDFreshPushStillWorks() throws {
        let pasteboard = FakePasteboard(), queue = DispatchQueue(label: "fixture.clipboard-push"), gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }; defer { gate.signal() }
        let clipboard = HostClipboardService(pasteboard: pasteboard, queue: queue)
        var replies: [ClipboardFrame] = []; clipboard.transport = { replies.append($0); return true }
        for frame in try ClipboardChunker.frames(for: ClipboardPayload(text: "revoked"), operation: "push", transfer: transfer) { clipboard.receive(frame, allowed: true) }
        clipboard.reset()
        for frame in try ClipboardChunker.frames(for: ClipboardPayload(text: "current"), operation: "push", transfer: transfer) { clipboard.receive(frame, allowed: true) }
        gate.signal(); queue.sync {}
        waitUntil("current push reply") { replies.count == 1 }
        XCTAssertEqual(pasteboard.writes, [ClipboardPayload(text: "current")]); XCTAssertEqual(replies.first?.status, "stored")
    }
    func testQueuedReadDoesNotBeginAfterResetAndAlreadyStartedReadCannotExport() {
        let pasteboard = FakePasteboard(), queue = DispatchQueue(label: "fixture.clipboard-read"), gate = DispatchSemaphore(value: 0)
        pasteboard.set(.text(ClipboardPayload(text: "secret fixture")))
        queue.async { gate.wait() }; defer { gate.signal() }
        let clipboard = HostClipboardService(pasteboard: pasteboard, queue: queue)
        var replies: [ClipboardFrame] = []; clipboard.transport = { replies.append($0); return true }
        clipboard.receive(.pull(transfer), allowed: true); clipboard.reset(); gate.signal(); queue.sync {}
        XCTAssertEqual(pasteboard.reads, 0); XCTAssertTrue(replies.isEmpty)
        let readGate = DispatchSemaphore(value: 0); pasteboard.readGate = readGate; defer { readGate.signal() }
        clipboard.receive(.pull(transfer), allowed: true)
        waitUntil("read entered") { pasteboard.reads == 1 }
        clipboard.reset(); readGate.signal(); queue.sync {}
        let settled = expectation(description: "old result filtered")
        DispatchQueue.main.async { settled.fulfill() }; wait(for: [settled], timeout: 1)
        XCTAssertTrue(replies.isEmpty); XCTAssertTrue(clipboard.isIdle)
    }

}

/// Uses private, uniquely named pasteboards, which macOS does not gate behind the
/// general pasteboard's paste-privacy prompt, and never touches the user's clipboard.
final class SystemHostPasteboardTests: XCTestCase {
    private func pasteboard(_ build: (NSPasteboard) -> Void) -> SystemHostPasteboard {
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        board.clearContents()
        build(board)
        return SystemHostPasteboard(board)
    }

    func testPasswordManagerAndTransientItemsAreNeverRead() {
        for marker in ["org.nspasteboard.ConcealedType", "com.agilebits.onepassword",
                       "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
            let access = pasteboard { board in
                let item = NSPasteboardItem()
                item.setString("hunter2", forType: .string)
                item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
                board.writeObjects([item])
            }
            XCTAssertEqual(access.read(limit: ClipboardLimits.maximumBytes), .refused(.concealed), marker)
        }
    }

    func testPlainTextURLAndLimits() {
        XCTAssertEqual(pasteboard { $0.setString("hello", forType: .string) }.read(limit: 100),
                       .text(ClipboardPayload(text: "hello", kind: .text)))
        XCTAssertEqual(pasteboard { $0.setString("https://example.com/x", forType: .string) }.read(limit: 100),
                       .text(ClipboardPayload(text: "https://example.com/x", kind: .url)))
        XCTAssertEqual(pasteboard { $0.setString(String(repeating: "a", count: 101), forType: .string) }.read(limit: 100),
                       .refused(.tooLarge))
        XCTAssertEqual(pasteboard { _ in }.read(limit: 100), .refused(.empty))
        XCTAssertEqual(pasteboard { $0.setData(Data([1, 2, 3]), forType: .png) }.read(limit: 100), .refused(.unsupported))
    }

    func testWritesTagTheItemAsPocketDeskContent() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let access = SystemHostPasteboard(board)
        XCTAssertTrue(access.write(ClipboardPayload(text: "https://example.com/a")))
        XCTAssertEqual(board.string(forType: .string), "https://example.com/a")
        XCTAssertEqual(board.string(forType: .URL), "https://example.com/a")
        XCTAssertTrue(board.types?.contains(NSPasteboard.PasteboardType(ClipboardPrivacy.pocketDeskMarker)) == true)
        XCTAssertEqual(access.read(limit: 100), .text(ClipboardPayload(text: "https://example.com/a")),
                       "PocketDesk's own marker is not a privacy marker")
    }
}
