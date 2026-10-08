import XCTest

final class StreamStatisticsTests: XCTestCase {
    func testPhoneRenderStagesExposeObservedPercentilesCountsAndDrain() throws {
        let counters = StreamCounters(phoneRenderTimingEnabled: true)
        for index in 1...100 {
            let ms = Double(index)
            counters.phoneDecodeTrace(PhoneDecodeTrace(submitMs: 100, callbackMs: 100 + ms,
                ownershipMs: 100 + ms * 2, deliveryMs: 100 + ms * 3))
            for metric in [PhoneRenderTimingMetric.decodedToPresented, .deliveryToPresented, .commitToPresented,
                           .drawableAcquire, .rendererFenceWait, .displayLinkInterval, .leadingMotionLatency] {
                counters.phoneRenderTiming(metric, milliseconds: ms)
            }
        }
        counters.phoneRenderTiming(.drawableAcquire, milliseconds: .nan)
        counters.phoneRenderTiming(.displayLinkInterval, milliseconds: -1)
        counters.phoneDecodeTrace(PhoneDecodeTrace(submitMs: 4, callbackMs: 3, ownershipMs: 5, deliveryMs: 6))
        var snapshot = counters.drain(inputBufferedBytes: nil)
        snapshot.interval = 1
        let report = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []), counters: snapshot)
        XCTAssertEqual(report.decodeVTP95Ms, 95)
        XCTAssertEqual(report.decodeVTSamples, 100)
        XCTAssertEqual(report.ownershipDelayP99Ms, 99)
        XCTAssertEqual(report.ownershipDelaySamples, 100)
        XCTAssertEqual(report.deliveryDelayP99Ms, 198, "delivery delay starts at callback entry")
        XCTAssertEqual(report.deliveryDelaySamples, 100)
        XCTAssertEqual(report.decodedToPresentedP95Ms, 95)
        XCTAssertEqual(report.decodedToPresentedSamples, 100)
        XCTAssertEqual(report.deliveryToPresentedP95Ms, 95)
        XCTAssertEqual(report.deliveryToPresentedSamples, 100)
        XCTAssertEqual(report.commitToPresentedP50Ms, 50)
        XCTAssertEqual(report.commitToPresentedP95Ms, 95)
        XCTAssertEqual(report.commitToPresentedSamples, 100)
        XCTAssertEqual(report.drawableAcquireP99Ms, 99)
        XCTAssertEqual(report.drawableAcquireSamples, 100)
        XCTAssertEqual(report.rendererFenceWaitP99Ms, 99)
        XCTAssertEqual(report.rendererFenceWaitSamples, 100)
        XCTAssertEqual(report.displayLinkIntervalP50Ms, 50)
        XCTAssertEqual(report.displayLinkIntervalP95Ms, 95)
        XCTAssertEqual(report.displayLinkIntervalSamples, 100)
        XCTAssertEqual(report.displayLinkAt120Share, 0.09)
        XCTAssertEqual(report.leadingMotionLatencyP95Ms, 95)
        XCTAssertEqual(report.leadingMotionLatencySamples, 100)
        XCTAssertEqual(try JSONDecoder().decode(StreamStatsReport.self, from: JSONEncoder().encode(report)), report)
        let next = counters.drain(inputBufferedBytes: nil)
        XCTAssertNil(next.decodeVTP95Ms)
        XCTAssertNil(next.decodeVTSamples)
        XCTAssertNil(next.displayLinkIntervalSamples)
        XCTAssertNil(next.displayLinkAt120Share)
        XCTAssertNil(next.commitToPresentedSamples)
    }

    func testPresentationStageCountersBecomeRatesAndTheTickCadenceDrains() throws {
        let counters = StreamCounters(phoneRenderTimingEnabled: true)
        for tick in 0..<120 { counters.displayTick(at: Double(tick) / 120) }
        counters.displayTick(at: 1.1)
        for _ in 0..<3 { counters.drawCommitted(prompt: true) }
        for _ in 0..<6 { counters.drawCommitted(prompt: false) }
        counters.takeRefused(); counters.takeRefused()
        counters.presentedDropped()
        counters.presented(latencyMs: 1)
        var snapshot = counters.drain(inputBufferedBytes: nil)
        snapshot.interval = 2
        let report = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []), counters: snapshot)
        XCTAssertEqual(report.tickIntervalP50Ms, 8.3)
        XCTAssertEqual(report.tickIntervalP90Ms, 8.3, "one 100 ms tick does not reach p90 of 120")
        XCTAssertEqual(report.promptDrawsPerSecond, 1.5)
        XCTAssertEqual(report.tickDrawsPerSecond, 3)
        XCTAssertEqual(report.takeRefusedPerSecond, 1)
        XCTAssertEqual(report.presentedDroppedPerSecond, 0.5)
        XCTAssertTrue(report.summaryLines.contains { $0.hasPrefix("commit→glass") }, report.summaryLines.joined(separator: "\n"))
        XCTAssertEqual(try JSONDecoder().decode(StreamStatsReport.self, from: JSONEncoder().encode(report)), report)
        var quiet = counters.drain(inputBufferedBytes: nil)
        XCTAssertNil(quiet.tickIntervalP50Ms)
        XCTAssertEqual(quiet.takeRefused, 0); XCTAssertEqual(quiet.tickDraws, 0); XCTAssertEqual(quiet.presentedDropped, 0)
        quiet.interval = 1
        let idle = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []), counters: quiet)
        XCTAssertNil(idle.takeRefusedPerSecond, "rates appear only for a window that drew or replaced a frame")
        XCTAssertFalse(idle.summaryLines.contains { $0.hasPrefix("commit→glass") })
    }

    func testPhoneRenderTimingDisabledLeavesUnknownStagesAndCapsCadenceSampleDenominator() {
        let disabled = StreamCounters(phoneRenderTimingEnabled: false)
        disabled.phoneDecodeTrace(PhoneDecodeTrace(submitMs: 1, callbackMs: 2, ownershipMs: 3, deliveryMs: 4))
        disabled.phoneRenderTiming(.decodedToPresented, milliseconds: 5)
        disabled.displayTick(at: 1); disabled.displayTick(at: 1.01)
        disabled.drawCommitted(prompt: true); disabled.takeRefused(); disabled.presentedDropped()
        let absent = disabled.drain(inputBufferedBytes: nil)
        XCTAssertNil(absent.decodeVTSamples)
        XCTAssertNil(absent.decodedToPresentedP95Ms)
        XCTAssertNil(absent.tickIntervalP50Ms)
        XCTAssertEqual([absent.promptDraws, absent.takeRefused, absent.presentedDropped], [0, 0, 0], "the kill switch covers the presentation stage")
        let bounded = StreamCounters(phoneRenderTimingEnabled: true)
        for _ in 0..<LatencyWindow.capacity { bounded.phoneRenderTiming(.displayLinkInterval, milliseconds: 8) }
        for _ in 0..<10 { bounded.phoneRenderTiming(.displayLinkInterval, milliseconds: 50) }
        let snapshot = bounded.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.displayLinkIntervalSamples, LatencyWindow.capacity)
        XCTAssertEqual(snapshot.displayLinkAt120Share, 1, "share and percentiles cover the same bounded samples")
    }

    func testPhoneSendToArrivalDistributionAndUncertaintyReachTheHostSummary() throws {
        let counters = StreamCounters()
        for (duration, uncertainty) in [(5.0, 2.0), (15.0, 4.0), (25.0, 3.0)] {
            counters.phoneInputArrived(timing: InputSendTiming(sendHostMs: 1_000, uncertaintyMs: uncertainty),
                                      arrivedHostMs: 1_000 + duration)
        }
        counters.phoneInputArrived(timing: InputSendTiming(sendHostMs: 1_000, uncertaintyMs: 3), arrivedHostMs: 990)
        counters.phoneInputArrived(timing: InputSendTiming(sendHostMs: 1_000, uncertaintyMs: .nan), arrivedHostMs: 1_010)
        let snapshot = counters.drain(inputBufferedBytes: nil, at: ProcessInfo.processInfo.systemUptime + 1)
        let sample = StreamStatsSample(entries: [])
        let report = StreamStatsReport(role: "host", previous: sample, current: sample, counters: snapshot)
        XCTAssertEqual(report.phoneSendToArrivalP50Ms, 15)
        XCTAssertEqual(report.phoneSendToArrivalP95Ms, 25)
        XCTAssertEqual(report.phoneSendToArrivalMaxMs, 25)
        XCTAssertEqual(report.phoneSendToArrivalUncertaintyMs, 4)
        XCTAssertEqual(report.phoneSendToArrivalSamples, 3)
        let summary = report.hostSummary
        XCTAssertEqual(summary.phoneSendToArrivalP50Ms, 15)
        XCTAssertEqual(summary.phoneSendToArrivalP95Ms, 25)
        XCTAssertEqual(summary.phoneSendToArrivalMaxMs, 25)
        XCTAssertEqual(summary.phoneSendToArrivalUncertaintyMs, 4)
        XCTAssertEqual(summary.phoneSendToArrivalSamples, 3)
        try summary.validate()
        XCTAssertEqual(try JSONDecoder().decode(HostStreamSummary.self, from: JSONEncoder().encode(summary)), summary)
        XCTAssertTrue(report.summaryLines.contains { $0.contains("phone send → arrival") })
        let empty = counters.drain(inputBufferedBytes: nil, at: ProcessInfo.processInfo.systemUptime + 2)
        XCTAssertNil(empty.phoneSendToArrivalP50Ms)
        XCTAssertNil(empty.phoneSendToArrivalUncertaintyMs)
        XCTAssertNil(empty.phoneSendToArrivalSamples)
        let older = try JSONDecoder().decode(HostStreamSummary.self, from: Data("{}".utf8))
        XCTAssertNil(older.phoneSendToArrivalSamples)
    }

    func testPhoneSendToArrivalSummaryOmitsInvalidEvidenceAndValidatesBounds() throws {
        let sample = StreamStatsSample(entries: [])
        var report = StreamStatsReport(role: "host", previous: sample, current: sample, counters: nil)
        report.phoneSendToArrivalP50Ms = .nan
        report.phoneSendToArrivalP95Ms = -1
        report.phoneSendToArrivalMaxMs = InputSendTiming.maximumLatencyMs + 1
        report.phoneSendToArrivalUncertaintyMs = InputSendTiming.maximumUncertaintyMs + 1
        report.phoneSendToArrivalSamples = 100_000
        let summary = report.hostSummary
        XCTAssertNil(summary.phoneSendToArrivalP50Ms)
        XCTAssertNil(summary.phoneSendToArrivalP95Ms)
        XCTAssertNil(summary.phoneSendToArrivalMaxMs)
        XCTAssertNil(summary.phoneSendToArrivalUncertaintyMs)
        XCTAssertNil(summary.phoneSendToArrivalSamples)
        try summary.validate()
        var invalid = summary; invalid.phoneSendToArrivalP50Ms = .infinity
        XCTAssertThrowsError(try invalid.validate())
        invalid = summary; invalid.phoneSendToArrivalMaxMs = InputSendTiming.maximumLatencyMs + 1
        XCTAssertThrowsError(try invalid.validate())
        invalid = summary; invalid.phoneSendToArrivalUncertaintyMs = -1
        XCTAssertThrowsError(try invalid.validate())
    }

    func testHostSummaryCarriesObservedMaximumGapAndOlderMissingFieldRemainsUnknown() throws {
        let previous = StreamStatsSample(entries: senderEntries(at: 1, encoded: 0, sent: 0, bytes: 0, encodeTime: 0, qp: 0))
        let current = StreamStatsSample(entries: senderEntries(at: 2, encoded: 66, sent: 66, bytes: 100_000, encodeTime: 0.1, qp: 100))
        let report = StreamStatsReport(role: "host", previous: previous, current: current,
            counters: StreamCounterSnapshot(interval: 1, captureFrames: 66, captureGapP90Ms: 8, captureGapMaxMs: 450))
        XCTAssertEqual(report.captureGapMaxMs, 450)
        XCTAssertEqual(report.hostSummary.captureGapMaxMs, 450, "source-idle outlier survives sender summary rather than being hidden byP90")
        let encoded = try JSONEncoder().encode(report.hostSummary)
        let received = try JSONDecoder().decode(HostStreamSummary.self, from: encoded)
        XCTAssertEqual(received.captureGapMaxMs, 450); try received.validate()
        let older = try JSONDecoder().decode(HostStreamSummary.self, from: Data("{}".utf8))
        XCTAssertNil(older.captureGapMaxMs); try older.validate()
        var invalid = received; invalid.captureGapMaxMs = .nan
        XCTAssertThrowsError(try invalid.validate())
    }
    private func senderEntries(at seconds: Double, encoded: Double, sent: Double, bytes: Double,
                               encodeTime: Double, qp: Double) -> [StreamStatsEntry] {
        [
            StreamStatsEntry(id: "OT1", type: "outbound-rtp", values: [
                "kind": "video" as NSString, "framesEncoded": encoded as NSNumber,
                "framesSent": sent as NSNumber, "bytesSent": bytes as NSNumber,
                "totalEncodeTime": encodeTime as NSNumber, "qpSum": qp as NSNumber,
                "keyFramesEncoded": 1 as NSNumber,
                "encoderImplementation": "VideoToolbox" as NSString,
                "powerEfficientEncoder": true as NSNumber,
                "qualityLimitationReason": "none" as NSString,
                "frameWidth": 2940 as NSNumber, "frameHeight": 1912 as NSNumber,
                "targetBitrate": 12_000_000 as NSNumber, "codecId": "C1" as NSString,
                "mediaSourceId": "S1" as NSString
            ]),
            StreamStatsEntry(id: "S1", type: "media-source", values: [
                "kind": "video" as NSString, "frames": (encoded + 2) as NSNumber
            ]),
            StreamStatsEntry(id: "C1", type: "codec", values: [
                "mimeType": "video/H264" as NSString,
                "sdpFmtpLine": "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c34" as NSString
            ]),
            StreamStatsEntry(id: "T1", type: "transport", values: ["selectedCandidatePairId": "P1" as NSString]),
            StreamStatsEntry(id: "P1", type: "candidate-pair", values: [
                "localCandidateId": "L1" as NSString, "remoteCandidateId": "R1" as NSString,
                "currentRoundTripTime": 0.0055 as NSNumber,
                "availableOutgoingBitrate": 25_000_000 as NSNumber
            ]),
            StreamStatsEntry(id: "L1", type: "local-candidate", values: ["candidateType": "host" as NSString]),
            StreamStatsEntry(id: "R1", type: "remote-candidate", values: ["candidateType": "host" as NSString])
        ].map { entry in
            var entry = entry
            entry.timestamp = seconds
            return entry
        }
    }

    func testSenderRatesComeFromCounterDeltas() throws {
        let first = StreamStatsSample(entries: senderEntries(at: 10, encoded: 100, sent: 100, bytes: 1_000_000,
                                                               encodeTime: 0.8, qp: 2_000))
        let second = StreamStatsSample(entries: senderEntries(at: 11, encoded: 160, sent: 159, bytes: 2_500_000,
                                                                encodeTime: 1.1, qp: 3_500))
        let report = StreamStatsReport(role: "host", previous: first, current: second,
                                       counters: StreamCounterSnapshot(interval: 1, captureFrames: 61,
                                                                       captureIdleFrames: 3, pushedFrames: 60,
                                                                       pushSkipped: 1))
        XCTAssertEqual(report.encodedFPS, 60)
        XCTAssertEqual(report.sentFPS, 59)
        XCTAssertEqual(report.encodeMs, 5)
        XCTAssertEqual(report.sentKbps, 12_000)
        XCTAssertEqual(report.qpAverage, 25)
        XCTAssertEqual(report.captureFPS, 61)
        XCTAssertEqual(report.pushSkipped, 1)
        XCTAssertEqual(report.encoderImplementation, "VideoToolbox")
        XCTAssertEqual(report.powerEfficientEncoder, true)
        XCTAssertEqual(report.sentWidth, 2940)
        XCTAssertEqual(report.sentHeight, 1912)
        XCTAssertEqual(report.targetKbps, 12_000)
        XCTAssertEqual(report.availableOutgoingKbps, 25_000)
        XCTAssertEqual(report.rttMs, 5.5)
        XCTAssertEqual(report.route, "Direct")
        XCTAssertEqual(report.codec, "video/H264")
        XCTAssertEqual(report.h264ProfileLevel, "640c34")
    }

    func testReceiverRatesAndJitterBufferDelay() throws {
        func entries(at seconds: Double, received: Double, decoded: Double, dropped: Double, bytes: Double,
                     decodeTime: Double, jitterDelay: Double, emitted: Double, target: Double,
                     lost: Double, packets: Double, processing: Double) -> [StreamStatsEntry] {
            var entry = StreamStatsEntry(id: "IT1", type: "inbound-rtp", values: [
                "kind": "video" as NSString, "framesReceived": received as NSNumber,
                "framesDecoded": decoded as NSNumber, "framesDropped": dropped as NSNumber,
                "bytesReceived": bytes as NSNumber, "totalDecodeTime": decodeTime as NSNumber,
                "jitterBufferDelay": jitterDelay as NSNumber, "jitterBufferEmittedCount": emitted as NSNumber,
                "jitterBufferTargetDelay": target as NSNumber, "packetsLost": lost as NSNumber,
                "packetsReceived": packets as NSNumber, "totalProcessingDelay": processing as NSNumber,
                "freezeCount": 0 as NSNumber, "decoderImplementation": "VideoToolbox" as NSString,
                "frameWidth": 1920 as NSNumber, "frameHeight": 1248 as NSNumber
            ])
            entry.timestamp = seconds
            return [entry]
        }
        let first = StreamStatsSample(entries: entries(at: 0, received: 0, decoded: 0, dropped: 0, bytes: 0,
                                                       decodeTime: 0, jitterDelay: 0, emitted: 0, target: 0,
                                                       lost: 0, packets: 0, processing: 0))
        let second = StreamStatsSample(entries: entries(at: 2, received: 120, decoded: 118, dropped: 2,
                                                        bytes: 2_000_000, decodeTime: 0.59, jitterDelay: 2.36,
                                                        emitted: 118, target: 1.18, lost: 5, packets: 995,
                                                        processing: 4.72))
        let report = StreamStatsReport(role: "phone", previous: first, current: second,
                                       counters: StreamCounterSnapshot(interval: 2, renderedFrames: 118,
                                                                       renderGapMedianMs: 16.7, renderGapP90Ms: 20,
                                                                       renderGapMaxMs: 40))
        XCTAssertEqual(report.receivedFPS, 60)
        XCTAssertEqual(report.decodedFPS, 59)
        XCTAssertEqual(report.framesDropped, 2)
        XCTAssertEqual(report.receivedKbps, 8_000)
        XCTAssertEqual(report.decodeMs, 5)
        XCTAssertEqual(report.jitterBufferMs, 20)
        XCTAssertEqual(report.jitterBufferTargetMs, 10)
        XCTAssertEqual(report.processingMs, 40)
        XCTAssertEqual(report.packetLossPercent, 0.5)
        XCTAssertEqual(report.renderedFPS, 59)
        XCTAssertEqual(report.renderGapP90Ms, 20)
        XCTAssertEqual(report.receivedWidth, 1920)
    }

    func testFirstSampleAndCounterResetsReportNoRatesInsteadOfNegativeValues() {
        let current = StreamStatsSample(entries: senderEntries(at: 5, encoded: 10, sent: 10, bytes: 100,
                                                                 encodeTime: 0.1, qp: 100))
        let initial = StreamStatsReport(role: "host", previous: nil, current: current, counters: nil)
        XCTAssertNil(initial.encodedFPS)
        XCTAssertNil(initial.sentKbps)
        XCTAssertEqual(initial.encoderImplementation, "VideoToolbox")

        let restarted = StreamStatsSample(entries: senderEntries(at: 6, encoded: 2, sent: 2, bytes: 50,
                                                                   encodeTime: 0.01, qp: 10))
        let reset = StreamStatsReport(role: "host", previous: current, current: restarted, counters: nil)
        XCTAssertNil(reset.encodedFPS)
        XCTAssertNil(reset.sentKbps)
    }

    func testLogLineIsSingleLineMachineReadableJSON() throws {
        let sample = StreamStatsSample(entries: senderEntries(at: 1, encoded: 1, sent: 1, bytes: 1,
                                                                encodeTime: 0, qp: 0))
        var report = StreamStatsReport(role: "host", previous: nil, current: sample,
                                       counters: StreamCounterSnapshot(interval: 1, inputBufferedBytes: 512,
                                                                       inputBufferedPeakBytes: 2048))
        report.captureMaximumDimension = 2560
        let line = report.logLine
        XCTAssertTrue(line.hasPrefix("PDSTATS "))
        XCTAssertFalse(line.contains("\n"))
        let json = try XCTUnwrap(line.dropFirst("PDSTATS ".count).data(using: .utf8))
        let decoded = try JSONDecoder().decode(StreamStatsReport.self, from: json)
        XCTAssertEqual(decoded.role, "host")
        XCTAssertEqual(decoded.inputBufferedPeakBytes, 2048)
        XCTAssertEqual(decoded.captureMaximumDimension, 2560)
        XCTAssertFalse(report.summaryLines.isEmpty)
    }

    func testUniqueSourceFramesExcludeIdleResendsAndRepeatedDisplayTimes() throws {
        let counters = StreamCounters()
        for displayMs in [1_000, 1_008.3, 1_008.3, 1_004, 1_016.7] {
            counters.captured(idle: false, displayTimeMs: displayMs, at: displayMs / 1_000)
        }
        counters.captured(idle: false, displayTimeMs: nil)
        counters.captured(idle: false, displayTimeMs: 0)
        counters.captured(idle: true, displayTimeMs: 1_025)
        counters.idleResent(); counters.idleResent()
        let snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.captureFrames, 7)
        XCTAssertEqual(snapshot.uniqueSourceFrames, 3, "duplicate, earlier, missing and idle display times are not new pixels")
        XCTAssertEqual(snapshot.captureResends, 2)
        let report = StreamStatsReport(role: "host", previous: nil, current: StreamStatsSample(entries: []),
            counters: StreamCounterSnapshot(interval: 2, captureFrames: 240, uniqueSourceFrames: 236, captureResends: 1))
        XCTAssertEqual(report.captureFPS, 120)
        XCTAssertEqual(report.uniqueSourceFPS, 118)
        XCTAssertEqual(report.captureResendFPS, 0.5)
        let received = try JSONDecoder().decode(HostStreamSummary.self, from: JSONEncoder().encode(report.hostSummary))
        XCTAssertEqual(received.uniqueSourceFPS, 118); XCTAssertEqual(received.resendFPS, 0.5); try received.validate()
        let older = try JSONDecoder().decode(HostStreamSummary.self, from: Data("{}".utf8))
        XCTAssertNil(older.uniqueSourceFPS); XCTAssertNil(older.resendFPS)
        var invalid = received; invalid.uniqueSourceFPS = -1
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertTrue(report.summaryLines.contains("unique source 118fps · idle resends 0.5/s"))
        counters.captured(idle: false, displayTimeMs: 1_016.7)
        XCTAssertEqual(counters.drain(inputBufferedBytes: nil).uniqueSourceFrames, 0, "identity survives a drain")
    }

    func testUniqueDecodedFramesCountDistinctRtpTimestampsSeparatelyFromRedraws() {
        let counters = StreamCounters()
        for rtp: UInt32 in [100, 100, 850, 100, 1_600] { counters.rendered(rtp: rtp) }
        counters.rendered()
        counters.presented(latencyMs: 2); counters.presented(latencyMs: 2); counters.presented(latencyMs: 2)
        let snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.renderedFrames, 6)
        XCTAssertEqual(snapshot.uniqueDecodedFrames, 3, "a repeated timestamp is the same encoded frame")
        XCTAssertEqual(snapshot.presentedFrames, 3)
        for rtp in UInt32(0)..<UInt32(StreamCounters.decodedRtpMemory + 1) { counters.rendered(rtp: 10_000 + rtp * 750) }
        XCTAssertEqual(counters.drain(inputBufferedBytes: nil).uniqueDecodedFrames, StreamCounters.decodedRtpMemory + 1)
        var report = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []),
            counters: StreamCounterSnapshot(interval: 1, renderedFrames: 121, uniqueDecodedFrames: 119, presentedFrames: 120))
        report.host = HostStreamSummary(uniqueSourceFPS: 119.5, resendFPS: 0)
        XCTAssertEqual(report.renderedFPS, 121)
        XCTAssertEqual(report.uniqueDecodedFPS, 119)
        XCTAssertEqual(report.presentedFPS, 120)
        XCTAssertTrue(report.summaryLines.contains("unique source 120fps (Mac) · unique decoded 119fps · Mac resends 0.0/s"))
    }
}

