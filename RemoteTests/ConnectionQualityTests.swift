import Network
import XCTest

final class ConnectionQualityMonitorTests: XCTestCase {
    /// Feeds one mark per second; `lossPercent` of each window's 180 frames never arrive.
    private struct Feed {
        var monitor = ConnectionQualityMonitor()
        var host = 0
        var phone = 0
        var now = 100.0
        var transitions = 0

        mutating func second(fps: Int = 60, lossPercent: Double = 0, pipelineMs: Double? = nil, rtt: Double? = nil) {
            host += fps
            phone += fps - Int((Double(fps) * lossPercent / 100).rounded())
            now += 1
            let mark = FrameMark(hostEncoded: host, phoneArrived: phone, at: now)
            if monitor.observe(ConnectionQualitySample(at: now + 0.2, mark: mark, pipelineMs: pipelineMs, rttSampleMs: rtt)) {
                transitions += 1
            }
        }

        mutating func window(fps: Int = 60, lossPercent: Double) {
            for _ in 0..<3 { second(fps: fps, lossPercent: lossPercent) }
        }

        /// Opening mark plus the ignored settle window.
        mutating func settle() {
            second()
            window(lossPercent: 0)
        }
    }

    func testTheFirstMeasuredWindowIsIgnored() {
        var feed = Feed()
        feed.second()
        feed.window(lossPercent: 50)
        XCTAssertEqual(feed.monitor.level, .ok)
        XCTAssertNil(feed.monitor.lastLossPercent)
        feed.window(lossPercent: 50)
        XCTAssertEqual(feed.monitor.level, .poor)
    }

    func testThirtyPercentInOneWindowIsPoor() {
        var feed = Feed()
        feed.settle()
        feed.window(lossPercent: 29)
        XCTAssertEqual(feed.monitor.level, .ok)
        feed.window(lossPercent: 30)
        XCTAssertEqual(feed.monitor.level, .poor)
        XCTAssertEqual(feed.monitor.poorEntries, 1)
    }

    func testFifteenPercentTwiceInARowIsPoorButNotAfterACleanerWindow() {
        var feed = Feed()
        feed.settle()
        feed.window(lossPercent: 15)
        XCTAssertEqual(feed.monitor.level, .ok)
        feed.window(lossPercent: 10)
        XCTAssertEqual(feed.monitor.level, .ok)
        feed.window(lossPercent: 15)
        feed.window(lossPercent: 16)
        XCTAssertEqual(feed.monitor.level, .poor)
    }

    func testUnmeasuredWindowsAreSkippedLikeMoonlight() {
        var feed = Feed()
        feed.settle()
        feed.window(lossPercent: 20)
        feed.window(fps: 10, lossPercent: 0)
        XCTAssertEqual(feed.monitor.level, .ok)
        feed.window(lossPercent: 20)
        XCTAssertEqual(feed.monitor.level, .poor, "an unmeasured window between two 20 % windows keeps them consecutive")
    }

    func testItClearsAtFivePercentAndHoldsInBetween() {
        var feed = Feed()
        feed.settle()
        feed.window(lossPercent: 40)
        XCTAssertEqual(feed.monitor.level, .poor)
        for loss in [29.0, 12, 6] {
            feed.window(lossPercent: loss)
            XCTAssertEqual(feed.monitor.level, .poor, "\(loss) % holds")
        }
        feed.window(lossPercent: 5)
        XCTAssertEqual(feed.monitor.level, .ok)
    }

    func testAStillPictureClearsPoorAfterAQuietSpell() {
        var feed = Feed()
        feed.settle()
        feed.window(lossPercent: 40)
        for _ in 0..<9 { feed.second(fps: 0) }
        XCTAssertEqual(feed.monitor.level, .poor)
        feed.second(fps: 0)
        feed.second(fps: 0)
        XCTAssertEqual(feed.monitor.level, .ok)
    }

    func testThePreviousWindowExpiresAcrossAStillStretch() {
        var feed = Feed()
        feed.settle()
        feed.window(lossPercent: 16)
        for _ in 0..<60 { feed.second(fps: 0) }
        feed.window(lossPercent: 16)
        XCTAssertEqual(feed.monitor.level, .ok, "two scroll-starts a minute apart are not two in a row")
        feed.window(lossPercent: 16)
        XCTAssertEqual(feed.monitor.level, .poor)
    }

