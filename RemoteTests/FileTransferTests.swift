import XCTest
import CryptoKit
import CoreServices

final class FileTransferFramingTests: XCTestCase {
    private let transfer = "0123456789abcdef0123456789abcdef"

    func testChunkRoundTripsTransferOffsetAndPayload() throws {
        let payload = Data((0..<FileTransferLimits.directChunkPayload).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let message = try XCTUnwrap(FileChunk.encode(transfer: transfer, offset: 1_000_000_123, payload: payload))
        XCTAssertEqual(message.count, FileTransferLimits.maximumOutgoingMessageBytes, "new sends are bounded to 16 KiB without interleaving")
        XCTAssertEqual(FileChunk.decode(message), FileChunk.Decoded(transfer: transfer, offset: 1_000_000_123, payload: payload))
        let small = try XCTUnwrap(FileChunk.encode(transfer: transfer, offset: 65_508, payload: Data([1, 2, 3])))
        XCTAssertEqual(FileChunk.decode(small), FileChunk.Decoded(transfer: transfer, offset: 65_508, payload: Data([1, 2, 3])))
        XCTAssertLessThanOrEqual(FileTransferLimits.relayChunkPayload + FileTransferLimits.chunkHeaderBytes, 16 * 1024)
        let legacy = message.prefix(FileTransferLimits.chunkHeaderBytes) + Data(count: FileTransferLimits.maximumMessageBytes - FileTransferLimits.chunkHeaderBytes)
        XCTAssertEqual(FileChunk.decode(legacy)?.payload.count, 65_508, "existing file.1 peers may still send bounded 64 KiB chunks")
    }

    func testChunkCodecRejectsMalformedMessages() throws {
        XCTAssertNil(FileChunk.encode(transfer: "short", offset: 0, payload: Data([1])))
        XCTAssertNil(FileChunk.encode(transfer: transfer, offset: 0, payload: Data()))
        XCTAssertNil(FileChunk.encode(transfer: transfer, offset: 0, payload: Data(count: FileTransferLimits.directChunkPayload + 1)))
        var message = try XCTUnwrap(FileChunk.encode(transfer: transfer, offset: 0, payload: Data([9])))
        message[0] = UInt8(ascii: "X")
        XCTAssertNil(FileChunk.decode(message), "wrong magic")
        XCTAssertNil(FileChunk.decode(Data(count: FileTransferLimits.chunkHeaderBytes)), "header without payload")
        XCTAssertNil(FileChunk.decode(Data(count: FileTransferLimits.maximumMessageBytes + 1)), "over 64 KiB")
        var beyond = Data("FSF1".utf8) + Data(repeating: 0xAB, count: 16)
        withUnsafeBytes(of: UInt64(FileTransferLimits.maximumBytes + 1).bigEndian) { beyond.append(contentsOf: $0) }
        XCTAssertNil(FileChunk.decode(beyond + Data([1])), "offset past the 1 GiB cap")
    }

    func testFrameValidationAcceptsEachOperationAndRejectsStrayFields() {
        let valid: [FileFrame] = [
            .offer(transfer, name: "report.pdf", bytes: 10, type: "com.adobe.pdf"),
            .offer(transfer, name: String(repeating: "a", count: 255), bytes: FileTransferLimits.maximumBytes, type: nil),
            .accept(transfer), .progress(transfer, bytes: 0), .complete(transfer, digest: String(repeating: "a", count: 64)),
            .result(transfer, .stored), .cancel(transfer), .request(transfer), .link(transfer, url: "https://example.com/a?b=c")
        ]
        for frame in valid { XCTAssertNoThrow(try frame.validate(), frame.op) }

        var invalid: [FileFrame] = [
            .offer(transfer, name: "", bytes: 10, type: nil),
            .offer(transfer, name: "a\u{0}b", bytes: 10, type: nil),
            .offer(transfer, name: String(repeating: "a", count: 256), bytes: 10, type: nil),
            .offer(transfer, name: "a", bytes: 0, type: nil),
            .offer(transfer, name: "a", bytes: FileTransferLimits.maximumBytes + 1, type: nil),
            .offer(transfer, name: "a", bytes: 1, type: "not a type!"),
            .offer("ABCDEF0123456789ABCDEF0123456789", name: "a", bytes: 1, type: nil),
            .complete(transfer, digest: "abc"),
            .link(transfer, url: "javascript:alert(1)"),
            .link(transfer, url: "file:///etc/passwd"),
            .link(transfer, url: "https://exa mple.com"),
            .result(transfer, .stored)
        ]
        invalid[invalid.count - 1].status = "not-a-status"
        var stray = FileFrame.accept(transfer); stray.name = "x"; invalid.append(stray)
        var version = FileFrame.cancel(transfer); version.version = 2; invalid.append(version)
        var unknown = FileFrame.cancel(transfer); unknown.op = "upload"; invalid.append(unknown)
        for frame in invalid { XCTAssertThrowsError(try frame.validate(), frame.op) }
    }

    func testFileActionIsGatedByTheSessionValidator() throws {
        XCTAssertNoThrow(try RemoteAction(action: "file", file: .request(transfer)).validate())
        XCTAssertThrowsError(try RemoteAction(action: "file").validate(), "a file action needs a frame")
        XCTAssertThrowsError(try RemoteAction(action: "clipboard", file: .request(transfer)).validate())
        XCTAssertThrowsError(try RemoteAction(action: "displays", file: .request(transfer)).validate())
        XCTAssertThrowsError(try RemoteAction(action: "file", text: "x", file: .request(transfer)).validate())
        var bad = FileFrame.request(transfer); bad.bytes = 1
        XCTAssertThrowsError(try RemoteAction(action: "file", file: bad).validate())
    }

    func testCapabilityIsAdvertisedWithinTheFeatureLimit() throws {
        XCTAssertEqual(SessionFeature.fileTransfer, "file.1")
        XCTAssertTrue(SessionFeature.host.contains(SessionFeature.fileTransfer))
        XCTAssertLessThanOrEqual(SessionFeature.host.count, 16)
        XCTAssertNoThrow(try RemoteAction(action: "capture", features: SessionFeature.host).validate())
    }

    func testLargestOfferFitsTheControlPacketLimit() throws {
        let name = String(repeating: "\u{1F642}", count: 63) + "abc"
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        let frame = FileFrame.offer(transfer, name: name, bytes: FileTransferLimits.maximumBytes,
                                    type: String(repeating: "a", count: FileTransferLimits.maximumTypeBytes))
        XCTAssertNoThrow(try frame.validate())
        let packet = ControlPacket(session: String(repeating: "S", count: 64), sequence: .max,
                                   action: RemoteAction(action: "file", epoch: .max, file: frame))
        XCTAssertLessThan(try JSONEncoder().encode(packet).count, 16_384)
    }

    func testSanitizerStripsPathsControlAndSpoofingCharacters() {
        XCTAssertEqual(FileNameSanitizer.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(FileNameSanitizer.sanitize("C:\\Users\\me\\notes.txt"), "notes.txt")
        XCTAssertEqual(FileNameSanitizer.sanitize("photo\u{202E}gpj.exe"), "photogpj.exe", "bidi override removed")
        XCTAssertEqual(FileNameSanitizer.sanitize("a\u{200B}b\u{0007}c\u{0}.txt"), "abc.txt")
        XCTAssertEqual(FileNameSanitizer.sanitize(".hidden"), "hidden")
        XCTAssertEqual(FileNameSanitizer.sanitize("..."), FileNameSanitizer.fallback)
        XCTAssertEqual(FileNameSanitizer.sanitize("/"), FileNameSanitizer.fallback)
        XCTAssertEqual(FileNameSanitizer.sanitize("  report.pdf  "), "report.pdf")
        XCTAssertEqual(FileNameSanitizer.sanitize("time 10:30.txt"), "time 10-30.txt")
        XCTAssertEqual(FileNameSanitizer.sanitize("Cafe\u{0301}.txt"), "Caf\u{00E9}.txt", "NFC")
        let long = FileNameSanitizer.sanitize(String(repeating: "é", count: 300) + ".jpeg")
        XCTAssertTrue(long.hasSuffix(".jpeg"))
        XCTAssertLessThanOrEqual(FileNameSanitizer.candidate(long, attempt: 999).utf8.count, 255)
        XCTAssertEqual(FileNameSanitizer.candidate("report.pdf", attempt: 1), "report.pdf")
        XCTAssertEqual(FileNameSanitizer.candidate("report.pdf", attempt: 2), "report 2.pdf")
        XCTAssertEqual(FileNameSanitizer.candidate("archive.tar.gz", attempt: 3), "archive.tar 3.gz")
        XCTAssertEqual(FileNameSanitizer.candidate("README", attempt: 2), "README 2")
    }

    func testAssemblerVerifiesTheDigestWhicheverArrivesLast() {
        let data = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0) })
        let digest = FileDigest.hex(SHA256.hash(data: data))

