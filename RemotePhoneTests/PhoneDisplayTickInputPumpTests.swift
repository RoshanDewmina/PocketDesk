import XCTest
import QuartzCore
@testable import PocketDeskRemote

@MainActor
final class PhoneDisplayTickInputPumpTests: XCTestCase {
    func testSynthetic120HzOffersCompare60And120HzRequestedTicks() throws {
        func run(couch: Bool) throws -> (waitP50: Double, waitP90: Double, gapP50: Double, gapP90: Double) {
            var now: TimeInterval = 10
            var config = configuration()
            config.now = { now }
            config.maximumFramesPerSecond = { 120 }
            var requested: CAFrameRateRange?
            var link: FakePhoneDisplayTickLink?
            config.displayLinkFactory = { range, tick in
                requested = range
                let created = FakePhoneDisplayTickLink(onTick: tick)
                link = created
                return created
            }
            let pump = PhoneDisplayTickInputPump(configuration: config)
            var waits: [Double] = [], sends: [TimeInterval] = []
            pump.send = { actions in
                sends.append(now)
                for action in actions { waits.append((now - (10 + action.x / 120)) * 1_000) }
                return true
            }
            XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 0), preferDisplayMaximum: couch))
            let preferred = try XCTUnwrap(try XCTUnwrap(requested).preferred)
            let tickStride = Int(120 / preferred)
            for sample in 1...120 {
                now = 10 + Double(sample) / 120
                XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: Double(sample)), preferDisplayMaximum: couch))
                if sample.isMultiple(of: tickStride) { link?.fire() }
            }
            XCTAssertEqual(waits.count, 121)
            func percentile(_ values: [Double], _ fraction: Double) -> Double {
                let sorted = values.sorted()
                return sorted[Int(ceil(Double(sorted.count) * fraction)) - 1]
            }
            let gapError = zip(sends.dropFirst(), sends).map { pair in
                abs((pair.0 - pair.1) * 1_000 - 1_000 / 120)
            }
            return (percentile(waits, 0.5), percentile(waits, 0.9),
                    percentile(gapError, 0.5), percentile(gapError, 0.9))
        }
        // The injected link honors the preference exactly. This is synthetic queue evidence;
        // real CADisplayLink callback cadence is a separate device acceptance gate.
        let old = try run(couch: false), new = try run(couch: true)
        XCTAssertEqual(old.waitP50, 0, accuracy: 0.001)
        XCTAssertEqual(old.waitP90, 1_000 / 120, accuracy: 0.001)
        XCTAssertEqual(new.waitP50, 0, accuracy: 0.001)
        XCTAssertEqual(new.waitP90, 0, accuracy: 0.001)
        XCTAssertEqual(old.gapP50, 1_000 / 120, accuracy: 0.001)
        XCTAssertEqual(old.gapP90, 1_000 / 120, accuracy: 0.001)
        XCTAssertEqual(new.gapP50, 0, accuracy: 0.001)
        XCTAssertEqual(new.gapP90, 0, accuracy: 0.001)
        print("SYNTHETIC Couch 120Hz offers: 60Hz ticks wait p50/p90=\(old.waitP50)/\(old.waitP90)ms gap-error p50/p90=\(old.gapP50)/\(old.gapP90)ms; 120Hz ticks wait p50/p90=\(new.waitP50)/\(new.waitP90)ms gap-error p50/p90=\(new.gapP50)/\(new.gapP90)ms")
    }

    func testCouchPrefersDisplayMaximumAndPictureKeeps60Hz() throws {
        var config = configuration()
        config.maximumFramesPerSecond = { 120 }
        var ranges: [CAFrameRateRange?] = []
        var links: [FakePhoneDisplayTickLink] = []
        config.displayLinkFactory = { range, tick in
            ranges.append(range)
            let link = FakePhoneDisplayTickLink(onTick: tick)
            links.append(link)
            return link
        }
        let pump = PhoneDisplayTickInputPump(configuration: config)
        var batches: [[Double]] = []
        pump.send = { batches.append($0.map(\.x)); return true }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1), preferDisplayMaximum: true))
        XCTAssertEqual(try XCTUnwrap(ranges[0]).preferred, 120)
        XCTAssertEqual(try XCTUnwrap(ranges[0]).minimum, 60)
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 2), preferDisplayMaximum: true))
        // Recreate the link when the mode changes; pending motion remains ordered.
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 3)))
        XCTAssertEqual(links[0].invalidationCount, 1)
        XCTAssertEqual(try XCTUnwrap(ranges[1]).preferred, 60)
        links[0].fire()
        XCTAssertEqual(batches, [[1]])
        links[1].fire()
        XCTAssertEqual(batches, [[1], [2, 3]])
    }

    func testCouchCadenceUses60HzFallbackAndHonorsRollback() throws {
        for optimized in [true, false] {
            var config = configuration()
            config.maximumFramesPerSecond = { 60 }
            config.userDefaults.set(optimized, forKey: PhoneDisplayTickInputPump.optimizationDefaultsKey)
            var ranges: [CAFrameRateRange?] = []
            config.displayLinkFactory = { range, tick in
                ranges.append(range)
                return FakePhoneDisplayTickLink(onTick: tick)
            }
            let pump = PhoneDisplayTickInputPump(configuration: config)
            pump.send = { _ in true }
            XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1), preferDisplayMaximum: true))
            if optimized { XCTAssertEqual(try XCTUnwrap(ranges[0]).preferred, 60) }
            else { XCTAssertNil(ranges[0]) }
        }
        var config = configuration()
        config.maximumFramesPerSecond = { 120 }
        config.userDefaults.set(true, forKey: PhoneDisplayTickInputPump.couchMaximumCadenceDisabledKey)
        var range: CAFrameRateRange?
        config.displayLinkFactory = { requested, tick in
            range = requested
            return FakePhoneDisplayTickLink(onTick: tick)
        }
        let pump = PhoneDisplayTickInputPump(configuration: config)
        pump.send = { _ in true }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1), preferDisplayMaximum: true))
        let requested = try XCTUnwrap(range)
        XCTAssertEqual(requested.preferred, 60, "Couch rollback retains the prior60Hz hint and link retention")
        XCTAssertEqual(requested.maximum, 120)
        XCTAssertEqual(requested.minimum, 60)
    }

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

    func test60HzPreferenceWithDisplayMaximumRetainedLinkAndIdleLeadingRestart() throws {
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
        XCTAssertEqual(range.preferred, 60)
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

    func testActivePumpRequests60HzWithDisplayMaximumAndRetainsLinkForIdleWindow() {
        var now: TimeInterval = 10
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: PhoneDisplayTickInputPump.leadingMotionDefaultsKey)
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
        var batches: [[Double]] = []
        pump.send = { batches.append($0.map(\.x)); return true }

        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1)))
        XCTAssertTrue(batches.isEmpty)
        let link = createdLinks[0]
        let range = try! XCTUnwrap(requestedRanges[0])
        XCTAssertEqual(range.minimum, 60)
        XCTAssertEqual(range.preferred, 60)
        XCTAssertEqual(range.maximum, 120)

        now += 0.149
        link.fire()
        XCTAssertEqual(batches, [[1]])
        XCTAssertEqual(createdLinks.count, 1)
        XCTAssertEqual(link.invalidationCount, 0)

        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 2)))
        XCTAssertEqual(batches, [[1]])
        link.fire()
        XCTAssertEqual(batches, [[1], [2]])
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
        defaults.set(false, forKey: PhoneDisplayTickInputPump.leadingMotionDefaultsKey)
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
        defaults.set(false, forKey: PhoneDisplayTickInputPump.leadingMotionDefaultsKey)
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
        var batches: [[Double]] = []
        pump.send = { batches.append($0.map(\.x)); return true }
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 1)))
        XCTAssertEqual(batches, [[1]])
        XCTAssertTrue(pump.offer(RemoteAction(action: "move", x: 2)))
        XCTAssertEqual(batches, [[1]])

        link?.fire()

        XCTAssertEqual(batches, [[1], [2]])
        XCTAssertEqual(requestedRanges.count, 1)
        XCTAssertNil(requestedRanges[0])
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
        XCTAssertTrue(model.connection.connected)
        // Retiring presentation sends Listen-off while geometry's willSet still has epoch7;
        // subsequent retirement can use epoch8. Neither heartbeat may contain causal input.
        XCTAssertTrue(outgoing.dropFirst(before).allSatisfy {
            $0.action.action == "heartbeat" && [UInt64(7), 8].contains($0.action.epoch) &&
                $0.action.macAudioRequested == false && $0.input == nil
        }, "Only Listen-off metadata may follow geometry; no old move, key or release: \(outgoing.dropFirst(before))")
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
        let defaults = isolatedDefaults()
        defaults.set(leading, forKey: PhoneDisplayTickInputPump.leadingMotionDefaultsKey)
        defaults.set(true, forKey: PhoneDisplayTickInputPump.optimizationDefaultsKey)
        var configuration = PhoneDisplayTickInputPump.Configuration(userDefaults: defaults)
        configuration.now = { 10 }
        return configuration
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

