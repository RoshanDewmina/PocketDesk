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
    func testSignalRouteCleansUpBeforeRequestingTermination() {
        var events: [String] = []
        let lifecycle = HostTerminationLifecycle { events.append("cleanup") }

        lifecycle.requestTermination { events.append("terminate") }
        lifecycle.applicationWillTerminate()
        lifecycle.requestTermination { events.append("duplicate terminate") }

        XCTAssertEqual(events, ["cleanup", "terminate"])
    }
}
