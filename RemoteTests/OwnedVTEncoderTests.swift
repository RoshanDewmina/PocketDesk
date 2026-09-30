import XCTest
import WebRTC
import CoreVideo

final class OwnedVTEncoderTests: XCTestCase {
    func testAnnexBRejectsTruncatedNALAndBoundsParameterSets() {
        XCTAssertEqual(H264AnnexB.convert(Data([0, 0, 0, 2, 0x65, 0x80]), lengthBytes: 4), Data([0, 0, 0, 1, 0x65, 0x80]))
        XCTAssertNil(H264AnnexB.convert(Data([0, 0, 0, 3, 0x65, 0x80]), lengthBytes: 4))
        XCTAssertNil(H264AnnexB.convert(Data([0, 0]), lengthBytes: 4))
        XCTAssertNil(H264AnnexB.convert(Data([0, 0, 0, 0]), lengthBytes: 4))
        XCTAssertNil(H264AnnexB.convert(Data([1, 0x65]), lengthBytes: 0))
        XCTAssertNil(H264AnnexB.convert(Data([1, 0x65]), lengthBytes: 1, parameterSets: [Data()]))
        XCTAssertEqual(H264AnnexB.convert(Data([1, 0x65]), lengthBytes: 1, parameterSets: [Data([0x67])]), Data([0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x65]))
    }
    func testLowLatencyIsBoundToNegotiatedHighProfileAndPacketization() {
        XCTAssertTrue(OwnedVTConfiguration(parameters: ["profile-level-id": "640c34", "packetization-mode": "1"])!.lowLatency)
        XCTAssertFalse(OwnedVTConfiguration(parameters: ["profile-level-id": "42e034", "packetization-mode": "1"])!.lowLatency)
        XCTAssertNil(OwnedVTConfiguration(parameters: ["profile-level-id": "640034", "packetization-mode": "0"]))
        XCTAssertNil(OwnedVTConfiguration(parameters: ["profile-level-id": "f40034", "packetization-mode": "1"]))
    }
    func testNegotiatedLevelCapsRateAndRejectsHigherOrDifferentSPS() throws {
        let config = try XCTUnwrap(OwnedVTConfiguration(parameters: ["profile-level-id": "64001f", "packetization-mode": "1"]))
        XCTAssertFalse(config.lowLatency)
        XCTAssertEqual(config.maximumKbps, 14_000)
        XCTAssertTrue(config.acceptsSPS(Data([0x67, 0x64, 0, 31])))
        XCTAssertFalse(config.acceptsSPS(Data([0x67, 0x64, 0, 32])))
        XCTAssertFalse(config.acceptsSPS(Data([0x67, 0x42, 0, 31])))
        XCTAssertFalse(config.acceptsSPS(Data([0x67, 0x64, 0])))
    }

    func testOutwardCallbackCanSynchronouslyInspectRateAndReleaseOwnedQueue() throws {
        let preferred = QueueOwnedFixtureEncoder()
        let counters = StreamCounters()
        let wrapper = ResilientVTEncoder(preferred: preferred, fallback: QueueOwnedFixtureEncoder(), counters: counters)
        let settings = RTCVideoEncoderSettings()
        settings.width = 16; settings.height = 16; settings.startBitrate = 100; settings.maxBitrate = 100
        settings.maxFramerate = 30; settings.name = "H264"
        let retired = expectation(description: "Callback retires encoder without queue inversion")
        wrapper.setCallback { _, _ in
            XCTAssertEqual(wrapper.implementationName(), "queue-owned fixture")
            XCTAssertEqual(wrapper.setBitrate(200, framerate: 30), 0)
            XCTAssertEqual(wrapper.release(), 0)
            retired.fulfill()
            return true
        }
        XCTAssertEqual(wrapper.startEncode(with: settings, numberOfCores: 1), 0)
        preferred.produce()
        wait(for: [retired], timeout: 2)
        XCTAssertEqual(counters.encodedTotal, 0, "Retired callback is not accepted into the new session")
        XCTAssertEqual(wrapper.release(), 0)
    }

