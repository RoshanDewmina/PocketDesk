import XCTest

final class DataUseEstimateTests: XCTestCase {
    func testPictureModesKeepWirePresetsAndModeSpecificDataUse() throws {
        XCTAssertEqual(PictureMode.allCases, [.quality, .performance])
        XCTAssertEqual(PictureMode.defaultMode, .quality)
        XCTAssertEqual(PictureMode.quality.streamQuality, .sharp)
        XCTAssertEqual(PictureMode.performance.streamQuality, .balanced)
        XCTAssertEqual(PictureMode(quality: .sharp), .quality)
        XCTAssertEqual(PictureMode(quality: .balanced), .performance)
        XCTAssertFalse(PictureMode.quality.prioritizesFrameRate)
        XCTAssertTrue(PictureMode.performance.prioritizesFrameRate)
        XCTAssertEqual(StreamQuality.sharp.title, "Quality")
        XCTAssertEqual(StreamQuality.balanced.title, "Performance")
        // The transport still sends the old enum values, even to a pre-modes Mac.
        XCTAssertEqual(String(data: try JSONEncoder().encode(PictureMode.quality.streamQuality), encoding: .utf8), "\"sharp\"")
        for mode in PictureMode.allCases {
            let estimate = DataUseEstimate(mode.streamQuality, audio: false, packetRepair: false)
            XCTAssertEqual(estimate.highGBPerHour, mode == .quality ? 11.25 : 5.4, accuracy: 1e-9)
            XCTAssertEqual(estimate.lowGBPerHour, mode == .quality ? 0.18 : 0.09, accuracy: 1e-9)
        }
    }

    func testSustained25MbpsIs11Point25GigabytesPerHour() {
        XCTAssertEqual(DataUseEstimate.gigabytesPerHour(kbps: 25_000), 11.25, accuracy: 1e-9)
        XCTAssertEqual(DataUseEstimate.gigabytesPerHour(kbps: 8_000), 3.6, accuracy: 1e-9)
        XCTAssertEqual(DataUseEstimate.gigabytesPerHour(kbps: -5), 0)
    }

    func testRangeRunsFromStillToMotionAndAddsAudioThenRepairOnVideoOnly() {
        let plain = DataUseEstimate(videoKbps: 400...25_000)
        XCTAssertLessThan(plain.lowGBPerHour, plain.highGBPerHour)
        let audio = DataUseEstimate(videoKbps: 400...25_000, audioKbps: 64)
        XCTAssertEqual(audio.lowKbps, 464); XCTAssertEqual(audio.highKbps, 25_064)
        let repaired = DataUseEstimate(videoKbps: 400...25_000, audioKbps: 64, repairOverhead: 0.2)
        XCTAssertEqual(repaired.lowKbps, 544, accuracy: 1e-9); XCTAssertEqual(repaired.highKbps, 30_064, accuracy: 1e-9)
        XCTAssertEqual(repaired.highGBPerHour, 13.5288, accuracy: 1e-9)
    }

    func testEveryPresetMapsToItsEncoderCeilingAndStillFloor() {
        let expected: [StreamQuality: (low: Double, high: Double)] = [.balanced: (0.09, 5.4), .sharp: (0.18, 11.25)]
        XCTAssertEqual(Set(expected.keys), Set(StreamQuality.allCases))
        for quality in StreamQuality.allCases {
            let estimate = DataUseEstimate(quality, audio: false, packetRepair: false)
            XCTAssertEqual(estimate.highKbps, Double(quality.maximumBitrateBps) / 1000)
            XCTAssertEqual(estimate.lowGBPerHour, expected[quality]!.low, accuracy: 1e-9, quality.rawValue)
            XCTAssertEqual(estimate.highGBPerHour, expected[quality]!.high, accuracy: 1e-9, quality.rawValue)
            let full = DataUseEstimate(quality, audio: true, packetRepair: true)
            XCTAssertGreaterThan(full.lowKbps, estimate.lowKbps); XCTAssertGreaterThan(full.highKbps, estimate.highKbps)
        }
        XCTAssertLessThan(DataUseEstimate(.balanced, audio: true, packetRepair: false).highGBPerHour,
                          DataUseEstimate(.sharp, audio: true, packetRepair: false).highGBPerHour)
    }

    func testDisplayRoundsForReadingAndNeverShowsZero() {
        let english = Locale(identifier: "en_US"), french = Locale(identifier: "fr_CA")
        XCTAssertEqual(DataUseEstimate.display(11.25, locale: english), "11")
        XCTAssertEqual(DataUseEstimate.display(5.4, locale: english), "5.4")
        XCTAssertEqual(DataUseEstimate.display(5.4, locale: french), "5,4")
        XCTAssertEqual(DataUseEstimate.display(0.09, locale: english), "0.1")
        XCTAssertEqual(DataUseEstimate.display(0.001, locale: english), "0.1")
        XCTAssertEqual(DataUseEstimate.display(2, locale: english), "2")
    }

    func testByteSplitCountsRTPPayloadAndHeadersAndOnlyTheFileChannel() {
        let entries = [
            StreamStatsEntry(id: "v", type: "inbound-rtp", values: ["kind": "video", "bytesReceived": 1000, "headerBytesReceived": 100]),
            StreamStatsEntry(id: "a", type: "inbound-rtp", values: ["kind": "audio", "bytesReceived": 200, "headerBytesReceived": 20]),
            StreamStatsEntry(id: "o", type: "outbound-rtp", values: ["kind": "video", "bytesSent": 5]),
            StreamStatsEntry(id: "f", type: "data-channel", values: ["label": "file", "bytesSent": 30, "bytesReceived": 70]),
            StreamStatsEntry(id: "c", type: "data-channel", values: ["label": "control", "bytesSent": 999, "bytesReceived": 999])]
        XCTAssertEqual(TransportByteSplit.media(entries), ["v": 1100, "a": 220, "o": 5])
        XCTAssertEqual(TransportByteSplit.files(entries, label: "file"), ["f": 100])
        XCTAssertEqual(TransportByteSplit.files(Array(entries.prefix(3)), label: "file"), [:], "No file channel carries no file bytes")
        let unreported = [StreamStatsEntry(id: "v", type: "inbound-rtp", values: ["kind": "video"])]
        XCTAssertNil(TransportByteSplit.media(unreported))
    }

    func testPerEntryGrowthSurvivesVanishingNewAndRestartedEntries() {
        XCTAssertEqual(TransportByteSplit.growth(from: ["v": 100, "a": 50], to: ["v": 300, "a": 80]), 230)
        XCTAssertEqual(TransportByteSplit.growth(from: ["v": 100, "gone": 999], to: ["v": 150, "new": 40]), 50,
                       "A vanished entry adds nothing; a new one is only a baseline")
        XCTAssertEqual(TransportByteSplit.growth(from: ["v": 500], to: ["v": 20]), 0, "A restarted counter is not negative growth")
    }

    func testEstimateFollowsTheTuningCeilingOverride() {
        var tuning = StreamTuning.tuned
        tuning.encoderCeilingKbps = 8_000
        let capped = DataUseEstimate(.sharp, tuning: tuning, audio: false, packetRepair: false)
        XCTAssertEqual(capped.highKbps, 8_000); XCTAssertEqual(capped.highGBPerHour, 3.6, accuracy: 1e-9)
        tuning.encoderCeilingKbps = 1_000
        XCTAssertLessThanOrEqual(DataUseEstimate(.sharp, tuning: tuning, audio: false, packetRepair: false).lowKbps, 1_000)
    }
}