final class StreamStageStatisticsTests: XCTestCase {
    func testDetailedDiagnosticsDefaultAndExplicitRollback() {
        let suite = "farside.detailed-diagnostics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(DetailedDiagnostics.isEnabled(defaults: defaults))
        defaults.set("NO", forKey: DetailedDiagnostics.defaultsKey)
        XCTAssertFalse(DetailedDiagnostics.isEnabled(defaults: defaults))
        defaults.set(true, forKey: DetailedDiagnostics.defaultsKey)
        XCTAssertTrue(DetailedDiagnostics.isEnabled(defaults: defaults))
    }

    func testRelayProtocolUsesOnlySelectedRelayEvidenceAndNeverAddressesOrSDP() throws {
        func entries(localType: String = "relay", localProtocol: String? = "UDP", remoteProtocol: String? = nil,
                     selected: Bool = true) -> [StreamStatsEntry] {
            var local: [String: Any] = ["candidateType": localType, "address": "private.example", "url": "turn:private.example"]
            if let localProtocol { local["relayProtocol"] = localProtocol }
            var remote: [String: Any] = ["candidateType": "relay", "protocol": "udp"]
            if let remoteProtocol { remote["relayProtocol"] = remoteProtocol }
            return [
                StreamStatsEntry(id: "transport", type: "transport", values: selected ? ["selectedCandidatePairId": "pair"] : [:]),
                StreamStatsEntry(id: "pair", type: "candidate-pair", values: ["localCandidateId": "local", "remoteCandidateId": "remote"]),
                StreamStatsEntry(id: "local", type: "local-candidate", values: local),
                StreamStatsEntry(id: "remote", type: "remote-candidate", values: remote),
                StreamStatsEntry(id: "unused", type: "local-candidate", values: ["candidateType": "relay", "relayProtocol": "tls"]),
                StreamStatsEntry(id: "video", type: "outbound-rtp", values: ["kind": "video", "codecId": "codec", "nackCount": 5]),
                StreamStatsEntry(id: "codec", type: "codec", values: ["sdpFmtpLine": "private SDP", "rtcpFeedback": ["nack"]])
            ]
        }
        func report(_ entries: [StreamStatsEntry], enabled: Bool = true) -> StreamStatsReport {
            StreamStatsReport(role: "host", previous: nil,
                current: StreamStatsSample(entries: entries, detailedDiagnosticsEnabled: enabled), counters: nil,
                detailedDiagnosticsEnabled: enabled)
        }
        let on = report(entries())
        XCTAssertEqual(on.relayProtocol, "udp")
        XCTAssertNil(on.negotiatedFeedback, "feedback traffic or nonstandard codec fields are not negotiation evidence")
        XCTAssertEqual(report(entries(localType: "host", localProtocol: "tcp", remoteProtocol: "TLS")).relayProtocol, "tls")
        XCTAssertNil(report(entries(localProtocol: "turn:private.example")).relayProtocol)
        XCTAssertNil(report(entries(localProtocol: nil)).relayProtocol, "candidate protocol does not describe its TURN leg")
        XCTAssertNil(report(entries(selected: false)).relayProtocol)
        var previousEntries = entries()
        previousEntries[5] = StreamStatsEntry(id: "video", type: "outbound-rtp", values: ["kind": "video", "bytesSent": 1000], timestamp: 1)
        var resetEntries = entries(localProtocol: nil)
        resetEntries[5] = StreamStatsEntry(id: "video", type: "outbound-rtp", values: ["kind": "video", "bytesSent": 10], timestamp: 2)
        let reset = StreamStatsReport(role: "host", previous: StreamStatsSample(entries: previousEntries),
            current: StreamStatsSample(entries: resetEntries), counters: nil, detailedDiagnosticsEnabled: true)
        XCTAssertNil(reset.sentKbps)
        XCTAssertNil(reset.relayProtocol, "missing current evidence cannot retain the previous selected transport")
        XCTAssertNil(report(entries(), enabled: false).relayProtocol)
        XCTAssertFalse(on.logLine.contains("private.example")); XCTAssertFalse(on.logLine.contains("private SDP"))
        XCTAssertEqual(try JSONDecoder().decode(StreamStatsReport.self, from: JSONEncoder().encode(on)).relayProtocol, "udp")
        XCTAssertNil(try JSONDecoder().decode(HostStreamSummary.self, from: Data("{}".utf8)).relayProtocol)
        XCTAssertEqual(on.hostSummary.relayProtocol, "udp")
        XCTAssertNoThrow(try on.hostSummary.validate())
        var invalid = on.hostSummary; invalid.relayProtocol = "https://private.example"
        XCTAssertThrowsError(try invalid.validate())
        invalid = on.hostSummary; invalid.negotiatedFeedback = ["private SDP"]
        XCTAssertThrowsError(try invalid.validate())
    }

