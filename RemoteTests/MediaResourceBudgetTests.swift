import XCTest

final class MediaResourceBudgetTests: XCTestCase {
    private func sample(at: Double = 0, route: String = "Relay", capacity: Double? = 5_000,
                        video: Double? = 3_000, rtt: Double? = 40) -> MediaCapacityObservation {
        MediaCapacityObservation(at: at, route: route, capacityKbps: capacity, videoKbps: video,
                                 rttMs: rtt, pacerDelayMs: 0)
    }

    func testFiveMegabitBudgetLeavesBulkBelowTenPercentAndNeverTwelveMegabits() throws {
        let rate = try XCTUnwrap(BulkAdmissionPolicy.bytesPerSecond(sample(), at: 1, baselineRTT: 40))
        XCTAssertEqual(rate, 58_500)
        XCTAssertLessThanOrEqual(rate * 8, 500_000)
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(sample(video: 4_900), at: 1, baselineRTT: 40))
    }

    func testMissingCapacityFallbackIsBoundedAndDoesNotClaimAnEstimate() throws {
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(sample(capacity: nil), at: 1, baselineRTT: 40), 16_000)
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(sample(route: "Direct", capacity: nil), at: 1, baselineRTT: 40), 32_000)
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(sample(route: "Route pending"), at: 1, baselineRTT: 40))
    }

    func testFasterUnknownCapacityPolicyRequiresActualSelectedLANAndFreshMeasuredLowRTT() {
        var lan = sample(route: "Direct", capacity: nil, rtt: 8)
        lan.routeDetail = "lan"
        XCTAssertNil(lan.capacityKbps, "policy allowance is not an invented bandwidth estimate")
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(lan, at: 1, baselineRTT: 8), 1_000_000)
        for detail in [nil, "p2p", "relay", "configured-lan"] as [String?] {
            var other = lan; other.routeDetail = detail
            XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(other, at: 1, baselineRTT: 8), 32_000)
        }
        var other = lan; other.rttMs = nil
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(other, at: 1, baselineRTT: nil), 32_000)
        other = lan; other.rttMs = 21
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(other, at: 1, baselineRTT: 8), 32_000)
        other = lan; other.route = "Relay"
        XCTAssertEqual(BulkAdmissionPolicy.bytesPerSecond(other, at: 1, baselineRTT: 8), 16_000)
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(lan, at: 3.01, baselineRTT: 8))
        other = lan; other.pacerDelayMs = 50
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(other, at: 1, baselineRTT: 8))
    }

    func testLANAllowanceRemainsGovernedByAggregateQueueControlAndRouteRetirement() {
        let budget = MediaResourceBudget()
        var lan = sample(route: "Direct", capacity: nil, rtt: 8); lan.routeDetail = "lan"
        budget.observe(lan)
        var admitted = 0
        for tick in 1...100 {
            if budget.permits(bytes: 16_384, at: Double(tick) / 100, controlBuffered: 0, fileBuffered: 0) { admitted += 16_384 }
        }
        XCTAssertGreaterThan(admitted, 700_000, "deterministic policy credit no longer limits a healthy LAN upload to31KiB/s")
        XCTAssertLessThanOrEqual(admitted, 1_000_000, "policy is bounded; this is not a network throughput measurement")
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 1.1, controlBuffered: 1, fileBuffered: 0))
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 1.1, controlBuffered: 0, fileBuffered: 0), "no recovery burst after control traffic")
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 1.2, controlBuffered: 0, fileBuffered: 20_000), "aggregate file+refinement credit stays within32KiB")
        XCTAssertFalse(budget.permits(bytes: 1, at: 1.3, controlBuffered: 0, fileBuffered: nil))
        lan.at = 1.4; budget.observe(lan)
        XCTAssertTrue(budget.permits(bytes: 16_384, at: 1.5, controlBuffered: 0, fileBuffered: 0))
        lan.routeDetail = "p2p"; lan.at = 1.5; budget.observe(lan)
        XCTAssertFalse(budget.permits(bytes: 1, at: 1.5, controlBuffered: 0, fileBuffered: 0), "selected route detail change retires LAN credit")
        budget.end(); lan.at = 2; budget.observe(lan)
        XCTAssertFalse(budget.permits(bytes: 1, at: 2.1, controlBuffered: 0, fileBuffered: 0))
    }

    func testStalenessNegativeClockAndNonfiniteCapacityFailClosed() {
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(sample(), at: 3.01, baselineRTT: 40))
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(sample(), at: -1, baselineRTT: 40))
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(sample(capacity: .nan), at: 1, baselineRTT: 40))
        XCTAssertNil(BulkAdmissionPolicy.bytesPerSecond(sample(rtt: 100), at: 1, baselineRTT: 40))
    }

    func testControlCongestionConsumesNoRecoveryBurstAndCloseIsFinal() {
        let budget = MediaResourceBudget()
        budget.observe(sample())
        XCTAssertTrue(budget.permits(bytes: 16_384, at: 1, controlBuffered: 0, fileBuffered: 0))
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 1, controlBuffered: 0, fileBuffered: 0))
        XCTAssertFalse(budget.permits(bytes: 1, at: 2, controlBuffered: 1, fileBuffered: 0))
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 2, controlBuffered: 0, fileBuffered: 0))
        budget.end()
        budget.observe(sample(at: 3))
        XCTAssertFalse(budget.permits(bytes: 1, at: 4, controlBuffered: 0, fileBuffered: 0))
    }

    func testBufferedByteBoundAndRouteChangeResetCredit() {
        let budget = MediaResourceBudget()
        budget.observe(sample())
        XCTAssertFalse(budget.permits(bytes: 16_384, at: 1, controlBuffered: 0, fileBuffered: 20_000))
        XCTAssertFalse(budget.permits(bytes: 1, at: 1, controlBuffered: 0, fileBuffered: .max))
        XCTAssertFalse(budget.permits(bytes: 16_385, at: 2, controlBuffered: 0, fileBuffered: 0))
        XCTAssertTrue(budget.permits(bytes: 16_384, at: 3, controlBuffered: 0, fileBuffered: 0))
        budget.observe(sample(at: 3, route: "Direct"))
        XCTAssertFalse(budget.permits(bytes: 1, at: 3, controlBuffered: 0, fileBuffered: 0))
    }
}
