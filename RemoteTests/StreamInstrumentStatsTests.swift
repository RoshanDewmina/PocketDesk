import XCTest
import WebRTC

final class StreamInstrumentStatsTests: XCTestCase {
    func testEncoderKeepsItsOwnCountersAfterAnotherHostStarts() {
        let first = StreamCounters()
        let second = StreamCounters()
        DesktopH264Encoder.sharedCounters = first
        defer { DesktopH264Encoder.sharedCounters = nil }
        let codec = RTCVideoCodecInfo(name: kRTCVideoCodecH264Name, parameters: [:])
        let firstEncoder = DesktopH264Encoder(codecInfo: codec)

        DesktopH264Encoder.sharedCounters = second
        _ = firstEncoder.setBitrate(1_000, framerate: 60)

        XCTAssertEqual(first.drain(inputBufferedBytes: nil).rateUpdates, 1)
        XCTAssertNil(second.drain(inputBufferedBytes: nil).rateUpdates)
    }

    func testEncoderLatencyTraceMatchesByKeyAndFallsBackToTheOldest() {
        var trace = EncoderLatencyTrace()
        trace.submitted(key: 100, atMs: 1_000)
        trace.submitted(key: 116, atMs: 1_016)
        trace.submitted(key: 133, atMs: 1_033)
        XCTAssertEqual(trace.inFlight, 3)
        let first = trace.completed(key: 100, atMs: 1_030)
        XCTAssertEqual(first, EncoderLatencyTrace.Sample(latencyMs: 30, inFlight: 1))
        let unknown = trace.completed(key: 999, atMs: 1_045)
        XCTAssertEqual(unknown, EncoderLatencyTrace.Sample(latencyMs: 29, inFlight: 2), "an unknown key takes the oldest submission")
        XCTAssertEqual(trace.takeSilentDrops(), 0, "an unknown key retires nothing")
        XCTAssertEqual(trace.inFlight, 1)
        XCTAssertNil(trace.completed(key: 133, atMs: 3_000), "a frame older than a second was forgotten")
        XCTAssertEqual(trace.inFlight, 0)
        trace.submitted(key: 1, atMs: 5_000)
        trace.reset()
        XCTAssertEqual(trace.inFlight, 0)
    }

    /// VideoToolbox returns frames in submit order (the ObjC encoder turns frame reordering off), so a
    /// completion for a later frame means every older pending frame was dropped without a callback.
    func testCompletionRetiresOlderPendingFramesAsSilentDrops() {
        var trace = EncoderLatencyTrace()
        trace.submitted(key: 100, atMs: 1_000)
        trace.submitted(key: 116, atMs: 1_016)
        trace.submitted(key: 133, atMs: 1_033)
        XCTAssertEqual(trace.completed(key: 133, atMs: 1_040), EncoderLatencyTrace.Sample(latencyMs: 7, inFlight: 3))
        XCTAssertEqual(trace.inFlight, 0)
        XCTAssertEqual(trace.takeSilentDrops(), 2)
        XCTAssertEqual(trace.takeSilentDrops(), 0, "taking resets the count")
    }

    func testSilentDropOpensTheNewestFrameWinsGateAtTheNextCompletionOrAfterTheWindow() {
        let window = DesktopH264Encoder.inFlightWindowMs
        XCTAssertEqual(window, 100)
        var trace = EncoderLatencyTrace()
        trace.submitted(key: 1, atMs: 0)
        XCTAssertEqual(trace.pending(withinMs: window, now: 99), 1, "still counted inside the window")
        XCTAssertEqual(trace.pending(withinMs: window, now: 101), 0, "a frame that never calls back stops blocking")
        trace.submitted(key: 2, atMs: 101)
        _ = trace.completed(key: 2, atMs: 110)
        XCTAssertEqual(trace.pending(withinMs: window, now: 110), 0)
        XCTAssertEqual(trace.takeSilentDrops(), 1)
    }

    func testFailedSubmitIsCancelledSoItNeverHoldsTheGate() {
        var trace = EncoderLatencyTrace()
        trace.submitted(key: 5, atMs: 0)
        trace.submitted(key: 6, atMs: 8)
        trace.cancel(key: 6)
        XCTAssertEqual(trace.inFlight, 1)
        XCTAssertEqual(trace.pending(withinMs: 100, now: 9), 1)
        trace.cancel(key: 42)
        XCTAssertEqual(trace.inFlight, 1, "an unknown key cancels nothing")
        _ = trace.completed(key: 5, atMs: 12)
        XCTAssertEqual(trace.takeSilentDrops(), 0, "a cancelled frame is not a silent drop")
    }

