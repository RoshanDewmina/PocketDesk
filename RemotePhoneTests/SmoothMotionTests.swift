import CoreVideo
import MetalKit
import XCTest
import WebRTC
@testable import PocketDeskRemote

/// D40 Smooth motion: the Auto/Always/Off policy, geometry-safe reconfiguration, pacing and the
/// pass-through fallbacks. VideoToolbox's interpolator is absent from the simulator SDK, so the
/// pipeline runs against a fake engine that checks every pair's geometry like the real one must.
final class SmoothMotionPolicyTests: XCTestCase {
    /// Frames every 16 ms up to and including `end`, as a moving stream delivers them.
    private func stream(_ policy: inout SmoothMotionPolicy, from start: Double, to end: Double) {
        var time = start
        while time < end - 0.0001 {
            policy.frameArrived(change: nil, at: time)
            time += 0.016
        }
        policy.frameArrived(change: nil, at: end)
    }

    func testAutoEngagesOnlyForLargeMotionAndYieldsToTypingAndTaps() {
        var policy = SmoothMotionPolicy(mode: .auto)
        stream(&policy, from: 0.9, to: 1)
        XCTAssertFalse(policy.evaluate(at: 1), "frames alone are not motion")
        XCTAssertEqual(policy.state, .idle("still"))

        policy.note(.scroll, at: 1.01)
        stream(&policy, from: 1.016, to: 1.02)
        XCTAssertTrue(policy.evaluate(at: 1.02))
        XCTAssertEqual(policy.state, .engaged("scroll"))

        stream(&policy, from: 1.036, to: 1.2)
        XCTAssertTrue(policy.evaluate(at: 1.2), "held briefly after the last scroll event")
        stream(&policy, from: 1.216, to: 1.4)
        XCTAssertFalse(policy.evaluate(at: 1.4), "released once motion stops")

        stream(&policy, from: 1.416, to: 2)
        policy.note(.windowDrag, at: 2)
        policy.note(.typing, at: 2)
        stream(&policy, from: 2.01, to: 2.01)
        XCTAssertFalse(policy.evaluate(at: 2.01))
        XCTAssertEqual(policy.state, .idle("typing"))
        stream(&policy, from: 2.026, to: 2.9)
        policy.note(.windowDrag, at: 2.9)
        XCTAssertTrue(policy.evaluate(at: 2.9), "typing quiet period over")

        policy.note(.preciseTap, at: 3)
        policy.note(.scroll, at: 3)
        stream(&policy, from: 2.916, to: 3.05)
        XCTAssertEqual(policy.evaluate(at: 3.05), false)
        XCTAssertEqual(policy.state, .idle("tap"))
    }

    func testTheFirstFrameAfterAStillPictureIsShownAsItIs() {
        var policy = SmoothMotionPolicy(mode: .always)
        policy.frameArrived(change: nil, at: 0)
        XCTAssertFalse(policy.evaluate(at: 0), "nothing before it")
        policy.frameArrived(change: nil, at: 0.016)
        XCTAssertTrue(policy.evaluate(at: 0.016))
        policy.frameArrived(change: nil, at: 2)
        XCTAssertFalse(policy.evaluate(at: 2), "its predecessor is two seconds old")
        XCTAssertEqual(policy.state, .idle("static"))
    }

    func testAutoTreatsSustainedWholePictureChangeAsMotionButNotOneChange() {
        var policy = SmoothMotionPolicy(mode: .auto)
        policy.frameArrived(change: 0.6, at: 0)
        policy.frameArrived(change: 0.01, at: 0.016)
        policy.frameArrived(change: 0.6, at: 0.033)
        XCTAssertFalse(policy.evaluate(at: 0.033), "a window opening is one large change, not video")
        policy.frameArrived(change: 0.3, at: 0.05)
        policy.frameArrived(change: 0.3, at: 0.066)
        XCTAssertTrue(policy.evaluate(at: 0.066))
        XCTAssertEqual(policy.state, .engaged("content"))
    }

    func testStaticPictureNeverEngagesSoIdleRefreshIsLeftAlone() {
        var policy = SmoothMotionPolicy(mode: .always)
        policy.frameArrived(change: nil, at: 0)
        policy.frameArrived(change: nil, at: 0.016)
        XCTAssertTrue(policy.evaluate(at: 0.1))
        XCTAssertFalse(policy.evaluate(at: 0.1 + SmoothMotionPolicy.staticAfter + 0.01))
        XCTAssertEqual(policy.state, .idle("static"))
    }

    func testOffAndBlocksAlwaysWin() {
        var policy = SmoothMotionPolicy(mode: .off)
        policy.note(.scroll, at: 0)
        policy.frameArrived(change: 1, at: 0)
        XCTAssertFalse(policy.evaluate(at: 0))
        policy.mode = .always
        policy.block = .thermal
        XCTAssertFalse(policy.evaluate(at: 0))
        XCTAssertEqual(policy.state, .idle("thermal"))
        policy.block = nil
        policy.frameArrived(change: 1, at: 0.016)
        XCTAssertTrue(policy.evaluate(at: 0.016))
    }

    func testAutoYieldsToAFingerOnTheScreenOnlyWithTheSwitch() {
        var policy = SmoothMotionPolicy(mode: .auto)
        XCTAssertFalse(policy.yieldsToTouch, "off by default")
        policy.touching = true
        policy.note(.scroll, at: 1)
        stream(&policy, from: 0.95, to: 1.01)
        XCTAssertTrue(policy.evaluate(at: 1.01), "today: a finger-driven scroll engages")

        policy.yieldsToTouch = true
        XCTAssertFalse(policy.evaluate(at: 1.01))
        XCTAssertEqual(policy.state, .idle("touch"))
        policy.touching = false
        policy.note(.scroll, at: 1.02)
        stream(&policy, from: 1.026, to: 1.03)
        XCTAssertTrue(policy.evaluate(at: 1.03), "the coast after the lift engages")
        XCTAssertEqual(policy.state, .engaged("scroll"))

        policy.mode = .always
        policy.touching = true
        XCTAssertTrue(policy.evaluate(at: 1.03), "Always is the person's explicit choice")
        policy.mode = .off
        XCTAssertEqual(policy.evaluate(at: 1.03), false)
        XCTAssertEqual(policy.state, .idle("off"))
    }

