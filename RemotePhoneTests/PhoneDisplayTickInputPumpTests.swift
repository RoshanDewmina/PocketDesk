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
    func testActualModelAnchorCancelsPendingMotionAndHoldBeforeGeometryArrives() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.prepareConnection(mode: .couch)
        model.connection.startInputFixtureForTesting(session: "phone-geometry")
        defer { model.connection.stop() }
        var outgoing: [ControlPacket] = []
        model.connection.inputPacketSenderForTesting = { outgoing.append($0); return true }
        func deliver(_ action: RemoteAction) throws { model.connection.onControl?(try JSONEncoder().encode(action)) }
        try deliver(RemoteAction(action: "geometry", x: 200, y: 200, epoch: 7))
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 7))
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 7,
            interaction: NativeInteraction(token: "t", doubleClickInterval: 0.5),
            features: SessionFeature.host + [SessionFeature.couch], mode: "couch"))
        let offer = try XCTUnwrap(outgoing.first { $0.input?.kind == "offer" })
        var context = try XCTUnwrap(offer.input)
        context.kind = "accept"; context.anchor = String(repeating: "a", count: 32)
        try model.connection.receiveInputFixtureForTesting(ControlPacket(session: "phone-geometry", sequence: 1,
            action: RemoteAction(action: "heartbeat", epoch: 7), input: context))
        XCTAssertTrue(model.canControl)
        model.drag(); XCTAssertTrue(model.dragging)
        XCTAssertTrue(model.gesture(.move(CGSize(width: 5, height: 0))))
        let before = outgoing.count
        context.kind = "anchor"; context.anchor = String(repeating: "b", count: 32); context.epoch = 8
        try model.connection.receiveInputFixtureForTesting(ControlPacket(session: "phone-geometry", sequence: 2,
            action: RemoteAction(action: "heartbeat", epoch: 8), input: context))
        XCTAssertFalse(model.dragging); XCTAssertFalse(model.canControl)
        // A semantic flush cannot emit the old tick or pair an old release with epoch8.
        model.key("a"); model.release(); XCTAssertEqual(outgoing.count, before)
        try deliver(RemoteAction(action: "geometry", x: 300, y: 300, epoch: 8))
        XCTAssertEqual(model.sourceSize, CGSize(width: 300, height: 300))
        XCTAssertTrue(model.connection.connected); XCTAssertEqual(outgoing.count, before)
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
