import XCTest

/// Efficiency audit (Docs/perf/EFFICIENCY-AUDIT-2026-09-30.md): P1 newest frame wins, P2 idle refresh
/// switch, P16 Wi-Fi stall tip.
final class EfficiencyDefaultsTests: XCTestCase {
    private func defaults() throws -> (UserDefaults, () -> Void) {
        let suite = "EfficiencyDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    func testNewestFrameWinsIsTheTunedDefaultAndZeroTurnsItOff() throws {
        XCTAssertEqual(StreamTuning.tuned.encoderMaxInFlight, 1)
        XCTAssertNil(StreamTuning.legacy.encoderMaxInFlight)
        XCTAssertTrue(StreamTuning.tuned.summary.hasSuffix("max refresh · max in-flight 1"), StreamTuning.tuned.summary)
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        defaults.set(0, forKey: StreamTuning.encoderMaxInFlightKey)
        XCTAssertNil(StreamTuning.resolve(defaults: defaults).encoderMaxInFlight)
        defaults.set(2, forKey: StreamTuning.encoderMaxInFlightKey)
        XCTAssertEqual(StreamTuning.resolve(defaults: defaults).encoderMaxInFlight, 2)
    }

    func testRuntimeSwitchIsRecordedInTheLiveSummary() {
        let before = NewestFrameWinsSwitch.isOn
        let stored = UserDefaults.standard.object(forKey: NewestFrameWinsSwitch.defaultsKey)
        defer {
            NewestFrameWinsSwitch.isOn = before
            if stored == nil { UserDefaults.standard.removeObject(forKey: NewestFrameWinsSwitch.defaultsKey) }
        }
        NewestFrameWinsSwitch.isOn = true
        XCTAssertEqual(StreamTuning.tuned.liveSummary, StreamTuning.tuned.summary)
        NewestFrameWinsSwitch.isOn = false
        XCTAssertTrue(StreamTuning.tuned.liveSummary.hasSuffix(" · newest-frame-wins off"))
        XCTAssertEqual(StreamTuning.legacy.liveSummary, "legacy", "nothing to turn off without a limit")
    }

    func testIdleVideoRefreshDefaultsOnAndIsAnExperimentKey() throws {
        XCTAssertTrue(StreamTuning.tuned.idleVideoRefresh)
        XCTAssertFalse(StreamTuning.legacy.idleVideoRefresh)
        XCTAssertTrue(StreamTuning.experimentKeys.contains(StreamTuning.idleVideoRefreshKey))
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        defaults.set(false, forKey: StreamTuning.idleVideoRefreshKey)
        let off = StreamTuning.resolve(defaults: defaults)
        XCTAssertFalse(off.idleVideoRefresh)
        XCTAssertTrue(off.summary.contains("no idle refresh"), off.summary)
    }
}

