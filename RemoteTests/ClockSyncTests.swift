import XCTest

final class ClockSyncTests: XCTestCase {
    func testProbeValidation() {
        XCTAssertNoThrow(try ClockProbe(phoneMs: 1_000).validate())
        XCTAssertNoThrow(try ClockProbe(phoneMs: 1_000, hostReceivedMs: 5_000, hostSentMs: 5_000.2).validate())
        XCTAssertThrowsError(try ClockProbe(phoneMs: -1).validate())
        XCTAssertThrowsError(try ClockProbe(phoneMs: .nan).validate())
        XCTAssertThrowsError(try ClockProbe(phoneMs: 1, hostReceivedMs: 5).validate(), "half an echo is malformed")
        XCTAssertThrowsError(try ClockProbe(phoneMs: 1, hostReceivedMs: 6, hostSentMs: 5).validate(), "host cannot send before it received")
        XCTAssertThrowsError(try ClockProbe(phoneMs: 2e13).validate())
    }

    func testProbeRidesOnlyOnHeartbeats() throws {
        let probe = ClockProbe(phoneMs: 12)
        XCTAssertNoThrow(try RemoteAction(action: "heartbeat", clock: probe).validate())
        XCTAssertThrowsError(try RemoteAction(action: "move", clock: probe).validate())
        XCTAssertThrowsError(try RemoteAction(action: "capture", clock: probe).validate())
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(RemoteAction(action: "heartbeat", clock: probe)))
        XCTAssertEqual(decoded.clock, probe)
        let legacy = Data(#"{"action":"heartbeat","x":0,"y":0,"text":"","key":"","modifiers":[],"epoch":1}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(RemoteAction.self, from: legacy).clock)
    }

    func testEstimatorUsesTheLowestRoundTripAndReportsHalfOfIt() {
        var estimator = ClockSyncEstimator()
        // Host clock is 500 ms ahead of the phone; the path is asymmetric on the slow sample.
        XCTAssertTrue(estimator.record(ClockProbe(phoneMs: 1_000, hostReceivedMs: 1_520, hostSentMs: 1_521), receivedAtPhoneMs: 1_040))
        XCTAssertTrue(estimator.record(ClockProbe(phoneMs: 2_000, hostReceivedMs: 2_503, hostSentMs: 2_503.5), receivedAtPhoneMs: 2_006))
        let estimate = estimator.estimate(now: 2_010)
        XCTAssertEqual(estimate?.samples, 2)
        XCTAssertEqual(estimate?.offsetMs ?? 0, 500, accuracy: 0.26, "the 6 ms sample wins: ((503) + (497.5)) / 2")
        XCTAssertEqual(estimate?.uncertaintyMs ?? 0, (6 - 0.5) / 2, accuracy: 0.001)
    }

    func testEstimatorRejectsImpossibleTimingAndExpiresSamples() {
        var estimator = ClockSyncEstimator()
        estimator.windowMs = 1_000
        XCTAssertFalse(estimator.record(ClockProbe(phoneMs: 100), receivedAtPhoneMs: 110), "not an echo")
        XCTAssertFalse(estimator.record(ClockProbe(phoneMs: 100, hostReceivedMs: 900, hostSentMs: 950), receivedAtPhoneMs: 120), "host time inside the round trip exceeds it")
        XCTAssertFalse(estimator.record(ClockProbe(phoneMs: 100, hostReceivedMs: 900, hostSentMs: 900), receivedAtPhoneMs: 5_000), "round trip over the limit")
        XCTAssertTrue(estimator.record(ClockProbe(phoneMs: 100, hostReceivedMs: 900, hostSentMs: 900), receivedAtPhoneMs: 104))
        XCTAssertNotNil(estimator.estimate(now: 500))
        XCTAssertNil(estimator.estimate(now: 1_200), "samples older than the window are dropped")
        estimator.reset()
        XCTAssertNil(estimator.estimate(now: 104))
    }
}