    func testDetailedEncoderStagesBoundDrainAndRollbackWithoutChangingEarlierCounters() throws {
        for enabled in [true, false] {
            let counters = StreamCounters(detailedDiagnosticsEnabled: enabled)
            for _ in 0..<(LatencyWindow.capacity + 10) {
                counters.encoderPreparation(milliseconds: 2)
                counters.encoderSubmit(milliseconds: 0.5)
            }
            for value in [Double.nan, -Double.infinity, -1, DetailedDiagnostics.maximumStageMs + 1] {
                counters.encoderPreparation(milliseconds: value); counters.encoderSubmit(milliseconds: value)
            }
            counters.encoded(latencyMs: 5, vtLatencyMs: 4, bytes: 100, isKeyFrame: true, inFlight: 1)
            var snapshot = counters.drain(inputBufferedBytes: nil); snapshot.interval = 1
            XCTAssertEqual(snapshot.encodeLatencyP50Ms, 5, "rollback preserves existing instrumentation")
            XCTAssertEqual(snapshot.encodePreparationP95Ms, enabled ? 2 : nil)
            XCTAssertEqual(snapshot.encodePreparationSamples, enabled ? LatencyWindow.capacity : nil)
            XCTAssertEqual(snapshot.encodeSubmitP95Ms, enabled ? 0.5 : nil)
            XCTAssertEqual(snapshot.encodeSubmitSamples, enabled ? LatencyWindow.capacity : nil)
            var report = StreamStatsReport(role: "host", previous: nil, current: StreamStatsSample(entries: []),
                counters: snapshot, detailedDiagnosticsEnabled: enabled)
            XCTAssertEqual(report.hostSummary.encodePreparationP95Ms, enabled ? 2 : nil)
            XCTAssertNoThrow(try report.hostSummary.validate())
            XCTAssertEqual(try JSONDecoder().decode(HostStreamSummary.self, from: JSONEncoder().encode(report.hostSummary)), report.hostSummary)
            let next = counters.drain(inputBufferedBytes: nil)
            XCTAssertNil(next.encodePreparationSamples); XCTAssertNil(next.encodeSubmitP95Ms)
            if !enabled {
                report.host = HostStreamSummary(relayProtocol: "tls", negotiatedFeedback: ["nack"],
                    encodePreparationP95Ms: 2, encodePreparationSamples: 1, encodeSubmitP95Ms: 1, encodeSubmitSamples: 1)
                XCTAssertFalse(report.logLine.contains("encodePreparation")); XCTAssertFalse(report.logLine.contains("relayProtocol"))
                XCTAssertFalse(report.summaryLines.contains { $0.contains("encode preparation") })
            }
        }
    }

