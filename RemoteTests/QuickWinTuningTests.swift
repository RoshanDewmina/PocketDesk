import XCTest
import CoreMedia

final class QuickWinTuningTests: XCTestCase {
    private func defaults() throws -> (UserDefaults, () -> Void) {
        let suite = "QuickWinTuningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    func testSwitchesDefaultToTodaysBehaviourAndResolveFromDefaults() throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        let tuned = StreamTuning.resolve(defaults: defaults)
        XCTAssertEqual(tuned, .tuned)
        XCTAssertFalse(tuned.captureAtNativeRate)
        XCTAssertFalse(tuned.routeAwareSeed)
        XCTAssertEqual(tuned.restartFloorKbps, 5_000)
        XCTAssertNil(tuned.restartKeyFrameBudgetMs)
        XCTAssertFalse(tuned.summary.contains("native capture rate"))

        defaults.set(true, forKey: StreamTuning.captureNativeRateKey)
        defaults.set(true, forKey: StreamTuning.routeAwareSeedKey)
        defaults.set(1_500, forKey: StreamTuning.restartFloorKey)
        defaults.set(250, forKey: StreamTuning.restartKeyFrameBudgetKey)
        let candidate = StreamTuning.resolve(defaults: defaults)
        XCTAssertTrue(candidate.captureAtNativeRate)
        XCTAssertTrue(candidate.routeAwareSeed)
        XCTAssertEqual(candidate.restartFloorKbps, 1_500)
        XCTAssertEqual(candidate.restartKeyFrameBudgetMs, 250)
        for part in ["native capture rate", "route seed", "restart floor 1500", "IDR budget 250ms"] {
            XCTAssertTrue(candidate.summary.contains(part), candidate.summary)
        }
        XCTAssertEqual(candidate.fieldTrials, StreamTuning.tuned.fieldTrials, "switches never change process-wide trials")

        defaults.set(50, forKey: StreamTuning.restartFloorKey)
        defaults.set(0, forKey: StreamTuning.restartKeyFrameBudgetKey)
        let bounded = StreamTuning.resolve(defaults: defaults)
        XCTAssertEqual(bounded.restartFloorKbps, 5_000, "an absurd floor is ignored")
        XCTAssertNil(bounded.restartKeyFrameBudgetMs, "zero disables the budget")

        defaults.set(12_000, forKey: StreamTuning.encoderCeilingKey)
        let capped = StreamTuning.resolve(defaults: defaults)
        XCTAssertEqual(capped.encoderCeilingKbps, 12_000)
        XCTAssertEqual(capped.maximumBitrateBps(for: .sharp), 12_000_000)
        XCTAssertEqual(StreamTuning.tuned.maximumBitrateBps(for: .sharp), StreamQuality.sharp.maximumBitrateBps)
        XCTAssertTrue(capped.summary.contains("ceiling 12000"), capped.summary)
        defaults.set(100, forKey: StreamTuning.encoderCeilingKey)
        XCTAssertNil(StreamTuning.resolve(defaults: defaults).encoderCeilingKbps, "an absurd ceiling is ignored")

        defaults.set(false, forKey: StreamTuning.level52ProbeCacheKey)
        let uncached = StreamTuning.resolve(defaults: defaults)
        XCTAssertFalse(uncached.cacheLevel52Probe)
        XCTAssertTrue(uncached.summary.contains("no probe cache"), uncached.summary)
        XCTAssertTrue(StreamTuning.tuned.cacheLevel52Probe)
        XCTAssertEqual(Set(StreamTuning.experimentKeys).count, 7, "every experiment key is listed for the cleanup step")

        defaults.set(true, forKey: StreamTuning.legacyDefaultsKey)
        XCTAssertEqual(StreamTuning.resolve(defaults: defaults), .legacy, "the legacy switch wins")
    }

    func testCaptureIntervalFollowsTheG1Switch() {
        XCTAssertEqual(RemoteCaptureConfiguration.minimumFrameInterval(for: .tuned), CMTime(value: 1, timescale: 60))
        var native = StreamTuning.tuned
        native.captureAtNativeRate = true
        XCTAssertEqual(RemoteCaptureConfiguration.minimumFrameInterval(for: native), .zero)
    }

    func testRouteDetailSeparatesLANFromInternetP2P() {
        XCTAssertEqual(MediaRoute.detail(selected: true, local: "host", remote: "host"), "lan")
        XCTAssertEqual(MediaRoute.detail(selected: true, local: "host", remote: "srflx"), "p2p")
        XCTAssertEqual(MediaRoute.detail(selected: true, local: "prflx", remote: "host"), "p2p")
        XCTAssertEqual(MediaRoute.detail(selected: true, local: "relay", remote: "host"), "relay")
        XCTAssertEqual(MediaRoute.detail(selected: true, local: "host", remote: "relay"), "relay")
        XCTAssertNil(MediaRoute.detail(selected: false, local: "host", remote: "host"))
        XCTAssertNil(MediaRoute.detail(selected: true, local: nil, remote: "host"))
    }

