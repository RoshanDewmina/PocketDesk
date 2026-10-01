import XCTest
import CoreVideo
import WebRTC

final class ExactVideoTimingTests: XCTestCase {
    private let generation = String(repeating: "a", count: 32)
    private let nonce = String(repeating: "b", count: 32)
    private func timing(resend: Bool = false) -> ExactVideoTiming {
        ExactVideoTiming(sourceID: String(repeating: "c", count: 32), displayMs: 1_000, capturedMs: 1_002,
                         pushedMs: 1_003, submittedMs: 1_005, encodedMs: 1_010, resend: resend)
    }
    func testPresentationRequiresTheSameSuccessfullyDecodedAccessUnitAndCannotReplay() {
        let receiver = ExactVideoTimingReceiver(), value = timing()
        let clock = ClockSyncEstimate(offsetMs: 100, uncertaintyMs: 2, samples: 3)
        receiver.presented(value, generation: generation, nonce: nonce, atMs: 950, clock: clock, clockRecordedAtMs: 900, nowMs: 960)
        XCTAssertEqual(receiver.drain().presented, 0)
        receiver.decoded(value, generation: generation, nonce: nonce, atMs: 930)
        receiver.presented(value, generation: generation, nonce: nonce, atMs: 950, clock: clock, clockRecordedAtMs: 900, nowMs: 960)
        let report = receiver.drain()
        XCTAssertEqual(report.uniqueSources, 1); XCTAssertEqual(report.timed, 1)
        XCTAssertEqual(report.captureToDecodeP50Ms, 30); XCTAssertEqual(report.captureToPresentP95Ms, 50)
        XCTAssertEqual(report.maximumClockUncertaintyMs, 2)
        receiver.decoded(value, generation: generation, nonce: nonce, atMs: 970)
        receiver.presented(value, generation: generation, nonce: nonce, atMs: 980, clock: clock, clockRecordedAtMs: 900, nowMs: 990)
        XCTAssertEqual(receiver.drain().presented, 0)
    }
    func testReencodedSameSourceAndIdleResendNeverInflateUniqueCadence() {
        let receiver = ExactVideoTimingReceiver()
        for (index, resend) in [false, false, true].enumerated() {
            let n = String(format: "%032x", index), value = timing(resend: resend)
            receiver.decoded(value, generation: generation, nonce: n, atMs: 930)
            receiver.presented(value, generation: generation, nonce: n, atMs: 950, clock: nil, clockRecordedAtMs: nil, nowMs: 960)
        }
        let report = receiver.drain()
        XCTAssertEqual(report.presented, 3); XCTAssertEqual(report.uniqueSources, 1)
        XCTAssertEqual(report.resends, 1); XCTAssertEqual(report.missingClock, 2)
        XCTAssertNil(report.captureToPresentP50Ms)
    }
    func testStaleFutureAndNonfiniteClockMappingsRemainUnknown() {
        for (offset, uncertainty, recorded) in [(100.0, 1.0, 100.0), (100, 1, 40_001), (.infinity, 1, 39_000), (100, .nan, 39_000)] {
            let receiver = ExactVideoTimingReceiver(), value = timing()
            receiver.decoded(value, generation: generation, nonce: nonce, atMs: 39_900)
            receiver.presented(value, generation: generation, nonce: nonce, atMs: 39_950,
                clock: ClockSyncEstimate(offsetMs: offset, uncertaintyMs: uncertainty, samples: 1), clockRecordedAtMs: recorded, nowMs: 40_000)
            let report = receiver.drain(); XCTAssertEqual(report.timed, 0); XCTAssertEqual(report.missingClock, 1)
        }
    }
    func testResetAndMismatchedPayloadCannotCompleteOldMeasurements() {
        let receiver = ExactVideoTimingReceiver(), value = timing()
        receiver.decoded(value, generation: generation, nonce: nonce, atMs: 930)
        receiver.reset()
        receiver.presented(value, generation: generation, nonce: nonce, atMs: 950, clock: nil, clockRecordedAtMs: nil, nowMs: 960)
        XCTAssertEqual(receiver.drain().presented, 0)
        receiver.decoded(value, generation: generation, nonce: nonce, atMs: 930)
        var different = value; different.encodedMs += 1
        receiver.presented(different, generation: generation, nonce: nonce, atMs: 950, clock: nil, clockRecordedAtMs: nil, nowMs: 960)
        XCTAssertEqual(receiver.drain().presented, 0)
    }
    func testMalformedStagesAndIDsNeverEnterTimingLog() {
        var value = timing(); value.submittedMs = 999
        XCTAssertThrowsError(try value.validate())
        value = timing(); value.encodedMs = .nan
        let receiver = ExactVideoTimingReceiver()
        receiver.decoded(value, generation: generation, nonce: nonce, atMs: 930)
        receiver.decoded(timing(), generation: "bad", nonce: nonce, atMs: 930)
        XCTAssertEqual(receiver.drain().decoded, 0)
    }
}


