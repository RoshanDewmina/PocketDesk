import XCTest

/// ENCODER-OPTIMIZATIONS row 2 (`StreamTuning.ladderKeyNeutral`): the ladder's climb clock against the
/// pacer spike of a key frame every 10 s. Off is today's policy, sample for sample.
final class LadderKeyNeutralTests: XCTestCase {
    /// Clean at a 60 fps target on a moving picture, off the LAN trust rule.
    private func calm() -> LadderInputs {
        LadderInputs(targetFPS: 60, captureFPS: 60, captureLatencyP90Ms: 1, encodedFPS: 60, encodeLatencyP90Ms: 3,
                     encodeInFlightMax: 1, droppedBeforeEncode: 0, pacerDelayMs: 1, targetKbps: 10_000, availableKbps: 20_000,
                     qualityLimitation: "none", hostThermalState: "nominal", hostLowPowerMode: false, phoneSupersededPerSecond: 0,
                     phoneDecodeMs: 3, phonePresentedFPS: 60, phoneThermalState: "nominal", encoderSessionAgeS: 30, sourceFPS: 60)
    }

    private func with(_ change: (inout LadderInputs) -> Void) -> LadderInputs {
        var inputs = calm()
        change(&inputs)
        return inputs
    }

    /// The window of the 10 s key: one unrequested key frame, its 500 KB draining behind the pacer, the estimate dented.
    private var keyWindow: LadderInputs { with { $0.keyFrames = 1; $0.pliReceived = 0; $0.pacerDelayMs = 90; $0.availableKbps = 5_000 } }
    /// The same window on a lossy link: the phone asked for the key (PLI), so the congestion is the link's.
    private var requestedKeyWindow: LadderInputs { with { $0.keyFrames = 1; $0.pliReceived = 1; $0.pacerDelayMs = 90; $0.availableKbps = 5_000 } }
    private var backlog: LadderInputs { with { $0.encodeInFlightMax = 2; $0.encodeLatencyP90Ms = 40 } }

    private func policy(keyNeutral: Bool) -> LadderPolicy {
        var policy = LadderPolicy(targetFPS: 60)
        policy.falseLoadRules = true; policy.lanTrustRules = true; policy.encoderPipelining = false
        policy.keyNeutralRules = keyNeutral
        return policy
    }

    private let ladder60 = LadderPolicy.ladder(targetFPS: 60)

    private func rung(_ index: Int, _ reason: String?) -> LadderState {
        var state = ladder60[index]
        state.reason = reason
        return state
    }

    /// Steps the policy to rung 1 ("encoding") with its move at second 1.
    private func steppedDown(keyNeutral: Bool) -> LadderPolicy {
        var policy = policy(keyNeutral: keyNeutral)
        XCTAssertNil(policy.evaluate(backlog, at: 0))
        XCTAssertEqual(policy.evaluate(backlog, at: 1), rung(1, "encoding"))
        return policy
    }