    func testSilentDropsReachTheHostSummary() throws {
        let counters = StreamCounters()
        counters.encoded(latencyMs: 12, bytes: 40_000, isKeyFrame: false, inFlight: 1)
        counters.encoderSilentlyDropped(3)
        let snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.encoderSilentDrops, 3)
        XCTAssertNil(counters.drain(inputBufferedBytes: nil).encoderSilentDrops, "reset after each sample")
        var report = StreamStatsReport(role: "host", previous: StreamStatsSample(entries: []),
                                       current: StreamStatsSample(entries: []), counters: snapshot)
        report.encoderSilentDrops = snapshot.encoderSilentDrops
        let summary = report.hostSummary
        XCTAssertEqual(summary.encoderSilentDrops, 3)
        XCTAssertNoThrow(try summary.validate())
        let decoded = try JSONDecoder().decode(HostStreamSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(decoded.encoderSilentDrops, 3)
        var bad = summary
        bad.encoderSilentDrops = -1
        XCTAssertThrowsError(try bad.validate())
    }

    // Performance pack item 1a: pointer moves merge only while the control channel is backed up.
    private func move(_ x: Double, _ y: Double, ordinal: UInt64? = 1, epoch: UInt64 = 3,
                      modifiers: [String] = [], token: String? = "t1") -> RemoteAction {
        RemoteAction(action: "move", x: x, y: y, modifiers: modifiers, epoch: epoch,
                     interaction: token.map { NativeInteraction(token: $0) },
                     pointerSync: ordinal.map { PointerSync(move: $0) })
    }

    private func summary(_ actions: [RemoteAction]) -> [String] {
        actions.map { "\($0.action) \($0.x),\($0.y) #\($0.pointerSync?.move ?? 0)" }
    }

    func testMovesPassThroughWhileTheChannelIsHealthy() {
        var coalescer = PointerMoveCoalescer()
        XCTAssertEqual(summary(coalescer.offer(move(1, 2), backlogged: false, now: 0)), ["move 1.0,2.0 #1"])
        XCTAssertEqual(summary(coalescer.offer(move(3, 4, ordinal: 2), backlogged: false, now: 0.001)), ["move 3.0,4.0 #2"])
        XCTAssertNil(coalescer.pending)
        XCTAssertEqual(coalescer.takeMerged(), 0)
    }

    func testBackloggedMovesSumIntoOneMessageWithTheNewestOrdinal() {
        var coalescer = PointerMoveCoalescer()
        XCTAssertTrue(coalescer.offer(move(1, 2, ordinal: 1), backlogged: true, now: 0).isEmpty)
        XCTAssertTrue(coalescer.offer(move(3, -1, ordinal: 2), backlogged: true, now: 0.008).isEmpty)
        XCTAssertTrue(coalescer.offer(move(0.5, 0.25, ordinal: 3), backlogged: true, now: 0.016).isEmpty)
        XCTAssertEqual(coalescer.takeMerged(), 2)
        XCTAssertNil(coalescer.flush(backlogged: true, now: 0.02), "held while backed up, inside the deadline")
        XCTAssertEqual(summary([coalescer.flush(backlogged: false, now: 0.02)].compactMap { $0 }), ["move 4.5,1.25 #3"])
        XCTAssertNil(coalescer.pending)
    }

    func testAHeldMoveIsSentAtTheDeadlineEvenWhileBackedUp() {
        var coalescer = PointerMoveCoalescer()
        _ = coalescer.offer(move(1, 1), backlogged: true, now: 1)
        XCTAssertNil(coalescer.flush(backlogged: true, now: 1 + PointerMoveCoalescer.flushInterval - 0.001))
        XCTAssertNotNil(coalescer.flush(backlogged: true, now: 1 + PointerMoveCoalescer.flushInterval))
    }

    func testAbsolutePlacementsKeepTheNewestPoint() {
        var coalescer = PointerMoveCoalescer()
        var first = move(100, 200, ordinal: 4); first.action = "moveTo"
        var second = move(110, 190, ordinal: 5); second.action = "moveTo"
        XCTAssertTrue(coalescer.offer(first, backlogged: true, now: 0).isEmpty)
        XCTAssertTrue(coalescer.offer(second, backlogged: true, now: 0.01).isEmpty)
        XCTAssertEqual(summary([coalescer.flush(backlogged: false, now: 0.02)].compactMap { $0 }), ["moveTo 110.0,190.0 #5"])
    }

