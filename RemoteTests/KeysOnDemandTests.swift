import XCTest
import WebRTC

/// ENCODER-OPTIMIZATIONS rows 1 and 3: the keys-on-demand capability and the libwebrtc degradation
/// switch at 60 fps. Every default keeps today's behaviour; only the host flags change anything.
final class KeysOnDemandTests: XCTestCase {
    private func defaults(_ name: String) throws -> UserDefaults {
        let suite = "KeysOnDemandTests.\(name).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testTheThreeFlagsDefaultToTodayParseFromDefaultsAndReachTheSummary() throws {
        for key in [StreamTuning.keysOnDemandKey, StreamTuning.ladderKeyNeutralKey, StreamTuning.webRTCAdaptationAt60Key] {
            XCTAssertTrue(StreamTuning.experimentKeys.contains(key), key)
        }
        let defaults = try defaults("flags")
        let today = StreamTuning.resolve(defaults: defaults)
        XCTAssertEqual(today, StreamTuning.tuned)
        XCTAssertFalse(today.keysOnDemand); XCTAssertFalse(today.ladderKeyNeutral); XCTAssertTrue(today.webRTCAdaptationAt60)
        for text in ["keys on demand", "key-neutral ladder", "no webrtc adaptation at 60"] {
            XCTAssertFalse(today.summary.contains(text), today.summary)
        }
        defaults.set("YES", forKey: StreamTuning.keysOnDemandKey)
        defaults.set(true, forKey: StreamTuning.ladderKeyNeutralKey)
        defaults.set("NO", forKey: StreamTuning.webRTCAdaptationAt60Key)
        let flipped = StreamTuning.resolve(defaults: defaults)
        XCTAssertTrue(flipped.keysOnDemand); XCTAssertTrue(flipped.ladderKeyNeutral); XCTAssertFalse(flipped.webRTCAdaptationAt60)
        XCTAssertTrue(flipped.summary.contains("keys on demand · key-neutral ladder · no webrtc adaptation at 60"), flipped.summary)
        defaults.set(false, forKey: StreamTuning.keysOnDemandKey)
        defaults.set("NO", forKey: StreamTuning.ladderKeyNeutralKey)
        defaults.set(true, forKey: StreamTuning.webRTCAdaptationAt60Key)
        XCTAssertEqual(StreamTuning.resolve(defaults: defaults), StreamTuning.tuned, "each switch restores today's stream")
        defaults.set(true, forKey: StreamTuning.legacyDefaultsKey)
        XCTAssertEqual(StreamTuning.resolve(defaults: defaults).summary, "legacy")
    }

    func testThePhoneAsksForKeysOnDemandUnlessItsSwitchIsOffAndOlderMacsStillReadTheRequest() throws {
        let defaults = try defaults("phone")
        XCTAssertTrue(KeysOnDemandRequest.isEnabled(defaults), "on with no setting")
        let request = MacShareBlocker.Handshake.phoneRequest(StillTextPreferences.requestedFeatures(defaults), defaults: defaults)
        XCTAssertEqual(request.keysOnDemand, true)
        XCTAssertTrue(request.requested.contains(SessionFeature.keysOnDemand))
        XCTAssertEqual(request.features, MacShareBlocker.Handshake.phone.features, "the capability is not a ninth feature")
        XCTAssertLessThanOrEqual(request.options?.count ?? 0, MacShareBlocker.Handshake.maximumOptions, "nor a fifth option")
        XCTAssertFalse(request.options?.contains(SessionFeature.keysOnDemand) ?? false)
        let body = try JSONEncoder().encode(request)
        XCTAssertLessThanOrEqual(body.count, 1024)
        let heard = MacShareBlocker.Handshake.features(in: body)
        XCTAssertTrue(heard.contains(SessionFeature.keysOnDemand))
        XCTAssertTrue(heard.contains(SessionFeature.textClarity), "the known options still arrive beside it")
        struct OldHandshake: Codable { let features: [String]; let mode: String?; let options: [String]? }
        let old = try JSONDecoder().decode(OldHandshake.self, from: body)
        XCTAssertEqual(old.features, request.features); XCTAssertEqual(old.options, request.options)
        XCTAssertFalse(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(old)).contains(SessionFeature.keysOnDemand),
                       "an older Mac's own shape never grows the capability")

