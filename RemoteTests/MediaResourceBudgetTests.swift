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

    func testMissingCapacityStartsAtTheProbeStartRateAndDoesNotClaimAnEstimate() throws {
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
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(probed, at: 1, baselineRTT: 40), 48_000, "unknown probe uses the start rate")
        probed.probeKbps = 50
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(probed, at: 1, baselineRTT: 40), 16_000, "relay floor 128 kbps")
        probed.route = "Direct"
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(probed, at: 1, baselineRTT: 40), 32_000, "direct floor 256 kbps")
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

        var host = lan; host.capacityKbps = 300; host.videoKbps = 0; host.senderMaxKbps = 350
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), 1_000_000, "an allocation-limited host estimate does not hide the LAN")
        host.videoKbps = 5_000
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), 1_000_000)
        host.pacerDelayMs = 50
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), "a backed-up video pacer still pauses files")
        host = lan; host.capacityKbps = 300; host.videoKbps = 0; host.senderMaxKbps = 350; host.rttMs = 80
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), "RTT inflation still pauses files")
        host.rttMs = 8; host.senderMaxKbps = 20_000
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), 1_000_000,
                       "an estimate video is not using (GCC grows only ~1.5x acked throughput) does not hide the LAN")
        host.senderMaxKbps = nil
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), 1_000_000, "nor does an unknown encoder ceiling")
        host.videoKbps = 290; host.senderMaxKbps = 20_000
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), "edge of Wi-Fi: video needs the whole estimate")
        host.capacityKbps = 2_000; host.videoKbps = 1_700
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), 10_750, "edge of Wi-Fi keeps the measured formula")
        host.capacityKbps = 300; host.videoKbps = 0
        for (sample, floor) in [(nil, true), (12.0, true), (19.0, false), (25.0, false)] as [(Double?, Bool)] {
            host.rttSampleMs = sample
            XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), floor ? 1_000_000 : 10_750,
                           "LAN floor needs a calm window RTT sample: \(String(describing: sample)) ms")
        }
        host.rttSampleMs = nil
        host.routeDetail = "p2p"; host.senderMaxKbps = 350; host.videoKbps = 0
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(host, at: 1, baselineRTT: 8), 10_750, "off-LAN host keeps the measured formula")
    }

    func testDegradedSenderGovernorOrDeepSenderQueueStopsBulkEverywhere() {
        var lan = sample(route: "Direct", capacity: nil, rtt: 8); lan.routeDetail = "lan"
        var host = lan; host.capacityKbps = 300; host.videoKbps = 0; host.senderMaxKbps = 350
        var probed = sample(route: "Direct", capacity: nil); probed.probeKbps = 2_000
        for base in [lan, host, probed, sample()] {
            XCTAssertNotNil(BulkAdmissionPolicy.bytesPerSecond(base, at: 1, baselineRTT: 8))
            var next = base; next.governorDegraded = true
            XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(next, at: 1, baselineRTT: 8))
            next = base; next.senderQueueMs = 100
            XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(next, at: 1, baselineRTT: 8))
            next.senderQueueMs = .nan
            XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(next, at: 1, baselineRTT: 8))
            next.senderQueueMs = 99
            XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(next, at: 1, baselineRTT: 8), BulkAdmissionPolicy.bytesPerSecond(base, at: 1, baselineRTT: 8))
        }
        let budget = MediaResourceBudget()
        budget.observe(lan)
        XCTAssertTrue(budget.permits(bytes: 16_384, at: 0.1, controlBuffered: 0, fileBuffered: 0))
        lan.at = 0.2; lan.governorDegraded = true; budget.observe(lan)
        XCTAssertFalse(budget.permits(bytes: 1, at: 0.5, controlBuffered: 0, fileBuffered: 0))
    }

    func testLANAllowanceBucketReachesTheAllowanceAt10msPumpTicksAndStaysGoverned() {
        let budget = MediaResourceBudget(fastLane: false) // The kill-switch and ladder-step fallback.
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

    func testCalmLANFastLaneQueuesMebibytesInLargeMessagesAndBacksOffForInputLadderAndKillSwitch() {
        var lan = sample(route: "Direct", capacity: nil, rtt: 8); lan.routeDetail = "lan"; lan.rttSampleMs = 8
        XCTAssertEqual(BulkAdmissionPolicy.maxMessageSize(sdp: "v=0\r\na=sctp-port:5000\r\na=max-message-size:262144\r\n"), 262_144)
        XCTAssertNil(BulkAdmissionPolicy.maxMessageSize(sdp: "v=0\r\na=sctp-port:5000\r\n"))
        let budget = MediaResourceBudget(fastLane: true)
        budget.observe(lan)
        XCTAssertEqual(budget.messageBytes(at: 0.1), 16_384, "64 KiB only once the peer's SDP allows it")
        budget.observePeerMaxMessageSize(262_144)
        XCTAssertEqual(budget.messageBytes(at: 0.1), 65_536)
        XCTAssertTrue(budget.permits(bytes: 65_536, at: 0.2, controlBuffered: 0, fileBuffered: 1_900_000), "MiB-scale queue")
        XCTAssertFalse(budget.permits(bytes: 65_536, at: 0.3, controlBuffered: 0, fileBuffered: 2_040_000), "bounded at 2 MiB")
        var admitted = 0
        for tick in 1...100 where budget.permits(bytes: 65_536, at: 0.3 + Double(tick) / 100, controlBuffered: 0, fileBuffered: 0) {
            admitted += 65_536
        }
        XCTAssertGreaterThan(admitted, 20_000_000, "tens of MB/s, not the 1 MB/s floor")
        XCTAssertLessThanOrEqual(admitted, 26_000_000, "still a bounded allowance")
        XCTAssertFalse(budget.permits(bytes: 65_536, at: 1.4, controlBuffered: 1, fileBuffered: 0), "queued input pauses files")

        budget.observeLadder(steppedDown: true)
        XCTAssertEqual(budget.messageBytes(at: 1.5), 16_384, "a ladder step backs off to the conservative lane")
        XCTAssertFalse(budget.permits(bytes: 65_536, at: 1.5, controlBuffered: 0, fileBuffered: 0))
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 1.6, controlBuffered: 0, fileBuffered: 40_000), "32 KiB queue again")
        budget.observeLadder(steppedDown: false)
        XCTAssertEqual(budget.messageBytes(at: 1.7), 65_536)
        budget.observePeerMaxMessageSize(65_535)
        XCTAssertEqual(budget.messageBytes(at: 1.7), 16_384, "a peer that cannot take 64 KiB keeps 16 KiB messages")

        var busy = lan; busy.at = 1.8; busy.rttSampleMs = 30; budget.observe(busy)
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 1.9, controlBuffered: 0, fileBuffered: 100_000), "an RTT rise leaves the fast lane")

        let disabled = MediaResourceBudget(fastLane: false)
        disabled.observe(lan); disabled.observePeerMaxMessageSize(0)
        XCTAssertEqual(disabled.messageBytes(at: 0.1), 16_384, "kill switch keeps the old lane")
        XCTAssertFalse(disabled.permits(bytes: 16_384, at: 0.2, controlBuffered: 0, fileBuffered: 40_000))
        var relay = lan; relay.route = "Relay"; relay.routeDetail = "relay"
        let relayed = MediaResourceBudget(fastLane: true); relayed.observe(relay); relayed.observePeerMaxMessageSize(0)
        XCTAssertEqual(relayed.messageBytes(at: 0.1), BulkAdmissionPolicy.messageBytes(rate: 48_000), "relay pacing is unchanged")
    }

    func testBucketHoldsThirtyMillisecondsOfCreditButNeverLessThanOneMessage() {
        XCTAssertEqual(BulkAdmissionPolicy.bucketBytes(rate: 48_000), 16_384)
        XCTAssertEqual(BulkAdmissionPolicy.bucketBytes(rate: 1_000_000), 30_000)
        XCTAssertEqual(BulkAdmissionPolicy.bucketBytes(rate: 2_000_000), 60_000)
    }

    func testMessagesCarryFiftyMillisecondsOfRateBetweenTwoAndSixteenKiB() {
        XCTAssertEqual(BulkAdmissionPolicy.messageBytes(rate: 16_000), 2_048)
        XCTAssertEqual(BulkAdmissionPolicy.messageBytes(rate: 48_000), 2_400)
        XCTAssertEqual(BulkAdmissionPolicy.messageBytes(rate: 187_500), 9_375)
        XCTAssertEqual(BulkAdmissionPolicy.messageBytes(rate: 1_000_000), 16_384)
        XCTAssertEqual(BulkAdmissionPolicy.messageBytes(rate: .nan), 16_384)
        let budget = MediaResourceBudget()
        XCTAssertEqual(budget.messageBytes(at: 0), 16_384, "no observation: the send is refused anyway")
        budget.observe(sample(capacity: nil))
        XCTAssertEqual(budget.messageBytes(at: 0.5), 2_400)
    }

    func testBaselineRTTExpiresAfterALegitimatePathChange() {
        let budget = MediaResourceBudget()
        func observe(_ at: Double, _ rtt: Double) {
            var next = sample(at: at, route: "Direct", capacity: nil, rtt: rtt); next.routeDetail = "p2p"; next.rttSampleMs = rtt
            budget.observe(next)
        }
        observe(0, 40)
        for second in 1...14 { observe(Double(second), 150) }
        XCTAssertFalse(budget.permits(bytes: 2_048, at: 14.5, controlBuffered: 0, fileBuffered: 0), "+110 ms over the old path pauses files")
        observe(15, 150)
        XCTAssertTrue(budget.permits(bytes: 2_048, at: 15.5, controlBuffered: 0, fileBuffered: 0), "after 15 s the new path is the baseline")
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

    func testProbeRampsOnlyWhenUsedAndCalmHalvesOnInflationAndIsBounded() {
        var probe = BulkRateProbe(route: "Direct")
        XCTAssertEqual([probe.startKbps, probe.floorKbps, probe.ceilingKbps, probe.kbps], [512, 256, 8_000, 512])
        probe.update(achievedKbps: 300, rttSampleMs: 40, baselineRTTMs: 40, queueRefusedShare: 0)
        XCTAssertEqual(probe.kbps, 512, "an under-used allowance is not evidence of headroom")
        probe.update(achievedKbps: 512, rttSampleMs: nil, baselineRTTMs: 40, queueRefusedShare: 0)
        XCTAssertEqual(probe.kbps, 512, "no fresh RTT sample, no RTT decision")
        probe.update(achievedKbps: 360, rttSampleMs: 59, baselineRTTMs: 40, queueRefusedShare: 0)
        XCTAssertEqual(probe.kbps, 768, "70% use and +19 ms ramps x1.5")
        probe.update(achievedKbps: 768, rttSampleMs: 61, baselineRTTMs: 40, queueRefusedShare: 0)
        XCTAssertEqual(probe.kbps, 384, "+21 ms is over 1.5x a 40 ms baseline")
        probe.update(achievedKbps: 384, rttSampleMs: 100, baselineRTTMs: 40, queueRefusedShare: 0)
        XCTAssertEqual(probe.kbps, 256, "halving stops at the floor, below the start rate")
        for _ in 0..<20 { probe.update(achievedKbps: probe.kbps, rttSampleMs: 40, baselineRTTMs: 40, queueRefusedShare: 0) }
        XCTAssertEqual(probe.kbps, 8_000)

        XCTAssertTrue(BulkRateProbe.inflated(rttMs: 251, baselineRTTMs: 200), "+50 ms caps the 1.5x rule on long paths")
        XCTAssertFalse(BulkRateProbe.inflated(rttMs: 249, baselineRTTMs: 200))
        XCTAssertFalse(BulkRateProbe.inflated(rttMs: 11, baselineRTTMs: 2), "10 ms jitter floor on short paths")
        XCTAssertTrue(BulkRateProbe.inflated(rttMs: 12.5, baselineRTTMs: 2))

        var relay = BulkRateProbe(route: "Relay")
        XCTAssertEqual([relay.startKbps, relay.floorKbps, relay.ceilingKbps], [384, 128, 1_500])
        for _ in 0..<20 { relay.update(achievedKbps: relay.kbps, rttSampleMs: 80, baselineRTTMs: 80, queueRefusedShare: 0) }
        XCTAssertEqual(relay.kbps, 1_500)
    }

    func testProbeFallsBelowAchievedWhenTheFileQueueRefusesMostSends() {
        var probe = BulkRateProbe(route: "Direct")
        for _ in 0..<4 { probe.update(achievedKbps: probe.kbps, rttSampleMs: 40, baselineRTTMs: 40, queueRefusedShare: 0) }
        XCTAssertEqual(probe.kbps, 2_592)
        probe.update(achievedKbps: 2_000, rttSampleMs: 40, baselineRTTMs: 40, queueRefusedShare: 0.6)
        XCTAssertEqual(probe.kbps, 1_700, "0.85 x achieved, no ramp despite calm RTT")
        probe.update(achievedKbps: 1_700, rttSampleMs: nil, baselineRTTMs: 40, queueRefusedShare: 0.5)
        XCTAssertEqual(probe.kbps, 1_700, "half the sends refused is not yet a standing queue")
        probe.update(achievedKbps: 100, rttSampleMs: 40, baselineRTTMs: 40, queueRefusedShare: 0.9)
        XCTAssertEqual(probe.kbps, 850, "one back-off halves at most: a window straddling a transfer's start under-reports achieved")
        probe.update(achievedKbps: 0, rttSampleMs: 40, baselineRTTMs: 40, queueRefusedShare: 0, standingQueue: true)
        XCTAssertEqual(probe.kbps, 425, "a standing queue backs off the same way")
        for _ in 0..<4 { probe.update(achievedKbps: 0, rttSampleMs: 40, baselineRTTMs: 40, queueRefusedShare: 1) }
        XCTAssertEqual(probe.kbps, 256, "never below the floor")
    }

    func testIdleProbeDecaysBackToTheStartRate() {
        var probe = BulkRateProbe(route: "Direct")
        for _ in 0..<7 { probe.update(achievedKbps: probe.kbps, rttSampleMs: 40, baselineRTTMs: 40, queueRefusedShare: 0) }
        XCTAssertEqual(probe.kbps, 8_000)
        var decay: [Double] = []
        for _ in 0..<6 { probe.update(achievedKbps: 0, rttSampleMs: 40, baselineRTTMs: 40, queueRefusedShare: 0); decay.append(probe.kbps) }
        XCTAssertEqual(decay, [4_000, 2_000, 1_000, 512, 512, 512], "an idle window halves, never below the start rate")
        probe.update(achievedKbps: 300, rttSampleMs: 100, baselineRTTMs: 40, queueRefusedShare: 0)
        XCTAssertEqual(probe.kbps, 256)
        probe.update(achievedKbps: 0, rttSampleMs: 40, baselineRTTMs: 40, queueRefusedShare: 0)
        XCTAssertEqual(probe.kbps, 256, "idle does not lift a probe that congestion pushed below the start")
    }

    /// Mirrors the engine pump: rate-sized messages (or `fixedMessage`) on 10 ms retries, stats every second,
    /// and a link draining `drain` B/s (instant when nil). `each` sees the queue before each tick's sends.
    /// Returns bytes admitted per one-second window.
    private func simulatePump(_ budget: MediaResourceBudget, seconds: Int, observation: (Double) -> MediaCapacityObservation,
                              drain: Double? = nil, fixedMessage: Int? = nil, total: Int = .max,
                              each: (Int, UInt64) -> Void = { _, _ in }) -> [Int] {
        var windows: [Int] = [], sent = 0, buffered: UInt64 = 0
        for second in 0..<seconds {
            budget.observe(observation(Double(second)))
            var window = 0
            for tick in 1...100 where sent < total {
                let at = Double(second) + Double(tick) / 100
                buffered = drain.map { UInt64(max(0, Double(buffered) - $0 / 100)) } ?? 0
                each(second, buffered)
                while sent < total {
                    let bytes = fixedMessage ?? budget.messageBytes(at: at)
                    guard budget.permits(bytes: bytes, at: at, controlBuffered: 0, fileBuffered: buffered) else { break }
                    window += bytes; sent += bytes
                    if drain != nil { buffered += UInt64(bytes) }
                }
            }
            windows.append(window)
        }
        return windows
    }

    private func offLAN(_ route: String, rtt: Double, at: Double) -> MediaCapacityObservation {
        var next = MediaCapacityObservation(at: at, route: route, capacityKbps: nil, videoKbps: 200, rttMs: rtt, pacerDelayMs: 0)
        next.routeDetail = route == "Relay" ? "relay" : "p2p"; next.rttSampleMs = rtt
        return next
    }

    func testPhoneProbeMovesFourMebibytesOffLANFarFasterThanTheOldFixedFallback() {
        let fourMiB = 4 * 1024 * 1024
        for (route, rtt, oldRate, bound) in [("Direct", 40.0, 32_000.0, 12), ("Relay", 90.0, 16_000.0, 30)] {
            let budget = MediaResourceBudget()
            let windows = simulatePump(budget, seconds: 40, observation: { self.offLAN(route, rtt: rtt, at: $0) }, total: fourMiB)
            var seconds = 0, moved = 0
            for bytes in windows where moved < fourMiB { seconds += 1; moved += bytes }
            XCTAssertGreaterThanOrEqual(windows.reduce(0, +), fourMiB)
            XCTAssertLessThanOrEqual(seconds, bound, "\(route): 4 MiB in \(seconds) s \(windows); the old fixed fallback needed \(Int(Double(fourMiB) / oldRate)) s")
            XCTAssertLessThanOrEqual(windows.max() ?? 0, route == "Relay" ? 187_500 + 16_384 : 1_000_000 + 32_768, "probe ceiling holds")
        }
    }

    func testProbeDoesNotRampPastALinkSlowerThanItsAllowance() {
        let link = 55_000.0, linkKbps = 440.0
        for fixed in [16_384, nil] as [Int?] {
            let label = "message \(fixed.map(String.init) ?? "rate-sized")"
            let budget = MediaResourceBudget()
            var allowance: [Double] = [], low: [UInt64] = [], high: UInt64 = 0
            let windows = simulatePump(budget, seconds: 30, observation: { at in
                if at > 0, let kbps = budget.probedKbps { allowance.append(kbps) }
                return self.offLAN("Direct", rtt: 40, at: at)
            }, drain: link, fixedMessage: fixed) { second, buffered in
                if low.count == second { low.append(buffered) } else { low[second] = min(low[second], buffered) }
                high = max(high, buffered)
            }
            XCTAssertLessThanOrEqual(high, 32 * 1_024, label)
            XCTAssertGreaterThan(high, 30 * 1_024, "\(label): the allowance outruns the link and fills the queue")
            let steady = Array(allowance.dropFirst(5))
            XCTAssertLessThanOrEqual(steady.reduce(0, +) / Double(steady.count), linkKbps * 1.5, "\(label): \(allowance)")
            XCTAssertLessThanOrEqual(steady.max() ?? .infinity, linkKbps * 2, "\(label): one probe step at most: \(allowance)")
            let moved = Double(windows.dropFirst(5).reduce(0, +)) / Double(windows.count - 5)
            XCTAssertLessThanOrEqual(moved, link * 1.05, label)
            XCTAssertGreaterThan(moved, link * 0.6, "\(label): backing off does not starve the transfer")
            guard fixed == nil else {
                // A whole 16 KiB message takes 0.3 s to drain here, so the queue swings 15-31 KiB by
                // granularity alone; the refused-send share keeps the probe from running away.
                XCTAssertLessThanOrEqual(low.dropFirst(5).min() ?? 0, 16 * 1_024, "\(label): \(low)")
                continue
            }
            var standing = 0
            for window in 1..<(allowance.count - 1) where low[window] >= 16 * 1_024 {
                standing += 1
                XCTAssertLessThanOrEqual(allowance[window + 1], allowance[window],
                                         "\(label): no ramp after window \(window) whose queue never drained below 16 KiB: \(allowance)")
            }
            XCTAssertGreaterThan(standing, 2, "\(label): \(low)")
        }
    }

    func testPhoneProbeBacksOffOnPerWindowRTTInflation() {
        let budget = MediaResourceBudget()
        let windows = simulatePump(budget, seconds: 9, observation: { at in
            var next = self.offLAN("Direct", rtt: 40, at: at)
            if at == 6 { next.rttSampleMs = 75 }
            return next
        })
        XCTAssertGreaterThan(windows[5], windows[4], "ramping while calm")
        XCTAssertLessThan(windows[6], windows[5], "a +35 ms window mean halves the next window")
        XCTAssertGreaterThan(windows[7], windows[6], "and the ramp resumes once calm")
    }

    func testGovernorHookStopsAnOngoingTransferWithinOneWindow() {
        let budget = MediaResourceBudget()
        let windows = simulatePump(budget, seconds: 4, observation: { at in
            var next = self.offLAN("Direct", rtt: 40, at: at)
            if at == 2 { next.senderQueueMs = 120 }
            if at == 3 { next.governorDegraded = true }
            return next
        })
        XCTAssertGreaterThan(windows[1], 0)
        XCTAssertEqual(windows[2], 0)
        XCTAssertEqual(windows[3], 0)
    }
}