        var bytesFirst = FileAssembler(transfer: transfer, expectedBytes: 1000)
        XCTAssertEqual(bytesFirst.accept(chunk(data, 0, 600)), .progress(600))
        XCTAssertEqual(bytesFirst.accept(chunk(data, 600, 400)), .awaitingDigest)
        XCTAssertEqual(bytesFirst.receiveDigest(digest), .verified)

        var digestFirst = FileAssembler(transfer: transfer, expectedBytes: 1000)
        XCTAssertEqual(digestFirst.receiveDigest(digest), .progress(0))
        XCTAssertEqual(digestFirst.accept(chunk(data, 0, 1000)), .verified)

        var mismatch = FileAssembler(transfer: transfer, expectedBytes: 1000)
        _ = mismatch.accept(chunk(data, 0, 1000))
        XCTAssertEqual(mismatch.receiveDigest(String(repeating: "0", count: 64)), .failed)
    }

    func testAssemblerRejectsGapsOverflowAndForeignTransfers() {
        let data = Data(repeating: 1, count: 100)
        var gap = FileAssembler(transfer: transfer, expectedBytes: 100)
        XCTAssertEqual(gap.accept(chunk(data, 10, 10)), .failed)
        XCTAssertEqual(gap.accept(chunk(data, 0, 10)), .failed, "stays failed")

        var overflow = FileAssembler(transfer: transfer, expectedBytes: 50)
        XCTAssertEqual(overflow.accept(chunk(data, 0, 60)), .failed)

        var foreign = FileAssembler(transfer: transfer, expectedBytes: 100)
        XCTAssertEqual(foreign.accept(FileChunk.Decoded(transfer: String(repeating: "f", count: 32), offset: 0, payload: data)), .failed)
    }

    func testPacerOnlyLimitsRelayedTransfers() {
        var direct = FilePacer(bytesPerSecond: nil)
        for _ in 0..<1000 { XCTAssertTrue(direct.allows(65_000, at: 0)) }

        var relay = FilePacer(bytesPerSecond: 1_000_000, burst: 100_000)
        XCTAssertTrue(relay.allows(60_000, at: 0))
        XCTAssertFalse(relay.allows(60_000, at: 0), "burst spent")
        XCTAssertTrue(relay.allows(60_000, at: 0.05), "50 ms refills 50 KB")
    }

    func testRoomCheckKeepsAMargin() {
        XCTAssertTrue(FileTransferLimits.hasRoom(for: 10, available: nil))
        XCTAssertTrue(FileTransferLimits.hasRoom(for: 1000, available: 1000 + FileTransferLimits.freeSpaceMargin))
        XCTAssertFalse(FileTransferLimits.hasRoom(for: 1000, available: 999 + FileTransferLimits.freeSpaceMargin))
    }

    private func chunk(_ data: Data, _ offset: Int, _ count: Int) -> FileChunk.Decoded {
        FileChunk.Decoded(transfer: transfer, offset: Int64(offset), payload: data.subdata(in: offset..<min(data.count, offset + count)))
    }
}

