import XCTest
import SwiftUI
@testable import PocketDeskRemote

@MainActor
final class PhoneClipboardTests: XCTestCase {
    private var defaults: UserDefaults!
    private var sent: [ClipboardFrame] = []
    private var written: [ClipboardPayload] = []
    private var now: TimeInterval = 100
    private var pasteShortcutAccepted = true
    private var pasteShortcutPresses = 0

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "PhoneClipboardTests")
        defaults.removePersistentDomain(forName: "PhoneClipboardTests")
        sent = []; written = []; now = 100; pasteShortcutAccepted = true; pasteShortcutPresses = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "PhoneClipboardTests")
        super.tearDown()
    }

    private func makeClipboard() -> PhoneClipboard {
        let clipboard = PhoneClipboard(defaults: defaults, clock: { [unowned self] in self.now })
        clipboard.transport = { [unowned self] frame in
            XCTAssertNotNil(try? RemoteAction(action: "clipboard", clipboard: frame).validate())
            self.sent.append(frame)
            return true
        }
        clipboard.bufferedAmount = { 0 }
        clipboard.pressPaste = { [unowned self] in
            self.pasteShortcutPresses += 1
            return self.pasteShortcutAccepted
        }
        clipboard.writeToPasteboard = { [unowned self] in self.written.append($0) }
        return clipboard
    }

    private func waitForFrames(_ count: Int) {
        let done = expectation(description: "\(count) frames")
        func poll(_ attempts: Int) {
            if sent.count >= count || attempts == 0 { done.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll(attempts - 1) }
        }
        poll(100)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(sent.count, count)
    }

    func testPasteToMacSendsPacedChunksThenPressesCommandVOnlyAfterTheMacStoresIt() throws {
        let clipboard = makeClipboard()
        XCTAssertTrue(clipboard.pasteAfterSending, "Pasting right away is the default")
        let text = String(repeating: "Bonjour 👋\n", count: 1_500)
        clipboard.send(text)
        XCTAssertEqual(clipboard.activity, .sending)
        waitForFrames(ClipboardLimits.chunkCount(forBytes: text.utf8.count))
        XCTAssertEqual(pasteShortcutPresses, 0, "⌘V must wait for the Mac's acknowledgment")

        clipboard.receive(.result("someoneelse0000", .stored))
        XCTAssertEqual(clipboard.activity, .sending, "Results for other transfers are ignored")
        clipboard.receive(.result(sent[0].transfer, .stored))
        XCTAssertEqual(pasteShortcutPresses, 1)
        XCTAssertEqual(clipboard.activity, .idle)
        XCTAssertEqual(clipboard.notice?.message, "Pasted on your Mac")
        XCTAssertEqual(clipboard.notice?.tone, .success)
    }

    func testStoredWithoutPasteShortcutAndRefusalsAreExplained() {
        let clipboard = makeClipboard()
        clipboard.pasteAfterSending = false
        XCTAssertFalse(PhoneClipboard(defaults: defaults).pasteAfterSending, "The preference persists")
        clipboard.send("short")
        waitForFrames(1)
        clipboard.receive(.result(sent[0].transfer, .stored))
        XCTAssertEqual(pasteShortcutPresses, 0)
        XCTAssertEqual(clipboard.notice?.message, "Copied to your Mac’s clipboard")

        clipboard.pasteAfterSending = true
        pasteShortcutAccepted = false
        clipboard.send("again")
        waitForFrames(2)
        clipboard.receive(.result(sent[1].transfer, .stored))
        XCTAssertEqual(clipboard.notice?.message, "On your Mac’s clipboard. Press ⌘V on the Mac to paste.")

        clipboard.send("refused")
        waitForFrames(3)
        clipboard.receive(.result(sent[2].transfer, .notAllowed))
        XCTAssertEqual(clipboard.notice?.tone, .caution)
        XCTAssertEqual(clipboard.activity, .idle)
    }

    func testOversizedOrEmptyTextIsNeverSent() {
        let clipboard = makeClipboard()
        clipboard.send(String(repeating: "a", count: ClipboardLimits.maximumBytes + 1))
        XCTAssertEqual(clipboard.notice?.message, "Clipboard text is too large to send. The limit is 256 KB.")
        clipboard.send("")
        XCTAssertEqual(clipboard.notice?.message, "Your iPhone clipboard has no text to send.")
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(clipboard.activity, .idle)
    }

    func testCopyFromMacWritesVerifiedTextToTheIPhoneClipboard() throws {
        let clipboard = makeClipboard()
        clipboard.requestFromMac(afterCopy: true)
        XCTAssertEqual(sent.count, 1)
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.op, "pull")
        XCTAssertEqual(request.afterCopy, true)
        XCTAssertEqual(clipboard.activity, .receiving)

        let text = String(repeating: "ligne ", count: 2_000)
        let stray = try ClipboardChunker.frames(for: ClipboardPayload(text: "not requested"), operation: "data",
                                                transfer: "0000aaaa0000aaaa")
        clipboard.receive(stray[0])
        XCTAssertTrue(written.isEmpty, "Unrequested data is ignored")
        for frame in try ClipboardChunker.frames(for: ClipboardPayload(text: text), operation: "data", transfer: request.transfer) {
            clipboard.receive(frame)
        }
        XCTAssertEqual(written, [ClipboardPayload(text: text)])
        XCTAssertEqual(clipboard.notice?.message, "Copied from your Mac · 12,000 characters")
        XCTAssertEqual(clipboard.activity, .idle)
    }

    func testMacRefusalsAndTimeoutsLeaveTheIPhoneClipboardAlone() {
        let clipboard = makeClipboard()
        clipboard.requestFromMac()
        clipboard.receive(.result(sent[0].transfer, .concealed))
        XCTAssertEqual(clipboard.notice?.message, "Your Mac’s clipboard holds a password or private item, so it wasn’t shared.")

        clipboard.requestFromMac()
        now += PhoneClipboard.receiveTimeout - 1
        clipboard.checkTimeout()
        XCTAssertEqual(clipboard.activity, .receiving)
        now += 2
        clipboard.checkTimeout()
        XCTAssertEqual(clipboard.activity, .idle)
        XCTAssertEqual(clipboard.notice?.tone, .caution)

        clipboard.send("pending")
        clipboard.requestFromMac()
        XCTAssertEqual(clipboard.notice?.message, "Wait for the current clipboard transfer to finish.")
        clipboard.cancel()
        XCTAssertFalse(clipboard.isBusy)
        XCTAssertTrue(written.isEmpty)
    }
}