@MainActor
final class HardwareKeyboardRechordPhoneTests: XCTestCase {
    private var sent: [(String, [String])] = []

    func testPhysicalModifierPressAndReleaseRechordTheStillHeldArrow() {
        var now: TimeInterval = 0
        let router = makeRouter(rechordEnabled: true, now: { now })
        XCTAssertTrue(router.pressBegan(usage: 0x4F, flags: [], at: now))
        XCTAssertTrue(router.pressBegan(usage: 0xE1, flags: .shift, at: 0.2))
        now = 0.5; router.fireRepeat(at: now)
        XCTAssertEqual(sent.count, 2); XCTAssertEqual(sent.last?.1, ["shift"])
        XCTAssertTrue(router.pressBegan(usage: 0xE2, flags: [.shift, .alternate], at: 0.55))
        now = 0.571; router.fireRepeat(at: now)
        XCTAssertEqual(sent.count, 3); XCTAssertEqual(sent.last?.1, ["shift", "option"])
        XCTAssertTrue(router.pressEnded(usage: 0xE1, flags: .alternate))
        now = 0.642; router.fireRepeat(at: now)
        XCTAssertEqual(sent.count, 4); XCTAssertEqual(sent.last?.1, ["option"])
        XCTAssertTrue(router.pressEnded(usage: 0xE2, flags: []))
        now = 0.713; router.fireRepeat(at: now)
        XCTAssertEqual(sent.count, 5); XCTAssertEqual(sent.last?.1, [])
        XCTAssertTrue(router.pressEnded(usage: 0x4F, flags: []))
        now = 1; router.fireRepeat(at: now)
        XCTAssertEqual(sent.count, 5)
    }

