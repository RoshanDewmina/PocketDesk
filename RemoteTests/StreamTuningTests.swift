import XCTest
import WebRTC

final class StreamTuningTests: XCTestCase {
    func testTunedPolicySelectsLowLatencyPlayoutThroughTheReceiverFieldTrial() {
        XCTAssertEqual(StreamTuning.tuned.fieldTrials["WebRTC-ForcePlayoutDelay"], "min_ms:0,max_ms:0")
        XCTAssertTrue(StreamTuning.legacy.fieldTrials.isEmpty)
        XCTAssertEqual(StreamTuning.legacy.summary, "legacy")
        XCTAssertTrue(StreamTuning.tuned.summary.contains("playout 0-0ms"))
    }

    func testSharperRaisesTheBitrateNotJustThePixels() {
        let pixelRatio = Double(StreamQuality.sharp.maximumDimension * StreamQuality.sharp.maximumDimension)
            / Double(StreamQuality.balanced.maximumDimension * StreamQuality.balanced.maximumDimension)
        let bitrateRatio = Double(StreamQuality.sharp.maximumBitrateBps) / Double(StreamQuality.balanced.maximumBitrateBps)
        XCTAssertGreaterThanOrEqual(bitrateRatio, pixelRatio, "bits per pixel must not fall in Sharper")
        XCTAssertGreaterThan(StreamQuality.sharp.startBitrateBps, StreamQuality.balanced.startBitrateBps)
        for quality in StreamQuality.allCases {
            XCTAssertLessThan(quality.startBitrateBps, quality.maximumBitrateBps)
            XCTAssertGreaterThan(quality.startBitrateBps, 300_000, "start above libwebrtc's 300 kbps default")
        }
    }

    func testCaptureDisplayLatencyUsesMachTicksAndRejectsImplausibleValues() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let now = mach_absolute_time()
        let tenMs = UInt64(10_000_000) * UInt64(timebase.denom) / UInt64(timebase.numer)
        let latency = CaptureTiming.displayLatencyMs(displayTime: now - tenMs, now: now)
        XCTAssertEqual(latency ?? -1, 10, accuracy: 0.01)
        XCTAssertNil(CaptureTiming.displayLatencyMs(displayTime: 0, now: now))
        XCTAssertNil(CaptureTiming.displayLatencyMs(displayTime: now + 1, now: now), "future display time")
        XCTAssertNil(CaptureTiming.displayLatencyMs(displayTime: 1, now: now), "stale timestamps are not latencies")
    }

    func testCaptureQueueIsDeeperThanScreenCaptureKitsMinimum() {
        XCTAssertGreaterThan(RemoteCaptureConfiguration.queueDepth, 3)
        XCTAssertLessThanOrEqual(RemoteCaptureConfiguration.queueDepth, 8)
    }
}

final class EncoderRestartPolicyTests: XCTestCase {
    func testSessionStartedAtTheDefaultRateRestartsOnceTheSeededEstimateSettles() {
        var policy = EncoderRestartPolicy()
        policy.sessionStarted(kbps: 300, at: 0)
        policy.updateTarget(kbps: 4_000)
        XCTAssertFalse(policy.shouldRestart(at: 1), "below 5 Mb/s the restart key frame would clog the pacer")
        policy.updateTarget(kbps: 10_000)
        XCTAssertFalse(policy.shouldRestart(at: 1.2), "the estimate may still be ramping")
        policy.updateTarget(kbps: 23_000)
        XCTAssertFalse(policy.shouldRestart(at: 1.6))
        XCTAssertTrue(policy.shouldRestart(at: 2.0))
        XCTAssertEqual(policy.baselineKbps, 23_000, "the new session starts at the settled rate")
        XCTAssertFalse(policy.shouldRestart(at: 3))
        XCTAssertEqual(policy.restarts, 1)
    }