final class FolderFileSinkTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FolderFileSinkTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testCommitNeverOverwritesAndLeavesNoPartial() throws {
        try Data("keep".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let sink = try FolderFileSink(folder: folder, partialFolder: folder, name: "../a.txt", transfer: FileTransferID.make())
        try sink.write(Data("new".utf8))
        let url = try sink.commit()
        XCTAssertEqual(url.lastPathComponent, "a 2.txt")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8), "keep")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["a 2.txt", "a.txt"])
    }

    func testPartialRefusesAnExistingLinkAndDiscardCleansUp() throws {
        let transfer = FileTransferID.make()
        let partial = folder.appendingPathComponent(".farside-\(transfer).partial")
        try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: folder.appendingPathComponent("elsewhere"))
        XCTAssertThrowsError(try FolderFileSink(folder: folder, partialFolder: folder, name: "x", transfer: transfer))
        try FileManager.default.removeItem(at: partial)

        let sink = try FolderFileSink(folder: folder, partialFolder: folder, name: "x", transfer: transfer)
        try sink.write(Data([1, 2, 3]))
        sink.discard()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testFinalizeRunsBeforeTheFileAppears() throws {
        var finalized: URL?
        let sink = try FolderFileSink(folder: folder, partialFolder: folder, name: "doc", transfer: FileTransferID.make()) {
            finalized = $0
        }
        try sink.write(Data([1]))
        let url = try sink.commit()
        XCTAssertEqual(finalized?.lastPathComponent.hasSuffix(".partial"), true)
        XCTAssertEqual(url.lastPathComponent, "doc")
    }

    @MainActor
    func testHostSinkQuarantinesReceivedFiles() throws {
        let offer = FileTransferOffer(transfer: FileTransferID.make(), name: "tool.command", bytes: 3, type: nil)
        let sink = try HostFileTransferService.prepareSink(for: offer, in: folder.appendingPathComponent("Farside")).get()
        try sink.write(Data("abc".utf8))
        let url = try sink.commit()
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
        XCTAssertGreaterThan(size, 0, "received files carry the quarantine attribute")
        let values = try url.resourceValues(forKeys: [.quarantinePropertiesKey])
        XCTAssertEqual(values.quarantineProperties?[kLSQuarantineAgentNameKey as String] as? String, "Farside")
    }

    func testErrorMapping() {
        XCTAssertEqual(FolderFileSink.status(for: ENOSPC), .diskFull)
        XCTAssertEqual(FolderFileSink.status(for: EPERM), .denied)
        XCTAssertEqual(FolderFileSink.status(for: EACCES), .denied)
        XCTAssertEqual(FolderFileSink.status(for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), .diskFull)
        XCTAssertEqual(FolderFileSink.status(for: CocoaError(.fileWriteOutOfSpace)), .diskFull)
    }
}

