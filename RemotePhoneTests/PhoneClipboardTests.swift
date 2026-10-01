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

    func testSessionInputRespondersDisableSystemThreeFingerEditing() {
        XCTAssertEqual(NativeTrackpadInputView().editingInteractionConfiguration, .none)
        XCTAssertEqual(CommittedTextField.InitialFocusTextView().editingInteractionConfiguration, .none)
    }

    func testAutomaticMacTransferWritesWithoutRequestOrToast() throws {
        let clipboard = makeClipboard()
        let frames = try ClipboardChunker.frames(for: ClipboardPayload(text: "new Mac copy"), operation: "data", transfer: "automaticcopy0001")
        for frame in frames {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any])
            object["automatic"] = true
            clipboard.receive(try JSONDecoder().decode(ClipboardFrame.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        XCTAssertEqual(written, [ClipboardPayload(text: "new Mac copy")])
        XCTAssertNil(clipboard.notice, "Automatic copy should be quiet")
        XCTAssertFalse(clipboard.isBusy)
        XCTAssertEqual(pasteShortcutPresses, 0)
    }

    func testPasteChipUsesOnlyMetadataAndSuppressesOwnWritesAndSentGeneration() throws {
        let clipboard = makeClipboard()
        var count = 10
        var hasStrings = true
        clipboard.pasteboardMetadata = { (count, hasStrings) }
        clipboard.refreshPasteChip(available: true)
        XCTAssertTrue(clipboard.showsPasteChip)
        clipboard.send("phone text", pasteAfter: true)
        waitForFrames(1)
        count = 11 // Another phone copy while the send is in flight must stay discoverable.
        clipboard.receive(.result(sent[0].transfer, .stored))
        clipboard.refreshPasteChip(available: true)
        XCTAssertTrue(clipboard.showsPasteChip)
        clipboard.send("next phone text", pasteAfter: true)
        waitForFrames(2)
        clipboard.receive(.result(sent[1].transfer, .stored))
        clipboard.refreshPasteChip(available: true)
        XCTAssertFalse(clipboard.showsPasteChip)
        count = 12; hasStrings = false
        clipboard.refreshPasteChip(available: true)
        XCTAssertFalse(clipboard.showsPasteChip)
        hasStrings = true
        clipboard.refreshPasteChip(available: false)
        XCTAssertFalse(clipboard.showsPasteChip)
        clipboard.refreshPasteChip(available: true)
        XCTAssertTrue(clipboard.showsPasteChip)
        clipboard.writeToPasteboard = { [unowned self] payload in count += 1; self.written.append(payload) }
        var frame = try ClipboardChunker.frames(for: ClipboardPayload(text: "Mac text"), operation: "data", transfer: "automaticcopy0002")[0]
        frame.automatic = true
        clipboard.receive(frame)
        clipboard.refreshPasteChip(available: true)
        XCTAssertFalse(clipboard.showsPasteChip, "Mac writes must not offer an echo Paste")
    }

    func testAutomaticTransferCannotMixWithExplicitDataOrSurviveCancellation() throws {
        let clipboard = makeClipboard()
        var frames = try ClipboardChunker.frames(for: ClipboardPayload(text: String(repeating: "x", count: 5000)), operation: "data", transfer: "automaticcopy0003")
        frames = frames.map { var frame = $0; frame.automatic = true; return frame }
        clipboard.receive(frames[0])
        clipboard.cancel()
        clipboard.receive(frames[1])
        XCTAssertTrue(written.isEmpty)
        clipboard.receive(frames[0])
        var unmarked = frames[1]; unmarked.automatic = nil
        clipboard.receive(unmarked)
        XCTAssertTrue(written.isEmpty)
        clipboard.cancel()
        defaults.set(true, forKey: PhoneClipboard.automaticDisabledKey)
        frames.forEach(clipboard.receive)
        XCTAssertTrue(written.isEmpty)
    }

    func testSendAcknowledgmentDoesNotOfferEchoOfNewerAutomaticCopy() throws {
        let clipboard = makeClipboard()
        var count = 10
        clipboard.pasteboardMetadata = { (count, true) }
        clipboard.writeToPasteboard = { [unowned self] payload in count += 1; self.written.append(payload) }
        clipboard.send("phone copy")
        waitForFrames(1)
        var frame = try ClipboardChunker.frames(for: ClipboardPayload(text: "newer Mac copy"), operation: "data", transfer: "automaticcopy0004")[0]
        frame.automatic = true
        clipboard.receive(frame)
        clipboard.receive(.result(sent[0].transfer, .stored))
        clipboard.refreshPasteChip(available: true)
        XCTAssertFalse(clipboard.showsPasteChip, "A late phone-send ack cannot downgrade the newer Mac-write generation")
    }

    func testExplicitSendCompletionDoesNotDiscardIndependentAutomaticReassembly() throws {
        let clipboard = makeClipboard()
        clipboard.send("phone copy")
        waitForFrames(1)
        var frames = try ClipboardChunker.frames(for: ClipboardPayload(text: String(repeating: "x", count: 5000)), operation: "data", transfer: "automaticcopy0005")
        frames = frames.map { var frame = $0; frame.automatic = true; return frame }
        clipboard.receive(frames[0])
        clipboard.receive(.result(sent[0].transfer, .stored))
        clipboard.receive(frames[1])
        XCTAssertEqual(written.count, 1)
    }

    func testPasteChipKillSwitchDoesNotConsumePhoneContent() {
        let clipboard = makeClipboard()
        clipboard.pasteboardMetadata = { (10, true) }
        defaults.set(true, forKey: PhoneClipboard.pasteChipDisabledKey)
        clipboard.refreshPasteChip(available: true)
        XCTAssertFalse(clipboard.showsPasteChip)
        defaults.set(false, forKey: PhoneClipboard.pasteChipDisabledKey)
        clipboard.refreshPasteChip(available: true)
        XCTAssertTrue(clipboard.showsPasteChip)
    }

    func testDelayedPasteAndShareTextCannotConsumeNewPhoneCopy() {
        let clipboard = makeClipboard()
        var count = 10
        clipboard.pasteboardMetadata = { (count, true) }
        clipboard.refreshPasteChip(available: true)
        let offered = clipboard.pasteChipChangeCount
        count = 11
        clipboard.send("older pasted value", sourceChangeCount: offered)
        waitForFrames(1)
        clipboard.receive(.result(sent[0].transfer, .stored))
        clipboard.refreshPasteChip(available: true)
        XCTAssertTrue(clipboard.showsPasteChip)
        XCTAssertEqual(clipboard.pasteChipChangeCount, 11)
        clipboard.send("share-sheet text", pasteAfter: false, usesPhonePasteboard: false)
        waitForFrames(2)
        clipboard.receive(.result(sent[1].transfer, .stored))
        clipboard.refreshPasteChip(available: true)
        XCTAssertTrue(clipboard.showsPasteChip)
    }

    func testFailedSendKeepsPasteChipAvailable() {
        let clipboard = makeClipboard()
        clipboard.pasteboardMetadata = { (10, true) }
        clipboard.refreshPasteChip(available: true)
        clipboard.send("phone text")
        waitForFrames(1)
        clipboard.receive(.result(sent[0].transfer, .notAllowed))
        clipboard.refreshPasteChip(available: true)
        XCTAssertTrue(clipboard.showsPasteChip)
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