    func testTooFewFramesIsUnmeasured() {
        var feed = Feed()
        feed.settle()
        feed.window(fps: 19, lossPercent: 50)
        XCTAssertEqual(feed.monitor.level, .ok)
        XCTAssertEqual(feed.monitor.measuredWindows, 0)
    }

    func testACounterGoingBackwardsOrALongGapResettles() {
        var feed = Feed()
        feed.settle()
        feed.host = 0; feed.phone = 0
        feed.window(lossPercent: 50)
        XCTAssertEqual(feed.monitor.level, .ok, "the backward mark restarts and the next window settles")
        feed.window(lossPercent: 50)
        feed.window(lossPercent: 50)
        XCTAssertEqual(feed.monitor.level, .poor)

        var gap = Feed()
        gap.settle()
        gap.now += 6
        gap.window(lossPercent: 50)
        XCTAssertEqual(gap.monitor.level, .ok)
    }

    func testARepeatedMarkIsCountedOnce() {
        var monitor = ConnectionQualityMonitor()
        let marks = [FrameMark(hostEncoded: 0, phoneArrived: 0, at: 1)] + (1...7).map {
            FrameMark(hostEncoded: $0 * 60, phoneArrived: $0 * 60, at: 1 + Double($0))
        }
        for mark in marks {
            monitor.observe(ConnectionQualitySample(at: mark.at, mark: mark))
            monitor.observe(ConnectionQualitySample(at: mark.at + 0.5, mark: mark))
        }
        XCTAssertEqual(monitor.measuredWindows, 1)
        XCTAssertEqual(monitor.lastLossPercent, 0)
    }

    func testFramesInFlightAtMotionStartDoNotReachPoorAlone() {
        var monitor = ConnectionQualityMonitor()
        var host = 0, phone = 0
        var at = 0.0
        func mark(_ encoded: Int, _ arrived: Int, pipeline: Double = 80) {
            host += encoded; phone += arrived; at += 1
            monitor.observe(ConnectionQualitySample(at: at, mark: FrameMark(hostEncoded: host, phoneArrived: phone, at: at),
                                                    pipelineMs: pipeline))
        }
        mark(0, 0)
        for _ in 0..<3 { mark(60, 60) }
        for _ in 0..<12 { mark(0, 0) }
        mark(0, 0)
        mark(20, 14)
        mark(60, 60)
        mark(60, 60)
        XCTAssertEqual(monitor.level, .ok)
        XCTAssertLessThan(monitor.lastLossPercent ?? 100, 30)
    }

    func testAlternatingModerateLossNeverFlickers() {
        var feed = Feed()
        feed.settle()
        for index in 0..<20 { feed.window(lossPercent: index % 2 == 0 ? 12 : 8) }
        XCTAssertEqual(feed.transitions, 0)
        XCTAssertEqual(feed.monitor.level, .ok)
    }

    func testNoisyLossChangesStateLessThanOnceEveryTwoWindows() {
        var feed = Feed()
        feed.settle()
        var generator = SeededGenerator(seed: 42)
        let windows = 100
        for _ in 0..<windows { feed.window(lossPercent: Double(Int.random(in: 0...40, using: &generator))) }
        XCTAssertLessThan(feed.transitions, windows / 2)
    }

    func testResetStartsOver() {
        var feed = Feed()
        feed.settle()
        feed.window(lossPercent: 40)
        XCTAssertTrue(feed.monitor.isPoor)
        feed.monitor.reset()
        XCTAssertEqual(feed.monitor.level, .ok)
        feed.second()
        feed.window(lossPercent: 40)
        XCTAssertEqual(feed.monitor.level, .ok, "the first window after a reset settles")
    }

    func testNoMarksMeansNoVerdict() {
        var monitor = ConnectionQualityMonitor()
        for second in 0..<30 { monitor.observe(ConnectionQualitySample(at: Double(second), rttSampleMs: 20)) }
        XCTAssertEqual(monitor.level, .ok)
        XCTAssertNil(monitor.lastLossPercent)
    }

    // MARK: Round trip