/// Two engines wired back to back: control frames through the real validator and JSON, bytes
/// through an in-memory link that can hold, corrupt or drop messages.
@MainActor
final class FileTransferEngineTests: XCTestCase {
    final class LoopLink: FileChannelLink {
        weak var target: FileTransferEngine?
        var buffered: UInt64 = 0
        var holding = false
        var held: [Data] = []
        var corruptAt: Int?
        var sentMessages = 0
        var largestMessage = 0
        var open = true

        func sendFile(_ data: Data) -> Bool {
            guard open else { return false }
            sentMessages += 1
            largestMessage = max(largestMessage, data.count)
            var message = data
            if sentMessages == corruptAt { message[message.count - 1] ^= 0xFF }
            if holding { held.append(message) } else { target?.receiveChunk(message) }
            return true
        }

        var fileBufferedAmount: UInt64? { open ? buffered : nil }

        func flush() {
            holding = false
            for message in held { target?.receiveChunk(message) }
            held.removeAll()
        }
    }

    private var folder: URL!
    private var phone: FileTransferEngine!
    private var mac: FileTransferEngine!
    private var toMac: LoopLink!
    private var toPhone: LoopLink!
    private var phoneFinishes: [FileTransferFinish] = []
    private var macFinishes: [FileTransferFinish] = []
    private var controlFrames: [String] = []
    private var relayed = false

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileTransferEngineTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        phone = FileTransferEngine(acceptsUnsolicitedOffers: false)
        mac = FileTransferEngine(acceptsUnsolicitedOffers: true)
        toMac = LoopLink(); toMac.target = mac
        toPhone = LoopLink(); toPhone.target = phone
        connect(phone, to: mac, link: toMac)
        connect(mac, to: phone, link: toPhone)
        let folder = self.folder!
        let admit: (FileTransferOffer, @escaping @MainActor (Result<FileByteSink, FileTransferStatus>) -> Void) -> Void = { offer, answer in
            answer(Result { try FolderFileSink(folder: folder, partialFolder: folder, name: offer.name, transfer: offer.transfer) }
                .mapError { FolderFileSink.status(for: $0) })
        }
        mac.admit = admit
        phone.admit = admit
        phone.onFinish = { [unowned self] in phoneFinishes.append($0) }
        mac.onFinish = { [unowned self] in macFinishes.append($0) }
    }

    override func tearDown() async throws {
        phone.reset(); mac.reset()
        try? FileManager.default.removeItem(at: folder)
    }

    private func connect(_ from: FileTransferEngine, to: FileTransferEngine, link: LoopLink) {
        from.sendControl = { [unowned self] frame in
            let action = RemoteAction(action: "file", file: frame)
            guard (try? action.validate()) != nil, let data = try? JSONEncoder().encode(action),
                  let decoded = try? JSONDecoder().decode(RemoteAction.self, from: data), let delivered = decoded.file
            else { XCTFail("invalid frame \(frame.op)"); return false }
            controlFrames.append(delivered.op)
            DispatchQueue.main.async { to.receive(delivered) }
            return true
        }
        from.link = { link }
        from.isRelayed = { [unowned self] in relayed }
    }

    private func wait(_ timeout: TimeInterval = 10, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out")
    }

    private func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func testPhoneToMacTransferArrivesIntactInChunks() async throws {
        let data = randomData(3 * 1024 * 1024 + 123)
        let result = phone.send(DataByteSource(data), name: "../report.pdf", type: "com.adobe.pdf")
        let transfer = try result.get()
        XCTAssertEqual(phone.outgoing?.name, "report.pdf", "the path never leaves the phone")
        try await wait { phoneFinishes.count == 1 && macFinishes.count == 1 }
        XCTAssertEqual(phoneFinishes.first?.status, .stored)
        XCTAssertEqual(macFinishes.first?.status, .stored)
        XCTAssertEqual(macFinishes.first?.transfer, transfer)
        let saved = try XCTUnwrap(macFinishes.first?.savedURL)
        XCTAssertEqual(try Data(contentsOf: saved), data)
        XCTAssertEqual(files(), ["report.pdf"])
        XCTAssertEqual(toMac.sentMessages, 193)
        XCTAssertEqual(toMac.largestMessage, FileTransferLimits.maximumOutgoingMessageBytes)
        XCTAssertEqual(Array(controlFrames.prefix(2)), ["offer", "accept"])
        XCTAssertTrue(controlFrames.contains("complete"))
        XCTAssertEqual(controlFrames.last, "result")
        XCTAssertTrue(phone.isIdle && mac.isIdle)
    }

    func testRelayedTransfersUseSmallChunks() async throws {
        relayed = true
        let data = randomData(100_000)
        _ = try phone.send(DataByteSource(data), name: "a.bin", type: nil).get()
        try await wait { phoneFinishes.count == 1 }
        XCTAssertEqual(phoneFinishes.first?.status, .stored)
        XCTAssertLessThanOrEqual(toMac.largestMessage, 16 * 1024)
        XCTAssertEqual(toMac.sentMessages, Int((100_000 + FileTransferLimits.relayChunkPayload - 1) / FileTransferLimits.relayChunkPayload))
    }

    func testCorruptedByteFailsTheHashAndKeepsNothing() async throws {
        toMac.corruptAt = 2
        _ = try phone.send(DataByteSource(randomData(200_000)), name: "a.bin", type: nil).get()
        try await wait { phoneFinishes.count == 1 && macFinishes.count == 1 }
        XCTAssertEqual(macFinishes.first?.status, .invalid)
        XCTAssertEqual(phoneFinishes.first?.status, .invalid)
        XCTAssertEqual(files(), [], "no partial or final file survives a failed digest")
    }

    func testCapAndEmptyAreRefusedBeforeAnythingIsSent() throws {
        final class HugeSource: FileByteSource {
            var byteCount: Int64 { FileTransferLimits.maximumBytes + 1 }
            func read(upTo count: Int) throws -> Data { Data(count: count) }
            func close() {}
        }
        XCTAssertEqual(phone.send(HugeSource(), name: "big", type: nil), .failure(.tooLarge))
        XCTAssertEqual(phone.send(DataByteSource(Data()), name: "empty", type: nil), .failure(.empty))
        XCTAssertTrue(controlFrames.isEmpty)
        XCTAssertTrue(phone.isIdle)
    }

    func testOneOutgoingTransferAtATime() throws {
        toMac.holding = true
        _ = try phone.send(DataByteSource(Data([1])), name: "a", type: nil).get()
        XCTAssertEqual(phone.send(DataByteSource(Data([2])), name: "b", type: nil), .failure(.busy))
    }

    func testSenderCancelStopsBothSidesAndDeletesThePartial() async throws {
        toMac.holding = true
        let data = randomData(5 * FileTransferLimits.directChunkPayload)
        _ = try phone.send(DataByteSource(data), name: "a.bin", type: nil).get()
        try await wait { toMac.held.count == 5 && mac.incoming?.phase == .transferring }
        XCTAssertEqual(files().count, 1, "the hidden partial exists while receiving")
        phone.cancel(try XCTUnwrap(phone.outgoing?.transfer))
        try await wait { macFinishes.count == 1 }
        toMac.flush()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(phoneFinishes.first?.status, .cancelled)
        XCTAssertEqual(macFinishes.first?.status, .cancelled)
        XCTAssertEqual(files(), [], "late chunks after a cancel write nothing")
        XCTAssertTrue(mac.isIdle)
    }

    func testReceiverCancelStopsTheSender() async throws {
        toMac.holding = true
        _ = try phone.send(DataByteSource(randomData(100_000)), name: "a.bin", type: nil).get()
        try await wait { mac.incoming?.phase == .transferring }
        mac.cancelAll()
        try await wait { phoneFinishes.count == 1 }
        XCTAssertEqual(phoneFinishes.first?.status, .cancelled)
        XCTAssertEqual(files(), [])
    }

    func testFlowControlWaitsWhileTheChannelIsFull() async throws {
        toMac.buffered = FileTransferLimits.directHighWater
        _ = try phone.send(DataByteSource(randomData(200_000)), name: "a.bin", type: nil).get()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(toMac.sentMessages, 0, "nothing is queued above the high-water mark")
        toMac.buffered = 0
        phone.fileBufferedAmountChanged()
        try await wait { phoneFinishes.count == 1 }
        XCTAssertEqual(phoneFinishes.first?.status, .stored)
    }

    func testLostChannelFailsTheSender() async throws {
        toMac.open = false
        _ = try phone.send(DataByteSource(randomData(10)), name: "a", type: nil).get()
        try await wait { phoneFinishes.count == 1 }
        XCTAssertEqual(phoneFinishes.first?.status, .connectionLost)
    }

    func testPhoneRefusesFilesItDidNotAskFor() async throws {
        _ = try mac.send(DataByteSource(Data([1, 2, 3])), name: "surprise.app", type: nil).get()
        try await wait { macFinishes.count == 1 }
        XCTAssertEqual(macFinishes.first?.status, .notAllowed)
        XCTAssertEqual(files(), [])
    }

    func testMacToPhoneRequestDeliversThePickedFile() async throws {
        mac.onRequest = { [unowned self] transfer in
            _ = mac.send(DataByteSource(Data("from mac".utf8)), name: "notes.txt", type: "public.plain-text", transfer: transfer)
        }
        let transfer = try phone.request().get()
        XCTAssertEqual(phone.pendingRequest, transfer)
        try await wait { phoneFinishes.count == 1 }
        XCTAssertEqual(phoneFinishes.first?.status, .stored)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(phoneFinishes.first?.savedURL), encoding: .utf8), "from mac")
        XCTAssertNil(phone.pendingRequest)
    }

    func testMacPickerCancelEndsThePhoneRequest() async throws {
        mac.onRequest = { [unowned self] transfer in mac.answerRequest(transfer, .cancelled) }
        _ = try phone.request().get()
        try await wait { phoneFinishes.count == 1 }
        XCTAssertEqual(phoneFinishes.first?.status, .cancelled)
        XCTAssertNil(phoneFinishes.first?.name)
    }

    func testRefusedAdmissionIsReportedToTheSender() async throws {
        mac.admit = { _, answer in answer(.failure(.disabled)) }
        _ = try phone.send(DataByteSource(Data([1])), name: "a", type: nil).get()
        try await wait { phoneFinishes.count == 1 }
        XCTAssertEqual(phoneFinishes.first?.status, .disabled)
    }

    func testResetEndsQuietly() throws {
        toMac.holding = true
        _ = try phone.send(DataByteSource(Data([1])), name: "a", type: nil).get()
        let before = controlFrames.count
        phone.reset()
        XCTAssertEqual(phoneFinishes.first?.status, .connectionLost)
        XCTAssertEqual(controlFrames.count, before, "no messages after the session ended")
    }
}

