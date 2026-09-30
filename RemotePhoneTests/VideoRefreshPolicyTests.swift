import XCTest
@testable import PocketDeskRemote

/// Efficiency audit P2: idle 30 Hz while the Mac picture is static, full rate at once on activity.
final class VideoRefreshPolicyTests: XCTestCase {
    func testQuietViewDropsToThirtyAndANewFrameRaisesAndDrawsAtOnce() {
        var policy = VideoRefreshPolicy(activeFramesPerSecond: 120, now: 0)
        policy.drew(at: 0.1, framePending: false)
        XCTAssertEqual(policy.framesPerSecond, 120, "not quiet long enough")
        policy.drew(at: VideoRefreshPolicy.idleAfter, framePending: false)
        XCTAssertTrue(policy.idle)
        XCTAssertEqual(policy.framesPerSecond, VideoRefreshPolicy.idleFramesPerSecond)
        XCTAssertEqual(policy.signal(at: 1, newFrame: true), .raiseAndDraw)
        XCTAssertEqual(policy.framesPerSecond, 120)
        XCTAssertEqual(policy.signal(at: 1.01, newFrame: true), .none, "already at full rate")
    }

    func testTouchRaisesWithoutAForcedDrawAndPendingFramesKeepItActive() {
        var policy = VideoRefreshPolicy(activeFramesPerSecond: 120, now: 0)
        policy.drew(at: 1, framePending: false)
        XCTAssertTrue(policy.idle)
        XCTAssertEqual(policy.signal(at: 2, newFrame: false), .raise)
        policy.drew(at: 2.2, framePending: false)
        XCTAssertFalse(policy.idle, "a touch restarts the quiet period")
        policy.drew(at: 3, framePending: true)
        policy.drew(at: 3.1, framePending: false)
        XCTAssertFalse(policy.idle, "a frame waiting at the last draw counts as activity")
        policy.drew(at: 3 + VideoRefreshPolicy.idleAfter, framePending: false)
        XCTAssertTrue(policy.idle)
    }

    func testIdleRateNeverExceedsTheActiveRate() {
        var policy = VideoRefreshPolicy(activeFramesPerSecond: 24, now: 0)
        policy.drew(at: 5, framePending: false)
        XCTAssertEqual(policy.framesPerSecond, 24)
    }
}