    private func roundTrips(_ values: [Double], into monitor: inout ConnectionQualityMonitor, from start: Double = 0) {
        for (index, value) in values.enumerated() {
            monitor.observe(ConnectionQualitySample(at: start + Double(index), rttSampleMs: value))
        }
    }

    func testRoundTripNeedsTwoSlowWindowsOrOneVerySlowOne() {
        var monitor = ConnectionQualityMonitor()
        roundTrips([160, 160, 160, 160], into: &monitor)
        XCTAssertNil(monitor.slowRoundTripMs)
        roundTrips([160, 160, 160], into: &monitor, from: 4)
        XCTAssertEqual(monitor.slowRoundTripMs, 160)

        var spike = ConnectionQualityMonitor()
        roundTrips([320, 320, 320, 320], into: &spike)
        XCTAssertEqual(spike.slowRoundTripMs, 320)
    }

    func testRoundTripHoldsBetweenTheThresholdsAndClearsAt110() {
        var monitor = ConnectionQualityMonitor()
        roundTrips([320, 320, 320, 320], into: &monitor)
        roundTrips([130, 130, 130], into: &monitor, from: 4)
        XCTAssertEqual(monitor.slowRoundTripMs, 130, "the hold band keeps it slow")
        roundTrips([110, 110, 110], into: &monitor, from: 7)
        XCTAssertNil(monitor.slowRoundTripMs)
    }

    func testStaleRoundTripsBecomeUnmeasuredAndRestartTheWindow() {
        var monitor = ConnectionQualityMonitor()
        roundTrips([320, 320, 320, 320], into: &monitor)
        XCTAssertNotNil(monitor.slowRoundTripMs)
        monitor.observe(ConnectionQualitySample(at: 14))
        XCTAssertNil(monitor.slowRoundTripMs)
        XCTAssertNil(monitor.roundTripSpreadMs)
        roundTrips([160, 160, 160, 160], into: &monitor, from: 15)
        XCTAssertNil(monitor.slowRoundTripMs, "a new slow window cannot pair with an expired one")
    }

    func testRoundTripSpreadUsesOnlyFreshSamples() {
        var monitor = ConnectionQualityMonitor()
        for (index, value) in [40.0, 60, 40, 60].enumerated() {
            monitor.observe(ConnectionQualitySample(at: Double(index), rttSampleMs: value))
            monitor.observe(ConnectionQualitySample(at: Double(index) + 0.5))
        }
        XCTAssertEqual(monitor.roundTripSpreadMs, 10)
    }
}

final class ConnectionQualityCauseTests: XCTestCase {
    private let cellular = NetworkLinkHint.from(NetworkLinkReading(cellular: true))
    private let hotspot = NetworkLinkHint.from(NetworkLinkReading(expensive: true, wifi: true))
    private let weak = NetworkLinkHint.from(NetworkLinkReading(quality: .minimal, wifi: true))

    func testOneObservedConditionInPriorityOrder() {
        XCTAssertEqual(ConnectionQualityCause.pick(routeDetail: "relay", phoneLink: cellular, macLink: "wifi"), .relay)
        XCTAssertEqual(ConnectionQualityCause.pick(routeDetail: "lan", phoneLink: cellular, macLink: "wifi"), .phoneCellular)
        XCTAssertEqual(ConnectionQualityCause.pick(routeDetail: "lan", phoneLink: weak, macLink: "wifi"), .phoneWeakWiFi)
        XCTAssertEqual(ConnectionQualityCause.pick(routeDetail: "lan", phoneLink: nil, macLink: "wifi"), .macOnWiFi)
        XCTAssertEqual(ConnectionQualityCause.pick(routeDetail: "lan", phoneLink: nil, macLink: "wired"), .unknown)
        XCTAssertEqual(ConnectionQualityCause.pick(routeDetail: "lan", phoneLink: hotspot, macLink: nil), .unknown,
                       "a hotspot is metered, not cellular on this device")
    }

    func testTheMacsWiFiIsNeverNamedOffTheLocalNetwork() {
        XCTAssertEqual(ConnectionQualityCause.pick(routeDetail: "p2p", phoneLink: nil, macLink: "wifi"), .unknown)
        XCTAssertEqual(ConnectionQualityCause.pick(routeDetail: nil, phoneLink: nil, macLink: "wifi"), .unknown)
    }

