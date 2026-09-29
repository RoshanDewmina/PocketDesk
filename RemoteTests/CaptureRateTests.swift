import XCTest
import CoreMedia
import WebRTC

final class CaptureRatePolicyTests: XCTestCase {
    private func target(_ hz: Double?, _ tuning: StreamTuning = .tuned) -> Int {
        CaptureRatePolicy.targetFPS(displayRefreshHz: hz, tuning: tuning)
    }

    func testTargetRateFollowsTheDisplayOnlyFromOneHundredHertz() {
        XCTAssertEqual(target(nil), 60, "an unknown rate stays at 60")
        XCTAssertEqual(target(0), 60)
        XCTAssertEqual(target(59.94), 60)
        XCTAssertEqual(target(60), 60)
        XCTAssertEqual(target(99.9), 60)
        XCTAssertEqual(target(100), 120)
        XCTAssertEqual(target(120), 120)
        XCTAssertEqual(target(144), 120, "a 144 Hz panel is streamed at 120, never 144")

        var off = StreamTuning.tuned
        off.highRefreshCapture = false
        XCTAssertEqual(target(144, off), 60)
        XCTAssertEqual(target(120, off), 60)
    }

    func testOverrideWinsInsideItsRangeEvenWithTheSwitchOff() {
        var tuning = StreamTuning.tuned
        tuning.targetFPSOverride = 90
        XCTAssertEqual(target(60, tuning), 90)
        XCTAssertEqual(target(nil, tuning), 90)
        tuning.highRefreshCapture = false
        XCTAssertEqual(target(144, tuning), 90, "the override is checked before the switch")
        tuning.targetFPSOverride = 30
        XCTAssertEqual(target(144, tuning), 30)
        tuning.targetFPSOverride = 120
        XCTAssertEqual(target(60, tuning), 120, "forces the 120 path on a 60 Hz panel")
        tuning.highRefreshCapture = true
        tuning.targetFPSOverride = 144
        XCTAssertEqual(target(144, tuning), 120, "an override outside 30…120 is ignored")
        tuning.targetFPSOverride = 29
        XCTAssertEqual(target(60, tuning), 60)
    }

    func testQueueDepthDeepensAboveSixty() {
        XCTAssertEqual(CaptureRatePolicy.queueDepth(for: 30), 5)
        XCTAssertEqual(CaptureRatePolicy.queueDepth(for: 60), 5)
        XCTAssertEqual(CaptureRatePolicy.queueDepth(for: 60), RemoteCaptureConfiguration.queueDepth)
        XCTAssertEqual(CaptureRatePolicy.queueDepth(for: 61), 8)
        XCTAssertEqual(CaptureRatePolicy.queueDepth(for: 120), 8)
    }

    func testLongEdgeByQualityRateAndClientCap() {
        func cap(_ quality: StreamQuality, _ fps: Int, _ client: Int?, _ tuning: StreamTuning = .tuned) -> Int {
            CaptureRatePolicy.maximumDimension(quality: quality, fps: fps, clientLongEdge: client, tuning: tuning)
        }
        XCTAssertEqual(cap(.sharp, 60, nil), 2560)
        XCTAssertEqual(cap(.sharp, 120, nil), 2048)
        XCTAssertEqual(cap(.balanced, 60, nil), 1920)
        XCTAssertEqual(cap(.balanced, 120, nil), 1600)
        XCTAssertEqual(cap(.sharp, 60, 2622), 2560, "an iPhone 17's 2622 px never raises the cap")
        XCTAssertEqual(cap(.sharp, 120, 2752), 2048)
        XCTAssertEqual(cap(.sharp, 60, 1600), 1600)
        XCTAssertEqual(cap(.balanced, 120, 1280), 1280)
        XCTAssertEqual(cap(.sharp, 60, 640), 640)
        XCTAssertEqual(cap(.sharp, 60, 639), 2560, "a client edge under 640 is ignored")

        var off = StreamTuning.tuned
        off.capToClientPixels = false
        XCTAssertEqual(cap(.sharp, 60, 1600, off), 2560)
        XCTAssertEqual(cap(.balanced, 120, 1280, off), 1600)
    }

