import XCTest
@testable import PocketDeskRemote

@MainActor
final class PhoneDisplayTickInputPumpTests: XCTestCase {
    func testDisplayTickPreservesRelativePathAndSemanticFlushIsImmediate() {
        let pump = PhoneDisplayTickInputPump(automaticTicks: false)
        var batches: [[Double]] = []
        pump.send = { batches.append($0.map(\.x)); return true }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 500)))
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: -80)))
        XCTAssertTrue(batches.isEmpty)
        pump.tick(); XCTAssertEqual(batches, [[500, -80]])
        pump.offer(RemoteAction(action: "move", x: 3)); XCTAssertTrue(pump.flush())
        XCTAssertEqual(batches, [[500, -80], [3]])
    }
    func testReleaseAndBackgroundCancelUnsentMotionAndBoundAcceptedBatch() {
        let pump = PhoneDisplayTickInputPump(automaticTicks: false)
        var sizes: [Int] = []
        pump.send = { sizes.append($0.count); return true }
        for _ in 0..<25 { XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1))) }
        XCTAssertEqual(sizes, [24])
        pump.cancel(); pump.tick(); XCTAssertEqual(sizes, [24])
    }
    func testSendRefusalClearsPendingAndReportsOnce() {
        let pump = PhoneDisplayTickInputPump(automaticTicks: false)
        var failures = 0
        pump.send = { _ in false }; pump.onFailure = { failures += 1 }
        pump.offer(RemoteAction(action: "move", x: 1)); XCTAssertFalse(pump.flush())
        pump.tick(); XCTAssertEqual(failures, 1)
        XCTAssertFalse(pump.offer(RemoteAction(action: "key", key: "a")))
    }
}