    func testRecoveryFromABandwidthDipRestartsButRepeatsAreSpaced() {
        var policy = EncoderRestartPolicy()
        policy.sessionStarted(kbps: 10_000, at: 0)
        policy.updateTarget(kbps: 3_000)
        policy.updateTarget(kbps: 9_000)
        XCTAssertFalse(policy.shouldRestart(at: 5))
        XCTAssertTrue(policy.shouldRestart(at: 5.8), "a dip to 3 Mb/s left the session starved; 9 Mb/s is 3x that")
        policy.updateTarget(kbps: 2_000)
        policy.updateTarget(kbps: 9_000)
        XCTAssertFalse(policy.shouldRestart(at: 10))
        XCTAssertFalse(policy.shouldRestart(at: 20), "repeat restarts wait 15 s")
        XCTAssertTrue(policy.shouldRestart(at: 21))
    }

    func testOscillatingEstimateCannotCauseKeyFrameStorms() {
        var policy = EncoderRestartPolicy()
        policy.sessionStarted(kbps: 300, at: 0)
        var restarts = 0
        for step in 0..<120 {
            policy.updateTarget(kbps: step.isMultiple(of: 2) ? 2_000 : 8_000)
            if policy.shouldRestart(at: 1 + Double(step) * 0.5) { restarts += 1 }
        }
        XCTAssertEqual(restarts, 0, "a 2<->8 Mb/s estimate never stays eligible long enough to restart")
    }

    func testBriefSpikeDoesNotRestart() {
        var policy = EncoderRestartPolicy()
        policy.sessionStarted(kbps: 2_000, at: 0)
        policy.updateTarget(kbps: 9_000)
        XCTAssertFalse(policy.shouldRestart(at: 1))
        policy.updateTarget(kbps: 3_000)
        XCTAssertFalse(policy.shouldRestart(at: 1.5))
        policy.updateTarget(kbps: 9_000)
        XCTAssertFalse(policy.shouldRestart(at: 1.9), "eligibility restarts after the dip")
        XCTAssertTrue(policy.shouldRestart(at: 2.7))
    }
}

final class BandwidthSeedPolicyTests: XCTestCase {
    func testSeedWaitsForTheSecondDirectSampleAndRetriesOnceIfProbesOverwroteIt() {
        var policy = BandwidthSeedPolicy()
        XCTAssertFalse(policy.observe(route: "Route pending", estimateKbps: 300, lossPercent: nil, seedKbps: 10_000))
        XCTAssertFalse(policy.observe(route: "Direct", estimateKbps: 300, lossPercent: nil, seedKbps: 10_000),
                       "initial probes may still be in flight")
        XCTAssertTrue(policy.observe(route: "Direct", estimateKbps: 300, lossPercent: nil, seedKbps: 10_000))
        XCTAssertTrue(policy.observe(route: "Direct", estimateKbps: 1_800, lossPercent: 0, seedKbps: 10_000),
                      "a probe result replaced the seed without any loss")
        XCTAssertFalse(policy.observe(route: "Direct", estimateKbps: 1_800, lossPercent: 0, seedKbps: 10_000))
    }

    func testNoRetryWhenTheSeedHeldOrThePathReportsLoss() {
        var held = BandwidthSeedPolicy()
        _ = held.observe(route: "Direct", estimateKbps: 300, lossPercent: nil, seedKbps: 10_000)
        XCTAssertTrue(held.observe(route: "Direct", estimateKbps: 300, lossPercent: nil, seedKbps: 10_000))
        XCTAssertFalse(held.observe(route: "Direct", estimateKbps: 9_000, lossPercent: 0, seedKbps: 10_000))
        XCTAssertFalse(held.observe(route: "Direct", estimateKbps: 1_000, lossPercent: 0, seedKbps: 10_000), "only one check")

        var lossy = BandwidthSeedPolicy()
        _ = lossy.observe(route: "Direct", estimateKbps: 300, lossPercent: nil, seedKbps: 10_000)
        XCTAssertTrue(lossy.observe(route: "Direct", estimateKbps: 300, lossPercent: nil, seedKbps: 10_000))
        XCTAssertFalse(lossy.observe(route: "Direct", estimateKbps: 2_000, lossPercent: 4, seedKbps: 10_000),
                       "a lossy path keeps the lower estimate")
    }

