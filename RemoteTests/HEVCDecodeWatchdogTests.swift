import XCTest

final class HEVCDecodeWatchdogTests: XCTestCase {
    private func observation(_ time: Double, received: Double? = nil, decoded: Double = 0,
                             codec: HEVCDecodeWatchdog.Codec = .fullColor444,
                             inbound: String = "inbound", codecID: String = "codec") -> HEVCDecodeWatchdog.Observation {
        .init(identity: .init(inboundID: inbound, codecID: codecID, codec: codec),
              timestamp: time, framesReceived: received ?? time * 50, framesDecoded: decoded)
    }

    func testContinuousUndecodedFullColorTriggersOnlyOnceAtFiveSeconds() {
        var watchdog = HEVCDecodeWatchdog()
        for time in 100...104 { XCTAssertNil(watchdog.observe(observation(Double(time)))) }
        XCTAssertEqual(watchdog.observe(observation(105)), .fullColor444)
        XCTAssertTrue(watchdog.fired)
        XCTAssertNil(watchdog.observe(observation(106)))
        XCTAssertNil(watchdog.observe(observation(200, codec: .main, inbound: "replacement")))
    }

    func testMainProfileUsesMainFallbackRatherThanFullColorFallback() {
        var watchdog = HEVCDecodeWatchdog()
        for time in 100...104 { XCTAssertNil(watchdog.observe(observation(Double(time), codec: .main))) }
        XCTAssertEqual(watchdog.observe(observation(105, codec: .main)), .main)
    }

    func testOneDecodedFramePermanentlyCancelsFirstPictureFailureForThatStream() {
        var watchdog = HEVCDecodeWatchdog()
        for time in 100...104 { XCTAssertNil(watchdog.observe(observation(Double(time)))) }
        XCTAssertNil(watchdog.observe(observation(105, decoded: 1)))
        // A later counter reset or missing sample must not turn a healthy stream into a first-picture failure.
        XCTAssertNil(watchdog.observe(nil))
        for time in 106...120 { XCTAssertNil(watchdog.observe(observation(Double(time), decoded: 0))) }
        XCTAssertFalse(watchdog.fired)
    }

    func testDuplicateProducerSamplesNeverAdvanceGraceEvenIfPolledLater() {
        var watchdog = HEVCDecodeWatchdog()
        XCTAssertNil(watchdog.observe(observation(100)))
        for _ in 0..<20 { XCTAssertNil(watchdog.observe(observation(100))) }
        for time in 101...104 { XCTAssertNil(watchdog.observe(observation(Double(time)))) }
        XCTAssertEqual(watchdog.observe(observation(105)), .fullColor444)
    }

    func testIdleAndControlOnlyIntervalsCannotCauseFailure() {
        var watchdog = HEVCDecodeWatchdog()
        for time in 100...104 { XCTAssertNil(watchdog.observe(observation(Double(time)))) }
        XCTAssertNil(watchdog.observe(observation(105, received: 5200))) // No new video frames.
        for time in 106...109 { XCTAssertNil(watchdog.observe(observation(Double(time)))) }
        XCTAssertNil(watchdog.observe(nil)) // No inbound-video counters, regardless of transport traffic.
        for time in 110...114 { XCTAssertNil(watchdog.observe(observation(Double(time)))) }
        XCTAssertEqual(watchdog.observe(observation(115)), .fullColor444)
    }

    func testLongSampleGapDoesNotCountUnobservedTimeAsContinuousReception() {
        var watchdog = HEVCDecodeWatchdog()
        for time in 100...104 { XCTAssertNil(watchdog.observe(observation(Double(time)))) }
        XCTAssertNil(watchdog.observe(observation(110)))
        for time in 111...114 { XCTAssertNil(watchdog.observe(observation(Double(time)))) }
        XCTAssertEqual(watchdog.observe(observation(115)), .fullColor444)
    }

    func testCounterResetRestartsGraceInsteadOfFailingImmediately() {
        var watchdog = HEVCDecodeWatchdog()
        for time in 100...104 { XCTAssertNil(watchdog.observe(observation(Double(time)))) }
        XCTAssertNil(watchdog.observe(observation(105, received: 0)))
        for time in 106...109 { XCTAssertNil(watchdog.observe(observation(Double(time), received: (Double(time) - 105) * 50))) }
        XCTAssertEqual(watchdog.observe(observation(110, received: 250)), .fullColor444)
    }

    func testBackwardProducerTimeRestartsGrace() {
        var watchdog = HEVCDecodeWatchdog()
        for time in 100...104 { XCTAssertNil(watchdog.observe(observation(Double(time)))) }
        XCTAssertNil(watchdog.observe(observation(90)))
        for time in 91...94 { XCTAssertNil(watchdog.observe(observation(Double(time)))) }
        XCTAssertEqual(watchdog.observe(observation(95)), .fullColor444)
    }