    func testCapsOnlyTransitionWithRollbackKeepsTheOriginalLetterChord() {
        var now: TimeInterval = 0
        let router = makeRouter(rechordEnabled: false, now: { now })
        XCTAssertTrue(router.pressBegan(usage: 0x04, flags: [], at: now))
        router.updateModifiers(.alphaShift)
        now = 0.5; router.fireRepeat(at: now)
        XCTAssertEqual(sent.count, 2); XCTAssertEqual(sent.last?.1, [])
        router.releaseAll()
    }

    func testRemovingShortcutStandInRecomputesThePhysicalKeyChord() {
        var now: TimeInterval = 0
        let router = makeRouter(rechordEnabled: true, now: { now })
        XCTAssertTrue(router.pressBegan(usage: 0x0B, flags: [.control, .alternate], at: now))
        XCTAssertEqual(sent.first?.0, "h"); XCTAssertEqual(sent.first?.1, ["command"])
        now = 0.6; router.fireRepeat(at: now)
        XCTAssertEqual(sent.count, 1)
        router.updateModifiers([]); router.fireRepeat(at: now)
        XCTAssertEqual(sent.count, 2); XCTAssertEqual(sent.last?.0, "h"); XCTAssertEqual(sent.last?.1, [])
        router.releaseAll()
    }

