import XCTest

/// G12 (Docs/perf/PLAN-120FPS-AND-LOAD.md §4): the ladder engine, the busy state and the host monitor
/// that feeds them. Time is injected; one sample per second.
final class LadderPolicyTests: XCTestCase {
    /// Clean at every rung of a 120 fps ladder: the encoder keeps up, 3 ms latency, capture on time.
    private func calm(targetFPS: Int = 120) -> LadderInputs {
        LadderInputs(targetFPS: targetFPS, captureFPS: Double(targetFPS), captureLatencyP90Ms: 1,
                     encodedFPS: Double(targetFPS), encodeLatencyP90Ms: 3, encodeInFlightMax: 1, droppedBeforeEncode: 0,
                     pacerDelayMs: 1, targetKbps: 10_000, availableKbps: 20_000, qualityLimitation: "none",
                     hostThermalState: "nominal", hostLowPowerMode: false, phoneSupersededPerSecond: 0,
                     phoneDecodeMs: 3, phonePresentedFPS: Double(targetFPS), phoneThermalState: "nominal")
    }

    /// Bad at every rung, two samples to act: two frames in flight, each slower than any rung's interval.
    private func backlog(targetFPS: Int = 120) -> LadderInputs {
        var inputs = calm(targetFPS: targetFPS)
        inputs.encodeInFlightMax = 2
        inputs.encodeLatencyP90Ms = 34
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

    /// Runs one sample per second and returns the moves.
    private func run(_ policy: inout LadderPolicy, _ seconds: ClosedRange<Int>,
                     _ inputs: (Int) -> LadderInputs) -> [(time: Int, state: LadderState)] {
        var moves: [(time: Int, state: LadderState)] = []
        for second in seconds {
            if let state = policy.evaluate(inputs(second), at: TimeInterval(second)) { moves.append((second, state)) }
        }
        return moves
    }

    // MARK: Rungs

    func testRungsFollowTheContractAndNeverRunFasterThanTheTarget() {
        XCTAssertEqual(LadderPolicy.ladder(targetFPS: 120), LadderState.rungs(targetFPS: 120))
        XCTAssertEqual(LadderPolicy.ladder(targetFPS: 60), LadderState.rungs(targetFPS: 60))
        XCTAssertEqual(ladder120.map(\.fps), [120, 60, 60, 30, 30])
        XCTAssertEqual(ladder120.map(\.sizeFraction), [1, 1, 0.75, 0.75, 0.5])
        let thirty = LadderPolicy.ladder(targetFPS: 30)
        XCTAssertEqual(thirty.map(\.fps), [30, 30, 30], "a 30 fps override is a size-only ladder")
        XCTAssertEqual(thirty.map(\.sizeFraction), [1, 0.75, 0.5])
        XCTAssertEqual(thirty.map(\.rung), [0, 1, 2])
        XCTAssertEqual(LadderPolicy.ladder(targetFPS: 45).map(\.fps), [45, 30, 30, 30])
        for target in [30, 45, 60, 90, 120] {
            let rungs = LadderPolicy.ladder(targetFPS: target)
            XCTAssertEqual(rungs.map(\.rung), Array(rungs.indices))
            XCTAssertTrue(rungs.allSatisfy { $0.fps <= target && $0.reason == nil })
            for (higher, lower) in zip(rungs, rungs.dropFirst()) {
                XCTAssertLessThanOrEqual(lower.fps, higher.fps)
                XCTAssertLessThanOrEqual(lower.sizeFraction, higher.sizeFraction)
                XCTAssertLessThanOrEqual(Double(lower.fps) * lower.sizeFraction * lower.sizeFraction,
                                         Double(higher.fps) * higher.sizeFraction * higher.sizeFraction)
            }
            XCTAssertEqual(LadderPolicy(targetFPS: target).state, rungs[0])
            XCTAssertNoThrow(try rungs.forEach { try $0.validate() })
        }
        XCTAssertEqual([30, 45, 60, 90, 120].map { LadderPolicy(targetFPS: $0).lowPowerRung }, [0, 0, 0, 1, 1])
    }

    // MARK: Down

    private struct Row {
        let name: String
        let inputs: LadderInputs
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
            Row(name: "two frames in flight, slower than the interval",
                inputs: with { $0.encodeInFlightMax = 2; $0.encodeLatencyP90Ms = 9 },
                trigger: .encodeQueue, reason: "encoding"),
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
            Row(name: "superseded over 25 % with few presented",
                inputs: with { $0.phoneSupersededPerSecond = 31; $0.phonePresentedFPS = 90 },
                trigger: .phoneSuperseded, reason: "phone"),
            Row(name: "phone decode over one frame interval", inputs: with { $0.phoneDecodeMs = 8.4 },
                trigger: .phoneDecode, reason: "phone"),
            Row(name: "phone thermal serious", inputs: with { $0.phoneThermalState = "serious" },
                trigger: .phoneThermal, reason: "phone"),
            Row(name: "capture under 80 % and late",
                inputs: with { $0.captureFPS = 90; $0.encodedFPS = 90; $0.captureLatencyP90Ms = 9 },
                trigger: .captureBehind, reason: "capture"),
        ]
    }

    func testEachDownTriggerFiresAloneWithItsReason() {
        XCTAssertEqual(LadderTrigger.firing(calm(), at: ladder120[0]), [])
        XCTAssertTrue(LadderPolicy.isClean(calm(), at: ladder120[0]))
        for row in downRows {
            XCTAssertEqual(LadderTrigger.firing(row.inputs, at: ladder120[0]), [row.trigger], row.name)
            XCTAssertEqual(row.trigger.reason.rawValue, row.reason, row.name)
        }
        XCTAssertEqual(Set(downRows.map(\.trigger)).count, LadderTrigger.allCases.count, "every trigger has a row")
        XCTAssertEqual(Set(downRows.map(\.reason)), Set(LadderReason.allCases.map(\.rawValue)).subtracting(["power", "phonePower"]),
                       "every reason but power comes from a trigger")
    }

    func testEachDownTriggerStepsOneRungWithItsReason() throws {
        for row in downRows {
            var policy = LadderPolicy(targetFPS: 120)
            let first = policy.evaluate(row.inputs, at: 0)
            let moved: LadderState?
            if row.trigger.isThermal || row.trigger.isImmediate {
                moved = first
            } else {
                XCTAssertNil(first, "\(row.name): one sample is not enough")
                moved = policy.evaluate(row.inputs, at: 1)
            }
            let state = try XCTUnwrap(moved, row.name)
            XCTAssertEqual(state, rung(1, row.reason), row.name)
            XCTAssertEqual(policy.state, state)
            XCTAssertNoThrow(try state.validate())
        }
    }

    func testThresholdsAreStrictAndJustInsideIsQuiet() {
        let quiet: [(String, LadderInputs)] = [
            ("encoded at 81 %", with { $0.encodedFPS = 97 }),
            ("latency under two intervals", with { $0.encodeLatencyP90Ms = 16.6 }),
            ("6 dropped is 5 %", with { $0.droppedBeforeEncode = 6 }),
            ("pacer at 50 ms", with { $0.pacerDelayMs = 50 }),
            ("estimate at 60 %", with { $0.availableKbps = 6_000 }),
            ("no target bitrate yet", with { $0.targetKbps = 0; $0.availableKbps = 100 }),
            ("other limitation", with { $0.qualityLimitation = "other" }),
            ("Mac thermal fair", with { $0.hostThermalState = "fair" }),
            ("30 superseded is 25 %", with { $0.phoneSupersededPerSecond = 30; $0.phonePresentedFPS = 90 }),
            ("bunching alone", with { $0.phoneSupersededPerSecond = 60 }),
            ("superseded, no other phone signal",
             with { $0.phoneSupersededPerSecond = 60; $0.phoneDecodeMs = nil; $0.phonePresentedFPS = nil }),
            ("decode under one interval", with { $0.phoneDecodeMs = 8.3 }),
            ("phone thermal fair", with { $0.phoneThermalState = "fair" }),
            ("capture at 81 % and late", with { $0.captureFPS = 97; $0.encodedFPS = 97; $0.captureLatencyP90Ms = 9 }),
            ("capture low but on time", with { $0.captureFPS = 90; $0.encodedFPS = 90; $0.captureLatencyP90Ms = 8.3 }),
            ("capture low, timing unknown",
             with { $0.captureFPS = 90; $0.encodedFPS = 90; $0.captureLatencyP90Ms = nil }),
            ("Low Power Mode is a cap, not a trigger", with { $0.hostLowPowerMode = true }),
            ("all unknown", LadderInputs(targetFPS: 120)),
        ]
        for (name, inputs) in quiet {
            XCTAssertEqual(LadderTrigger.firing(inputs, at: ladder120[0]), [], name)
        }
    }

    func testSupersededFramesNeedASecondPhoneSignal() {
        let slowDecode = with { $0.phoneSupersededPerSecond = 31; $0.phoneDecodeMs = 8.4 }
        XCTAssertEqual(LadderTrigger.firing(slowDecode, at: ladder120[0]), [.phoneSuperseded, .phoneDecode])
        let fewPresented = with { $0.phoneSupersededPerSecond = 31; $0.phonePresentedFPS = 95 }
        XCTAssertEqual(LadderTrigger.firing(fewPresented, at: ladder120[0]), [.phoneSuperseded])
        let enoughPresented = with { $0.phoneSupersededPerSecond = 31; $0.phonePresentedFPS = 97 }
        XCTAssertEqual(LadderTrigger.firing(enoughPresented, at: ladder120[0]), [])
        let atThirty = with { $0.phoneSupersededPerSecond = 8; $0.phonePresentedFPS = 20 }
        XCTAssertTrue(LadderTrigger.phoneSuperseded.fires(atThirty, at: ladder120[3]), "8 of 30 is over 25 %")
        let sevenAtThirty = with { $0.phoneSupersededPerSecond = 7; $0.phonePresentedFPS = 20 }
        XCTAssertFalse(LadderTrigger.phoneSuperseded.fires(sevenAtThirty, at: ladder120[3]))
        var policy = LadderPolicy(targetFPS: 120)
        XCTAssertNil(policy.evaluate(fewPresented, at: 0), "two samples, like every load trigger")
        XCTAssertEqual(policy.evaluate(fewPresented, at: 1), rung(1, "phone"))
    }