    func testLevel52FitDependsOnTheRate() {
        // 2560×1440 is 160×90 = 14,400 macroblocks; × 144 = 2,073,600, exactly the level-5.2 limit.
        XCTAssertTrue(H264LevelPolicy.fits(width: 2560, height: 1440, fps: 60))
        XCTAssertTrue(H264LevelPolicy.fits(width: 2560, height: 1440, fps: 120))
        XCTAssertTrue(H264LevelPolicy.fits(width: 2560, height: 1440, fps: 144))
        XCTAssertFalse(H264LevelPolicy.fits(width: 2560, height: 1456, fps: 144), "one more macroblock row is over")
        // 2560×1656 rounds up to 160×104 = 16,640 macroblocks: 1,996,800 at 120, 2,396,160 at 144.
        XCTAssertTrue(H264LevelPolicy.fits(width: 2560, height: 1656, fps: 120))
        XCTAssertFalse(H264LevelPolicy.fits(width: 2560, height: 1656, fps: 144))
        // 3840×2160 is 32,400 macroblocks: 1,944,000 at 60, twice that at 120.
        XCTAssertTrue(H264LevelPolicy.fits(width: 3840, height: 2160, fps: 60))
        XCTAssertFalse(H264LevelPolicy.fits(width: 3840, height: 2160, fps: 120))
        XCTAssertEqual(H264LevelPolicy.fitsAt60FPS(width: 2560, height: 1656),
                       H264LevelPolicy.fits(width: 2560, height: 1656, fps: 60))
        XCTAssertFalse(H264LevelPolicy.fits(width: 2560, height: 1440, fps: 0))
        XCTAssertFalse(H264LevelPolicy.fits(width: 4112, height: 16, fps: 30), "wider than 4096")
    }

    func testCaptureIntervalAtEachRate() {
        let tuned = StreamTuning.tuned
        var native = StreamTuning.tuned
        native.captureAtNativeRate = true
        let sixtieth = CMTime(value: 1, timescale: 60)
        func interval(_ tuning: StreamTuning, _ fps: Int, _ hz: Double?) -> CMTime {
            RemoteCaptureConfiguration.minimumFrameInterval(for: tuning, targetFPS: fps, displayRefreshHz: hz)
        }
        XCTAssertEqual(RemoteCaptureConfiguration.minimumFrameInterval(for: tuned), sixtieth)
        XCTAssertEqual(interval(tuned, 60, 60), sixtieth)
        XCTAssertEqual(interval(tuned, 60, nil), sixtieth)
        XCTAssertEqual(interval(tuned, 60, 144), sixtieth, "a 60 fps session on a fast panel keeps the 1/60 floor")
        XCTAssertEqual(interval(native, 60, 60), .zero, "G1 at 60")

        XCTAssertEqual(interval(tuned, 120, 120), .zero, "120 on a 120 Hz panel: the display's own cadence")
        XCTAssertEqual(interval(tuned, 120, 121), .zero, "within 1 Hz of the target counts as the target")
        XCTAssertEqual(interval(tuned, 120, 100), .zero)
        XCTAssertEqual(interval(tuned, 120, nil), .zero)
        XCTAssertEqual(interval(tuned, 120, 144), CMTime(value: 1, timescale: 120), "144 Hz thinned to 120 at capture")
        XCTAssertEqual(interval(native, 120, 144), CMTime(value: 1, timescale: 120), "the G1 switch only applies at 60")
        XCTAssertEqual(interval(tuned, 90, 144), CMTime(value: 1, timescale: 90))
        XCTAssertEqual(interval(tuned, 90, 60), .zero)
    }

