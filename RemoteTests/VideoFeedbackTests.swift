import XCTest
import WebRTC
import CoreVideo

final class VideoFeedbackTests: XCTestCase {
    @MainActor
    func testActualNativeRTPAndControlReceiverAckWithTimingOffAndStaticPNGChannel() async throws {
        try await runNative(hevc: false)
        try await runNative(hevc: true)
    }
    @MainActor
    private func runNative(hevc: Bool) async throws {
        let previousLoopback = E2EMedia.loopbackOnly; E2EMedia.loopbackOnly = true
        let previousTiming = FrameTimingSwitch.override; FrameTimingSwitch.override = false
        let host = PeerMedia(isHost: true, servers: [], hevc: hevc, videoLTR: !hevc)
        let phone = PeerMedia(isHost: false, servers: [], hevc: hevc)
        FrameTimingSwitch.override = previousTiming
        defer { host.close(); phone.close(); E2EMedia.loopbackOnly = previousLoopback }
        XCTAssertNil(host.frameTimingLog)
        host.videoFeedback.configure(allowed: true, ltr: true, refinement: true, geometry: 7, scope: 3)
        phone.videoFeedback.configure(allowed: true, ltr: true, refinement: true, geometry: 7, scope: 3)
        host.configureVideoRefinement(enabled: true, geometry: 7, scope: 3)
        phone.configureVideoRefinement(enabled: true, geometry: 7, scope: 3)
        host.onSignal = { [weak phone] signal in phone?.receive(signal) }
        phone.onSignal = { [weak host] signal in host?.receive(signal) }
        phone.videoFeedback.setFeedback { [weak phone] feedback, epoch in
            guard let data = try? JSONEncoder().encode(RemoteAction(action: "heartbeat", epoch: epoch, videoFeedback: feedback)) else { return }
            _ = phone?.sendControl(data)
        }
        host.onControl = { [weak host] data in
            guard let action = try? JSONDecoder().decode(RemoteAction.self, from: data), (try? action.validate()) != nil,
                  let packet = action.videoFeedback else { return }
            host?.videoFeedback.receive(packet, epoch: action.epoch)
        }
        var connectedHost = false, connectedPhone = false, remote: RTCVideoTrack?
        var observedCodec: String?
        phone.onStreamStatistics = { observedCodec = $0.codec }
        host.onState = { if $0 == "connected" { connectedHost = true } }
        phone.onState = { if $0 == "connected" { connectedPhone = true } }
        phone.onRemoteVideo = { remote = $0 }
        host.offer()
        let connectionDeadline = ProcessInfo.processInfo.systemUptime + 10
        while !(connectedHost && connectedPhone && remote != nil), ProcessInfo.processInfo.systemUptime < connectionDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let track = try XCTUnwrap(remote)
        let renderer = FeedbackNativeRenderer(context: phone.videoFeedback)
        track.add(renderer); defer { track.remove(renderer) }
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 256, 128, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixel)
        CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pixels, []); memset(CVPixelBufferGetBaseAddress(pixels), 255, CVPixelBufferGetDataSize(pixels)); CVPixelBufferUnlockBaseAddress(pixels, [])
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while ProcessInfo.processInfo.systemUptime < deadline && !((hevc || host.videoFeedback.receiverAcknowledgements > 0) && renderer.refinedFrames > 0 && observedCodec?.lowercased().contains(hevc ? "h265" : "h264") == true) {
            let now = ProcessInfo.processInfo.systemUptime
            host.pushFrame(pixels, timeStampNs: Int64(now * 1_000_000_000))
            try await Task.sleep(for: .milliseconds(33))
        }
        XCTAssertGreaterThan(renderer.taggedFrames, 0, "SEI marker passed actual native RTP and successful output")
        if !hevc { XCTAssertGreaterThan(host.videoFeedback.receiverAcknowledgements, 0, "Real receiver ACK returned on native control, independent of frame timing") }
        else { XCTAssertEqual(host.videoFeedback.receiverAcknowledgements, 0, "HEVC has no unproven LTR capability") }
        XCTAssertTrue(observedCodec?.lowercased().contains(hevc ? "h265" : "h264") == true, "Actual RTP codec observed: \(observedCodec ?? "unknown")")
        XCTAssertGreaterThan(renderer.refinedFrames, 0, "Actual reliable channel PNG matches exact decoded base tag")
        phone.close()
        XCTAssertNil(phone.videoFeedback.encoded(token: 1))
    }

    func testPublicHardwareNativeDecodeAckReturnsExactVTAttachmentOnNextSubmission() throws {
        let sender = VideoFeedbackContext(), receiver = VideoFeedbackContext()
        sender.configure(allowed: true, geometry: 7, scope: 3); receiver.configure(allowed: true, geometry: 7, scope: 3)
        let config = try XCTUnwrap(OwnedVTConfiguration(parameters: ["profile-level-id": "640034", "packetization-mode": "1"]))
        let encoder = OwnedVTEncoder(configuration: config, videoFeedback: sender)
        let decoder = VideoFeedbackDecoder(inner: RTCVideoDecoderH264(), context: receiver)
        defer { _ = encoder.release(); _ = decoder.release() }
        let settings = RTCVideoEncoderSettings(); settings.width = 256; settings.height = 128
        settings.startBitrate = 8000; settings.maxBitrate = 8000; settings.maxFramerate = 60; settings.name = "H264"; settings.mode = .screensharing
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), 0)
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 1), 0)
        let output = expectation(description: "Actual successful native reference output"), acknowledged = expectation(description: "Actual receiver token ACK")
        let refreshed = expectation(description: "Actual LTR predictive refresh access unit")
        let lock = NSLock(); var emittedToken: Int64?, actualAck: Int64?
        receiver.setFeedback { packet, epoch in
            sender.receive(packet, epoch: epoch)
            lock.lock(); let first = actualAck == nil; actualAck = packet.token; lock.unlock()
            if first { acknowledged.fulfill() }
        }
        decoder.setCallback { frame in if UInt32(bitPattern: frame.timeStamp) == 42 { output.fulfill() } }
        encoder.setCallback { image, info in
            let tag = H26xVideoMarker.read(image.buffer)
            XCTAssertNotNil(tag)
            if image.timeStamp == 42 { lock.lock(); emittedToken = tag?.ltrToken; lock.unlock() }
            if image.timeStamp == 43 { XCTAssertEqual(image.frameType, .videoFrameDelta, "Receiver-proven LTR refresh may predict instead of unconditional IDR"); refreshed.fulfill() }
            XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: info, renderTimeMs: 0), 0)
            return true
        }
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 256, 128, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(pixels, []); memset(CVPixelBufferGetBaseAddress(pixels), 255, CVPixelBufferGetDataSize(pixels)); CVPixelBufferUnlockBaseAddress(pixels, [])
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: 1_000_000_000); frame.timeStamp = 42
        XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]), 0)
        wait(for: [output], timeout: 5)
        guard encoder.ltrEnabled else { throw XCTSkip("Public hardware LTR property is unsupported on this runtime; no LTR evidence claimed") }
        wait(for: [acknowledged], timeout: 5)
        lock.lock(); let token = emittedToken, ack = actualAck; lock.unlock()
        XCTAssertNotNil(token); XCTAssertEqual(token, ack)
        let next = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: 1_016_666_667); next.timeStamp = 43
        XCTAssertEqual(encoder.encode(next, codecSpecificInfo: nil, frameTypes: [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]), 0)
        XCTAssertEqual(encoder.submittedLTRTokens, token.map { [$0] } ?? [])
        XCTAssertTrue(encoder.submittedLTRRefresh)
        wait(for: [refreshed], timeout: 5)
    }

    func testNegotiatedFactoryPrefersSupportedHighOnlyAndKeepsHEVCAndOldCaptureCompatibility() throws {
        let modern = PocketDeskVideoEncoderFactory(hevc: false, preferLTR: true).supportedCodecs()
        if NativeCodecCapability.supportsLevel52 {
            XCTAssertTrue(OwnedVTConfiguration(parameters: try XCTUnwrap(modern.first).parameters)?.lowLatency == true)
        }
        XCTAssertEqual(PocketDeskVideoEncoderFactory(hevc: true, preferLTR: true).supportedCodecs().first?.name, "H265")
        let old = HostFeatureList.features(base: SessionFeature.host, allowBigText: false, accessibility: true, peerFeatures: [], requestedMode: .picture)
        XCTAssertEqual(old, SessionFeature.legacyHost); XCTAssertFalse(old.contains(SessionFeature.videoLTR)); XCTAssertFalse(old.contains(SessionFeature.videoRefinement))
        XCTAssertLessThanOrEqual(MacShareBlocker.Handshake.phone.features.count, 8)
    }
    func testAccessUnitMarkersSurviveEscapingAndRejectDuplicateOrTruncatedPayloads() throws {
        let context = VideoFeedbackContext(); context.configure(allowed: true, geometry: 7, scope: 3)
        let tag = try XCTUnwrap(context.encoded(token: 0))
        for hevc in [false, true] {
            let base = Data([0,0,0,1] + (hevc ? [0x26,1,0x80] : [0x65,0x80]))
            let marked = try XCTUnwrap(H26xVideoMarker.append(tag, to: base, hevc: hevc))
            XCTAssertEqual(H26xVideoMarker.read(marked, hevc: hevc), tag)
            XCTAssertNil(H26xVideoMarker.read(try XCTUnwrap(H26xVideoMarker.append(tag, to: marked, hevc: hevc)), hevc: hevc))
            XCTAssertNil(H26xVideoMarker.read(Data(marked.prefix(24)), hevc: hevc))
        }
    }
    func testSubmissionDoesNotAcknowledgeAndOnlySuccessfulExactNativeOutputCanAcknowledge() throws {
        let sender = VideoFeedbackContext(), receiver = VideoFeedbackContext()
        sender.configure(allowed: true, geometry: 7, scope: 3); receiver.configure(allowed: true, geometry: 7, scope: 3)
        let tag = try XCTUnwrap(sender.encoded(token: 912))
        receiver.setFeedback { packet, epoch in sender.receive(packet, epoch: epoch) }
        receiver.received(tag, wire: 42)
        XCTAssertTrue(sender.takeOptions().tokens.isEmpty)
        receiver.decoded(try frame(41))
        XCTAssertTrue(sender.takeOptions().tokens.isEmpty)
        let output = try frame(42); receiver.decoded(output)
        XCTAssertEqual(sender.takeOptions().tokens, [912])
        XCTAssertEqual(receiver.tag(for: output), tag)
        receiver.decoded(output); XCTAssertTrue(sender.takeOptions().tokens.isEmpty)
    }
    func testNativeFanoutWrapperRequiresExactWeakPixelsAndPublicTimestamp() throws {
        let context = VideoFeedbackContext(); context.configure(allowed: true, geometry: 7, scope: 3)
        let tag = try XCTUnwrap(context.encoded(token: nil)), original = try frame(42)
        context.received(tag, wire: 42); context.decoded(original)
        let wrapper = RTCVideoFrame(buffer: original.buffer, rotation: original.rotation, timeStampNs: original.timeStampNs)
        wrapper.timeStamp = 42
        XCTAssertEqual(context.tag(for: wrapper), tag, "Native wrapper recreation preserves exact pixels and timestamp")
        let reusedPixels = RTCVideoFrame(buffer: original.buffer, rotation: original.rotation, timeStampNs: original.timeStampNs + 1000)
        reusedPixels.timeStamp = 42
        XCTAssertNil(context.tag(for: reusedPixels), "A timestamp from another decoded envelope cannot inherit a tag")
        XCTAssertNil(context.tag(for: try frame(42)), "Equal timestamp/geometry with another pixel buffer cannot inherit a tag")
        context.configure(allowed: false, geometry: 7, scope: 3)
        XCTAssertNil(context.tag(for: wrapper))
    }
    func testRepeatedWireTimestampAndRejectedSubmissionNeverProveReference() throws {
        let receiver = VideoFeedbackContext(); receiver.configure(allowed: true, geometry: 7, scope: 3)
        let tag = try XCTUnwrap(receiver.encoded(token: 1))
        receiver.setFeedback { _,_ in XCTFail("Ambiguous/rejected output cannot ACK") }
        receiver.received(tag, wire: 42); receiver.received(tag, wire: 42); receiver.received(tag, wire: 42)
        receiver.decoded(try frame(42))
        receiver.received(tag, wire: 43); receiver.rejected(wire: 43); receiver.decoded(try frame(43))
    }
    func testProductionDecoderUnmarkedMalformedAndStaleDuplicateCannotInheritPendingReference() throws {
        let base = Data([0, 0, 0, 1, 0x65, 0x80])
        for replacement in 0..<3 {
            let context = VideoFeedbackContext(); context.configure(allowed: true, geometry: 7, scope: 3)
            let inner = ControlledFeedbackDecoder(), decoder = VideoFeedbackDecoder(inner: inner, context: context)
            XCTAssertEqual(decoder.startDecode(withNumberOfCores: 1), 0)
            defer { _ = decoder.release() }
            let tag = try XCTUnwrap(context.encoded(token: 912)), marked = try XCTUnwrap(H26xVideoMarker.append(tag, to: base))
            let duplicate: Data
            if replacement == 0 { duplicate = base }
            else if replacement == 1 { duplicate = Data(marked.prefix(24)) + base }
            else {
                duplicate = try XCTUnwrap(H26xVideoMarker.append(VideoFrameTag(generation: tag.generation, nonce: tag.nonce,
                    geometryEpoch: 8, scopeEpoch: 3, ltrToken: 912), to: base))
            }
            var acknowledgements = 0, outputs = 0
            context.setFeedback { _, _ in acknowledgements += 1 }
            decoder.setCallback { _ in outputs += 1 }
            let first = RTCEncodedImage(); first.buffer = marked; first.timeStamp = 42
            let second = RTCEncodedImage(); second.buffer = duplicate; second.timeStamp = 42
            XCTAssertEqual(decoder.decode(first, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), 0)
            XCTAssertEqual(decoder.decode(second, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), 0)
            XCTAssertEqual(inner.submissions, [42, 42])
            let nativeOutput = try frame(42); inner.emit(nativeOutput)
            XCTAssertEqual(outputs, 1, "Production wrapper forwards the controlled successful native output")
            XCTAssertEqual(acknowledgements, 0, "Duplicate AU cannot acknowledge a preceding token")
            XCTAssertNil(context.tag(for: nativeOutput), "Duplicate output cannot inherit the preceding refinement tag")
            let independent = RTCEncodedImage(); independent.buffer = marked; independent.timeStamp = 43
            XCTAssertEqual(decoder.decode(independent, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), 0)
            let independentOutput = try frame(43); inner.emit(independentOutput)
            XCTAssertEqual(acknowledgements, 1, "An unrelated current wire still completes normally")
            XCTAssertEqual(context.tag(for: independentOutput), tag)
        }
    }
    func testRevokeEpochDecoderRestartAndForgedAckCannotReuseTokens() throws {
        let context = VideoFeedbackContext(); context.configure(allowed: true, geometry: 7, scope: 3)
        let tag = try XCTUnwrap(context.encoded(token: 2))
        let ack = VideoFeedback(operation: .ltrAck, generation: tag.generation, nonce: tag.nonce, token: 3, scopeEpoch: 3)
        context.receive(ack, epoch: 7); XCTAssertTrue(context.takeOptions().tokens.isEmpty)
        context.received(tag, wire: 42); context.beginDecoder(); context.decoded(try frame(42)); XCTAssertNil(context.tag(for: try frame(42)))
        context.configure(allowed: true, geometry: 8, scope: 3)
        context.receive(VideoFeedback(operation: .ltrAck, generation: tag.generation, nonce: tag.nonce, token: 2, scopeEpoch: 3), epoch: 8)
        XCTAssertTrue(context.takeOptions().tokens.isEmpty)
        context.end(); context.configure(allowed: true, geometry: 8, scope: 3); XCTAssertNil(context.encoded(token: 2))
    }
    func testHeartbeatOnlyAndNarrowScopeVideoFeedbackDoesNotGrantInput() throws {
        let packet = VideoFeedback(operation: .ltrAck, generation: VideoFeedbackContext.id(), nonce: VideoFeedbackContext.id(), token: 0, scopeEpoch: 1)
        XCTAssertNoThrow(try RemoteAction(action: "heartbeat", epoch: 1, videoFeedback: packet).validate())
        XCTAssertThrowsError(try RemoteAction(action: "click", epoch: 1, videoFeedback: packet).validate())
        let capabilities = SharedCaptureScopePolicy.features(SessionFeature.host, kind: .window)
        XCTAssertTrue(capabilities.contains(SessionFeature.videoLTR)); XCTAssertFalse(capabilities.contains(SessionFeature.pencilInput))
    }
    private func frame(_ timestamp: UInt32) throws -> RTCVideoFrame {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let result = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixel)), rotation: ._0, timeStampNs: 1_000_000)
        result.timeStamp = Int32(bitPattern: timestamp); return result
    }
}

