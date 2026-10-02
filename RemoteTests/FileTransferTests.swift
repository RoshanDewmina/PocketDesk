import XCTest
import CryptoKit
import CoreServices

final class FileTransferFramingTests: XCTestCase {
    private let transfer = "0123456789abcdef0123456789abcdef"

    func testChunkRoundTripsTransferOffsetAndPayload() throws {
        let payload = Data((0..<FileTransferLimits.directChunkPayload).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let message = try XCTUnwrap(FileChunk.encode(transfer: transfer, offset: 1_000_000_123, payload: payload))
        XCTAssertEqual(message.count, FileTransferLimits.maximumMessageBytes, "fast-lane sends stay within every file.1 receiver's 64 KiB")
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
        XCTAssertEqual(SessionFeature.legacyHost.count, 16)
        XCTAssertLessThanOrEqual(SessionFeature.host.count, 32)
        XCTAssertFalse(SessionFeature.legacyHost.contains(SessionFeature.videoRefinement))
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
        relay.refund(60_000)
        XCTAssertTrue(relay.allows(60_000, at: 0.05), "a send the media budget refused does not spend relay credit")
        direct.refund(1)
        XCTAssertGreaterThan(FileTransferLimits.relayBytesPerSecond, BulkAdmissionPolicy.relayCeilingKbps * 1_000 / 8,
                             "the relay backstop never undercuts the media governor's relay ceiling")
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
        var messageBytes: Int?

        func fileMessageBytes(at now: TimeInterval) -> Int { messageBytes ?? FileTransferLimits.maximumOutgoingMessageBytes }

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

    func testSlowRouteMessagesShrinkToTheLinksMessageSizeAndStillArriveIntact() async throws {
        toMac.messageBytes = 2_048
        let data = randomData(100_000)
        _ = try phone.send(DataByteSource(data), name: "slow.bin", type: nil).get()
        try await wait { phoneFinishes.count == 1 && macFinishes.count == 1 }
        XCTAssertEqual(phoneFinishes.first?.status, .stored)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(macFinishes.first?.savedURL)), data)
        XCTAssertEqual(toMac.largestMessage, 2_048, "header included")
        XCTAssertEqual(toMac.sentMessages, (100_000 + 2_019) / 2_020)
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
        XCTAssertEqual(toMac.sentMessages, 49)
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
        host.onSignal = { [weak self, weak phone] in if let sdp = $0.sdp { self?.descriptions.append("host " + sdp) }; phone?.receive($0) }
        phone.onSignal = { [weak self, weak host] in if let sdp = $0.sdp { self?.descriptions.append("phone " + sdp) }; host?.receive($0) }
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

    private var hostStats: StreamStatsReport?
    private var phoneStats: StreamStatsReport?
    private var descriptions: [String] = []

    private func routeSummary() -> String {
        func line(_ name: String, _ report: StreamStatsReport?) -> String {
            "\(name) \(report?.route ?? "nil")/\(report?.routeDetail ?? "nil") rtt \(report?.rttMs.map { "\($0)" } ?? "nil") ms" +
                " sample \(report?.rttSampleMs.map { "\($0)" } ?? "nil") ms bwe \(report?.availableOutgoingKbps.map { "\($0)" } ?? "nil")" +
                " max \(report?.maxKbps.map { "\($0)" } ?? "nil") kbps"
        }
        return line("host", hostStats) + "; " + line("phone", phoneStats)
    }

    private struct Loopback {
        let host: PeerMedia, phone: PeerMedia, phoneEngine: FileTransferEngine, macEngine: FileTransferEngine, folder: URL
    }

    private func loopback() async throws -> Loopback {
        let (host, phone) = try await connect(phoneAcceptsFiles: true)
        host.onStreamStatistics = { [weak self] in self?.hostStats = $0 }
        phone.onStreamStatistics = { [weak self] in self?.phoneStats = $0 }
        let deadline = Date().addingTimeInterval(5)
        while !(phone.fileChannelOpen && host.fileChannelOpen), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(phone.fileChannelOpen)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileChannelLoopback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
        let admit: (FileTransferOffer, @escaping @MainActor (Result<FileByteSink, FileTransferStatus>) -> Void) -> Void = { offer, answer in
            answer(Result { try FolderFileSink(folder: folder, partialFolder: folder, name: offer.name, transfer: offer.transfer) }
                .mapError { FolderFileSink.status(for: $0) })
        }
        macEngine.admit = admit
        phoneEngine.admit = admit
        return Loopback(host: host, phone: phone, phoneEngine: phoneEngine, macEngine: macEngine, folder: folder)
    }

    private func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    func testEnginesMoveAFileOverTheFileChannel() async throws {
        let link = try await loopback()
        defer { link.host.close(); link.phone.close(); try? FileManager.default.removeItem(at: link.folder) }
        var finish: FileTransferFinish?
        link.phoneEngine.onFinish = { finish = $0 }
        // Keep real SCTP/governor integrity coverage to 32+ chunks within the CI deadline;
        // the deterministic engine suite retains the 3 MiB whole-file case.
        let data = randomData(512 * 1024 + 7)
        _ = try link.phoneEngine.send(DataByteSource(data), name: "big.bin", type: nil).get()
        let done = Date().addingTimeInterval(30)
        while finish == nil, Date() < done { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(finish?.status, .stored)
        XCTAssertEqual(try Data(contentsOf: link.folder.appendingPathComponent("big.bin")), data)
        XCTAssertNotNil(link.host.controlBufferedAmount, "the control channel is untouched")
    }

    func testFourMebibytesCrossTheLoopbackLANBothWaysWithinTheDeadline() async throws {
        let link = try await loopback()
        defer { link.host.close(); link.phone.close(); try? FileManager.default.removeItem(at: link.folder) }
        let data = randomData(4 * 1024 * 1024)
        var phoneFinish: FileTransferFinish?, macFinish: FileTransferFinish?
        link.phoneEngine.onFinish = { if $0.direction == .outgoing { phoneFinish = $0 } }
        link.macEngine.onFinish = { if $0.direction == .outgoing { macFinish = $0 } }

        var started = Date()
        _ = try link.phoneEngine.send(DataByteSource(data), name: "up.bin", type: nil).get()
        var done = Date().addingTimeInterval(40)
        while phoneFinish == nil, Date() < done { try await Task.sleep(nanoseconds: 5_000_000) }
        let upRate = Double(data.count) / Date().timeIntervalSince(started)
        XCTAssertEqual(phoneFinish?.status, .stored, routeSummary())
        XCTAssertEqual(try Data(contentsOf: link.folder.appendingPathComponent("up.bin")), data)

        link.macEngine.onRequest = { transfer in
            _ = link.macEngine.send(DataByteSource(data), name: "down.bin", type: nil, transfer: transfer)
        }
        started = Date()
        _ = try link.phoneEngine.request().get()
        done = Date().addingTimeInterval(40)
        while macFinish == nil, Date() < done { try await Task.sleep(nanoseconds: 5_000_000) }
        let downRate = Double(data.count) / Date().timeIntervalSince(started)
        XCTAssertEqual(macFinish?.status, .stored, routeSummary())
        XCTAssertEqual(try Data(contentsOf: link.folder.appendingPathComponent("down.bin")), data)
        print("LOOPBACK-RECEIPT phone->mac \(Int(upRate)) B/s, mac->phone \(Int(downRate)) B/s; \(routeSummary())")
        // Deliberately loose on a shared, loaded machine: one RTT sample over 20 ms drops the LAN rule.
        // Before the bucket and host LAN rule, phone->Mac measured ~0.9 MB/s and Mac->phone missed 40 s;
        // the loopback host estimate (BWE ~6 Mbps vs a 12 Mbps encoder max, no video) is app-limited.
        XCTAssertGreaterThan(upRate, 200_000, routeSummary())
        if hostStats?.routeDetail == "lan" {
            XCTAssertGreaterThan(downRate, 400_000, "an app-limited host estimate keeps the LAN floor: \(routeSummary())")
        }
        XCTAssertNotNil(link.host.controlBufferedAmount, "the control channel is untouched")
    }

    /// DF10 bench, opt in with `FARSIDE_FILE_BENCH_MB=100`: throughput both ways on loopback, and the
    /// phone->Mac control-message delay (send to the host's main-queue delivery) idle and during each transfer.
    func testFileBenchBothWaysWithControlLatency() async throws {
        guard let megabytes = ProcessInfo.processInfo.environment["FARSIDE_FILE_BENCH_MB"].flatMap(Int.init), megabytes > 0 else {
            throw XCTSkip("set FARSIDE_FILE_BENCH_MB to run the DF10 bench")
        }
        let link = try await loopback()
        defer { link.host.close(); link.phone.close(); try? FileManager.default.removeItem(at: link.folder) }
        var data = Data(count: megabytes * 1_000_000)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        var delays: [Double] = []
        link.host.onControl = { message in
            guard message.count == 8 else { return }
            let sent = message.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            delays.append(Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000)
        }
        func probe(for seconds: Double) async throws {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                var now = DispatchTime.now().uptimeNanoseconds
                _ = link.phone.sendControl(Data(bytes: &now, count: 8))
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "n=0" }
            func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
            return String(format: "n=%d p50 %.1f p95 %.1f p99 %.1f max %.1f ms", sorted.count, pct(0.5), pct(0.95), pct(0.99), sorted.last!)
        }
        try await probe(for: 3)
        let idle = summary(delays)

        func timed(_ start: () throws -> Void, finished: @escaping () -> FileTransferFinish?) async throws -> (Double, String) {
            delays = []
            let started = Date()
            try start()
            let deadline = Date().addingTimeInterval(600)
            while finished() == nil, Date() < deadline {
                var now = DispatchTime.now().uptimeNanoseconds
                _ = link.phone.sendControl(Data(bytes: &now, count: 8))
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(finished()?.status, .stored, routeSummary())
            return (Double(data.count) / Date().timeIntervalSince(started), summary(delays))
        }
        var phoneFinish: FileTransferFinish?, macFinish: FileTransferFinish?
        link.phoneEngine.onFinish = { if $0.direction == .outgoing { phoneFinish = $0 } }
        link.macEngine.onFinish = { if $0.direction == .outgoing { macFinish = $0 } }
        let (up, upDelay) = try await timed({ _ = try link.phoneEngine.send(DataByteSource(data), name: "up.bin", type: nil).get() },
                                            finished: { phoneFinish })
        link.macEngine.onRequest = { transfer in
            _ = link.macEngine.send(DataByteSource(data), name: "down.bin", type: nil, transfer: transfer)
        }
        let (down, downDelay) = try await timed({ _ = try link.phoneEngine.request().get() }, finished: { macFinish })
        print(String(format: "FILE-BENCH %d MB phone->mac %.2f MB/s, mac->phone %.2f MB/s", megabytes, up / 1e6, down / 1e6))
        print("FILE-BENCH control delay idle: \(idle)")
        print("FILE-BENCH control delay during phone->mac: \(upDelay)")
        print("FILE-BENCH control delay during mac->phone: \(downDelay)")
        print("FILE-BENCH route: \(routeSummary())")
        for description in descriptions {
            let role = description.prefix { $0 != " " }
            print("FILE-BENCH \(role) SDP " + description.split(separator: "\r\n").filter { $0.hasPrefix("a=max-message-size") || $0.hasPrefix("a=sctp-port") }.joined(separator: " "))
        }
    }
}

private final class RevocationSource: FileByteSource, @unchecked Sendable {
    let byteCount: Int64 = 1
    let readStarted = DispatchSemaphore(value: 0), readRelease = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var reads = 0, closes = 0, reading = false, closeOverlapped = false
    let blockRead: Bool
    init(blockRead: Bool = false) { self.blockRead = blockRead }
    var counts: (Int, Int, Bool) { lock.lock(); defer { lock.unlock() }; return (reads, closes, closeOverlapped) }
    func read(upTo count: Int) throws -> Data {
        lock.lock(); reads += 1; reading = true; lock.unlock()
        readStarted.signal(); if blockRead { readRelease.wait() }
        lock.lock(); reading = false; lock.unlock(); return Data([1])
    }
    func close() { lock.lock(); closes += 1; closeOverlapped = closeOverlapped || reading; lock.unlock() }
}
private final class RevocationLink: FileChannelLink, @unchecked Sendable {
    private let lock = NSLock(); private var sends = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return sends }
    var fileBufferedAmount: UInt64? { 0 }
    func sendFile(_ data: Data) -> Bool { lock.lock(); sends += 1; lock.unlock(); return true }
}
private final class RevocationSink: FileByteSink, @unchecked Sendable {
    private let lock = NSLock(); private var writes = 0, commits = 0, discards = 0
    let commitStarted = DispatchSemaphore(value: 0), commitRelease = DispatchSemaphore(value: 0)
    var blockCommit = false
    var counts: (Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (writes, commits, discards) }
    func write(_ data: Data) throws { lock.lock(); writes += 1; lock.unlock() }
    func commit() throws -> URL {
        commitStarted.signal(); if blockCommit { commitRelease.wait() }
        lock.lock(); commits += 1; lock.unlock(); return URL(fileURLWithPath: "/fixture/committed")
    }
    func discard() { lock.lock(); discards += 1; lock.unlock() }
}

@MainActor
final class FileTransferRevocationTests: XCTestCase {
    private let id = String(repeating: "a", count: 32)
    private func drain(_ queue: DispatchQueue) async { await withCheckedContinuation { c in queue.async { c.resume() } } }
    func testQueuedBeginSendingCannotResurrectAfterReset() async throws {
        let queue = DispatchQueue(label: "fixture.queued-send"), gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }; defer { gate.signal() }
        let io = FileTransferIO(queue: queue), engine = FileTransferEngine(acceptsUnsolicitedOffers: true, io: io)
        let source = RevocationSource(), link = RevocationLink()
        engine.sendControl = { _ in true }; engine.link = { link }
        _ = try engine.send(source, name: "fixture", type: nil, transfer: id).get()
        engine.receive(.accept(id)); engine.reset() // Returns while IO queue remains deliberately blocked.
        XCTAssertTrue(engine.isIdle); gate.signal(); await drain(queue)
        XCTAssertEqual(source.counts.0, 0); XCTAssertEqual(source.counts.1, 1); XCTAssertEqual(link.count, 0)
    }
    func testBlockedSourceReadMayFinishButCannotSendAndCloseIsSerialized() async throws {
        let queue = DispatchQueue(label: "fixture.read"), io = FileTransferIO(queue: queue)
        let engine = FileTransferEngine(acceptsUnsolicitedOffers: true, io: io), source = RevocationSource(blockRead: true), link = RevocationLink()
        defer { source.readRelease.signal() }
        engine.sendControl = { _ in true }; engine.link = { link }
        _ = try engine.send(source, name: "fixture", type: nil, transfer: id).get(); engine.receive(.accept(id))
        XCTAssertEqual(source.readStarted.wait(timeout: .now() + 2), .success)
        engine.cancelAll(status: .notAllowed)
        XCTAssertEqual(source.counts.1, 0, "Revocation does not close concurrently with an in-flight read")
        source.readRelease.signal(); await drain(queue)
        XCTAssertEqual(link.count, 0); XCTAssertEqual(source.counts.1, 1); XCTAssertFalse(source.counts.2)
    }
    func testQueuedReceivingBeginChunksAndDigestCannotWriteOrCommitAfterResetAndSameIDReusesNewLease() async throws {
        let queue = DispatchQueue(label: "fixture.receive"), gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }; defer { gate.signal() }
        let io = FileTransferIO(queue: queue), engine = FileTransferEngine(acceptsUnsolicitedOffers: true, io: io)
        let old = RevocationSink(), replacement = RevocationSink(); var sink: RevocationSink = old
        engine.sendControl = { _ in true }; engine.admit = { _, answer in answer(.success(sink)) }
        let chunk = try XCTUnwrap(FileChunk.encode(transfer: id, offset: 0, payload: Data([1])))
        let digest = FileDigest.hex(SHA256.hash(data: Data([1])))
        engine.receive(.offer(id, name: "old", bytes: 1, type: nil)); engine.receiveChunk(chunk); engine.receive(.complete(id, digest: digest))
        engine.reset(); sink = replacement
        engine.receive(.offer(id, name: "new", bytes: 1, type: nil)); engine.receiveChunk(chunk); engine.receive(.complete(id, digest: digest))
        gate.signal(); await drain(queue); await Task.yield()
        XCTAssertEqual(old.counts.0, 0); XCTAssertEqual(old.counts.1, 0); XCTAssertEqual(old.counts.2, 1)
        XCTAssertEqual(replacement.counts.0, 1); XCTAssertEqual(replacement.counts.1, 1)
        engine.reset()
    }
    func testFinalDigestQueuedAfterWholeFileCannotCommitAfterCancellationReturns() async throws {
        let queue = DispatchQueue(label: "fixture.digest"), io = FileTransferIO(queue: queue)
        let engine = FileTransferEngine(acceptsUnsolicitedOffers: true, io: io), sink = RevocationSink()
        engine.sendControl = { _ in true }; engine.admit = { _, answer in answer(.success(sink)) }
        engine.receive(.offer(id, name: "fixture", bytes: 1, type: nil))
        engine.receiveChunk(try XCTUnwrap(FileChunk.encode(transfer: id, offset: 0, payload: Data([1])))); await drain(queue)
        XCTAssertEqual(sink.counts.0, 1)
        let gate = DispatchSemaphore(value: 0); queue.async { gate.wait() }; defer { gate.signal() }
        engine.receive(.complete(id, digest: FileDigest.hex(SHA256.hash(data: Data([1])))))
        engine.cancelAll(status: .notAllowed); gate.signal(); await drain(queue)
        XCTAssertEqual(sink.counts.1, 0); XCTAssertEqual(sink.counts.2, 1)
    }
    func testRetirementLinearizesWithAlreadyEnteredCommitWithoutQueueOrMainCallbackDeadlock() async throws {
        let queue = DispatchQueue(label: "fixture.commit"), io = FileTransferIO(queue: queue), lease = TransferEffectLease(), sink = RevocationSink()
        sink.blockCommit = true; defer { sink.commitRelease.signal() }
        io.beginReceiving(transfer: id, bytes: 1, sink: sink, lease: lease)
        io.receive(try XCTUnwrap(FileChunk.encode(transfer: id, offset: 0, payload: Data([1]))))
        io.receiveDigest(transfer: id, digest: FileDigest.hex(SHA256.hash(data: Data([1]))))
        XCTAssertEqual(sink.commitStarted.wait(timeout: .now() + 2), .success)
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { io.stopReceiving(lease); stopped.signal() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.05), .timedOut, "Retire must wait for the irreversible operation that already won admission")
        sink.commitRelease.signal(); XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(sink.counts.1, 1, "Commit finished before revocation returned")
        io.receiveDigest(transfer: id, digest: FileDigest.hex(SHA256.hash(data: Data([1])))); await drain(queue)
        XCTAssertEqual(sink.counts.1, 1); XCTAssertFalse(lease.isActive)
    }
    func testReentrantFailedCompleteCannotCancelReplacementUsingSameWireID() async throws {
        let queue = DispatchQueue(label: "fixture.reentrant-event"), io = FileTransferIO(queue: queue)
        let engine = FileTransferEngine(acceptsUnsolicitedOffers: true, io: io), link = RevocationLink()
        engine.link = { link }; var replaced = false
        let replacement = expectation(description: "Reentrant replacement admitted")
        engine.sendControl = { frame in
            if frame.op == "complete", !replaced {
                replaced = true; engine.reset()
                _ = engine.send(RevocationSource(), name: "replacement", type: nil, transfer: self.id)
                replacement.fulfill(); return false
            }
            return true
        }
        _ = try engine.send(RevocationSource(), name: "old", type: nil, transfer: id).get(); engine.receive(.accept(id))
        await drain(queue)
        await fulfillment(of: [replacement], timeout: 2)
        XCTAssertTrue(replaced); XCTAssertEqual(engine.outgoing?.name, "replacement")
        XCTAssertEqual(engine.outgoing?.phase, .waiting)
        engine.reset(); await drain(queue)
    }
    func testDelayedOldSentEventCannotCompleteReplacementUsingSameWireID() async throws {
        let queue = DispatchQueue(label: "fixture.event"), io = FileTransferIO(queue: queue)
        let engine = FileTransferEngine(acceptsUnsolicitedOffers: true, io: io), link = RevocationLink()
        var completes = 0; engine.sendControl = { if $0.op == "complete" { completes += 1 }; return true }; engine.link = { link }
        _ = try engine.send(RevocationSource(), name: "old", type: nil, transfer: id).get(); engine.receive(.accept(id))
        queue.sync {} // Byte send completes; main delivery deliberately cannot run until after replacement below.
        engine.reset(); _ = try engine.send(RevocationSource(), name: "new", type: nil, transfer: id).get()
        await Task.yield(); await Task.yield()
        XCTAssertEqual(engine.outgoing?.phase, .waiting); XCTAssertEqual(completes, 0)
        engine.reset(); await drain(queue)
    }
}