    func testAKeyFrameWindowIsNotNetworkEvidenceOnlyWhenKeyNeutral() {
        let top = ladder60[0]
        XCTAssertEqual(LadderTrigger.firing(keyWindow, at: top, lanTrustRules: true), [.pacerDelay, .lowEstimate], "today")
        XCTAssertEqual(LadderTrigger.firing(keyWindow, at: top, lanTrustRules: true, keyNeutral: true), [])
        XCTAssertEqual(LadderTrigger.firing(with { $0.pacerDelayMs = 90; $0.availableKbps = 5_000 }, at: top, lanTrustRules: true, keyNeutral: true),
                       [.pacerDelay, .lowEstimate], "a window without a key frame is judged as before")
        XCTAssertEqual(LadderTrigger.firing(with { $0.keyFrames = 2; $0.pliReceived = 0; $0.pacerDelayMs = 90 }, at: top, lanTrustRules: true, keyNeutral: true), [])
        XCTAssertEqual(LadderTrigger.firing(with { $0.keyFrames = 0; $0.pliReceived = 0; $0.pacerDelayMs = 90 }, at: top, lanTrustRules: true, keyNeutral: true), [.pacerDelay])
        XCTAssertEqual(LadderTrigger.firing(with { $0.keyFrames = 1; $0.pacerDelayMs = 90 }, at: top, lanTrustRules: true, keyNeutral: true), [.pacerDelay],
                       "no PLI count on the report: the key is not known to be unsolicited")
        XCTAssertEqual(LadderTrigger.firing(with { $0.keyFrames = 1; $0.qualityLimitation = "bandwidth" }, at: top, lanTrustRules: true, keyNeutral: true),
                       [.bandwidthLimited], "libwebrtc's own verdict is not the key frame's cost")
        var slowKey = backlog; slowKey.keyFrames = 1
        XCTAssertEqual(LadderTrigger.firing(slowKey, at: top, lanTrustRules: true, keyNeutral: true), [.encodeLatency, .encodeQueue],
                       "encoder triggers never go quiet for a key frame")
        var still = keyWindow; still.captureFPS = 1; still.sourceFPS = 1; still.encodedFPS = 1; still.availableKbps = 20_000
        XCTAssertFalse(LadderPolicy.isClean(still, at: top), "today a key frame's pacer wait on a still screen holds the climb")
        XCTAssertTrue(LadderPolicy.isClean(still, at: top, keyNeutral: true))
        still.keyFrames = 0
        XCTAssertFalse(LadderPolicy.isClean(still, at: top, keyNeutral: true), "a still screen queueing packets with no key frame still holds it")
    }

    func testARequestedKeyFrameWindowIsStillNetworkEvidenceAndStepsDown() {
        let top = ladder60[0]
        XCTAssertFalse(LadderPolicy.hasUnsolicitedKeyFrame(requestedKeyWindow))
        XCTAssertTrue(LadderPolicy.hasUnsolicitedKeyFrame(keyWindow))
        XCTAssertEqual(LadderTrigger.firing(requestedKeyWindow, at: top, lanTrustRules: true, keyNeutral: true), [.pacerDelay, .lowEstimate])
        var still = requestedKeyWindow; still.captureFPS = 1; still.sourceFPS = 1; still.encodedFPS = 1; still.availableKbps = 20_000
        XCTAssertFalse(LadderPolicy.isClean(still, at: top, keyNeutral: true), "a requested key's pacer wait on a still screen still holds the climb")
        for keyNeutral in [false, true] {
            var policy = policy(keyNeutral: keyNeutral)
            XCTAssertNil(policy.evaluate(requestedKeyWindow, at: 0))
            XCTAssertEqual(policy.evaluate(requestedKeyWindow, at: 1), rung(1, "network"), "keyNeutral=\(keyNeutral): a lossy link with keys every window steps within 2 s")
            for second in 2...4 { XCTAssertNil(policy.evaluate(calm(), at: TimeInterval(second))) }
            XCTAssertNil(policy.evaluate(requestedKeyWindow, at: 5), "counted as load, not yet a step")
            // A lone window is a lone network sample either way: forgiven only by the key-neutral clock rule.
            let climb = keyNeutral ? 11 : 15
            for second in 6..<climb { XCTAssertNil(policy.evaluate(calm(), at: TimeInterval(second)), "second \(second)") }
            XCTAssertEqual(policy.evaluate(calm(), at: TimeInterval(climb)), ladder60[0], "keyNeutral=\(keyNeutral)")
        }
    }

    func testALoneEncoderOrPhoneSampleStillResetsTheClockWhenKeyNeutral() {
        let slowEncoder = with { $0.encodeLatencyP90Ms = 70 }
        let slowPhone = with { $0.phoneDecodeMs = 50 }
        for sample in [slowEncoder, slowPhone] {
            XCTAssertEqual(LadderTrigger.firing(sample, at: ladder60[1], lanTrustRules: true, keyNeutral: true).count, 1)
            XCTAssertFalse(LadderTrigger.firing(sample, at: ladder60[1], lanTrustRules: true, keyNeutral: true).contains(where: \.isKeyFrameCost))
            for keyNeutral in [false, true] {
                var policy = steppedDown(keyNeutral: keyNeutral)
                for second in 2...25 {
                    XCTAssertNil(policy.evaluate(second.isMultiple(of: 2) ? calm() : sample, at: TimeInterval(second)),
                                 "keyNeutral=\(keyNeutral) second \(second): alternating load neither steps nor climbs")
                }
                XCTAssertEqual(policy.state, rung(1, "encoding"))
                for second in 26...34 { XCTAssertNil(policy.evaluate(calm(), at: TimeInterval(second))) }
                XCTAssertEqual(policy.evaluate(calm(), at: 35), ladder60[0], "keyNeutral=\(keyNeutral): the clock restarted at the last firing sample (25)")
            }
        }
    }