    func testCapsChangesRechordLettersButDoNotChangeArrowRepeat() {
        var now: TimeInterval = 0
        let router = makeRouter(rechordEnabled: true, now: { now })

        _ = router.pressBegan(usage: 0x4F, flags: [], at: now)
        router.updateModifiers(.alphaShift)
        now = 0.5
        router.fireRepeat(at: now)
        XCTAssertEqual(sent.count, 2, "The held arrow produces a repeat after Caps Lock changes")
        XCTAssertEqual(sent.last?.0, "right")
        XCTAssertEqual(sent.last?.1 ?? ["missing"], [], "Caps Lock does not affect arrow keys")

        _ = router.pressEnded(usage: 0x4F, flags: .alphaShift)
        now = 1
        _ = router.pressBegan(usage: 0x04, flags: [], at: now)
        router.updateModifiers(.alphaShift)
        now = 1.5
        router.fireRepeat(at: now)
        XCTAssertEqual(sent.count, 4, "The held letter produces a repeat after Caps Lock changes")
        XCTAssertEqual(sent.last?.0, "a")
        XCTAssertEqual(sent.last?.1, ["shift"], "Turning Caps Lock on adds a derived Shift to a held letter")
        router.updateModifiers([])
        now = 1.571
        router.fireRepeat(at: now)
        XCTAssertEqual(sent.count, 5, "The held letter keeps repeating after Caps Lock is removed")
        XCTAssertEqual(sent.last?.1 ?? ["missing"], [], "Turning Caps Lock off removes the derived Shift from a held letter")
        XCTAssertTrue(router.pressEnded(usage: 0x04, flags: []))
    }

    func testCommandAndControlSuppressRepeatAndModifierReleaseResumesIt() {
        var now: TimeInterval = 0
        let router = makeRouter(rechordEnabled: true, now: { now })
        _ = router.pressBegan(usage: 0x4F, flags: .command, at: now)

        now = 0.6
        router.updateModifiers(.control)
        router.fireRepeat(at: now)
        XCTAssertEqual(sent.count, 1, "Control chords remain suppressed")

        router.updateModifiers(.shift)
        router.fireRepeat(at: now)
        XCTAssertEqual(sent.last?.0, "right")
        XCTAssertEqual(sent.last?.1, ["shift"], "Releasing Command and Control resumes the still-held key")

        router.releaseAll()
        router.updateModifiers(.shift)
        now = 2
        router.fireRepeat(at: now)
        XCTAssertEqual(sent.count, 2, "Cleanup cancels the physical held-key record")
    }

    func testSwitchOffKeepsExistingCancelOnModifierChangeBehavior() {
        var now: TimeInterval = 10
        let router = makeRouter(rechordEnabled: false, now: { now })
        _ = router.pressBegan(usage: 0x4F, flags: [], at: now)

        router.updateModifiers(.shift)
        now = 11
        router.fireRepeat(at: now)
        XCTAssertEqual(sent.count, 1, "NO restores the old cancel-on-change behavior")
        XCTAssertEqual(sent.first?.0, "right")
        XCTAssertEqual(sent.first?.1 ?? ["missing"], [])
    }

    private func makeRouter(rechordEnabled: Bool, now: @escaping () -> TimeInterval) -> HardwareKeyboardRouter {
        let router = HardwareKeyboardRouter(repeatRechordEnabled: rechordEnabled, now: now,
                                            schedulesRepeats: false)
        router.send = { [unowned self] key, modifiers in
            self.sent.append((key, modifiers))
            return true
        }
        return router
    }
}