    func testSenderStagesComeFromPacerAndSourceCounters() {
        func entries(at seconds: Double, source: Double, encoded: Double, packets: Double,
                     sendDelay: Double, retransmitted: Double) -> [StreamStatsEntry] {
            [
                StreamStatsEntry(id: "OT1", type: "outbound-rtp", values: [
                    "kind": "video" as NSString, "framesEncoded": encoded as NSNumber,
                    "packetsSent": packets as NSNumber, "totalPacketSendDelay": sendDelay as NSNumber,
                    "retransmittedPacketsSent": retransmitted as NSNumber, "mediaSourceId": "S1" as NSString
                ], timestamp: seconds),
                StreamStatsEntry(id: "S1", type: "media-source", values: [
                    "kind": "video" as NSString, "frames": source as NSNumber
                ], timestamp: seconds)
            ]
        }
        let first = StreamStatsSample(entries: entries(at: 0, source: 0, encoded: 0, packets: 0, sendDelay: 0, retransmitted: 0))
        let second = StreamStatsSample(entries: entries(at: 1, source: 60, encoded: 57, packets: 400,
                                                       sendDelay: 0.8, retransmitted: 2))
        let report = StreamStatsReport(role: "host", previous: first, current: second, counters: nil)
        XCTAssertEqual(report.pacerDelayMs, 2)
        XCTAssertEqual(report.droppedBeforeEncode, 3)
        XCTAssertEqual(report.retransmittedPackets, 2)
    }

