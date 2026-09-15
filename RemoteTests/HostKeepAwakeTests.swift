import XCTest

final class HostKeepAwakeTests: XCTestCase {
    func testAssertionIsAcquiredOnceAndReleasedOnStop() {
        var acquireCount = 0
        var released: [UInt32] = []
        let keepAwake = HostKeepAwake(backend: HostKeepAwakeBackend(
            acquire: {
                acquireCount += 1
                return 42
            },
            release: {
                released.append($0)
                return true
            }
        ))

        XCTAssertTrue(keepAwake.start())
        XCTAssertTrue(keepAwake.start())
        XCTAssertTrue(keepAwake.isActive)
        XCTAssertEqual(acquireCount, 1)

        XCTAssertTrue(keepAwake.stop())
        XCTAssertFalse(keepAwake.isActive)
        XCTAssertEqual(released, [42])
    }

    func testFailedAcquisitionNeverReportsActive() {
        let keepAwake = HostKeepAwake(backend: HostKeepAwakeBackend(
            acquire: { nil },
            release: { _ in XCTFail("No assertion should be released"); return false }
        ))

        XCTAssertFalse(keepAwake.start())
        XCTAssertFalse(keepAwake.isActive)
        XCTAssertTrue(keepAwake.stop())
    }

    func testReleaseIsRetriedAndRemainsVisibleAfterFailure() {
        var releaseCount = 0
        let keepAwake = HostKeepAwake(backend: HostKeepAwakeBackend(
            acquire: { 7 },
            release: { _ in
                releaseCount += 1
                return false
            }
        ))

        XCTAssertTrue(keepAwake.start())
        XCTAssertFalse(keepAwake.stop())
        XCTAssertTrue(keepAwake.isActive)
        XCTAssertEqual(releaseCount, 3)
    }

    func testOnlyLiveOrRecoveringCoordinatorStateKeepsAccessActive() {
        XCTAssertTrue(HostActiveAccessPolicy.isRunning(
            status: "Connection interrupted · retrying…",
            hostRegistered: false,
            connected: false,
            awaitingApproval: false
        ))
        XCTAssertTrue(HostActiveAccessPolicy.isRunning(
            status: "Ready for your paired phone",
            hostRegistered: true,
            connected: false,
            awaitingApproval: false
        ))
        XCTAssertFalse(HostActiveAccessPolicy.isRunning(
            status: "Connection timed out. Check that the Mac is awake and the service is reachable.",
            hostRegistered: false,
            connected: false,
            awaitingApproval: false
        ))
    }
}
