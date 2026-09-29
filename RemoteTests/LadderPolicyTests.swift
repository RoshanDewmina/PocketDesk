import XCTest

/// G12 (Docs/perf/PLAN-120FPS-AND-LOAD.md §4): the ladder engine, the busy state and the host monitor
/// that feeds them. Time is injected; one sample per second.
final class LadderPolicyTests: XCTestCase {
    /// Clean at every rung of a 120 fps ladder: the encoder keeps up, 3 ms latency, nothing limited.
    private func calm(targetFPS: Int = 120) -> LadderInputs {
        LadderInputs(targetFPS: targetFPS, captureFPS: Double(targetFPS), encodedFPS: Double(targetFPS),
                     encodeLatencyP90Ms: 3, encodeInFlightMax: 1, droppedBeforeEncode: 0, pacerDelayMs: 1,
                     targetKbps: 10_000, availableKbps: 20_000, qualityLimitation: "none", hostThermalState: "nominal",
                     phoneSupersededPerSecond: 0, phoneDecodeMs: 3, phonePresentedFPS: Double(targetFPS),
                     phoneThermalState: "nominal")
    }

    /// Bad at every rung: three frames in flight.
    private func backlog(targetFPS: Int = 120) -> LadderInputs {
        var inputs = calm(targetFPS: targetFPS)
        inputs.encodeInFlightMax = 3
        return inputs
    }

    private func with(_ change: (inout LadderInputs) -> Void) -> LadderInputs {
        var inputs = calm()
        change(&inputs)
        return inputs
    }

    private let ladder120 = LadderPolicy.ladder(targetFPS: 120)

    private func rung(_ index: Int, _ reason: String?) -> LadderState {
        var state = ladder120[index]
        state.reason = reason
        return state
    }

    // MARK: Rungs

    func testRungsFollowTheContractAndNeverRunFasterThanTheTarget() {
        XCTAssertEqual(LadderPolicy.ladder(targetFPS: 120), LadderState.rungs(targetFPS: 120))
        XCTAssertEqual(LadderPolicy.ladder(targetFPS: 60), LadderState.rungs(targetFPS: 60))
        XCTAssertEqual(ladder120.map(\.fps), [120, 120, 60, 60, 60, 30, 30])
        XCTAssertEqual(ladder120.map(\.sizeFraction), [1, 0.75, 1, 0.75, 0.5, 0.75, 0.5])
        let thirty = LadderPolicy.ladder(targetFPS: 30)
        XCTAssertEqual(thirty.map(\.fps), [30, 30, 30], "a 30 fps override is a size-only ladder")
        XCTAssertEqual(thirty.map(\.sizeFraction), [1, 0.75, 0.5])
        XCTAssertEqual(thirty.map(\.rung), [0, 1, 2])
        XCTAssertEqual(LadderPolicy.ladder(targetFPS: 45).map(\.fps), [45, 45, 30, 30])
        for target in [30, 45, 60, 90, 120] {
            let rungs = LadderPolicy.ladder(targetFPS: target)
            XCTAssertEqual(rungs.map(\.rung), Array(rungs.indices))
            XCTAssertTrue(rungs.allSatisfy { $0.fps <= target && $0.reason == nil })
            XCTAssertEqual(LadderPolicy(targetFPS: target).state, rungs[0])
            XCTAssertNoThrow(try rungs.forEach { try $0.validate() })
        }
    }

    // MARK: Down

    private struct Row {
        let name: String
        let inputs: LadderInputs
        var captureLatency: Double? = nil
        let trigger: LadderTrigger
        let reason: String
    }