    func testReceiverAssemblyAndPresentationStages() {
        func entries(at seconds: Double, assembled: Double, assembly: Double) -> [StreamStatsEntry] {
            [StreamStatsEntry(id: "IT1", type: "inbound-rtp", values: [
                "kind": "video" as NSString, "framesAssembledFromMultiplePackets": assembled as NSNumber,
                "totalAssemblyTime": assembly as NSNumber
            ], timestamp: seconds)]
        }
        let counters = StreamCounters()
        counters.setDisplayMaxFPS(120)
        for index in 0..<60 { counters.presented(latencyMs: Double(index % 10), at: Double(index) / 60) }
        counters.superseded(2)
        counters.superseded(0)
        var snapshot = counters.drain(inputBufferedBytes: 0, at: 1)
        snapshot.interval = 1
        let report = StreamStatsReport(role: "phone",
                                       previous: StreamStatsSample(entries: entries(at: 0, assembled: 0, assembly: 0)),
                                       current: StreamStatsSample(entries: entries(at: 1, assembled: 50, assembly: 0.1)),
                                       counters: snapshot)
        XCTAssertEqual(report.assemblyMs, 2)
        XCTAssertEqual(report.presentedFPS, 60)
        XCTAssertEqual(report.supersededFrames, 2)
        XCTAssertEqual(report.presentLatencyMs, 4)
        XCTAssertEqual(report.presentLatencyP90Ms, 8)
        XCTAssertEqual(report.displayMaxFPS, 120)
        XCTAssertEqual(counters.drain(inputBufferedBytes: nil, at: 2).displayMaxFPS, 120, "the refresh rate persists")
    }

