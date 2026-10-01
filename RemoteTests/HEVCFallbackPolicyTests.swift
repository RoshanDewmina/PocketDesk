import XCTest

final class HEVCFallbackPolicyTests: XCTestCase {
    func testOneFailureFallsBackForThatSessionThenTheNextSessionRetriesHEVC() {
        var policy = HEVCFallbackPolicy()
        XCTAssertTrue(policy.permits(at: 100))
        policy.failed(at: 100)
        XCTAssertFalse(policy.permits(at: 101), "The reconnect after a failure negotiates H.264")
        XCTAssertFalse(policy.permits(at: 100 + HEVCFallbackPolicy.retryAfter - 1))
        XCTAssertTrue(policy.permits(at: 100 + HEVCFallbackPolicy.retryAfter), "A later session tries HEVC again")
    }

    func testRepeatedFailureKeepsH264ForTheLaunch() {
        var policy = HEVCFallbackPolicy()
        policy.failed(at: 100)
        policy.failed(at: 100 + HEVCFallbackPolicy.retryAfter + 5)
        XCTAssertFalse(policy.permits(at: 100 + 100 * HEVCFallbackPolicy.retryAfter),
                       "HEVC that keeps failing starts sessions on H.264 instead of tearing them down")
    }

    func testACleanHEVCSessionForgetsAnEarlierFailure() {
        var policy = HEVCFallbackPolicy()
        policy.failed(at: 100)
        let start = 100 + HEVCFallbackPolicy.retryAfter
        policy.ended(failed: false, startedAt: start, at: start + HEVCFallbackPolicy.cleanSession - 1)
        XCTAssertEqual(policy.failures, 1, "A short session proves nothing")
        policy.ended(failed: true, startedAt: start, at: start + 3600)
        XCTAssertEqual(policy.failures, 1)
        policy.ended(failed: false, startedAt: start, at: start + HEVCFallbackPolicy.cleanSession)
        XCTAssertEqual(policy, HEVCFallbackPolicy())
        policy.failed(at: start + 7200)
        XCTAssertTrue(policy.permits(at: start + 7200 + HEVCFallbackPolicy.retryAfter), "A transient failure days later is a first failure")
    }

    func testARunReportsItsFailureAndEndOnce() {
        let run = HEVCRun(at: 5)
        XCTAssertTrue(run.markFailed())
        XCTAssertFalse(run.markFailed(), "Encoder and decoder failing together count once")
        XCTAssertEqual(run.markEnded(), true)
        XCTAssertNil(run.markEnded())
        let late = HEVCRun(at: 5)
        XCTAssertEqual(late.markEnded(), false)
        XCTAssertFalse(late.markFailed(), "A codec callback after close does not count")
    }
}