        defaults.set("NO", forKey: KeysOnDemandRequest.defaultsKey)
        XCTAssertFalse(KeysOnDemandRequest.isEnabled(defaults), "a launch argument arrives as a string and still turns it off")
        let quiet = MacShareBlocker.Handshake.phoneRequest(StillTextPreferences.requestedFeatures(defaults), defaults: defaults)
        XCTAssertNil(quiet.keysOnDemand)
        XCTAssertFalse(quiet.requested.contains(SessionFeature.keysOnDemand))
        XCTAssertFalse(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(quiet)).contains(SessionFeature.keysOnDemand))
        defaults.set(false, forKey: KeysOnDemandRequest.defaultsKey)
        XCTAssertNil(MacShareBlocker.Handshake.phoneRequest([], defaults: defaults).keysOnDemand)
        defaults.set(true, forKey: KeysOnDemandRequest.defaultsKey)
        XCTAssertEqual(MacShareBlocker.Handshake.phoneRequest([], defaults: defaults).keysOnDemand, true)
    }

    func testAnOlderPhoneNeverAsksForKeysOnDemand() throws {
        let earlier = Data(#"{"features":["blocker.1","blocker.2","features.32","input.causal.1","input.pencil.1","video.ltr.1","video.timing.1"],"options":["video.clarity.1"],"phoneLoadWindows":true}"#.utf8)
        let heard = MacShareBlocker.Handshake.features(in: earlier)
        XCTAssertTrue(heard.contains(SessionFeature.textClarity))
        XCTAssertFalse(heard.contains(SessionFeature.keysOnDemand))
        let declined = Data(#"{"features":["blocker.1"],"keysOnDemand":false}"#.utf8)
        XCTAssertFalse(MacShareBlocker.Handshake.features(in: declined).contains(SessionFeature.keysOnDemand))
        var overflow = MacShareBlocker.Handshake(features: Array(repeating: "f", count: 9))
        overflow.keysOnDemand = true
        XCTAssertFalse(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(overflow)).contains(SessionFeature.keysOnDemand),
                       "too many features counts as no features, the capability included")
    }

    func testTheHostDropsTheTenSecondKeyOnlyForAnAskingPhoneWithTheHostFlagOn() throws {
        var on = StreamTuning.tuned; on.keysOnDemand = true
        let off = StreamTuning.tuned
        let newPhone = MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(MacShareBlocker.Handshake.phoneRequest([SessionFeature.textClarity])))
        let oldPhone = MacShareBlocker.Handshake.features(in: Data(#"{"features":["blocker.1","video.ltr.1"],"options":["video.clarity.1"]}"#.utf8))
        let cases: [(name: String, tuning: StreamTuning, phone: Set<String>, onDemand: Bool)] = [
            ("old phone, flag off", off, oldPhone, false), ("old phone, flag on", on, oldPhone, false),
            ("new phone, flag off", off, newPhone, false), ("new phone, flag on", on, newPhone, true)]
        for item in cases {
            let options = OwnedEncoderOptions(item.tuning, phoneRequestsKeysOnDemand: item.phone.contains(SessionFeature.keysOnDemand))
            XCTAssertFalse(options.periodicKeyFrames, item.name)
            XCTAssertEqual(options.keysOnDemand, item.onDemand, item.name)
            XCTAssertEqual(options.keyFrameIntervalDurationSeconds(hevc: true), item.onDemand ? 0 : 10, item.name)
            XCTAssertEqual(options.keyFrameIntervalDurationSeconds(hevc: false), 10, "\(item.name): an H.264 session keeps the 10 s key")
            let host = PeerMedia(isHost: true, servers: [], hevc: false, hevc444: false, textClarity: item.phone.contains(SessionFeature.textClarity),
                                 keysOnDemand: item.phone.contains(SessionFeature.keysOnDemand))
            defer { host.close() }
            XCTAssertEqual(host.keysOnDemandRequested, item.phone.contains(SessionFeature.keysOnDemand), item.name)
        }
        XCTAssertEqual(OwnedEncoderOptions.requestedKeysOnlyInterval, 1_000_000, "the frame interval stays: 0 there hands placement to the encoder")
        XCTAssertEqual(OwnedEncoderOptions(on), OwnedEncoderOptions(periodicKeyFrames: false), "no phone asked")
        XCTAssertEqual(OwnedEncoderOptions(StreamTuning.legacy, phoneRequestsKeysOnDemand: true), OwnedEncoderOptions(), "the legacy stream has no requested-keys-only session to change")
        let phone = PeerMedia(isHost: false, servers: [], hevc: false, hevc444: false, keysOnDemand: true)
        defer { phone.close() }
        XCTAssertFalse(phone.keysOnDemandRequested, "host only")
    }

    func testAKeysOnDemandSessionIsCreatedOnEveryStartRecordsItselfAndStillAnswersKeyRequests() throws {
        let configuration = try XCTUnwrap(OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters))
        for onDemand in [false, true] {
            let counters = StreamCounters()
            let encoder = OwnedVTEncoder(configuration: configuration, counters: counters, inFlightLimit: { 1 }, maximumQPCeiling: { 26 },
                                         newestFrameWins: { true }, options: { OwnedEncoderOptions(periodicKeyFrames: false, keysOnDemand: onDemand) })
            defer { _ = encoder.release() }
            let settings = RTCVideoEncoderSettings()
            settings.name = "H265"; settings.width = 640; settings.height = 416; settings.startBitrate = 8000
            settings.maxBitrate = 8000; settings.maxFramerate = 60; settings.qpMax = 30; settings.mode = .screensharing
            XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), 0, "stage=\(encoder.lastStage) status=\(encoder.lastStatus)")
            XCTAssertEqual(encoder.optionsEvidence, onDemand ? "requested keys only · keys on demand" : "requested keys only")
            let evidence = try XCTUnwrap(counters.drain(inputBufferedBytes: nil).encoderEvidence)
            XCTAssertNoThrow(try evidence.validate())
            XCTAssertEqual(evidence.options, encoder.optionsEvidence)
            XCTAssertEqual(evidence.options?.contains("keys on demand"), onDemand)
            XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), 0, "a replacement session applies the same setting")
            XCTAssertEqual(encoder.optionsEvidence, onDemand ? "requested keys only · keys on demand" : "requested keys only")

            let lock = NSLock(), signal = DispatchSemaphore(value: 0)
            var keys: [Int] = [], outputs = 0
            encoder.setCallback { image, _ in
                lock.lock(); outputs += 1
                if image.frameType == .videoFrameKey { keys.append(Int(image.timeStamp) - 1000) }
                lock.unlock(); signal.signal(); return true
            }
            var pixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 640, 416, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixels)
            let key = [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]
            for index in 0..<12 {
                CVPixelBufferLockBaseAddress(buffer, [])
                for plane in 0..<2 { memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? Int32(40 + index * 9) : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)) }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                if index == 9 { encoder.requireIndependentKeyFrame() }
                let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1_000_000_000 + Int64(index) * 16_666_667)
                frame.timeStamp = Int32(1000 + index)
                XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [0, 5].contains(index) ? key : []), 0)
                XCTAssertEqual(signal.wait(timeout: .now() + 2), .success, "frame \(index)")
            }
            lock.lock(); defer { lock.unlock() }
            XCTAssertEqual(outputs, 12)
            XCTAssertEqual(keys, [0, 5, 9], "onDemand=\(onDemand): the start key, a PLI/FIR request and a forced recovery still produce key frames")
        }
    }

    func testAnH264SessionKeepsTheTenSecondKeyWithTheFlagAndCapabilityOn() throws {
        let configuration = try XCTUnwrap(OwnedVTConfiguration(parameters: ["packetization-mode": "1", "profile-level-id": "640033"]))
        XCTAssertFalse(configuration.lowLatency)
        let counters = StreamCounters()
        let encoder = OwnedVTEncoder(configuration: configuration, counters: counters, inFlightLimit: { 1 }, maximumQPCeiling: { 26 },
                                     newestFrameWins: { true }, options: { OwnedEncoderOptions(periodicKeyFrames: false, keysOnDemand: true) })
        defer { _ = encoder.release() }
        let settings = RTCVideoEncoderSettings()
        settings.name = "H264"; settings.width = 640; settings.height = 416; settings.startBitrate = 8000
        settings.maxBitrate = 8000; settings.maxFramerate = 60; settings.qpMax = 30; settings.mode = .screensharing
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), 0, "stage=\(encoder.lastStage) status=\(encoder.lastStatus)")
        XCTAssertEqual(encoder.optionsEvidence, "requested keys only", "no 'keys on demand' on the stock-decoder codec")
        let evidence = try XCTUnwrap(counters.drain(inputBufferedBytes: nil).encoderEvidence)
        XCTAssertEqual(evidence.options, "requested keys only")
    }

    /// Presentation timestamps one second apart stand in for ten seconds of session: VideoToolbox places
    /// its duration-based key by PTS. Only the first frame asks for a key.
    func testTheTenSecondKeyArrivesByPresentationTimeOnlyWithTheFlagOff() throws {
        let configuration = try XCTUnwrap(OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters))
        for onDemand in [false, true] {
            let encoder = OwnedVTEncoder(configuration: configuration, counters: StreamCounters(), inFlightLimit: { 1 }, maximumQPCeiling: { 26 },
                                         newestFrameWins: { true }, options: { OwnedEncoderOptions(periodicKeyFrames: false, keysOnDemand: onDemand) })
            defer { _ = encoder.release() }
            let settings = RTCVideoEncoderSettings()
            settings.name = "H265"; settings.width = 640; settings.height = 416; settings.startBitrate = 8000
            settings.maxBitrate = 8000; settings.maxFramerate = 60; settings.qpMax = 30; settings.mode = .screensharing
            XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), 0, "stage=\(encoder.lastStage) status=\(encoder.lastStatus)")
            let lock = NSLock(), signal = DispatchSemaphore(value: 0)
            var keys: [Int] = [], outputs = 0
            encoder.setCallback { image, _ in
                lock.lock(); outputs += 1
                if image.frameType == .videoFrameKey { keys.append(Int(image.timeStamp) - 1000) }
                lock.unlock(); signal.signal(); return true
            }
            var pixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 640, 416, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixels)
            let key = [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]
            for index in 0..<13 {
                CVPixelBufferLockBaseAddress(buffer, [])
                for plane in 0..<2 { memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? Int32(40 + index * 9) : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)) }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1_000_000_000 + Int64(index) * 1_000_000_000)
                frame.timeStamp = Int32(1000 + index)
                XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: index == 0 ? key : []), 0)
                XCTAssertEqual(signal.wait(timeout: .now() + 2), .success, "frame \(index)")
            }
            lock.lock(); defer { lock.unlock() }
            XCTAssertEqual(outputs, 13)
            if onDemand {
                XCTAssertEqual(keys, [0], "keys on demand: nothing after the requested start key")
            } else {
                XCTAssertEqual(keys.count, 2, "today's 10 s key: \(keys)")
                XCTAssertTrue((10...12).contains(keys.last ?? -1), "the safety key lands about 10 s of PTS after the start key: \(keys)")
            }
        }
    }

    func testWebRTCAdaptationAtSixtyStaysUnlessItsFlagIsOff() {
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 60, tuning: .tuned),
                       SenderRateParameters(maxFramerate: 60, degradationPreference: .maintainResolution), "today")
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 60, tuning: .tuned, quality: .balanced).degradationPreference, .maintainFramerate)
        var tuning = StreamTuning.tuned
        tuning.webRTCAdaptationAt60 = false
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 60, tuning: tuning),
                       SenderRateParameters(maxFramerate: 60, degradationPreference: .maintainFramerateAndResolution))
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 60, tuning: tuning, ladderFPS: 30),
                       SenderRateParameters(maxFramerate: 30, degradationPreference: .maintainFramerateAndResolution),
                       "the ladder still lowers the rate; libwebrtc no longer does")
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 30, tuning: tuning).degradationPreference, .maintainFramerateAndResolution)
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 60, tuning: tuning, quality: .balanced).degradationPreference,
                       .maintainFramerateAndResolution, "Performance mode too")
        for noAdaptation in [true, false] {
            tuning.highRefreshNoAdaptation = noAdaptation
            XCTAssertEqual(SenderRateParameters.make(targetFPS: 120, tuning: tuning).degradationPreference,
                           noAdaptation ? .maintainFramerateAndResolution : .maintainResolution, "above 60 the G5 switch alone decides")
        }
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 60, tuning: .legacy),
                       SenderRateParameters(maxFramerate: 60, degradationPreference: nil), "legacy keeps WebRTC's default")
    }
}
