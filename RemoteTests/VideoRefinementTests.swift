import XCTest
import CoreVideo
import CryptoKit

final class VideoRefinementTests: XCTestCase {
    private func identity(_ bytes: Data, width: Int = 16, height: Int = 16) -> VideoRefinementIdentity {
        .init(generation: String(repeating: "a", count: 32), geometryEpoch: 7, scopeEpoch: 3,
            content: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), width: width, height: height,
            x: 0, y: 0, roiWidth: width, roiHeight: height, transfer: "srgb")
    }
    func testPublicPNGRoundTripPreservesOpaqueColoredTextBytesAndRejectsHeaderDimensionMismatch() throws {
        var bytes = Data(count: 16 * 16 * 4)
        for pixel in 0..<(16 * 16) { let index = pixel * 4; bytes[index] = UInt8(pixel & 255); bytes[index+1] = pixel % 2 == 0 ? 255 : 0; bytes[index+2] = UInt8((pixel * 7) & 255); bytes[index+3] = 255 }
        let proof = identity(bytes)
        let png = try XCTUnwrap(VideoRefinementPNG.encode(bytes, identity: proof))
        XCTAssertLessThanOrEqual(png.count, 256 * 1024)
        let pixels = try XCTUnwrap(VideoRefinementPNG.decode(VideoRefinementImage(identity: proof, png: png)))
        CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(pixels), base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
        for row in 0..<16 { XCTAssertEqual(Data(bytes: base.advanced(by: row * stride), count: 64), bytes.subdata(in: (row*64)..<(row*64+64))) }
        XCTAssertNil(VideoRefinementPNG.decode(VideoRefinementImage(identity: identity(Data(), width: 8, height: 8), png: png)))
        XCTAssertNil(VideoRefinementPNG.decode(VideoRefinementImage(identity: proof, png: Data(repeating: 1, count: 256 * 1024 + 1))))
    }
    func testAuthorizedStreamBGRAChoicePreservesExactExistingViewportGeometry() {
        let output = CapturePixelDimensions(width: 1920, height: 1200)
        let region = CaptureRegion(epoch: 7, x: 48, y: 32, width: 960, height: 600, outputWidth: 960, outputHeight: 600)
        let base = RemoteCaptureConfiguration.streamConfiguration(output: output, region: region, showsCursor: false,
            fps: 60, displayRefreshHz: 60, tuning: .tuned)
        let refined = RemoteCaptureConfiguration.streamConfiguration(output: output, region: region, showsCursor: false,
            fps: 60, displayRefreshHz: 60, tuning: .tuned, refinesText: true)
        XCTAssertEqual(base.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(refined.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(refined.sourceRect, base.sourceRect); XCTAssertEqual(refined.width, base.width); XCTAssertEqual(refined.height, base.height)
        XCTAssertEqual(refined.preservesAspectRatio, base.preservesAspectRatio); XCTAssertEqual(refined.showsCursor, base.showsCursor)
    }
    func testReliableChannelUsesEncodedSizeAndOneAckBoundaryAndRevokeRetiresQueuedImage() throws {
        let sender = VideoRefinementChannel(), receiver = VideoRefinementChannel()
        sender.configure(enabled: true, geometry: 7, scope: 3); receiver.configure(enabled: true, geometry: 7, scope: 3)
        let bytes = Data(repeating: 1, count: 24000), proof = identity(Data())
        var chunks: [Data] = [], acks: [Data] = [], received: [Data] = []
        sender.send = { data, ack in XCTAssertFalse(ack); XCTAssertLessThanOrEqual(data.count, 16384); chunks.append(data); return true }
        receiver.send = { data, ack in XCTAssertTrue(ack); acks.append(data); return true }
        receiver.image = { received.append($0.png) }
        sender.offer(.init(identity: proof, png: bytes), at: 10)
        sender.pump(at: 10.1); XCTAssertEqual(chunks.count, 1, "No second chunk until exact ACK")
        for index in 0..<3 {
            receiver.receive(chunks[index], at: 10.2 + Double(index) * 0.1)
            sender.receive(acks[index], at: 10.2 + Double(index) * 0.1)
            sender.pump(at: 10.21 + Double(index) * 0.1)
        }
        XCTAssertEqual(received, [bytes]); XCTAssertEqual(chunks.count, 3)
        sender.offer(.init(identity: proof, png: bytes), at: 11)
        sender.configure(enabled: false, geometry: 8, scope: 3)
        let count = chunks.count; sender.pump(at: 11.1); XCTAssertEqual(chunks.count, count)
        receiver.configure(enabled: false, geometry: 8, scope: 3); receiver.receive(chunks.last!, at: 11.1)
        XCTAssertEqual(received.count, 1)
    }
    func testCongestedAcknowledgementRetriesWithoutSendingAnotherChunkOrIndependentCredit() throws {
        let sender = VideoRefinementChannel(), receiver = VideoRefinementChannel()
        sender.configure(enabled: true, geometry: 7, scope: 3); receiver.configure(enabled: true, geometry: 7, scope: 3)
        var chunks: [Data] = [], acknowledgements: [Data] = [], permit = false
        sender.send = { data,_ in chunks.append(data); return true }
        receiver.send = { data,_ in if !permit { return false }; acknowledgements.append(data); return true }
        sender.offer(.init(identity: identity(Data()), png: Data(repeating: 0, count: 10000)), at: 10)
        receiver.receive(chunks[0], at: 10.1); XCTAssertTrue(acknowledgements.isEmpty)
        sender.pump(at: 10.2); XCTAssertEqual(chunks.count, 1)
        permit = true; receiver.pump(at: 10.3); XCTAssertEqual(acknowledgements.count, 1)
        sender.receive(acknowledgements[0], at: 10.3); sender.pump(at: 10.4); XCTAssertEqual(chunks.count, 2)
    }
    func testWrongAcknowledgementOverflowScopeAndTimeoutDoNotDrain() throws {
        let pipe = VideoRefinementChannel(); pipe.configure(enabled: true, geometry: 7, scope: 3)
        var messages: [Data] = []; pipe.send = { data,_ in messages.append(data); return true }
        let proof = identity(Data()); pipe.offer(.init(identity: proof, png: Data(repeating: 0, count: 20000)), at: 10)
        let first = try JSONDecoder().decode(VideoRefinementChunk.self, from: messages[0])
        let forged = VideoRefinementChunk(version: 1, id: first.id, identity: proof, total: first.total, offset: 8999, body: Data(), ack: true)
        pipe.receive(try JSONEncoder().encode(forged), at: 10.1); pipe.pump(at: 10.2); XCTAssertEqual(messages.count, 1)
        pipe.pump(at: 12.1); pipe.receive(try JSONEncoder().encode(VideoRefinementChunk(version: 1, id: first.id, identity: proof, total: first.total, offset: 9000, body: Data(), ack: true)), at: 12.2)
        pipe.pump(at: 12.3); XCTAssertEqual(messages.count, 1)
        XCTAssertThrowsError(try VideoRefinementChunk(version: 1, id: first.id, identity: proof, total: 262145, offset: 0, body: Data([1]), ack: false).validate())
        pipe.end(); pipe.configure(enabled: true, geometry: 7, scope: 3); pipe.offer(.init(identity: proof, png: Data([1])), at: 13); XCTAssertEqual(messages.count, 1)
    }
    func testOverlayRequiresExactContentGeometryScopeAndExpiry() throws {
        let bytes = Data(repeating: 255, count: 1024), proof = identity(bytes)
        let png = try XCTUnwrap(VideoRefinementPNG.encode(bytes, identity: proof))
        let context = VideoFeedbackContext(); context.configure(allowed: true, ltr: false, refinement: true, geometry: 7, scope: 3)
        context.acceptRefinement(.init(identity: proof, png: png))
        let tag = VideoFrameTag(generation: proof.generation, nonce: String(repeating: "b", count: 32), geometryEpoch: 7, scopeEpoch: 3, ltrToken: nil, refinement: proof)
        XCTAssertNotNil(context.refinement(for: tag, at: ProcessInfo.processInfo.systemUptime))
        var changed = tag; changed.refinement = identity(Data(repeating: 0, count: 1024))
        XCTAssertNil(context.refinement(for: changed, at: ProcessInfo.processInfo.systemUptime))
        XCTAssertNil(context.refinement(for: tag, at: ProcessInfo.processInfo.systemUptime + 3))
        context.configure(allowed: true, ltr: false, refinement: true, geometry: 8, scope: 3)
        XCTAssertNil(context.refinement(for: tag, at: ProcessInfo.processInfo.systemUptime))
    }
}
