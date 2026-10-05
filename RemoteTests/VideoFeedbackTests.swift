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
    func testActualNativeRTPH264AndHEVCExactTimingArrivesWithoutPixelBenchMarker() async throws {
        try await runNative(hevc: false, exactTiming: true)
        try await runNative(hevc: true, exactTiming: true)
    }
    #if DEBUG && AUDIO_LIFETIME_TESTS
    @MainActor
    func testActualNativeRefinementSendUnderFinalRouteFenceAndPausedCallbackCut() async throws {
        try await runNative(hevc: false, fencedRoute: true)
    }
    #endif
    @MainActor
    private func runNative(hevc: Bool, fencedRoute: Bool = false, exactTiming: Bool = false) async throws {
        // Match Connect's real readiness step before freezing the factories' capabilities.
        // A cold conservative H.264 snapshot cannot negotiate the High 5.2 path that enables LTR.
        let hostCapabilities = NativeVideoCapabilitySnapshot.enabled
            ? await NativeVideoCapabilitySnapshot.ready(isHost: true) : nil
        let phoneCapabilities = NativeVideoCapabilitySnapshot.enabled
            ? await NativeVideoCapabilitySnapshot.ready(isHost: false) : nil
        let previousLoopback = E2EMedia.loopbackOnly; E2EMedia.loopbackOnly = true
        let previousTiming = FrameTimingSwitch.override; FrameTimingSwitch.override = false
        let host = PeerMedia(isHost: true, servers: [], fileChannel: true, hevc: hevc, videoLTR: !hevc,
                             capabilitySnapshot: hostCapabilities)
        let phone = PeerMedia(isHost: false, servers: [], fileChannel: true, hevc: hevc,
                              capabilitySnapshot: phoneCapabilities)
        FrameTimingSwitch.override = previousTiming
        defer { host.close(); phone.close(); E2EMedia.loopbackOnly = previousLoopback }
        #if DEBUG && AUDIO_LIFETIME_TESTS
        if fencedRoute { host.forceNativeRouteAuthorityForTesting() }
        #endif
        XCTAssertNil(host.frameTimingLog)
        host.videoFeedback.configure(allowed: true, ltr: true, refinement: true, timing: exactTiming, geometry: 7, scope: 3)
        phone.videoFeedback.configure(allowed: true, ltr: true, refinement: true, timing: exactTiming, geometry: 7, scope: 3)
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
            let ms = MachClock.nowMs()
            let timing = exactTiming ? ExactVideoTiming(sourceID: String(repeating: "e", count: 32),
                displayMs: ms - 2, capturedMs: ms - 1, pushedMs: ms, submittedMs: ms, encodedMs: ms, resend: true) : nil
            host.pushFrame(pixels, timeStampNs: Int64(now * 1_000_000_000), exactTiming: timing)
            try await Task.sleep(for: .milliseconds(33))
        }
        XCTAssertGreaterThan(renderer.taggedFrames, 0, "SEI marker passed actual native RTP and successful output")
        if exactTiming {
            let timing = try XCTUnwrap(phone.videoFeedback.drainTiming())
            XCTAssertGreaterThan(renderer.exactTaggedFrames, 0, "Exact successful native AU output survives RTP timestamp rewriting")
            XCTAssertEqual(timing.presented, 0, "Native decode never invents a public drawable presentation")
        }
        if !hevc { XCTAssertGreaterThan(host.videoFeedback.receiverAcknowledgements, 0, "Real receiver ACK returned on native control, independent of frame timing") }
        else { XCTAssertEqual(host.videoFeedback.receiverAcknowledgements, 0, "HEVC has no unproven LTR capability") }
        XCTAssertTrue(observedCodec?.lowercased().contains(hevc ? "h265" : "h264") == true, "Actual RTP codec observed: \(observedCodec ?? "unknown")")
        XCTAssertGreaterThan(renderer.refinedFrames, 0, "Actual reliable channel PNG matches exact decoded base tag")
        #if DEBUG && AUDIO_LIFETIME_TESTS
        if fencedRoute {
            let paused = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
            let result = RefinementRouteResult()
            host.installRefinementSubmissionHooksForTesting(before: {
                if result.claimPause() { paused.signal(); _ = resume.wait(timeout: .now() + 4) }
            }, submitted: { result.recordEffect() })
            let pauseDeadline = ProcessInfo.processInfo.systemUptime + 3
            var reached = false
            while !reached, ProcessInfo.processInfo.systemUptime < pauseDeadline {
                host.pushFrame(pixels, timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
                reached = paused.wait(timeout: .now()) == .success
                if !reached { try await Task.sleep(for: .milliseconds(20)) }
            }
            XCTAssertTrue(reached, "Actual native refinement send paused immediately before the final production route fence")
            DispatchQueue(label: "refinement-test.ice-callback").sync { host.cutRefinementPathForTesting() }
            resume.signal()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(result.effects, 0, "No actual native send starts after path retirement returns")
            return
        }
        #endif
        var fileMessages: [Data] = []
        phone.onFileMessage = { data in DispatchQueue.main.async { fileMessages.append(data) } }
        host.closeRefinementChannelForTesting()
        let fileDeadline = ProcessInfo.processInfo.systemUptime + 3
        let filePayload = Data("governed-file-after-refinement-close".utf8)
        var fileSent = false
        while fileMessages.isEmpty, ProcessInfo.processInfo.systemUptime < fileDeadline {
            if host.refinementChannelRetiredForTesting, !fileSent,
               host.permitsFileSend(bytes: filePayload.count, at: ProcessInfo.processInfo.systemUptime) {
                fileSent = host.sendFile(filePayload)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(host.refinementChannelRetiredForTesting, "Closed optional native lane detached only after owner retirement")
        XCTAssertTrue(fileSent); XCTAssertEqual(fileMessages, [filePayload], "Actual governed file channel survives optional refinement failure")
        host.configureVideoRefinement(enabled: true, geometry: 7, scope: 3)
        XCTAssertTrue(host.refinementChannelRetiredForTesting, "Failure never silently reopens the optional lane")
        phone.close()
        XCTAssertNil(phone.videoFeedback.encoded(token: 1))
    }

    func testPublicHardwareNativeDecodeAckReturnsExactVTAttachmentOnNextSubmission() throws {
        let sender = VideoFeedbackContext(), receiver = VideoFeedbackContext()
        sender.configure(allowed: true, timing: true, geometry: 7, scope: 3); receiver.configure(allowed: true, timing: true, geometry: 7, scope: 3)
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
            if image.timeStamp == 42 {
                let timing = try? XCTUnwrap(tag?.timing)
                XCTAssertNotNil(timing, "Actual VT output carries the borrowed source's stages")
                XCTAssertEqual(timing?.sourceID, String(repeating: "f", count: 32))
                if let timing {
                    do { try timing.validate() } catch { XCTFail("Invalid actual VT stage metadata: \(error)") }
                    XCTAssertGreaterThanOrEqual(timing.submittedMs, Double(image.encodeStartMs))
                    XCTAssertLessThanOrEqual(timing.encodedMs, Double(image.encodeFinishMs) + 1, "VT callback entry precedes owner post-processing")
                }
                lock.lock(); emittedToken = tag?.ltrToken; lock.unlock()
            }
            if image.timeStamp == 43 { XCTAssertEqual(image.frameType, .videoFrameDelta, "Receiver-proven LTR refresh may predict instead of unconditional IDR"); refreshed.fulfill() }
            XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: info, renderTimeMs: 0), 0)
            return true
        }
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 256, 128, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(pixels, []); memset(CVPixelBufferGetBaseAddress(pixels), 255, CVPixelBufferGetDataSize(pixels)); CVPixelBufferUnlockBaseAddress(pixels, [])
        let ms = MachClock.nowMs()
        sender.pushedTiming(ExactVideoTiming(sourceID: String(repeating: "f", count: 32), displayMs: ms - 4,
            capturedMs: ms - 3, pushedMs: ms - 2, submittedMs: ms - 1, encodedMs: ms, resend: false), buffer: pixels)
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
    /// b7-scroll: the capture region rides in the access unit so the phone places each frame by it.
    func testTheCaptureRegionRidesInTheAccessUnitAndIsFoundByThePushedBuffer() throws {
        let context = VideoFeedbackContext(); context.configure(allowed: true, geometry: 7, scope: 3)
        let crop = CaptureRegion(epoch: 29, x: 32, y: 268, width: 1216, height: 560, outputWidth: 2432, outputHeight: 1200)
        let whole = CaptureRegion(epoch: 0, x: 0, y: 0, width: 1280, height: 828, outputWidth: 2560, outputHeight: 1656)
        var tag = try XCTUnwrap(context.encoded(token: nil))
        tag.region = crop
        XCTAssertNoThrow(try tag.validate())
        let json = try JSONEncoder().encode(tag)
        XCTAssertLessThanOrEqual(json.count, H26xVideoMarker.maximumJSONBytes)
        XCTAssertEqual(try JSONDecoder().decode(VideoFrameTag.self, from: json), tag)
        for hevc in [false, true] {
            let base = Data([0,0,0,1] + (hevc ? [0x26,1,0x80] : [0x65,0x80]))
            let marked = try XCTUnwrap(H26xVideoMarker.append(tag, to: base, hevc: hevc))
            XCTAssertEqual(H26xVideoMarker.read(marked, hevc: hevc)?.region, crop)
        }
        var bad = tag; bad.region = CaptureRegion(epoch: 1, x: 0, y: 0, width: 0, height: 10, outputWidth: 16, outputHeight: 16)
        XCTAssertThrowsError(try bad.validate())
        // The encoder rebuilds the final tag from the submitted one at output: the region must survive.
        let final = try XCTUnwrap(context.encoded(token: nil, expected: tag))
        XCTAssertEqual(final.region, crop)
        XCTAssertEqual(final.nonce, tag.nonce)
        XCTAssertNil(try XCTUnwrap(context.encoded(token: nil, expected: nil)).region)
        // An older Mac's tag has no region; an older phone reads a tag with one as if it had none.
        struct OldTag: Codable { let version: Int; let generation: String; let nonce: String; let geometryEpoch: UInt64; let scopeEpoch: UInt64 }
        XCTAssertEqual(try JSONDecoder().decode(OldTag.self, from: json).geometryEpoch, 7)

        var a: CVPixelBuffer?, b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &a)
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &b)
        let first = try XCTUnwrap(a), second = try XCTUnwrap(b)
        context.pushedRegion(crop, buffer: first)
        context.pushedRegion(whole, buffer: second)
        XCTAssertEqual(context.submittedRegion(buffer: second), whole, "found by the buffer, not by order")
        XCTAssertEqual(context.submittedRegion(buffer: first), crop)
        XCTAssertNil(context.submittedRegion(buffer: first), "each push is found once")
        context.pushedRegion(crop, buffer: first)
        context.pushedRegion(whole, buffer: first)
        XCTAssertEqual(context.submittedRegion(buffer: first), whole, "a re-pushed buffer carries its latest region")
        context.pushedRegion(nil, buffer: first)
        XCTAssertNil(context.submittedRegion(buffer: first))
        context.pushedRegion(bad.region, buffer: first)
        XCTAssertNil(context.submittedRegion(buffer: first), "an invalid region is dropped, not the tag")
        context.configure(allowed: false, geometry: 7, scope: 3)
        context.pushedRegion(crop, buffer: first)
        XCTAssertNil(context.submittedRegion(buffer: first), "no tags, no regions")
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
    func testSustainedExactCropAssociationsAt60_120And240FPSAcrossFiveSecondWindows() throws {
        for fps in [60, 120, 240] {
            let context = VideoFeedbackContext()
            context.configure(allowed: true, ltr: false, geometry: 7, scope: 3)
            // Cross both the signed boundary and UInt32 rollover used by native RTP timestamps.
            var wire = UInt32.max - 6000
            for index in 0..<(fps * 12) {
                let now = 1000 + Double(index) / Double(fps)
                let crop = CaptureRegion(epoch: UInt64(index + 1), x: Double(index % 3) * 16,
                    y: 8, width: 640, height: 400, outputWidth: 1280, outputHeight: 800)
                var tag = VideoFrameTag(generation: String(repeating: "a", count: 32),
                    nonce: String(format: "%032x", index + 1), geometryEpoch: 7, scopeEpoch: 3, ltrToken: nil)
                tag.region = crop
                context.received(tag, wire: wire, at: now)
                let output = try frame(wire)
                context.decoded(output, at: now)
                XCTAssertEqual(context.tag(for: output, at: now), tag,
                    "Every current native output retains its exact crop at \(fps) FPS, frame \(index)")
                // Replay of a retired wire must not manufacture a new tag.
                context.received(tag, wire: wire, at: now)
                let replay = try frame(wire); context.decoded(replay, at: now)
                XCTAssertNil(context.tag(for: replay, at: now))
                wire = wire &+ UInt32(90_000 / fps)
            }
        }
    }

    func testRetiredAssociationBoundFailsClosedAndExpiresOnlyAfterFiveSeconds() throws {
        let context = VideoFeedbackContext()
        context.configure(allowed: true, ltr: false, geometry: 7, scope: 3)
        let tag = VideoFrameTag(generation: String(repeating: "a", count: 32),
            nonce: String(repeating: "b", count: 32), geometryEpoch: 7, scopeEpoch: 3, ltrToken: nil)
        for wire in UInt32(0)..<2048 {
            context.received(tag, wire: wire, at: 1000)
            let output = try frame(wire); context.decoded(output, at: 1000)
            XCTAssertEqual(context.tag(for: output, at: 1000), tag)
        }
        for (wire, time) in [(UInt32(2048), 1000.0), (UInt32(0), 1005.0)] {
            context.received(tag, wire: wire, at: time)
            let output = try frame(wire); context.decoded(output, at: time)
            XCTAssertNil(context.tag(for: output, at: time), "No live tombstone is evicted, including TTL boundary")
        }
        context.received(tag, wire: 0, at: 1005.001)
        let fresh = try frame(0); context.decoded(fresh, at: 1005.001)
        XCTAssertEqual(context.tag(for: fresh, at: 1005.001), tag)
        context.received(tag, wire: 9000, at: 1006)
        context.beginDecoder(at: 1006)
        let oldDecoderOutput = try frame(9000); context.decoded(oldDecoderOutput, at: 1006)
        XCTAssertNil(context.tag(for: oldDecoderOutput, at: 1006))
        context.received(tag, wire: 9001, at: 1006)
        context.rejected(wire: 9001, at: 1006)
        let rejectedOutput = try frame(9001); context.decoded(rejectedOutput, at: 1006)
        XCTAssertNil(context.tag(for: rejectedOutput, at: 1006))
        context.configure(allowed: true, ltr: false, geometry: 8, scope: 3)
        context.received(tag, wire: 9002, at: 1007)
        let staleOutput = try frame(9002); context.decoded(staleOutput, at: 1007)
        XCTAssertNil(context.tag(for: staleOutput, at: 1007))
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
            let context = VideoFeedbackContext(); context.configure(allowed: true, timing: true, geometry: 7, scope: 3)
            let inner = ControlledFeedbackDecoder(), decoder = VideoFeedbackDecoder(inner: inner, context: context)
            XCTAssertEqual(decoder.startDecode(withNumberOfCores: 1), 0)
            defer { _ = decoder.release() }
            let ms = MachClock.nowMs()
            var tag = try XCTUnwrap(context.encoded(token: 912))
            tag.timing = ExactVideoTiming(sourceID: String(repeating: "d", count: 32), displayMs: ms - 4,
                capturedMs: ms - 3, pushedMs: ms - 2, submittedMs: ms - 1, encodedMs: ms, resend: false)
            let marked = try XCTUnwrap(H26xVideoMarker.append(tag, to: base))
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
            XCTAssertEqual(context.drainTiming()?.decoded, 0, "Invalid/unmarked duplicate cannot inherit exact timing")
            let independent = RTCEncodedImage(); independent.buffer = marked; independent.timeStamp = 43
            XCTAssertEqual(decoder.decode(independent, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), 0)
            let independentOutput = try frame(43); inner.emit(independentOutput)
            XCTAssertEqual(acknowledgements, 1, "An unrelated current wire still completes normally")
            XCTAssertEqual(context.tag(for: independentOutput), tag)
            XCTAssertEqual(context.drainTiming()?.decoded, 1, "Current successful exact output contributes once")
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
    #if DEBUG && AUDIO_LIFETIME_TESTS
    func testControlledNativeCallbackEntryTimingExcludesBlockedAssociationLock() throws {
        let context = VideoFeedbackContext()
        context.configure(allowed: true, ltr: false, timing: true, geometry: 7, scope: 3)
        let inner = ControlledFeedbackDecoder(), decoder = VideoFeedbackDecoder(inner: inner, context: context)
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 1), 0)
        defer { _ = decoder.release() }
        let now = MachClock.nowMs()
        var tag = try XCTUnwrap(context.encoded(token: nil))
        tag.timing = ExactVideoTiming(sourceID: String(repeating: "e", count: 32), displayMs: now - 4,
            capturedMs: now - 3, pushedMs: now - 2, submittedMs: now - 1, encodedMs: now, resend: false)
        let image = RTCEncodedImage(); image.timeStamp = 42
        image.buffer = try XCTUnwrap(H26xVideoMarker.append(tag, to: Data([0,0,0,1,0x65,0x80])))
        let done = expectation(description: "Controlled successful native callback passed actual wrapper")
        decoder.setCallback { _ in done.fulfill() }
        XCTAssertEqual(decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), 0)
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let stamp = DecodeEntryFixtureClock()
        context.beforeDecodedAdmissionForTesting = { stamp.record(MachClock.nowMs()); entered.signal() }
        DispatchQueue(label: "timing-fixture.association-holder").async {
            context.withTimingAdmissionHeldForTesting { held.signal(); _ = release.wait(timeout: .now() + 2) }
        }
        XCTAssertEqual(held.wait(timeout: .now() + 2), .success)
        let decoded = try frame(42)
        DispatchQueue(label: "timing-fixture.native-callback").async { inner.emit(decoded) }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { release.signal() }
        wait(for: [done], timeout: 2)
        context.beforeDecodedAdmissionForTesting = nil
        let shown = MachClock.nowMs() + 1
        // Controlled cross-clock alignment isolates this boundary; it is not measured physical latency.
        let offset = try XCTUnwrap(tag.timing).displayMs - stamp.value + 10
        context.presentedTiming(tag, originalSource: true, newSubmission: true, presentedTime: shown / 1000,
            clock: ClockSyncEstimate(offsetMs: offset, uncertaintyMs: 1, samples: 1), observedAtMs: shown - 1, nowMs: shown + 1)
        let report = try XCTUnwrap(context.drainTiming())
        XCTAssertEqual(report.timed, 1)
        XCTAssertLessThan(try XCTUnwrap(report.captureToDecodeP50Ms), 30, "Native entry timestamp excludes held association lock")
        XCTAssertGreaterThan(try XCTUnwrap(report.captureToPresentP50Ms), 100, "Later controlled presentation retains that wait")
    }
    func testProductionFinalNativeRouteGateRefusesPausedSubmissionAfterCallbackCutReturns() {
        let peer = PeerMedia(isHost: true, servers: [], localLink: ProvenLocalLink(localAddress: "192.168.1.10", peerAddress: "192.168.1.20"), hevc: false)
        defer { peer.close() }
        peer.authorizeRefinementPathForTesting()
        let paused = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let result = RefinementRouteResult()
        DispatchQueue(label: "refinement-test.owner").async {
            let accepted = peer.submitNativeRefinementEffectForTesting(before: {
                paused.signal(); _ = resume.wait(timeout: .now() + 3)
            }, effect: { result.recordEffect(); return true })
            result.recordAccepted(accepted); finished.signal()
        }
        XCTAssertEqual(paused.wait(timeout: .now() + 2), .success)
        DispatchQueue(label: "refinement-test.native-callback").sync { peer.cutRefinementPathForTesting() }
        resume.signal(); XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(result.effects, 0); XCTAssertFalse(result.accepted)
        XCTAssertFalse(peer.submitNativeRefinementEffectForTesting(before: {}, effect: { result.recordEffect(); return true }))
    }
    #endif
    private func frame(_ timestamp: UInt32) throws -> RTCVideoFrame {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let result = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixel)), rotation: ._0, timeStampNs: 1_000_000)
        result.timeStamp = Int32(bitPattern: timestamp); return result
    }
}

