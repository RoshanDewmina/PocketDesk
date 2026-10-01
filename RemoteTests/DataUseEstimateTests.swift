import XCTest

final class DataUseEstimateTests: XCTestCase {
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
        XCTAssertEqual(TransportByteSplit.media(entries), 1325)
        XCTAssertEqual(TransportByteSplit.files(entries, label: "file"), 100)
        XCTAssertEqual(TransportByteSplit.files(Array(entries.prefix(3)), label: "file"), 0, "No file channel carries no file bytes")
        let unreported = [StreamStatsEntry(id: "v", type: "inbound-rtp", values: ["kind": "video"])]
        XCTAssertNil(TransportByteSplit.media(unreported))
    }
}