    func testRelayRoutesAreNeverSeeded() {
        var policy = BandwidthSeedPolicy()
        for _ in 0..<5 { XCTAssertFalse(policy.observe(route: "Relay", estimateKbps: 300, lossPercent: nil, seedKbps: 10_000)) }
    }
}

final class HostStreamSummaryProtocolTests: XCTestCase {
    private var summary: HostStreamSummary {
        HostStreamSummary(captureFPS: 59.8, captureLatencyMs: 7.5, captureGapP90Ms: 18, pushSkipped: 0,
                          droppedBeforeEncode: 1, encodedFPS: 59.8, encodeMs: 9.4, pacerDelayMs: 1.2,
                          sentFPS: 59.8, sentKbps: 4_200, targetKbps: 17_000, maxKbps: 20_000, qpAverage: 30,
                          sentWidth: 2560, sentHeight: 1664, encoder: "VideoToolbox", hardwareEncoder: true,
                          qualityLimitation: "none")
    }

    func testSummaryTravelsOnlyWithCaptureStatusAndOldPayloadsStillDecode() throws {
        let action = RemoteAction(action: "capture", x: 1, hostStream: summary)
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(action))
        XCTAssertEqual(decoded.hostStream, summary)
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertThrowsError(try RemoteAction(action: "move", hostStream: summary).validate())
        let legacy = try JSONDecoder().decode(RemoteAction.self, from: Data(#"{"action":"capture","x":1,"y":0,"text":"","key":"","modifiers":[],"epoch":1}"#.utf8))
        XCTAssertNil(legacy.hostStream)
    }

    func testSummaryRejectsUnboundedValues() {
        var bad = summary
        bad.encodeMs = .infinity
        XCTAssertThrowsError(try bad.validate())
        bad = summary
        bad.encoder = String(repeating: "x", count: 200)
        XCTAssertThrowsError(try bad.validate())
        bad = summary
        bad.sentWidth = -1
        XCTAssertThrowsError(try bad.validate())
    }

    func testPhoneReportShowsBothEndsAndAStageSum() {
        let entries = [StreamStatsEntry(id: "IT1", type: "inbound-rtp", values: ["kind": "video" as NSString])]
        var report = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: entries), counters: nil)
        report.host = summary
        report.rttMs = 6
        report.jitterBufferMs = 2
        report.decodeMs = 3
        report.presentLatencyMs = 4
        XCTAssertEqual(report.estimatedDisplayToDrawMs ?? 0, 7.5 + 9.4 + 1.2 + 3 + 2 + 3 + 4, accuracy: 0.05)
        XCTAssertTrue(report.summaryLines.contains { $0.hasPrefix("Mac encode") })
        XCTAssertTrue(report.summaryLines.contains { $0.contains("Mac display → phone draw") })
    }
}

@MainActor
final class NativeSenderTuningTests: XCTestCase {
    func testHostSenderCarriesTheModeCeilingAndFollowsQualityChanges() async throws {
        let host = PeerMedia(isHost: true, servers: [])
        let phone = PeerMedia(isHost: false, servers: [])
        defer { host.close(); phone.close() }
        host.onSignal = { [weak phone] in phone?.receive($0) }
        phone.onSignal = { [weak host] in host?.receive($0) }
        var connected = false
        host.onState = { if $0 == "connected" { connected = true } }
        host.applyStreamQuality(.balanced)
        host.offer()
        let deadline = Date().addingTimeInterval(15)
        while !connected, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(connected)
        let expected = host.tuning.qualityBitrates ? Double(StreamQuality.balanced.maximumBitrateBps) / 1000 : 12_000
        XCTAssertEqual(host.appliedSenderMaxKbps, expected)
        if host.tuning.degradationPreference != nil {
            XCTAssertEqual(host.appliedDegradationPreference, host.tuning.degradationPreference)
        }
        host.applyStreamQuality(.sharp)
        if host.tuning.qualityBitrates {
            XCTAssertEqual(host.appliedSenderMaxKbps, Double(StreamQuality.sharp.maximumBitrateBps) / 1000)
        }
        XCTAssertNil(phone.appliedSenderMaxKbps, "the phone does not send video")
    }
}