    func testEvidenceRejectsImpossibleCompatibilityAndUnboundedQPClaims() throws {
        XCTAssertThrowsError(try VideoEncoderEvidence(path: .compatibility, maximumQPBound: 30, lowLatencyRequested: false, hardwareRequired: false, hardwareReported: nil).validate())
        XCTAssertThrowsError(try VideoEncoderEvidence(path: .ownedVideoToolbox, maximumQPBound: 52, lowLatencyRequested: true, hardwareRequired: true, hardwareReported: nil).validate())
        XCTAssertThrowsError(try VideoEncoderEvidence(path: .ownedVideoToolbox, maximumQPBound: 30, lowLatencyRequested: true, hardwareRequired: true, hardwareReported: false).validate())
        var summary = HostStreamSummary()
        summary.encoderEvidence = VideoEncoderEvidence(path: .ownedVideoToolbox, maximumQPBound: 30, lowLatencyRequested: true, hardwareRequired: true, hardwareReported: nil)
        XCTAssertEqual(try JSONDecoder().decode(HostStreamSummary.self, from: JSONEncoder().encode(summary)), summary)
    }

    func testOwnedHardwareEncoderProducesDecodableAnnexBWithOriginalTimestamp() throws {
        let configuration = try XCTUnwrap(OwnedVTConfiguration(parameters: ["profile-level-id": "640034", "packetization-mode": "1"]))
        let counters = StreamCounters()
        let encoder = OwnedVTEncoder(configuration: configuration, counters: counters)
        let decoder = RTCVideoDecoderH264()
        defer { _ = encoder.release(); _ = decoder.release() }
        let settings = RTCVideoEncoderSettings()
        settings.width = 256; settings.height = 128; settings.startBitrate = 8000
        settings.maxBitrate = 8000; settings.maxFramerate = 60; settings.qpMax = 30
        settings.name = "H264"; settings.mode = .screensharing
        let started = encoder.startEncode(with: settings, numberOfCores: 1)
        XCTAssertEqual(started, 0, "VT stage=\(encoder.lastStage) status=\(encoder.lastStatus)")
        guard started == 0 else { return }
        XCTAssertTrue(encoder.hardwareRequired)
        XCTAssertNotEqual(encoder.hardwareReported, false, "Optional hardware getter may be unsupported, but must never report software")
        XCTAssertTrue(encoder.lowLatencyApplied)
        let evidence = try XCTUnwrap(counters.drain(inputBufferedBytes: nil).encoderEvidence)
        XCTAssertEqual(evidence.path, .ownedVideoToolbox)
        XCTAssertEqual(evidence.maximumQPBound, encoder.maximumQPApplied ? 30 : nil)
        XCTAssertEqual(evidence.hardwareReported, encoder.hardwareReported)
        XCTAssertNoThrow(try evidence.validate())
        let encoded = expectation(description: "Public VT encoded frame")
        let decoded = expectation(description: "Public RTC decoded frame")
        decoder.setCallback { frame in
            XCTAssertEqual(frame.width, 256); XCTAssertEqual(frame.height, 128)
            XCTAssertEqual(UInt32(bitPattern: frame.timeStamp), 123456)
            decoded.fulfill()
        }
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 1), 0)
        encoder.setCallback { image, info in
            XCTAssertEqual(image.timeStamp, 123456); XCTAssertEqual(image.frameType, .videoFrameKey)
            XCTAssertGreaterThan(image.buffer.count, 16)
            XCTAssertEqual(Array(image.buffer.prefix(4)), [0, 0, 0, 1])
            XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: info, renderTimeMs: 0), 0)
            encoded.fulfill(); return true
        }
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 256, 128, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<128 { for x in 0..<256 {
            let i = y * stride + x * 4, value: UInt8 = (x / 4 + y / 4) % 2 == 0 ? 240 : 16
            base[i] = value; base[i + 1] = value; base[i + 2] = value; base[i + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: 1_000_000_000)
        frame.timeStamp = 123456
        XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]), 0)
        wait(for: [encoded, decoded], timeout: 5)
        _ = encoder.release()
        XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: []), -1)
    }
}

private final class QueueOwnedFixtureEncoder: NSObject, RTCVideoEncoder {
    private let queue = DispatchQueue(label: "farside.test.queue-owned-encoder")
    private var callback: RTCVideoEncoderCallback?
    func setCallback(_ callback: RTCVideoEncoderCallback?) { queue.sync { self.callback = callback } }
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int { queue.sync { 0 } }
    func release() -> Int { queue.sync { callback = nil; return 0 } }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 { queue.sync { 0 } }
    func implementationName() -> String { queue.sync { "queue-owned fixture" } }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }
    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { true }
    var supportsNativeHandle: Bool { true }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int { 0 }
    func produce() {
        queue.async { [self] in
            let image = RTCEncodedImage(); image.buffer = Data([0, 0, 0, 1, 0x65])
            _ = callback?(image, RTCCodecSpecificInfoH264())
        }
    }
}