    private var downRows: [Row] {
        [
            Row(name: "encoded under 80 % of the frames captured", inputs: with { $0.encodedFPS = 95 },
                trigger: .encodeShortfall, reason: "encoding"),
            Row(name: "encoder p90 over two frame intervals", inputs: with { $0.encodeLatencyP90Ms = 16.7 },
                trigger: .encodeLatency, reason: "encoding"),
            Row(name: "three frames in flight", inputs: with { $0.encodeInFlightMax = 3 },
                trigger: .encodeBacklog, reason: "encoding"),
            Row(name: "dropped over 5 % of the rung rate", inputs: with { $0.droppedBeforeEncode = 7 },
                trigger: .droppedBeforeEncode, reason: "encoding"),
            Row(name: "WebRTC says cpu", inputs: with { $0.qualityLimitation = "cpu" },
                trigger: .cpuLimited, reason: "encoding"),
            Row(name: "pacer over 50 ms", inputs: with { $0.pacerDelayMs = 51 },
                trigger: .pacerDelay, reason: "network"),
            Row(name: "estimate under 60 % of the target", inputs: with { $0.availableKbps = 5_999 },
                trigger: .lowEstimate, reason: "network"),
            Row(name: "WebRTC says bandwidth", inputs: with { $0.qualityLimitation = "bandwidth" },
                trigger: .bandwidthLimited, reason: "network"),
            Row(name: "Mac thermal serious", inputs: with { $0.hostThermalState = "serious" },
                trigger: .hostThermal, reason: "thermal"),
            Row(name: "Mac thermal critical", inputs: with { $0.hostThermalState = "critical" },
                trigger: .hostThermal, reason: "thermal"),
            Row(name: "superseded over 10 % of the rung rate", inputs: with { $0.phoneSupersededPerSecond = 13 },
                trigger: .phoneSuperseded, reason: "phone"),
            Row(name: "phone decode over one frame interval", inputs: with { $0.phoneDecodeMs = 8.4 },
                trigger: .phoneDecode, reason: "phone"),
            Row(name: "phone thermal serious", inputs: with { $0.phoneThermalState = "serious" },
                trigger: .phoneThermal, reason: "phone"),
            Row(name: "capture under 80 % and late", inputs: with { $0.captureFPS = 90; $0.encodedFPS = 90 },
                captureLatency: 9, trigger: .captureBehind, reason: "capture"),
        ]
    }

    func testEachDownTriggerFiresAloneWithItsReason() {
        XCTAssertEqual(LadderTrigger.firing(calm(), at: ladder120[0], captureLatencyP90Ms: 1), [])
        XCTAssertTrue(LadderPolicy.isClean(calm(), at: ladder120[0]))
        for row in downRows {
            XCTAssertEqual(LadderTrigger.firing(row.inputs, at: ladder120[0], captureLatencyP90Ms: row.captureLatency),
                           [row.trigger], row.name)
            XCTAssertEqual(row.trigger.reason.rawValue, row.reason, row.name)
        }
        let covered = Set(downRows.map(\.trigger))
        XCTAssertEqual(covered.count, LadderTrigger.allCases.count, "every trigger has a row")
        XCTAssertEqual(Set(downRows.map(\.reason)), Set(LadderReason.allCases.map(\.rawValue)))
    }

    func testEachDownTriggerStepsOneRungWithItsReason() throws {
        for row in downRows {
            var policy = LadderPolicy(targetFPS: 120)
            let first = policy.evaluate(row.inputs, captureLatencyP90Ms: row.captureLatency, at: 0)
            let moved: LadderState?
            if row.trigger.isThermal {
                moved = first
            } else {
                XCTAssertNil(first, "\(row.name): one sample is not enough")
                moved = policy.evaluate(row.inputs, captureLatencyP90Ms: row.captureLatency, at: 1)
            }
            let state = try XCTUnwrap(moved, row.name)
            XCTAssertEqual(state, rung(1, row.reason), row.name)
            XCTAssertEqual(policy.state, state)
            XCTAssertNoThrow(try state.validate())
        }
    }

    func testThresholdsAreStrictAndJustInsideIsQuiet() {
        let quiet: [(String, LadderInputs, Double?)] = [
            ("encoded at 81 %", with { $0.encodedFPS = 97 }, nil),
            ("latency under two intervals", with { $0.encodeLatencyP90Ms = 16.6 }, nil),
            ("two in flight", with { $0.encodeInFlightMax = 2 }, nil),
            ("6 dropped is 5 %", with { $0.droppedBeforeEncode = 6 }, nil),
            ("pacer at 50 ms", with { $0.pacerDelayMs = 50 }, nil),
            ("estimate at 60 %", with { $0.availableKbps = 6_000 }, nil),
            ("no target bitrate yet", with { $0.targetKbps = 0; $0.availableKbps = 100 }, nil),
            ("other limitation", with { $0.qualityLimitation = "other" }, nil),
            ("Mac thermal fair", with { $0.hostThermalState = "fair" }, nil),
            ("12 superseded is 10 %", with { $0.phoneSupersededPerSecond = 12 }, nil),
            ("decode under one interval", with { $0.phoneDecodeMs = 8.3 }, nil),
            ("phone thermal fair", with { $0.phoneThermalState = "fair" }, nil),
            ("capture at 81 % and late", with { $0.captureFPS = 97; $0.encodedFPS = 97 }, 9),
            ("capture low but on time", with { $0.captureFPS = 90; $0.encodedFPS = 90 }, 8.3),
            ("capture low, timing unknown", with { $0.captureFPS = 90; $0.encodedFPS = 90 }, nil),
            ("all unknown", LadderInputs(targetFPS: 120), nil),
        ]
        for (name, inputs, latency) in quiet {
            XCTAssertEqual(LadderTrigger.firing(inputs, at: ladder120[0], captureLatencyP90Ms: latency), [], name)
        }
    }

