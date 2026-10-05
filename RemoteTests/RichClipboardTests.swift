import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

func richClipboardFixture(width: Int = 2, height: Int = 3, orientation: Int = 1, jpeg: Bool = false) throws -> Data {
    var pixels = Data(repeating: 0x80, count: width * height * 4)
    pixels[3] = 0
    let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
    let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                                    decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let result = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(result, (jpeg ? UTType.jpeg : .png).identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return result as Data
}
final class RichClipboardTests: XCTestCase {
    func testCanonicalPNGPreservesAlphaAndNormalizesRotation() throws {
        let transparent = try RichClipboardPNG.normalize(richClipboardFixture())
        let source = try XCTUnwrap(CGImageSourceCreateWithData(transparent.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertTrue([CGImageAlphaInfo.last, .first, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo))
        let rotated = try RichClipboardPNG.normalize(richClipboardFixture(width: 2, height: 3, orientation: 6, jpeg: true))
        XCTAssertEqual(rotated.metadata.width, 3); XCTAssertEqual(rotated.metadata.height, 2)
        XCTAssertEqual(transparent.metadata.digest, ClipboardDigest.hex(transparent.data))
    }
    func testInvalidOversizedAndDecodedBombMetadataAreRejected() throws {
        XCTAssertThrowsError(try RichClipboardPNG.normalize(Data([1, 2, 3])))
        XCTAssertThrowsError(try RichClipboardPNG.normalize(Data(repeating: 0, count: RichClipboardLimits.encodedBytes + 1)))
        XCTAssertThrowsError(try RichImageMetadata(bytes: 1, width: 5000, height: 5000, digest: String(repeating: "a", count: 64)).validate())
        let png = try RichClipboardPNG.normalize(richClipboardFixture())
        let wrong = RichImageMetadata(bytes: png.data.count, width: 1, height: 1, digest: png.metadata.digest)
        XCTAssertThrowsError(try RichClipboardPNG.validateIncoming(png.data, expected: wrong))
        var corrupt = png.data; corrupt[corrupt.count / 2] ^= 1
        XCTAssertThrowsError(try RichClipboardPNG.validateIncoming(corrupt, expected: png.metadata))
    }
    func testOversizedPNGHeaderIsRejectedBeforeRasterDecode() throws {
        var data = try richClipboardFixture()
        func write32(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - index * 8)) }
        }
        write32(5000, at: 16); write32(5000, at: 20)
        var crc: UInt32 = 0xffffffff
        for byte in data[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        write32(crc ^ 0xffffffff, at: 29)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 5000)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 5000)
        XCTAssertThrowsError(try RichClipboardPNG.normalize(data))
    }
    func testSixteenBitSourceIsRejectedBeforeRasterDecode() throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data([0, 0]) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: 2,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertThrowsError(try RichClipboardPNG.normalize(bytes as Data))
    }
    func testRichProtocolRejectsUnboundControlAndInvalidMetadata() throws {
        let id = FileTransferID.make()
        XCTAssertThrowsError(try RichClipboardMessage(operation: .control, transfer: id, revision: 1, control: .offer(FileTransferID.make(), name: "Clipboard image", bytes: 1, type: "public.png")).validate())
        XCTAssertThrowsError(try RichClipboardMessage(operation: .committed, transfer: id).validate())
        XCTAssertThrowsError(try RichClipboardMessage(operation: .push, transfer: id, revision: 1, image: RichImageMetadata(bytes: 1, width: 1, height: 1, digest: String(repeating: "a", count: 64))).validate())
        let frame = try WorkspaceFrame(kind: .richClipboard, requestID: InputCausalEnvelope.identity(), value: ["operation": "pull", "transfer": id, "path": "/private"])
        XCTAssertThrowsError(try RichClipboardMessage.decode(frame))
    }
    func testRevisionBarrierRejectsUnseenOldTransfersAndAllowsNewerText() {
        var barrier = ClipboardRevisionBarrier()
        XCTAssertTrue(barrier.admit(5)); barrier.commit(8)
        XCTAssertFalse(barrier.admit(5)); XCTAssertFalse(barrier.admit(7)); XCTAssertFalse(barrier.admit(8))
        XCTAssertTrue(barrier.admit(9)); XCTAssertFalse(barrier.admit(6)); barrier.commit(9)
        XCTAssertFalse(barrier.admit(9)); XCTAssertTrue(barrier.admit(10))
    }
    func testAutomaticAssemblerPinsEverySourceRevision() throws {
        var frames = try ClipboardChunker.frames(for: ClipboardPayload(text: String(repeating: "x", count: 5000)), operation: "data", transfer: ClipboardTransferID.make())
        frames = frames.map { var value = $0; value.automatic = true; value.sourceRevision = 10; return value }
        var assembler = ClipboardAssembler()
        _ = assembler.accept(frames[0], at: 0)
        frames[1].sourceRevision = 11
        if case .failed = assembler.accept(frames[1], at: 0.1) {} else { XCTFail("mixed source revisions must fail") }
    }
    func testBulkNamespaceNeverMasqueradesAsAUserFileChunk() {
        let data = Data([1,2,3])
        XCTAssertNil(RichClipboardBulk.unwrap(data))
        let rich = RichClipboardBulk.magic + data
        XCTAssertEqual(RichClipboardBulk.unwrap(rich), data)
        XCTAssertNil(FileChunk.decode(rich))
        XCTAssertNil(RichClipboardBulk.unwrap(RichClipboardBulk.magic))
    }
}

