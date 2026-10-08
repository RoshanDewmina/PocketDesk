import XCTest
import CoreGraphics
import ScreenCaptureKit
import WebRTC

/// LATENCY-PLAN items 5, 7, 14, 15 and 16: host switches that all default to today's stream.
final class HostLatencyTweaksTests: XCTestCase {
    private func defaults(_ name: String) throws -> UserDefaults {
        let suite = "HostLatencyTweaksTests.\(name).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private let keys = [StreamTuning.keysOnDemandH264Key, StreamTuning.encoderMaxFrameDelayKey, StreamTuning.captureQueueDepthKey,
                        StreamTuning.captureResolutionKey, StreamTuning.encodingMinBitrateLANKey]

    func testTheFiveFlagsDefaultToTodayParseTheirRangesAndReachTheSummary() throws {
        for key in keys { XCTAssertTrue(StreamTuning.experimentKeys.contains(key), key) }
        let defaults = try defaults("flags")
        let today = StreamTuning.resolve(defaults: defaults)
        XCTAssertEqual(today, StreamTuning.tuned)
        XCTAssertFalse(today.keysOnDemandH264)
        XCTAssertNil(today.encoderMaxFrameDelay)
        XCTAssertNil(today.captureQueueDepth)
        XCTAssertEqual(today.captureResolution, .automatic)
        XCTAssertNil(today.encodingMinBitrateLANKbps)
        let parts = ["H.264 keys on demand", "max frame delay", "capture queue", "capture resolution", "LAN encoding floor"]
        for part in parts { XCTAssertFalse(today.summary.contains(part), today.summary) }

        defaults.set("YES", forKey: StreamTuning.keysOnDemandH264Key)
        defaults.set(1, forKey: StreamTuning.encoderMaxFrameDelayKey)
        defaults.set(3, forKey: StreamTuning.captureQueueDepthKey)
        defaults.set("Nominal", forKey: StreamTuning.captureResolutionKey)
        defaults.set(8000, forKey: StreamTuning.encodingMinBitrateLANKey)
        let flipped = StreamTuning.resolve(defaults: defaults)
        XCTAssertTrue(flipped.keysOnDemandH264)
        XCTAssertFalse(flipped.keysOnDemand, "the HEVC switch is separate")
        XCTAssertEqual(flipped.encoderMaxFrameDelay, 1)
        XCTAssertEqual(flipped.captureQueueDepth, 3)
        XCTAssertEqual(flipped.captureResolution, .nominal)
        XCTAssertEqual(flipped.encodingMinBitrateLANKbps, 8000)
        XCTAssertTrue(flipped.summary.contains("H.264 keys on demand · max frame delay 1 · capture queue 3 · capture resolution nominal · LAN encoding floor 8000"),
                      flipped.summary)
        defaults.set("best", forKey: StreamTuning.captureResolutionKey)
        XCTAssertEqual(StreamTuning.resolve(defaults: defaults).captureResolution, .best)

        let invalid: [(String, Any)] = [(StreamTuning.encoderMaxFrameDelayKey, 0), (StreamTuning.captureQueueDepthKey, 2),
                                        (StreamTuning.captureResolutionKey, "sharpest"), (StreamTuning.encodingMinBitrateLANKey, 299)]
        for (key, value) in invalid { defaults.set(value, forKey: key) }
        defaults.set(false, forKey: StreamTuning.keysOnDemandH264Key)
        XCTAssertEqual(StreamTuning.resolve(defaults: defaults), StreamTuning.tuned, "out-of-range values keep today's stream")
        for (key, value) in [(StreamTuning.encoderMaxFrameDelayKey, 9), (StreamTuning.captureQueueDepthKey, 9),
                             (StreamTuning.encodingMinBitrateLANKey, 100_001)] { defaults.set(value, forKey: key) }
        XCTAssertEqual(StreamTuning.resolve(defaults: defaults), StreamTuning.tuned)
        for (key, value) in [(StreamTuning.encoderMaxFrameDelayKey, 8), (StreamTuning.captureQueueDepthKey, 8),
                             (StreamTuning.encodingMinBitrateLANKey, 100_000)] { defaults.set(value, forKey: key) }
        let upper = StreamTuning.resolve(defaults: defaults)
        XCTAssertEqual([upper.encoderMaxFrameDelay, upper.captureQueueDepth, upper.encodingMinBitrateLANKbps], [8, 8, 100_000])
        defaults.set(true, forKey: StreamTuning.legacyDefaultsKey)
        XCTAssertEqual(StreamTuning.resolve(defaults: defaults).summary, "legacy")
    }