    func testAnythingElseSendsThePendingMoveFirst() {
        var coalescer = PointerMoveCoalescer()
        _ = coalescer.offer(move(2, 2), backlogged: true, now: 0)
        let click = RemoteAction(action: "click", epoch: 3, interaction: NativeInteraction(token: "t1", clickCount: 1))
        XCTAssertEqual(coalescer.offer(click, backlogged: true, now: 0.001).map(\.action), ["move", "click"],
                       "a click lands where the moves put the pointer")
        _ = coalescer.offer(move(2, 2), backlogged: true, now: 0.002)
        let heartbeat = RemoteAction(action: "heartbeat", epoch: 3)
        XCTAssertEqual(coalescer.offer(heartbeat, backlogged: true, now: 0.003).map(\.action), ["move", "heartbeat"])
        XCTAssertNil(coalescer.pending)
    }

    func testMovesWithADifferentEnvelopeNeverMerge() {
        let variants: [(String, RemoteAction)] = [
            ("epoch", move(1, 1, epoch: 4)), ("modifiers", move(1, 1, modifiers: ["shift"])),
            ("token", move(1, 1, token: "t2")), ("kind", { var a = move(1, 1); a.action = "moveTo"; return a }()),
            ("legacy host", move(1, 1, ordinal: nil))
        ]
        for (name, other) in variants {
            var coalescer = PointerMoveCoalescer()
            _ = coalescer.offer(move(5, 5), backlogged: true, now: 0)
            let sent = coalescer.offer(other, backlogged: true, now: 0.001)
            XCTAssertEqual(summary(sent), ["move 5.0,5.0 #1"], name)
            XCTAssertNotNil(coalescer.pending, name)
            XCTAssertEqual(coalescer.takeMerged(), 0, name)
        }
    }

    func testAMergeThatWouldLeaveTheValidRangeSendsFirst() throws {
        var coalescer = PointerMoveCoalescer()
        _ = coalescer.offer(move(15_000, 0), backlogged: true, now: 0)
        let sent = coalescer.offer(move(15_000, 0, ordinal: 2), backlogged: true, now: 0.001)
        XCTAssertEqual(summary(sent), ["move 15000.0,0.0 #1"])
        let held = try XCTUnwrap(coalescer.flush(backlogged: false, now: 0.002))
        XCTAssertNoThrow(try held.validate())
    }

    func testDiscardDropsAHeldMove() {
        var coalescer = PointerMoveCoalescer()
        _ = coalescer.offer(move(1, 1), backlogged: true, now: 0)
        coalescer.discard()
        XCTAssertNil(coalescer.pending)
        XCTAssertNil(coalescer.flush(backlogged: false, now: 1))
    }

    func testMergeSwitchDefaultsOnAndLegacyTurnsItOff() throws {
        XCTAssertTrue(StreamTuning.tuned.mergePointerMoves)
        XCTAssertFalse(StreamTuning.legacy.mergePointerMoves)
        XCTAssertTrue(StreamTuning.experimentKeys.contains(StreamTuning.mergePointerMovesKey))
        let suite = "PointerMoveCoalescer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: StreamTuning.mergePointerMovesKey)
        let off = StreamTuning.resolve(defaults: defaults)
        XCTAssertFalse(off.mergePointerMoves)
        XCTAssertTrue(off.summary.contains("no move merge"), off.summary)
    }