    func testAKeyFrameEveryTenSecondsPinsTheClimbTodayAndNotWhenKeyNeutral() {
        var today = steppedDown(keyNeutral: false)
        var moves: [(Int, LadderState)] = []
        for second in 2...45 {
            if let move = today.evaluate(second % 10 == 5 ? keyWindow : calm(), at: TimeInterval(second)) { moves.append((second, move)) }
        }
        XCTAssertTrue(moves.isEmpty, "a 10 s spike against a 10 s climb: \(moves)")
        XCTAssertEqual(today.state, rung(1, "encoding"))

        var neutral = steppedDown(keyNeutral: true)
        moves = []
        for second in 2...45 {
            if let move = neutral.evaluate(second % 10 == 5 ? keyWindow : calm(), at: TimeInterval(second)) { moves.append((second, move)) }
        }
        XCTAssertEqual(moves.map { $0.0 }, [11], "10 s after the move, through the key frame at 5")
        XCTAssertEqual(moves.map { $0.1 }, [ladder60[0]])
        XCTAssertEqual(neutral.climbWait, LadderPolicy.upAfter, "the climb held: no back-off")
    }

    func testALoneFiringSampleResetsTheClockTodayButOnlyARepeatDoesWhenKeyNeutral() {
        let spike = with { $0.pacerDelayMs = 90 }
        var today = steppedDown(keyNeutral: false)
        for second in 2...14 { XCTAssertNil(today.evaluate(second == 5 ? spike : calm(), at: TimeInterval(second)), "second \(second)") }
        XCTAssertEqual(today.evaluate(calm(), at: 15), ladder60[0], "the clock restarted at the spike")

        var neutral = steppedDown(keyNeutral: true)
        for second in 2...10 { XCTAssertNil(neutral.evaluate(second == 5 ? spike : calm(), at: TimeInterval(second)), "second \(second)") }
        XCTAssertEqual(neutral.evaluate(calm(), at: 11), ladder60[0], "one spike with a clean sample after it keeps the clock")

        for keyNeutral in [false, true] {
            var policy = steppedDown(keyNeutral: keyNeutral)
            for second in 2...4 { XCTAssertNil(policy.evaluate(calm(), at: TimeInterval(second))) }
            XCTAssertNil(policy.evaluate(spike, at: 5))
            XCTAssertEqual(policy.evaluate(spike, at: 6), rung(2, "network"), "keyNeutral=\(keyNeutral): two in a row step down as before")
        }

        var repeated = steppedDown(keyNeutral: true)
        let slow = with { $0.encodeLatencyP90Ms = 40 }
        for second in 2...4 { XCTAssertNil(repeated.evaluate(calm(), at: TimeInterval(second))) }
        XCTAssertNil(repeated.evaluate(spike, at: 5))
        XCTAssertNil(repeated.evaluate(slow, at: 6), "a slow encoder fires no trigger but is not clean")
        for second in 7...15 { XCTAssertNil(repeated.evaluate(calm(), at: TimeInterval(second)), "second \(second)") }
        XCTAssertEqual(repeated.evaluate(calm(), at: 16), ladder60[0], "an unclean sample still restarts the clock; only a lone firing one is forgiven")
    }