/// The `file` channel on real loopback peers, and an older phone that does not know it.
@MainActor
final class FileChannelLoopbackTests: XCTestCase {
    private func connect(phoneAcceptsFiles: Bool) async throws -> (PeerMedia, PeerMedia) {
        let host = PeerMedia(isHost: true, servers: [], fileChannel: true)
        let phone = PeerMedia(isHost: false, servers: [], fileChannel: phoneAcceptsFiles)
        host.onSignal = { [weak phone] in phone?.receive($0) }
        phone.onSignal = { [weak host] in host?.receive($0) }
        var connected = false
        phone.onState = { if $0 == "connected" { connected = true } }
        host.offer()
        let deadline = Date().addingTimeInterval(15)
        while !connected, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(connected)
        return (host, phone)
    }

    func testOlderPhoneClosesTheFileChannelAndKeepsItsSession() async throws {
        let (host, phone) = try await connect(phoneAcceptsFiles: false)
        defer { host.close(); phone.close() }
        var states: [String] = []
        phone.onState = { states.append($0) }
        host.onState = { states.append($0) }
        let deadline = Date().addingTimeInterval(5)
        while host.fileChannelOpen, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(phone.fileChannelOpen)
        XCTAssertFalse(host.fileChannelOpen, "the refused channel closes")
        XCTAssertNotNil(host.controlBufferedAmount, "control stays open")
        XCTAssertFalse(states.contains("closed") || states.contains("failed"))
        XCTAssertFalse(host.sendFile(Data([1])))
    }