private final class RevocationPasteboard: HostPasteboardAccess, @unchecked Sendable {
    private let lock = NSLock(); private var stored: [ClipboardPayload] = []
    var writes: [ClipboardPayload] { lock.lock(); defer { lock.unlock() }; return stored }
    var changeCount: Int { writes.count }
    func read(limit: Int) -> HostPasteboardRead { .refused(.empty) }
    func write(_ payload: ClipboardPayload) -> Bool { lock.lock(); stored.append(payload); lock.unlock(); return true }
}
@MainActor
final class HostFileLinkRevocationTests: XCTestCase {
    func testScreenOnlyConsentAndStaleSessionRefuseFileAndLinkAdmission() async throws {
        let queue = DispatchQueue(label: "fixture.consent"), board = RevocationPasteboard()
        let offer = HostLinkOffer(showPanel: false, opener: { _ in XCTFail("Screen-only must not open links"); return false })
        var destinations = 0, allowed = false
        let service = HostFileTransferService(destination: { destinations += 1; return nil }, pasteboard: board,
                                              queue: queue, linkOffer: offer)
        service.refusal = { allowed ? nil : .notAllowed }
        var results: [FileFrame] = []
        service.engine.sendControl = { results.append($0); return true }
        let id = FileTransferID.make()
        let frames: [FileFrame] = [.offer(id, name: "fixture.txt", bytes: 1, type: nil), .request(id),
                                   .link(id, url: "https://fixture.invalid")]
        for frame in frames { service.receive(frame, current: true) }
        XCTAssertEqual(results.map(\.status), Array(repeating: FileTransferStatus.notAllowed.rawValue, count: 3))
        allowed = true
        for frame in frames { service.receive(frame, current: false) }
        await withCheckedContinuation { c in queue.async { c.resume() } }
        XCTAssertEqual(results.count, 3); XCTAssertEqual(destinations, 0)
        XCTAssertNil(service.engine.incoming); XCTAssertNil(offer.currentID); XCTAssertTrue(board.writes.isEmpty)
        service.reset()
    }