    func testOutgoingActionsMapToHints() {
        XCTAssertEqual(SmoothMotionHint.classify(action: "scroll", dragging: false), .scroll)
        XCTAssertEqual(SmoothMotionHint.classify(action: "move", dragging: true), .windowDrag)
        XCTAssertNil(SmoothMotionHint.classify(action: "move", dragging: false), "the pointer is drawn locally")
        XCTAssertEqual(SmoothMotionHint.classify(action: "key", dragging: false), .typing)
        XCTAssertEqual(SmoothMotionHint.classify(action: "text", dragging: false), .typing)
        XCTAssertEqual(SmoothMotionHint.classify(action: "click", dragging: false), .preciseTap)
        XCTAssertNil(SmoothMotionHint.classify(action: "heartbeat", dragging: false))
    }

    func testChangedShareCountsOnlyMovedSamples() {
        XCTAssertEqual(FrameChangeSampler.changedShare([10, 10, 10, 10], [10, 30, 10, 60]), 0.5)
        XCTAssertEqual(FrameChangeSampler.changedShare([10, 10], [15, 5]), 0, "noise under the threshold")
    }

    func testOversizePicturesFitTheDocumentedLimitKeepingAspect() throws {
        let sharp = FrameGeometry(width: 2560, height: 1656, pixelFormat: SmoothMotionSource.convertedFormat)
        let plan = try XCTUnwrap(InterpolationPlan.make(for: sharp, limits: .documented, upscaleLimits: nil,
                                                        upscale: false, fitOversize: true))
        XCTAssertTrue(plan.fitted)
        let input = plan.setup.input
        XCTAssertTrue(InterpolationLimits.documented.fits(width: input.width, height: input.height), "\(input)")
        XCTAssertEqual(Double(input.width) / Double(input.height), 2560.0 / 1656, accuracy: 0.01)
        XCTAssertEqual(input.width % 2, 0)
        XCTAssertNil(InterpolationPlan.make(for: sharp, limits: .documented, upscaleLimits: nil, upscale: false, fitOversize: false))

        let small = FrameGeometry(width: 1280, height: 800, pixelFormat: sharp.pixelFormat)
        XCTAssertEqual(InterpolationPlan.make(for: small, limits: .documented, upscaleLimits: nil, upscale: false, fitOversize: true),
                       InterpolationPlan(setup: InterpolationSetup(input: small), fitted: false), "zero-copy when it fits")

        let doubled = try XCTUnwrap(InterpolationPlan.make(for: sharp, limits: .documented, upscaleLimits: .documented,
                                                           upscale: true, fitOversize: true))
        XCTAssertEqual(doubled.setup.scale, 2)
        XCTAssertEqual(doubled.setup.input.width, 1280)
        XCTAssertEqual(doubled.setup.output.width, 2560)
        XCTAssertEqual(InterpolationPlan.make(for: small, limits: .documented, upscaleLimits: nil, upscale: true, fitOversize: true)?.setup.scale,
                       1, "no 2× limit reported: stays at 1×")
    }
}

final class SmoothMotionPresenterTests: XCTestCase {
    func testMidpointThenSourceOnConsecutiveTicksAndNeverOlderAfterNewer() {
        var shown: [String] = []
        let presenter = SmoothMotionPresenter<String>(deliver: { shown.append($0) })
        let tick = 1.0 / 120
        XCTAssertTrue(presenter.presentNow("1", order: 2, at: 0))
        presenter.enqueue([.init(payload: "1.5", order: 3, spacing: 0, arrival: nil),
                           .init(payload: "2", order: 4, spacing: 1.0 / 120, arrival: 0.016)])
        XCTAssertEqual(presenter.pump(at: 0.02, tick: tick)?.order, 3)
        XCTAssertNil(presenter.pump(at: 0.021, tick: tick), "the source waits for the next tick")
        let delivery = presenter.pump(at: 0.02 + tick, tick: tick)
        XCTAssertEqual(delivery?.order, 4)
        XCTAssertEqual(delivery?.addedDelay ?? 0, 0.02 + tick - 0.016, accuracy: 0.0001)
        XCTAssertEqual(shown, ["1", "1.5", "2"])

        XCTAssertTrue(presenter.presentNow("4", order: 8, at: 0.05))
        presenter.enqueue([.init(payload: "2.5", order: 5, spacing: 0, arrival: nil),
                           .init(payload: "3", order: 6, spacing: 0.008, arrival: 0.03)])
        XCTAssertNil(presenter.pump(at: 0.06, tick: tick))
        XCTAssertFalse(presenter.presentNow("3", order: 6, at: 0.06))
        XCTAssertEqual(shown, ["1", "1.5", "2", "4"], "late output for an older frame is dropped")
        XCTAssertEqual(presenter.dropped, 2)
    }

    func testFlushShowsTheHeldSourceAtOnce() {
        var shown: [String] = []
        let presenter = SmoothMotionPresenter<String>(deliver: { shown.append($0) })
        presenter.enqueue([.init(payload: "0.5", order: 1, spacing: 0, arrival: nil),
                           .init(payload: "1", order: 2, spacing: 0.008, arrival: 0)])
        XCTAssertEqual(presenter.flush(at: 0.001)?.order, 2)
        XCTAssertEqual(shown, ["1"])
        XCTAssertFalse(presenter.hasPending)
    }