    // MARK: Item 7 — keys on demand for H.264

    func testH264KeysOnDemandNeedsItsOwnFlagAndAnAskingPhone() {
        for hevcFlag in [false, true] {
            for h264Flag in [false, true] {
                for phoneAsks in [false, true] {
                    var tuning = StreamTuning.tuned
                    tuning.keysOnDemand = hevcFlag
                    tuning.keysOnDemandH264 = h264Flag
                    let options = OwnedEncoderOptions(tuning, phoneRequestsKeysOnDemand: phoneAsks)
                    let name = "hevc \(hevcFlag) h264 \(h264Flag) phone \(phoneAsks)"
                    XCTAssertEqual(options.keyFrameIntervalDurationSeconds(hevc: false), h264Flag && phoneAsks ? 0 : 10, name)
                    XCTAssertEqual(options.keyFrameIntervalDurationSeconds(hevc: true), hevcFlag && phoneAsks ? 0 : 10, name)
                }
            }
        }
        var legacy = StreamTuning.legacy
        legacy.keysOnDemandH264 = true
        XCTAssertTrue(OwnedEncoderOptions(legacy, phoneRequestsKeysOnDemand: true).periodicKeyFrames,
                      "the legacy stream sets no key interval at all, so nothing changes there")
    }

    private func settings(_ name: String) -> RTCVideoEncoderSettings {
        let settings = RTCVideoEncoderSettings()
        settings.name = name; settings.width = 640; settings.height = 416; settings.startBitrate = 8000
        settings.maxBitrate = 8000; settings.maxFramerate = 60; settings.qpMax = 30; settings.mode = .screensharing
        return settings
    }