    func testDifferentInboundOrNegotiatedCodecGetsItsOwnGrace() {
        for replaceCodec in [false, true] {
            var watchdog = HEVCDecodeWatchdog()
            for time in 100...104 { XCTAssertNil(watchdog.observe(observation(Double(time)))) }
            func replacement(_ time: Double) -> HEVCDecodeWatchdog.Observation {
                observation(time, codec: replaceCodec ? .main : .fullColor444,
                            inbound: replaceCodec ? "inbound" : "new-inbound", codecID: replaceCodec ? "new-codec" : "codec")
            }
            for time in 105...109 { XCTAssertNil(watchdog.observe(replacement(Double(time)))) }
            XCTAssertEqual(watchdog.observe(replacement(110)), replaceCodec ? .main : .fullColor444)
        }
    }

    func testUnknownOrInvalidMetricsResetPendingGrace() {
        let invalid = [observation(.nan), observation(.infinity), observation(105, received: -.infinity),
                       observation(105, received: -1), observation(105, received: 1.5),
                       observation(105, decoded: .nan), observation(105, decoded: -1),
                       observation(105, inbound: ""), observation(105, codecID: "")]
        for bad in invalid {
            var watchdog = HEVCDecodeWatchdog()
            for time in 100...104 { XCTAssertNil(watchdog.observe(observation(Double(time)))) }
            XCTAssertNil(watchdog.observe(bad))
            for time in 106...110 { XCTAssertNil(watchdog.observe(observation(Double(time)))) }
            XCTAssertEqual(watchdog.observe(observation(111)), .fullColor444)
        }
    }

    func testNegotiatedProfileMustBeExplicitAndUnambiguous() {
        XCTAssertEqual(HEVCDecodeWatchdog.Codec.negotiated(mimeType: "video/H265", fmtp: "profile-id=4;tier-flag=1;level-id=153;tx-mode=SRST"), .fullColor444)
        XCTAssertEqual(HEVCDecodeWatchdog.Codec.negotiated(mimeType: "VIDEO/H265", fmtp: " profile-id = 1 ; level-id=153 "), .main)
        for mime in ["video/H264", "video/VP9", "H265", ""] {
            XCTAssertNil(HEVCDecodeWatchdog.Codec.negotiated(mimeType: mime, fmtp: "profile-id=4"))
        }
        for fmtp in [nil, "", "level-id=153", "profile-id=2", "profile-id=4;profile-id=4", "profile-id=4;PROFILE-ID=1", "profile-id=", "profile-id=4;broken"] as [String?] {
            XCTAssertNil(HEVCDecodeWatchdog.Codec.negotiated(mimeType: "video/H265", fmtp: fmtp))
        }
    }

    #if canImport(WebRTC)
    func testNativeInboundEntryDrivesRecoveryDespiteUnrelatedOutboundCodecAndPolling() throws {
        var watchdog = HEVCDecodeWatchdog()
        for time in 100...105 {
            let entries = [
                StreamStatsEntry(id: "out", type: "outbound-rtp", values: ["kind": "video", "codecId": "h264"], timestamp: 9999),
                StreamStatsEntry(id: "h264", type: "codec", values: ["mimeType": "video/H264", "sdpFmtpLine": "profile-id=1"]),
                StreamStatsEntry(id: "in", type: "inbound-rtp", values: ["kind": "video", "codecId": "main444", "framesReceived": time * 50, "framesDecoded": 0], timestamp: Double(time)),
                StreamStatsEntry(id: "main444", type: "codec", values: ["mimeType": "video/H265", "sdpFmtpLine": "profile-id=4"])
            ]
            let observed = try XCTUnwrap(PeerMedia.firstPictureDecodeObservation(entries))
            XCTAssertEqual(observed.timestamp, Double(time), "Other entries or polling time cannot advance the deadline")
            XCTAssertEqual(observed.identity.codec, .fullColor444, "Only the inbound codec determines fallback")
            XCTAssertEqual(watchdog.observe(observed), time == 105 ? .fullColor444 : nil)
        }
    }

    func testControlTrafficMissingDecodedCountAndUnmatchedCodecRemainUnknown() {
        let codec = StreamStatsEntry(id: "codec", type: "codec", values: ["mimeType": "video/H265", "sdpFmtpLine": "profile-id=4"])
        let control = StreamStatsEntry(id: "control", type: "data-channel", values: ["bytesReceived": 1_000_000], timestamp: 100)
        XCTAssertNil(PeerMedia.firstPictureDecodeObservation([control, codec]))
        let missingDecoded = StreamStatsEntry(id: "in", type: "inbound-rtp", values: ["kind": "video", "codecId": "codec", "framesReceived": 5000], timestamp: 100)
        XCTAssertNil(PeerMedia.firstPictureDecodeObservation([missingDecoded, codec]))
        let unmatched = StreamStatsEntry(id: "in", type: "inbound-rtp", values: ["kind": "video", "codecId": "another-codec", "framesReceived": 5000, "framesDecoded": 0], timestamp: 100)
        XCTAssertNil(PeerMedia.firstPictureDecodeObservation([unmatched, codec]))
    }
    #endif
}