    func testAnOverdueMidpointIsDroppedAndItsSourceShownAtOnce() {
        var shown: [String] = []
        let presenter = SmoothMotionPresenter<String>(deliver: { shown.append($0) })
        let tick = 1.0 / 120
        XCTAssertTrue(presenter.presentNow("1", order: 2, at: 0))
        presenter.enqueue([.init(payload: "1.5", order: 3, spacing: 0, arrival: nil, deadline: 0.0334),
                           .init(payload: "2", order: 4, spacing: 1.0 / 120, arrival: 0.0167)])
        XCTAssertEqual(presenter.pump(at: 0.04, tick: tick)?.order, 4, "past its deadline the midpoint is skipped")
        XCTAssertEqual(shown, ["1", "2"])
        XCTAssertEqual(presenter.dropped, 1)
        XCTAssertFalse(presenter.hasPending)

        presenter.enqueue([.init(payload: "2.5", order: 5, spacing: 0, arrival: nil, deadline: 0.07),
                           .init(payload: "3", order: 6, spacing: 1.0 / 120, arrival: 0.05)])
        presenter.dropMidpoints()
        XCTAssertEqual(presenter.pump(at: 0.055, tick: tick)?.order, 6, "a newer source arrived: the midpoint is stale")
        XCTAssertEqual(shown, ["1", "2", "3"])
        XCTAssertEqual(presenter.dropped, 2)

        presenter.enqueue([.init(payload: "3.5", order: 7, spacing: 0, arrival: nil, deadline: 0.09),
                           .init(payload: "4", order: 8, spacing: 1.0 / 120, arrival: 0.07)])
        XCTAssertEqual(presenter.pump(at: 0.075, tick: tick)?.order, 7, "a midpoint within its deadline is still shown")
    }
}

final class SmoothMotionPipelineTests: XCTestCase {
    private var clock = 0.0
    private var engine: FakeInterpolationEngine!
    private var thermal = ProcessInfo.ThermalState.nominal
    private var lowPower = false
    private var delivered: [SmoothMotionController.Output] = []
    private var controller: SmoothMotionController!

    override func setUp() {
        super.setUp()
        engine = FakeInterpolationEngine()
        makeController(mode: .always)
    }

    private func makeController(mode: SmoothMotionMode, supported: Bool = true, limits: InterpolationLimits = .documented,
                                fitOversize: Bool = false, midpointDeadline: Bool = true,
                                colorTags: Bool = true, lowPowerBypass: Bool = false, warmCadence: Bool = true,
                                yieldsToTouch: Bool = false) {
        let environment = SmoothMotionController.Environment(
            makeEngine: { [unowned self] in supported ? engine : nil },
            supported: supported,
            limits: limits,
            upscaleLimits: nil,
            now: { [unowned self] in clock },
            thermal: { [unowned self] in thermal },
            queue: DispatchQueue(label: "SmoothMotionTests"),
            fitOversize: fitOversize,
            midpointDeadline: midpointDeadline,
            colorTags: colorTags,
            lowPower: { [unowned self] in lowPower },
            lowPowerBypass: lowPowerBypass,
            yieldsToTouch: yieldsToTouch)
        controller = SmoothMotionController(mode: mode, environment: environment)
        delivered = []
        controller.deliver = { [unowned self] in delivered.append($0) }
        controller.displayTick(at: clock, framesPerSecond: 120, capable: true)
        if lowPowerBypass, warmCadence {
            // Actual 120 Hz callbacks establish the gate; a maximum/request alone cannot.
            controller.resetSession()
            for index in 0...132 {
                controller.displayTick(at: clock - 1.1 + Double(index) / 120, framesPerSecond: 120, capable: true)
            }
        }
    }

    private func send(_ frame: RTCVideoFrame, at time: Double) {
        clock = time
        controller.receive(frame, marker: nil)
        controller.interpolator.waitUntilIdle()
    }

    private func tick(at time: Double) {
        clock = time
        controller.displayTick(at: time, framesPerSecond: 120, capable: true)
    }