    func testAStillScreenOrSlowContentIsNotLoad() {
        var still = calm(targetFPS: 60)
        still.captureFPS = 0
        still.encodedFPS = 2.2
        let top60 = LadderPolicy.ladder(targetFPS: 60)[0]
        XCTAssertEqual(LadderTrigger.firing(still, at: top60), [],
                       "ScreenCaptureKit sends no complete frames for a still desktop; the idle refresh is ~2 fps")
        XCTAssertTrue(LadderPolicy.isClean(still, at: top60), "a still screen is headroom, so the ladder can climb")

        var video = calm(targetFPS: 60)
        video.captureFPS = 30
        video.encodedFPS = 30
        video.captureLatencyP90Ms = 1.2
        XCTAssertEqual(LadderTrigger.firing(video, at: top60), [], "a 30 fps video on time")
        XCTAssertTrue(LadderPolicy.isClean(video, at: top60))
        video.captureLatencyP90Ms = 20
        XCTAssertEqual(LadderTrigger.firing(video, at: top60), [.captureBehind],
                       "the same rate delivered late is a busy Mac")

        var typing = calm(targetFPS: 60)
        typing.captureFPS = 5
        typing.encodedFPS = 3
        XCTAssertEqual(LadderTrigger.firing(typing, at: top60), [],
                       "below half the rung rate a frame or two of counting skew is not a shortfall")
    }

