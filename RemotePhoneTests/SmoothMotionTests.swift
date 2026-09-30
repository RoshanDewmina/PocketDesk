import CoreVideo
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
}

final class SmoothMotionPipelineTests: XCTestCase {
    private var clock = 0.0
    private var engine: FakeInterpolationEngine!
    private var thermal = ProcessInfo.ThermalState.nominal
    private var delivered: [SmoothMotionController.Output] = []
    private var controller: SmoothMotionController!

    override func setUp() {
        super.setUp()
        engine = FakeInterpolationEngine()
        makeController(mode: .always)
    }

    private func makeController(mode: SmoothMotionMode, supported: Bool = true) {
        let environment = SmoothMotionController.Environment(
            makeEngine: { [unowned self] in supported ? engine : nil },
            supported: supported,
            limits: .documented,
            upscaleLimits: nil,
            now: { [unowned self] in clock },
            thermal: { [unowned self] in thermal },
            queue: DispatchQueue(label: "SmoothMotionTests"))
        controller = SmoothMotionController(mode: mode, environment: environment)
        delivered = []
        controller.deliver = { [unowned self] in delivered.append($0) }
        controller.displayTick(at: clock, framesPerSecond: 120, capable: true)
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
        producedMiddles.append(middle)
        completion(.success(InterpolatedFrames(middle: middle, upscaledSource: nil)))
    }

    func stop() {
        if setup != nil { stops += 1 }
        setup = nil
    }
}