    func testInterpolatedMidpointIsShownOneTickBeforeItsSourceFrame() throws {
        let frames = try (0..<3).map { try Self.frame(width: 64, height: 48, luma: UInt8(40 * $0)) }
        send(frames[0], at: 0)
        XCTAssertTrue(delivered.last?.frame === frames[0], "warming up: shown directly")
        send(frames[1], at: 0.0167)
        XCTAssertTrue(delivered.last?.frame === frames[1], "first pair after warm-up primes the reference")
        send(frames[2], at: 0.0333)
        XCTAssertEqual(delivered.count, 2, "frame 2 is held for its midpoint")
        tick(at: 0.035)
        XCTAssertEqual(delivered.count, 3)
        let middle = try XCTUnwrap(delivered.last?.frame.buffer as? RTCCVPixelBuffer)
        XCTAssertTrue(engine.producedMiddles.contains { $0 === middle.pixelBuffer })
        tick(at: 0.035 + 1.0 / 120)
        XCTAssertTrue(delivered.last?.frame === frames[2])
        XCTAssertEqual(engine.pairs, [FakeInterpolationEngine.Pair(previous: 40, current: 80)])
        let snapshot = controller.diagnostics.snapshot()
        XCTAssertEqual(snapshot.interpolatedFrames, 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.addedLatencyP95Ms), (0.035 + 1.0 / 120 - 0.0333) * 1000, accuracy: 0.5)
    }

    func testALateMidpointIsSkippedSoItsSourceIsNotHeldBehindIt() throws {
        let frames = try (0..<3).map { try Self.frame(width: 64, height: 48, luma: UInt8(40 * $0)) }
        for (index, frame) in frames.enumerated() { send(frame, at: Double(index) * 0.0167) }
        XCTAssertEqual(delivered.count, 2, "frame 2 is held for its midpoint")
        tick(at: 0.0334 + 0.0167 + 0.002)
        XCTAssertTrue(delivered.last?.frame === frames[2], "one source interval later the source goes, not the midpoint")
        XCTAssertEqual(delivered.count, 3)
        XCTAssertEqual(controller.diagnostics.snapshot().droppedFrames, 1)

        makeController(mode: .always, midpointDeadline: false)
        for (index, frame) in frames.enumerated() { send(frame, at: 1 + Double(index) * 0.0167) }
        tick(at: 1.0334 + 0.0167 + 0.002)
        let late = try XCTUnwrap(delivered.last?.frame.buffer as? RTCCVPixelBuffer)
        XCTAssertTrue(engine.producedMiddles.contains { $0 === late.pixelBuffer }, "kill switch: the late midpoint is shown")
    }

    func testAnOversizedSourceIsShownAtItsDecodedSizeAndNotInterpolated() throws {
        let small = InterpolationLimits(maxDimension: 64, maxPixels: 64 * 48)
        makeController(mode: .always, limits: small)
        let frames = try (0..<3).map { try Self.frame(width: 80, height: 60, luma: UInt8(40 * $0)) }
        for (index, frame) in frames.enumerated() {
            send(frame, at: Double(index) * 0.0167)
            XCTAssertTrue(delivered.last?.frame === frame, "frame \(index) is the decoded frame itself")
        }
        XCTAssertEqual(delivered.count, frames.count)
        XCTAssertTrue(engine.started.isEmpty)
        XCTAssertTrue(engine.pairs.isEmpty)
        XCTAssertEqual(controller.diagnostics.snapshot().state, SmoothMotionBlock.size.rawValue)

        makeController(mode: .always, limits: small, fitOversize: true)
        send(frames[0], at: 1)
        send(frames[1], at: 1.0167)
        let primed = try XCTUnwrap(delivered.last?.frame.buffer as? RTCCVPixelBuffer)
        XCTAssertEqual(engine.started.map(\.input.width), [64], "kill switch: the old fitted interpolation")
        XCTAssertEqual(CVPixelBufferGetWidth(primed.pixelBuffer), 64, "and the source is shown from the fitted copy")
        send(frames[2], at: 1.0334)
        tick(at: 1.035)
        tick(at: 1.035 + 1.0 / 120)
        let source = try XCTUnwrap(delivered.last?.frame.buffer as? RTCCVPixelBuffer)
        XCTAssertFalse(engine.producedMiddles.contains { $0 === source.pixelBuffer })
        XCTAssertEqual(CVPixelBufferGetWidth(source.pixelBuffer), 64)
    }

    func testGeometryChangeReconfiguresAndNeverPairsMismatchedFrames() throws {
        send(try Self.frame(width: 64, height: 48, luma: 0), at: 0)
        send(try Self.frame(width: 64, height: 48, luma: 10), at: 0.016)
        let resized = try Self.frame(width: 80, height: 60, luma: 20)
        send(resized, at: 0.033)
        XCTAssertTrue(delivered.last?.frame === resized, "a new size is shown directly while the session restarts")
        XCTAssertEqual(engine.started.map(\.input.width), [64, 80])
        XCTAssertEqual(engine.stops, 1, "the old session ends before the new one starts")
        send(try Self.frame(width: 80, height: 60, luma: 30), at: 0.05)
        send(try Self.frame(width: 80, height: 60, luma: 40), at: 0.066)
        XCTAssertEqual(engine.pairs, [FakeInterpolationEngine.Pair(previous: 30, current: 40)])
        XCTAssertEqual(engine.mismatchedCalls, 0)
    }

    func testProcessingErrorsFallBackToPassThroughThenStopTrying() throws {
        engine.failure = .processingFailed("test")
        for index in 0..<6 {
            let frame = try Self.frame(width: 64, height: 48, luma: UInt8(index * 10))
            send(frame, at: Double(index) * 0.0167)
            XCTAssertTrue(delivered.last?.frame === frame, "frame \(index) is still shown")
        }
        XCTAssertEqual(engine.pairs.count, SmoothMotionController.errorLimit, "gives up after repeated errors")
        let snapshot = controller.diagnostics.snapshot()
        XCTAssertEqual(snapshot.state, SmoothMotionBlock.failed.rawValue)
        XCTAssertGreaterThanOrEqual(snapshot.fallbacks, SmoothMotionController.errorLimit)
    }

    func testFallingBehindShowsFramesDirectlyAndCoolsDown() throws {
        engine.holdsCompletion = true
        for index in 0..<3 { send(try Self.frame(width: 64, height: 48, luma: UInt8(index)), at: Double(index) * 0.0167) }
        for index in 3..<(3 + SmoothMotionController.behindLimit) {
            let frame = try Self.frame(width: 64, height: 48, luma: UInt8(index))
            send(frame, at: Double(index) * 0.0167)
            XCTAssertTrue(delivered.last?.frame === frame, "a pair in flight never delays the next frame")
        }
        XCTAssertEqual(controller.diagnostics.snapshot().busyFrames, SmoothMotionController.behindLimit)
        send(try Self.frame(width: 64, height: 48, luma: 99), at: 0.2)
        XCTAssertEqual(controller.diagnostics.snapshot().state, SmoothMotionBlock.behind.rawValue)
    }

    func testThermalUnsupportedAndSlowDisplaysPassThroughSynchronously() throws {
        thermal = .serious
        let hot = try Self.frame(width: 64, height: 48, luma: 1)
        send(hot, at: 0)
        XCTAssertTrue(delivered.last?.frame === hot)
        XCTAssertEqual(controller.diagnostics.snapshot().state, "thermal")
        XCTAssertTrue(engine.started.isEmpty)

        thermal = .nominal
        makeController(mode: .always, supported: false)
        let unsupported = try Self.frame(width: 64, height: 48, luma: 2)
        send(unsupported, at: 1)
        XCTAssertTrue(delivered.last?.frame === unsupported)
        XCTAssertEqual(controller.diagnostics.snapshot().state, SmoothMotionBlock.unsupported.rawValue)

        makeController(mode: .always)
        controller.displayTick(at: 2, framesPerSecond: 60, capable: false)
        let slow = try Self.frame(width: 64, height: 48, luma: 3)
        send(slow, at: 2)
        XCTAssertTrue(delivered.last?.frame === slow)
        XCTAssertEqual(controller.diagnostics.snapshot().state, SmoothMotionBlock.display.rawValue)
    }

    func testAutoStaysDirectUntilMotionAndOffNeverTouchesTheEngine() throws {
        makeController(mode: .auto)
        for index in 0..<4 { send(try Self.frame(width: 64, height: 48, luma: 50), at: Double(index) * 0.0167) }
        XCTAssertEqual(engine.started.count, 1, "the session is warmed while streaming")
        XCTAssertTrue(engine.pairs.isEmpty, "but nothing is interpolated without motion")
        XCTAssertEqual(delivered.count, 4)
        controller.note(.scroll, at: 0.07)
        send(try Self.frame(width: 64, height: 48, luma: 60), at: 0.07)
        send(try Self.frame(width: 64, height: 48, luma: 70), at: 0.087)
        XCTAssertEqual(engine.pairs, [FakeInterpolationEngine.Pair(previous: 60, current: 70)])
        XCTAssertEqual(engine.started.count, 1)

        makeController(mode: .off)
        engine.started.removeAll()
        controller.note(.scroll, at: 1)
        for index in 0..<4 { send(try Self.frame(width: 64, height: 48, luma: UInt8(index * 60)), at: 1 + Double(index) * 0.0167) }
        XCTAssertTrue(engine.started.isEmpty)
        XCTAssertEqual(delivered.count, 4)
    }

    func testAFingerOnTheScreenShowsFramesDirectlyAndTheLiftEngagesAgain() throws {
        makeController(mode: .auto, yieldsToTouch: true)
        controller.setTouching(true)
        controller.note(.scroll, at: 0)
        for index in 0..<4 { send(try Self.frame(width: 64, height: 48, luma: UInt8(index * 40)), at: Double(index) * 0.0167) }
        XCTAssertTrue(engine.pairs.isEmpty, "no frame waits a tick while the finger scrolls")
        XCTAssertEqual(delivered.count, 4)
        XCTAssertEqual(controller.diagnostics.snapshot().state, "touch")

        controller.setTouching(false)
        controller.note(.scroll, at: 0.07)
        send(try Self.frame(width: 64, height: 48, luma: 200), at: 0.07)
        send(try Self.frame(width: 64, height: 48, luma: 210), at: 0.087)
        XCTAssertEqual(engine.pairs, [FakeInterpolationEngine.Pair(previous: 200, current: 210)], "the coast is smoothed")

        controller.setTouching(true)
        controller.resetSession()
        controller.note(.scroll, at: 1)
        for index in 0..<3 { send(try Self.frame(width: 64, height: 48, luma: UInt8(index * 50)), at: 1 + Double(index) * 0.0167) }
        XCTAssertEqual(engine.pairs.count, 1, "a new stream keeps the finger that is still down")
    }

    func testLowPowerBypassNeverStartsEngineAndFlushesPendingMidpoint() throws {
        lowPower = true
        makeController(mode: .always, lowPowerBypass: true)
        let frames = try (0..<6).map { try Self.frame(width: 64, height: 48, luma: UInt8($0 * 10)) }
        for index in 0..<3 { send(frames[index], at: Double(index) / 60) }
        XCTAssertEqual(delivered.count, 3)
        XCTAssertTrue(engine.started.isEmpty)
        XCTAssertEqual(controller.diagnostics.snapshot().state, SmoothMotionBlock.lowPower.rawValue)

        lowPower = false
        for index in 3..<6 { send(frames[index], at: Double(index) / 60) }
        XCTAssertEqual(engine.pairs.count, 1)
        XCTAssertEqual(delivered.count, 5, "latest source is held behind its midpoint")
        lowPower = true
        tick(at: 0.085)
        XCTAssertTrue(delivered.last?.frame === frames[5], "LPM flushes the source without showing its midpoint")
        XCTAssertEqual(delivered.count, 6)
    }

    func testLowPowerChangeWhileEngineOwnsPairCannotEnqueueAMidpoint() throws {
        makeController(mode: .always, lowPowerBypass: true)
        engine.holdsCompletion = true
        let frames = try (0..<3).map { try Self.frame(width: 64, height: 48, luma: UInt8($0 * 10)) }
        for index in 0..<3 { send(frames[index], at: Double(index) / 60) }
        XCTAssertEqual(engine.pairs.count, 1)
        lowPower = true
        let output = try Self.pixelBuffer(width: 64, height: 48, luma: 5)
        engine.completeHeld(with: InterpolatedFrames(middle: output, upscaledSource: nil))
        XCTAssertTrue(delivered.last?.frame === frames[2])
        tick(at: 0.035)
        XCTAssertEqual(delivered.count, 3, "no late synthetic output follows a power bypass")
    }

    func testBypassSwitchOffRestoresInterpolationInLowPowerAtObserved60Hz() throws {
        lowPower = true
        makeController(mode: .always, lowPowerBypass: false)
        // Eligibility says 120 Hz, but the observed callbacks run at 60 Hz.
        for index in 0...72 { tick(at: Double(index) / 60) }
        let start = clock
        let frames = try (0..<3).map { try Self.frame(width: 64, height: 48, luma: UInt8($0 * 10)) }
        for index in 0..<3 { send(frames[index], at: start + Double(index) / 60) }
        XCTAssertEqual(engine.pairs.count, 1, "NO restores the legacy maximum/request eligibility and ignores LPM")
        tick(at: clock + 0.002)
        XCTAssertEqual(delivered.count, 3)
        XCTAssertFalse(delivered.last?.frame === frames[2], "legacy behavior still presents the midpoint")
    }

    func testObservedCadenceBypassesAfterOneSecondAndRecoversWithHysteresis() throws {
        makeController(mode: .always, lowPowerBypass: true)
        let frames = try (0..<3).map { try Self.frame(width: 64, height: 48, luma: UInt8($0 * 10)) }
        for index in 0..<3 { send(frames[index], at: Double(index) / 60) }
        XCTAssertEqual(engine.pairs.count, 1)
        for index in 3...69 { tick(at: Double(index) / 60) }
        let slow = try Self.frame(width: 64, height: 48, luma: 40)
        send(slow, at: 1.16)
        XCTAssertTrue(delivered.last?.frame === slow)
        XCTAssertEqual(controller.diagnostics.snapshot().state, SmoothMotionBlock.display.rawValue)
        XCTAssertEqual(engine.pairs.count, 1, "requesting 120 Hz does not override observed slow callbacks")

        for index in 1...60 { tick(at: 1.15 + Double(index) / 120) }
        send(try Self.frame(width: 64, height: 48, luma: 50), at: 1.66)
        XCTAssertEqual(controller.diagnostics.snapshot().state, SmoothMotionBlock.display.rawValue)
        for index in 61...132 { tick(at: 1.15 + Double(index) / 120) }
        send(try Self.frame(width: 64, height: 48, luma: 60), at: 2.26)
        XCTAssertNotEqual(controller.diagnostics.snapshot().state, SmoothMotionBlock.display.rawValue)
    }

    func testHighMaximumNeedsObservedFastCadenceAnd60HzPanelStaysDirect() throws {
        makeController(mode: .always, lowPowerBypass: true, warmCadence: false)
        send(try Self.frame(width: 64, height: 48, luma: 1), at: 0)
        XCTAssertTrue(engine.started.isEmpty, "one tick and a 120 Hz request prove no observed cadence")
        for index in 1...132 { tick(at: Double(index) / 120) }
        send(try Self.frame(width: 64, height: 48, luma: 2), at: 1.11)
        XCTAssertEqual(engine.started.count, 1)
        controller.displayTick(at: 1.12, framesPerSecond: 60, capable: false)
        let source = try Self.frame(width: 64, height: 48, luma: 3)
        send(source, at: 1.12)
        XCTAssertTrue(delivered.last?.frame === source)
        XCTAssertEqual(controller.diagnostics.snapshot().state, SmoothMotionBlock.display.rawValue)
    }

    func testResetSessionRequiresNewCadenceOnlyWhenBypassIsEnabled() throws {
        for enabled in [true, false] {
            clock = 0
            engine = FakeInterpolationEngine()
            makeController(mode: .always, lowPowerBypass: enabled)
            controller.resetSession()
            send(try Self.frame(width: 64, height: 48, luma: 1), at: 0)
            if enabled {
                XCTAssertTrue(engine.started.isEmpty, "ON requires new scheduled callback evidence")
                XCTAssertEqual(controller.diagnostics.snapshot().state, SmoothMotionBlock.display.rawValue)
            } else {
                XCTAssertEqual(engine.started.count, 1, "NO retains the baseline display eligibility across reset")
            }
        }
    }

    @MainActor
    func testPerformanceAutoScrollRendersTaggedMidpointWithoutCreatingFallback() throws {
        clock = 1.1
        makeController(mode: .auto, lowPowerBypass: true)
        let identity = VideoPresentationIdentity(hostRecordID: "performance-host", ownerPairID: "performance-owner",
            sessionID: UUID(), trackID: UUID(), contentEpoch: 1, geometryEpoch: 1)
        let admission = VideoPresentationAdmission(identity: identity,
            validUntil: ProcessInfo.processInfo.systemUptime + 10)
        let view = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
        _ = try XCTUnwrap(view.metal.device, "simulator Metal device is required for this renderer acceptance check")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(view)
        view.frame = window.bounds
        window.isHidden = false
        view.layoutIfNeeded()
        view.metal.isPaused = true
        view.drawRequester = { _ in } // This test owns bounded explicit draws and injected scheduled ticks.
        view.renderDiagnostics = controller.diagnostics
        defer {
            controller.deactivate()
            view.invalidate()
            window.isHidden = true
            window.rootViewController = nil
        }

        let frames = try (0..<3).map { try Self.frame(width: 64, height: 48, luma: UInt8($0 * 40)) }
        var drawnMidpoints = 0
        view.onFrameDrawn = { envelope in
            if !envelope.originalSource { drawnMidpoints += 1 }
        }
        controller.deliver = { output in
            let envelope = VideoFrameEnvelope(receiptID: UUID(), identity: identity, frame: output.frame,
                arrivalMs: MachClock.nowMs(), marker: output.marker,
                originalSource: frames.contains { $0 === output.frame })
            DispatchQueue.main.async { view.offer(envelope) }
        }
        func drawUntil(_ satisfied: () -> Bool) {
            let deadline = Date().addingTimeInterval(0.75)
            repeat {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                view.draw(in: view.metal)
            } while !satisfied() && Date() < deadline
        }

        controller.note(.scroll, at: clock) // Performance mode uses Auto; scrolling predicts motion.
        send(frames[0], at: 1.1)
        drawUntil { view.drawsPresented > 0 }
        XCTAssertGreaterThan(view.drawsPresented, 0, "the tagged source must submit a real Metal draw")
        // Keep the injected display clock at 120 Hz between 60 Hz source arrivals. Without
        // these ticks the first pump observes a 35 ms gap and correctly skips the midpoint.
        tick(at: 1.1 + 1.0 / 120)
        tick(at: 1.1 + 2.0 / 120)
        send(frames[1], at: 1.1 + 1.0 / 60)
        drawUntil { view.drawsPresented > 1 }
        tick(at: 1.1 + 3.0 / 120)
        tick(at: 1.1 + 4.0 / 120)
        send(frames[2], at: 1.1 + 2.0 / 60)
        tick(at: 1.1 + 5.0 / 120)
        drawUntil { drawnMidpoints > 0 }
        tick(at: clock + 1.0 / 120)
        drawUntil { view.drawsPresented > 2 }

        XCTAssertGreaterThan(controller.diagnostics.snapshot().interpolatedFrames, 0)
        XCTAssertGreaterThan(drawnMidpoints, 0, "the synthetic midpoint must reach the owned Metal renderer")
        XCTAssertGreaterThan(view.drawsPresented, 0)
        XCTAssertEqual(view.fallbackCreationCount, 0, "Performance sources and midpoints never create the fallback view")
        XCTAssertEqual(controller.diagnostics.snapshot().rendererFallbackCreations, 0)
    }

    static func frame(width: Int, height: Int, luma: UInt8) throws -> RTCVideoFrame {
        RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try pixelBuffer(width: width, height: height, luma: luma)),
                      rotation: ._0, timeStampNs: 0)
    }

    static func pixelBuffer(width: Int, height: Int, luma: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                           attributes, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(result, [])
        if let base = CVPixelBufferGetBaseAddressOfPlane(result, 0) {
            memset(base, Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(result, 0) * height)
        }
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }

    static func luma(of buffer: CVPixelBuffer) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.load(as: UInt8.self) ?? 0
    }
}

