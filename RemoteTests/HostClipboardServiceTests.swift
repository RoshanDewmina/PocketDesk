import XCTest
import AppKit

private final class FakePasteboard: HostPasteboardAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var result: HostPasteboardRead = .refused(.empty)
    private var stored: [ClipboardPayload] = []
    var readGate: DispatchSemaphore?

    var changeCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var writes: [ClipboardPayload] { lock.lock(); defer { lock.unlock() }; return stored }

    func set(_ next: HostPasteboardRead) { lock.lock(); result = next; lock.unlock() }
    func bump() { lock.lock(); count += 1; lock.unlock() }

    func read(limit: Int) -> HostPasteboardRead {
        readGate?.wait()
        lock.lock(); defer { lock.unlock() }
        return result
    }

    func write(_ payload: ClipboardPayload) -> Bool {
        lock.lock(); stored.append(payload); count += 1; lock.unlock()
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
        let service = HostClipboardService(pasteboard: pasteboard, readTimeout: readTimeout, copyWait: copyWait)
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