    func testClientPixelSizeBounds() {
        XCTAssertNoThrow(try PixelSize(width: 1, height: 1).validate())
        XCTAssertNoThrow(try PixelSize(width: 16_384, height: 16_384).validate())
        XCTAssertNoThrow(try PixelSize(width: 2622, height: 1206).validate())
        let bad = [PixelSize(width: 0, height: 100), PixelSize(width: 100, height: 0), PixelSize(width: -1, height: 10),
                   PixelSize(width: 16_385, height: 10), PixelSize(width: 10, height: 16_385)]
        for size in bad { XCTAssertThrowsError(try size.validate(), "\(size)") }
        XCTAssertEqual(PixelSize(width: 1206, height: 2622).longEdge, 2622)

        let pixels = PixelSize(width: 2622, height: 1206)
        XCTAssertNoThrow(try RemoteAction(action: "heartbeat", screenPixels: pixels).validate())
        XCTAssertThrowsError(try RemoteAction(action: "capture", screenPixels: pixels).validate(), "heartbeats only")
        let empty = PixelSize(width: 0, height: 1)
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", screenPixels: empty).validate())
    }
}

final class CaptureRateTuningTests: XCTestCase {
    func testG5G4AndLadderSwitchesResolveFromDefaults() throws {
        let suite = "CaptureRateTuningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let tuned = StreamTuning.resolve(defaults: defaults)
        XCTAssertTrue(tuned.highRefreshCapture)
        XCTAssertNil(tuned.targetFPSOverride)
        XCTAssertTrue(tuned.highRefreshNoAdaptation, "at 120 the app's ladder adapts, not WebRTC")
        XCTAssertTrue(tuned.capToClientPixels)
        XCTAssertTrue(tuned.viewportCapture)
        XCTAssertTrue(tuned.ladder)
        let switchParts = ["60 fps only", "target 90 fps", "webrtc adaptation at 120", "no client cap",
                           "whole-display capture", "no ladder"]
        for part in switchParts { XCTAssertFalse(tuned.summary.contains(part), tuned.summary) }

        defaults.set(false, forKey: StreamTuning.highRefreshCaptureKey)
        defaults.set(90, forKey: StreamTuning.targetFPSKey)
        defaults.set(false, forKey: StreamTuning.highRefreshNoAdaptationKey)
        defaults.set(false, forKey: StreamTuning.capToClientPixelsKey)
        defaults.set(false, forKey: StreamTuning.viewportCaptureKey)
        defaults.set(false, forKey: StreamTuning.ladderKey)
        let switched = StreamTuning.resolve(defaults: defaults)
        XCTAssertFalse(switched.highRefreshCapture)
        XCTAssertEqual(switched.targetFPSOverride, 90)
        XCTAssertFalse(switched.highRefreshNoAdaptation)
        XCTAssertFalse(switched.capToClientPixels)
        XCTAssertFalse(switched.viewportCapture)
        XCTAssertFalse(switched.ladder)
        for part in switchParts { XCTAssertTrue(switched.summary.contains(part), switched.summary) }
        XCTAssertEqual(switched.fieldTrials, StreamTuning.tuned.fieldTrials, "switches never change field trials")

        let overrides: [(Int, Int?)] = [(30, 30), (120, 120), (29, nil), (121, nil), (0, nil)]
        for (value, expected) in overrides {
            defaults.set(value, forKey: StreamTuning.targetFPSKey)
            XCTAssertEqual(StreamTuning.resolve(defaults: defaults).targetFPSOverride, expected, "\(value)")
        }

        XCTAssertEqual(StreamTuning.experimentKeys.count, 14)
        XCTAssertEqual(Set(StreamTuning.experimentKeys).count, 14, "every experiment key is listed once")
        let newKeys = [StreamTuning.highRefreshCaptureKey, StreamTuning.targetFPSKey,
                       StreamTuning.highRefreshNoAdaptationKey, StreamTuning.capToClientPixelsKey,
                       StreamTuning.viewportCaptureKey, StreamTuning.ladderKey]
        for key in newKeys { XCTAssertTrue(StreamTuning.experimentKeys.contains(key), key) }

        defaults.set(true, forKey: StreamTuning.legacyDefaultsKey)
        XCTAssertEqual(StreamTuning.resolve(defaults: defaults), .legacy, "the legacy switch wins")
    }
}