/// Stands in for VideoToolbox: checks every pair against the started geometry (the real
/// processor crashes on a mismatch) and returns a fresh buffer of the output geometry.
final class FakeInterpolationEngine: FrameInterpolationEngine {
    struct Pair: Equatable {
        let previous: UInt8
        let current: UInt8
    }

    var started: [InterpolationSetup] = []
    var stops = 0
    var pairs: [Pair] = []
    var mismatchedCalls = 0
    var producedMiddles: [CVPixelBuffer] = []
    var failure: InterpolationError?
    var holdsCompletion = false
    private var setup: InterpolationSetup?
    private var held: [(Result<InterpolatedFrames, InterpolationError>) -> Void] = []

    func start(_ setup: InterpolationSetup) throws {
        started.append(setup)
        self.setup = setup
    }

    func interpolate(previous: CVPixelBuffer, previousTime: TimeInterval, current: CVPixelBuffer,
                     currentTime: TimeInterval, completion: @escaping (Result<InterpolatedFrames, InterpolationError>) -> Void) {
        guard let setup, setup.input.matches(previous), setup.input.matches(current) else {
            mismatchedCalls += 1
            return completion(.failure(.geometryMismatch))
        }
        pairs.append(Pair(previous: SmoothMotionPipelineTests.luma(of: previous), current: SmoothMotionPipelineTests.luma(of: current)))
        if holdsCompletion { held.append(completion); return }
        if let failure { return completion(.failure(failure)) }
        guard let middle = try? SmoothMotionPipelineTests.pixelBuffer(width: setup.output.width, height: setup.output.height, luma: 1)
        else { return completion(.failure(.bufferUnavailable)) }
        InterpolationColorTags.clear(middle) // Like the real destination pool, the fake supplies no color tags.
        producedMiddles.append(middle)
        completion(.success(InterpolatedFrames(middle: middle, upscaledSource: nil)))
    }

