import XCTest

final class ExactVideoTimingTests: XCTestCase {
    private let generation = String(repeating: "a", count: 32)
    private let nonce = String(repeating: "b", count: 32)
    private func timing(resend: Bool = false) -> ExactVideoTiming {
        ExactVideoTiming(sourceID: String(repeating: "c", count: 32), displayMs: 1_000, capturedMs: 1_002,
                         pushedMs: 1_003, submittedMs: 1_005, encodedMs: 1_010, resend: resend)
    }
    func testPresentationRequiresTheSameSuccessfullyDecodedAccessUnitAndCannotReplay() {
        let receiver = ExactVideoTimingReceiver(), value = timing()
        let clock = ClockSyncEstimate(offsetMs: 100, uncertaintyMs: 2, samples: 3)
        receiver.presented(value, generation: generation, nonce: nonce, atMs: 950, clock: clock, clockRecordedAtMs: 900, nowMs: 960)
        XCTAssertEqual(receiver.drain().presented, 0)
        receiver.decoded(value, generation: generation, nonce: nonce, atMs: 930)
        receiver.presented(value, generation: generation, nonce: nonce, atMs: 950, clock: clock, clockRecordedAtMs: 900, nowMs: 960)
        let report = receiver.drain()
        XCTAssertEqual(report.uniqueSources, 1); XCTAssertEqual(report.timed, 1)
        XCTAssertEqual(report.captureToDecodeP50Ms, 30); XCTAssertEqual(report.captureToPresentP95Ms, 50)
        XCTAssertEqual(report.maximumClockUncertaintyMs, 2)
        receiver.decoded(value, generation: generation, nonce: nonce, atMs: 970)
        receiver.presented(value, generation: generation, nonce: nonce, atMs: 980, clock: clock, clockRecordedAtMs: 900, nowMs: 990)
        XCTAssertEqual(receiver.drain().presented, 0)
    }
    func testReencodedSameSourceAndIdleResendNeverInflateUniqueCadence() {
        let receiver = ExactVideoTimingReceiver()
        for (index, resend) in [false, false, true].enumerated() {
            let n = String(format: "%032x", index), value = timing(resend: resend)
            receiver.decoded(value, generation: generation, nonce: n, atMs: 930)
            receiver.presented(value, generation: generation, nonce: n, atMs: 950, clock: nil, clockRecordedAtMs: nil, nowMs: 960)
        }
        let report = receiver.drain()
        XCTAssertEqual(report.presented, 3); XCTAssertEqual(report.uniqueSources, 1)
        XCTAssertEqual(report.resends, 1); XCTAssertEqual(report.missingClock, 2)
        XCTAssertNil(report.captureToPresentP50Ms)
    }
    func testStaleFutureAndNonfiniteClockMappingsRemainUnknown() {
        for (offset, uncertainty, recorded) in [(100.0, 1.0, 100.0), (100, 1, 40_001), (.infinity, 1, 39_000), (100, .nan, 39_000)] {
            let receiver = ExactVideoTimingReceiver(), value = timing()
            receiver.decoded(value, generation: generation, nonce: nonce, atMs: 39_900)
            receiver.presented(value, generation: generation, nonce: nonce, atMs: 39_950,
                clock: ClockSyncEstimate(offsetMs: offset, uncertaintyMs: uncertainty, samples: 1), clockRecordedAtMs: recorded, nowMs: 40_000)
            let report = receiver.drain(); XCTAssertEqual(report.timed, 0); XCTAssertEqual(report.missingClock, 1)
        }
    }
    func testResetAndMismatchedPayloadCannotCompleteOldMeasurements() {
        let receiver = ExactVideoTimingReceiver(), value = timing()
        receiver.decoded(value, generation: generation, nonce: nonce, atMs: 930)
        receiver.reset()
        receiver.presented(value, generation: generation, nonce: nonce, atMs: 950, clock: nil, clockRecordedAtMs: nil, nowMs: 960)
        XCTAssertEqual(receiver.drain().presented, 0)
        receiver.decoded(value, generation: generation, nonce: nonce, atMs: 930)
        var different = value; different.encodedMs += 1
        receiver.presented(different, generation: generation, nonce: nonce, atMs: 950, clock: nil, clockRecordedAtMs: nil, nowMs: 960)
        XCTAssertEqual(receiver.drain().presented, 0)
    }
    func testMalformedStagesAndIDsNeverEnterTimingLog() {
        var value = timing(); value.submittedMs = 999
        XCTAssertThrowsError(try value.validate())
        value = timing(); value.encodedMs = .nan
        let receiver = ExactVideoTimingReceiver()
        receiver.decoded(value, generation: generation, nonce: nonce, atMs: 930)
        receiver.decoded(timing(), generation: "bad", nonce: nonce, atMs: 930)
        XCTAssertEqual(receiver.drain().decoded, 0)
    }
}
