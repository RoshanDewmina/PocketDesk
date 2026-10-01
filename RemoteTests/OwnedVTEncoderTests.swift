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

    // X04: the owned encoder honours the compatibility encoder's newest-frame-wins policy.
    func testLimitOneDropsANewDeltaWhileADeltaIsInFlight() {
        var gate = EncoderInFlightGate<Int>(limit: 1)
        XCTAssertEqual(gate.admit(key: false, enabled: true, now: 0), .submit(retired: 0, superseded: 0))
        gate.submitted(1, entry: 1, at: 0)
        XCTAssertEqual(gate.admit(key: false, enabled: true, now: 10), .drop)
        XCTAssertEqual(gate.admit(key: false, enabled: true, now: 99), .drop)
        XCTAssertEqual(gate.complete(1), 1)
        XCTAssertEqual(gate.admit(key: false, enabled: true, now: 100), .submit(retired: 0, superseded: 0))
        XCTAssertEqual(gate.counts.droppedByLimit, 2)
        XCTAssertEqual(gate.counts.superseded, 0)
    }

    func testKeyFrameRequestIsNeverDroppedAndSupersedesTheInFlightDelta() {
        var gate = EncoderInFlightGate<Int>(limit: 1)
        gate.submitted(1, entry: 1, at: 0)
        let decision = gate.admit(key: true, enabled: true, now: 5)
        XCTAssertEqual(decision, .submit(retired: 0, superseded: 1))
        XCTAssertTrue(decision.discards, "the caller must make the replacement independent")
        gate.submitted(2, entry: 2, at: 5)
        XCTAssertNil(gate.complete(1), "the superseded delta's output is discarded")
        XCTAssertEqual(gate.complete(2), 2)
        XCTAssertEqual(gate.counts.lateCallbacksIgnored, 1)
        XCTAssertEqual(gate.counts.droppedByLimit, 0)
        var limitTwo = EncoderInFlightGate<Int>(limit: 2)
        limitTwo.submitted(1, entry: 1, at: 0)
        XCTAssertEqual(limitTwo.admit(key: true, enabled: true, now: 1), .submit(retired: 0, superseded: 0),
                       "below the limit a key frame supersedes nothing")
    }

    func testStalledCallbackRetiresAfterTheWindowAndItsLateCallbackIsIgnored() {
        var gate = EncoderInFlightGate<Int>(limit: 1)
        gate.submitted(1, entry: 1, at: 0)
        XCTAssertEqual(gate.admit(key: false, enabled: true, now: 100), .drop, "100 ms is still inside the window")
        let retired = gate.admit(key: false, enabled: true, now: 100.5)
        XCTAssertEqual(retired, .submit(retired: 1, superseded: 0))
        XCTAssertTrue(retired.discards)
        gate.submitted(2, entry: 2, at: 100.5)
        XCTAssertNil(gate.complete(1), "a late callback after retirement is ignored")
        XCTAssertNil(gate.complete(1), "and counted once")
        XCTAssertEqual(gate.counts.retiredByTimeout, 1)
        XCTAssertEqual(gate.counts.lateCallbacksIgnored, 1)
        XCTAssertEqual(gate.inFlight, 1)
        XCTAssertEqual(gate.admit(key: false, enabled: true, now: 400), .drop,
                       "a second stall retires at most once per spacing, so retirement cannot become a key-frame storm")
        XCTAssertEqual(gate.admit(key: false, enabled: true, now: 1_100.5), .submit(retired: 1, superseded: 0))
        XCTAssertEqual(gate.counts.retiredByTimeout, 2)
    }

    func testKillSwitchOrNoLimitRestoresUnlimitedSubmission() {
        var off = EncoderInFlightGate<Int>(limit: 1)
        var unlimited = EncoderInFlightGate<Int>(limit: nil)
        for id in 1...5 {
            XCTAssertEqual(off.admit(key: false, enabled: false, now: Double(id)), .submit(retired: 0, superseded: 0))
            off.submitted(UInt64(id), entry: id, at: Double(id))
            XCTAssertEqual(unlimited.admit(key: false, enabled: true, now: Double(id)), .submit(retired: 0, superseded: 0))
            unlimited.submitted(UInt64(id), entry: id, at: Double(id))
        }
        XCTAssertEqual(off.inFlight, 5)
        XCTAssertEqual(unlimited.inFlight, 5)
        XCTAssertEqual(off.counts.droppedByLimit + unlimited.counts.droppedByLimit, 0)
        XCTAssertEqual(off.admit(key: false, enabled: false, now: 200), .submit(retired: 5, superseded: 0),
                       "the switch removes the limit, not the lost-callback fallback")
    }

    func testCountersSeparateSubmittedDroppedSupersededRetiredAndAccepted() {
        var gate = EncoderInFlightGate<Int>(limit: 1)
        gate.submitted(1, entry: 1, at: 0)
        _ = gate.admit(key: false, enabled: true, now: 1)
        _ = gate.admit(key: true, enabled: true, now: 2)
        gate.submitted(2, entry: 2, at: 2)
        if gate.complete(2) != nil { gate.accepted() }
        gate.submitted(3, entry: 3, at: 3)
        gate.cancel(3)
        gate.submitted(4, entry: 4, at: 4)
        _ = gate.admit(key: false, enabled: true, now: 200)
        if gate.complete(1) != nil { gate.accepted() }
        if gate.complete(4) != nil { gate.accepted() }
        XCTAssertEqual(gate.counts, EncoderInFlightCounts(submitted: 3, droppedByLimit: 1, superseded: 1,
                                                          retiredByTimeout: 1, lateCallbacksIgnored: 2, accepted: 1))
        gate.reset()
        XCTAssertEqual(gate.inFlight, 0)
        XCTAssertNil(gate.complete(4), "a reset forgets discarded ids without counting them")
        XCTAssertEqual(gate.counts.lateCallbacksIgnored, 2)

        let counters = StreamCounters()
        counters.encoderSubmitted(); counters.encoderSubmitted()
        counters.encoderSuperseded(1); counters.encoderRetired(1); counters.encoderOutput()
        var snapshot = counters.drain(inputBufferedBytes: nil)
        snapshot.interval = 1
        let sample = StreamStatsSample(entries: [])
        let report = StreamStatsReport(role: "host", previous: sample, current: sample, counters: snapshot)
        XCTAssertEqual([report.encoderSubmitted, report.encoderSuperseded, report.encoderRetired, report.encoderOutputs], [2, 1, 1, 1])
        let summary = report.hostSummary
        XCTAssertNoThrow(try summary.validate())
        XCTAssertEqual(try JSONDecoder().decode(HostStreamSummary.self, from: JSONEncoder().encode(summary)), summary)
        XCTAssertTrue(report.summaryLines.contains("VT in 2 out 1 · superseded 1 · retired 1"), report.summaryLines.joined(separator: "\n"))
        XCTAssertNil(counters.drain(inputBufferedBytes: nil).encoderSubmitted, "each sample counts its own window")
    }

    func testOwnedEncoderSubmitsRequestedKeyFramesAtTheLimitAndCountsOutputs() throws {
        let configuration = try XCTUnwrap(OwnedVTConfiguration(parameters: ["profile-level-id": "640034", "packetization-mode": "1"]))
        for switchOn in [true, false] {
            let counters = StreamCounters()
            let encoder = OwnedVTEncoder(configuration: configuration, counters: counters, inFlightLimit: { 1 },
                                         newestFrameWins: { switchOn }, clock: { 0 })
            defer { _ = encoder.release() }
            let settings = RTCVideoEncoderSettings()
            settings.width = 256; settings.height = 128; settings.startBitrate = 4000
            settings.maxBitrate = 4000; settings.maxFramerate = 60; settings.qpMax = 30
            settings.name = "H264"; settings.mode = .screensharing
            let started = encoder.startEncode(with: settings, numberOfCores: 1)
            XCTAssertEqual(started, 0, "VT stage=\(encoder.lastStage) status=\(encoder.lastStatus)")
            guard started == 0 else { return }
            let outputs = NSLock(); var delivered = 0
            encoder.setCallback { _, _ in outputs.lock(); delivered += 1; outputs.unlock(); return true }
            let key = [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]
            for index in 0..<3 {
                let frame = try Self.frame(timeStampNs: 1_000_000_000 + Int64(index) * 16_666_667)
                XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: switchOn ? key : []), 0)
            }
            let drained = expectation(description: "VideoToolbox callbacks drained")
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { drained.fulfill() }
            wait(for: [drained], timeout: 3)
            let counts = encoder.inFlightCounts
            XCTAssertEqual(counts.submitted, 3, "a requested key frame is never dropped; with the switch off nothing is")
            XCTAssertEqual(counts.droppedByLimit, 0)
            outputs.lock(); let received = delivered; outputs.unlock()
            XCTAssertEqual(counts.accepted, received, "accepted counts only callbacks that produced a sample")
            XCTAssertEqual(counts.retiredByTimeout, 0)
            XCTAssertLessThanOrEqual(counts.accepted + counts.lateCallbacksIgnored, 3)
            XCTAssertGreaterThan(counts.accepted, 0)
            if !switchOn { XCTAssertEqual(counts.superseded, 0, "no limit, nothing superseded") }
        }
    }

    private static func frame(timeStampNs: Int64) throws -> RTCVideoFrame {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 256, 128, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        memset(base, 128, CVPixelBufferGetBytesPerRow(pixelBuffer) * 128)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: timeStampNs)
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