    func stop() {
        if setup != nil { stops += 1 }
        setup = nil
    }

    func completeHeld(with frames: InterpolatedFrames) {
        let completions = held
        held.removeAll()
        for completion in completions { completion(.success(frames)) }
    }
}

final class InterpolationColorTagsTests: XCTestCase {
    private func makeInterpolator(engine: FakeInterpolationEngine, colorTags: Bool = true) -> FrameInterpolator {
        let interpolator = FrameInterpolator(queue: DispatchQueue(label: "InterpolationColorTagsTests"),
                                            colorTags: colorTags, makeEngine: { engine })
        interpolator.prepare(for: InterpolationSetup(input: FrameGeometry(width: 64, height: 48,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)))
        interpolator.waitUntilIdle()
        return interpolator
    }

    @discardableResult
    private func submit(_ buffer: CVPixelBuffer, at time: Double, to interpolator: FrameInterpolator,
                        completion: @escaping (FrameInterpolator.Outcome) -> Void = { _ in }) -> FrameInterpolator.Submission {
        let submission = interpolator.submit(time: time, setup: InterpolationSetup(input: FrameGeometry(buffer)),
                                             prepare: { buffer }, completion: completion)
        interpolator.waitUntilIdle()
        return submission
    }

    private func envelope(_ buffer: CVPixelBuffer) -> VideoFrameEnvelope {
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 0)
        let identity = VideoPresentationIdentity(hostRecordID: "test-host", ownerPairID: "test-owner",
            sessionID: UUID(), trackID: UUID(), contentEpoch: 1, geometryEpoch: 1)
        return VideoFrameEnvelope(receiptID: UUID(), identity: identity, frame: frame, arrivalMs: 0,
                                  marker: nil, originalSource: false)
    }

    func testTaggedPairCopiesOnlyAfterCompletionAndEnvelopeAcceptsBothOutputs() throws {
        let engine = FakeInterpolationEngine()
        engine.holdsCompletion = true
        let interpolator = makeInterpolator(engine: engine)
        let previous = try SmoothMotionPipelineTests.pixelBuffer(width: 64, height: 48, luma: 1)
        let current = try SmoothMotionPipelineTests.pixelBuffer(width: 64, height: 48, luma: 2)
        for buffer in [previous, current] {
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        }
        submit(previous, at: 0, to: interpolator)
        let middle = try SmoothMotionPipelineTests.pixelBuffer(width: 64, height: 48, luma: 3)
        let upscaled = try SmoothMotionPipelineTests.pixelBuffer(width: 64, height: 48, luma: 4)
        var acceptedOutput = false
        submit(current, at: 1.0 / 60, to: interpolator) { outcome in
            guard case .interpolated(let frames, _, _) = outcome else { return XCTFail("expected interpolation") }
            guard let upscaled = frames.upscaledSource else { return XCTFail("expected upscaled source") }
            acceptedOutput = self.envelope(frames.middle).pixels != nil && self.envelope(upscaled).pixels != nil
        }
        XCTAssertEqual(CVBufferCopyAttachment(middle, kCVImageBufferTransferFunctionKey, nil) as? String,
                       kCVImageBufferTransferFunction_ITU_R_709_2 as String, "no mutation while the engine owns the pair")
        engine.completeHeld(with: InterpolatedFrames(middle: middle, upscaledSource: upscaled))
        XCTAssertEqual(InterpolationColorTags(middle), InterpolationColorTags(current))
        XCTAssertEqual(InterpolationColorTags(upscaled), InterpolationColorTags(current))
        XCTAssertTrue(acceptedOutput, "both midpoint and optional upscaled source stay on the owned renderer")
    }

    func testDomainTransitionPrimesWithoutCallingEngineThenResumesWithMatchingTags() throws {
        let engine = FakeInterpolationEngine()
        let interpolator = makeInterpolator(engine: engine)
        let previous = try SmoothMotionPipelineTests.pixelBuffer(width: 64, height: 48, luma: 1)
        let current = try SmoothMotionPipelineTests.pixelBuffer(width: 64, height: 48, luma: 2)
        CVBufferSetAttachment(current, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        submit(previous, at: 0, to: interpolator)
        var primed = false
        submit(current, at: 1.0 / 60, to: interpolator) {
            if case .primed = $0 { primed = true }
        }
        XCTAssertTrue(primed)
        XCTAssertTrue(engine.pairs.isEmpty)
        submit(current, at: 2.0 / 60, to: interpolator)
        XCTAssertEqual(engine.pairs.count, 1)
        XCTAssertNotNil(envelope(try XCTUnwrap(engine.producedMiddles.last)).pixels)
    }

    func testMissingOrMalformedTagsNeverInventAColorDomain() throws {
        for malformed in [false, true] {
            let engine = FakeInterpolationEngine()
            let interpolator = makeInterpolator(engine: engine)
            let source = try SmoothMotionPipelineTests.pixelBuffer(width: 64, height: 48, luma: 1)
            if malformed {
                CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey, NSNumber(value: 709), .shouldPropagate)
            } else {
                CVBufferRemoveAttachment(source, kCVImageBufferYCbCrMatrixKey)
            }
            submit(source, at: 0, to: interpolator)
            submit(source, at: 1.0 / 60, to: interpolator)
            XCTAssertTrue(engine.pairs.isEmpty)
            XCTAssertNil(InterpolationColorTags(source))
        }
    }

    func testColorTagsSwitchOffRestoresUncheckedPairAndUntaggedOutput() throws {
        let engine = FakeInterpolationEngine()
        let interpolator = makeInterpolator(engine: engine, colorTags: false)
        let previous = try SmoothMotionPipelineTests.pixelBuffer(width: 64, height: 48, luma: 1)
        let current = try SmoothMotionPipelineTests.pixelBuffer(width: 64, height: 48, luma: 2)
        CVBufferRemoveAttachment(current, kCVImageBufferYCbCrMatrixKey)
        submit(previous, at: 0, to: interpolator)
        submit(current, at: 1.0 / 60, to: interpolator)
        XCTAssertEqual(engine.pairs.count, 1)
        let middle = try XCTUnwrap(engine.producedMiddles.last)
        XCTAssertNil(InterpolationColorTags(middle))
        XCTAssertNil(envelope(middle).pixels, "NO reproduces the old fallback-triggering output")
    }

    func testUnsupportedPrimariesTransferAndMatrixBypassButNoRestoresUncheckedPairing() throws {
        let unsupported: [(CFString, CFString)] = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020),
            (kCVImageBufferColorPrimariesKey, "unknown primaries" as CFString),
            (kCVImageBufferTransferFunctionKey, "unknown transfer" as CFString),
            (kCVImageBufferYCbCrMatrixKey, "unknown matrix" as CFString),
        ]
        for (key, value) in unsupported {
            for enabled in [true, false] {
                let engine = FakeInterpolationEngine()
                let interpolator = makeInterpolator(engine: engine, colorTags: enabled)
                let source = try SmoothMotionPipelineTests.pixelBuffer(width: 64, height: 48, luma: 1)
                CVBufferSetAttachment(source, key, value, .shouldPropagate)
                XCTAssertNil(InterpolationColorTags(source))
                submit(source, at: 0, to: interpolator)
                var primed = false
                submit(source, at: 1.0 / 60, to: interpolator) {
                    if case .primed = $0 { primed = true }
                }
                XCTAssertEqual(engine.pairs.count, enabled ? 0 : 1, "\(key): \(value), enabled=\(enabled)")
                XCTAssertEqual(primed, enabled, "ON shows the unsupported source directly without a synthetic frame")
            }
        }
    }

    func testClearingReusedBufferRemovesAllThreeColorKeys() throws {
        let buffer = try SmoothMotionPipelineTests.pixelBuffer(width: 64, height: 48, luma: 1)
        InterpolationColorTags.clear(buffer)
        for key in InterpolationColorTags.keys { XCTAssertNil(CVBufferCopyAttachment(buffer, key, nil)) }
    }
}

