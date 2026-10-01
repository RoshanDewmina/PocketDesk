import XCTest

final class MediaResourceBudgetTests: XCTestCase {
    private func sample(at: Double = 0, route: String = "Relay", capacity: Double? = 5_000,
                        video: Double? = 3_000, rtt: Double? = 40) -> MediaCapacityObservation {
        MediaCapacityObservation(at: at, route: route, capacityKbps: capacity, videoKbps: video,
                                 rttMs: rtt, pacerDelayMs: 0)
    }

    func testMeasuredCapacityGivesBulkHalfOfSpareAtMostThirtyPercentAndTheRouteCeiling() throws {
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(sample(), at: 1, baselineRTT: 40), 117_000, "(5000-3000-128)*0.5 kbps")
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(sample(capacity: 3_000, video: 0), at: 1, baselineRTT: 40), 112_500, "30% of capacity")
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(sample(capacity: 100_000, video: 0), at: 1, baselineRTT: 40), 187_500, "relay ceiling 1.5 Mbps")
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(sample(route: "Direct", capacity: 4_000, video: 0), at: 1, baselineRTT: 40), 150_000, "30% of capacity")
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(sample(route: "Direct", capacity: 50_000, video: 0), at: 1, baselineRTT: 40), 1_875_000)
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(sample(route: "Direct", capacity: 100_000, video: 0), at: 1, baselineRTT: 40), 2_000_000, "direct ceiling 16 Mbps")
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(sample(video: 4_900), at: 1, baselineRTT: 40), "video keeps the whole estimate")
    }

    func testTransportRateExcludesTheBudgetsOwnBulkBytesWhenComputingSpare() throws {
        var own = sample(route: "Direct", capacity: 10_000, video: 6_000); own.totalTransportKbps = 6_000; own.bulkKbps = 2_000
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(own, at: 1, baselineRTT: 40), 367_000, "(10000-4000-128)*0.5 kbps")
        own.bulkKbps = 9_000
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(own, at: 1, baselineRTT: 40), 375_000, "media never goes below zero")
        own.bulkKbps = .nan
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(own, at: 1, baselineRTT: 40))

        let budget = MediaResourceBudget()
        var observed = sample(capacity: 2_000, video: 1_000); observed.totalTransportKbps = 1_000
        budget.observe(observed)
        var admitted = 0
        for tick in 1...100 where budget.permits(bytes: 1_000, at: Double(tick) / 100, controlBuffered: 0, fileBuffered: 0) {
            admitted += 1_000
        }
        observed.at = 1; observed.videoKbps = 1_000 + Double(admitted) * 8 / 1_000; observed.totalTransportKbps = observed.videoKbps
        budget.observe(observed)
        var next = 0
        for tick in 101...200 where budget.permits(bytes: 1_000, at: Double(tick) / 100, controlBuffered: 0, fileBuffered: 0) {
            next += 1_000
        }
        XCTAssertGreaterThanOrEqual(next, admitted - 1_000, "a transfer's own bytes do not shrink its next window")
    }

    func testMissingCapacityStartsAtTheProbeFloorAndDoesNotClaimAnEstimate() throws {
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(sample(capacity: nil), at: 1, baselineRTT: 40), 48_000)
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(sample(route: "Direct", capacity: nil), at: 1, baselineRTT: 40), 64_000)
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(sample(route: "Route pending"), at: 1, baselineRTT: 40))
        var probed = sample(route: "Direct", capacity: nil); probed.probeKbps = 2_000
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(probed, at: 1, baselineRTT: 40), 250_000)
        probed.probeKbps = 20_000
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(probed, at: 1, baselineRTT: 40), 1_000_000, "direct probe ceiling 8 Mbps")
        probed.route = "Relay"
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(probed, at: 1, baselineRTT: 40), 187_500, "relay probe ceiling 1.5 Mbps")
        probed.probeKbps = .nan
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(probed, at: 1, baselineRTT: 40), 48_000)
        var measured = sample(); measured.probeKbps = 1_500
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(measured, at: 1, baselineRTT: 40), 117_000, "a real estimate ignores the probe")
    }

    func testLANAllowanceRequiresActualSelectedLANAndFreshMeasuredLowRTTOnBothSides() {
        var lan = sample(route: "Direct", capacity: nil, rtt: 8)
        lan.routeDetail = "lan"
        XCTAssertNil(lan.capacityKbps, "policy allowance is not an invented bandwidth estimate")
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(lan, at: 1, baselineRTT: 8), 1_000_000)
        for detail in [nil, "p2p", "relay", "configured-lan"] as [String?] {
            var other = lan; other.routeDetail = detail
            XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(other, at: 1, baselineRTT: 8), 64_000)
        }
        var other = lan; other.rttMs = nil
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(other, at: 1, baselineRTT: nil), 64_000)
        other = lan; other.rttMs = 21
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(other, at: 1, baselineRTT: 8), 64_000)
        other = lan; other.route = "Relay"
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(other, at: 1, baselineRTT: 8), 48_000)
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(lan, at: 3.01, baselineRTT: 8))
        other = lan; other.pacerDelayMs = 50
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(other, at: 1, baselineRTT: 8))

        var host = lan; host.capacityKbps = 300; host.videoKbps = 0
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), 1_000_000, "an allocation-limited host estimate does not hide the LAN")
        host.videoKbps = 5_000
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), 1_000_000)
        host.pacerDelayMs = 50
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), "a backed-up video pacer still pauses files")
        host = lan; host.capacityKbps = 300; host.videoKbps = 0; host.rttMs = 80
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), "RTT inflation still pauses files")
        host.routeDetail = "p2p"; host.rttMs = 8
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), 10_750, "off-LAN host keeps the measured formula")
    }

    func testLANAllowanceBucketReachesTheAllowanceAt10msPumpTicksAndStaysGoverned() {
        let budget = MediaResourceBudget()
        var lan = sample(route: "Direct", capacity: nil, rtt: 8); lan.routeDetail = "lan"
        budget.observe(lan)
        var admitted = 0
        for tick in 1...100 {
            if budget.permits(bytes: 16_384, at: Double(tick) / 100, controlBuffered: 0, fileBuffered: 0) { admitted += 16_384 }
        }
        XCTAssertGreaterThan(admitted, 960_000, "a one-message bucket capped this at 819,200 B (one 16 KiB message per two ticks)")
        XCTAssertLessThanOrEqual(admitted, 1_000_000, "policy is bounded; this is not a network throughput measurement")
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 1.1, controlBuffered: 1, fileBuffered: 0))
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 1.1, controlBuffered: 0, fileBuffered: 0), "no credit accrues while control is queued")
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 1.2, controlBuffered: 0, fileBuffered: 20_000), "aggregate file+refinement credit stays within32KiB")
        XCTAssertFalse(budget.permits(bytes: 1, at: 1.3, controlBuffered: 0, fileBuffered: nil))
        lan.at = 1.4; budget.observe(lan)
        XCTAssertTrue(budget.permits(bytes: 16_384, at: 1.5, controlBuffered: 0, fileBuffered: 0))
        lan.routeDetail = "p2p"; lan.at = 1.5; budget.observe(lan)
        XCTAssertFalse(budget.permits(bytes: 1, at: 1.5, controlBuffered: 0, fileBuffered: 0), "selected route detail change retires LAN credit")
        budget.end(); lan.at = 2; budget.observe(lan)
        XCTAssertFalse(budget.permits(bytes: 1, at: 2.1, controlBuffered: 0, fileBuffered: 0))
    }

    func testBucketHoldsThirtyMillisecondsOfCreditButNeverLessThanOneMessage() {
        XCTAssertEqual(BulkAdmissionPolicy.bucketBytes(rate: 48_000), 16_384)
        XCTAssertEqual(BulkAdmissionPolicy.bucketBytes(rate: 1_000_000), 30_000)
        XCTAssertEqual(BulkAdmissionPolicy.bucketBytes(rate: 2_000_000), 60_000)
    }

    func testStalenessNegativeClockAndNonfiniteCapacityFailClosed() {
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(sample(), at: 3.01, baselineRTT: 40))
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(sample(), at: -1, baselineRTT: 40))
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(sample(capacity: .nan), at: 1, baselineRTT: 40))
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(sample(rtt: 100), at: 1, baselineRTT: 40))
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(sample(capacity: nil, rtt: 100), at: 1, baselineRTT: 40), "the probe never overrides the RTT gate")
    }

    func testControlCongestionConsumesNoRecoveryBurstAndCloseIsFinal() {
        let budget = MediaResourceBudget()
        budget.observe(sample())
        XCTAssertTrue(budget.permits(bytes: 16_384, at: 1, controlBuffered: 0, fileBuffered: 0))
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 1, controlBuffered: 0, fileBuffered: 0))
        XCTAssertFalse(budget.permits(bytes: 1, at: 2, controlBuffered: 1, fileBuffered: 0))
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 2, controlBuffered: 0, fileBuffered: 0))
        XCTAssertFalse(budget.permits(bytes: 1, at: 2.5, controlBuffered: nil, fileBuffered: 0), "a closed control channel fails closed")
        budget.end()
        budget.observe(sample(at: 3))
        XCTAssertFalse(budget.permits(bytes: 1, at: 4, controlBuffered: 0, fileBuffered: 0))
    }

    func testControlBacklogPausesAccrualButKeepsEarnedCredit() {
        let budget = MediaResourceBudget()
        budget.observe(sample(video: 4_000))
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 0.2, controlBuffered: 0, fileBuffered: 30_000), "earns 10,900 B while the queue is full")
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 0.3, controlBuffered: 1, fileBuffered: 0))
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 0.4, controlBuffered: 2, fileBuffered: 0))
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 0.4, controlBuffered: 0, fileBuffered: 0), "the 200 ms control pause earned nothing")
        XCTAssertTrue(budget.permits(bytes: 16_384, at: 0.55, controlBuffered: 0, fileBuffered: 0), "10,900 earned before the pause + 8,175 after")
    }

    func testBufferedByteBoundKeepsCreditAndRouteChangeResetsIt() {
        let budget = MediaResourceBudget()
        budget.observe(sample())
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 1, controlBuffered: 0, fileBuffered: 20_000))
        XCTAssertFalse(budget.permits(bytes: 1, at: 1, controlBuffered: 0, fileBuffered: .max))
        XCTAssertTrue(budget.permits(bytes: 16_384, at: 1, controlBuffered: 0, fileBuffered: 0), "a full file queue is not congestion")
        XCTAssertFalse(budget.permits(bytes: 16_385, at: 2, controlBuffered: 0, fileBuffered: 0))
        XCTAssertTrue(budget.permits(bytes: 16_384, at: 3, controlBuffered: 0, fileBuffered: 0))
        budget.observe(sample(at: 3, route: "Direct"))
        XCTAssertFalse(budget.permits(bytes: 1, at: 3, controlBuffered: 0, fileBuffered: 0))
    }

    func testProbeRampsOnlyWhenUsedAndCalmHalvesOnInflationOrStandingQueueAndIsBounded() {
        var probe = BulkRateProbe(route: "Direct")
        XCTAssertEqual(probe.kbps, 512)
        probe.update(achievedKbps: 300, rttMs: 40, baselineRTTMs: 40, standingQueue: false)
        XCTAssertEqual(probe.kbps, 512, "an under-used allowance is not evidence of headroom")
        probe.update(achievedKbps: 512, rttMs: nil, baselineRTTMs: 40, standingQueue: false)
        XCTAssertEqual(probe.kbps, 512, "no RTT, no ramp")
        probe.update(achievedKbps: 360, rttMs: 59, baselineRTTMs: 40, standingQueue: false)
        XCTAssertEqual(probe.kbps, 768, "70% use and +19 ms ramps x1.5")
        probe.update(achievedKbps: 768, rttMs: 61, baselineRTTMs: 40, standingQueue: false)
        XCTAssertEqual(probe.kbps, 512, "+21 ms is over 1.5x a 40 ms baseline")
        probe.update(achievedKbps: 512, rttMs: 40, baselineRTTMs: 40, standingQueue: true)
        XCTAssertEqual(probe.kbps, 512, "halving stops at the floor")
        for _ in 0..<20 { probe.update(achievedKbps: probe.kbps, rttMs: 40, baselineRTTMs: 40, standingQueue: false) }
        XCTAssertEqual(probe.kbps, 8_000)
        probe.update(achievedKbps: 8_000, rttMs: 40, baselineRTTMs: 40, standingQueue: true)
        XCTAssertEqual(probe.kbps, 4_000)

        XCTAssertTrue(BulkRateProbe.inflated(rttMs: 251, baselineRTTMs: 200), "+50 ms caps the 1.5x rule on long paths")
        XCTAssertFalse(BulkRateProbe.inflated(rttMs: 249, baselineRTTMs: 200))
        XCTAssertFalse(BulkRateProbe.inflated(rttMs: 11, baselineRTTMs: 2), "10 ms jitter floor on short paths")
        XCTAssertTrue(BulkRateProbe.inflated(rttMs: 12.5, baselineRTTMs: 2))

        var relay = BulkRateProbe(route: "Relay")
        XCTAssertEqual(relay.kbps, 384)
        for _ in 0..<20 { relay.update(achievedKbps: relay.kbps, rttMs: 80, baselineRTTMs: 80, standingQueue: false) }
        XCTAssertEqual(relay.kbps, 1_500)
    }

    /// Mirrors the engine pump: 16 KiB messages at 10 ms retries, stats every second, an instantly
    /// draining queue unless `buffered` says otherwise. Returns bytes admitted per one-second window.
    private func simulatePump(_ budget: MediaResourceBudget, seconds: Int, observation: (Double) -> MediaCapacityObservation,
                              buffered: (Int) -> UInt64 = { _ in 0 }, total: Int = .max) -> [Int] {
        var windows: [Int] = [], sent = 0
        for second in 0..<seconds {
            budget.observe(observation(Double(second)))
            var window = 0
            for tick in 1...100 where sent < total {
                let at = Double(second) + Double(tick) / 100
                while sent < total, budget.permits(bytes: 16_384, at: at, controlBuffered: 0, fileBuffered: buffered(second)) {
                    window += 16_384; sent += 16_384
                }
            }
            windows.append(window)
        }
        return windows
    }

    func testPhoneProbeMovesFourMebibytesOffLANFarFasterThanTheOldFixedFallback() {
        let fourMiB = 4 * 1024 * 1024
        for (route, detail, rtt, oldRate, bound) in [("Direct", "p2p", 40.0, 32_000.0, 12), ("Relay", "relay", 90.0, 16_000.0, 30)] {
            let budget = MediaResourceBudget()
            let windows = simulatePump(budget, seconds: 40, observation: { at in
                var next = MediaCapacityObservation(at: at, route: route, capacityKbps: nil, videoKbps: 200, rttMs: rtt, pacerDelayMs: 0)
                next.routeDetail = detail; return next
            }, total: fourMiB)
            var seconds = 0, moved = 0
            for bytes in windows where moved < fourMiB { seconds += 1; moved += bytes }
            XCTAssertGreaterThanOrEqual(windows.reduce(0, +), fourMiB)
            XCTAssertLessThanOrEqual(seconds, bound, "\(route): 4 MiB in \(seconds) s; the old fixed fallback needed \(Int(Double(fourMiB) / oldRate)) s")
            XCTAssertLessThanOrEqual(windows.max() ?? 0, route == "Relay" ? 187_500 + 16_384 : 1_000_000 + 32_768, "probe ceiling holds")
        }
    }

    func testPhoneProbeBacksOffOnRTTInflationAndStandingQueue() {
        let budget = MediaResourceBudget()
        let windows = simulatePump(budget, seconds: 10, observation: { at in
            var next = MediaCapacityObservation(at: at, route: "Direct", capacityKbps: nil, videoKbps: 200,
                                                rttMs: at == 6 ? 120 : 40, pacerDelayMs: 0)
            next.routeDetail = "p2p"; return next
        }, buffered: { $0 == 8 ? 20_000 : 0 })
        XCTAssertGreaterThan(windows[5], windows[4], "ramping while calm")
        XCTAssertEqual(windows[6], 0, "+80 ms over a 40 ms baseline pauses files")
        XCTAssertLessThan(windows[7], windows[5], "the window after inflation runs at half rate")
        XCTAssertEqual(windows[8], 0, "a queue that never drains admits nothing")
        XCTAssertLessThan(windows[9], windows[7], "and halves the next window")
    }
}