/// Holds submissions until the test emits the second input's successful callback.
/// This exercises the real production wrapper; it does not simulate hardware-decoder evidence.
private final class ControlledFeedbackDecoder: NSObject, RTCVideoDecoder {
    private var callback: RTCVideoDecoderCallback?
    private(set) var submissions: [UInt32] = []
    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) { self.callback = callback }
    func startDecode(withNumberOfCores cores: Int32) -> Int { 0 }
    func release() -> Int { callback = nil; return 0 }
    func decode(_ image: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        submissions.append(image.timeStamp); return 0
    }
    func emit(_ frame: RTCVideoFrame) { callback?(frame) }
    func implementationName() -> String { "ControlledFeedbackDecoder" }
}

private final class FeedbackNativeRenderer: NSObject, RTCVideoRenderer {
    private let context: VideoFeedbackContext
    private let lock = NSLock()
    private var tagged = 0, refined = 0
    var taggedFrames: Int { lock.lock(); defer { lock.unlock() }; return tagged }
    var refinedFrames: Int { lock.lock(); defer { lock.unlock() }; return refined }
    init(context: VideoFeedbackContext) { self.context = context; super.init() }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let tag = context.tag(for: frame) else { return }
        let pixels = context.refinement(for: tag, at: ProcessInfo.processInfo.systemUptime)
        lock.lock(); tagged += 1; if pixels != nil { refined += 1 }; lock.unlock()
    }
}
