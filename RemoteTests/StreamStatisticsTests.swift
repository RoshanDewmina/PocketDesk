import XCTest

final class StreamStatisticsTests: XCTestCase {
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
}

final class StreamStageStatisticsTests: XCTestCase {
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
}
