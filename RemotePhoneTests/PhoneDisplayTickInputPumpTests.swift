import XCTest
import QuartzCore
@testable import PocketDeskRemote

@MainActor
final class PhoneDisplayTickInputPumpTests: XCTestCase {
    func testBuiltPhoneEnablesDisplayLinkFrameRateHints() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool, true)
    }
    func testActivePumpRequests60HzWithDisplayMaximumAndRetainsLinkForIdleWindow() {
        var now: TimeInterval = 10
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: PhoneDisplayTickInputPump.optimizationDefaultsKey)
        var createdLinks: [FakePhoneDisplayTickLink] = []
        var requestedRanges: [CAFrameRateRange?] = []
        var configuration = PhoneDisplayTickInputPump.Configuration(userDefaults: defaults)
        configuration.now = { now }
        configuration.maximumFramesPerSecond = { 120 }
        configuration.displayLinkFactory = { range, tick in
            requestedRanges.append(range)
            let link = FakePhoneDisplayTickLink(onTick: tick)
            createdLinks.append(link)
            return link
        }
        let pump = PhoneDisplayTickInputPump(configuration: configuration)
        pump.send = { _ in true }

        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1)))
        let link = createdLinks[0]
        let range = try! XCTUnwrap(requestedRanges[0])
        XCTAssertEqual(range.minimum, 60)
        XCTAssertEqual(range.preferred, 60)
        XCTAssertEqual(range.maximum, 120)

        now += 0.149
        link.fire()
        XCTAssertEqual(createdLinks.count, 1)
        XCTAssertEqual(link.invalidationCount, 0)

        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 2)))
        link.fire()
        now += 0.149
        link.fire()
        XCTAssertEqual(createdLinks.count, 1)
        XCTAssertEqual(link.invalidationCount, 0)

        now += 0.0011
        link.fire()
        XCTAssertEqual(link.invalidationCount, 1)
    }

    func testCancelInvalidatesRetainedLinkSynchronouslyAndDropsPendingMotion() {
        var now: TimeInterval = 0
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: PhoneDisplayTickInputPump.optimizationDefaultsKey)
        var links: [FakePhoneDisplayTickLink] = []
        var configuration = PhoneDisplayTickInputPump.Configuration(userDefaults: defaults)
        configuration.now = { now }
        configuration.maximumFramesPerSecond = { 120 }
        configuration.displayLinkFactory = { _, tick in
            let link = FakePhoneDisplayTickLink(onTick: tick)
            links.append(link)
            return link
        }
        let pump = PhoneDisplayTickInputPump(configuration: configuration)
        var sends = 0
        pump.send = { _ in sends += 1; return true }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1)))

        pump.cancel()

        XCTAssertEqual(links[0].invalidationCount, 1)
        now = 1
        links[0].fire()
        XCTAssertEqual(sends, 0)
    }

    func testFailedTickInvalidatesLinkAndReportsFailureSynchronously() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: PhoneDisplayTickInputPump.optimizationDefaultsKey)
        var link: FakePhoneDisplayTickLink?
        var configuration = PhoneDisplayTickInputPump.Configuration(userDefaults: defaults)
        configuration.maximumFramesPerSecond = { 120 }
        configuration.displayLinkFactory = { _, tick in
            let created = FakePhoneDisplayTickLink(onTick: tick)
            link = created
            return created
        }
        let pump = PhoneDisplayTickInputPump(configuration: configuration)
        pump.send = { _ in false }
        var failures = 0
        pump.onFailure = { failures += 1 }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1)))

        link?.fire()

        XCTAssertEqual(link?.invalidationCount, 1)
        XCTAssertEqual(failures, 1)
    }

    func testDefaultsKillSwitchRestoresLegacyUnrangedImmediateInvalidation() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: PhoneDisplayTickInputPump.optimizationDefaultsKey)
        var requestedRanges: [CAFrameRateRange?] = []
        var link: FakePhoneDisplayTickLink?
        var configuration = PhoneDisplayTickInputPump.Configuration(userDefaults: defaults)
        configuration.maximumFramesPerSecond = { 120 }
        configuration.displayLinkFactory = { range, tick in
            requestedRanges.append(range)
            let created = FakePhoneDisplayTickLink(onTick: tick)
            link = created
            return created
        }
        let pump = PhoneDisplayTickInputPump(configuration: configuration)
        pump.send = { _ in true }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1)))

        link?.fire()

        XCTAssertEqual(requestedRanges.count, 1)
        XCTAssertNil(requestedRanges[0])
        XCTAssertEqual(link?.invalidationCount, 1)
    }

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

    private func isolatedDefaults() -> UserDefaults {
        let suite = "PhoneDisplayTickInputPumpTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
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