    func testVerdictCopyIsOneFactOneFix() {
        let verdict = ConnectionQualityVerdict(cause: .macOnWiFi, lossPercent: 32)
        XCTAssertEqual(verdict.title(device: "iPhone"), "Your Mac is on Wi-Fi")
        XCTAssertEqual(verdict.fix, "An Ethernet cable on your Mac can help steady the picture.")
        XCTAssertEqual(verdict.detail, "32% of frames did not reach the picture in the last measured window.")
        XCTAssertTrue(ConnectionQualityVerdict(cause: .unknown, lossPercent: 40).detail.hasSuffix("The cause is unknown."))
        XCTAssertEqual(ConnectionQualityCause.phoneWeakWiFi.title(device: "iPad"), "This iPad’s Wi-Fi is weak")
    }
}

/// Every user-facing sentence this package can show, enumerated through the API.
final class ConnectionQualityCopyTests: XCTestCase {
    private var sentences: [String] {
        var all: [String] = []
        for device in ["iPhone", "iPad"] {
            for cause in ConnectionQualityCause.allCases {
                let verdict = ConnectionQualityVerdict(cause: cause, lossPercent: 30)
                all += [verdict.title(device: device), verdict.fix, verdict.detail]
            }
            for wired in [false, true] {
                for guidance in [WiFiStallTip.Guidance.settings, .causeOnly] {
                    let tip = WiFiStallTip(macWired: wired, guidance: guidance)
                    all += [tip.title, tip.observation, tip.fix(device: device), tip.secondary(device: device) ?? ""]
                }
            }
        }
        let readings = [NetworkLinkReading(ultraConstrained: true), NetworkLinkReading(quality: .minimal, wifi: true),
                        NetworkLinkReading(cellular: true), NetworkLinkReading(expensive: true)]
        for hint in readings.compactMap(NetworkLinkHint.from) { all += [hint.title, hint.detail, hint.nextStep] }
        return all.filter { !$0.isEmpty }
    }

    func testNothingEverSaysToTurnWiFiOff() throws {
        let forbidden = try NSRegularExpression(pattern: "turn(ing)? off wi-?fi|disable wi-?fi|wi-?fi off|awdl",
                                                options: .caseInsensitive)
        for sentence in sentences {
            XCTAssertNil(forbidden.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)), sentence)
        }
    }

    func testEachFixIsOneSentence() {
        for cause in ConnectionQualityCause.allCases {
            XCTAssertEqual(cause.fix.filter { $0 == "." }.count, 1, cause.fix)
        }
        for wired in [false, true] {
            for guidance in [WiFiStallTip.Guidance.settings, .causeOnly] {
                let fix = WiFiStallTip(macWired: wired, guidance: guidance).fix(device: "iPhone")
                XCTAssertEqual(fix.filter { $0 == "." }.count, 1, fix)
            }
        }
    }
}

final class MacNetworkLinkTests: XCTestCase {
    private let interfaces = [LocalPathInterface(name: "en0", index: 4, type: .wiredEthernet),
                              LocalPathInterface(name: "en1", index: 5, type: .wifi),
                              LocalPathInterface(name: "utun3", index: 20, type: .other)]
    private let addresses: [(name: String, address: String)] = [("en0", "192.168.1.20"), ("en1", "192.168.1.21"),
                                                                ("en1", "fe80::1c2b:3a4d:5e6f:7081%en1"),
                                                                ("utun3", "10.8.0.2")]

    func testTheHostCandidateAddressNamesTheInterfaceType() {
        XCTAssertEqual(MacNetworkLink.resolve(localAddress: "192.168.1.20", candidateType: "host",
                                              addresses: addresses, interfaces: interfaces), .wired,
                       "en0 is Ethernet on a Mac mini")
        XCTAssertEqual(MacNetworkLink.resolve(localAddress: "192.168.1.21", candidateType: "host",
                                              addresses: addresses, interfaces: interfaces), .wifi)
        XCTAssertEqual(MacNetworkLink.resolve(localAddress: "[FE80::1C2B:3A4D:5E6F:7081]", candidateType: "host",
                                              addresses: addresses, interfaces: interfaces), .wifi)
        XCTAssertEqual(MacNetworkLink.resolve(localAddress: "10.8.0.2", candidateType: "host",
                                              addresses: addresses, interfaces: interfaces), .other)
    }