    func testAStillScreenOrSlowContentIsNotLoad() {
        var still = calm(targetFPS: 60)
        still.captureFPS = 0
        still.encodedFPS = 2.2
        let top60 = LadderPolicy.ladder(targetFPS: 60)[0]
        XCTAssertEqual(LadderTrigger.firing(still, at: top60, captureLatencyP90Ms: nil), [],
                       "ScreenCaptureKit sends no complete frames for a still desktop; the idle refresh is ~2 fps")
        XCTAssertTrue(LadderPolicy.isClean(still, at: top60), "a still screen is headroom, so the ladder can climb")

        var video = calm(targetFPS: 60)
        video.captureFPS = 30
        video.encodedFPS = 30
        XCTAssertEqual(LadderTrigger.firing(video, at: top60, captureLatencyP90Ms: 1.2), [], "a 30 fps video on time")
        XCTAssertTrue(LadderPolicy.isClean(video, at: top60))
        XCTAssertEqual(LadderTrigger.firing(video, at: top60, captureLatencyP90Ms: 20), [.captureBehind],
                       "the same rate delivered late is a busy Mac")

        var typing = calm(targetFPS: 60)
        typing.captureFPS = 5
        typing.encodedFPS = 3
        XCTAssertEqual(LadderTrigger.firing(typing, at: top60, captureLatencyP90Ms: 1), [],
                       "below half the rung rate a frame or two of counting skew is not a shortfall")
    }

    func testThresholdsFollowTheRungNotTheTarget() {
        let top = ladder120[0]
        let sixty = ladder120[2]
        let thirty = ladder120[5]
        let slowEncode = with { $0.encodeLatencyP90Ms = 20 }
        XCTAssertTrue(LadderTrigger.encodeLatency.fires(slowEncode, at: top), "20 ms is over 2 × 8.3 ms")
        XCTAssertFalse(LadderTrigger.encodeLatency.fires(slowEncode, at: sixty), "20 ms fits 2 × 16.7 ms")
        let slowDecode = with { $0.phoneDecodeMs = 10 }
        XCTAssertTrue(LadderTrigger.phoneDecode.fires(slowDecode, at: top))
        XCTAssertFalse(LadderTrigger.phoneDecode.fires(slowDecode, at: sixty))
        let dropped = with { $0.droppedBeforeEncode = 4 }
        XCTAssertFalse(LadderTrigger.droppedBeforeEncode.fires(dropped, at: top), "4 of 120 is 3 %")
        XCTAssertTrue(LadderTrigger.droppedBeforeEncode.fires(dropped, at: sixty), "4 of 60 is 7 %")
        let superseded = with { $0.phoneSupersededPerSecond = 8 }
        XCTAssertFalse(LadderTrigger.phoneSuperseded.fires(superseded, at: top))
        XCTAssertTrue(LadderTrigger.phoneSuperseded.fires(superseded, at: thirty))
        let sixtyEncoded = with { $0.encodedFPS = 60 }
        XCTAssertTrue(LadderTrigger.encodeShortfall.fires(sixtyEncoded, at: top))
        XCTAssertFalse(LadderTrigger.encodeShortfall.fires(sixtyEncoded, at: sixty), "60 encoded is the 60 rung's rate")
    }

    func testStepDownNeedsTwoBadSamplesInARow() {
        var policy = LadderPolicy(targetFPS: 120)
        XCTAssertNil(policy.evaluate(backlog(), at: 0))
        XCTAssertNil(policy.evaluate(calm(), at: 1), "a clean sample breaks the run")
        XCTAssertNil(policy.evaluate(backlog(), at: 2))
        XCTAssertEqual(policy.evaluate(backlog(), at: 3), rung(1, "encoding"), "second bad sample in a row: within 2 s")
        XCTAssertNil(policy.evaluate(backlog(), at: 4), "each step needs its own two samples")
        XCTAssertEqual(policy.evaluate(backlog(), at: 5), rung(2, "encoding"))
        var neutral = calm()
        neutral.encodedFPS = 50
        XCTAssertNil(policy.evaluate(backlog(), at: 6))
        XCTAssertNil(policy.evaluate(neutral, at: 7), "neither bad nor clean still breaks the run")
        XCTAssertNil(policy.evaluate(backlog(), at: 8))
        XCTAssertEqual(policy.evaluate(backlog(), at: 9), rung(3, "encoding"))
    }