final class ExactVideoTimingWireTests: XCTestCase {
    private func pixels() throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &value), kCVReturnSuccess)
        return try XCTUnwrap(value)
    }
    private func timing(atMs now: Double) -> ExactVideoTiming {
        ExactVideoTiming(sourceID: String(repeating: "c", count: 32), displayMs: now - 20, capturedMs: now - 18,
            pushedMs: now - 15, submittedMs: now - 10, encodedMs: now - 5, resend: false)
    }
    private func tag(_ timing: ExactVideoTiming) -> VideoFrameTag {
        VideoFrameTag(generation: String(repeating: "a", count: 32), nonce: String(repeating: "b", count: 32),
            geometryEpoch: 7, scopeEpoch: 3, ltrToken: nil, timing: timing)
    }
    private func output(_ context: VideoFeedbackContext, _ tag: VideoFrameTag) throws -> RTCVideoFrame {
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try pixels()), rotation: ._0, timeStampNs: 1_000_000)
        frame.timeStamp = 42
        context.received(tag, wire: 42); context.decoded(frame)
        XCTAssertEqual(context.tag(for: frame), tag)
        return frame
    }
    func testActualCaptureTicksRepeatAndResendKeepSourceIdentityButNewCaptureChangesIt() throws {
        var source = CaptureSourceTiming()
        let ticks = mach_absolute_time(), now = MachClock.nowMs()
        let first = try XCTUnwrap(source.captured(displayTicks: ticks, atMs: now))
        let repeated = try XCTUnwrap(source.captured(displayTicks: ticks, atMs: now + 1))
        XCTAssertEqual(first.sourceID, repeated.sourceID)
        let resend = try XCTUnwrap(source.resent())
        XCTAssertEqual(resend.sourceID, first.sourceID); XCTAssertTrue(resend.resend)
        XCTAssertEqual(resend.displayMs, repeated.displayMs); XCTAssertEqual(resend.capturedMs, repeated.capturedMs)
        XCTAssertNotEqual(try XCTUnwrap(source.captured(displayTicks: ticks + 1, atMs: now + 1)).sourceID, first.sourceID)
        source.reset(); XCTAssertNil(source.resent())
        XCTAssertNil(source.captured(displayTicks: 0, atMs: now)); XCTAssertNil(source.resent())
        XCTAssertNil(source.captured(displayTicks: ticks, atMs: now + 10_001))
    }
    func testHostMappingRejectsBorrowedBufferReuseUnknownAndExpiredInsteadOfGuessing() throws {
        let log = HostExactVideoTimingLog(), buffer = try pixels(), other = try pixels()
        let value = timing(atMs: 1_000)
        log.pushed(value, buffer: buffer, atMs: 1_000)
        XCTAssertNil(log.submitted(buffer: other, atMs: 1_001))
        let mapped = try XCTUnwrap(log.submitted(buffer: buffer, atMs: 1_002))
        XCTAssertEqual(mapped.pushedMs, 1_000); XCTAssertEqual(mapped.submittedMs, 1_002)
        XCTAssertEqual(mapped.sourceID, value.sourceID)
        log.pushed(value, buffer: buffer, atMs: 1_010); log.pushed(value, buffer: buffer, atMs: 1_011)
        XCTAssertNil(log.submitted(buffer: buffer, atMs: 1_012))
        log.pushed(value, buffer: buffer, atMs: 1_013)
        XCTAssertEqual(try XCTUnwrap(log.submitted(buffer: buffer, atMs: 1_014)).pushedMs, 1_013, "A consumed quarantine does not poison the next push")
        let recycled = ExactVideoTiming(sourceID: String(repeating: "d", count: 32), displayMs: 1_020, capturedMs: 1_021,
            pushedMs: 1_022, submittedMs: 1_022, encodedMs: 1_022, resend: false)
        log.pushed(value, buffer: buffer, atMs: 1_030); log.pushed(recycled, buffer: buffer, atMs: 1_031)
        XCTAssertEqual(try XCTUnwrap(log.submitted(buffer: buffer, atMs: 1_032)).sourceID, recycled.sourceID, "A recycled buffer carries its newer source")
        XCTAssertNil(log.submitted(buffer: buffer, atMs: 1_033))
        log.reset(); log.pushed(value, buffer: buffer, atMs: 1_020)
        XCTAssertNil(log.submitted(buffer: buffer, atMs: 6_021))
        log.reset(); XCTAssertNil(log.submitted(buffer: buffer, atMs: 6_022))
    }
    func testStaleIdleResendKeepsOriginAndOmitsExpiredTimingWithoutInventingCadence() throws {
        var capture = CaptureSourceTiming()
        let ticks = mach_absolute_time(), now = MachClock.nowMs()
        let original = try XCTUnwrap(capture.captured(displayTicks: ticks, atMs: now))
        let idle = try XCTUnwrap(capture.resent())
        XCTAssertEqual(idle.sourceID, original.sourceID); XCTAssertEqual(idle.displayMs, original.displayMs)
        let log = HostExactVideoTimingLog(), buffer = try pixels()
        log.pushed(idle, buffer: buffer, atMs: now + 10_001)
        XCTAssertNil(log.submitted(buffer: buffer, atMs: now + 10_002), "No old source timestamps refreshed to pass timing bound")
    }
    func testTimingOnlyNegotiationDoesNotNeedLTROrRefinementAndMarkerIsBounded() throws {
        let context = VideoFeedbackContext()
        context.configure(allowed: true, ltr: false, refinement: false, timing: true, geometry: 7, scope: 3)
        XCTAssertFalse(context.permitsLTR)
        let buffer = try pixels(), now = MachClock.nowMs()
        context.pushedTiming(timing(atMs: now), buffer: buffer)
        let mapped = try XCTUnwrap(context.submittedTiming(buffer: buffer, atMs: MachClock.nowMs()))
        var value = try XCTUnwrap(context.encoded(token: nil)); value.timing = mapped
        for hevc in [false, true] {
            let encoded = try XCTUnwrap(H26xVideoMarker.append(value, to: Data([0,0,0,1,0x65,0x80]), hevc: hevc))
            XCTAssertEqual(H26xVideoMarker.read(encoded, hevc: hevc), value)
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(value).count, 1024)
        }
        context.configure(allowed: true, ltr: true, refinement: true, timing: false, geometry: 7, scope: 3)
        context.pushedTiming(timing(atMs: now), buffer: buffer)
        XCTAssertNil(context.submittedTiming(buffer: buffer, atMs: MachClock.nowMs()))
        XCTAssertNil(context.drainTiming(), "Other negotiated video features do not grant timing")
        XCTAssertNil(context.encoded(token: nil, expected: value), "Capability transition retires the old generation")
    }
    func testReceiverRejectsOversizedUnknownJSONEvenWhenKnownFieldsValidate() throws {
        let value = tag(timing(atMs: MachClock.nowMs()))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object["unknownFutureField"] = String(repeating: "x", count: 1_100)
        let json = try JSONSerialization.data(withJSONObject: object)
        XCTAssertGreaterThan(json.count, H26xVideoMarker.maximumJSONBytes)
        XCTAssertLessThan(json.count, 2_000)
        let identifier: [UInt8] = [0x46,0x41,0x52,0x53,0x49,0x44,0x45,0x56,0x49,0x44,0x45,0x4f,0x30,0x30,0x30,0x31]
        var rbsp: [UInt8] = [5], size = json.count + identifier.count
        while size >= 255 { rbsp.append(255); size -= 255 }; rbsp.append(UInt8(size))
        rbsp += identifier; rbsp += json; rbsp.append(0x80)
        var escaped: [UInt8] = [], zeros = 0
        for byte in rbsp {
            if zeros >= 2 && byte <= 3 { escaped.append(3); zeros = 0 }
            escaped.append(byte); zeros = byte == 0 ? zeros + 1 : 0
        }
        for header: [UInt8] in [[6], [0x4e,1]] {
            let hevc = header.count == 2
            let oversized = Data([0,0,0,1] + header + escaped + [0,0,0,1,0x65,0x80])
            XCTAssertNil(H26xVideoMarker.read(oversized, hevc: hevc), "Own SEI JSON must respect the same receive bound")
        }
    }
    func testPublicPresentationAdapterRejectsInterpolationRedrawUnknownTimeReplayAndRetirement() throws {
        let context = VideoFeedbackContext()
        context.configure(allowed: true, ltr: false, timing: true, geometry: 7, scope: 3)
        let now = MachClock.nowMs(), value = tag(timing(atMs: now))
        let frame = try output(context, value)
        withExtendedLifetime(frame) {
            let publicSeconds = (MachClock.nowMs() + 1) / 1000
            let clock = ClockSyncEstimate(offsetMs: 0, uncertaintyMs: 2, samples: 3)
            for (original, new, time) in [(false, true, publicSeconds), (true, false, publicSeconds), (true, true, 0.0), (true, true, Double.nan)] {
                context.presentedTiming(value, originalSource: original, newSubmission: new, presentedTime: time,
                    clock: clock, observedAtMs: now, nowMs: publicSeconds * 1000 + 1)
            }
            XCTAssertEqual(context.drainTiming()?.presented, 0)
            context.presentedTiming(value, originalSource: true, newSubmission: true, presentedTime: publicSeconds,
                clock: clock, observedAtMs: now, nowMs: publicSeconds * 1000 + 1)
            let report = context.drainTiming()
            XCTAssertEqual(report?.presented, 1); XCTAssertEqual(report?.uniqueSources, 1); XCTAssertEqual(report?.timed, 1)
            XCTAssertEqual(report?.maximumClockUncertaintyMs, 2)
            context.presentedTiming(value, originalSource: true, newSubmission: true, presentedTime: publicSeconds,
                clock: clock, observedAtMs: now, nowMs: publicSeconds * 1000 + 1)
            XCTAssertEqual(context.drainTiming()?.presented, 0)
        }
        context.beginDecoder()
        context.presentedTiming(value, originalSource: true, newSubmission: true, presentedTime: MachClock.nowMs()/1000,
            clock: nil, observedAtMs: nil)
        XCTAssertEqual(context.drainTiming()?.presented, 0)
        context.end(); XCTAssertNil(context.drainTiming())
    }
    func testContextGeometryScopeDecoderRestartAndEndRetireSuccessfullyDecodedPendingAU() throws {
        for retirement in 0..<4 {
            let context = VideoFeedbackContext()
            context.configure(allowed: true, ltr: false, timing: true, geometry: 7, scope: 3)
            let value = tag(timing(atMs: MachClock.nowMs())), frame = try output(context, value)
            withExtendedLifetime(frame) {
                switch retirement {
                case 0:
                    context.configure(allowed: false, ltr: false, timing: true, geometry: 7, scope: 3)
                    context.configure(allowed: true, ltr: false, timing: true, geometry: 7, scope: 3)
                case 1: context.configure(allowed: true, ltr: false, timing: true, geometry: 8, scope: 4)
                case 2: context.beginDecoder()
                default: context.end()
                }
                XCTAssertNil(context.tag(for: frame))
                let shown = MachClock.nowMs() + 1
                context.presentedTiming(value, originalSource: true, newSubmission: true, presentedTime: shown / 1000,
                    clock: ClockSyncEstimate(offsetMs: 0, uncertaintyMs: 1, samples: 1), observedAtMs: shown - 1, nowMs: shown + 1)
                XCTAssertEqual(context.drainTiming()?.presented ?? 0, 0, "Retirement cannot complete an old successful decode")
            }
        }
    }
    func testClockObservationIsSelectedSampleTimeAndStaleMappingNeverProducesLatency() throws {
        var estimator = ClockSyncEstimator()
        estimator.sent(phoneMs: 1_000)
        XCTAssertTrue(estimator.record(ClockProbe(phoneMs: 1_000, hostReceivedMs: 1_105, hostSentMs: 1_105), receivedAtPhoneMs: 1_010))
        estimator.sent(phoneMs: 20_000)
        XCTAssertTrue(estimator.record(ClockProbe(phoneMs: 20_000, hostReceivedMs: 20_150, hostSentMs: 20_150), receivedAtPhoneMs: 20_100))
        XCTAssertEqual(estimator.observation(now: 20_100)?.atMs, 1_010, "Reading a cached lowest-RTT estimate does not freshen it")
        XCTAssertEqual(estimator.observation(now: 32_000)?.atMs, 20_100)
        XCTAssertNil(estimator.observation(now: 60_101))
        let context = VideoFeedbackContext()
        context.configure(allowed: true, ltr: false, timing: true, geometry: 7, scope: 3)
        let now = MachClock.nowMs(), value = tag(timing(atMs: now)), frame = try output(context, value)
        withExtendedLifetime(frame) {
            let presented = MachClock.nowMs() + 1
            context.presentedTiming(value, originalSource: true, newSubmission: true, presentedTime: presented / 1000,
                clock: ClockSyncEstimate(offsetMs: 0, uncertaintyMs: 2, samples: 3), observedAtMs: now - 30_001, nowMs: presented + 1)
            let report = context.drainTiming()
            XCTAssertEqual(report?.presented, 1); XCTAssertEqual(report?.missingClock, 1)
            XCTAssertEqual(report?.timed, 0); XCTAssertNil(report?.captureToPresentP50Ms)
        }
    }
    func testFullCaptureAndPhoneHandshakeNegotiateTimingWithinHistoricalBounds() throws {
        let handshake = MacShareBlocker.Handshake.phone
        XCTAssertEqual(handshake.features, [MacShareBlocker.feature, MacShareBlocker.approvalFeature, SessionFeature.extendedFeatureList,
                                            SessionFeature.causalInput, SessionFeature.pencilInput, SessionFeature.videoLTR, SessionFeature.exactVideoTiming])
        let everyOptIn = MacShareBlocker.Handshake.phoneRequest(StillTextPreferences.requestedFeatures(sharpen: true, textClarity: true, fullColor: false))
        XCTAssertLessThanOrEqual(everyOptIn.features.count, 8, "Every opt-in on still leaves the feature list inside an earlier Mac's bound")
        XCTAssertTrue(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(everyOptIn)).isSuperset(of: handshake.features))
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(handshake)), Set(handshake.features))
        let overflow = MacShareBlocker.Handshake(features: handshake.features + ["video.ninth.1"])
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(overflow)), [], "A ninth phone feature needs a post-handshake exchange, not this list")
        let modern = HostFeatureList.features(base: SessionFeature.host, allowBigText: true, accessibility: true,
            peerFeatures: Set(handshake.features), requestedMode: .picture)
        XCTAssertTrue(modern.contains(SessionFeature.exactVideoTiming)); XCTAssertLessThanOrEqual(modern.count, 32)
        let action = RemoteAction(action: "capture", features: modern)
        try action.validate()
        XCTAssertEqual(try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(action)).features, modern)
        let old = HostFeatureList.features(base: SessionFeature.host, allowBigText: true, accessibility: true,
            peerFeatures: [], requestedMode: .picture)
        XCTAssertLessThanOrEqual(old.count, 16); XCTAssertFalse(old.contains(SessionFeature.exactVideoTiming))
    }
}