    func testCaptureLatencyAndGapsSeparateCompleteFromIdleFrames() {
        let counters = StreamCounters()
        counters.captured(idle: false, displayLatencyMs: 6, at: 0)
        counters.captured(idle: false, displayLatencyMs: 8, at: 0.0167)
        counters.captured(idle: false, displayLatencyMs: 30, at: 0.1167)
        counters.captured(idle: true, displayLatencyMs: 500, at: 0.2)
        var snapshot = counters.drain(inputBufferedBytes: nil, at: 1)
        snapshot.interval = 1
        let report = StreamStatsReport(role: "host", previous: nil,
                                       current: StreamStatsSample(entries: []), counters: snapshot)
        XCTAssertEqual(report.captureFPS, 3)
        XCTAssertEqual(report.captureIdleFPS, 1)
        XCTAssertEqual(report.captureLatencyMs, 8)
        XCTAssertEqual(report.captureLatencyP90Ms, 30)
        XCTAssertEqual(report.captureGapMaxMs ?? 0, 100, accuracy: 0.5)
    }
}

final class LatencyWindowTests: XCTestCase {
    func testPercentilesAndBoundedCapacity() {
        var window = LatencyWindow()
        for value in 1...10 { window.record(Double(value)) }
        window.record(.nan)
        window.record(-1)
        let summary = window.drain()
        XCTAssertEqual(summary.count, 10)
        XCTAssertEqual(summary.p50, 5)
        XCTAssertEqual(summary.p90, 9)
        for _ in 0..<(LatencyWindow.capacity + 10) { window.record(1) }
        XCTAssertEqual(window.drain().count, LatencyWindow.capacity)
        XCTAssertEqual(window.drain().count, 0)
    }
}

