import XCTest

final class StreamInstrumentStatsTests: XCTestCase {
    func testEncoderLatencyTraceMatchesByKeyAndFallsBackToTheOldest() {
        var trace = EncoderLatencyTrace()
        trace.submitted(key: 100, atMs: 1_000)
        trace.submitted(key: 116, atMs: 1_016)
        trace.submitted(key: 133, atMs: 1_033)
        XCTAssertEqual(trace.inFlight, 3)
        let second = trace.completed(key: 116, atMs: 1_040)
        XCTAssertEqual(second, EncoderLatencyTrace.Sample(latencyMs: 24, inFlight: 2))
        let unknown = trace.completed(key: 999, atMs: 1_045)
        XCTAssertEqual(unknown, EncoderLatencyTrace.Sample(latencyMs: 45, inFlight: 1), "an unknown key takes the oldest submission")
        XCTAssertEqual(trace.inFlight, 1)
        XCTAssertNil(trace.completed(key: 133, atMs: 3_000), "a frame older than a second was forgotten")
        XCTAssertEqual(trace.inFlight, 0)
        trace.submitted(key: 1, atMs: 5_000)
        trace.reset()
        XCTAssertEqual(trace.inFlight, 0)
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