final class SmoothMotionDisplayCadenceTests: XCTestCase {
    func testInterpolationSwitchesReadMissingTypedAndLaunchArgumentStringValues() throws {
        let switches: [(String, (UserDefaults) -> Bool)] = [
            (InterpolationColorTagsSwitch.defaultsKey, InterpolationColorTagsSwitch.read(defaults:)),
            (InterpolationLPMBypassSwitch.defaultsKey, InterpolationLPMBypassSwitch.read(defaults:)),
        ]
        for (key, read) in switches {
            let suite = "SmoothMotionSwitchTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            defer {
                defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
                defaults.removePersistentDomain(forName: suite)
            }
            // Isolate from the test process's own A/B launch arguments.
            defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
            XCTAssertTrue(read(defaults), "missing \(key) defaults ON in the .7 test build")
            defaults.set(true, forKey: key)
            XCTAssertTrue(read(defaults))
            defaults.set(false, forKey: key)
            XCTAssertFalse(read(defaults))
            defaults.removeObject(forKey: key)
            defaults.setVolatileDomain([key: "YES"], forName: UserDefaults.argumentDomain)
            XCTAssertTrue(read(defaults), "launch argument YES enables \(key)")
            defaults.setVolatileDomain([key: "NO"], forName: UserDefaults.argumentDomain)
            XCTAssertFalse(read(defaults), "launch argument NO rolls back \(key)")
        }
    }

    func testSlowRunAndRecoveryRequireContinuousEvidenceAndUseDifferentThresholds() {
        var cadence = SmoothMotionDisplayCadence()
        for index in 0...132 { cadence.observe(at: Double(index) / 120) }
        XCTAssertTrue(cadence.permitsInterpolation)
        for index in 1...50 { cadence.observe(at: 1.1 + Double(index) / 60) }
        XCTAssertTrue(cadence.permitsInterpolation, "a short hitch does not switch the pipeline")
        for index in 51...66 { cadence.observe(at: 1.1 + Double(index) / 60) }
        XCTAssertFalse(cadence.permitsInterpolation)
        for index in 1...120 { cadence.observe(at: 2.2 + Double(index) * 0.0098) }
        XCTAssertFalse(cadence.permitsInterpolation, "inside the hysteresis band is not recovery")
        let resumed = 2.2 + 120 * 0.0098
        for index in 1...132 { cadence.observe(at: resumed + Double(index) / 120) }
        XCTAssertTrue(cadence.permitsInterpolation)
        cadence.observe(at: resumed + 2)
        XCTAssertFalse(cadence.permitsInterpolation, "background/idle gaps need fresh cadence evidence")
    }
}