final class FrameCadenceWindowTests: XCTestCase {
    func testGapPercentilesDescribeDeliveredCadence() {
        var window = FrameCadenceWindow()
        var time = 0.0
        window.record(at: time)
        for gap in [0.016, 0.017, 0.016, 0.017, 0.033, 0.016, 0.017, 0.016, 0.017, 0.100] {
            time += gap
            window.record(at: time)
        }
        let summary = window.drain()
        XCTAssertEqual(summary.frames, 11)
        XCTAssertEqual(summary.medianGapMs ?? 0, 17, accuracy: 0.5)
        XCTAssertEqual(summary.p90GapMs ?? 0, 33, accuracy: 0.5)
        XCTAssertEqual(summary.maxGapMs ?? 0, 100, accuracy: 0.5)
    }

    func testGapAcrossDrainIsKeptSoSlowFramesAreNotHidden() {
        var window = FrameCadenceWindow()
        window.record(at: 1.0)
        _ = window.drain()
        window.record(at: 1.45)
        let summary = window.drain()
        XCTAssertEqual(summary.frames, 1)
        XCTAssertEqual(summary.maxGapMs ?? 0, 450, accuracy: 0.5)
    }

    func testEmptyWindowHasNoGaps() {
        var window = FrameCadenceWindow()
        let summary = window.drain()
        XCTAssertEqual(summary.frames, 0)
        XCTAssertNil(summary.maxGapMs)
    }
    func testHostSummaryRoundTripsTheUniqueFrameAndGovernorFieldsTogether() throws {
        let sample = StreamStatsSample(entries: [])
        var snapshot = StreamCounterSnapshot(interval: 1)
        snapshot.uniqueSourceFrames = 58; snapshot.captureResends = 2
        var report = StreamStatsReport(role: "host", previous: sample, current: sample, counters: snapshot)
        report.transportPriorityRequested = "DSCP on · priority high"; report.bweCeilingKbps = 12_000; report.lanCeilingApplied = true
        report.senderQueueMs = 12; report.networkQueueMs = 3; report.backlogDrainMs = 40; report.senderQueueGovernor = "shadow, no cap"
        let summary = report.hostSummary
        XCTAssertEqual(summary.uniqueSourceFPS, 58); XCTAssertEqual(summary.resendFPS, 2)
        XCTAssertEqual(summary.senderQueueMs, 12); XCTAssertEqual(summary.lanCeilingApplied, true)
        XCTAssertEqual(summary.transportPriorityRequested, "DSCP on · priority high"); XCTAssertEqual(summary.senderQueueGovernor, "shadow, no cap")
        XCTAssertNoThrow(try summary.validate())
        XCTAssertEqual(try JSONDecoder().decode(HostStreamSummary.self, from: JSONEncoder().encode(summary)), summary)
    }

}

/// B0: the capture stall each `SCStream.updateConfiguration` costs, as a local host stats field.
final class ReconfigureStallTests: XCTestCase {
    func testASizeChangeEndsAtTheFirstFrameOfTheNewSize() {
        var tracker = ReconfigureStallTracker()
        tracker.requested(atMs: 1_000, width: 1520, height: 984, previousWidth: 2560, previousHeight: 1656)
        tracker.frame(atMs: 1_020, displayMs: 1_010, width: 2560, height: 1656)
        tracker.frame(atMs: 1_050, displayMs: 990, width: 1520, height: 984)
        XCTAssertEqual(tracker.drain(atMs: 1_100).longestStallMs, nil, "old-size frames and frames displayed before the request do not end it")
        tracker.frame(atMs: 1_310, displayMs: 1_300, width: 1520, height: 984)
        let window = tracker.drain(atMs: 1_400)
        XCTAssertNil(window.reconfigures, "the request was counted in the window it happened in")
        XCTAssertEqual(window.longestStallMs, 310)
    }

