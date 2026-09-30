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