final class SenderRateParametersTests: XCTestCase {
    func testSixtyIsTheTunedPolicyWhateverTheHighRefreshSwitch() {
        for noAdaptation in [false, true] {
            var tuning = StreamTuning.tuned
            tuning.highRefreshNoAdaptation = noAdaptation
            XCTAssertEqual(SenderRateParameters.make(targetFPS: 60, tuning: tuning),
                           SenderRateParameters(maxFramerate: 60, degradationPreference: .maintainResolution))
        }
        XCTAssertEqual(StreamTuning.tuned.degradationPreference, .maintainResolution)
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 60, tuning: .legacy),
                       SenderRateParameters(maxFramerate: 60, degradationPreference: nil),
                       "legacy keeps WebRTC's default")
    }

    func testAboveSixtyTheSwitchTurnsWebRTCAdaptationOff() {
        XCTAssertEqual(RTCDegradationPreference.maintainFramerateAndResolution.rawValue,
                       RTCDegradationPreference.disabled.rawValue, "the M153 header aliases disabled to this case")
        var tuning = StreamTuning.tuned
        tuning.highRefreshNoAdaptation = true
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 120, tuning: tuning),
                       SenderRateParameters(maxFramerate: 120, degradationPreference: .maintainFramerateAndResolution))
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 90, tuning: tuning).degradationPreference,
                       .maintainFramerateAndResolution)
        tuning.highRefreshNoAdaptation = false
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 120, tuning: tuning),
                       SenderRateParameters(maxFramerate: 120, degradationPreference: .maintainResolution))
        var legacy = StreamTuning.legacy
        legacy.highRefreshNoAdaptation = false
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 120, tuning: legacy),
                       SenderRateParameters(maxFramerate: 120, degradationPreference: nil))
    }

    func testTheLadderLowersTheRateButKeepsTheSessionMode() {
        var tuning = StreamTuning.tuned
        tuning.highRefreshNoAdaptation = true
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 120, tuning: tuning, ladderFPS: 60),
                       SenderRateParameters(maxFramerate: 60, degradationPreference: .maintainFramerateAndResolution))
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 120, tuning: tuning, ladderFPS: 30).maxFramerate, 30)
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 120, tuning: tuning, ladderFPS: 240).maxFramerate, 120,
                       "never above the session rate")
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 60, tuning: tuning, ladderFPS: 0).maxFramerate, 1)
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 60, tuning: tuning, ladderFPS: 60),
                       SenderRateParameters.make(targetFPS: 60, tuning: tuning))
    }
}

final class SenderOutputFormatTests: XCTestCase {
    private let level52 = H264FrameBudget.level(52)

    private func format(_ width: Int, _ height: Int, budget: H264FrameBudget?, fps: Int,
                        ladder: LadderState? = nil) -> SenderOutputFormat? {
        SenderOutputFormat.make(width: width, height: height, budget: budget, targetFPS: fps, ladder: ladder)
    }

    func testSixtyWithoutALadderIsTodaysAdaptation() {
        let sizes = [(2560, 1440), (2560, 1664), (3840, 2496), (1920, 1080)]
        for (width, height) in sizes {
            let fitted = level52.fitted(width: width, height: height)
            XCTAssertEqual(format(width, height, budget: level52, fps: 60),
                           SenderOutputFormat(width: fitted.width, height: fitted.height, fps: 60),
                           "\(width)×\(height)")
        }
        let oldPeer = H264FrameBudget.level(31)
        let fitted = oldPeer.fitted(width: 2940, height: 1912)
        XCTAssertEqual(format(2940, 1912, budget: oldPeer, fps: 60),
                       SenderOutputFormat(width: fitted.width, height: fitted.height, fps: 60))
        XCTAssertNil(format(2560, 1440, budget: nil, fps: 60), "no budget and no ladder: frames stay untouched")
    }