final class WiFiStallDetectorTests: XCTestCase {
    private func second(gap: Double, fps: Double = 55, loss: Double? = 0, route: String? = "Direct",
                        hostCaptureGap: Double? = 17, pacer: Double? = 0) -> StreamStatsReport {
        var report = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []),
                                       counters: nil)
        report.route = route
        report.receivedFPS = fps
        report.renderGapMaxMs = gap
        report.packetLossPercent = loss
        report.hostSummaryAgeMs = 100
        report.host = HostStreamSummary(captureFPS: fps, captureGapP90Ms: hostCaptureGap,
                                       captureGapMaxMs: hostCaptureGap, pacerDelayMs: pacer)
        return report
    }

    func testOnceASecondStallsShowTheTipAfterAFullWindow() {
        var detector = WiFiStallDetector()
        XCTAssertFalse(detector.observe(second(gap: 20)), "first motion second establishes continuity")
        for index in 0..<(WiFiStallDetector.window - 1) {
            XCTAssertFalse(detector.observe(second(gap: 105)), "second \(index)")
        }
        XCTAssertNil(detector.tip)
        XCTAssertTrue(detector.observe(second(gap: 110)))
        XCTAssertEqual(detector.tip?.message,
                       "Picture pauses about once a second — Setting AirDrop to Receiving Off on this iPhone can help smooth this.")
    }

    func testStaticLossyRelayAndMacSideSecondsDoNotCount() {
        var detector = WiFiStallDetector()
        for _ in 0..<30 {
            detector.observe(second(gap: 400, fps: 2))
            detector.observe(second(gap: 120, loss: 3))
            detector.observe(second(gap: 120, route: "Relay"))
            detector.observe(second(gap: 120, hostCaptureGap: 60))
            detector.observe(second(gap: 120, pacer: 80))
        }
        XCTAssertTrue(detector.recent.isEmpty)
        XCTAssertNil(detector.tip)
    }

    func testIdleThen120HzBurstsNeverBecomeAnAirDropStallButContinuousSourceStallsDo() {
        var detector = WiFiStallDetector()
        for _ in 0..<30 {
            detector.observe(second(gap: 600, fps: 2, hostCaptureGap: 600))
            // A single source-idle outlier is invisible to P90 but visible to max.
            var burst = second(gap: 450, fps: 66, hostCaptureGap: 8)
            burst.host?.captureGapMaxMs = 450
            detector.observe(burst)
            detector.observe(second(gap: 9, fps: 120, hostCaptureGap: 9))
        }
        XCTAssertNil(detector.tip)
        XCTAssertTrue(detector.recent.isEmpty)
        for _ in 0..<WiFiStallDetector.window { detector.observe(second(gap: 110, fps: 120, hostCaptureGap: 9)) }
        XCTAssertNotNil(detector.tip, "continuous observed source motion with long arrival gaps still reports the pattern")
    }

    func testUnknownStaleAndNonfiniteSourceEvidenceCannotInferAStall() {
        let known = second(gap: 110)
        var unknowns: [StreamStatsReport] = []
        var value = known; value.host?.captureGapMaxMs = nil; unknowns.append(value)
        value = known; value.hostSummaryAgeMs = nil; unknowns.append(value)
        value = known; value.hostSummaryAgeMs = 3_001; unknowns.append(value)
        value = known; value.host?.captureGapMaxMs = .nan; unknowns.append(value)
        value = known; value.renderGapMaxMs = .infinity; unknowns.append(value)
        value = known; value.packetLossPercent = nil; unknowns.append(value)
        value = known; value.host?.pacerDelayMs = nil; unknowns.append(value)
        value = known; value.route = "Route pending"; unknowns.append(value)
        for value in unknowns { XCTAssertNil(WiFiStallDetector.stalled(value)) }
        var detector = WiFiStallDetector()
        for _ in 0...WiFiStallDetector.window { detector.observe(known) }
        XCTAssertNotNil(detector.tip)
        XCTAssertTrue(detector.observe(unknowns[0]))
        XCTAssertNil(detector.tip, "unreported evidence clears an earlier inference")
    }

    func testPausedStatisticsAndBackwardClockBreakTheMotionRun() {
        var detector = WiFiStallDetector()
        for index in 0...WiFiStallDetector.window { detector.observe(second(gap: 110), at: Double(index)) }
        XCTAssertNotNil(detector.tip)
        XCTAssertTrue(detector.observe(second(gap: 600), at: 100), "resume first second cannot inherit an old motion run")
        XCTAssertNil(detector.tip); XCTAssertTrue(detector.recent.isEmpty)
        detector.observe(second(gap: 110), at: 99)
        XCTAssertTrue(detector.recent.isEmpty, "backward time resets continuity")
    }

    func testOccasionalStallsNeverShowAndTheTipClearsWithHysteresis() {
        var detector = WiFiStallDetector()
        for index in 0..<40 { detector.observe(second(gap: index % 3 == 0 ? 110 : 25)) }
        XCTAssertNil(detector.tip, "a third of seconds is below the show threshold")
        for _ in 0..<10 { detector.observe(second(gap: 110)) }
        XCTAssertNotNil(detector.tip)
        for _ in 0..<5 { detector.observe(second(gap: 20)) }
        XCTAssertNotNil(detector.tip, "5 of 10 still stall; it stays up")
        for _ in 0..<3 { detector.observe(second(gap: 20)) }
        XCTAssertNil(detector.tip, "2 of the last 10 stall; it clears")
        detector.observe(second(gap: 110))
        detector.reset()
        XCTAssertTrue(detector.recent.isEmpty)
    }
}
