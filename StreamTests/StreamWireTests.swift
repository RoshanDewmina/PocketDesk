import XCTest
import Network
import VideoToolbox
import CoreVideo

final class StreamWireTests: XCTestCase {

    func testActualHostEncoderConfigurationAccepts1080p() throws {
        let host = HostStream()
        try host.makeEncoder(width: 1920, height: 1080)
        host.stop()
        host.queue.sync {}
    }
    func testHardwareH264EncoderAndDecoderRoundTrip() throws {
        var encoder: VTCompressionSession?
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
                             kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        let created = VTCompressionSessionCreate(allocator: nil, width: 320, height: 240, codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
        XCTAssertEqual(created, noErr)
        let compression = try XCTUnwrap(encoder)
        defer { VTCompressionSessionInvalidate(compression) }
        XCTAssertEqual(VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue), noErr)
        XCTAssertEqual(VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse), noErr)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 128, CVPixelBufferGetBytesPerRow(image) * 240)
        CVPixelBufferUnlockBaseAddress(image, [])
        let encoded = expectation(description: "hardware encoded")
        var compressed: CMSampleBuffer?
        XCTAssertEqual(VTCompressionSessionEncodeFrame(compression, imageBuffer: image,
            presentationTimeStamp: .zero, duration: CMTime(value: 1, timescale: 60), frameProperties: nil,
            infoFlagsOut: nil) { status, _, sample in
                XCTAssertEqual(status, noErr); compressed = sample; encoded.fulfill()
            }, noErr)
        wait(for: [encoded], timeout: 5)
        let sample = try XCTUnwrap(compressed)
        var accelerated: CFTypeRef?
        let propertyStatus = VTSessionCopyProperty(compression, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                                  allocator: nil, valueOut: &accelerated)
        // RequireHardware makes successful session creation the hardware gate. Some low-latency encoders do not expose this optional query.
        XCTAssertTrue(propertyStatus == noErr || propertyStatus == kVTPropertyNotSupportedErr)
        if propertyStatus == noErr { XCTAssertEqual(accelerated as? Bool, true) }
        else { print("Hardware query unsupported; session was created with RequireHardware=true and encoded successfully") }
        let wireFrame = try XCTUnwrap(HostStream().serialize(sample, id: 42, captureTime: 1, ms: 2))
        let parsed = try VideoFrame(payload: wireFrame.payload)
        XCTAssertEqual(parsed.id, 42)
        XCTAssertEqual(parsed.bytes, wireFrame.bytes)
        XCTAssertFalse(parsed.sps.isEmpty); XCTAssertFalse(parsed.pps.isEmpty)
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_H264)
        var decoder: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &decoder), noErr)
        let decompression = try XCTUnwrap(decoder)
        defer { VTDecompressionSessionInvalidate(decompression) }
        let decoded = expectation(description: "decoded")
        XCTAssertEqual(VTDecompressionSessionDecodeFrame(decompression, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            XCTAssertEqual(status, noErr)
            XCTAssertEqual(image.map { CVPixelBufferGetWidth($0) }, 320)
            XCTAssertEqual(image.map { CVPixelBufferGetHeight($0) }, 240)
            decoded.fulfill()
        }, noErr)
        wait(for: [decoded], timeout: 5)
    }

    func testFrameRoundTripAndEveryTruncationIsRejected() throws {
        let frame = VideoFrame(id: UInt64.max, captureTime: 8.25, encodeMS: 3.1,
            sps: Data([0x67, 0x42]), pps: Data([0x68]), bytes: Data([0,0,0,1,0x65]))
        let copy = try VideoFrame(payload: frame.payload)
        XCTAssertEqual(copy.id, frame.id)
        XCTAssertEqual(copy.captureTime, frame.captureTime)
        XCTAssertEqual(copy.encodeMS, frame.encodeMS)
        XCTAssertEqual(copy.sps, frame.sps); XCTAssertEqual(copy.pps, frame.pps); XCTAssertEqual(copy.bytes, frame.bytes)
        // Truncating the fixed header or either parameter set must never read out of bounds.
        for length in 0..<31 { XCTAssertThrowsError(try VideoFrame(payload: frame.payload.prefix(length))) }
    }
    func testRejectsNonFiniteTimingAndInvalidPairingKeys() throws {
        let frame = VideoFrame(id: 1, captureTime: .nan, encodeMS: 1, sps: Data([1]), pps: Data([2]), bytes: Data([3]))
        XCTAssertThrowsError(try VideoFrame(payload: frame.payload))
        XCTAssertNil(StreamWire.parseKey(String(repeating: "a", count: 63)))
        XCTAssertNil(StreamWire.parseKey(String(repeating: "g", count: 64)))
        XCTAssertNil(StreamWire.parseKey(String(repeating: "Ａ", count: 64)))
        let secret = try StreamWire.randomKey()
        XCTAssertEqual(secret.count, 32)
        XCTAssertEqual(StreamWire.parseKey(secret.map { String(format: "%02x", $0) }.joined()), secret)
        XCTAssertNotEqual(secret, try StreamWire.randomKey())
    }
    func testReaderHandlesSlicedDataAndRejectsOversizedTake() throws {
        let data = Data([99,0,0,1,0,88]).dropFirst().dropLast()
        var reader = WireReader(data: Data(data))
        XCTAssertEqual(try reader.integer(UInt32.self), 256)
        XCTAssertThrowsError(try reader.take(1))
        XCTAssertThrowsError(try reader.take(-1))
    }
    func testTLSAuthenticatesAndTransmitsFramedPayload() throws {
        try exerciseTLS(wrongKey: false)
    }
    func testLargeFrameCrossesTLSRecordsWithoutTruncation() throws {
        try exerciseTLS(wrongKey: false, payload: Data(repeating: 0xA7, count: 1_000_000))
    }
    func testWrongSessionKeyCannotAuthenticate() throws {
        try exerciseTLS(wrongKey: true)
    }
    private func exerciseTLS(wrongKey: Bool, payload: Data = Data("framing works".utf8)) throws {
        let queue = DispatchQueue(label: "test.tls.\(UUID())")
        let key = try StreamWire.randomKey()
        let params = StreamWire.parameters(key: key)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params, on: .any)
        let done = expectation(description: wrongKey ? "authentication rejected" : "round trip")
        let stateLock = NSLock()
        var server: WireConnection?
        var client: WireConnection?
        var authenticated = false
        var completed = false
        func finish() { stateLock.lock(); defer { stateLock.unlock() }; if !completed { completed = true; done.fulfill() } }
        listener.newConnectionHandler = { connection in
            let peer = WireConnection(connection, queue: queue); server = peer
            peer.onPacket = { kind, data in
                XCTAssertEqual(kind, 7); XCTAssertTrue(data == payload, "TLS must preserve the complete framed payload")
                peer.send(StreamWire.packet(8, data))
            }
            peer.start()
        }
        listener.stateUpdateHandler = { state in
            guard case .ready = state, let port = listener.port else { return }
            let clientKey = wrongKey ? Data(repeating: 0xEE, count: 32) : key
            let peer = WireConnection(NWConnection(host: "127.0.0.1", port: port, using: StreamWire.parameters(key: clientKey)), queue: queue)
            client = peer
            peer.onReady = { stateLock.lock(); authenticated = true; stateLock.unlock(); peer.send(StreamWire.packet(7, payload)) }
            peer.onPacket = { kind, data in XCTAssertEqual(kind, 8); XCTAssertTrue(data == payload, "TLS must preserve the complete framed payload"); finish() }
            peer.onClose = { _ in if wrongKey { finish() } }
            peer.start()
        }
        listener.start(queue: queue)
        wait(for: [done], timeout: 12)
        stateLock.lock(); XCTAssertEqual(authenticated, !wrongKey); stateLock.unlock()
        queue.sync { client?.close(); server?.close(); listener.cancel() }
    }
    func testUntrustedLengthClosesBeforeAllocatingPayload() throws {
        let queue = DispatchQueue(label: "test.length")
        let listener = try NWListener(using: .tcp, on: .any)
        let done = expectation(description: "length rejected")
        var receiver: WireConnection?
        var sender: NWConnection?
        listener.newConnectionHandler = { connection in
            let peer = WireConnection(connection, queue: queue); receiver = peer
            peer.onPacket = { _, _ in XCTFail("Malformed packet must not be delivered") }
            peer.onClose = { reason in XCTAssertEqual(reason, "Invalid packet size"); done.fulfill() }
            peer.start()
        }
        listener.stateUpdateHandler = { state in
            guard case .ready = state, let port = listener.port else { return }
            let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp); sender = connection
            connection.stateUpdateHandler = { state in
                if case .ready = state { connection.send(content: Data([255,255,255,255]), completion: .contentProcessed { _ in }) }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        wait(for: [done], timeout: 5)
        queue.sync { receiver?.close(); sender?.cancel(); listener.cancel() }
    }
}