private final class RefinementRouteResult: @unchecked Sendable {
    private let lock = NSLock()
    private var effectCount = 0, acceptedValue = false
    private var pauseClaimed = false
    func claimPause() -> Bool { lock.lock(); defer { lock.unlock() }; if pauseClaimed { return false }; pauseClaimed = true; return true }
    var effects: Int { lock.lock(); defer { lock.unlock() }; return effectCount }
    var accepted: Bool { lock.lock(); defer { lock.unlock() }; return acceptedValue }
    func recordEffect() { lock.lock(); effectCount += 1; lock.unlock() }
    func recordAccepted(_ value: Bool) { lock.lock(); acceptedValue = value; lock.unlock() }
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
    private var tagged = 0, refined = 0, exact = 0
    var taggedFrames: Int { lock.lock(); defer { lock.unlock() }; return tagged }
    var refinedFrames: Int { lock.lock(); defer { lock.unlock() }; return refined }
    var exactTaggedFrames: Int { lock.lock(); defer { lock.unlock() }; return exact }
    init(context: VideoFeedbackContext) { self.context = context; super.init() }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let tag = context.tag(for: frame) else { return }
        let pixels = context.refinement(for: tag, at: ProcessInfo.processInfo.systemUptime)
        lock.lock(); tagged += 1; if pixels != nil { refined += 1 }; if tag.timing != nil { exact += 1 }; lock.unlock()
    }
}

private final class DecodeEntryFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ms = 0.0
    func record(_ value: Double) { lock.lock(); ms = value; lock.unlock() }
    var value: Double { lock.lock(); defer { lock.unlock() }; return ms }
}