    func testTheLevelIsFittedAtTheSessionRate() throws {
        XCTAssertEqual(format(2560, 1664, budget: level52, fps: 120),
                       SenderOutputFormat(width: 2560, height: 1664, fps: 120))
        let fast = try XCTUnwrap(format(2560, 1664, budget: level52, fps: 144))
        XCTAssertEqual(fast.fps, 144)
        XCTAssertLessThan(fast.width, 2560)
        XCTAssertTrue(H264LevelPolicy.fits(width: fast.width, height: fast.height, fps: 144))
        let fitted = level52.fitted(width: 2560, height: 1664, fps: 144)
        XCTAssertEqual(fast, SenderOutputFormat(width: fitted.width, height: fitted.height, fps: 144))
    }

    func testRungZeroIsExactlyTheCaptureRateFormat() {
        let top = LadderState.rungs(targetFPS: 120)[0]
        XCTAssertEqual(top, LadderState(rung: 0, fps: 120, sizeFraction: 1, reason: nil))
        XCTAssertEqual(format(2560, 1440, budget: level52, fps: 120, ladder: top),
                       format(2560, 1440, budget: level52, fps: 120))
        XCTAssertNil(format(2560, 1440, budget: nil, fps: 120, ladder: top))
    }

    func testLadderStepsScaleAndThinWithoutExceedingRungZero() throws {
        let rungs = LadderState.rungs(targetFPS: 120)
        XCTAssertEqual(rungs.map(\.fps), [120, 120, 60, 60, 60, 30, 30])
        XCTAssertEqual(rungs.map(\.sizeFraction), [1, 0.75, 1, 0.75, 0.5, 0.75, 0.5])
        let expected = [SenderOutputFormat(width: 2560, height: 1440, fps: 120),
                        SenderOutputFormat(width: 1920, height: 1080, fps: 120),
                        SenderOutputFormat(width: 2560, height: 1440, fps: 60),
                        SenderOutputFormat(width: 1920, height: 1080, fps: 60),
                        SenderOutputFormat(width: 1280, height: 720, fps: 60),
                        SenderOutputFormat(width: 1920, height: 1080, fps: 30),
                        SenderOutputFormat(width: 1280, height: 720, fps: 30)]
        for (rung, format) in zip(rungs, expected) {
            XCTAssertEqual(self.format(2560, 1440, budget: level52, fps: 120, ladder: rung), format,
                           "rung \(rung.rung)")
        }

        let odd = LadderState(rung: 1, fps: 120, sizeFraction: 0.75, reason: "encode")
        XCTAssertEqual(format(2558, 1438, budget: level52, fps: 120, ladder: odd),
                       SenderOutputFormat(width: 1918, height: 1078, fps: 120), "even dimensions")
        let above = LadderState(rung: 1, fps: 240, sizeFraction: 1.5, reason: nil)
        XCTAssertEqual(format(2560, 1440, budget: level52, fps: 120, ladder: above),
                       SenderOutputFormat(width: 2560, height: 1440, fps: 120), "never above rung 0")
        let unknownSize = LadderState(rung: 2, fps: 60, sizeFraction: .nan, reason: nil)
        XCTAssertEqual(format(2560, 1440, budget: level52, fps: 120, ladder: unknownSize),
                       SenderOutputFormat(width: 2560, height: 1440, fps: 60))
        XCTAssertEqual(format(2560, 1440, budget: nil, fps: 120, ladder: rungs[4]),
                       SenderOutputFormat(width: 1280, height: 720, fps: 60), "a step applies without a level budget")

        let oldPeer = H264FrameBudget.level(31)
        let base = oldPeer.fitted(width: 2560, height: 1440, fps: 120)
        let small = try XCTUnwrap(format(2560, 1440, budget: oldPeer, fps: 120, ladder: rungs[4]))
        XCTAssertLessThanOrEqual(small.width, base.width)
        XCTAssertLessThanOrEqual(small.height, base.height)
        XCTAssertEqual(small.width % 2, 0)
        XCTAssertEqual(small.height % 2, 0)
        XCTAssertEqual(small.fps, 60)
    }
}

