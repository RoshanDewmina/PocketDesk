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
}