    func testSeedRouteAndStartRates() {
        XCTAssertEqual(SeedRoute.classify(detail: "lan", rttMs: 7), .lan)
        XCTAssertEqual(SeedRoute.classify(detail: "lan", rttMs: 40), .p2p, "a host pair over a tunnel is not a LAN")
        XCTAssertNil(SeedRoute.classify(detail: "lan", rttMs: nil), "no round trip yet: unknown, not LAN")
        XCTAssertEqual(SeedRoute.classify(detail: "p2p", rttMs: 5), .p2p)
        XCTAssertEqual(SeedRoute.classify(detail: "relay", rttMs: 5), .relay)
        XCTAssertNil(SeedRoute.classify(detail: nil, rttMs: 5))
        XCTAssertEqual(StreamQuality.sharp.startBitrateBps(for: .lan), StreamQuality.sharp.startBitrateBps)
        XCTAssertEqual(StreamQuality.balanced.startBitrateBps(for: .lan), StreamQuality.balanced.startBitrateBps)
        for quality in StreamQuality.allCases {
            XCTAssertEqual(quality.startBitrateBps(for: .p2p), 3_000_000)
            XCTAssertEqual(quality.startBitrateBps(for: .relay), 2_500_000)
            XCTAssertLessThan(quality.startBitrateBps(for: .relay), quality.startBitrateBps(for: .p2p))
            XCTAssertLessThan(quality.startBitrateBps(for: .p2p), quality.startBitrateBps(for: .lan))
        }
    }

    func testSeedPolicyCountsOnlyEligibleSamples() {
        var policy = BandwidthSeedPolicy()
        XCTAssertFalse(policy.observe(eligible: false, estimateKbps: 300, lossPercent: nil, seedKbps: 2_500))
        XCTAssertFalse(policy.observe(eligible: false, estimateKbps: 300, lossPercent: nil, seedKbps: 2_500))
        XCTAssertFalse(policy.observe(eligible: true, estimateKbps: 300, lossPercent: nil, seedKbps: 2_500), "first eligible sample waits for probes")
        XCTAssertTrue(policy.observe(eligible: true, estimateKbps: 300, lossPercent: nil, seedKbps: 2_500))
        XCTAssertEqual(policy.attempts, 1)
    }

    func testRestartFloorAndKeyFrameBudget() {
        var policy = EncoderRestartPolicy()
        policy.minimumKbps = 1_500
        policy.keyFrameBudgetMs = 250
        policy.sessionStarted(kbps: 300, at: 0)
        policy.updateTarget(kbps: 3_000)
        XCTAssertNil(policy.lastKeyFrameBytes)
        XCTAssertEqual(policy.keyFrameLinkTimeMs ?? 0, 200_000 * 8 / 3_000, accuracy: 0.01, "200 KB assumed before any key frame")
        XCTAssertFalse(policy.shouldRestart(at: 1), "533 ms of link time is over the 250 ms budget")
        XCTAssertFalse(policy.shouldRestart(at: 2), "and it never becomes eligible while it stays over")
        policy.lastKeyFrameBytes = 60_000
        XCTAssertEqual(policy.keyFrameLinkTimeMs ?? 0, 160, accuracy: 0.01)
        XCTAssertFalse(policy.shouldRestart(at: 2.1), "eligibility starts now")
        XCTAssertTrue(policy.shouldRestart(at: 2.9), "a 60 KB key frame fits at 3 Mb/s, above the 1.5 Mb/s floor")

        var floored = EncoderRestartPolicy()
        floored.minimumKbps = 1_500
        floored.sessionStarted(kbps: 300, at: 0)
        floored.updateTarget(kbps: 1_200)
        XCTAssertFalse(floored.shouldRestart(at: 1))
        XCTAssertFalse(floored.shouldRestart(at: 3), "still under the floor")
        floored.updateTarget(kbps: 1_600)
        XCTAssertFalse(floored.shouldRestart(at: 3.1))
        XCTAssertTrue(floored.shouldRestart(at: 4), "no budget set: the floor alone decides")

        var stock = EncoderRestartPolicy()
        stock.sessionStarted(kbps: 300, at: 0)
        stock.updateTarget(kbps: 4_000)
        stock.lastKeyFrameBytes = 10_000
        XCTAssertFalse(stock.shouldRestart(at: 5), "the stock 5 Mb/s floor is unchanged when no switch is set")
    }
}