    func testOnlyAKnownHostCandidateResolves() {
        XCTAssertNil(MacNetworkLink.resolve(localAddress: "203.0.113.9", candidateType: "srflx",
                                            addresses: addresses, interfaces: interfaces))
        XCTAssertNil(MacNetworkLink.resolve(localAddress: "192.168.1.21", candidateType: "relay",
                                            addresses: addresses, interfaces: interfaces))
        XCTAssertNil(MacNetworkLink.resolve(localAddress: "192.168.9.9", candidateType: "host",
                                            addresses: addresses, interfaces: interfaces))
        XCTAssertNil(MacNetworkLink.resolve(localAddress: nil, candidateType: "host",
                                            addresses: addresses, interfaces: interfaces))
    }
}

final class ResumeTimingTests: XCTestCase {
    func testAHeldReturnMeasuresUntilANewFrameOnAnActiveScreen() {
        var timing = ResumeTiming()
        timing.begin(.held, at: 10, sceneActive: false)
        XCTAssertNil(timing.frame(at: 10.25))
        let result = timing.sceneActive(at: 10.5)
        XCTAssertEqual(result, ResumeTiming.Measurement(kind: .held, fellBack: false, totalMs: 500, afterActiveMs: 0, settledMs: nil))
        XCTAssertFalse(timing.isOpen)
        XCTAssertNil(timing.frame(at: 11), "reported once")
    }

    func testAFrameAfterActiveCountsAsVisibleWait() {
        var timing = ResumeTiming()
        timing.begin(.held, at: 10, sceneActive: false)
        XCTAssertNil(timing.sceneActive(at: 10.3))
        XCTAssertEqual(timing.frame(at: 10.9)?.afterActiveMs, 600)
    }

    func testAFrameFromBeforeTheReturnIsIgnored() {
        var timing = ResumeTiming()
        timing.begin(.held, at: 10, sceneActive: true)
        XCTAssertNil(timing.frame(at: 9.9))
        XCTAssertEqual(timing.frame(at: 10.2)?.totalMs, 200)
    }

    func testAReconnectWaitsForTheViewToSettle() {
        var timing = ResumeTiming()
        timing.begin(.reconnect, at: 0, sceneActive: true)
        XCTAssertNil(timing.frame(at: 1.8))
        let result = timing.settled(at: 2.1)
        XCTAssertEqual(result?.totalMs, 1800)
        XCTAssertEqual(result?.settledMs, 2100)
        XCTAssertEqual(result?.summary, "1.8 s · reconnected")
    }

    func testAFallBackKeepsTheStartAndNeedsANewFrame() {
        var timing = ResumeTiming()
        timing.begin(.held, at: 0, sceneActive: true)
        timing.fellBack(at: 5)
        XCTAssertNil(timing.frame(at: 7))
        let result = timing.settled(at: 7.5)
        XCTAssertEqual(result?.totalMs, 7000)
        XCTAssertEqual(result?.fellBack, true)
        XCTAssertEqual(result?.summary, "7.0 s · reconnected after the held session stopped answering")
    }