@MainActor
final class CaptureRateSenderTests: XCTestCase {
    func testSenderFollowsTheCaptureRateAndTheLadderOnALiveConnection() async throws {
        let host = PeerMedia(isHost: true, servers: [])
        let phone = PeerMedia(isHost: false, servers: [])
        defer { host.close(); phone.close() }
        host.onSignal = { [weak phone] in phone?.receive($0) }
        phone.onSignal = { [weak host] in host?.receive($0) }
        var connected = false
        var reports: [StreamStatsReport] = []
        host.onState = { if $0 == "connected" { connected = true } }
        host.onSenderStatistics = { reports.append($0) }
        host.offer()
        let deadline = Date().addingTimeInterval(15)
        while !connected, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(connected)

        XCTAssertEqual(host.targetFPS, 60)
        XCTAssertEqual(host.appliedSenderMaxFramerate, 60, "the 60 fps control")
        if let preference = host.tuning.degradationPreference {
            XCTAssertEqual(host.appliedDegradationPreference, preference)
        }

        host.applyCaptureRate(targetFPS: 120, displayRefreshHz: 144, display: "2560x1440 @1x 144Hz")
        XCTAssertEqual(host.appliedSenderMaxFramerate, 120)
        let highMode = SenderRateParameters.make(targetFPS: 120, tuning: host.tuning).degradationPreference
        if let highMode { XCTAssertEqual(host.appliedDegradationPreference, highMode) }

        host.applyLadder(LadderState(rung: 2, fps: 60, sizeFraction: 1, reason: "encode"))
        XCTAssertEqual(host.appliedSenderMaxFramerate, 60)
        XCTAssertEqual(host.ladderState, LadderState(rung: 2, fps: 60, sizeFraction: 1, reason: "encode"))
        if let highMode {
            XCTAssertEqual(host.appliedDegradationPreference, highMode, "a ladder step keeps the 120 mode")
        }
        host.busyState = BusyState(level: .strained, fps: 60, longEdge: 2560, reason: "encoding")
        host.captureRegion = CaptureRegion(epoch: 0, x: 0, y: 0, width: 2560, height: 1440,
                                           outputWidth: 2560, outputHeight: 1440)

        reports.removeAll()
        let statsDeadline = Date().addingTimeInterval(5)
        while reports.isEmpty, Date() < statsDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        let report = try XCTUnwrap(reports.last, "a statistics sample within 5 s")
        XCTAssertEqual(report.targetFPS, 120)
        XCTAssertEqual(report.displayRefreshHz, 144)
        XCTAssertEqual(report.captureDisplay, "2560x1440 @1x 144Hz")
        XCTAssertEqual(report.ladder?.fps, 60)
        XCTAssertEqual(report.busy?.level, .strained)
        XCTAssertEqual(report.captureRegion?.outputWidth, 2560)
        XCTAssertTrue((0...3).contains(report.thermalState ?? -1))
        XCTAssertNotNil(report.lowPowerMode)
        XCTAssertNoThrow(try report.hostSummary.validate())

        host.applyLadder(LadderState(rung: 0, fps: 240, sizeFraction: 1, reason: nil))
        XCTAssertEqual(host.appliedSenderMaxFramerate, 120, "clamped to the session rate")
        XCTAssertEqual(host.ladderState?.fps, 120)

        host.applyCaptureRate(targetFPS: 60, displayRefreshHz: 60, display: nil)
        XCTAssertEqual(host.appliedSenderMaxFramerate, 60)
        XCTAssertNil(host.ladderState, "a new capture rate starts at rung 0")
        if let preference = host.tuning.degradationPreference {
            XCTAssertEqual(host.appliedDegradationPreference, preference, "back to the tuned policy at 60")
        }
        XCTAssertNil(phone.appliedSenderMaxFramerate, "the phone does not send video")
    }
}
