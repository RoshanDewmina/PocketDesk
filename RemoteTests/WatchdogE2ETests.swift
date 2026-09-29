#if DEBUG && os(macOS)
import Darwin
import XCTest

/// The E2E watchdog tells E2E host instances from the owner's host by their launch arguments.
final class WatchdogE2ETests: XCTestCase {
    func testOrdinaryProcessIsNotInE2EMode() {
        XCTAssertNil(WatchdogE2E.configuration)
        XCTAssertFalse(WatchdogE2E.isE2EInstance(pid: getpid()))
    }

    func testReadsAnotherProcessesArguments() {
        XCTAssertEqual(WatchdogE2E.arguments(of: getpid()), CommandLine.arguments)
        XCTAssertEqual(WatchdogE2E.arguments(of: 999_999), [])
    }

    func testRecognisesAnE2EInstanceByItsArguments() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `; :` keeps the shell from exec-ing sleep in its place, so its own argv stays visible.
        process.arguments = ["-c", "sleep 5; :", "--farside-e2e"]
        try process.run()
        defer { process.terminate() }
        XCTAssertEqual(WatchdogE2E.arguments(of: process.processIdentifier), ["/bin/sh", "-c", "sleep 5; :", "--farside-e2e"])
        XCTAssertTrue(WatchdogE2E.isE2EInstance(pid: process.processIdentifier))
    }
}
#endif