    func testCancelAndCeiling() {
        var timing = ResumeTiming()
        timing.begin(.manual, at: 0, sceneActive: true)
        timing.cancel(.leftAgain)
        XCTAssertNil(timing.frame(at: 1))
        timing.begin(.manual, at: 0, sceneActive: true)
        XCTAssertFalse(timing.expire(at: 59))
        XCTAssertTrue(timing.expire(at: 61))
        XCTAssertFalse(timing.isOpen)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class ConnectionQualityWireTests: XCTestCase {
    func testOlderMacsDecodeWithoutQualityFieldsAndLargeTotalsRoundTrip() throws {
        let old = try JSONDecoder().decode(HostStreamSummary.self, from: Data("{}".utf8))
        XCTAssertNil(old.framesEncodedTotal)
        XCTAssertNil(old.macLink)
        try old.validate()
        let new = HostStreamSummary(framesEncodedTotal: 4_000_000, macLink: "wifi")
        try new.validate()
        XCTAssertEqual(try JSONDecoder().decode(HostStreamSummary.self, from: JSONEncoder().encode(new)), new)
        XCTAssertThrowsError(try HostStreamSummary(framesEncodedTotal: -1).validate())
        XCTAssertThrowsError(try HostStreamSummary(framesEncodedTotal: HostStreamSummary.maximumFrameTotal + 1).validate())
        for bad in ["wireless-long", "mystery"] { XCTAssertThrowsError(try HostStreamSummary(macLink: bad).validate()) }
    }

    func testSuccessfulEncodeAndRendererTotalsSurviveDrainAndLatencyTraceAbsence() {
        let counters = StreamCounters()
        counters.encodedFrameAccepted()
        counters.rendered(at: 1)
        _ = counters.drain(inputBufferedBytes: nil, at: 2)
        XCTAssertEqual(counters.encodedTotal, 1)
        XCTAssertEqual(counters.arrivedTotal, 1)
        counters.encoded(latencyMs: 8, bytes: 50, isKeyFrame: false, inFlight: 1)
        XCTAssertEqual(counters.encodedTotal, 1, "a latency sample does not count another output")
        counters.encodedFrameAccepted()
        counters.rendered(at: 3)
        _ = counters.drain(inputBufferedBytes: nil, at: 4)
        XCTAssertEqual(counters.encodedTotal, 2)
        XCTAssertEqual(counters.arrivedTotal, 2)
    }

    func testRoundTripUsesNewResponsesAndRejectsAChangedPair() {
        func sample(id: String = "pair", at: Double, total: Double, replies: Int) -> StreamStatsSample {
            StreamStatsSample(entries: [
                StreamStatsEntry(id: "transport", type: "transport", values: ["selectedCandidatePairId": id], timestamp: at),
                StreamStatsEntry(id: id, type: "candidate-pair", values: ["totalRoundTripTime": total,
                    "responsesReceived": replies, "currentRoundTripTime": 0.900], timestamp: at)
            ])
        }
        let a = sample(at: 1, total: 1, replies: 10)
        let b = sample(at: 2, total: 1.060, replies: 12)
        XCTAssertEqual(StreamStatsReport(role: "phone", previous: a, current: b, counters: nil).rttSampleMs, 30)
        let duplicate = sample(at: 3, total: 1.060, replies: 12)
        XCTAssertNil(StreamStatsReport(role: "phone", previous: b, current: duplicate, counters: nil).rttSampleMs)
        let changed = sample(id: "new-pair", at: 3, total: 5, replies: 20)
        XCTAssertNil(StreamStatsReport(role: "phone", previous: b, current: changed, counters: nil).rttSampleMs)
    }

    func testAStaleHostSummaryDoesNotProduceAMark() {
        var report = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []), counters: nil)
        report.hostFramesEncodedTotal = 100
        report.framesArrivedAtMark = 90
        report.frameMarkAt = 1
        report.hostSummaryAgeMs = 5_001
        XCTAssertNil(ConnectionQualitySample(report, at: 7).mark)
        report.hostSummaryAgeMs = 20
        XCTAssertEqual(ConnectionQualitySample(report, at: 2).mark?.phoneArrived, 90)
    }

    func testStallGuidanceNamesTheMacOnlyOnAKnownWiFiLAN() {
        var report = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []), counters: nil)
        report.host = HostStreamSummary(macLink: "wifi")
        report.routeDetail = "p2p"
        XCTAssertTrue(WiFiStallTip.observed(report).fix(device: "iPad").contains("this iPad"))
        report.routeDetail = "lan"
        XCTAssertTrue(WiFiStallTip.observed(report).fix(device: "iPhone").contains("your Mac"))
        report.host?.macLink = "wired"
        XCTAssertTrue(WiFiStallTip.observed(report).fix(device: "iPhone").contains("this iPhone"))
        XCTAssertTrue(WiFiStallTip(macWiFi: true, guidance: .causeOnly).fix.contains("Ethernet"))
    }

    func testLateFramesNeverReportBeyondTheResumeCeiling() {
        var timing = ResumeTiming()
        timing.begin(.held, at: 0, sceneActive: true)
        XCTAssertNil(timing.frame(at: 61))
        XCTAssertTrue(timing.expire(at: 61))
        timing.begin(.held, at: 100, sceneActive: false)
        timing.cancel(.leftAgain)
        XCTAssertNil(timing.sceneActive(at: 100.2))
        XCTAssertNil(timing.frame(at: 100.3))
    }
}