    /// A minute of mixed load: two backlog seconds, a key window and a lone spike every 12 s. The off arm
    /// pins today's moves (every firing sample restarts the clock, so it walks down and never back up);
    /// the on arm climbs through the key window and the lone spike and pays for the climbs that then fail.
    func testTheOffArmIsTodaysLadderAndTheOnArmClimbsThroughKeyWindows() {
        XCTAssertFalse(StreamTuning.tuned.ladderKeyNeutral, "the tuned default is today's ladder")
        let script: [LadderInputs] = (0..<60).map { second in
            switch second % 12 {
            case 0, 1: return backlog
            case 5: return keyWindow
            case 8: return with { $0.pacerDelayMs = 90 }
            default: return calm()
            }
        }
        func moves(keyNeutral: Bool) -> [(Int, LadderState)] {
            var policy = policy(keyNeutral: keyNeutral)
            return script.enumerated().compactMap { second, inputs in
                policy.evaluate(inputs, at: TimeInterval(second)).map { (second, $0) }
            }
        }
        let today = moves(keyNeutral: false)
        XCTAssertEqual(today.map { $0.0 }, [1, 13, 25])
        XCTAssertEqual(today.map { $0.1 }, [rung(1, "encoding"), rung(2, "encoding"), rung(3, "encoding")])
        let neutral = moves(keyNeutral: true)
        XCTAssertEqual(neutral.map { $0.0 }, [1, 11, 13, 25, 37])
        XCTAssertEqual(neutral.map { $0.1 }, [rung(1, "encoding"), ladder60[0], rung(1, "encoding"), rung(2, "encoding"), rung(3, "encoding")])
    }

    func testATargetChangeKeepsTheRule() {
        var policy = policy(keyNeutral: true)
        var inputs = calm(); inputs.targetFPS = 120; inputs.captureFPS = 120; inputs.encodedFPS = 120; inputs.sourceFPS = 120; inputs.phonePresentedFPS = 120
        XCTAssertEqual(policy.evaluate(inputs, at: 0), LadderPolicy.ladder(targetFPS: 120)[0], "a new target restarts at the top of the new ladder")
        XCTAssertTrue(policy.keyNeutralRules)
    }

    /// Row 3: with libwebrtc's degradation off at 60 fps, a genuinely slow encoder must still step the
    /// ladder through its own triggers, with `qualityLimitation` never reading "cpu".
    func testTheLadderStillStepsASlowEncoderWithoutWebRTCsCpuVerdict() {
        for keyNeutral in [false, true] {
            var shortfall = policy(keyNeutral: keyNeutral)
            let slow = with { $0.qualityLimitation = "none"; $0.encodedFPS = 40 }
            XCTAssertEqual(LadderTrigger.firing(slow, at: ladder60[0], lanTrustRules: true, keyNeutral: keyNeutral), [.encodeShortfall])
            XCTAssertNil(shortfall.evaluate(slow, at: 0))
            XCTAssertEqual(shortfall.evaluate(slow, at: 1), rung(1, "encoding"), "keyNeutral=\(keyNeutral)")

            var pipelined = policy(keyNeutral: keyNeutral)
            pipelined.encoderPipelining = true
            let saturated = with { $0.qualityLimitation = "none"; $0.encodedFPS = 50; $0.encodeAtCapShare = 0.95 }
            XCTAssertEqual(LadderTrigger.firing(saturated, at: ladder60[0], lanTrustRules: true, encoderPipelining: true, keyNeutral: keyNeutral),
                           [.encodeShortfall, .encodeQueue])
            XCTAssertNil(pipelined.evaluate(saturated, at: 0))
            XCTAssertEqual(pipelined.evaluate(saturated, at: 1), rung(1, "encoding"))

            var dropping = policy(keyNeutral: keyNeutral)
            dropping.encoderPipelining = true
            let drops = with { $0.qualityLimitation = "none"; $0.encodedFPS = 52; $0.encodeAtCapShare = 0.5; $0.droppedBeforeEncode = 6 }
            XCTAssertEqual(LadderTrigger.firing(drops, at: ladder60[0], lanTrustRules: true, encoderPipelining: true, keyNeutral: keyNeutral),
                           [.droppedBeforeEncode])
            XCTAssertNil(dropping.evaluate(drops, at: 0))
            XCTAssertEqual(dropping.evaluate(drops, at: 1), rung(1, "encoding"))

            var keyed = slow; keyed.keyFrames = 1
            XCTAssertEqual(LadderTrigger.firing(keyed, at: ladder60[0], lanTrustRules: true, keyNeutral: keyNeutral), [.encodeShortfall],
                           "a key frame in the window does not excuse a slow encoder")
        }
    }
}
