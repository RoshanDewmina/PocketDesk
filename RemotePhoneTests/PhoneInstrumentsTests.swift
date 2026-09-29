import XCTest
@testable import PocketDeskRemote

/// The phone side of the performance instruments (Docs/perf/INSTRUMENTS-DESIGN.md): clock sync,
/// the legibility schedule and chart crop, and the negotiated-level summary.
@MainActor
final class PhoneInstrumentsTests: XCTestCase {
    private func withStreamStatistics(_ on: Bool, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: StreamDebug.defaultsKey)
        defaults.set(on, forKey: StreamDebug.defaultsKey)
        defer {
            if let saved { defaults.set(saved, forKey: StreamDebug.defaultsKey) }
            else { defaults.removeObject(forKey: StreamDebug.defaultsKey) }
        }
        try body()
    }

    private func deliver(_ action: RemoteAction, to model: PhoneRemoteModel) throws {
        model.connection.onControl?(try JSONEncoder().encode(action))
    }

    // MARK: Clock sync

    func testHeartbeatClockEchoLandsInTheStreamCounters() throws {
        try withStreamStatistics(true) {
            let model = PhoneRemoteModel(background: FakeBackgroundExecution())
            let peer = PeerMedia(isHost: false, servers: [])
            model.connection.media = peer
            defer { model.connection.media = nil; peer.close() }
            // The Mac's clock reads about 1_000_000 ms ahead; the Mac held the probe for 1 ms.
            let sent = MachClock.nowMs() - 4
            _ = model.registerClockProbe(phoneMs: sent)
            let echo = ClockProbe(phoneMs: sent, hostReceivedMs: sent + 1_000_002, hostSentMs: sent + 1_000_003)
            try deliver(RemoteAction(action: "heartbeat", epoch: 0, clock: echo), to: model)
            let snapshot = peer.counters.drain(inputBufferedBytes: nil)
            XCTAssertEqual(try XCTUnwrap(snapshot.clockOffsetMs), 1_000_000.5, accuracy: 3)
            XCTAssertEqual(snapshot.clockSamples, 1)
            XCTAssertLessThan(try XCTUnwrap(snapshot.clockUncertaintyMs), 5)

            try deliver(RemoteAction(action: "heartbeat", epoch: 0, clock: ClockProbe(phoneMs: sent)), to: model)
            XCTAssertEqual(peer.counters.drain(inputBufferedBytes: nil).clockSamples, 1, "only echoes are recorded")
            let stranger = ClockProbe(phoneMs: sent - 100, hostReceivedMs: sent + 1_000_002, hostSentMs: sent + 1_000_003)
            try deliver(RemoteAction(action: "heartbeat", epoch: 0, clock: stranger), to: model)
            XCTAssertEqual(peer.counters.drain(inputBufferedBytes: nil).clockSamples, 1, "an echo of a probe never sent is ignored")
        }
    }

    func testClockEchoIsIgnoredWithoutStreamStatistics() throws {
        try withStreamStatistics(false) {
            let model = PhoneRemoteModel(background: FakeBackgroundExecution())
            let peer = PeerMedia(isHost: false, servers: [])
            model.connection.media = peer
            defer { model.connection.media = nil; peer.close() }
            let sent = MachClock.nowMs() - 4
            _ = model.registerClockProbe(phoneMs: sent)
            let echo = ClockProbe(phoneMs: sent, hostReceivedMs: sent + 2, hostSentMs: sent + 3)
            try deliver(RemoteAction(action: "heartbeat", epoch: 0, clock: echo), to: model)
            let snapshot = peer.counters.drain(inputBufferedBytes: nil)
            XCTAssertNil(snapshot.clockOffsetMs)
            XCTAssertEqual(snapshot.clockSamples, 0)
        }
    }

    // MARK: Legibility schedule

    func testLegibilityScheduleFollowsAChartChange() {
        XCTAssertEqual((0..<5).map { LegibilityScheduler.offsetMs(slot: $0) }, [300, 1_000, 3_000, 8_000, 13_000])
        var scheduler = LegibilityScheduler()
        XCTAssertNil(scheduler.frame(markerSeed: 5, atMs: 1_000), "the change itself is not scored")
        XCTAssertNil(scheduler.frame(markerSeed: 5, atMs: 1_299))
        XCTAssertEqual(scheduler.frame(markerSeed: 5, atMs: 1_300), LegibilityScheduler.Job(seed: 5, ageMs: 300, scoresDecoded: false))
        XCTAssertNil(scheduler.frame(markerSeed: 5, atMs: 1_400), "one scoring at a time")
        scheduler.finished()
        XCTAssertNil(scheduler.frame(markerSeed: 5, atMs: 1_999))
        XCTAssertEqual(scheduler.frame(markerSeed: 5, atMs: 2_000), LegibilityScheduler.Job(seed: 5, ageMs: 1_000, scoresDecoded: false))
        scheduler.finished()
        XCTAssertEqual(scheduler.frame(markerSeed: 5, atMs: 4_000), LegibilityScheduler.Job(seed: 5, ageMs: 3_000, scoresDecoded: true),
                       "native pixels are scored at +3 s")
        scheduler.finished()
        XCTAssertNil(scheduler.frame(markerSeed: 5, atMs: 8_999))
        XCTAssertEqual(scheduler.frame(markerSeed: 5, atMs: 9_000), LegibilityScheduler.Job(seed: 5, ageMs: 8_000, scoresDecoded: false))
        scheduler.finished()
        XCTAssertNil(scheduler.frame(markerSeed: nil, atMs: 14_000), "an unreadable marker changes nothing")
        XCTAssertEqual(scheduler.frame(markerSeed: 5, atMs: 14_000)?.ageMs, 13_000, "every 5 s while the seed holds")
        scheduler.finished()
        XCTAssertNil(scheduler.frame(markerSeed: 9, atMs: 15_000), "a new seed restarts the schedule")
        XCTAssertEqual(scheduler.frame(markerSeed: 9, atMs: 15_300), LegibilityScheduler.Job(seed: 9, ageMs: 300, scoresDecoded: false))
    }

    func testSlotsPassedDuringAScoringAreFoldedIntoTheNextOne() {
        var scheduler = LegibilityScheduler()
        XCTAssertNil(scheduler.frame(markerSeed: 7, atMs: 0))
        XCTAssertNotNil(scheduler.frame(markerSeed: 7, atMs: 300))
        XCTAssertNil(scheduler.frame(markerSeed: 7, atMs: 1_000))
        XCTAssertNil(scheduler.frame(markerSeed: 7, atMs: 3_000))
        scheduler.finished()
        XCTAssertEqual(scheduler.frame(markerSeed: 7, atMs: 3_500), LegibilityScheduler.Job(seed: 7, ageMs: 3_500, scoresDecoded: true),
                       "the missed +1 s and +3 s slots become one scoring that still covers native pixels")
        scheduler.finished()
        XCTAssertNil(scheduler.frame(markerSeed: 7, atMs: 7_999))
        XCTAssertNotNil(scheduler.frame(markerSeed: 7, atMs: 8_000))
    }

    func testNoChartSeedForgetsTheChartButNotTheRunningScoring() {
        var scheduler = LegibilityScheduler()
        _ = scheduler.frame(markerSeed: 3, atMs: 0)
        XCTAssertNotNil(scheduler.frame(markerSeed: 3, atMs: 300))
        XCTAssertNil(scheduler.frame(markerSeed: LegibilityScheduler.noChart, atMs: 400))
        XCTAssertNil(scheduler.seed)
        XCTAssertNil(scheduler.frame(markerSeed: 3, atMs: 500), "the same chart coming back is a change")
        XCTAssertNil(scheduler.frame(markerSeed: 3, atMs: 800), "but the scoring still running blocks a second one")
        scheduler.finished()
        XCTAssertEqual(scheduler.frame(markerSeed: 3, atMs: 800)?.ageMs, 300)
        scheduler.forgetChart()
        XCTAssertTrue(scheduler.inFlight)
    }

    func testChartCropIsTheChartLayoutInFramePixels() throws {
        let source = CGSize(width: 1470, height: 956)
        let visible = CGRect(x: 0, y: 0, width: 2560, height: 1656)
        let rect = try XCTUnwrap(LegibilityProbe.chartRect(visible: visible, sourceSize: source))
        let chart = LegibilityChart.layout(displayPointSize: source).frame
        XCTAssertEqual(rect.minX, chart.minX * 2560 / 1470, accuracy: 1)
        XCTAssertEqual(rect.minY, chart.minY * 1656 / 956, accuracy: 1)
        XCTAssertEqual(rect.width, chart.width * 2560 / 1470, accuracy: 2)
        XCTAssertEqual(rect.height, chart.height * 1656 / 956, accuracy: 2)
        XCTAssertTrue(visible.contains(rect))
        let flipped = LegibilityProbe.coreImageRect(rect, bufferHeight: 1656)
        XCTAssertEqual(flipped.minY, 1656 - rect.maxY)
        XCTAssertEqual(flipped.size, rect.size)
        XCTAssertNil(LegibilityProbe.chartRect(visible: visible, sourceSize: .zero))
        XCTAssertEqual(LegibilityProbe.displayedZoom(onScreenPixelWidth: 1170, frameWidth: 2560), 1170.0 / 2560, accuracy: 0.0001)
        XCTAssertEqual(LegibilityProbe.displayedZoom(onScreenPixelWidth: 0, frameWidth: 2560), 1, "unknown on-screen size")
    }

    // MARK: Negotiated level and picture size

    private func report(codec: String? = "video/H264", level: String? = "640c34", width: Int? = 2560, height: Int? = 1656,
                        decoder: String? = nil, powerEfficient: Bool? = true) -> StreamStatsReport {
        var report = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []), counters: nil)
        report.route = "Direct"
        report.rttMs = 6.6
        report.codec = codec
        report.h264ProfileLevel = level
        report.receivedWidth = width
        report.receivedHeight = height
        report.decoderImplementation = decoder
        report.powerEfficientDecoder = powerEfficient
        return report
    }

    func testLinkSummaryDescribesPictureSizeAndCodecLevel() throws {
        let full = try XCTUnwrap(LinkSummary(report(), physicalDevice: true))
        XCTAssertEqual(full.route, "Direct")
        XCTAssertEqual(full.roundTripMs, 7)
        XCTAssertEqual(full.pictureSize, "2560×1656")
        XCTAssertEqual(full.codecLevel, "H.264 5.2")
        XCTAssertEqual(full.decoder, "hardware decode")
        XCTAssertFalse(full.reducedLevel)

        let reduced = try XCTUnwrap(LinkSummary(report(level: "42e01f", width: 832, height: 538), physicalDevice: true))
        XCTAssertEqual(reduced.codecLevel, "H.264 3.1")
        XCTAssertEqual(reduced.pictureSize, "832×538")
        XCTAssertTrue(reduced.reducedLevel, "a physical iPhone below level 5.2 is flagged")
        XCTAssertFalse(try XCTUnwrap(LinkSummary(report(level: "42e01f"), physicalDevice: false)).reducedLevel,
                       "the simulator always decodes at level 3.1")
        XCTAssertEqual(PhoneSessionNotice.reducedPicture(size: "832×538"),
                       "Reduced picture: this session runs at 832×538 (H.264 level 3.1). Quit and reopen Farside on both devices to retry.")

        XCTAssertEqual(LinkSummary(report(level: "640c28"), physicalDevice: true)?.codecLevel, "H.264 4")
        XCTAssertEqual(LinkSummary(report(level: nil), physicalDevice: true)?.codecLevel, "H.264")
        XCTAssertFalse(try XCTUnwrap(LinkSummary(report(level: nil), physicalDevice: true)).reducedLevel)
        XCTAssertEqual(LinkSummary(report(codec: "video/VP8", level: "640c1f"), physicalDevice: true)?.codecLevel, "VP8",
                       "the level is only read for H.264")
        XCTAssertNil(LinkSummary(report(width: 0))?.pictureSize, "no picture before the first decoded frame")
        XCTAssertEqual(LinkSummary(report(decoder: "VideoToolbox", powerEfficient: nil))?.decoder, "hardware decode")
        XCTAssertEqual(LinkSummary(report(powerEfficient: false))?.decoder, "software decode")
        XCTAssertNil(LinkSummary(report(decoder: "libavcodec", powerEfficient: nil))?.decoder)
    }

    func testLinkSummaryNeedsSomethingToShow() {
        var empty = report(codec: nil, level: nil, width: nil, height: nil, powerEfficient: nil)
        empty.route = "Route pending"
        empty.rttMs = nil
        XCTAssertNil(LinkSummary(empty))
        var sizeOnly = empty
        sizeOnly.receivedWidth = 1920
        sizeOnly.receivedHeight = 1242
        XCTAssertEqual(LinkSummary(sizeOnly)?.pictureSize, "1920×1242")
    }
}