    func testSameSizeUpdatesEndAtTheFirstFrameDisplayedAfterTheNewestRequest() {
        var tracker = ReconfigureStallTracker()
        tracker.requested(atMs: 1_000, width: 2560, height: 1656, previousWidth: 2560, previousHeight: 1656)
        tracker.requested(atMs: 1_100, width: 2560, height: 1656, previousWidth: 2560, previousHeight: 1656)
        tracker.frame(atMs: 1_120, displayMs: 1_090, width: 2560, height: 1656)
        tracker.frame(atMs: 1_180, displayMs: 1_170, width: 2560, height: 1656)
        tracker.frame(atMs: 1_200, displayMs: 1_190, width: 2560, height: 1656)
        let window = tracker.drain(atMs: 1_300)
        XCTAssertEqual(window.reconfigures, 2)
        XCTAssertEqual(window.longestStallMs, 180, "back-to-back updates are one stall from the first request")
    }

    func testFailedAndAbandonedStallsAreNotRecordedButStillCounted() {
        var tracker = ReconfigureStallTracker()
        tracker.requested(atMs: 1_000, width: 1520, height: 984, previousWidth: 2560, previousHeight: 1656)
        tracker.failed()
        tracker.frame(atMs: 1_100, displayMs: 1_090, width: 1520, height: 984)
        tracker.requested(atMs: 2_000, width: 2560, height: 1656, previousWidth: 1520, previousHeight: 984)
        tracker.frame(atMs: 2_000 + ReconfigureStallTracker.abandonAfterMs + 1, displayMs: 0, width: 2560, height: 1656)
        let window = tracker.drain(atMs: 9_000)
        XCTAssertEqual(window.reconfigures, 2)
        XCTAssertNil(window.longestStallMs, "a still screen that sends no frame is not a measured stall")
        XCTAssertNil(tracker.drain(atMs: 9_100).reconfigures, "an empty window reports nothing")
    }

    func testALongStallWithFramesStillArrivingIsRecordedAtTheFloor() {
        var tracker = ReconfigureStallTracker()
        tracker.requested(atMs: 1_000, width: 1520, height: 984, previousWidth: 2560, previousHeight: 1656)
        tracker.frame(atMs: 1_500, displayMs: 1_490, width: 2560, height: 1656)
        XCTAssertEqual(tracker.drain(atMs: 1_000 + ReconfigureStallTracker.abandonAfterMs + 1).longestStallMs,
                       ReconfigureStallTracker.abandonAfterMs)
    }

    func testAFailedUpdateKeepsTheStallOpenBeforeItAndRetirementCancels() {
        var tracker = ReconfigureStallTracker()
        tracker.requested(atMs: 1_000, width: 1520, height: 984, previousWidth: 2560, previousHeight: 1656)
        tracker.requested(atMs: 1_100, width: 1216, height: 788, previousWidth: 1520, previousHeight: 984)
        tracker.failed()
        tracker.frame(atMs: 1_250, displayMs: 1_240, width: 1216, height: 788)
        tracker.frame(atMs: 1_300, displayMs: 1_290, width: 1520, height: 984)
        XCTAssertEqual(tracker.drain(atMs: 1_400).longestStallMs, 300, "the earlier successful update's stall still ends at its size")
        tracker.requested(atMs: 2_000, width: 2560, height: 1656, previousWidth: 1520, previousHeight: 984)
        tracker.cancel()
        tracker.frame(atMs: 2_100, displayMs: 2_090, width: 2560, height: 1656)
        XCTAssertNil(tracker.drain(atMs: 2_200).longestStallMs, "a new capture's first frame never closes a retired capture's stall")
    }

    func testHostReportCarriesTheLongestStallOfTheWindowLocallyOnly() throws {
        let counters = StreamCounters()
        let now = MachClock.nowMs()
        counters.captureReconfigureRequested(atMs: now - 500, width: 1520, height: 984, previousWidth: 2560, previousHeight: 1656)
        counters.captureFrameDelivered(atMs: now - 380, displayMs: now - 390, width: 1520, height: 984)
        counters.captureReconfigureRequested(atMs: now - 300, width: 1216, height: 788, previousWidth: 1520, previousHeight: 984)
        counters.captureFrameDelivered(atMs: now - 250, displayMs: now - 260, width: 1216, height: 788)
        let snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.reconfigures, 2)
        XCTAssertEqual(try XCTUnwrap(snapshot.reconfigureStallMs), 120, accuracy: 0.001)

        let host = StreamStatsReport(role: "host", previous: nil, current: StreamStatsSample(entries: []), counters: snapshot)
        XCTAssertEqual(host.reconfigures, 2)
        XCTAssertEqual(host.reconfigureStallMs, 120)
        XCTAssertTrue(host.logLine.contains("\"reconfigureStallMs\":120"), host.logLine)
        let summary = try JSONEncoder().encode(host.hostSummary)
        XCTAssertFalse(String(decoding: summary, as: UTF8.self).contains("reconfigure"), "the phone's summary is unchanged")
        let phone = StreamStatsReport(role: "phone", previous: nil, current: StreamStatsSample(entries: []), counters: snapshot)
        XCTAssertNil(phone.reconfigures)

        let quiet = StreamStatsReport(role: "host", previous: nil, current: StreamStatsSample(entries: []),
                                      counters: counters.drain(inputBufferedBytes: nil))
        XCTAssertFalse(quiet.logLine.contains("reconfigure"), "absent when nothing reconfigured")
    }
}
