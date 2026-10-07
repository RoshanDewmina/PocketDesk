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
    private func capturedFormat(_ peer: PeerMedia) -> OSType {
        RemoteCaptureConfiguration.streamConfiguration(output: CapturePixelDimensions(width: 1920, height: 1200), region: nil, showsCursor: true,
            fps: 60, displayRefreshHz: 60, tuning: .tuned, refinesText: peer.refinementCaptureEnabled, fullColor444: peer.fullColorCaptureEnabled).pixelFormat
    }
    func testRefinementIsNotRequestedWhenTheOverrideIsOffAndCaptureStaysOnTheOriginal420Path() throws {
        let suite = "VideoRefinementTests.off.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: StillTextPreferences.sharpenKey); defaults.set(false, forKey: StillTextPreferences.textClarityKey)
        XCTAssertEqual(StillTextPreferences.requestedFeatures(defaults), [], "The internal overrides still turn both refinements off")
        let request = MacShareBlocker.Handshake.phoneRequest(StillTextPreferences.requestedFeatures(defaults))
        let heard = MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(request))
        XCTAssertFalse(heard.contains(SessionFeature.videoRefinement)); XCTAssertFalse(heard.contains(SessionFeature.textClarity))
        XCTAssertTrue(heard.contains(SessionFeature.videoLTR))
        let host = PeerMedia(isHost: true, servers: [], hevc: false, hevc444: false, textClarity: heard.contains(SessionFeature.textClarity))
        defer { host.close() }
        host.requestRefinementCapture(heard.contains(SessionFeature.videoRefinement))
        XCTAssertFalse(host.refinementCaptureEnabled); XCTAssertFalse(host.textClarity.enabled)
        XCTAssertEqual(capturedFormat(host), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }
    func testByDefaultOnlyTextClarityIsRequestedAndCaptureStaysOn420() throws {
        let suite = "VideoRefinementTests.default.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(StillTextPreferences.requestedFeatures(defaults), [SessionFeature.textClarity], "Text clarity is on with no setting; refinement is not")
        let heard = MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(MacShareBlocker.Handshake.phoneRequest(StillTextPreferences.requestedFeatures(defaults))))
        XCTAssertFalse(heard.contains(SessionFeature.videoRefinement)); XCTAssertTrue(heard.contains(SessionFeature.textClarity))
        let host = PeerMedia(isHost: true, servers: [], hevc: false, hevc444: false, textClarity: heard.contains(SessionFeature.textClarity))
        defer { host.close() }
        host.requestRefinementCapture(heard.contains(SessionFeature.videoRefinement))
        XCTAssertFalse(host.refinementCaptureEnabled); XCTAssertTrue(host.textClarity.enabled)
        XCTAssertEqual(capturedFormat(host), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }
    func testRefinementIsRequestedOnlyWhenTheOverrideIsOnAndThenCapturesBGRA() throws {
        let suite = "VideoRefinementTests.on.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: StillTextPreferences.sharpenKey)
        XCTAssertEqual(StillTextPreferences.requestedFeatures(defaults), [SessionFeature.videoRefinement, SessionFeature.textClarity])
        let request = MacShareBlocker.Handshake.phoneRequest(StillTextPreferences.requestedFeatures(defaults))
        let body = try JSONEncoder().encode(request)
        XCTAssertLessThanOrEqual(request.features.count, 8); XCTAssertLessThanOrEqual(body.count, 1024)
        let heard = MacShareBlocker.Handshake.features(in: body)
        XCTAssertTrue(heard.contains(SessionFeature.videoRefinement)); XCTAssertTrue(heard.contains(SessionFeature.textClarity))
        XCTAssertEqual(MacShareBlocker.Handshake.phoneRequest(["unknown.1"]).features, MacShareBlocker.Handshake.phone.features)
        let host = PeerMedia(isHost: true, servers: [], hevc: false, hevc444: false, textClarity: heard.contains(SessionFeature.textClarity))
        defer { host.close() }
        host.requestRefinementCapture(heard.contains(SessionFeature.videoRefinement))
        XCTAssertTrue(host.refinementCaptureEnabled); XCTAssertTrue(host.textClarity.enabled)
        XCTAssertEqual(capturedFormat(host), kCVPixelFormatType_32BGRA)
        host.requestRefinementCapture(false)
        XCTAssertEqual(capturedFormat(host), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }
    func testValuesTheRemovedTogglesWroteAreForgottenOnce() throws {
        let suite = "VideoRefinementTests.retire.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: StillTextPreferences.sharpenKey); defaults.set(false, forKey: StillTextPreferences.textClarityKey)
        StillTextPreferences.retireSettingValues(defaults)
        XCTAssertEqual(StillTextPreferences.requestedFeatures(defaults), [SessionFeature.textClarity], "Old toggle values give way to the defaults")
        defaults.set(false, forKey: StillTextPreferences.textClarityKey)
        StillTextPreferences.retireSettingValues(defaults)
        XCTAssertEqual(StillTextPreferences.requestedFeatures(defaults), [], "A later override is kept")
        defaults.set("YES", forKey: StillTextPreferences.sharpenKey)
        XCTAssertEqual(StillTextPreferences.requestedFeatures(defaults), [SessionFeature.videoRefinement], "A launch argument arrives as a string and still overrides")
        defaults.removeObject(forKey: StillTextPreferences.sharpenKey); defaults.set("NO", forKey: StillTextPreferences.textClarityKey)
        XCTAssertEqual(StillTextPreferences.requestedFeatures(defaults), [], "A string NO turns text clarity off")
    }
    func testAnEarlierPhoneThatAlwaysListsRefinementStillNegotiatesWithinTheBound() throws {
        let earlierBody = Data(#"{"features":["blocker.1","blocker.2","features.32","input.causal.1","input.pencil.1","video.ltr.1","video.refine.1"]}"#.utf8)
        let heard = MacShareBlocker.Handshake.features(in: earlierBody)
        XCTAssertEqual(heard.count, 7); XCTAssertTrue(heard.contains(SessionFeature.videoRefinement))
        XCTAssertFalse(heard.contains(SessionFeature.textClarity), "An earlier phone never asks for the QP floor")
    }
    func testOptInsNeverPushTheBaseFeaturesPastAnEarlierMacsBound() throws {
        let base = MacShareBlocker.Handshake.phone.features
        let everyOptIn = MacShareBlocker.Handshake.phoneRequest([SessionFeature.videoRefinement, SessionFeature.textClarity], mode: "couch")
        XCTAssertLessThanOrEqual(everyOptIn.features.count, 8)
        XCTAssertEqual(everyOptIn.features, base + [SessionFeature.videoRefinement]); XCTAssertEqual(everyOptIn.options, [SessionFeature.textClarity, SessionFeature.clipboardSync, SessionFeature.phoneAudio, SessionFeature.deliberateEnd])
        XCTAssertLessThanOrEqual(everyOptIn.options?.count ?? 0, MacShareBlocker.Handshake.maximumOptions)
        XCTAssertEqual(everyOptIn.requested, Set(base + [SessionFeature.videoRefinement, SessionFeature.textClarity, SessionFeature.clipboardSync, SessionFeature.phoneAudio, SessionFeature.deliberateEnd]).union(everyOptIn.shortcutChips == true ? [SessionFeature.shortcutChips] : []).union(everyOptIn.keysOnDemand == true ? [SessionFeature.keysOnDemand] : []))
        let body = try JSONEncoder().encode(everyOptIn)
        XCTAssertEqual(MacShareBlocker.Handshake.requestedMode(in: body), .couch)
        let suite = "VideoRefinementTests.clipboardOff.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "clipboardAutoSyncDisabled")
        defaults.set(true, forKey: "phoneAudioRequestDisabled")
        defaults.set(true, forKey: DeliberateSessionEnd.disabledDefaultsKey)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(MacShareBlocker.Handshake.phoneRequest([], defaults: defaults)), as: UTF8.self).contains("options"),
                       "With every opt-in off the request is the earlier wire format")
        // An earlier Mac decodes with a struct that has no `options`; its synthesized Codable ignores the key.
        struct EarlierMacHandshake: Decodable { var features: [String]; var mode: String? }
        let earlier = try JSONDecoder().decode(EarlierMacHandshake.self, from: body)
        XCTAssertEqual(earlier.features, everyOptIn.features); XCTAssertLessThanOrEqual(earlier.features.count, 8)
        let withoutOptions = Data(#"{"features":["blocker.1","blocker.2","features.32","input.causal.1","input.pencil.1","video.ltr.1","video.timing.1"]}"#.utf8)
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: withoutOptions), Set(base), "A request without options decodes to the full base set")
        let flooded = MacShareBlocker.Handshake(features: base, options: (0...MacShareBlocker.Handshake.maximumOptions).map { "option.\($0)" })
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(flooded)), Set(base), "Too many options drop only the options")
        let bounded = MacShareBlocker.Handshake(features: base, options: [SessionFeature.textClarity, "", String(repeating: "x", count: 33)])
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(bounded)), Set(base + [SessionFeature.textClarity]))
        let smuggled = MacShareBlocker.Handshake(features: [MacShareBlocker.feature], options: [SessionFeature.causalInput, "video.unknown.1", SessionFeature.textClarity])
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(smuggled)), [MacShareBlocker.feature, SessionFeature.textClarity],
                       "Unknown option names are dropped; only text clarity rides in options")
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
    func testIdleTimerDropsIncompleteAssemblyWithoutAnotherIncomingPacket() throws {
        let pipe = VideoRefinementChannel(); pipe.configure(enabled: true, geometry: 7, scope: 3)
        pipe.send = { _, _ in true }
        let packet = VideoRefinementChunk(version: 1, id: String(repeating: "b", count: 32), identity: identity(Data()),
            total: 18000, offset: 0, body: Data(repeating: 5, count: 9000), ack: false)
        pipe.receive(try JSONEncoder().encode(packet), at: 10)
        XCTAssertEqual(pipe.retainedIncomingBytesForTesting, 9000)
        pipe.pump(at: 12); XCTAssertEqual(pipe.retainedIncomingBytesForTesting, 9000)
        pipe.pump(at: 12.001); XCTAssertEqual(pipe.retainedIncomingBytesForTesting, 0)
    }
    func testContextRetirementDropsCachedPNGAndFencesAnAlreadyQueuedProducerJob() throws {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixel)
        CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pixels, []); memset(CVPixelBufferGetBaseAddress(pixels), 255, CVPixelBufferGetDataSize(pixels)); CVPixelBufferUnlockBaseAddress(pixels, [])
        for terminal in [false, true] {
            let context = VideoFeedbackContext(); context.configure(allowed: true, refinement: true, geometry: 7, scope: 3)
            let producer = context.refinementProducerForTesting
            var tag = try XCTUnwrap(context.encoded(token: nil))
            var images = 0
            context.setRefinementImage { _ in images += 1 }
            _ = context.prepareRefinement(pixels, tag: tag, at: 10)
            _ = context.prepareRefinement(pixels, tag: tag, at: 10.6)
            producer.drainForTesting(); XCTAssertGreaterThan(producer.cachedBytesForTesting, 0); XCTAssertEqual(images, 1)
            context.configure(allowed: false, refinement: true, geometry: 7, scope: 3)
            XCTAssertEqual(producer.cachedBytesForTesting, 0)
            context.configure(allowed: true, refinement: true, geometry: 7, scope: 3)
            tag = try XCTUnwrap(context.encoded(token: nil))
            let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
            producer.beforeEncodeForTesting = { entered.signal(); _ = resume.wait(timeout: .now() + 3) }
            _ = context.prepareRefinement(pixels, tag: tag, at: 20)
            _ = context.prepareRefinement(pixels, tag: tag, at: 20.6)
            XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
            if terminal { context.end() } else { context.configure(allowed: false, refinement: true, geometry: 7, scope: 3) }
            XCTAssertEqual(producer.cachedBytesForTesting, 0, "Retirement synchronously drops the sensitive cache")
            resume.signal(); producer.drainForTesting()
            XCTAssertEqual(producer.cachedBytesForTesting, 0); XCTAssertEqual(images, 1, "Old queued job cannot repopulate or emit")
            if terminal { XCTAssertNil(producer.inspect(pixels, tag: tag, at: 30) { _ in XCTFail("Terminal producer") }) }
        }
    }
}