    /// Encodes `count` frames, one second of presentation time apart unless `frameSpacingNs` says
    /// otherwise, and returns the indices that came out as key frames.
    private func encodedKeys(_ encoder: OwnedVTEncoder, count: Int, frameSpacingNs: Int64 = 1_000_000_000,
                             requestKeyAt: Set<Int> = [0], heldFrames: Int = 0,
                             file: StaticString = #filePath, line: UInt = #line) throws -> [Int] {
        let lock = NSLock(), signal = DispatchSemaphore(value: 0)
        var keys: [Int] = [], outputs = 0
        encoder.setCallback { image, _ in
            lock.lock(); outputs += 1
            if image.frameType == .videoFrameKey { keys.append(Int(image.timeStamp) - 1000) }
            lock.unlock(); signal.signal(); return true
        }
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 640, 416, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess, file: file, line: line)
        let buffer = try XCTUnwrap(pixels)
        let key = [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]
        for index in 0..<count {
            CVPixelBufferLockBaseAddress(buffer, [])
            for plane in 0..<2 { memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? Int32(40 + index * 9) : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1_000_000_000 + Int64(index) * frameSpacingNs)
            frame.timeStamp = Int32(1000 + index)
            XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: requestKeyAt.contains(index) ? key : []), 0, file: file, line: line)
            // An encoder may hold `heldFrames` frames until later ones arrive (MaxFrameDelayCount).
            if index >= heldFrames {
                XCTAssertEqual(signal.wait(timeout: .now() + 2), .success, "frame \(index - heldFrames)", file: file, line: line)
            }
        }
        for _ in 0..<heldFrames { _ = signal.wait(timeout: .now() + 0.5) }
        lock.lock(); defer { lock.unlock() }
        XCTAssertGreaterThanOrEqual(outputs, count - heldFrames, file: file, line: line)
        XCTAssertLessThanOrEqual(outputs, count, file: file, line: line)
        return keys
    }

    /// Both H.264 shapes the host negotiates: High 5.1 (standard rate control) and High 5.2 (the
    /// low-latency rate control the Mac runs today).
    func testAnH264SessionDropsTheTenSecondKeyOnlyWithTheH264FlagAndStillAnswersRequests() throws {
        for profile in ["640033", "640034"] {
            let configuration = try XCTUnwrap(OwnedVTConfiguration(parameters: ["packetization-mode": "1", "profile-level-id": profile]))
            XCTAssertEqual(configuration.lowLatency, profile == "640034")
            for onDemand in [false, true] {
                let counters = StreamCounters()
                let encoder = OwnedVTEncoder(configuration: configuration, counters: counters, inFlightLimit: { 1 }, maximumQPCeiling: { 26 },
                                             newestFrameWins: { true },
                                             options: { OwnedEncoderOptions(periodicKeyFrames: false, keysOnDemand: true, keysOnDemandH264: onDemand) })
                defer { _ = encoder.release() }
                let name = "\(profile) onDemand=\(onDemand)"
                XCTAssertEqual(encoder.startEncode(with: settings("H264"), numberOfCores: 1), 0, "\(name) stage=\(encoder.lastStage) status=\(encoder.lastStatus)")
                XCTAssertEqual(encoder.optionsEvidence, onDemand ? "requested keys only · keys on demand" : "requested keys only", name)
                XCTAssertEqual(counters.drain(inputBufferedBytes: nil).encoderEvidence?.options, encoder.optionsEvidence, name)
                let keys = try encodedKeys(encoder, count: 13)
                if onDemand {
                    XCTAssertEqual(keys, [0], "\(name): nothing after the requested start key")
                } else {
                    XCTAssertEqual(keys.count, 2, "\(name): today's 10 s key: \(keys)")
                    XCTAssertTrue((10...12).contains(keys.last ?? -1), "\(name): \(keys)")
                }
                XCTAssertEqual(encoder.startEncode(with: settings("H264"), numberOfCores: 1), 0, "\(name): a replacement session")
                encoder.requireIndependentKeyFrame()
                XCTAssertEqual(try encodedKeys(encoder, count: 4, frameSpacingNs: 16_666_667, requestKeyAt: [2]), [0, 2],
                               "\(name): a forced recovery key and a PLI/FIR request still produce key frames")
            }
        }
    }

    // MARK: Item 14 — MaxFrameDelayCount

    func testMaxFrameDelayIsAskedForOnlyWithTheFlagAndEveryFrameStillComesOut() throws {
        let h264 = try XCTUnwrap(OwnedVTConfiguration(parameters: ["packetization-mode": "1", "profile-level-id": "640034"]))
        let hevc = try XCTUnwrap(OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.codecInfo.parameters))
        let cases: [(name: String, configuration: any OwnedVideoConfiguration, codec: String)] = [("H.264 5.2", h264, "H264"), ("HEVC", hevc, "H265")]
        for item in cases {
            for delay in [nil, 1] as [Int?] {
                let encoder = OwnedVTEncoder(configuration: item.configuration, counters: StreamCounters(), inFlightLimit: { 2 }, maximumQPCeiling: { 26 },
                                             newestFrameWins: { true }, encoderPipelining: { true },
                                             options: { OwnedEncoderOptions(periodicKeyFrames: false, maxFrameDelayCount: delay) })
                defer { _ = encoder.release() }
                let name = "\(item.name) delay=\(String(describing: delay))"
                XCTAssertEqual(encoder.startEncode(with: settings(item.codec), numberOfCores: 1), 0, "\(name) stage=\(encoder.lastStage) status=\(encoder.lastStatus)")
                if delay == nil {
                    XCTAssertEqual(encoder.optionsEvidence, "requested keys only", name)
                } else {
                    // The M4's hardware encoders report the property read-only (3) or omit it (low-latency
                    // H.264): a rejection is recorded and never fails the session.
                    XCTAssertTrue(["requested keys only · max frame delay 1", "requested keys only · max frame delay rejected"]
                        .contains(encoder.optionsEvidence ?? ""), "\(name): \(encoder.optionsEvidence ?? "nil")")
                }
                XCTAssertEqual(try encodedKeys(encoder, count: 8, frameSpacingNs: 16_666_667, heldFrames: delay ?? 0), [0], name)
            }
        }
        XCTAssertNil(OwnedEncoderOptions(StreamTuning.tuned).maxFrameDelayCount)
        var tuning = StreamTuning.tuned
        tuning.encoderMaxFrameDelay = 1
        XCTAssertEqual(OwnedEncoderOptions(tuning).maxFrameDelayCount, 1)
    }

    // MARK: Item 15 — capture queue depth

    func testTheQueueDepthOverrideAppliesAtSixtyAndBelowOnly() {
        var tuning = StreamTuning.tuned
        for fps in [30, 60, 120] {
            XCTAssertEqual(RemoteCaptureConfiguration.queueDepth(fps: fps, tuning: tuning), CaptureRatePolicy.queueDepth(for: fps), "today at \(fps)")
        }
        tuning.captureQueueDepth = 3
        XCTAssertEqual(RemoteCaptureConfiguration.queueDepth(fps: 30, tuning: tuning), 3)
        XCTAssertEqual(RemoteCaptureConfiguration.queueDepth(fps: 60, tuning: tuning), 3)
        XCTAssertEqual(RemoteCaptureConfiguration.queueDepth(fps: 120, tuning: tuning), 8, "above 60 a burst still needs the deep queue")
        let output = CapturePixelDimensions(width: 1920, height: 1242)
        let crop = CaptureRegion(epoch: 3, x: 400, y: 200, width: 480, height: 1024, outputWidth: 480, outputHeight: 1024)
        for region in [nil, crop] {
            let configured = RemoteCaptureConfiguration.streamConfiguration(output: output, region: region, showsCursor: true, fps: 60,
                                                                            displayRefreshHz: 60, tuning: tuning)
            XCTAssertEqual(configured.queueDepth, 3)
            let today = RemoteCaptureConfiguration.streamConfiguration(output: output, region: region, showsCursor: true, fps: 60,
                                                                       displayRefreshHz: 60, tuning: .tuned)
            XCTAssertEqual(today.queueDepth, 5)
        }
    }

    // MARK: Item 16 — capture resolution

    func testCaptureResolutionIsSetOnlyWhenChosen() {
        let output = CapturePixelDimensions(width: 2560, height: 1656)
        XCTAssertEqual(SCStreamConfiguration().captureResolution, .automatic, "ScreenCaptureKit's default")
        var tuning = StreamTuning.tuned
        for (choice, expected) in [(CaptureResolutionChoice.automatic, SCCaptureResolutionType.automatic), (.nominal, .nominal), (.best, .best)] {
            tuning.captureResolution = choice
            let configured = RemoteCaptureConfiguration.streamConfiguration(output: output, region: nil, showsCursor: true, fps: 60,
                                                                            displayRefreshHz: 60, tuning: tuning)
            XCTAssertEqual(configured.captureResolution, expected, choice.rawValue)
        }
    }

    /// The test Mac's "More Space" mode: 1920×1243 pt backed at 2×.
    func testNominalCaptureComputesSizesAndCropsAtOnePixelPerPoint() throws {
        let points = CGSize(width: 1920, height: 1243)
        var cropping = StreamTuning.tuned
        cropping.viewportCapture = true
        var nominal = cropping
        nominal.captureResolution = .nominal
        var best = StreamTuning.tuned
        best.captureResolution = .best
        XCTAssertEqual(RemoteCaptureConfiguration.geometry(contentSize: points, filterScale: 2, tuning: .tuned).pointPixelScale, 2)
        XCTAssertEqual(RemoteCaptureConfiguration.geometry(contentSize: points, filterScale: 2, tuning: best).pointPixelScale, 2)
        let atOne = RemoteCaptureConfiguration.geometry(contentSize: points, filterScale: 2, tuning: nominal)
        XCTAssertEqual(atOne, DisplayGeometry(size: points, pointPixelScale: 1), "points stay points; only the pixel scale changes")
        let atTwo = RemoteCaptureConfiguration.geometry(contentSize: points, filterScale: 2, tuning: .tuned)

        func whole(_ geometry: DisplayGeometry, _ tuning: StreamTuning) throws -> CapturePixelDimensions {
            try XCTUnwrap(RemoteCaptureConfiguration.outputSize(contentSize: geometry.size, pointPixelScale: geometry.pointPixelScale,
                                                                quality: .sharp, budget: nil, fps: 60, clientLongEdge: 2622, tuning: tuning))
        }
        XCTAssertEqual(try whole(atTwo, .tuned), CapturePixelDimensions(width: 2560, height: 1656), "today: a 2/3 downscale of the 3840 backing")
        XCTAssertEqual(try whole(atOne, nominal), CapturePixelDimensions(width: 1920, height: 1242), "never asks for more pixels than the source has")

        // iPhone 17 portrait zoomed to 3 phone px per Mac point: 1206×2622 px shows 402×874 pt.
        let viewport = ViewportRegion(epoch: 7, x: 700, y: 180, width: 402, height: 874, pixelWidth: 1206, pixelHeight: 2622, zoom: 3)
        for (name, geometry, tuning) in [("automatic", atTwo, cropping), ("nominal", atOne, nominal)] {
            let output = try whole(geometry, tuning)
            let crop = ViewportCapturePolicy.region(for: viewport, display: geometry, output: output, tuning: tuning, previous: nil,
                                                    phoneNative: true, nearNative: false)
            XCTAssertNotEqual(crop.epoch, 0, name)
            XCTAssertTrue(crop.rect.contains(viewport.rect), "\(name): the crop covers the visible rect in points")
            XCTAssertTrue(geometry.bounds.contains(crop.rect), name)
            let scale = geometry.pointPixelScale
            XCTAssertEqual(crop.width * scale, (crop.width * scale).rounded(), "\(name): whole source pixels")
            XCTAssertEqual(Int((crop.width * scale).rounded()) % ViewportCapturePolicy.macroblock, 0, name)
            XCTAssertEqual(crop.outputWidth, Int((crop.width * scale).rounded()),
                           "\(name): the phone wants 3 px per point, so the crop streams every source pixel and no more")
            XCTAssertEqual(crop.outputHeight, Int((crop.height * scale).rounded()), name)
            let configured = RemoteCaptureConfiguration.streamConfiguration(output: output, region: crop, showsCursor: true, fps: 60,
                                                                            displayRefreshHz: 60, tuning: tuning)
            XCTAssertEqual(configured.sourceRect, crop.rect, "\(name): sourceRect stays in points")
            XCTAssertEqual(configured.width, crop.outputWidth)
        }
        let gated = ViewportCapturePolicy.region(for: viewport, display: atOne, output: try whole(atOne, nominal), tuning: nominal,
                                                 previous: nil, phoneNative: true, nearNative: true)
        XCTAssertTrue(gated.isWholeDisplay, "at one pixel per point a crop is no denser than the whole display, so the gain gate keeps it")
        let automaticGated = ViewportCapturePolicy.region(for: viewport, display: atTwo, output: try whole(atTwo, .tuned), tuning: cropping,
                                                          previous: nil, phoneNative: true, nearNative: true)
        XCTAssertFalse(automaticGated.isWholeDisplay, "with cropping on, the same zoom crops at the backing scale")
    }

    // MARK: Item 5 — LAN encoding floor

    func testTheEncodingFloorIsOnlyOnATrustedLinkOutsideLowDataAndAtMostHalfTheCeiling() {
        XCTAssertNil(EncodingMinBitrateFloor.bps(kbps: nil, trusted: true, ceilingBps: 25_000_000), "flag unset")
        XCTAssertNil(EncodingMinBitrateFloor.bps(kbps: 8000, trusted: false, ceilingBps: 25_000_000), "untrusted")
        XCTAssertEqual(EncodingMinBitrateFloor.bps(kbps: 8000, trusted: true, ceilingBps: 25_000_000), 8_000_000)
        XCTAssertEqual(EncodingMinBitrateFloor.bps(kbps: 30_000, trusted: true, ceilingBps: 12_000_000), 6_000_000,
                       "at most half the ceiling, so the estimate can still move")
        XCTAssertNil(EncodingMinBitrateFloor.bps(kbps: 8000, trusted: true, ceilingBps: 0))

        XCTAssertNil(EncodingMinBitrateFloor.senderMinimumBps(floorBps: nil, ceilingBps: 25_000_000, lowData: false), "untrusted or unset")
        XCTAssertEqual(EncodingMinBitrateFloor.senderMinimumBps(floorBps: 8_000_000, ceilingBps: 25_000_000, lowData: false), 8_000_000)
        XCTAssertNil(EncodingMinBitrateFloor.senderMinimumBps(floorBps: 8_000_000, ceilingBps: 25_000_000, lowData: true), "never in low-data mode")
        XCTAssertEqual(EncodingMinBitrateFloor.senderMinimumBps(floorBps: 12_500_000, ceilingBps: 12_000_000, lowData: false), 6_000_000,
                       "a quality change to a lower ceiling never leaves min above max")
        for ceiling in [2_500_000, 12_000_000, 25_000_000] {
            for floor in [300_000, 8_000_000, 100_000_000] {
                let minimum = EncodingMinBitrateFloor.senderMinimumBps(floorBps: floor, ceilingBps: ceiling, lowData: false) ?? 0
                XCTAssertLessThan(minimum, ceiling, "libwebrtc rejects a whole setParameters with min above max")
            }
        }

        XCTAssertNil(EncodingMinBitrateFloor.estimateFloorBps(lanFloorBps: nil, encodingFloorBps: nil))
        XCTAssertEqual(EncodingMinBitrateFloor.estimateFloorBps(lanFloorBps: 10_000_000, encodingFloorBps: nil), 10_000_000, "today")
        XCTAssertEqual(EncodingMinBitrateFloor.estimateFloorBps(lanFloorBps: 10_000_000, encodingFloorBps: 8_000_000), 10_000_000)
        XCTAssertEqual(EncodingMinBitrateFloor.estimateFloorBps(lanFloorBps: 6_000_000, encodingFloorBps: 8_000_000), 8_000_000)
        XCTAssertEqual(EncodingMinBitrateFloor.estimateFloorBps(lanFloorBps: nil, encodingFloorBps: 8_000_000), 8_000_000,
                       "the estimate floor follows the encoder floor even with the LAN floor switched off")
    }

    @MainActor
    func testTodaysSenderCarriesNoEncodingMinimum() async throws {
        let host = PeerMedia(isHost: true, servers: [])
        let phone = PeerMedia(isHost: false, servers: [])
        defer { host.close(); phone.close() }
        host.onSignal = { [weak phone] in phone?.receive($0) }
        phone.onSignal = { [weak host] in host?.receive($0) }
        var connected = false
        host.onState = { if $0 == "connected" { connected = true } }
        host.offer()
        let deadline = Date().addingTimeInterval(15)
        while !connected, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(connected)
        XCTAssertNotNil(host.appliedSenderMaxKbps)
        if host.tuning.encodingMinBitrateLANKbps == nil {
            XCTAssertNil(host.appliedSenderMinKbps, "flag unset: the encoding minimum is never touched")
        }
        XCTAssertNil(phone.appliedSenderMinKbps, "the phone does not send video")
    }
}
