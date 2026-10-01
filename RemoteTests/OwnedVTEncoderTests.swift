import XCTest
import WebRTC
import CoreVideo
import VideoToolbox

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
        XCTAssertNil(OwnedVTConfiguration(parameters: ["profile-level-id": "42f00b", "packetization-mode": "1"]))
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

    func testBlockedEncodedDeliveryDropsDependentsUntilNewKeyFrame() {
        let delivery = VideoEncoderCallbackDelivery(), entered = DispatchSemaphore(value: 0), unblock = DispatchSemaphore(value: 0)
        let first = expectation(description: "Earlier key completes"), recovered = expectation(description: "Fresh recovery key delivered")
        let callbackLock = NSLock(); var timestamps: [UInt32] = []
        delivery.setCallback { image, _ in
            callbackLock.lock(); timestamps.append(image.timeStamp); callbackLock.unlock()
            if image.timeStamp == 1 { entered.signal(); _ = unblock.wait(timeout: .now() + 2); first.fulfill() }
            if image.timeStamp == 5 { recovered.fulfill() }
            return true
        }
        let epoch = delivery.activate()
        func offer(_ rtp: UInt32, _ type: RTCFrameType) {
            let image = RTCEncodedImage(); image.timeStamp = rtp; image.frameType = type
            delivery.enqueue(image, info: RTCCodecSpecificInfoH264(), epoch: epoch)
        }
        offer(1, .videoFrameKey)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        offer(2, .videoFrameDelta); offer(3, .videoFrameDelta)
        XCTAssertTrue(delivery.needsKeyFrame)
        unblock.signal(); wait(for: [first], timeout: 2)
        XCTAssertTrue(delivery.needsKeyFrame, "A key preceding the encoded loss cannot repair it")
        offer(4, .videoFrameDelta); offer(5, .videoFrameKey)
        wait(for: [recovered], timeout: 2)
        delivery.invalidate()
        callbackLock.lock(); let received = timestamps; callbackLock.unlock()
        XCTAssertEqual(received, [1, 5], "No dependent delta crosses an encoded reference gap")
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

    private func textClarityFrame(width: Int = 256, height: Int = 128, shade: UInt8) throws -> RTCVideoFrame {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)), Int32(shade), CVPixelBufferGetBytesPerRow(buffer) * height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1_000_000_000)
    }
    private func encodeAndWait(_ encoder: OwnedVTEncoder, _ frame: RTCVideoFrame, key: Bool = false) {
        let done = expectation(description: "Encoded")
        encoder.setCallback { _, _ in done.fulfill(); return true }
        XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: key ? [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)] : []), 0)
        wait(for: [done], timeout: 5)
    }
    private func clarityConfigurations() throws -> [(name: String, configuration: any OwnedVideoConfiguration, still: Int)] {
        [("H264", try XCTUnwrap(OwnedVTConfiguration(parameters: ["profile-level-id": "640034", "packetization-mode": "1"])), TextClarityPolicy.stillH264QP),
         ("H265", try XCTUnwrap(OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters)), TextClarityPolicy.stillHEVCQP)]
    }
    private func clarityEncoder(_ configuration: any OwnedVideoConfiguration, name: String, counters: StreamCounters, context: TextClarityContext?,
                                catalog: @escaping (VTCompressionSession) -> [String: Any]? = OwnedVTEncoder.supportedProperties) -> OwnedVTEncoder {
        let encoder = OwnedVTEncoder(configuration: configuration, counters: counters, textClarity: context, propertyCatalog: catalog)
        let settings = RTCVideoEncoderSettings()
        settings.width = 256; settings.height = 128; settings.startBitrate = 4000; settings.maxBitrate = 4000
        settings.maxFramerate = 60; settings.qpMax = 30; settings.name = name; settings.mode = .screensharing
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), 0, "\(name) VT stage=\(encoder.lastStage) status=\(encoder.lastStatus)")
        return encoder
    }

    func testStillFrameQPIsTighterThanTheSessionBoundAndNeverLooser() {
        XCTAssertEqual(TextClarityPolicy.stillFrameQP(hevc: true, sessionBound: 30), 24)
        XCTAssertEqual(TextClarityPolicy.stillFrameQP(hevc: false, sessionBound: 30), 26)
        XCTAssertEqual(TextClarityPolicy.stillFrameQP(hevc: false, sessionBound: 20), 20)
        XCTAssertFalse(TextClarityPolicy.supported(nil))
        XCTAssertFalse(TextClarityPolicy.supported([:]))
        XCTAssertTrue(TextClarityPolicy.supported([kVTCompressionPropertyKey_MaxAllowedFrameQP as String: [:]]))
        var now: TimeInterval = 100
        let context = TextClarityContext(enabled: true) { now }
        XCTAssertFalse(context.isStill, "No observed frame is not a still picture")
        context.contentChanged(); now += TextClarityContext.stillAfter - 0.01
        XCTAssertFalse(context.isStill)
        now += 0.02
        XCTAssertTrue(context.isStill)
        context.contentChanged()
        XCTAssertFalse(context.isStill)
        let off = TextClarityContext(enabled: false) { now }
        off.contentChanged(); now += 10
        XCTAssertFalse(off.isStill)
    }

    func testTextClarityTightensTheHardwareQPCeilingOnlyWhileStillAndRestoresItOnMotion() throws {
        for (name, configuration, still) in try clarityConfigurations() {
            var now: TimeInterval = 100
            let counters = StreamCounters(), context = TextClarityContext(enabled: true) { now }
            let encoder = clarityEncoder(configuration, name: name, counters: counters, context: context)
            defer { _ = encoder.release() }
            guard encoder.maximumQPApplied else {
                XCTAssertFalse(encoder.textClarityAvailable, "\(name): no QP setter, no floor")
                throw XCTSkip("\(name): this encoder does not accept MaxAllowedFrameQP")
            }
            XCTAssertTrue(encoder.textClarityAvailable, "\(name): the hardware encoder lists MaxAllowedFrameQP")
            XCTAssertEqual(counters.drain(inputBufferedBytes: nil).encoderEvidence?.textClarityActive, false)
            context.contentChanged()
            encodeAndWait(encoder, try textClarityFrame(shade: 40), key: true)
            XCTAssertFalse(encoder.textClarityActive, "\(name): a changing picture keeps the session bound")
            now += 1
            encodeAndWait(encoder, try textClarityFrame(shade: 40))
            XCTAssertTrue(encoder.textClarityActive, "\(name): still picture applies QP ≤ \(still)")
            let applied = try XCTUnwrap(counters.drain(inputBufferedBytes: nil).encoderEvidence)
            XCTAssertEqual(applied.textClarityActive, true); XCTAssertEqual(applied.maximumQPBound, 30)
            XCTAssertNoThrow(try applied.validate())
            context.contentChanged()
            encodeAndWait(encoder, try textClarityFrame(shade: 200))
            XCTAssertFalse(encoder.textClarityActive, "\(name): motion restores the session's own bound")
            XCTAssertEqual(counters.drain(inputBufferedBytes: nil).encoderEvidence?.textClarityActive, false)
        }
    }

    func testTextClarityIsAbsentUnlessRequestedAndSkippedWhenTheEncoderDoesNotListTheProperty() throws {
        for (name, configuration, _) in try clarityConfigurations() {
            var now: TimeInterval = 100
            for (context, catalog) in [(TextClarityContext?.none, OwnedVTEncoder.supportedProperties),
                                       (TextClarityContext(enabled: false) { now }, OwnedVTEncoder.supportedProperties),
                                       (TextClarityContext(enabled: true) { now }, { (_: VTCompressionSession) -> [String: Any]? in [:] })] {
                let counters = StreamCounters()
                let encoder = clarityEncoder(configuration, name: name, counters: counters, context: context, catalog: catalog)
                XCTAssertFalse(encoder.textClarityAvailable, name)
                context?.contentChanged(); now += 5
                encodeAndWait(encoder, try textClarityFrame(shade: 90), key: true)
                encodeAndWait(encoder, try textClarityFrame(shade: 90))
                XCTAssertFalse(encoder.textClarityActive, "\(name): the default session never changes its QP bound")
                let evidence = try XCTUnwrap(counters.drain(inputBufferedBytes: nil).encoderEvidence)
                XCTAssertNil(evidence.textClarityActive)
                XCTAssertFalse(evidence.summary.contains("text clarity"))
                _ = encoder.release()
            }
        }
    }

    func testTextClarityEvidenceIsOwnedEncoderOnlyAndReachesTheHostSummary() throws {
        XCTAssertThrowsError(try VideoEncoderEvidence(path: .compatibility, maximumQPBound: nil, lowLatencyRequested: false, hardwareRequired: false,
                                                      hardwareReported: nil, textClarityActive: false).validate())
        let sample = StreamStatsSample(entries: [])
        var snapshot = StreamCounterSnapshot(interval: 1)
        XCTAssertNil(StreamStatsReport(role: "host", previous: nil, current: sample, counters: snapshot).hostSummary.textClarityActive)
        snapshot.encoderEvidence = VideoEncoderEvidence(path: .ownedVideoToolbox, maximumQPBound: 30, lowLatencyRequested: true,
                                                        hardwareRequired: true, hardwareReported: nil, textClarityActive: true)
        let summary = StreamStatsReport(role: "host", previous: nil, current: sample, counters: snapshot).hostSummary
        XCTAssertEqual(summary.textClarityActive, true)
        let received = try JSONDecoder().decode(HostStreamSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(received, summary); XCTAssertNoThrow(try received.validate())
        XCTAssertTrue(try XCTUnwrap(summary.encoderEvidence).summary.hasSuffix("text clarity active"))
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
