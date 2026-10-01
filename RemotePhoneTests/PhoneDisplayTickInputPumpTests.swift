import XCTest
import QuartzCore
@testable import PocketDeskRemote

@MainActor
final class PhoneDisplayTickInputPumpTests: XCTestCase {
    func testBuiltPhoneEnablesDisplayLinkFrameRateHints() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool, true)
    }

    func testLeadingMotionSendsImmediatelyAndFollowingTicksPreservePath() {
        let pump = PhoneDisplayTickInputPump(automaticTicks: false, configuration: configuration())
        var batches: [[Double]] = []
        pump.send = { batches.append($0.map(\.x)); return true }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 500)))
        XCTAssertEqual(batches, [[500]])
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: -80)))
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: -2)))
        XCTAssertEqual(batches, [[500]])
        pump.tick()
        XCTAssertEqual(batches, [[500], [-80, -2]])
        XCTAssertTrue(pump.offer(RemoteAction(action: "moveTo", x: 3)))
        XCTAssertEqual(batches, [[500], [-80, -2]])
        pump.tick()
        XCTAssertEqual(batches, [[500], [-80, -2], [3]])
    }

    func testSemanticFlushPreservesBarrierAndNextMotionStartsImmediately() {
        let pump = PhoneDisplayTickInputPump(automaticTicks: false, configuration: configuration())
        var sent: [String] = []
        pump.send = { sent.append(contentsOf: $0.map { "\($0.action):\($0.x)" }); return true }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1)))
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 2)))
        XCTAssertTrue(pump.flush())
        sent.append("key")
        XCTAssertTrue(pump.offer(RemoteAction(action: "moveTo", x: 3)))
        XCTAssertEqual(sent, ["move:1.0", "move:2.0", "key", "moveTo:3.0"])
        pump.tick()
        XCTAssertEqual(sent.count, 4)
    }

    func testReleaseCancelDropsQueuedMotionAndRearmsLeadingSend() {
        let pump = PhoneDisplayTickInputPump(automaticTicks: false, configuration: configuration())
        var batches: [[Double]] = []
        pump.send = { batches.append($0.map(\.x)); return true }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1)))
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 2)))
        pump.cancel()
        pump.tick()
        XCTAssertEqual(batches, [[1]])
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 3)))
        XCTAssertEqual(batches, [[1], [3]])
    }

    func testLeadingSendRefusalReturnsFalseCancelsAndReportsOnce() {
        let pump = PhoneDisplayTickInputPump(automaticTicks: false, configuration: configuration())
        var failures = 0
        var latencySamples = 0
        pump.send = { _ in false }
        pump.onFailure = { failures += 1 }
        pump.onLeadingMotionLatency = { _ in latencySamples += 1 }
        XCTAssertFalse(pump.offer(RemoteAction(action: "move", x: 1)))
        pump.tick()
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(latencySamples, 0)
    }

    func testFullBatchRefusalRejectsNewerMotionAndCannotReplayQueuedPath() {
        let pump = PhoneDisplayTickInputPump(automaticTicks: false, configuration: configuration())
        var batches: [[Double]] = []
        pump.send = { batches.append($0.map(\.x)); return batches.count == 1 }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 0)))
        for x in 1...InputCausalEnvelope.maximumSegments {
            XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: Double(x))))
        }
        XCTAssertFalse(pump.offer(RemoteAction(action: "move", x: 99)))
        pump.tick()
        XCTAssertEqual(batches, [[0], (1...InputCausalEnvelope.maximumSegments).map(Double.init)])
    }

    func testLeadingLatencyMeasuresOfferThroughSuccessfulSendOnly() {
        var now: TimeInterval = 10
        var config = configuration()
        config.now = { now }
        let pump = PhoneDisplayTickInputPump(automaticTicks: false, configuration: config)
        var latencies: [Double] = []
        pump.onLeadingMotionLatency = { latencies.append($0) }
        pump.send = { _ in now += 0.002; return true }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1)))
        XCTAssertEqual(latencies.count, 1)
        XCTAssertEqual(latencies[0], 2, accuracy: 0.0001)
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 2)))
        pump.tick()
        XCTAssertEqual(latencies.count, 1)
    }

    func testMaximumFrameRateRetainedLinkAndIdleLeadingRestart() throws {
        var now: TimeInterval = 10
        var config = configuration()
        config.now = { now }
        config.maximumFramesPerSecond = { 120 }
        var links: [FakePhoneDisplayTickLink] = []
        var ranges: [CAFrameRateRange?] = []
        config.displayLinkFactory = { range, tick in
            ranges.append(range)
            let link = FakePhoneDisplayTickLink(onTick: tick)
            links.append(link)
            return link
        }
        let pump = PhoneDisplayTickInputPump(configuration: config)
        var batches: [[Double]] = []
        pump.send = { batches.append($0.map(\.x)); return true }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1)))
        let range = try XCTUnwrap(ranges[0])
        XCTAssertEqual(range.minimum, 60)
        XCTAssertEqual(range.maximum, 120)
        XCTAssertEqual(range.preferred, 120)
        now += 0.149
        links[0].fire()
        XCTAssertEqual(links[0].invalidationCount, 0)
        now += 0.002
        links[0].fire()
        XCTAssertEqual(links[0].invalidationCount, 1)
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 2)))
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(batches, [[1], [2]])
    }

    func testCancelInvalidatesSynchronouslyAndOldLinkCannotFlushNewBurst() {
        var config = configuration()
        var links: [FakePhoneDisplayTickLink] = []
        config.displayLinkFactory = { _, tick in
            let link = FakePhoneDisplayTickLink(onTick: tick)
            links.append(link)
            return link
        }
        let pump = PhoneDisplayTickInputPump(configuration: config)
        var batches: [[Double]] = []
        pump.send = { batches.append($0.map(\.x)); return true }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1)))
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 2)))
        pump.cancel()
        XCTAssertEqual(links[0].invalidationCount, 1)
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 3)))
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 4)))
        links[0].fire()
        XCTAssertEqual(batches, [[1], [3]])
        links[1].fire()
        XCTAssertEqual(batches, [[1], [3], [4]])
    }

    func testDisplayIntervalsUseCallbackArrivalClockAndExcludeLinkRestarts() {
        var now: TimeInterval = 10
        var config = configuration()
        config.now = { now }
        var links: [FakePhoneDisplayTickLink] = []
        config.displayLinkFactory = { _, tick in
            let link = FakePhoneDisplayTickLink(onTick: tick)
            links.append(link)
            return link
        }
        let pump = PhoneDisplayTickInputPump(configuration: config)
        pump.send = { _ in true }
        var intervals: [Double] = []
        pump.onDisplayInterval = { intervals.append($0) }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1)))
        now += 0.005; links[0].fire()
        now += 0.009; links[0].fire()
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0], 9, accuracy: 0.0001)
        pump.cancel()
        now += 10
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 2)))
        links[0].fire(); links[1].fire()
        XCTAssertEqual(intervals.count, 1)
    }

    func testFailedBatchedSendInvalidatesLinkAndReportsOnce() {
        var config = configuration()
        var link: FakePhoneDisplayTickLink?
        config.displayLinkFactory = { _, tick in
            let created = FakePhoneDisplayTickLink(onTick: tick)
            link = created
            return created
        }
        let pump = PhoneDisplayTickInputPump(configuration: config)
        var accepted = true
        var failures = 0
        pump.send = { _ in accepted }
        pump.onFailure = { failures += 1 }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1)))
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 2)))
        accepted = false
        link?.fire(); link?.fire()
        XCTAssertEqual(link?.invalidationCount, 1)
        XCTAssertEqual(failures, 1)
    }

    func testCadenceKillSwitchRestoresUnrangedImmediateLinkInvalidation() {
        var config = configuration(leading: false)
        config.userDefaults.set(false, forKey: PhoneDisplayTickInputPump.optimizationDefaultsKey)
        var range: CAFrameRateRange?
        var link: FakePhoneDisplayTickLink?
        config.displayLinkFactory = { requestedRange, tick in
            range = requestedRange
            let created = FakePhoneDisplayTickLink(onTick: tick)
            link = created
            return created
        }
        let pump = PhoneDisplayTickInputPump(configuration: config)
        var sends = 0
        pump.send = { _ in sends += 1; return true }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1)))
        XCTAssertEqual(sends, 0)
        XCTAssertNil(range)
        link?.fire()
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(link?.invalidationCount, 1)
    }

    func testDisplayTickPreservesRelativePathAndSemanticFlushIsImmediate() {
        let pump = PhoneDisplayTickInputPump(automaticTicks: false, configuration: configuration(leading: false))
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
        let pump = PhoneDisplayTickInputPump(automaticTicks: false, configuration: configuration())
        var sizes: [Int] = []
        pump.send = { sizes.append($0.count); return true }
        for _ in 0..<26 { XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1))) }
        XCTAssertEqual(sizes, [1, 24])
        pump.cancel(); pump.tick(); XCTAssertEqual(sizes, [1, 24])
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
        XCTAssertTrue(model.gesture(.move(CGSize(width: 2, height: 0))))
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
        let pump = PhoneDisplayTickInputPump(automaticTicks: false, configuration: configuration(leading: false))
        var failures = 0
        pump.send = { _ in false }; pump.onFailure = { failures += 1 }
        pump.offer(RemoteAction(action: "move", x: 1)); XCTAssertFalse(pump.flush())
        pump.tick(); XCTAssertEqual(failures, 1)
        XCTAssertFalse(pump.offer(RemoteAction(action: "key", key: "a")))
    }

    private func configuration(leading: Bool = true) -> PhoneDisplayTickInputPump.Configuration {
        let suite = "PhoneDisplayTickInputPumpTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(leading, forKey: PhoneDisplayTickInputPump.leadingMotionDefaultsKey)
        defaults.set(true, forKey: PhoneDisplayTickInputPump.optimizationDefaultsKey)
        var configuration = PhoneDisplayTickInputPump.Configuration(userDefaults: defaults)
        configuration.now = { 10 }
        return configuration
    }
}

@MainActor
private final class FakePhoneDisplayTickLink: PhoneDisplayTickLink {
    private let onTick: () -> Void
    private(set) var invalidationCount = 0
    init(onTick: @escaping () -> Void) { self.onTick = onTick }
    func fire() { onTick() }
    func invalidate() { invalidationCount += 1 }
}