@MainActor
final class RichClipboardEndpointTests: XCTestCase {
    final class Link: FileChannelLink {
        var receive: ((Data) -> Void)?
        var holding = false
        var held: [Data] = []
        func sendFile(_ data: Data) -> Bool {
            if holding { held.append(data) } else { receive?(data) }; return true
        }
        var fileBufferedAmount: UInt64? { 0 }
    }
    private func endpoints() -> (RichClipboardEndpoint, RichClipboardEndpoint, Link, Link) {
        let host = RichClipboardEndpoint(isHost: true), phone = RichClipboardEndpoint(isHost: false)
        host.allowed = { true }; phone.allowed = { true }
        host.beginExplicit = { 10 }
        host.transport = { [weak phone] in phone?.receive($0); return true }
        phone.transport = { [weak host] in host?.receive($0); return true }
        let toHost = Link(), toPhone = Link()
        toHost.receive = { [weak host] data in if let raw = RichClipboardBulk.unwrap(data) { host?.engine.receiveChunk(raw) } }
        toPhone.receive = { [weak phone] data in if let raw = RichClipboardBulk.unwrap(data) { phone?.engine.receiveChunk(raw) } }
        host.engine.link = { RichClipboardLink(toPhone) }; phone.engine.link = { RichClipboardLink(toHost) }
        return (host, phone, toHost, toPhone)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "bounded endpoint completion")
    }
    func testExplicitPNGPushAndPullCommitAfterVerifiedBulk() async throws {
        let (host, phone, _, _) = endpoints()
        let png = try RichClipboardPNG.normalize(richClipboardFixture())
        var hostStored: Data?, phoneStored: Data?, phoneBarrier: UInt64?
        host.storeImage = { image, _, lease, completion in XCTAssertTrue(lease.isActive); hostStored = image.data; completion(true) }
        phone.storeImage = { image, _, lease, completion in XCTAssertTrue(lease.isActive); phoneStored = image.data; completion(true) }
        phone.finishExplicit = { revision, committed in if committed { phoneBarrier = revision } }
        phone.sendImage(RichClipboardSource(png: png, stillCurrent: { true }))
        try await wait { !host.busy && !phone.busy }
        XCTAssertNotNil(hostStored); XCTAssertEqual(phoneBarrier, 10)
        host.readImage = { _, completion in completion(.success(RichClipboardSource(png: png, stillCurrent: { true }))) }
        phone.requestImage()
        try await wait { !host.busy && !phone.busy }
        XCTAssertNotNil(phoneStored); XCTAssertEqual(phoneBarrier, 10)
        XCTAssertTrue(phone.engine.isIdle && host.engine.isIdle)
    }
    func testCancelAndAuthorityLossNeverCommitLateChunks() async throws {
        let (host, phone, toHost, _) = endpoints()
        let png = try RichClipboardPNG.normalize(richClipboardFixture())
        toHost.holding = true
        var writes = 0; host.storeImage = { _, _, _, completion in writes += 1; completion(true) }
        phone.sendImage(RichClipboardSource(png: png, stillCurrent: { true }))
        try await wait { !toHost.held.isEmpty }
        phone.cancel()
        for data in toHost.held { toHost.receive?(data) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(writes, 0); XCTAssertFalse(host.busy); XCTAssertFalse(phone.busy)
        host.allowed = { false }
        phone.requestImage()
        XCTAssertFalse(phone.busy); XCTAssertEqual(writes, 0)
    }
    func testPrematureCommitAndRetiredStoreCallbackCannotReportSuccess() async throws {
        let (host, phone, toHost, _) = endpoints()
        let png = try RichClipboardPNG.normalize(richClipboardFixture())
        toHost.holding = true
        var id: String?, committed = false, writes = 0
        phone.transport = { [weak host] frame in id = try? RichClipboardMessage.decode(frame).transfer; host?.receive(frame); return true }
        phone.finishExplicit = { _, value in committed = committed || value }
        host.storeImage = { _, _, _, completion in writes += 1; completion(true) }
        phone.sendImage(RichClipboardSource(png: png, stillCurrent: { true }))
        try await wait { !toHost.held.isEmpty }
        phone.receive(try WorkspaceFrame(kind: .richClipboard, requestID: InputCausalEnvelope.identity(), value: RichClipboardMessage(operation: .committed, transfer: try XCTUnwrap(id), revision: 10)))
        XCTAssertFalse(committed); XCTAssertEqual(writes, 0); XCTAssertFalse(phone.busy); XCTAssertFalse(host.busy)

        let (sender, receiver, _, _) = endpoints()
        var delayed: ((Bool) -> Void)?, receiverCommitted = false
        sender.readImage = { _, completion in completion(.success(RichClipboardSource(png: png, stillCurrent: { true }))) }
        receiver.storeImage = { _, _, _, completion in delayed = completion }
        receiver.finishExplicit = { _, value in receiverCommitted = receiverCommitted || value }
        receiver.requestImage(); try await wait { delayed != nil }
        receiver.reset(); delayed?(true)
        XCTAssertFalse(receiverCommitted); XCTAssertFalse(receiver.busy)
        sender.reset()
    }
    func testUnsolicitedRichOfferAndSourceReplacementAreRejected() async throws {
        let (host, phone, _, _) = endpoints()
        let id = FileTransferID.make()
        phone.receive(try WorkspaceFrame(kind: .richClipboard, requestID: InputCausalEnvelope.identity(), value: RichClipboardMessage(operation: .control, transfer: id, revision: 1, control: .offer(id, name: "Clipboard image", bytes: 1, type: "public.png"))))
        XCTAssertNil(phone.engine.incoming)
        let png = try RichClipboardPNG.normalize(richClipboardFixture())
        var current = true, writes = 0
        host.storeImage = { _, _, _, completion in writes += 1; completion(true) }
        phone.sendImage(RichClipboardSource(png: png, stillCurrent: { current }))
        current = false
        try await wait { !host.busy && !phone.busy }
        XCTAssertEqual(writes, 0)
    }
}