    func testThermalStepsOnTheFirstSample() {
        var policy = LadderPolicy(targetFPS: 120)
        let hot = with { $0.hostThermalState = "serious" }
        XCTAssertEqual(policy.evaluate(hot, at: 0), rung(1, "thermal"))
        XCTAssertEqual(policy.evaluate(hot, at: 1), rung(2, "thermal"), "every serious sample steps")
        var mixed = hot
        mixed.encodeInFlightMax = 3
        XCTAssertEqual(policy.evaluate(mixed, at: 2), rung(3, "thermal"), "thermal outranks the encoder as the reason")
        XCTAssertEqual(policy.evaluate(with { $0.hostThermalState = "2" }, at: 3), rung(4, "thermal"))
    }

    func testTheReasonIsTheHighestPriorityTriggerOfTheMovingSample() {
        var policy = LadderPolicy(targetFPS: 120)
        XCTAssertNil(policy.evaluate(with { $0.pacerDelayMs = 80 }, at: 0))
        let both = with { $0.pacerDelayMs = 80; $0.encodeInFlightMax = 3 }
        XCTAssertEqual(policy.evaluate(both, at: 1), rung(1, "encoding"))
        XCTAssertNil(policy.evaluate(with { $0.encodeInFlightMax = 3 }, at: 2))
        XCTAssertEqual(policy.evaluate(with { $0.phoneDecodeMs = 30 }, at: 3), rung(2, "phone"),
                       "bad samples in a row may have different causes; the second names the move")
    }

    // MARK: Up

    func testStepUpAfterTenCleanSeconds() {
        var policy = LadderPolicy(targetFPS: 120)
        XCTAssertNil(policy.evaluate(backlog(), at: 0))
        XCTAssertEqual(policy.evaluate(backlog(), at: 1), rung(1, "encoding"))
        for second in 2...10 {
            XCTAssertNil(policy.evaluate(calm(), at: TimeInterval(second)), "second \(second)")
        }
        XCTAssertEqual(policy.evaluate(calm(), at: 11), ladder120[0], "10 s after the move; the top has no reason")
        XCTAssertNil(policy.evaluate(calm(), at: 12), "never above rung 0")
    }

    func testANeutralSampleRestartsTheCleanClock() {
        var policy = LadderPolicy(targetFPS: 120)
        _ = policy.evaluate(backlog(), at: 0)
        XCTAssertEqual(policy.evaluate(backlog(), at: 1), rung(1, "encoding"))
        for second in 2...6 { XCTAssertNil(policy.evaluate(calm(), at: TimeInterval(second))) }
        var neutral = calm()
        neutral.encodedFPS = 100
        XCTAssertFalse(LadderPolicy.isClean(neutral, at: ladder120[1]), "100 of 120 is not 95 %")
        XCTAssertEqual(LadderTrigger.firing(neutral, at: ladder120[1]), [], "and not under 80 %")
        XCTAssertNil(policy.evaluate(neutral, at: 7))
        for second in 8...16 { XCTAssertNil(policy.evaluate(calm(), at: TimeInterval(second)), "second \(second)") }
        XCTAssertEqual(policy.evaluate(calm(), at: 17), ladder120[0])

        var slow = calm()
        slow.encodeLatencyP90Ms = 9
        XCTAssertFalse(LadderPolicy.isClean(slow, at: ladder120[0]), "p90 must fit one frame interval to climb")
        var untraced = calm()
        untraced.encodeLatencyP90Ms = nil
        XCTAssertTrue(LadderPolicy.isClean(untraced, at: ladder120[0]), "an encoder without the trace can still climb")
        var unknown = calm()
        unknown.encodedFPS = nil
        XCTAssertFalse(LadderPolicy.isClean(unknown, at: ladder120[0]), "no encoded rate, no evidence of headroom")
    }

    func testAStepKeepsTheReasonUntilTheTop() {
        var policy = LadderPolicy(targetFPS: 120)
        for second in 0...3 { _ = policy.evaluate(with { $0.pacerDelayMs = 80 }, at: TimeInterval(second)) }
        XCTAssertEqual(policy.state, rung(2, "network"))
        for second in 4...12 { XCTAssertNil(policy.evaluate(calm(), at: TimeInterval(second))) }
        XCTAssertEqual(policy.evaluate(calm(), at: 13), rung(1, "network"))
        for second in 14...22 { XCTAssertNil(policy.evaluate(calm(), at: TimeInterval(second))) }
        XCTAssertEqual(policy.evaluate(calm(), at: 23), ladder120[0])
    }

