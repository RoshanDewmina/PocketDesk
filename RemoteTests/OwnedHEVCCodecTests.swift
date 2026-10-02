import XCTest
import WebRTC
import CoreVideo
import VideoToolbox

final class OwnedHEVCCodecTests: XCTestCase {
    @MainActor
    func testActualProfile4RTPDecoded444AndMain1H264LegacyFallback() async throws {
        for receiver in ["444", "Main1", "H264"] {
            let host = PeerMedia(isHost: true, servers: [], hevc: true, hevc444: true)
            let phone = PeerMedia(isHost: false, servers: [], hevc: receiver != "H264", hevc444: receiver == "444")
            defer { host.close(); phone.close() }
            var answer = "", track: RTCVideoTrack?, connected = false
            host.onSignal = { [weak phone] signal in phone?.receive(signal) }
            phone.onSignal = { [weak host] signal in if signal.kind == "answer" { answer = signal.sdp ?? "" }; host?.receive(signal) }
            phone.onRemoteVideo = { track = $0 }
            host.onState = { if $0 == "connected" { connected = true } }
            host.offer()
            let deadline = Date().addingTimeInterval(10)
            while (!connected || track == nil || answer.isEmpty) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(connected)
            let remote = try XCTUnwrap(track)
            let video = try XCTUnwrap(answer.components(separatedBy: .newlines).first { $0.hasPrefix("m=video ") })
            let payload = try XCTUnwrap(video.split(separator: " ").dropFirst(3).first)
            let codec = try XCTUnwrap(answer.components(separatedBy: .newlines).first { $0.hasPrefix("a=rtpmap:\(payload) ") })
            if receiver == "H264" { XCTAssertTrue(codec.lowercased().contains("h264/90000")) }
            else {
                XCTAssertTrue(codec.lowercased().contains("h265/90000"))
                let fmtp = try XCTUnwrap(answer.components(separatedBy: .newlines).first { $0.hasPrefix("a=fmtp:\(payload) ") })
                XCTAssertTrue(fmtp.contains("profile-id=\(receiver == "444" ? 4 : 1)"), fmtp)
            }
            let sink = HEVC444NativeSink(); remote.add(sink)
            defer { remote.remove(sink) }
            let pixels = try fullColorBGRA()
            for _ in 0..<150 {
                host.pushFrame(pixels, timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1e9))
                try await Task.sleep(for: .milliseconds(20))
                if sink.snapshot.count >= 2 { break }
            }
            let snapshot = sink.snapshot
            XCTAssertGreaterThanOrEqual(snapshot.count, 2, "Genuine native RTP decoding, no toI420 probe conversion")
            XCTAssertEqual(snapshot.fullColor, receiver == "444", "Only mutually negotiated profile4 produces actual full-size chroma")
            if receiver == "444" { XCTAssertTrue(snapshot.declared709, "Actual owned renderer needs explicit decoded primaries/transfer/matrix, not guessed color") }
            print("CHROMA RTP receiver=\(receiver) payload=\(payload) decoded=\(snapshot.count) actual444=\(snapshot.fullColor) declared709=\(snapshot.declared709)")
        }
    }
    func testMain444PublicHardwareProbeAndFactoryFallbackAreHonest() {
        XCTAssertTrue(NativeHEVC444Capability.encodeFixture())
        XCTAssertTrue(NativeHEVC444Capability.decodeFixture())
        let unsupported = PocketDeskVideoEncoderFactory(hevc: true, hevc444: false)
        XCTAssertFalse(unsupported.supportedCodecs().contains { $0.parameters["profile-id"] == "4" })
        XCTAssertNil(unsupported.createEncoder(OwnedHEVCConfiguration.fullColorCodecInfo))
        XCTAssertNotNil(unsupported.createEncoder(OwnedHEVCConfiguration.codecInfo))
        let legacy = PocketDeskVideoDecoderFactory(hevc: false, hevc444: false)
        XCTAssertNil(legacy.createDecoder(OwnedHEVCConfiguration.fullColorCodecInfo))
        XCTAssertTrue(legacy.supportedCodecs().contains { $0.name == kRTCVideoCodecH264Name })
    }
    func testAdmittedColoredBGRAPublicTransferRetainsNeighborChromaAndRefuses420Upsampling() throws {
        let source = try fullColorBGRA()
        let converted = try XCTUnwrap(HEVC444PixelTransfer.fullColor(source))
        XCTAssertTrue(HEVC444PixelTransfer.isFullColor(converted))
        XCTAssertEqual(CVBufferCopyAttachment(converted, kCVImageBufferYCbCrMatrixKey, nil) as? String, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(converted, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(converted, .readOnly) }
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(converted, 1)).assumingMemoryBound(to: UInt8.self)
        // Alternating saturated red/blue input at adjacent pixels must not collapse into 4:2:0's shared chroma.
        XCTAssertGreaterThan(abs(Int(chroma[0]) - Int(chroma[2])) + abs(Int(chroma[1]) - Int(chroma[3])), 80)
        var subsampled: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &subsampled), kCVReturnSuccess)
        XCTAssertNil(HEVC444PixelTransfer.fullColor(try XCTUnwrap(subsampled)))
        CVBufferRemoveAttachment(source, kCVImageBufferColorPrimariesKey)
        XCTAssertNil(HEVC444PixelTransfer.fullColor(source), "Missing color may not be guessed")
    }
    private func fullColorBGRA() throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<64 { for x in 0..<64 {
            let at = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            base[at] = x % 2 == 0 ? 0 : 255; base[at + 1] = 0; base[at + 2] = x % 2 == 0 ? 255 : 0; base[at + 3] = 255
        } }
        return buffer
    }

    func testActualDecoderSubmissionRecoverableBadDataAndTerminalFailureLifecycle() {
        let failed = expectation(description: "Terminal synchronous decode requests rollback exactly once")
        failed.assertForOverFulfill = true
        let decoder = OwnedHEVCDecoder(onFailure: { failed.fulfill() })
        defer { _ = decoder.release() }
        decoder.setCallback { _ in XCTFail("Injected submission may not publish pixels") }
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 1), 0)
        let image = RTCEncodedImage(); image.buffer = NativeHEVCCapability.fixture; image.captureTimeMs = 1000; image.timeStamp = 90000
        decoder.submissionStatusForTesting = kVTVideoDecoderBadDataErr
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        decoder.submissionStatusForTesting = kVTInvalidSessionErr
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        decoder.submissionStatusForTesting = nil
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1, "Terminal decoder may not silently reopen")
        wait(for: [failed], timeout: 2)
    }
    func testAnAsynchronousBadDataErrorRequestsAKeyFrameOnTheNextDecodeAtMostEveryHalfSecond() {
        var now = 10_000.0
        let decoder = OwnedHEVCDecoder(onFailure: { XCTFail("bad data is not terminal") }, recovery: true, clock: { now })
        defer { _ = decoder.release() }
        // The delivery mailbox keeps only the newest decoded frame, so two quick decodes may publish once.
        let decoded = expectation(description: "the frames after the request decode normally")
        decoded.assertForOverFulfill = false
        decoder.setCallback { _ in decoded.fulfill() }
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 1), 0)
        let image = RTCEncodedImage(); image.buffer = NativeHEVCCapability.fixture; image.captureTimeMs = 1000; image.timeStamp = 90000
        decoder.submissionStatusForTesting = kVTVideoDecoderBadDataErr
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        decoder.submissionStatusForTesting = nil
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0),
                       OwnedHEVCDecoder.requestKeyFrameResult, "the frame after the error asks for a key frame")
        now += 100
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), 0, "then decoding resumes")
        decoder.submissionStatusForTesting = kVTVideoDecoderReferenceMissingErr
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        decoder.submissionStatusForTesting = nil
        now += 100
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), 0,
                       "a second error within 500 ms of the last request does not ask again yet")
        now += 400
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0),
                       OwnedHEVCDecoder.requestKeyFrameResult, "it asks once the half second has passed")
        wait(for: [decoded], timeout: 5)

        let stock = OwnedHEVCDecoder(onFailure: { XCTFail("bad data is not terminal") }, recovery: false, clock: { now })
        defer { _ = stock.release() }
        let passive = expectation(description: "with the switch off the next frame just decodes")
        stock.setCallback { _ in passive.fulfill() }
        XCTAssertEqual(stock.startDecode(withNumberOfCores: 1), 0)
        stock.submissionStatusForTesting = kVTVideoDecoderBadDataErr
        XCTAssertEqual(stock.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
        stock.submissionStatusForTesting = nil
        XCTAssertEqual(stock.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), 0)
        wait(for: [passive], timeout: 5)
    }

    func testFatalStartRequestsRenegotiationOnceAndNeverReturnsH264UnderHEVC() throws {
        let failed = expectation(description: "Owner notified for next-session H264 rollback")
        failed.assertForOverFulfill = true
        let config = try XCTUnwrap(OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters))
        let encoder = ResilientVTEncoder(configuration: config, counters: nil, frameTiming: nil, onFailure: { failed.fulfill() })
        defer { _ = encoder.release() }
        let settings = RTCVideoEncoderSettings(); settings.name = "H265"; settings.width = 4098; settings.height = 2160
        settings.maxFramerate = 60; settings.startBitrate = 4000; settings.maxBitrate = 4000; settings.mode = .screensharing
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), -1)
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), -1)
        wait(for: [failed], timeout: 2)
    }
    func testNegotiatedHEVCLumaBudgetFitsActualSenderEnvelopeAt120() throws {
        let sdp = "m=video 9 UDP/TLS/RTP/SAVPF 98\r\na=rtpmap:98 H265/90000\r\na=fmtp:98 profile-id=1;tier-flag=1;level-id=153;tx-mode=SRST\r\n"
        let budget = try XCTUnwrap(H264FrameBudget.receivingLimit(sdp: sdp))
        let dimensions = budget.fitted(width: 3840, height: 2160, fps: 120)
        let config = try XCTUnwrap(OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters))
        XCTAssertTrue(config.fits(width: dimensions.width, height: dimensions.height, fps: 120))
        XCTAssertLessThan(dimensions.width, 3840)
        let wide = budget.fitted(width: 8000, height: 1000, fps: 60)
        XCTAssertLessThanOrEqual(wide.width, 4096)
        XCTAssertTrue(config.fits(width: wide.width, height: wide.height, fps: 60))
    }
    func testBaked4KFixtureActuallyHardwareDecodesAndHostProbeEncodes() {
        XCTAssertTrue(NativeHEVCCapability.decodeFixture())
        XCTAssertTrue(NativeHEVCCapability.encodeFixture())
    }
    func testNegotiationRejectsUnsupportedProfilesAndBudgets() throws {
        let config = try XCTUnwrap(OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters))
        XCTAssertTrue(config.fits(width: 3840, height: 2160, fps: 60))
        XCTAssertFalse(config.fits(width: 3840, height: 2160, fps: 120))
        XCTAssertTrue(config.fits(width: 1920, height: 1080, fps: 120))
        for (key, value) in [("profile-id", "2"), ("tier-flag", "2"), ("tx-mode", "MRST"), ("level-id", "156")] {
            var params = OwnedHEVCConfiguration.codecInfo.parameters; params[key] = value
            XCTAssertNil(OwnedHEVCConfiguration(parameters: params))
        }
        XCTAssertNil(H26xAnnexB.split(Data([1,2,3])))
        XCTAssertNil(H26xAnnexB.split(Data([0,0,0,1])))
        XCTAssertFalse(config.acceptsSPS(Data([0x42,1,0])))
    }
    func testPublicHardwareHEVCEncodeDecodePreservesTimestampAndCanRetireInCallback() throws {
        let config = try XCTUnwrap(OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters))
        let encoder = ResilientVTEncoder(configuration: config, counters: nil, frameTiming: nil)
        let decoder = OwnedHEVCDecoder(configuration: config)
        defer { _ = encoder.release(); _ = decoder.release() }
        let settings = RTCVideoEncoderSettings()
        settings.name = "H265"; settings.width = 256; settings.height = 128
        settings.startBitrate = 4000; settings.maxBitrate = 4000; settings.maxFramerate = 60
        settings.mode = .screensharing; settings.qpMax = 30
        let encoded = expectation(description: "HEVC encoded"), decoded = expectation(description: "HEVC decoded")
        decoder.setCallback { frame in
            XCTAssertEqual(frame.width, 256); XCTAssertEqual(frame.height, 128)
            XCTAssertEqual(UInt32(bitPattern: frame.timeStamp), 123456)
            XCTAssertEqual(decoder.release(), 0, "No decode queue inversion")
            decoded.fulfill()
        }
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 1), 0)
        encoder.setCallback { image, info in
            XCTAssertEqual(image.timeStamp, 123456)
            let units = H26xAnnexB.split(image.buffer) ?? []
            XCTAssertTrue(units.contains { ($0[0] >> 1) & 63 == 32 })
            XCTAssertTrue(units.contains { ($0[0] >> 1) & 63 == 33 })
            XCTAssertTrue(units.contains { ($0[0] >> 1) & 63 == 34 })
            XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: info, renderTimeMs: 0), 0)
            encoded.fulfill(); return true
        }
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), 0)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try Self.frame()), rotation: ._0, timeStampNs: 1_000_000_000)
        frame.timeStamp = 123456
        XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]), 0)
        wait(for: [encoded, decoded], timeout: 5)
        XCTAssertEqual(decoder.decode(RTCEncodedImage(), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), -1)
    }
    func testOneHardware4KFrameForCapabilityFixture() throws {
        let config = try XCTUnwrap(OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters))
        let encoder = OwnedVTEncoder(configuration: config, counters: nil, frameTiming: nil)
        let decoder = OwnedHEVCDecoder(configuration: config)
        defer { _ = encoder.release(); _ = decoder.release() }
        let settings = RTCVideoEncoderSettings()
        settings.name = "H265"; settings.width = 3840; settings.height = 2160
        settings.startBitrate = 12000; settings.maxBitrate = 12000; settings.maxFramerate = 60
        settings.mode = .screensharing; settings.qpMax = 30
        let decoded = expectation(description: "One 4K hardware decode")
        decoder.setCallback { frame in
            XCTAssertEqual(frame.width, 3840); XCTAssertEqual(frame.height, 2160)
            decoded.fulfill()
        }
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 1), 0)
        encoder.setCallback { image, info in
            // Synthetic, one-frame fixture, never sustained cadence/performance evidence.
            XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: info, renderTimeMs: 0), 0)
            return true
        }
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), 0)
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 { memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? 16 : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1000000000)
        frame.timeStamp = 99000
        XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]), 0)
        wait(for: [decoded], timeout: 5)
        XCTAssertEqual(encoder.lastStatus, 0, "Stage=\(encoder.lastStage)")
    }
    @MainActor
    func testRealHEVCRTPTransportAndLegacyH264Fallback() async throws {
        try await loopback(receiverHEVC: true)
        try await loopback(receiverHEVC: false)
    }
    @MainActor
    private func loopback(receiverHEVC: Bool) async throws {
        let host = PeerMedia(isHost: true, servers: [], hevc: true)
        let phone = PeerMedia(isHost: false, servers: [], hevc: receiverHEVC)
        defer { host.close(); phone.close() }
        var offer = "", answer = "", actualCodec: String?
        phone.onStreamStatistics = { actualCodec = $0.codec }
        host.onSignal = { [weak phone] value in if value.kind == "offer" { offer = value.sdp ?? "" }; phone?.receive(value) }
        phone.onSignal = { [weak host] value in if value.kind == "answer" { answer = value.sdp ?? "" }; host?.receive(value) }
        var remote: RTCVideoTrack?
        phone.onRemoteVideo = { remote = $0 }
        host.offer()
        let deadline = Date().addingTimeInterval(15)
        while remote == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let track = try XCTUnwrap(remote)
        let sink = HEVCRenderSink(); track.add(sink); defer { track.remove(sink) }
        let pixels = try (0..<24).map { try Self.frame(index: $0) }
        for index in 0..<250 {
            host.pushFrame(pixels[index % pixels.count], timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1e9), displayMs: MachClock.nowMs())
            try await Task.sleep(nanoseconds: 20_000_000)
            if sink.count >= 10 && actualCodec != nil { break }
        }
        XCTAssertTrue(offer.contains("H265/90000"))
        XCTAssertEqual(answer.contains("H265/90000"), receiverHEVC)
        XCTAssertEqual(actualCodec?.lowercased(), receiverHEVC ? "video/h265" : "video/h264", "Transport codec must match actual decoded media, not just SDP")
        XCTAssertGreaterThanOrEqual(sink.count, 10, "Decoded actual RTP pictures; SDP alone is insufficient")
    }
    private static func frame(index: Int = 0) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 256, 128, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let pixels = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<128 { for x in 0..<256 {
            let at = y * stride + x * 4
            let value: UInt8 = ((x + index * 11) / 8 + y / 8) % 2 == 0 ? 224 : 32
            base[at] = value; base[at + 1] = value; base[at + 2] = value; base[at + 3] = 255
        } }
        return pixels
    }
}
private final class HEVCRenderSink: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock(); private var rendered = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return rendered }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) { guard frame != nil else { return }; lock.lock(); rendered += 1; lock.unlock() }
}

private final class HEVC444NativeSink: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var count = 0, fullColor = false, declared709 = false
    var snapshot: (count: Int, fullColor: Bool, declared709: Bool) { lock.lock(); defer { lock.unlock() }; return (count, fullColor, declared709) }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let pixels = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { return }
        lock.lock(); count += 1; fullColor = HEVC444PixelTransfer.isFullColor(pixels)
        declared709 = CVBufferCopyAttachment(pixels, kCVImageBufferColorPrimariesKey, nil) as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String &&
            CVBufferCopyAttachment(pixels, kCVImageBufferTransferFunctionKey, nil) as? String == kCVImageBufferTransferFunction_ITU_R_709_2 as String &&
            CVBufferCopyAttachment(pixels, kCVImageBufferYCbCrMatrixKey, nil) as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        lock.unlock()
    }
}
