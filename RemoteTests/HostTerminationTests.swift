import XCTest

final class HostTerminationTests: XCTestCase {
    @MainActor
    func testNormalTerminationCleansUpExactlyOnce() {
        var cleanupCount = 0
        let lifecycle = HostTerminationLifecycle { cleanupCount += 1 }

        lifecycle.applicationWillTerminate()
        lifecycle.applicationWillTerminate()

        XCTAssertEqual(cleanupCount, 1)
    }

    @MainActor
    func testSignalRouteWaitsForAppKitBeforeCleaningUp() {
        var events: [String] = []
        let lifecycle = HostTerminationLifecycle { events.append("cleanup") }

        lifecycle.requestTermination { events.append("terminate") }
        XCTAssertEqual(events, ["terminate"])
        lifecycle.applicationWillTerminate()
        lifecycle.requestTermination { events.append("duplicate terminate") }

        XCTAssertEqual(events, ["terminate", "cleanup"])
    }

    @MainActor
    func testRejectedDeferredQuitResetsTheSignalLatchWithoutCleanup() {
        var cleanupCount = 0
        var requestCount = 0
        var finish: ((Bool) -> Void)?
        let lifecycle = HostTerminationLifecycle(prepare: {
            finish = $0
            return true
        }, cleanup: { cleanupCount += 1 })
        lifecycle.requestTermination { requestCount += 1 }
        var answers: [Bool] = []
        XCTAssertEqual(lifecycle.shouldTerminate { answers.append($0) }, .terminateLater)
        finish?(false)
        XCTAssertEqual(answers, [false])
        XCTAssertEqual(cleanupCount, 0)
        lifecycle.requestTermination { requestCount += 1 }
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(lifecycle.shouldTerminate { answers.append($0) }, .terminateLater)
        finish?(true)
        XCTAssertEqual(answers, [false, true])
        lifecycle.applicationWillTerminate()
        XCTAssertEqual(cleanupCount, 1)
    }

    @MainActor
    func testOrdinaryQuitRemainsImmediate() {
        let lifecycle = HostTerminationLifecycle { }
        XCTAssertEqual(lifecycle.shouldTerminate { _ in XCTFail("No deferred reply") }, .terminateNow)
    }
}
