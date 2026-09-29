import XCTest

/// The pill's words: calm, plain, and about what the stream is now.
final class BusyPresentationTests: XCTestCase {
    private func words(_ level: BusyState.Level, fps: Int = 30, longEdge: Int = 1440, reason: String,
                       device: String = "iPhone") -> BusyPresentation? {
        BusyPresentation(BusyState(level: level, fps: fps, longEdge: longEdge, reason: reason), device: device)
    }

    func testOkHasNothingToShow() {
        XCTAssertNil(BusyPresentation(.ok))
        XCTAssertNil(words(.ok, reason: "encoding"), "ok never shows, whatever else the state carries")
    }

    func testTitleAndSymbolForEveryLevelAndReason() {
        let rows: [(BusyState.Level, String, String, String)] = [
            (.busy, "encoding", "Your Mac is busy", "laptopcomputer"),
            (.strained, "encoding", "Your Mac is working hard", "laptopcomputer"),
            (.busy, "capture", "Your Mac is busy", "laptopcomputer"),
            (.strained, "capture", "Your Mac is working hard", "laptopcomputer"),
            (.busy, "thermal", "Your Mac is running warm", "thermometer.medium"),
            (.strained, "thermal", "Your Mac is running warm", "thermometer.medium"),
            (.busy, "network", "The connection is slow", "wifi"),
            (.strained, "network", "The connection is a little slow", "wifi"),
            (.busy, "phone", "Your iPhone is busy", "iphone"),
            (.strained, "phone", "Your iPhone is working hard", "iphone"),
            (.busy, "power", "Your Mac is saving power", "battery.25percent"),
            (.strained, "power", "Your Mac is saving power", "battery.25percent"),
            (.busy, "", "Your Mac is busy", "laptopcomputer"),
            (.strained, "something new", "Your Mac is working hard", "laptopcomputer"),
        ]
        for (level, reason, title, symbol) in rows {
            let presentation = words(level, reason: reason)
            XCTAssertEqual(presentation?.title, title, "\(level) \(reason)")
            XCTAssertEqual(presentation?.symbol, symbol, "\(level) \(reason)")
        }
        let covered = Set(rows.map { $0.1 })
        XCTAssertTrue(LadderReason.allCases.allSatisfy { covered.contains($0.rawValue) }, "every reason has words")
    }

    func testDetailSaysWhatTheStreamIsNow() {
        XCTAssertEqual(words(.busy, reason: "encoding")?.detail, "30 fps at 1440 px · encoding")
        XCTAssertEqual(words(.busy, reason: "capture")?.detail, "30 fps at 1440 px · screen capture")
        XCTAssertEqual(words(.strained, fps: 60, longEdge: 1920, reason: "network")?.detail, "60 fps at 1920 px",
                       "the title already names the connection")
        XCTAssertEqual(words(.busy, fps: 60, longEdge: 1920, reason: "phone")?.detail, "60 fps at 1920 px")
        XCTAssertEqual(words(.busy, longEdge: 1280, reason: "thermal")?.detail, "30 fps at 1280 px")
        XCTAssertEqual(words(.strained, fps: 60, longEdge: 2560, reason: "power")?.detail, "60 fps at 2560 px",
                       "the title already says it is saving power")
        XCTAssertEqual(words(.busy, longEdge: 0, reason: "encoding")?.detail, "30 fps · encoding",
                       "an unknown size is left out")
        XCTAssertEqual(words(.busy, fps: 0, reason: "network")?.detail, "1440 px")
        XCTAssertNil(words(.busy, fps: 0, longEdge: 0, reason: "network")?.detail)
        XCTAssertEqual(words(.busy, fps: 0, longEdge: 0, reason: "encoding")?.detail, "encoding")
    }

    func testAccessibilityLabelReadsAsASentence() {
        XCTAssertEqual(words(.busy, reason: "encoding")?.accessibilityLabel,
                       "Your Mac is busy. 30 frames per second at 1440 pixels, limited by encoding.")
        XCTAssertEqual(words(.strained, fps: 60, longEdge: 1920, reason: "network")?.accessibilityLabel,
                       "The connection is a little slow. 60 frames per second at 1920 pixels.")
        XCTAssertEqual(words(.busy, fps: 0, longEdge: 0, reason: "network")?.accessibilityLabel,
                       "The connection is slow.")
        XCTAssertEqual(words(.strained, fps: 60, longEdge: 2560, reason: "power")?.accessibilityLabel,
                       "Your Mac is saving power. 60 frames per second at 2560 pixels.")
        XCTAssertEqual(words(.busy, fps: 0, longEdge: 0, reason: "capture")?.accessibilityLabel,
                       "Your Mac is busy. Limited by screen capture.")
    }

    func testThePhoneIsNamedByItsKind() {
        let iPad = words(.busy, reason: "phone", device: "iPad")
        XCTAssertEqual(iPad?.title, "Your iPad is busy")
        XCTAssertEqual(iPad?.symbol, "ipad")
        XCTAssertEqual(words(.strained, reason: "phone", device: "iPad")?.title, "Your iPad is working hard")
        XCTAssertEqual(words(.busy, reason: "encoding", device: "iPad")?.title, "Your Mac is busy",
                       "the device kind only matters when the phone is the limit")
    }

    func testCopyIsCalmAndPlain() throws {
        let banned = ["!", "fault", "error", "fail", "cpu", "bitrate", "kbps", "encoder", "your wi-fi", "your network",
                      "sorry", "problem"]
        for level in [BusyState.Level.strained, .busy] {
            for reason in LadderReason.allCases.map(\.rawValue) + [""] {
                let presentation = try XCTUnwrap(words(level, fps: 120, longEdge: 2560, reason: reason))
                let text = [presentation.title, presentation.detail ?? "", presentation.accessibilityLabel]
                    .joined(separator: " ").lowercased()
                for word in banned {
                    XCTAssertFalse(text.contains(word), "\(level) \(reason): “\(word)” in “\(text)”")
                }
                XCTAssertLessThanOrEqual(presentation.title.count, 32, "fits the pill on a phone in portrait")
            }
        }
    }

    func testEveryStateThePolicyCanSendIsValidAndWorded() throws {
        for target in [60, 120] {
            for rung in LadderPolicy.ladder(targetFPS: target) {
                for reason in LadderReason.allCases {
                    let state = BusyState(level: .busy, fps: rung.fps,
                                          longEdge: Int((6016 * rung.sizeFraction).rounded()), reason: reason.rawValue)
                    XCTAssertNoThrow(try state.validate())
                    let presentation = try XCTUnwrap(BusyPresentation(state))
                    XCTAssertTrue(presentation.detail?.hasPrefix("\(rung.fps) fps at ") == true, "\(state)")
                }
            }
        }
    }
}