    func testNoClimbWithinTenSecondsOfAnyMove() {
        var policy = LadderPolicy(targetFPS: 120)
        var moves: [(time: TimeInterval, state: LadderState)] = []
        // Two bad seconds, then clean for longer than the climb needs, three times over, then flapping.
        let script: [Bool] = (0..<3).flatMap { _ in [true, true] + Array(repeating: false, count: 12) }
            + (0..<10).flatMap { _ in [true, true, false, false, false] }
        for (second, bad) in script.enumerated() {
            let time = TimeInterval(second)
            if let state = policy.evaluate(bad ? backlog() : calm(), at: time) { moves.append((time, state)) }
        }
        XCTAssertEqual(moves.map { $0.state.rung }, [1, 0, 1, 0, 1, 0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(moves.map { $0.time }, [1, 11, 15, 25, 29, 39, 43, 48, 53, 58, 63, 68])
        for (previous, move) in zip(moves, moves.dropFirst()) where move.state.rung < previous.state.rung {
            XCTAssertGreaterThanOrEqual(move.time - previous.time, LadderPolicy.upAfter, "climb at \(move.time)")
        }
        XCTAssertEqual(policy.state, ladder120[6].with(reason: "encoding"), "flapping walks down, never back up")
    }

    func testAThermalMoveWaitsThirtySecondsBeforeClimbing() {
        var policy = LadderPolicy(targetFPS: 120)
        XCTAssertEqual(policy.evaluate(with { $0.hostThermalState = "serious" }, at: 0), rung(1, "thermal"))
        for second in 1...29 {
            XCTAssertNil(policy.evaluate(calm(), at: TimeInterval(second)), "second \(second)")
        }
        XCTAssertEqual(policy.evaluate(calm(), at: 30), ladder120[0])

        var later = LadderPolicy(targetFPS: 120)
        XCTAssertEqual(later.evaluate(with { $0.phoneThermalState = "critical" }, at: 0), rung(1, "phone"))
        _ = later.evaluate(backlog(), at: 1)
        XCTAssertEqual(later.evaluate(backlog(), at: 2), rung(2, "encoding"))
        for second in 3...29 {
            XCTAssertNil(later.evaluate(calm(), at: TimeInterval(second)), "a later move does not end the thermal wait")
        }
        XCTAssertEqual(later.evaluate(calm(), at: 30), rung(1, "encoding"))
        for second in 31...39 { XCTAssertNil(later.evaluate(calm(), at: TimeInterval(second))) }
        XCTAssertEqual(later.evaluate(calm(), at: 40), ladder120[0])
    }

    // MARK: Bounds and resets

    func testNeverBelowTheFloorNorAboveTheTop() {
        var policy = LadderPolicy(targetFPS: 120)
        var moves: [LadderState] = []
        for second in 0..<40 {
            if let state = policy.evaluate(backlog(), at: TimeInterval(second)) { moves.append(state) }
        }
        XCTAssertEqual(moves.map(\.rung), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(policy.state, ladder120[6].with(reason: "encoding"))
        XCTAssertEqual(policy.state.fps, 30)
        XCTAssertEqual(policy.state.sizeFraction, 0.5)
        XCTAssertNil(policy.evaluate(with { $0.hostThermalState = "critical" }, at: 40),
                     "thermal cannot go below either")

        var top = LadderPolicy(targetFPS: 120)
        for second in 0..<60 { XCTAssertNil(top.evaluate(calm(), at: TimeInterval(second))) }
        XCTAssertEqual(top.state, ladder120[0])
    }

    func testTheProtocolEntryPointHasNoCaptureTiming() {
        var policy = LadderPolicy(targetFPS: 120)
        let behind = with { $0.captureFPS = 60; $0.encodedFPS = 60 }
        for second in 0..<5 { XCTAssertNil(policy.evaluate(behind, at: TimeInterval(second))) }
        var timed = LadderPolicy(targetFPS: 120)
        XCTAssertNil(timed.evaluate(behind, captureLatencyP90Ms: 12, at: 0))
        XCTAssertEqual(timed.evaluate(behind, captureLatencyP90Ms: 12, at: 1), rung(1, "capture"))
    }

    func testATargetChangeRestartsAtTheTopOfTheNewLadder() {
        var policy = LadderPolicy(targetFPS: 120)
        for second in 0...5 { _ = policy.evaluate(backlog(), at: TimeInterval(second)) }
        XCTAssertEqual(policy.state.rung, 3)
        let sixty = LadderPolicy.ladder(targetFPS: 60)
        XCTAssertEqual(policy.evaluate(calm(targetFPS: 60), at: 6), sixty[0])
        XCTAssertEqual(policy.targetFPS, 60)
        XCTAssertEqual(policy.rungs, sixty)
        XCTAssertNil(policy.evaluate(calm(targetFPS: 60), at: 7))
        XCTAssertNil(policy.evaluate(backlog(targetFPS: 60), at: 8), "the bad-sample run restarts too")
        XCTAssertEqual(policy.evaluate(backlog(targetFPS: 60), at: 9), sixty[1].with(reason: "encoding"))

        var atTop = LadderPolicy(targetFPS: 60)
        XCTAssertEqual(atTop.evaluate(calm(targetFPS: 120), at: 0), ladder120[0], "a faster display starts at 120")
        XCTAssertNil(atTop.evaluate(calm(targetFPS: 120), at: 1))
    }

    func testUnchangedReturnsNil() {
        var policy = LadderPolicy(targetFPS: 60)
        for second in 0..<100 { XCTAssertNil(policy.evaluate(calm(targetFPS: 60), at: TimeInterval(second))) }
    }

    func testThermalStateNamesAndLevels() {
        XCTAssertEqual(LadderPolicy.thermalLevel("nominal"), 0)
        XCTAssertEqual(LadderPolicy.thermalLevel("Fair"), 1)
        XCTAssertEqual(LadderPolicy.thermalLevel("serious"), 2)
        XCTAssertEqual(LadderPolicy.thermalLevel("critical"), 3)
        XCTAssertEqual(LadderPolicy.thermalLevel("2"), 2)
        XCTAssertNil(LadderPolicy.thermalLevel("hot"))
        XCTAssertNil(LadderPolicy.thermalLevel(nil))
        let states: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        XCTAssertEqual(states.map { LadderPolicy.thermalLevel(HostLoadMonitor.thermalName($0)) }, [0, 1, 2, 3])
    }

    // MARK: Busy state

    /// A 2560 px session; capture latency 1 ms (on time) unless a test says otherwise.
    private func evaluate(_ busy: inout BusyPolicy, _ ladder: LadderState, _ inputs: LadderInputs? = nil,
                          captureLatency: Double = 1, at time: TimeInterval) -> BusyState? {
        busy.evaluate(ladder: ladder, inputs: inputs ?? calm(), longEdge: 2560, captureLatencyP90Ms: captureLatency,
                      at: time)
    }

    func testBusyStaysOkWhileTheLadderHoldsTheTop() {
        var busy = BusyPolicy()
        for second in 0..<30 { XCTAssertNil(evaluate(&busy, ladder120[0], at: TimeInterval(second))) }
        XCTAssertEqual(busy.state, .ok)
    }

    func testStrainedOnceARungBelowTheTopHoldsFiveSeconds() throws {
        var busy = BusyPolicy()
        for second in 0...4 {
            XCTAssertNil(evaluate(&busy, rung(1, "encoding"), at: TimeInterval(second)), "second \(second)")
        }
        let strained = try XCTUnwrap(evaluate(&busy, rung(1, "encoding"), at: 5))
        XCTAssertEqual(strained, BusyState(level: .strained, fps: 120, longEdge: 1920, reason: "encoding"))
        XCTAssertNoThrow(try strained.validate())
        XCTAssertNil(evaluate(&busy, rung(1, "encoding"), at: 6))
        XCTAssertEqual(evaluate(&busy, rung(2, "encoding"), at: 7),
                       BusyState(level: .strained, fps: 60, longEdge: 2560, reason: "encoding"),
                       "a further step keeps the level and reports what the user gets now")
    }

    func testBusyAtTheFloorAtOnce() {
        var busy = BusyPolicy()
        XCTAssertEqual(evaluate(&busy, rung(6, "encoding"), at: 0),
                       BusyState(level: .busy, fps: 30, longEdge: 1280, reason: "encoding"))
        for second in 1..<20 { XCTAssertNil(evaluate(&busy, rung(6, "encoding"), at: TimeInterval(second))) }
    }

    func testBusyWhenCaptureStaysBehindForFiveSeconds() {
        let behind = with { $0.captureFPS = 60; $0.encodedFPS = 60 }
        var busy = BusyPolicy()
        for second in 0...4 {
            XCTAssertNil(evaluate(&busy, ladder120[0], behind, captureLatency: 12, at: TimeInterval(second)))
        }
        XCTAssertEqual(evaluate(&busy, ladder120[0], behind, captureLatency: 12, at: 5),
                       BusyState(level: .busy, fps: 120, longEdge: 2560, reason: "capture"))

        var still = BusyPolicy()
        for second in 0..<20 {
            XCTAssertNil(evaluate(&still, ladder120[0], behind, at: TimeInterval(second)),
                         "few frames on time: a quiet screen, not a busy Mac")
        }
        var interrupted = BusyPolicy()
        for second in 0...3 {
            _ = evaluate(&interrupted, ladder120[0], behind, captureLatency: 12, at: TimeInterval(second))
        }
        XCTAssertNil(evaluate(&interrupted, ladder120[0], at: 4))
        for second in 5...9 {
            XCTAssertNil(evaluate(&interrupted, ladder120[0], behind, captureLatency: 12, at: TimeInterval(second)),
                         "the 5 s start again after a good second")
        }
        XCTAssertEqual(evaluate(&interrupted, ladder120[0], behind, captureLatency: 12, at: 10)?.level, .busy)
    }

    func testBusyWhenEncoderLatencyStaysOverTwoIntervalsForFiveSeconds() {
        let slow = with { $0.encodeLatencyP90Ms = 17 }
        var busy = BusyPolicy()
        for second in 0...4 { XCTAssertNil(evaluate(&busy, ladder120[0], slow, at: TimeInterval(second))) }
        XCTAssertEqual(evaluate(&busy, ladder120[0], slow, at: 5),
                       BusyState(level: .busy, fps: 120, longEdge: 2560, reason: "encoding"))
    }

    func testEachLevelClearsOnlyAfterTenSecondsOfHeadroom() {
        var busy = BusyPolicy()
        func step(_ index: Int, at time: TimeInterval) -> BusyState? {
            evaluate(&busy, index == 0 ? ladder120[0] : rung(index, "network"), at: time)
        }
        XCTAssertEqual(step(6, at: 0), BusyState(level: .busy, fps: 30, longEdge: 1280, reason: "network"))
        XCTAssertEqual(step(5, at: 1), BusyState(level: .busy, fps: 30, longEdge: 1920, reason: "network"),
                       "off the floor, busy holds but shows the new picture")
        for second in 2...9 { XCTAssertNil(step(5, at: TimeInterval(second)), "second \(second)") }
        XCTAssertEqual(step(5, at: 10), BusyState(level: .strained, fps: 30, longEdge: 1920, reason: "network"),
                       "10 s after the last busy second")
        XCTAssertNil(step(5, at: 11))
        XCTAssertEqual(step(0, at: 12), BusyState(level: .strained, fps: 120, longEdge: 2560, reason: "network"),
                       "back at the top, strained holds and keeps its reason")
        for second in 13...20 { XCTAssertNil(step(0, at: TimeInterval(second)), "second \(second)") }
        XCTAssertEqual(step(0, at: 21), .ok, "10 s after the last strained second")
        XCTAssertNil(step(0, at: 22))
    }

    func testTheReasonIsTheLaddersOrElseTheBusyTrigger() {
        var stepped = BusyPolicy()
        let slowAtSixty = with { $0.encodeLatencyP90Ms = 40 }
        for second in 0...5 { _ = evaluate(&stepped, rung(2, "network"), slowAtSixty, at: TimeInterval(second)) }
        XCTAssertEqual(stepped.state, BusyState(level: .busy, fps: 60, longEdge: 2560, reason: "network"))

        var top = BusyPolicy()
        let slowAtTop = with { $0.encodeLatencyP90Ms = 17 }
        for second in 0...5 { _ = evaluate(&top, ladder120[0], slowAtTop, at: TimeInterval(second)) }
        XCTAssertEqual(top.state.reason, "encoding")
    }

    func testBusyRestartsWhenTheTargetChanges() {
        var busy = BusyPolicy()
        XCTAssertEqual(evaluate(&busy, rung(6, "encoding"), at: 0)?.level, .busy)
        XCTAssertEqual(evaluate(&busy, LadderPolicy.ladder(targetFPS: 60)[0], calm(targetFPS: 60), at: 1), .ok)
    }

    func testTheProtocolEntryPointReportsNoSize() {
        var busy = BusyPolicy()
        XCTAssertEqual(busy.evaluate(ladder: rung(6, "encoding"), inputs: calm(), at: 0),
                       BusyState(level: .busy, fps: 30, longEdge: 0, reason: "encoding"))
    }

    // MARK: Host monitor

    private let sample = HostLoadSample(targetFPS: 120, longEdge: 2560, captureFPS: 118, captureLatencyP90Ms: 2.5,
                                        encodedFPS: 117, encodeLatencyP90Ms: 6.5, encodeInFlightMax: 2,
                                        droppedBeforeEncode: 1, pacerDelayMs: 0.4, targetKbps: 18_000,
                                        availableKbps: 30_000, qualityLimitation: "none", hostThermalState: "fair",
                                        lowPowerMode: false)

    private func assertTick(_ tick: (ladder: LadderState?, busy: BusyState?), ladder: LadderState?, busy: BusyState?,
                            _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(tick.ladder, ladder, message, file: file, line: line)
        XCTAssertEqual(tick.busy, busy, message, file: file, line: line)
    }

    func testMonitorMapsEverySampleField() {
        XCTAssertEqual(HostLoadMonitor.inputs(from: sample),
                       LadderInputs(targetFPS: 120, captureFPS: 118, encodedFPS: 117, encodeLatencyP90Ms: 6.5,
                                    encodeInFlightMax: 2, droppedBeforeEncode: 1, pacerDelayMs: 0.4, targetKbps: 18_000,
                                    availableKbps: 30_000, qualityLimitation: "none", hostThermalState: "fair",
                                    phoneSupersededPerSecond: nil, phoneDecodeMs: nil, phonePresentedFPS: nil,
                                    phoneThermalState: nil))
    }

    func testSampleFromTheHostReport() {
        var report = StreamStatsReport(role: "host", previous: nil, current: StreamStatsSample(entries: []),
                                       counters: nil)
        report.captureFPS = 118
        report.captureLatencyP90Ms = 2.5
        report.encodedFPS = 117
        report.encodeLatencyP90Ms = 6.5
        report.encodeInFlightMax = 2
        report.droppedBeforeEncode = 1
        report.pacerDelayMs = 0.4
        report.targetKbps = 18_000
        report.availableOutgoingKbps = 30_000
        report.qualityLimitation = "none"
        report.sentKbps = 9_000
        XCTAssertEqual(HostLoadSample(report: report, targetFPS: 120, longEdge: 2560, hostThermalState: "fair",
                                      lowPowerMode: false), sample)
    }

    func testTickRunsTheLadderThenTheBusyState() {
        var monitor = HostLoadMonitor(targetFPS: 120)
        var bad = sample
        bad.encodeInFlightMax = 3
        assertTick(monitor.tick(sample: bad, at: 0), ladder: nil, busy: nil)
        assertTick(monitor.tick(sample: bad, at: 1), ladder: rung(1, "encoding"), busy: nil)
        assertTick(monitor.tick(sample: bad, at: 2), ladder: nil, busy: nil)
        assertTick(monitor.tick(sample: bad, at: 3), ladder: rung(2, "encoding"), busy: nil)
        assertTick(monitor.tick(sample: bad, at: 4), ladder: nil, busy: nil)
        assertTick(monitor.tick(sample: bad, at: 5), ladder: rung(3, "encoding"), busy: nil)
        let strained = BusyState(level: .strained, fps: 60, longEdge: 1920, reason: "encoding")
        assertTick(monitor.tick(sample: bad, at: 6), ladder: nil, busy: strained,
                   "5 s below the top since the first move")
        var unsized = bad
        unsized.longEdge = nil
        let smaller = BusyState(level: .strained, fps: 60, longEdge: 1280, reason: "encoding")
        assertTick(monitor.tick(sample: unsized, at: 7), ladder: rung(4, "encoding"), busy: smaller,
                   "nil keeps the last long edge")
        XCTAssertEqual(monitor.longEdge, 2560)
        XCTAssertEqual(monitor.ladder.state, rung(4, "encoding"))
        XCTAssertEqual(monitor.busy.state, smaller)
    }

    func testTickPassesCaptureTimingToBothPolicies() {
        var monitor = HostLoadMonitor(targetFPS: 120)
        var behind = sample
        behind.captureFPS = 60
        behind.encodedFPS = 60
        behind.captureLatencyP90Ms = 12
        _ = monitor.tick(sample: behind, at: 0)
        XCTAssertEqual(monitor.tick(sample: behind, at: 1).ladder, rung(1, "capture"))
        var onTime = behind
        onTime.captureLatencyP90Ms = 1
        var quiet = HostLoadMonitor(targetFPS: 120)
        for second in 0..<20 {
            assertTick(quiet.tick(sample: onTime, at: TimeInterval(second)), ladder: nil, busy: nil)
        }
    }
}

private extension LadderState {
    func with(reason: String?) -> LadderState {
        var state = self
        state.reason = reason
        return state
    }
}