    func testConsentRevocationRetiresPendingHostAdmission() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = DispatchQueue(label: "fixture.pending-consent"), gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }; defer { gate.signal() }
        let service = HostFileTransferService(destination: { folder }, queue: queue)
        var allowed = true
        service.refusal = { allowed ? nil : .notAllowed }; service.engine.sendControl = { _ in true }
        service.receive(.offer(FileTransferID.make(), name: "fixture.txt", bytes: 1, type: nil), current: true)
        XCTAssertEqual(service.engine.incoming?.phase, .waiting)
        allowed = false; service.revoke()
        gate.signal(); await withCheckedContinuation { c in queue.async { c.resume() } }
        await Task.yield()
        XCTAssertNil(service.engine.incoming)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "Retired admission must never create a destination")
    }

    func testStaleCompletionAndRevokedChunksCannotCommit() async throws {
        let queue = DispatchQueue(label: "fixture.service-consent-io"), sink = RevocationSink()
        let service = HostFileTransferService(destination: { nil }, io: FileTransferIO(queue: queue))
        var allowed = true
        service.refusal = { allowed ? nil : .notAllowed }; service.engine.sendControl = { _ in true }
        service.engine.admit = { _, answer in answer(.success(sink)) }
        let id = FileTransferID.make(), data = Data([1])
        service.receive(.offer(id, name: "fixture.txt", bytes: 1, type: nil), current: true)
        service.engine.receiveChunk(try XCTUnwrap(FileChunk.encode(transfer: id, offset: 0, payload: data)))
        await withCheckedContinuation { c in queue.async { c.resume() } }
        let complete = FileFrame.complete(id, digest: FileDigest.hex(SHA256.hash(data: data)))
        service.receive(complete, current: false)
        XCTAssertEqual(sink.counts.1, 0, "Old epoch completion cannot commit current bytes")
        allowed = false; service.revoke()
        service.receive(complete, current: true)
        service.engine.receiveChunk(try XCTUnwrap(FileChunk.encode(transfer: id, offset: 0, payload: data)))
        await withCheckedContinuation { c in queue.async { c.resume() } }
        XCTAssertEqual(sink.counts.0, 1); XCTAssertEqual(sink.counts.1, 0); XCTAssertEqual(sink.counts.2, 1)
        XCTAssertNil(service.engine.incoming)
    }

    func testActualServiceResetAndRevokeFenceQueuedLinkWriteDismissAndOldOpen() async throws {
        for revoke in [false, true] {
            let queue = DispatchQueue(label: "fixture.link"), gate = DispatchSemaphore(value: 0), board = RevocationPasteboard()
            queue.async { gate.wait() }; defer { gate.signal() }
            var opened: [URL] = [], refusal: FileTransferStatus?
            let offer = HostLinkOffer(showPanel: false, opener: { opened.append($0); return true })
            let service = HostFileTransferService(destination: { nil }, pasteboard: board, queue: queue, linkOffer: offer)
            service.refusal = { refusal }; service.engine.sendControl = { _ in true }
            let id = String(repeating: "a", count: 32), first = "https://fixture.invalid/old", next = "https://fixture.invalid/new"
            service.receive(.link(id, url: first), current: true); let old = try XCTUnwrap(offer.currentID)
            if revoke { service.revoke() } else { service.reset() }
            XCTAssertNil(offer.currentID); offer.openOffer(old); XCTAssertTrue(opened.isEmpty)
            gate.signal(); await withCheckedContinuation { c in queue.async { c.resume() } }
            XCTAssertTrue(board.writes.isEmpty, "Queued URL must not overwrite clipboard after reset/revoke returns")
            service.receive(.link(id, url: next), current: true); let current = try XCTUnwrap(offer.currentID)
            offer.openOffer(old); XCTAssertTrue(opened.isEmpty, "Old SwiftUI action cannot open replacement link")
            refusal = .notAllowed; offer.openOffer(current); XCTAssertTrue(opened.isEmpty, "Current offer still needs live owner authorization")
            refusal = nil; offer.openOffer(current); XCTAssertEqual(opened.map(\.absoluteString), [next]); XCTAssertNil(offer.currentID)
            service.reset(); await withCheckedContinuation { c in queue.async { c.resume() } }
        }
    }
    /// Batch-5 review: a new capture geometry used to reset the Mac's transfer silently, leaving the phone showing
    /// progress until the stall timeout. The Mac now revokes with a cancel the phone can show.
    func testRevokeTellsThePhoneAboutAnInFlightTransfer() throws {
        let service = HostFileTransferService(destination: { nil })
        var sent: [FileFrame] = []
        service.engine.sendControl = { sent.append($0); return true }
        let transfer = try service.engine.send(DataByteSource(Data([1, 2, 3])), name: "a.txt", type: nil).get()
        XCTAssertEqual(sent.last?.op, "offer")
        service.revoke()
        XCTAssertEqual(sent.last?.op, "cancel"); XCTAssertEqual(sent.last?.transfer, transfer)
        XCTAssertTrue(service.engine.isIdle)
    }
    /// MS05: no "Allow file transfer" switch. A stored legacy `false` is ignored; the view-only scope still refuses.
    func testFilesNeedOwnerControlConsentAndIgnoreTheRemovedMacSetting() throws {
        let suite = "MS05-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "allowFileTransfer")
        _ = HostPreferences(defaults: defaults)
        func refusal(scope: Bool = false, connected: Bool = true, sharing: Bool = true, paused: Bool = false,
                     viewOnly: Bool = false, locking: Bool = false, control: Bool = true) -> HostFileTransferService.Refusal? {
            HostFileTransferService.refusal(viewOnlyScope: scope, connected: connected, sharing: sharing, controlAllowed: control, paused: paused,
                                            liveViewOnly: viewOnly, locking: locking)
        }
        XCTAssertNil(refusal())
        XCTAssertEqual(refusal(control: false), .controlDisabled)
        XCTAssertEqual(refusal(scope: true)?.status, .disabled)
        XCTAssertEqual(refusal(connected: false), .noSession)
        XCTAssertEqual(refusal(sharing: false), .notSharing)
        XCTAssertEqual(refusal(paused: true), .paused)
        XCTAssertEqual(refusal(viewOnly: true), .viewOnly)
        XCTAssertEqual(refusal(locking: true)?.status, .notAllowed)
        XCTAssertEqual(HostFileTransferService.refusal(viewOnlyScope: false, connected: true, sharing: true, controlAllowed: true, paused: false,
                                                       liveViewOnly: false, locking: true, lockFailed: true), .lockFailed)
        XCTAssertThrowsError(try FileFrame(op: "cancel", transfer: String(repeating: "d", count: 32), reason: "paused").validate())
        let service = HostFileTransferService(destination: { nil })
        var sent: [FileFrame] = []
        service.engine.sendControl = { sent.append($0); return true }
        service.refusal = { refusal(scope: true)?.status }
        service.receive(.request(String(repeating: "b", count: 32)), current: true)
        XCTAssertEqual(sent.last?.status, FileTransferStatus.disabled.rawValue, "view-only scope keeps its refusal")
        // 1 Oct device report: every send said only "isn't accepting files". The refusal now says which condition.
        service.refusal = { refusal(paused: true)?.status }
        service.refusalReason = { refusal(paused: true)?.rawValue }
        service.receive(.offer(String(repeating: "c", count: 32), name: "a.txt", bytes: 1, type: nil), current: true)
        let result = try XCTUnwrap(sent.last)
        XCTAssertEqual(result.reason, "paused"); XCTAssertNoThrow(try result.validate())
        let phone = FileTransferEngine(acceptsUnsolicitedOffers: false)
        var finish: FileTransferFinish?
        phone.onFinish = { finish = $0 }
        phone.sendControl = { _ in true }
        let transfer = try phone.send(DataByteSource(Data([1])), name: "a.txt", type: nil).get()
        phone.receive(.result(transfer, .notAllowed, reason: "paused"))
        XCTAssertEqual(finish?.reason, "paused")
        XCTAssertEqual(HostFileTransferService.defaultDestination()?.pathComponents.suffix(2), ["Downloads", "Farside"])
    }
}