    func testThresholdsFollowTheRungNotTheTarget() {
        let top = ladder120[0]
        let sixty = ladder120[1]
        let thirty = ladder120[3]
        let slowEncode = with { $0.encodeLatencyP90Ms = 20 }
        XCTAssertTrue(LadderTrigger.encodeLatency.fires(slowEncode, at: top), "20 ms is over 2 × 8.3 ms")
        XCTAssertFalse(LadderTrigger.encodeLatency.fires(slowEncode, at: sixty), "20 ms fits 2 × 16.7 ms")
        let slowDecode = with { $0.phoneDecodeMs = 10 }
        XCTAssertTrue(LadderTrigger.phoneDecode.fires(slowDecode, at: top))
        XCTAssertFalse(LadderTrigger.phoneDecode.fires(slowDecode, at: sixty))
        let dropped = with { $0.droppedBeforeEncode = 4 }
        XCTAssertFalse(LadderTrigger.droppedBeforeEncode.fires(dropped, at: top), "4 of 120 is 3 %")
        XCTAssertTrue(LadderTrigger.droppedBeforeEncode.fires(dropped, at: sixty), "4 of 60 is 7 %")
        let lateCapture = with { $0.captureFPS = 40; $0.encodedFPS = 40; $0.captureLatencyP90Ms = 12 }
        XCTAssertTrue(LadderTrigger.captureBehind.fires(lateCapture, at: top))
        XCTAssertFalse(LadderTrigger.captureBehind.fires(lateCapture, at: sixty), "12 ms is on time at 60")
        let sixtyEncoded = with { $0.encodedFPS = 60 }
        XCTAssertTrue(LadderTrigger.encodeShortfall.fires(sixtyEncoded, at: top))
        XCTAssertFalse(LadderTrigger.encodeShortfall.fires(sixtyEncoded, at: sixty), "60 encoded is the 60 rung's rate")
        XCTAssertFalse(LadderTrigger.encodeShortfall.fires(with { $0.encodedFPS = 25 }, at: thirty))
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

    func testThreeFramesInFlightStepAtOnceAndTwoNeedTwoSamples() {
        var policy = LadderPolicy(targetFPS: 120)
        let three = with { $0.encodeInFlightMax = 3 }
        XCTAssertEqual(policy.evaluate(three, at: 0), rung(1, "encoding"), "a 40 ms queue does not wait a second")
        XCTAssertEqual(policy.evaluate(three, at: 1), rung(2, "encoding"), "and steps each second it holds")
        XCTAssertNil(policy.evaluate(backlog(), at: 2), "two in flight is a queue forming: two samples")
        XCTAssertEqual(policy.evaluate(backlog(), at: 3), rung(3, "encoding"))
        XCTAssertNil(policy.evaluate(with { $0.pacerDelayMs = 80 }, at: 4))
        XCTAssertEqual(policy.evaluate(with { $0.pacerDelayMs = 80; $0.encodeInFlightMax = 5 }, at: 5),
                       rung(4, "encoding"))
    }

    func testThermalStepsOnItsFirstSampleButAtMostOncePerTenSeconds() {
        var policy = LadderPolicy(targetFPS: 120)
        let hot = with { $0.hostThermalState = "serious" }
        XCTAssertEqual(policy.evaluate(hot, at: 0), rung(1, "thermal"))
        for second in 1...9 { XCTAssertNil(policy.evaluate(hot, at: TimeInterval(second)), "second \(second)") }
        XCTAssertEqual(policy.evaluate(hot, at: 10), rung(2, "thermal"))
        XCTAssertEqual(policy.evaluate(with { $0.hostThermalState = "2" }, at: 20), rung(3, "thermal"))

        var phone = LadderPolicy(targetFPS: 120)
        let hotPhone = with { $0.phoneThermalState = "critical" }
        XCTAssertEqual(run(&phone, 0...20) { _ in hotPhone }.map { $0.time }, [0, 10, 20], "the phone is limited too")

        var mixed = LadderPolicy(targetFPS: 120)
        let hotAndBacklogged = with { $0.hostThermalState = "serious"; $0.encodeInFlightMax = 2; $0.encodeLatencyP90Ms = 34 }
        let moves = run(&mixed, 0...10) { _ in hotAndBacklogged }
        XCTAssertEqual(moves.map { $0.time }, [0, 2, 4, 6], "load keeps its own two-sample pace until the floor")
        XCTAssertEqual(moves.map { $0.state.reason },
                       ["thermal", "encoding", "encoding", "encoding"])
    }

    func testTheReasonIsTheHighestPriorityTriggerOfTheMovingSample() {
        var policy = LadderPolicy(targetFPS: 120)
        XCTAssertNil(policy.evaluate(with { $0.pacerDelayMs = 80 }, at: 0))
        let both = with { $0.pacerDelayMs = 80; $0.encodeInFlightMax = 2; $0.encodeLatencyP90Ms = 9 }
        XCTAssertEqual(policy.evaluate(both, at: 1), rung(1, "encoding"))
        XCTAssertNil(policy.evaluate(with { $0.encodeInFlightMax = 2; $0.encodeLatencyP90Ms = 17 }, at: 2))
        XCTAssertEqual(policy.evaluate(with { $0.phoneDecodeMs = 30 }, at: 3), rung(2, "phone"),
                       "bad samples in a row may have different causes; the second names the move")
    }

    /// 20260930 M4 Air stream stats: at the 30 fps full-size rung HEVC took p90 17-19 ms with an
    /// occasional second frame in flight while encoding all 30 fps. That is headroom, not a queue.
    func testAnOccasionalOverlapUnderTheIntervalIsNotAQueue() {
        var sixty = LadderPolicy(targetFPS: 60)
        let thirty = sixty.rungs[1]
        XCTAssertEqual(thirty.fps, 30); XCTAssertEqual(thirty.sizeFraction, 1)
        var overlap = calm(targetFPS: 60)
        overlap.captureFPS = 57; overlap.encodedFPS = 30; overlap.encodeLatencyP90Ms = 17.8; overlap.encodeInFlightMax = 2
        XCTAssertEqual(LadderTrigger.firing(overlap, at: thirty), [])
        XCTAssertTrue(LadderPolicy.isClean(overlap, at: thirty))
        XCTAssertTrue(LadderTrigger.firing(overlap, at: sixty.rungs[0]).contains(.encodeQueue),
                      "the same overlap at 60 fps is slower than the 16.7 ms interval: a queue")
        var queued = overlap; queued.encodeLatencyP90Ms = nil
        XCTAssertEqual(LadderTrigger.firing(queued, at: thirty), [.encodeQueue], "no latency trace keeps the old rule")

        var stepped = calm(targetFPS: 60); stepped.encodeInFlightMax = 2; stepped.encodeLatencyP90Ms = 34
        _ = sixty.evaluate(stepped, at: 0)
        XCTAssertEqual(sixty.evaluate(stepped, at: 1)?.rung, 1)
        _ = sixty.evaluate(stepped, at: 2)
        XCTAssertEqual(sixty.evaluate(stepped, at: 3)?.rung, 2)
        var moves: [Int] = []
        for second in 4...40 {
            if let move = sixty.evaluate(overlap, at: TimeInterval(second)) { moves.append(move.rung) }
        }
        XCTAssertEqual(moves.first, 1, "climbs back to full size and stays there")
        XCTAssertEqual(sixty.state.rung, moves.last)
        XCTAssertFalse(moves.dropFirst().contains(2), "no failed climb back to 0.75")
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

    func testOneFrameBucketJitterDoesNotBlockRecoveryAtThirtyFPS() {
        var policy = LadderPolicy(targetFPS: 120)
        for second in 0...5 { _ = policy.evaluate(backlog(), at: TimeInterval(second)) }
        XCTAssertEqual(policy.state, rung(3, "encoding"))

        for second in 6...14 {
            var sample = calm()
            sample.captureFPS = 57
            sample.encodedFPS = second.isMultiple(of: 2) ? 28 : 29
            sample.encodeLatencyP90Ms = 9
            XCTAssertEqual(LadderTrigger.firing(sample, at: policy.state), [])
            XCTAssertTrue(LadderPolicy.isClean(sample, at: policy.state))
            XCTAssertNil(policy.evaluate(sample, at: TimeInterval(second)))
        }
        var final = calm()
        final.captureFPS = 57
        final.encodedFPS = 29
        final.encodeLatencyP90Ms = 9
        XCTAssertEqual(policy.evaluate(final, at: 15), rung(2, "encoding"),
                       "ordinary 28/29-frame buckets must not reset the 10-second recovery clock")
    }

    func testANeutralSampleRestartsTheCleanClock() {
        var policy = LadderPolicy(targetFPS: 120)
        _ = policy.evaluate(backlog(), at: 0)
        XCTAssertEqual(policy.evaluate(backlog(), at: 1), rung(1, "encoding"))
        for second in 2...6 { XCTAssertNil(policy.evaluate(calm(), at: TimeInterval(second))) }
        var neutral = calm()
        neutral.encodedFPS = 100
        neutral.encodedFPS = 50
        XCTAssertFalse(LadderPolicy.isClean(neutral, at: ladder120[1]), "50 of 60 is not 95 %")
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
        unknown.encodedFPS = -0.1
        XCTAssertFalse(LadderPolicy.isClean(unknown, at: ladder120[0]), "an invalid negative rate is not headroom")
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
        // Two bad seconds then twelve clean, three times over, then flapping (two bad, three clean).
        let script: [Bool] = (0..<3).flatMap { _ in [true, true] + Array(repeating: false, count: 12) }
            + (0..<10).flatMap { _ in [true, true, false, false, false] }
        let moves = run(&policy, 0...(script.count - 1)) { script[$0] ? self.backlog() : self.calm() }
        XCTAssertEqual(moves.map { $0.state.rung }, [1, 0, 1, 2, 3, 4])
        XCTAssertEqual(moves.map { $0.time }, [1, 11, 15, 29, 43, 48],
                       "the climb at 11 failed at 15, so the next climb waits 20 s and never comes")
        for (previous, move) in zip(moves, moves.dropFirst()) where move.state.rung < previous.state.rung {
            XCTAssertGreaterThanOrEqual(move.time - previous.time, 10, "climb at \(move.time)")
        }
        XCTAssertEqual(policy.state, ladder120[4].with(reason: "encoding"), "flapping walks down, never back up")
        XCTAssertEqual(policy.climbWait, 20)
    }

    func testFailedClimbsBackOffTenTwentyFortySixty() {
        var policy = LadderPolicy(targetFPS: 120)
        let bad: Set<Int> = [0, 1, 12, 13, 34, 35, 76, 77, 138, 139]
        var moves: [(time: Int, rung: Int, wait: TimeInterval)] = []
        var waits: [Int: TimeInterval] = [:]
        for second in 0...330 {
            if policy.evaluate(bad.contains(second) ? backlog() : calm(), at: TimeInterval(second)) != nil {
                moves.append((second, policy.state.rung, policy.climbWait))
            }
            waits[second] = policy.climbWait
        }
        XCTAssertEqual(moves.map { $0.time }, [1, 11, 13, 33, 35, 75, 77, 137, 139, 199])
        XCTAssertEqual(moves.map { $0.rung }, [1, 0, 1, 0, 1, 0, 1, 0, 1, 0])
        XCTAssertEqual(moves.map { $0.wait }, [10, 10, 20, 20, 40, 40, 60, 60, 60, 60], "10, 20, 40, 60, capped")
        XCTAssertEqual(waits[318], 60)
        XCTAssertEqual(waits[319], 10, "120 s on one rung resets the backoff")
    }

    func testBackoffRestartsWhenTheCauseChanges() {
        var policy = LadderPolicy(targetFPS: 120)
        let encoderBad: Set<Int> = [0, 1, 12, 13, 62, 63]
        let networkBad: Set<Int> = [50, 51]
        let slowPacer = with { $0.pacerDelayMs = 80 }
        let moves = run(&policy, 0...90) { second in
            if encoderBad.contains(second) { return self.backlog() }
            return networkBad.contains(second) ? slowPacer : self.calm()
        }
        XCTAssertEqual(moves.map { $0.time }, [1, 11, 13, 33, 51, 61, 63, 83])
        XCTAssertEqual(moves.map { $0.state.reason },
                       ["encoding", nil, "encoding", nil, "network", nil, "encoding", nil])
        XCTAssertEqual(policy.climbWait, 20,
                       "a new cause restarts the wait at 10 s, and the climb that just failed doubles it once")
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

    // MARK: Low Power Mode

    func testLowPowerModeCapsTheTopAtTheFirstSixtyRung() {
        var policy = LadderPolicy(targetFPS: 120)
        let saving = with { $0.hostLowPowerMode = true }
        XCTAssertEqual(policy.evaluate(saving, at: 0), rung(1, "power"), "one move to 60 fps at full size")
        for second in 1...40 { XCTAssertNil(policy.evaluate(saving, at: TimeInterval(second)), "never above the cap") }

        var savingBacklog = saving
        savingBacklog.encodeInFlightMax = 2
        savingBacklog.encodeLatencyP90Ms = 17
        XCTAssertNil(policy.evaluate(savingBacklog, at: 41))
        XCTAssertEqual(policy.evaluate(savingBacklog, at: 42), rung(2, "encoding"), "load still steps below the cap")
        for second in 43...51 { XCTAssertNil(policy.evaluate(saving, at: TimeInterval(second))) }
        XCTAssertEqual(policy.evaluate(saving, at: 52), rung(1, "power"), "back to the cap, which is power's again")
        for second in 53...62 { XCTAssertNil(policy.evaluate(saving, at: TimeInterval(second))) }
        XCTAssertEqual(policy.evaluate(calm(), at: 63), ladder120[0], "Low Power Mode off: climbing resumes")
    }

    func testLowPowerModeNeverPushesBelowTheCap() {
        var policy = LadderPolicy(targetFPS: 120)
        _ = run(&policy, 0...7) { _ in self.backlog() }
        XCTAssertEqual(policy.state, rung(4, "encoding"))
        let saving = with { $0.hostLowPowerMode = true }
        let moves = run(&policy, 8...40) { _ in saving }
        XCTAssertEqual(moves.map { $0.time }, [17, 27, 37])
        XCTAssertEqual(moves.map { $0.state }, [rung(3, "encoding"), rung(2, "encoding"), rung(1, "power")])

        var sixty = LadderPolicy(targetFPS: 60)
        var saving60 = calm(targetFPS: 60)
        saving60.hostLowPowerMode = true
        XCTAssertTrue(run(&sixty, 0...20) { _ in saving60 }.isEmpty, "a 60 fps session is already at the cap")
    }

    // MARK: Bounds and resets

    func testNeverBelowTheFloorNorAboveTheTop() {
        var policy = LadderPolicy(targetFPS: 120)
        let moves = run(&policy, 0...39) { _ in self.backlog() }
        XCTAssertEqual(moves.map { $0.state.rung }, [1, 2, 3, 4])
        XCTAssertEqual(policy.state, ladder120[4].with(reason: "encoding"))
        XCTAssertEqual(policy.state.fps, 30)
        XCTAssertEqual(policy.state.sizeFraction, 0.5)
        XCTAssertNil(policy.evaluate(with { $0.hostThermalState = "critical" }, at: 40),
                     "thermal cannot go below either")

        var top = LadderPolicy(targetFPS: 120)
        XCTAssertTrue(run(&top, 0...59) { _ in self.calm() }.isEmpty)
        XCTAssertEqual(top.state, ladder120[0])
    }

    func testCaptureNeedsItsTimingInTheInputs() {
        var policy = LadderPolicy(targetFPS: 120)
        let behind = with { $0.captureFPS = 60; $0.encodedFPS = 60; $0.captureLatencyP90Ms = nil }
        XCTAssertTrue(run(&policy, 0...4) { _ in behind }.isEmpty, "few frames and no timing: nothing to go on")
        var late = behind
        late.captureLatencyP90Ms = 12
        var timed = LadderPolicy(targetFPS: 120)
        XCTAssertNil(timed.evaluate(late, at: 0))
        XCTAssertEqual(timed.evaluate(late, at: 1), rung(1, "capture"))
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

        var saving = LadderPolicy(targetFPS: 60)
        XCTAssertEqual(saving.evaluate(with { $0.hostLowPowerMode = true }, at: 0), rung(1, "power"),
                       "the new ladder's power cap applies in the same second")
    }

    func testUnchangedReturnsNil() {
        var policy = LadderPolicy(targetFPS: 60)
        XCTAssertTrue(run(&policy, 0...99) { _ in self.calm(targetFPS: 60) }.isEmpty)
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

    /// A 2560 px session.
    private func evaluate(_ busy: inout BusyPolicy, _ ladder: LadderState, _ inputs: LadderInputs? = nil,
                          at time: TimeInterval) -> BusyState? {
        busy.evaluate(ladder: ladder, inputs: inputs ?? calm(), longEdge: 2560, at: time)
    }

    func testBusyStaysOkWhileTheLadderHoldsTheTop() {
        var busy = BusyPolicy()
        for second in 0..<30 { XCTAssertNil(evaluate(&busy, ladder120[0], at: TimeInterval(second))) }
        XCTAssertEqual(busy.state, .ok)
    }

    func testAStepForLoadShowsNothing() {
        for reason in ["encoding", "capture", "network", "phone"] {
            var busy = BusyPolicy()
            for (second, index) in [(0, 1), (5, 2), (12, 3), (20, 4), (40, 3), (50, 0)] {
                XCTAssertNil(evaluate(&busy, index == 0 ? ladder120[0] : rung(index, reason), at: TimeInterval(second)),
                             "\(reason) step to rung \(index): the ladder heals it, so no pill")
            }
            XCTAssertEqual(busy.state, .ok)
        }
    }

    func testStrainedForEightSecondsAfterAStepForAHotMacOrLowPower() throws {
        var busy = BusyPolicy()
        let strained = try XCTUnwrap(evaluate(&busy, rung(1, "thermal"), at: 0))
        XCTAssertEqual(strained, BusyState(level: .strained, fps: 60, longEdge: 2560, reason: "thermal"))
        XCTAssertNoThrow(try strained.validate())
        for second in 1...7 { XCTAssertNil(evaluate(&busy, rung(1, "thermal"), at: TimeInterval(second))) }
        XCTAssertEqual(evaluate(&busy, rung(1, "thermal"), at: 8), .ok,
                       "then ok although the rung stays below the top")
        for second in 9...30 {
            XCTAssertNil(evaluate(&busy, rung(1, "thermal"), at: TimeInterval(second)), "no permanent pill")
        }
        XCTAssertEqual(evaluate(&busy, rung(2, "power"), at: 31),
                       BusyState(level: .strained, fps: 60, longEdge: 1920, reason: "power"))
        XCTAssertEqual(evaluate(&busy, rung(3, "power"), at: 35),
                       BusyState(level: .strained, fps: 30, longEdge: 1920, reason: "power"),
                       "a further step restarts the eight seconds")
        for second in 36...42 { XCTAssertNil(evaluate(&busy, rung(3, "power"), at: TimeInterval(second))) }
        XCTAssertEqual(evaluate(&busy, rung(3, "power"), at: 43), .ok)
        XCTAssertNil(evaluate(&busy, rung(2, "power"), at: 44), "a climb is not news")
    }

    func testACalmFloorShowsNothing() {
        var busy = BusyPolicy()
        var floor = LadderPolicy.ladder(targetFPS: 60)[3]
        floor.reason = "phone"
        var screenshot = calm(targetFPS: 60)
        screenshot.captureFPS = 57
        screenshot.encodedFPS = 29
        screenshot.encodeLatencyP90Ms = 8.3
        screenshot.phoneSupersededPerSecond = 5
        screenshot.phoneDecodeMs = 3.3
        screenshot.phonePresentedFPS = 27

        for second in 0...30 {
            XCTAssertNil(evaluate(&busy, floor, screenshot, at: TimeInterval(second)))
        }
    }

    func testBusyAtTheFloorRequiresCurrentPressureAndClearsAfterBoundedCalm() {
        var busy = BusyPolicy()
        let floor = rung(4, "phone")
        let phonePressure = with { $0.phoneSupersededPerSecond = 8; $0.phonePresentedFPS = 20 }
        for second in 0...4 {
            XCTAssertNil(evaluate(&busy, floor, phonePressure, at: TimeInterval(second)),
                         "under five seconds of pressure is not yet persistent trouble")
        }
        XCTAssertEqual(evaluate(&busy, floor, phonePressure, at: 5),
                       BusyState(level: .busy, fps: 30, longEdge: 1280, reason: "phone"))
        XCTAssertNil(evaluate(&busy, floor, at: 6), "one calm sample must not flicker the warning")
        XCTAssertEqual(busy.state, BusyState(level: .busy, fps: 30, longEdge: 1280, reason: "phone"))
        XCTAssertNil(evaluate(&busy, floor, phonePressure, at: 7),
                     "a live intermittent sample refreshes the calm clock without changing the pill")
        for second in 8...16 { XCTAssertNil(evaluate(&busy, floor, at: TimeInterval(second))) }
        XCTAssertEqual(evaluate(&busy, floor, at: 17), .ok,
                       "the historical floor reason cannot refresh ten seconds without current pressure")

        var interrupted = BusyPolicy()
        for second in 0...3 { XCTAssertNil(evaluate(&interrupted, floor, phonePressure, at: TimeInterval(second))) }
        XCTAssertNil(evaluate(&interrupted, floor, at: 4))
        for second in 5...9 { XCTAssertNil(evaluate(&interrupted, floor, phonePressure, at: TimeInterval(second))) }
        XCTAssertEqual(evaluate(&interrupted, floor, phonePressure, at: 10)?.level, .busy,
                       "the five seconds start again after a calm one")

        var hot = BusyPolicy()
        XCTAssertEqual(evaluate(&hot, rung(4, "thermal"), with { $0.hostThermalState = "serious" }, at: 0),
                       BusyState(level: .busy, fps: 30, longEdge: 1280, reason: "thermal"),
                       "a hot Mac at the floor is persistent by nature")
    }

    func testBusyWhenCaptureStaysBehindForFiveSeconds() {
        let behind = with { $0.captureFPS = 60; $0.encodedFPS = 60; $0.captureLatencyP90Ms = 12 }
        var busy = BusyPolicy()
        for second in 0...4 { XCTAssertNil(evaluate(&busy, ladder120[0], behind, at: TimeInterval(second))) }
        XCTAssertEqual(evaluate(&busy, ladder120[0], behind, at: 5),
                       BusyState(level: .busy, fps: 120, longEdge: 2560, reason: "capture"))

        var onTime = behind
        onTime.captureLatencyP90Ms = 1
        var still = BusyPolicy()
        for second in 0..<20 {
            XCTAssertNil(evaluate(&still, ladder120[0], onTime, at: TimeInterval(second)),
                         "few frames on time: a quiet screen, not a busy Mac")
        }
        var interrupted = BusyPolicy()
        for second in 0...3 { _ = evaluate(&interrupted, ladder120[0], behind, at: TimeInterval(second)) }
        XCTAssertNil(evaluate(&interrupted, ladder120[0], at: 4))
        for second in 5...9 {
            XCTAssertNil(evaluate(&interrupted, ladder120[0], behind, at: TimeInterval(second)),
                         "the 5 s start again after a good second")
        }
        XCTAssertEqual(evaluate(&interrupted, ladder120[0], behind, at: 10)?.level, .busy)
    }

    func testBusyWhenEncoderLatencyStaysOverTwoIntervalsForFiveSeconds() {
        let slow = with { $0.encodeLatencyP90Ms = 17 }
        var busy = BusyPolicy()
        for second in 0...4 { XCTAssertNil(evaluate(&busy, ladder120[0], slow, at: TimeInterval(second))) }
        XCTAssertEqual(evaluate(&busy, ladder120[0], slow, at: 5),
                       BusyState(level: .busy, fps: 120, longEdge: 2560, reason: "encoding"))
    }

    func testBusyClearsAfterTenSecondsWithoutCurrentPressureIntoAnyRecentStepWindow() {
        let slow = with { $0.encodeLatencyP90Ms = 17 }
        var busy = BusyPolicy()
        for second in 0...4 { XCTAssertNil(evaluate(&busy, ladder120[0], slow, at: TimeInterval(second))) }
        XCTAssertEqual(evaluate(&busy, ladder120[0], slow, at: 5)?.level, .busy)
        for second in 6...9 { XCTAssertNil(evaluate(&busy, ladder120[0], slow, at: TimeInterval(second))) }
        for second in 10...11 { XCTAssertNil(evaluate(&busy, ladder120[0], at: TimeInterval(second))) }
        XCTAssertEqual(evaluate(&busy, rung(1, "encoding"), at: 12),
                       BusyState(level: .busy, fps: 60, longEdge: 2560, reason: "encoding"))
        for second in 13...18 { XCTAssertNil(evaluate(&busy, rung(1, "encoding"), at: TimeInterval(second))) }
        XCTAssertEqual(evaluate(&busy, rung(1, "encoding"), at: 19), .ok,
                       "the hold ends ten seconds after the last current pressure; the step itself shows nothing")
    }

    func testBusyNamesTheCurrentTriggerBeforeTheHistoricalLadderReason() {
        var stepped = BusyPolicy()
        let slowAtSixty = with { $0.encodeLatencyP90Ms = 40 }
        for second in 0...5 { _ = evaluate(&stepped, rung(1, "network"), slowAtSixty, at: TimeInterval(second)) }
        XCTAssertEqual(stepped.state, BusyState(level: .busy, fps: 60, longEdge: 2560, reason: "encoding"))
        XCTAssertNil(evaluate(&stepped, rung(1, "network"), at: 6))
        XCTAssertEqual(stepped.state.reason, "encoding", "the hold keeps the last live cause")

        var top = BusyPolicy()
        let slowAtTop = with { $0.encodeLatencyP90Ms = 17 }
        for second in 0...5 { _ = evaluate(&top, ladder120[0], slowAtTop, at: TimeInterval(second)) }
        XCTAssertEqual(top.state.reason, "encoding")
    }

    func testBusyRestartsWhenTheTargetChanges() {
        var busy = BusyPolicy()
        let phonePressure = with { $0.phoneSupersededPerSecond = 8; $0.phonePresentedFPS = 20 }
        for second in 0...4 { _ = evaluate(&busy, rung(4, "phone"), phonePressure, at: TimeInterval(second)) }
        XCTAssertEqual(evaluate(&busy, rung(4, "phone"), phonePressure, at: 5)?.level, .busy)
        XCTAssertEqual(evaluate(&busy, LadderPolicy.ladder(targetFPS: 60)[0], calm(targetFPS: 60), at: 6), .ok)
    }

    func testTheProtocolEntryPointReportsNoSize() {
        var busy = BusyPolicy()
        let phonePressure = with { $0.phoneSupersededPerSecond = 8; $0.phonePresentedFPS = 20 }
        for second in 0...4 { _ = busy.evaluate(ladder: rung(4, "phone"), inputs: phonePressure, at: TimeInterval(second)) }
        XCTAssertEqual(busy.evaluate(ladder: rung(4, "phone"), inputs: phonePressure, at: 5),
                       BusyState(level: .busy, fps: 30, longEdge: 0, reason: "phone"))
    }

    // MARK: Still screen (device test, 1 Oct 2026)

    /// A still Mac screen as the 1 Oct LAN session reported it: no complete frames, the idle refresh
    /// at ~1 fps, a healthy LAN, and a phone whose per-window counters cover one or two frames. The
    /// first sample after a ladder move carries the one new-size key frame: a capture frame, a
    /// 100-260 ms pacer wait, and a slow single decode on the phone.
    private func stillSample(afterMove: Bool) -> HostLoadSample {
        var report = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []), counters: nil)
        report.decodeMs = afterMove ? 45 : 38
        report.presentedFPS = afterMove ? 2 : 1
        report.supersededPerSecond = afterMove ? 1 : 0
        report.thermalState = 0
        report.lowPowerMode = false
        return HostLoadSample(targetFPS: 60, longEdge: 2560, captureFPS: afterMove ? 1 : 0, captureLatencyP90Ms: 4,
                              encodedFPS: afterMove ? 2 : 1, encodeLatencyP90Ms: 3.4, encodeInFlightMax: 1,
                              droppedBeforeEncode: 0, pacerDelayMs: afterMove ? 194 : 0, targetKbps: 19_385,
                              availableKbps: 25_000, qualityLimitation: "none", hostThermalState: "fair",
                              lowPowerMode: false, phoneLoad: PhoneLoadFeedback(report: report), sentKbps: 10,
                              senderQueueMs: afterMove ? 194 : 0, networkQueueMs: 1, routeDetail: "lan",
                              sentFPS: afterMove ? 2 : 1)
    }

    func testAnIdleSourceWithAHealthyPhoneAndNetworkNeverStepsDownAndClimbsBackToTheTop() {
        var monitor = HostLoadMonitor(targetFPS: 60)
        var overloaded = sample
        overloaded.targetFPS = 60
        overloaded.encodeInFlightMax = 2
        overloaded.encodeLatencyP90Ms = 34
        for second in 0...5 { _ = monitor.tick(sample: overloaded, at: TimeInterval(second)) }
        XCTAssertEqual(monitor.ladder.state.rung, 3, "start at the floor, half size, as on the device")

        var moves: [(time: Int, rung: Int)] = []
        var justMoved = true
        for second in 6...100 {
            let tick = monitor.tick(sample: stillSample(afterMove: justMoved), at: TimeInterval(second))
            XCTAssertNil(tick.busy, "second \(second): a still screen is not trouble, so no pill")
            justMoved = tick.ladder != nil
            if let ladder = tick.ladder { moves.append((second, ladder.rung)) }
        }
        XCTAssertEqual(moves.map(\.rung), [2, 1, 0], "only climbs, one rung at a time, back to full size")
        XCTAssertEqual(moves.map(\.time), [16, 27, 38],
                       "10 s after each new-size key frame's pacer wait, the step's included")
        XCTAssertEqual(monitor.ladder.state, LadderPolicy.ladder(targetFPS: 60)[0])
        XCTAssertEqual(monitor.ladder.climbWait, 10, "no climb failed, so the wait never doubled")
        XCTAssertEqual(monitor.busy.state, .ok)
        XCTAssertEqual(moves.last?.time, 38, "then 62 still seconds at the top: no move, so no encoder restart")
    }

    func testTheStillWindowsThatSteppedTheDeviceDownAreNotLoad() {
        let rungTwo = LadderPolicy.ladder(targetFPS: 60)[2]
        let keyFrame = HostLoadMonitor.inputs(from: stillSample(afterMove: true))
        XCTAssertEqual(LadderTrigger.firing(keyFrame, at: rungTwo), [],
                       "row 9349: one key frame's 194 ms pacer wait on a still screen is not a queue")
        XCTAssertFalse(LadderPolicy.isClean(keyFrame, at: rungTwo), "but it does not count toward a climb")
        let refresh = HostLoadMonitor.inputs(from: stillSample(afterMove: false))
        XCTAssertEqual(LadderTrigger.firing(refresh, at: rungTwo), [],
                       "row 9350 (the 'phone' step): 1 fps sent, so 1 presented and a 38 ms decode are the Mac's choice")
        XCTAssertTrue(LadderPolicy.isClean(refresh, at: rungTwo))

        var moving = keyFrame
        moving.captureFPS = 30
        moving.encodedFPS = 30
        moving.sentFPS = 30
        XCTAssertEqual(LadderTrigger.firing(moving, at: rungTwo), [.pacerDelay, .phoneDecode],
                       "the same waits while the picture moves are load")
    }

    func testAGenuinePhoneOverloadStillStepsDown() {
        let top = LadderPolicy.ladder(targetFPS: 60)[0]
        var overload = calm(targetFPS: 60)
        overload.sentFPS = 60
        overload.phonePresentedFPS = 30
        overload.phoneSupersededPerSecond = 30
        overload.phoneDecodeMs = 10
        XCTAssertEqual(LadderTrigger.firing(overload, at: top), [.phoneSuperseded])
        var policy = LadderPolicy(targetFPS: 60)
        XCTAssertNil(policy.evaluate(overload, at: 0))
        var stepped = LadderPolicy.ladder(targetFPS: 60)[1]
        stepped.reason = "phone"
        XCTAssertEqual(policy.evaluate(overload, at: 1), stepped, "sent 60, presented 30: the phone cannot keep up")

        var slowDecode = calm(targetFPS: 60)
        slowDecode.sentFPS = 60
        slowDecode.phoneDecodeMs = 17
        XCTAssertEqual(LadderTrigger.firing(slowDecode, at: top), [.phoneDecode], "17 ms per frame at 60 sent")
        slowDecode.sentFPS = 40
        XCTAssertEqual(LadderTrigger.firing(slowDecode, at: top), [], "40 sent leave 25 ms per frame")
        slowDecode.phoneDecodeMs = 26
        XCTAssertEqual(LadderTrigger.firing(slowDecode, at: top), [.phoneDecode])
        slowDecode.sentFPS = 24
        slowDecode.phoneDecodeMs = 45
        XCTAssertEqual(LadderTrigger.firing(slowDecode, at: top), [.phoneDecode],
                       "24 fps video leaves 41.7 ms a frame; 45 ms cannot keep up")
        slowDecode.sentFPS = 9
        slowDecode.phoneDecodeMs = 200
        XCTAssertEqual(LadderTrigger.firing(slowDecode, at: top), [],
                       "under 10 frames a second are too few to judge the phone by")

        var thin = calm(targetFPS: 60)
        thin.sentFPS = 10
        thin.phonePresentedFPS = 5
        thin.phoneSupersededPerSecond = 3
        XCTAssertEqual(LadderTrigger.firing(thin, at: top), [.phoneSuperseded], "3 of 10 replaced, 5 shown")
        thin.phoneSupersededPerSecond = 2
        XCTAssertEqual(LadderTrigger.firing(thin, at: top), [], "two replaced frames are noise")

        var fewSent = overload
        fewSent.sentFPS = 30
        fewSent.phonePresentedFPS = 25
        fewSent.phoneSupersededPerSecond = 5
        XCTAssertEqual(LadderTrigger.firing(fewSent, at: top), [],
                       "25 of the 30 sent shown is keeping up, though under 80 % of the rung's 60")
    }

    func testAKeyFrameSpreadOverTwoStillWindowsIsNotLoad() {
        var policy = LadderPolicy(targetFPS: 60)
        for second in 0...5 { _ = policy.evaluate(backlog(targetFPS: 60), at: TimeInterval(second)) }
        XCTAssertEqual(policy.state.rung, 3)
        var first = HostLoadMonitor.inputs(from: stillSample(afterMove: true))
        first.pacerDelayMs = 420
        var second = first
        second.captureFPS = 0
        second.pacerDelayMs = 1_348
        XCTAssertNil(policy.evaluate(first, at: 6))
        XCTAssertNil(policy.evaluate(second, at: 7), "two windows of one key frame's wait: no step")
        XCTAssertEqual(policy.state.rung, 3)
    }

    func testAClimbOnAStillScreenThatFailsOnTheNextScrollStillBacksOff() {
        var policy = LadderPolicy(targetFPS: 60)
        _ = policy.evaluate(backlog(targetFPS: 60), at: 0)
        XCTAssertEqual(policy.evaluate(backlog(targetFPS: 60), at: 1)?.rung, 1)
        let still = HostLoadMonitor.inputs(from: stillSample(afterMove: false))
        var climbedAt: Int?
        for second in 2...40 where policy.evaluate(still, at: TimeInterval(second)) != nil { climbedAt = second }
        XCTAssertEqual(climbedAt, 11, "a still screen is headroom")
        XCTAssertEqual(policy.state.rung, 0)
        XCTAssertNil(policy.evaluate(backlog(targetFPS: 60), at: 41))
        XCTAssertEqual(policy.evaluate(backlog(targetFPS: 60), at: 42)?.rung, 1,
                       "30 s after the climb, but on the scroll's second sample")
        XCTAssertEqual(policy.climbWait, 20, "the climb was never tested by a moving picture, so it failed")
        var next: Int?
        for second in 43...80 where policy.evaluate(still, at: TimeInterval(second)) != nil {
            next = next ?? second
        }
        XCTAssertEqual(next, 62, "the doubled wait")
    }

    func testTheBusyReasonIsThePersistentCauseNeverAKeyFrameSpike() throws {
        var floor = LadderPolicy.ladder(targetFPS: 60)[3]
        floor.reason = "phone"
        var still = BusyPolicy()
        for second in 0...30 {
            let inputs = HostLoadMonitor.inputs(from: stillSample(afterMove: second.isMultiple(of: 5)))
            XCTAssertNil(still.evaluate(ladder: floor, inputs: inputs, longEdge: 2560, at: TimeInterval(second)),
                         "second \(second): the device showed 'connection is slow' here")
        }

        var phoneBusy = BusyPolicy()
        var overload = calm(targetFPS: 60)
        overload.sentFPS = 30
        overload.phonePresentedFPS = 15
        overload.phoneSupersededPerSecond = 15
        for second in 0...4 {
            XCTAssertNil(phoneBusy.evaluate(ladder: floor, inputs: overload, longEdge: 2560, at: TimeInterval(second)))
        }
        let shown = BusyState(level: .busy, fps: 30, longEdge: 1280, reason: "phone")
        XCTAssertEqual(phoneBusy.evaluate(ladder: floor, inputs: overload, longEdge: 2560, at: 5), shown)
        var spike = calm(targetFPS: 60)
        spike.captureFPS = 30
        spike.encodedFPS = 30
        spike.sentFPS = 30
        spike.pacerDelayMs = 194
        XCTAssertEqual(LadderTrigger.firing(spike, at: floor), [.pacerDelay])
        XCTAssertNil(phoneBusy.evaluate(ladder: floor, inputs: spike, longEdge: 2560, at: 6),
                     "one network sample during a phone hold neither renames nor extends it")
        for second in 7...14 {
            XCTAssertNil(phoneBusy.evaluate(ladder: floor, inputs: calm(targetFPS: 60), longEdge: 2560, at: TimeInterval(second)))
        }
        XCTAssertEqual(phoneBusy.evaluate(ladder: floor, inputs: calm(targetFPS: 60), longEdge: 2560, at: 15), .ok)
        let words = try XCTUnwrap(BusyPresentation(shown))
        XCTAssertEqual(words.title, "Your iPhone is busy")

        var networkBusy = BusyPolicy()
        for second in 0...4 { _ = networkBusy.evaluate(ladder: floor, inputs: spike, longEdge: 2560, at: TimeInterval(second)) }
        XCTAssertEqual(networkBusy.evaluate(ladder: floor, inputs: spike, longEdge: 2560, at: 5)?.reason, "network",
                       "five seconds of a real queue at the floor is the connection")
    }

    // MARK: Host monitor

    private let sample = HostLoadSample(targetFPS: 120, longEdge: 2560, captureFPS: 118, captureLatencyP90Ms: 2.5,
                                        encodedFPS: 117, encodeLatencyP90Ms: 6.5, encodeInFlightMax: 1,
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
                       LadderInputs(targetFPS: 120, captureFPS: 118, captureLatencyP90Ms: 2.5, encodedFPS: 117,
                                    encodeLatencyP90Ms: 6.5, encodeInFlightMax: 1, droppedBeforeEncode: 1,
                                    pacerDelayMs: 0.4, targetKbps: 18_000, availableKbps: 30_000,
                                    qualityLimitation: "none", hostThermalState: "fair", hostLowPowerMode: false,
                                    phoneSupersededPerSecond: nil, phoneDecodeMs: nil, phonePresentedFPS: nil,
                                    phoneThermalState: nil, phoneLowPowerMode: nil))
    }

    func testReplacementPressureUsesActualCounterWindowInsteadOfRawCount() throws {
        let sample = StreamStatsSample(entries: [])
        for (seconds, count, expectedRate, fires) in [(0.5, 10, 20, true), (1.0, 10, 10, true), (2.0, 10, 5, false)] {
            var counters = StreamCounterSnapshot(interval: seconds)
            counters.presentedFrames = Int(20 * seconds)
            counters.supersededFrames = count
            let report = StreamStatsReport(role: "phone", previous: nil, current: sample, counters: counters)
            XCTAssertEqual(report.supersededFrames, count, "diagnostics keep the original count")
            let feedback = PhoneLoadFeedback(report: report)
            XCTAssertEqual(feedback.supersededPerSecond, expectedRate)
            XCTAssertEqual(feedback.presentedFPS, 20)
            XCTAssertNoThrow(try feedback.validate())
            XCTAssertEqual(try JSONDecoder().decode(PhoneLoadFeedback.self, from: JSONEncoder().encode(feedback)), feedback)
            var inputs = calm(targetFPS: 30)
            inputs.phoneSupersededPerSecond = feedback.supersededPerSecond
            inputs.phonePresentedFPS = feedback.presentedFPS
            XCTAssertEqual(LadderTrigger.phoneSuperseded.fires(inputs, at: LadderState.rungs(targetFPS: 30)[0]), fires)
        }
        // Equal physical replacement rates must stay equal as the reporting window varies.
        for seconds in [0.5, 1.0, 2.0] {
            var counters = StreamCounterSnapshot(interval: seconds)
            counters.presentedFrames = Int(20 * seconds)
            counters.supersededFrames = Int(10 * seconds)
            let report = StreamStatsReport(role: "phone", previous: nil, current: sample, counters: counters)
            XCTAssertEqual(PhoneLoadFeedback(report: report).supersededPerSecond, 10)
        }
    }

    func testUnknownAndInvalidReplacementRatesDoNotBecomePhonePressure() throws {
        let sample = StreamStatsSample(entries: [])
        var report = StreamStatsReport(role: "phone", previous: nil, current: sample, counters: nil)
        report.supersededFrames = 999
        XCTAssertNil(PhoneLoadFeedback(report: report).supersededPerSecond, "a count without duration is unknown")
        let legacy = try JSONDecoder().decode(StreamStatsReport.self, from: Data(#"{"role":"phone","supersededFrames":999}"#.utf8))
        XCTAssertNil(PhoneLoadFeedback(report: legacy).supersededPerSecond)
        for interval in [0.0, -1, .nan, .infinity, .leastNonzeroMagnitude] {
            var counters = StreamCounterSnapshot(interval: interval)
            counters.presentedFrames = 20
            counters.supersededFrames = 10
            let invalid = StreamStatsReport(role: "phone", previous: nil, current: sample, counters: counters)
            XCTAssertNil(invalid.supersededPerSecond, "invalid/overflow windows must not add a nonfinite report scalar")
            XCTAssertNoThrow(try JSONEncoder().encode(invalid))
            XCTAssertNil(PhoneLoadFeedback(report: invalid).supersededPerSecond)
            XCTAssertNil(invalid.presentedFPS)
        }
        for rate in [-1.0, .nan, .infinity, 1_001] {
            report.supersededPerSecond = rate
            XCTAssertNil(PhoneLoadFeedback(report: report).supersededPerSecond)
        }
        report.supersededPerSecond = 0
        XCTAssertEqual(PhoneLoadFeedback(report: report).supersededPerSecond, 0)
    }

    func testMonitorMapsFreshPhoneReportAndExpiresIt() {
        var report = StreamStatsReport(role: "phone", previous: nil,
                                       current: StreamStatsSample(entries: []), counters: nil)
        report.supersededFrames = 31
        report.supersededPerSecond = 31
        report.decodeMs = 9
        report.presentedFPS = 80
        report.thermalState = 2
        report.lowPowerMode = true
        let feedback = PhoneLoadFeedback(report: report)
        XCTAssertEqual(HostLoadMonitor.currentPhoneLoad(feedback, receivedAt: 10, now: 12.5), feedback)
        XCTAssertNil(HostLoadMonitor.currentPhoneLoad(feedback, receivedAt: 10, now: 12.501))
        XCTAssertNil(HostLoadMonitor.currentPhoneLoad(feedback, receivedAt: 10, now: 9))
        XCTAssertNil(HostLoadMonitor.currentPhoneLoad(feedback, receivedAt: nil, now: 10))
        var withPhone = sample
        withPhone.phoneLoad = feedback
        let inputs = HostLoadMonitor.inputs(from: withPhone)
        XCTAssertEqual(inputs.phoneSupersededPerSecond, 31)
        XCTAssertEqual(inputs.phoneDecodeMs, 9)
        XCTAssertEqual(inputs.phonePresentedFPS, 80)
        XCTAssertEqual(inputs.phoneThermalState, "2")
        XCTAssertEqual(inputs.phoneLowPowerMode, true)

        withPhone.phoneLoad = nil
        let oldPeer = HostLoadMonitor.inputs(from: withPhone)
        XCTAssertNil(oldPeer.phoneSupersededPerSecond)
        XCTAssertNil(oldPeer.phoneDecodeMs)
        XCTAssertNil(oldPeer.phonePresentedFPS)
        XCTAssertNil(oldPeer.phoneThermalState)
        XCTAssertNil(oldPeer.phoneLowPowerMode)
    }

    func testFreshPhoneFeedbackChangesTheMonitorLadder() {
        var hotReport = StreamStatsReport(role: "phone", previous: nil,
                                          current: StreamStatsSample(entries: []), counters: nil)
        hotReport.thermalState = 2
        var hotSample = sample
        hotSample.phoneLoad = PhoneLoadFeedback(report: hotReport)
        var hotMonitor = HostLoadMonitor(targetFPS: 120)
        XCTAssertEqual(hotMonitor.tick(sample: hotSample, at: 0).ladder, rung(1, "phone"))

        var slowReport = hotReport
        slowReport.thermalState = nil
        slowReport.decodeMs = 9
        var slowSample = sample
        slowSample.phoneLoad = PhoneLoadFeedback(report: slowReport)
        var slowMonitor = HostLoadMonitor(targetFPS: 120)
        XCTAssertNil(slowMonitor.tick(sample: slowSample, at: 0).ladder)
        XCTAssertEqual(slowMonitor.tick(sample: slowSample, at: 1).ladder, rung(1, "phone"))

        slowReport.decodeMs = nil
        slowReport.lowPowerMode = true
        slowSample.phoneLoad = PhoneLoadFeedback(report: slowReport)
        var powerMonitor = HostLoadMonitor(targetFPS: 120)
        XCTAssertEqual(powerMonitor.tick(sample: slowSample, at: 0).ladder, rung(1, "phonePower"))
    }

    func testSampleFromTheHostReport() {
        var report = StreamStatsReport(role: "host", previous: nil, current: StreamStatsSample(entries: []),
                                       counters: nil)
        report.captureFPS = 118
        report.captureLatencyP90Ms = 2.5
        report.encodedFPS = 117
        report.encodeLatencyP90Ms = 6.5
        report.encodeInFlightMax = 1
        report.droppedBeforeEncode = 1
        report.pacerDelayMs = 0.4
        report.targetKbps = 18_000
        report.availableOutgoingKbps = 30_000
        report.qualityLimitation = "none"
        report.sentKbps = 9_000
        var expected = sample
        expected.sentKbps = 9_000
        XCTAssertEqual(HostLoadSample(report: report, targetFPS: 120, longEdge: 2560, hostThermalState: "fair",
                                      lowPowerMode: false), expected)
    }

    func testTickRunsTheLadderThenTheBusyState() {
        var monitor = HostLoadMonitor(targetFPS: 120)
        var bad = sample
        bad.encodeInFlightMax = 2
        bad.encodeLatencyP90Ms = 34
        assertTick(monitor.tick(sample: bad, at: 0), ladder: nil, busy: nil)
        assertTick(monitor.tick(sample: bad, at: 1), ladder: rung(1, "encoding"), busy: nil,
                   "a step for load is not news")
        assertTick(monitor.tick(sample: bad, at: 2), ladder: nil, busy: nil)
        assertTick(monitor.tick(sample: bad, at: 3), ladder: rung(2, "encoding"), busy: nil)
        assertTick(monitor.tick(sample: bad, at: 4), ladder: nil, busy: nil)
        var unsized = bad
        unsized.longEdge = nil
        assertTick(monitor.tick(sample: unsized, at: 5), ladder: rung(3, "encoding"), busy: nil)
        assertTick(monitor.tick(sample: unsized, at: 6), ladder: nil, busy: nil)
        assertTick(monitor.tick(sample: unsized, at: 7), ladder: rung(4, "encoding"), busy: nil)
        for second in 8...11 { assertTick(monitor.tick(sample: unsized, at: TimeInterval(second)), ladder: nil, busy: nil) }
        let floorBusy = BusyState(level: .busy, fps: 30, longEdge: 1280, reason: "encoding")
        assertTick(monitor.tick(sample: unsized, at: 12), ladder: nil, busy: floorBusy,
                   "five seconds of pressure at the floor; nil keeps the last long edge")
        XCTAssertEqual(monitor.longEdge, 2560)
        XCTAssertEqual(monitor.ladder.state, rung(4, "encoding"))
        XCTAssertEqual(monitor.busy.state, floorBusy)
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

    func testLowPowerModeThroughTheMonitor() {
        var monitor = HostLoadMonitor(targetFPS: 120)
        var saving = sample
        saving.lowPowerMode = true
        assertTick(monitor.tick(sample: saving, at: 0), ladder: rung(1, "power"),
                   busy: BusyState(level: .strained, fps: 60, longEdge: 2560, reason: "power"))
        for second in 1...7 {
            assertTick(monitor.tick(sample: saving, at: TimeInterval(second)), ladder: nil, busy: nil)
        }
        assertTick(monitor.tick(sample: saving, at: 8), ladder: nil, busy: .ok, "8 s later the pill goes")
    }
}

// X17: send-path cap over the ladder.
final class SenderQueueGovernorTests: XCTestCase {
    private func window(_ route: String? = "relay", available: Double? = 4_000, sent: Double? = 3_900,
                        queue: Double? = 20, network: Double? = 0) -> SenderQueueGovernor.Window {
        SenderQueueGovernor.Window(route: route, availableKbps: available, sentKbps: sent,
                                   senderQueueMs: queue, networkQueueMs: network)
    }

    /// Feeds `count` windows and returns the level after each.
    private func feed(_ governor: inout SenderQueueGovernor, _ window: SenderQueueGovernor.Window, _ count: Int) -> [Int] {
        (0..<count).map { _ in _ = governor.observe(window); return governor.level }
    }

    func testStepsDownUnderTheCapRateFirstAndStopsAtFifteenFullSize() {
        var governor = SenderQueueGovernor()
        XCTAssertEqual(feed(&governor, window(), 3), [0, 0, 0], "warm-up: the estimate is still ramping")
        XCTAssertEqual(feed(&governor, window(), 4), [0, 1, 1, 2], "down after two bad windows in a row")
        XCTAssertEqual(governor.cap, SenderQueueGovernor.Level(fps: 15, sizeFraction: 1))
        XCTAssertEqual(feed(&governor, window(), 20), Array(repeating: 2, count: 20),
                       "low capacity alone never costs resolution")
        XCTAssertEqual(governor.keyFrameSteps, 0, "rate steps need no key frame")
    }

    func testPersistentQueueCostsResolutionWithKeyFrameStepsSpacedApart() {
        var governor = SenderQueueGovernor()
        let queued = window(available: 20_000, sent: 8_000, queue: 90, network: 30)
        let levels = feed(&governor, queued, 16)
        XCTAssertEqual(levels, [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4])
        XCTAssertEqual(governor.cap, SenderQueueGovernor.Level(fps: 15, sizeFraction: 0.5))
        XCTAssertEqual(governor.keyFrameSteps, 2, "one key frame per size step and none for rate steps")
        let sizeSteps = levels.indices.dropFirst().filter {
            SenderQueueGovernor.levels[levels[$0]].sizeFraction != SenderQueueGovernor.levels[levels[$0 - 1]].sizeFraction
        }
        XCTAssertEqual(sizeSteps.count, 2)
        XCTAssertGreaterThanOrEqual(sizeSteps[1] - sizeSteps[0], SenderQueueGovernor.sizeStepSpacing)
        XCTAssertFalse(governor.observe(queued), "at the floor nothing moves")
    }

    func testOnlyAQueueTriggeredLevelCountsAsSheddingAndClimbingBackClearsIt() {
        var queued = SenderQueueGovernor()
        _ = feed(&queued, window(available: 20_000, sent: 8_000, queue: 90, network: 30), 6)
        XCTAssertGreaterThan(queued.level, 0)
        XCTAssertTrue(queued.queueShedding, "a building send queue is real shedding")
        var small = SenderQueueGovernor()
        _ = feed(&small, window(), 7)
        XCTAssertGreaterThan(small.level, 0)
        XCTAssertFalse(small.queueShedding, "a small saturated link is a cap, not shedding; files keep flowing")
        let clean = window(available: 20_000, sent: 17_000, queue: 10)
        _ = feed(&queued, clean, SenderQueueGovernor.climbWindows * 4)
        XCTAssertEqual(queued.level, 0)
        XCTAssertFalse(queued.queueShedding, "back at level 0 nothing is shed")
    }

    func testShadowNeverReportsSheddingAndApplyReportsItOnlyForAQueue() {
        var queueSample = constrainedSample
        queueSample.availableKbps = 20_000; queueSample.sentKbps = 8_000; queueSample.senderQueueMs = 150
        var shadow = HostLoadMonitor(targetFPS: 60, senderQueueGovernor: true, applyGovernor: false)
        var apply = HostLoadMonitor(targetFPS: 60, senderQueueGovernor: true, applyGovernor: true)
        var capped = HostLoadMonitor(targetFPS: 60, senderQueueGovernor: true, applyGovernor: true)
        for second in 0..<8 {
            _ = shadow.tick(sample: queueSample, at: TimeInterval(second))
            _ = apply.tick(sample: queueSample, at: TimeInterval(second))
            _ = capped.tick(sample: constrainedSample, at: TimeInterval(second))
        }
        XCTAssertGreaterThan(shadow.governor?.level ?? 0, 0)
        XCTAssertFalse(shadow.governorShedding, "shadow mode never pauses bulk transfers")
        XCTAssertTrue(apply.governorShedding)
        XCTAssertGreaterThan(capped.governor?.level ?? 0, 0)
        XCTAssertFalse(capped.governorShedding, "a capacity cap is not shedding")
    }

    func testHysteresisDownAfterTwoBadUpOnlyAfterTenCleanWindows() {
        var governor = SenderQueueGovernor()
        let bad = window(), clean = window(available: 20_000, sent: 17_000, queue: 10)
        let neutral = window(available: 5_500, sent: 5_200, queue: 10)
        _ = feed(&governor, clean, 3)
        for _ in 0..<10 { _ = governor.observe(bad); _ = governor.observe(clean) }
        XCTAssertEqual(governor.level, 0, "alternating windows never step")
        _ = feed(&governor, bad, 2)
        XCTAssertEqual(governor.level, 1)
        XCTAssertEqual(feed(&governor, clean, 9), Array(repeating: 1, count: 9))
        _ = governor.observe(neutral)
        XCTAssertEqual(feed(&governor, clean, 9), Array(repeating: 1, count: 9),
                       "a saturated link between 5 and 6 Mb/s is not clean and restarts the count")
        XCTAssertEqual(feed(&governor, clean, 1), [0])
    }

    func testAFailedClimbDoublesTheWait() {
        var governor = SenderQueueGovernor()
        let bad = window(), clean = window(available: 20_000, sent: 17_000, queue: 10)
        _ = feed(&governor, bad, 5)
        XCTAssertEqual(governor.level, 1)
        _ = feed(&governor, clean, 10)
        XCTAssertEqual(governor.level, 0)
        _ = feed(&governor, bad, 2)
        XCTAssertEqual(governor.level, 1)
        XCTAssertEqual(governor.climbWait, 20)
        XCTAssertEqual(feed(&governor, clean, 20).last, 0)
        XCTAssertEqual(feed(&governor, clean, 19).last, 0)
        XCTAssertEqual(governor.climbWait, SenderQueueGovernor.climbWindows, "a climb that holds resets the wait")
    }

    func testAnAppLimitedLowEstimateIsNotABottleneck() {
        var governor = SenderQueueGovernor()
        XCTAssertEqual(feed(&governor, window(available: 3_000, sent: 400, queue: 5), 30).max(), 0,
                       "a still screen leaves the estimate low without a queue")
        XCTAssertEqual(feed(&governor, window(available: nil, sent: nil, queue: nil, network: nil), 10).max(), 0)
    }

    func testRouteChangeResetsTheCapAndWarmsUpAgain() {
        var governor = SenderQueueGovernor()
        _ = feed(&governor, window("relay"), 7)
        XCTAssertEqual(governor.level, 2)
        XCTAssertFalse(governor.observe(window(nil)), "a pending route keeps the last one")
        XCTAssertEqual(governor.level, 2)
        XCTAssertTrue(governor.observe(window("p2p")))
        XCTAssertEqual(governor.level, 0)
        XCTAssertEqual(feed(&governor, window("p2p"), 3), [0, 0, 0], "the new route warms up before any step")
        XCTAssertEqual(feed(&governor, window("p2p"), 2), [1, 1])
    }

    func testAProvenLocalLinkKeepsTheGovernorInactive() {
        var governor = SenderQueueGovernor()
        var lan = window("lan", queue: 300)
        lan.provenLocalLink = true
        XCTAssertEqual(feed(&governor, lan, 20).max(), 0)
        XCTAssertEqual(governor.status(applied: false), "LAN, inactive")
        _ = feed(&governor, window("relay"), 7)
        XCTAssertEqual(governor.level, 2, "losing the proof starts a fresh, warmed-up governor")
        XCTAssertTrue(governor.observe(lan), "regaining it drops the cap at once")
        XCTAssertEqual(governor.level, 0)
    }

    func testTheCapNeverRaisesTheLadderAndNamesTheNetwork() {
        var governor = SenderQueueGovernor()
        let top = LadderState(rung: 0, fps: 60, sizeFraction: 1, reason: nil)
        XCTAssertEqual(governor.apply(to: top), top)
        _ = feed(&governor, window(), 7)
        XCTAssertEqual(governor.apply(to: top), LadderState(rung: 2, fps: 15, sizeFraction: 1, reason: "network"))
        let lowRung = LadderState(rung: 3, fps: 12, sizeFraction: 0.5, reason: "thermal")
        XCTAssertEqual(governor.apply(to: lowRung), lowRung, "a tighter ladder rung is left alone")
        XCTAssertNoThrow(try governor.apply(to: LadderState(rung: 16, fps: 60, sizeFraction: 1, reason: nil)).validate())
    }

    private var constrainedSample: HostLoadSample {
        var sample = HostLoadSample(targetFPS: 60, longEdge: 2560, captureFPS: 60, captureLatencyP90Ms: 2,
                                    encodedFPS: 60, encodeLatencyP90Ms: 5, encodeInFlightMax: 1, droppedBeforeEncode: 0,
                                    pacerDelayMs: 5, targetKbps: 3_900, availableKbps: 4_000, qualityLimitation: "none",
                                    hostThermalState: "nominal", lowPowerMode: false)
        sample.sentKbps = 3_900
        sample.senderQueueMs = 20
        sample.routeDetail = "relay"
        return sample
    }

    func testDefaultIsShadowWhichReportsTheCapButLeavesTheLadder() {
        let tuned = StreamTuning.tuned
        XCTAssertTrue(tuned.senderQueueGovernor)
        XCTAssertFalse(tuned.senderQueueGovernorApply)
        var monitor = HostLoadMonitor(targetFPS: 60, senderQueueGovernor: tuned.senderQueueGovernor,
                                      applyGovernor: tuned.senderQueueGovernorApply)
        XCTAssertEqual(monitor.governorStatus, "shadow, no cap")
        for second in 0..<8 { XCTAssertNil(monitor.tick(sample: constrainedSample, at: TimeInterval(second)).ladder) }
        XCTAssertEqual(monitor.governor?.level, 2, "the level is still computed every window")
        XCTAssertEqual(monitor.applied, monitor.ladder.state)
        XCTAssertEqual(monitor.applied.fps, 60)
        XCTAssertEqual(monitor.governorStatus, "shadow, would cap: 15 fps")
    }

    func testTheApplyKeyAppliesTheCap() {
        var monitor = HostLoadMonitor(targetFPS: 60, senderQueueGovernor: true, applyGovernor: true)
        var changes: [LadderState] = []
        for second in 0..<8 {
            if let change = monitor.tick(sample: constrainedSample, at: TimeInterval(second)).ladder { changes.append(change) }
        }
        XCTAssertEqual(changes, [LadderState(rung: 1, fps: 30, sizeFraction: 1, reason: "network"),
                                 LadderState(rung: 2, fps: 15, sizeFraction: 1, reason: "network")])
        XCTAssertEqual(monitor.ladder.state.rung, 0, "the ladder's own rung is unchanged underneath")
        XCTAssertEqual(monitor.governorStatus, "applied: 15 fps")
    }

    func testTheKillKeyComputesNothing() {
        var monitor = HostLoadMonitor(targetFPS: 60, senderQueueGovernor: false, applyGovernor: true)
        for second in 0..<8 { XCTAssertNil(monitor.tick(sample: constrainedSample, at: TimeInterval(second)).ladder) }
        XCTAssertNil(monitor.governor)
        XCTAssertFalse(monitor.applyGovernor, "apply without the computation is off")
        XCTAssertEqual(monitor.governorStatus, "off")
    }

    func testTuningKeysAndSummaryNameTheGovernorMode() throws {
        let suite = "governor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(StreamTuning.resolve(defaults: defaults).summary.contains("governor shadow"))
        defaults.set(true, forKey: StreamTuning.senderQueueGovernorApplyKey)
        XCTAssertTrue(StreamTuning.resolve(defaults: defaults).senderQueueGovernorApply)
        XCTAssertTrue(StreamTuning.resolve(defaults: defaults).summary.contains("governor apply"))
        defaults.set(false, forKey: StreamTuning.senderQueueGovernorKey)
        XCTAssertTrue(StreamTuning.resolve(defaults: defaults).summary.contains("governor off"))
        XCTAssertTrue(StreamTuning.experimentKeys.contains(StreamTuning.senderQueueGovernorApplyKey))
        XCTAssertFalse(StreamTuning.legacy.senderQueueGovernorApply)
    }

    // False positives: none of these may step the cap down.
    func testAKeyFrameStraddlingTwoWindowsIsNotAQueue() {
        let counters = StreamCounters()
        var monitor = HostLoadMonitor(targetFPS: 60, senderQueueGovernor: true)
        var maximumBacklog = 0.0
        var bytesSent = 1_000_000.0
        var previous = StreamStatsSample(entries: Self.entries(at: 0, bytes: bytesSent, pacerMs: 25, available: 20_000_000))
        for second in 1...20 {
            let keyWindow = second % 2 == 1
            counters.encoded(latencyMs: 5, bytes: keyWindow ? 400_000 : 20_000, isKeyFrame: keyWindow, inFlight: 1)
            bytesSent += keyWindow ? 100_000 : 320_000
            let current = StreamStatsSample(entries: Self.entries(at: Double(second), bytes: bytesSent, pacerMs: 25, available: 20_000_000))
            var snapshot = counters.drain(inputBufferedBytes: nil)
            snapshot.interval = 1
            var report = StreamStatsReport(role: "host", previous: previous, current: current, counters: snapshot)
            report.routeDetail = "p2p"
            maximumBacklog = max(maximumBacklog, report.backlogDrainMs ?? 0)
            let sample = HostLoadSample(report: report, targetFPS: 60, longEdge: 2560, hostThermalState: "nominal", lowPowerMode: false)
            _ = monitor.tick(sample: sample, at: TimeInterval(second))
            previous = current
        }
        XCTAssertGreaterThan(maximumBacklog, 100, "the overlay estimate does flag the straddling key frame")
        XCTAssertEqual(monitor.governor?.level, 0, "but it never triggers the governor")
    }

    func testAStaleRoundTripSpikeAloneNeverSteps() {
        var governor = SenderQueueGovernor()
        let calm = window(available: 20_000, sent: 17_000, queue: 3, network: 0)
        _ = feed(&governor, calm, 4)
        XCTAssertEqual(feed(&governor, window(available: 20_000, sent: 17_000, queue: 3, network: 400), 1), [0])
        XCTAssertEqual(feed(&governor, window(available: 20_000, sent: 17_000, queue: 3, network: 180), 8).max(), 0,
                       "a currentRoundTripTime that stays stale counts at most 50 ms without pacer pressure")
    }

    func testABurstAfterIdleOnACollapsedEstimateIsNotABottleneck() {
        var governor = SenderQueueGovernor()
        XCTAssertEqual(feed(&governor, window(available: 1_500, sent: 100, queue: 2), 5).max(), 0)
        for available in [1_500.0, 1_500, 1_600, 1_800, 2_400, 3_500, 4_800, 6_000, 7_500] {
            _ = governor.observe(window(available: available, sent: 0.95 * available, queue: 15))
            XCTAssertEqual(governor.level, 0, "estimate \(available) kbps while GCC ramps after idle")
        }
    }

    func testMisalignedStatisticsWindowsAreNotABottleneck() {
        var governor = SenderQueueGovernor()
        for index in 0..<24 {
            let sent = index % 2 == 0 ? 6_400.0 : 800
            _ = governor.observe(window(available: 4_000, sent: sent, queue: 10))
        }
        XCTAssertEqual(governor.level, 0, "a byte count landing in the neighbouring window alternates over and under the estimate")
    }

    func testCappedRatesKeepTheSessionDegradationPreference() {
        var tuning = StreamTuning.tuned
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 60, tuning: tuning, ladderFPS: 15),
                       SenderRateParameters(maxFramerate: 15, degradationPreference: .maintainResolution),
                       "frames are shed before resolution, as the cap does")
        tuning.highRefreshNoAdaptation = true
        XCTAssertEqual(SenderRateParameters.make(targetFPS: 120, tuning: tuning, ladderFPS: 15),
                       SenderRateParameters(maxFramerate: 15, degradationPreference: .maintainFramerateAndResolution),
                       "in 120 mode the app's ladder and cap stay the only adaptation")
        XCTAssertTrue(StreamTuning.tuned.senderQueueGovernor)
        XCTAssertFalse(StreamTuning.legacy.senderQueueGovernor)
        XCTAssertTrue(StreamTuning.experimentKeys.contains(StreamTuning.senderQueueGovernorKey))
    }

    fileprivate static func entries(at seconds: Double, bytes: Double, pacerMs: Double = 4,
                                    available: Double = 4_000_000) -> [StreamStatsEntry] {
        let packets = bytes / 1000
        return [StreamStatsEntry(id: "O", type: "outbound-rtp", values: ["kind": "video" as NSString, "bytesSent": bytes as NSNumber,
                                                                         "packetsSent": packets as NSNumber,
                                                                         "totalPacketSendDelay": packets * pacerMs / 1000 as NSNumber], timestamp: seconds),
                StreamStatsEntry(id: "T", type: "transport", values: ["selectedCandidatePairId": "P" as NSString], timestamp: seconds),
                StreamStatsEntry(id: "P", type: "candidate-pair", values: ["availableOutgoingBitrate": available as NSNumber], timestamp: seconds)]
    }

    func testQueueEstimatesKeepThePacerTriggerApartFromTheBacklogEstimate() throws {
        XCTAssertEqual(SenderQueueEstimate.backlogDrainMs(encodedBytes: 500_000, sentBytes: 250_000, availableKbps: 4_000), 500,
                       "250 kB unsent at 4 Mb/s drains in 500 ms")
        XCTAssertEqual(SenderQueueEstimate.backlogDrainMs(encodedBytes: 100_000, sentBytes: 120_000, availableKbps: 4_000), 0)
        XCTAssertNil(SenderQueueEstimate.backlogDrainMs(encodedBytes: 10_000, sentBytes: 0, availableKbps: 0))
        XCTAssertNil(SenderQueueEstimate.backlogDrainMs(encodedBytes: nil, sentBytes: 0, availableKbps: 4_000))
        XCTAssertEqual(SenderQueueEstimate.networkQueueMs(rttMs: 80, baselineRTTMs: 30), 50)
        XCTAssertEqual(SenderQueueEstimate.networkQueueMs(rttMs: 20, baselineRTTMs: 30), 0)
        XCTAssertNil(SenderQueueEstimate.networkQueueMs(rttMs: 20, baselineRTTMs: nil))

        let counters = StreamCounters()
        counters.encoded(latencyMs: 5, bytes: 450_000, isKeyFrame: true, inFlight: 1)
        counters.encoded(latencyMs: 5, bytes: 50_000, isKeyFrame: false, inFlight: 1)
        var snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.encodedBytes, 500_000)
        snapshot.interval = 1
        var report = StreamStatsReport(role: "host", previous: StreamStatsSample(entries: Self.entries(at: 1, bytes: 1_000_000)),
                                       current: StreamStatsSample(entries: Self.entries(at: 2, bytes: 1_250_000)), counters: snapshot)
        XCTAssertEqual(report.pacerDelayMs, 4)
        XCTAssertEqual(report.senderQueueMs, 4, "the trigger is the pacer delay")
        XCTAssertEqual(report.backlogDrainMs, 500)
        report.networkQueueMs = 12
        report.senderQueueGovernor = "shadow, would cap: 30 fps"
        let summary = report.hostSummary
        XCTAssertEqual(summary.senderQueueMs, 4)
        XCTAssertEqual(summary.backlogDrainMs, 500)
        XCTAssertEqual(summary.networkQueueMs, 12)
        XCTAssertEqual(summary.senderQueueGovernor, "shadow, would cap: 30 fps")
        XCTAssertNoThrow(try summary.validate())
        XCTAssertEqual(try JSONDecoder().decode(HostStreamSummary.self, from: JSONEncoder().encode(summary)), summary)
        let lines = report.summaryLines
        XCTAssertTrue(lines.contains("queue estimate: pacer 4.0ms · unsent backlog ≈500ms · network ≈12.0ms"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("governor: shadow, would cap: 30 fps"))
        var phone = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []), counters: nil)
        phone.host = summary
        XCTAssertTrue(phone.summaryLines.contains("Mac governor: shadow, would cap: 30 fps"))
        XCTAssertEqual(counters.drain(inputBufferedBytes: nil).encodedBytes, 0, "each window counts its own bytes")
        var invalid = summary
        invalid.backlogDrainMs = .nan
        XCTAssertThrowsError(try invalid.validate())
        invalid = summary
        invalid.senderQueueGovernor = String(repeating: "x", count: 41)
        XCTAssertThrowsError(try invalid.validate())
    }
}

private extension LadderState {
    func with(reason: String?) -> LadderState {
        var state = self
        state.reason = reason
        return state
    }
}