    func testEnginesMoveAFileOverTheFileChannel() async throws {
        let (host, phone) = try await connect(phoneAcceptsFiles: true)
        defer { host.close(); phone.close() }
        let deadline = Date().addingTimeInterval(5)
        while !(phone.fileChannelOpen && host.fileChannelOpen), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(phone.fileChannelOpen)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileChannelLoopback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let phoneEngine = FileTransferEngine(acceptsUnsolicitedOffers: false)
        let macEngine = FileTransferEngine(acceptsUnsolicitedOffers: true)
        phoneEngine.sendControl = { frame in DispatchQueue.main.async { macEngine.receive(frame) }; return true }
        macEngine.sendControl = { frame in DispatchQueue.main.async { phoneEngine.receive(frame) }; return true }
        phoneEngine.link = { phone }
        macEngine.link = { host }
        host.onFileMessage = { [weak macEngine] in macEngine?.receiveChunk($0) }
        host.onFileBufferedAmountChange = { [weak macEngine] in macEngine?.fileBufferedAmountChanged() }
        phone.onFileMessage = { [weak phoneEngine] in phoneEngine?.receiveChunk($0) }
        phone.onFileBufferedAmountChange = { [weak phoneEngine] in phoneEngine?.fileBufferedAmountChanged() }
        macEngine.admit = { offer, answer in
            answer(Result { try FolderFileSink(folder: folder, partialFolder: folder, name: offer.name, transfer: offer.transfer) }
                .mapError { FolderFileSink.status(for: $0) })
        }
        var finish: FileTransferFinish?
        phoneEngine.onFinish = { finish = $0 }
        var generator = SystemRandomNumberGenerator()
        // Keep real SCTP/governor integrity coverage to 32+ chunks within the CI deadline;
        // the deterministic engine suite retains the 3 MiB whole-file case.
        let data = Data((0..<(512 * 1024 + 7)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        _ = try phoneEngine.send(DataByteSource(data), name: "big.bin", type: nil).get()
        let done = Date().addingTimeInterval(30)
        while finish == nil, Date() < done { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(finish?.status, .stored)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("big.bin")), data)
        XCTAssertNotNil(host.controlBufferedAmount, "the control channel is untouched")
    }
}