    // Performance pack item 1b: how long input waits for the Mac's main queue, and how long posting takes.
    func testHostInputDelayReachesTheSummary() throws {
        let counters = StreamCounters()
        for index in 0..<20 { counters.inputHandled(mainDelayMs: Double(index), postMs: 0.2) }
        counters.inputHandled(mainDelayMs: 120, postMs: 3)
        let snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.inputEvents, 21)
        XCTAssertEqual(snapshot.inputMainDelayP50Ms ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(snapshot.inputMainDelayMaxMs, 120)
        XCTAssertEqual(snapshot.inputPostP95Ms ?? -1, 0.2, accuracy: 0.001)
        XCTAssertNil(counters.drain(inputBufferedBytes: nil).inputEvents, "reset after each sample")
        var report = StreamStatsReport(role: "host", previous: StreamStatsSample(entries: []),
                                       current: StreamStatsSample(entries: []), counters: snapshot)
        report.inputMainDelayP50Ms = snapshot.inputMainDelayP50Ms
        report.inputMainDelayP95Ms = snapshot.inputMainDelayP95Ms
        report.inputMainDelayMaxMs = snapshot.inputMainDelayMaxMs
        report.inputPostP95Ms = snapshot.inputPostP95Ms
        report.inputEvents = snapshot.inputEvents
        let summary = report.hostSummary
        XCTAssertEqual(summary.inputEvents, 21)
        XCTAssertNoThrow(try summary.validate())
        var bad = summary
        bad.inputMainDelayMaxMs = .infinity
        XCTAssertThrowsError(try bad.validate())
        var phone = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []), counters: nil)
        phone.host = summary
        XCTAssertTrue(phone.summaryLines.contains { $0.hasPrefix("Mac input main p50 10") }, "\(phone.summaryLines)")
    }

    func testCountersReportGlassLatencyCadenceAndInputToPhoton() {
        let counters = StreamCounters()
        // Host clock runs 1_000_000 ms ahead of the phone.
        counters.clockUpdated(ClockSyncEstimate(offsetMs: 1_000_000, uncertaintyMs: 2, samples: 5))
        counters.clickSent(atMs: 90)
        var flash = false
        for frame in 0..<60 {
            let presentedMs = 100 + Double(frame) * 16.7
            if frame == 6 { flash = true }
            let drawnHostMs = presentedMs + 1_000_000 - 30 - Double(frame % 3) * 5
            let marker = BenchMarker(hostTimeMs: drawnHostMs, chartSeed: 1, flash: flash, motion: true)
            counters.presentedFrame(atMs: presentedMs, marker: marker)
        }
        counters.presentedFrame(atMs: 100 + 60 * 16.7, marker: nil)
        let snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.markerFrames, 60)
        XCTAssertEqual(snapshot.markerDistinct, 60)
        // The marker floors host time to whole ms, so each sample reads up to 1 ms above nominal.
        XCTAssertEqual(snapshot.glassP50Ms ?? 0, 35.5, accuracy: 0.6)
        XCTAssertEqual(snapshot.glassMaxMs ?? 0, 40.5, accuracy: 0.6)
        XCTAssertEqual(snapshot.clockOffsetMs, 1_000_000)
        XCTAssertEqual(snapshot.clockSamples, 5)
        XCTAssertEqual(snapshot.presentedIntervalP50Ms ?? 0, 16.7, accuracy: 0.01)
        XCTAssertEqual(snapshot.presentedAt120Share, 0)
        XCTAssertEqual(snapshot.inputToPhotonSamples, 1)
        XCTAssertEqual(snapshot.inputToPhotonP50Ms ?? 0, 100 + 6 * 16.7 - 90, accuracy: 0.01)
        let report = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []), counters: nil)
        XCTAssertNil(report.markerFrames)
    }

    func testCountersCarryTheEncoderTraceIntoTheHostSummary() throws {
        let counters = StreamCounters()
        counters.encoderSessionStarted(atMs: MachClock.nowMs() - 2_500)
        counters.encoderRateUpdated()
        counters.encoderRateUpdated()
        counters.encoded(latencyMs: 14.7, bytes: 12_000, isKeyFrame: false, inFlight: 1)
        counters.encoded(latencyMs: 29.4, bytes: 300_000, isKeyFrame: true, inFlight: 2)
        counters.encoded(latencyMs: 42.1, bytes: 8_000, isKeyFrame: false, inFlight: 3)
        let snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.encodeLatencyP50Ms, 29.4)
        XCTAssertEqual(snapshot.encodeLatencyMaxMs, 42.1)
        XCTAssertEqual(snapshot.encodeInFlightMax, 3)
        XCTAssertEqual(snapshot.encodeBytesP50, 12_000)
        XCTAssertEqual(snapshot.keyFrameBytesMax, 300_000)
        XCTAssertEqual(snapshot.rateUpdates, 2)
        XCTAssertEqual(snapshot.encoderSessionAgeS ?? 0, 2.5, accuracy: 0.5)

        var withInterval = snapshot
        withInterval.interval = 1
        let sample = StreamStatsSample(entries: [])
        let report = StreamStatsReport(role: "host", previous: sample, current: sample, counters: withInterval)
        XCTAssertEqual(report.encodeLatencyMs, 29.4)
        XCTAssertEqual(report.keyFrameBytesMax, 300_000)
        let summary = report.hostSummary
        XCTAssertEqual(summary.encodeInFlightMax, 3)
        XCTAssertEqual(summary.rateUpdates, 2)
        XCTAssertNoThrow(try summary.validate())
        let decoded = try JSONDecoder().decode(HostStreamSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(decoded, summary)
        XCTAssertTrue(report.summaryLines.contains { $0.hasPrefix("VT lat p50 29.4ms") }, report.summaryLines.joined(separator: "\n"))

        var oversized = summary
        oversized.keyFrameBytesMax = 60_000_000
        XCTAssertThrowsError(try oversized.validate())
        let legacy = try JSONDecoder().decode(HostStreamSummary.self, from: Data(#"{"captureFPS":58}"#.utf8))
        XCTAssertNil(legacy.encodeLatencyMs, "summaries from older hosts still decode")
    }

    func testPhoneOverlayShowsMarkerAndLegibilityLines() {
        var snapshot = StreamCounterSnapshot(interval: 1)
        snapshot.markerFrames = 58
        snapshot.markerDistinct = 57
        snapshot.glassP50Ms = 31
        snapshot.glassP95Ms = 44
        snapshot.glassMaxMs = 61
        snapshot.clockUncertaintyMs = 2
        snapshot.clockSamples = 12
        snapshot.presentedIntervalP50Ms = 8.3
        snapshot.presentedIntervalP90Ms = 16.7
        snapshot.presentedIntervalMinMs = 8.2
        snapshot.presentedAt120Share = 0.42
        snapshot.legibility = LegibilitySummary(seed: 7, ageMs: 1_000, surface: "displayed", zoom: 1.5,
                                                cer: ["9pt": 12, "11pt": 3, "13pt": 0, "15pt": 0, "coloured11pt": 4])
        let sample = StreamStatsSample(entries: [])
        let report = StreamStatsReport(role: "phone", previous: sample, current: sample, counters: snapshot)
        let lines = report.summaryLines.joined(separator: "\n")
        XCTAssertTrue(lines.contains("glass p50 31.0ms p95 44.0ms max 61.0ms ±2.0ms · n 58 · distinct 57.0/s"), lines)
        XCTAssertTrue(lines.contains("shownΔ p50 8.3ms p90 16.7ms min 8.2ms · at 120Hz 42%"), lines)
        XCTAssertTrue(lines.contains("CER 9pt 12% 11pt 3% 13pt 0% 15pt 0% coloured11pt 4% (+1.0s displayed)"), lines)
        XCTAssertEqual(report.presentedAt120Share, 0.42)
        XCTAssertEqual(report.legibility?.cer["11pt"], 3)
    }

    func testRepeatedMarkerIsTheFramesAgeNotALatency() {
        let counters = StreamCounters()
        counters.clockUpdated(ClockSyncEstimate(offsetMs: 0, uncertaintyMs: 3, samples: 4))
        let first = BenchMarker(hostTimeMs: 1_000, chartSeed: 1, flash: false, motion: false)
        counters.presentedFrame(atMs: 1_030, marker: first)
        counters.presentedFrame(atMs: 1_500, marker: first)
        counters.presentedFrame(atMs: 19_000, marker: first)
        var snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.markerFrames, 3, "every presented frame with a marker is still counted as shown")
        XCTAssertEqual(snapshot.markerDistinct, 1)
        XCTAssertEqual(snapshot.glassSamples, 1)
        XCTAssertEqual(snapshot.glassMaxMs ?? 0, 30, accuracy: 0.01, "the re-pushed frame's 18 s age is not glass")

        counters.clickSent(atMs: 19_100)
        let firstFlipped = BenchMarker(hostTimeMs: 1_000, chartSeed: 1, flash: true, motion: false)
        counters.presentedFrame(atMs: 19_150, marker: firstFlipped)
        counters.presentedFrame(atMs: 19_200, marker: first)
        let second = BenchMarker(hostTimeMs: 19_180, chartSeed: 1, flash: true, motion: false)
        counters.presentedFrame(atMs: 19_210, marker: second)
        counters.presentedFrame(atMs: 19_220, marker: second)
        snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.markerFrames, 4)
        XCTAssertEqual(snapshot.markerDistinct, 1, "only the new value is distinct")
        XCTAssertEqual(snapshot.glassSamples, 1)
        XCTAssertEqual(snapshot.glassP50Ms ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(snapshot.inputToPhotonSamples, 1, "a repeated value never completes a flash")
        XCTAssertEqual(snapshot.inputToPhotonP50Ms ?? 0, 110, accuracy: 0.01)

        counters.presentedFrame(atMs: 19_300, marker: second)
        counters.presentedFrame(atMs: 19_400, marker: second)
        var stale = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(stale.markerFrames, 2)
        XCTAssertEqual(stale.markerDistinct, 0)
        XCTAssertEqual(stale.glassSamples, 0)
        XCTAssertNil(stale.glassP50Ms)
        stale.interval = 1
        let sample = StreamStatsSample(entries: [])
        let staleLines = StreamStatsReport(role: "phone", previous: sample, current: sample,
                                           counters: stale).summaryLines
        XCTAssertTrue(staleLines.contains("glass — · no new Mac frame · shown 2"),
                      staleLines.joined(separator: "\n"))
        XCTAssertFalse(staleLines.contains { $0.hasPrefix("glass p50") })

        var fresh = StreamCounterSnapshot(interval: 1)
        fresh.markerFrames = 3
        fresh.markerDistinct = 2
        fresh.glassSamples = 2
        fresh.glassP50Ms = 30
        let freshLines = StreamStatsReport(role: "phone", previous: sample, current: sample,
                                           counters: fresh).summaryLines
        XCTAssertTrue(freshLines.contains { $0.hasPrefix("glass p50 30.0ms") && $0.contains("· n 2 · distinct 2.0/s") },
                      freshLines.joined(separator: "\n"))
    }

    func testCaptureDisplayTimesGiveTheSourceCadence() {
        let counters = StreamCounters()
        let frame = 1_000.0 / 120
        let times = [10_000, 10_000 + frame, 10_000 + 2 * frame, 10_000 + 3 * frame, 10_000 + 5 * frame]
        for (index, time) in times.enumerated() {
            counters.captured(idle: false, displayLatencyMs: 4, displayTimeMs: time, at: Double(index) * 0.02)
        }
        counters.captured(idle: true, displayLatencyMs: 4, displayTimeMs: 10_000 + 6 * frame, at: 0.2)
        counters.captured(idle: false, displayLatencyMs: 4, at: 0.25)
        var snapshot = counters.drain(inputBufferedBytes: nil, at: 1)
        XCTAssertEqual(snapshot.captureGapMedianMs ?? 0, frame, accuracy: 0.001,
                       "one skipped refresh does not move the median")
        XCTAssertEqual(snapshot.captureGapMaxMs ?? 0, 170, accuracy: 0.001,
                       "the callback cadence is measured separately")

        snapshot.interval = 1
        let report = StreamStatsReport(role: "host", previous: nil, current: StreamStatsSample(entries: []),
                                       counters: snapshot)
        XCTAssertEqual(report.captureGapMedianMs, 8.3)
        XCTAssertEqual(report.hostSummary.captureGapMedianMs, 8.3)

        XCTAssertNil(counters.drain(inputBufferedBytes: nil, at: 2).captureGapMedianMs, "each sample starts empty")
        counters.captured(idle: false, displayTimeMs: 0, at: 3)
        counters.captured(idle: false, displayTimeMs: -5, at: 3.1)
        XCTAssertNil(counters.drain(inputBufferedBytes: nil, at: 4).captureGapMedianMs,
                     "a missing display time is no gap")
    }

    func testEncoderDropsAreCountedPerSampleAndShownBesideTheTrace() throws {
        let counters = StreamCounters()
        counters.encoded(latencyMs: 9, bytes: 10_000, isKeyFrame: false, inFlight: 1)
        counters.droppedBeforeEncode()
        counters.droppedBeforeEncode()
        counters.droppedBeforeEncode()
        var snapshot = counters.drain(inputBufferedBytes: nil, at: 1)
        XCTAssertEqual(snapshot.encoderDropped, 3)
        counters.encoded(latencyMs: 9, bytes: 10_000, isKeyFrame: false, inFlight: 1)
        XCTAssertEqual(counters.drain(inputBufferedBytes: nil, at: 2).encoderDropped, 0,
                       "encoding without drops is zero")
        XCTAssertNil(counters.drain(inputBufferedBytes: nil, at: 3).encoderDropped, "no encoder activity: unknown")
        counters.droppedBeforeEncode()
        XCTAssertEqual(counters.drain(inputBufferedBytes: nil, at: 4).encoderDropped, 1,
                       "a second of only drops still counts")

        snapshot.interval = 1
        let sample = StreamStatsSample(entries: [])
        let report = StreamStatsReport(role: "host", previous: sample, current: sample, counters: snapshot)
        XCTAssertEqual(report.encoderDropped, 3)
        let summary = report.hostSummary
        XCTAssertEqual(summary.encoderDropped, 3)
        XCTAssertNoThrow(try summary.validate())
        XCTAssertTrue(report.summaryLines.contains { $0.hasPrefix("VT lat p50 9.0ms") && $0.hasSuffix("dropped 3/s") },
                      report.summaryLines.joined(separator: "\n"))
        var phone = StreamStatsReport(role: "phone", previous: nil, current: sample, counters: nil)
        phone.host = summary
        XCTAssertTrue(phone.summaryLines.contains { $0.hasPrefix("Mac VT lat") && $0.hasSuffix(" · dropped 3/s") },
                      phone.summaryLines.joined(separator: "\n"))
        var flooded = summary
        flooded.encoderDropped = 100_001
        XCTAssertThrowsError(try flooded.validate())
    }

    func testHostSummaryCarriesRateLoadAndRegion() throws {
        let sample = StreamStatsSample(entries: [])
        var report = StreamStatsReport(role: "host", previous: nil, current: sample, counters: nil)
        report.targetFPS = 120
        report.displayRefreshHz = 143.856
        report.captureDisplay = "2560x1440 @1x 144Hz"
        report.captureGapMedianMs = 8.3
        report.thermalState = ProcessInfo.ThermalState.serious.rawValue
        report.lowPowerMode = true
        report.ladder = LadderState(rung: 1, fps: 120, sizeFraction: 0.75, reason: "encode")
        report.busy = BusyState(level: .strained, fps: 120, longEdge: 1920, reason: "encoding")
        report.captureRegion = CaptureRegion(epoch: 3, x: 100, y: 50, width: 892, height: 410,
                                             outputWidth: 1784, outputHeight: 820)
        let summary = report.hostSummary
        XCTAssertEqual(summary.targetFPS, 120)
        XCTAssertEqual(summary.displayRefreshHz, 143.856)
        XCTAssertEqual(summary.captureDisplay, "2560x1440 @1x 144Hz")
        XCTAssertEqual(summary.captureGapMedianMs, 8.3)
        XCTAssertEqual(summary.thermalState, 2)
        XCTAssertEqual(summary.lowPowerMode, true)
        XCTAssertEqual(summary.ladder, report.ladder)
        XCTAssertEqual(summary.busy, report.busy)
        XCTAssertEqual(summary.captureRegion, report.captureRegion)
        XCTAssertNoThrow(try summary.validate())
        XCTAssertEqual(try JSONDecoder().decode(HostStreamSummary.self, from: JSONEncoder().encode(summary)), summary)
        let action = RemoteAction(action: "capture", x: 1, hostStream: summary)
        XCTAssertNoThrow(try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(action)).validate())
        let decodedReport = try JSONDecoder().decode(StreamStatsReport.self,
                                                     from: Data(report.logLine.dropFirst("PDSTATS ".count).utf8))
        XCTAssertEqual(decodedReport, report, "the JSONL log carries every new field")
        let old = Data(#"{"captureFPS":58,"encodeLatencyMs":14.7}"#.utf8)
        let legacy = try JSONDecoder().decode(HostStreamSummary.self, from: old)
        XCTAssertNil(legacy.targetFPS)
        XCTAssertNil(legacy.thermalState)
        XCTAssertNil(legacy.ladder)
        XCTAssertNoThrow(try legacy.validate())

        let rate = "target 120fps · 2560x1440 @1x 144Hz · capture Δ p50 8.3ms · thermal serious · low power"
        let load = "ladder 1 120fps ×0.75 (encode) · strained 120fps 1920px (encoding)"
            + " · region #3 100,50 892×410pt → 1784×820"
        XCTAssertTrue(report.summaryLines.contains(rate), report.summaryLines.joined(separator: "\n"))
        XCTAssertTrue(report.summaryLines.contains(load), report.summaryLines.joined(separator: "\n"))

        var phone = StreamStatsReport(role: "phone", previous: nil, current: sample, counters: nil)
        phone.host = summary
        phone.thermalState = ProcessInfo.ThermalState.fair.rawValue
        phone.lowPowerMode = false
        XCTAssertTrue(phone.summaryLines.contains("Mac " + rate), phone.summaryLines.joined(separator: "\n"))
        XCTAssertTrue(phone.summaryLines.contains("Mac " + load), phone.summaryLines.joined(separator: "\n"))
        XCTAssertTrue(phone.summaryLines.contains("phone thermal fair"), phone.summaryLines.joined(separator: "\n"))

        report.ladder = nil
        report.busy = .ok
        report.captureRegion = CaptureRegion(epoch: 0, x: 0, y: 0, width: 1280, height: 720,
                                             outputWidth: 2560, outputHeight: 1440)
        XCTAssertTrue(report.summaryLines.contains("not busy · whole display → 2560×1440"),
                      report.summaryLines.joined(separator: "\n"))

        let bare = StreamStatsReport(role: "host", previous: nil, current: sample, counters: nil)
        let newPrefixes = ["target ", "ladder ", "not busy", "thermal "]
        XCTAssertFalse(bare.summaryLines.contains { line in newPrefixes.contains { line.hasPrefix($0) } },
                       "no new lines without the new fields")
        XCTAssertEqual(StreamStatsReport.thermalName(ProcessInfo.ThermalState.nominal.rawValue), "nominal")
        XCTAssertEqual(StreamStatsReport.thermalName(ProcessInfo.ThermalState.critical.rawValue), "critical")
        XCTAssertNil(StreamStatsReport.thermalName(4))
        XCTAssertNil(StreamStatsReport.thermalName(nil))
    }

    func testHostSummaryClampsWhatThePhoneWouldReject() throws {
        var report = StreamStatsReport(role: "host", previous: nil, current: StreamStatsSample(entries: []),
                                       counters: nil)
        report.targetFPS = 500
        report.displayRefreshHz = .infinity
        report.captureDisplay = String(repeating: "\u{E9}", count: 40)
        report.thermalState = 9
        report.captureGapMedianMs = 50_000_000
        report.encoderDropped = 1_000_000
        report.ladder = LadderState(rung: 1, fps: 120, sizeFraction: 0, reason: nil)
        report.busy = BusyState(level: .busy, fps: 30, longEdge: 1440, reason: String(repeating: "x", count: 30))
        report.captureRegion = CaptureRegion(epoch: 1, x: 0, y: 0, width: 0, height: 10,
                                             outputWidth: 100, outputHeight: 100)
        var summary = report.hostSummary
        XCTAssertEqual(summary.targetFPS, 240)
        XCTAssertNil(summary.displayRefreshHz)
        XCTAssertEqual(summary.captureDisplay, String(repeating: "\u{E9}", count: 24), "48 bytes, whole characters")
        XCTAssertEqual(summary.thermalState, 3)
        XCTAssertEqual(summary.captureGapMedianMs, 10_000_000)
        XCTAssertEqual(summary.encoderDropped, 100_000)
        XCTAssertNil(summary.ladder)
        XCTAssertNil(summary.busy)
        XCTAssertNil(summary.captureRegion)
        XCTAssertNoThrow(try summary.validate(), "the Mac never sends a summary the phone rejects")

        report.targetFPS = 0
        report.displayRefreshHz = 5_000
        report.thermalState = -1
        summary = report.hostSummary
        XCTAssertEqual(summary.targetFPS, 1)
        XCTAssertEqual(summary.displayRefreshHz, 1_000)
        XCTAssertEqual(summary.thermalState, 0)
        XCTAssertNoThrow(try summary.validate())

        func rejects(_ change: (inout HostStreamSummary) -> Void, line: UInt = #line) {
            var bad = summary
            change(&bad)
            XCTAssertThrowsError(try bad.validate(), line: line)
        }
        rejects { $0.targetFPS = 0 }
        rejects { $0.targetFPS = 241 }
        rejects { $0.displayRefreshHz = 1_001 }
        rejects { $0.displayRefreshHz = -1 }
        rejects { $0.thermalState = 4 }
        rejects { $0.captureDisplay = String(repeating: "x", count: 49) }
        rejects { $0.captureGapMedianMs = .nan }
        rejects { $0.encoderDropped = -1 }
        rejects { $0.ladder = LadderState(rung: 17, fps: 60, sizeFraction: 1, reason: nil) }
        rejects { $0.busy = BusyState(level: .busy, fps: 241, longEdge: 0, reason: "") }
        rejects {
            $0.captureRegion = CaptureRegion(epoch: 1, x: 0, y: 0, width: 10, height: 10,
                                             outputWidth: 0, outputHeight: 10)
        }
    }
}
