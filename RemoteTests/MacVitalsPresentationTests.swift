import XCTest

final class MacVitalsPresentationTests: XCTestCase {
    private typealias Row = MacVitalsPresentation.Row
    private let heavy = MacVitals(power: "battery", batteryPercent: 12, charging: false, batteryWarning: 2,
                                  thermal: 2, lowPowerMode: true, load: "busy", loadCause: "processor")

    private func caption(_ vitals: MacVitals) -> String { MacVitalsPresentation(vitals).caption }
    private func spoken(_ vitals: MacVitals) -> String { MacVitalsPresentation(vitals).spoken }
    private func warning(_ vitals: MacVitals) -> Bool { MacVitalsPresentation(vitals).isWarning }

    func testBaseCaptions() {
        XCTAssertEqual(caption(MacVitals(power: "battery", batteryPercent: 64, charging: false)), "Mac · on battery 64%")
        XCTAssertEqual(caption(MacVitals(power: "ac", batteryPercent: 82, charging: true)), "Mac · charging 82%")
        XCTAssertEqual(caption(MacVitals(power: "ac", batteryPercent: 80, charging: false)), "Mac · plugged in")
        XCTAssertEqual(caption(MacVitals(power: "ac", batteryPercent: 100)), "Mac · plugged in")
        XCTAssertEqual(caption(MacVitals(power: "ac")), "Mac · running normally")
        XCTAssertEqual(caption(MacVitals()), "Mac · running normally")
        XCTAssertEqual(caption(MacVitals(power: "battery")), "Mac · on battery")
        XCTAssertEqual(caption(MacVitals(power: "ups", batteryPercent: 80)), "Mac · on UPS 80%")
        XCTAssertEqual(caption(MacVitals(power: "ups")), "Mac · on UPS")
    }

    func testSuffixesInOrder() {
        XCTAssertEqual(caption(heavy), "Mac · on battery 12% · warm · Low Power Mode · busy")
        XCTAssertEqual(caption(MacVitals(power: "ac", batteryPercent: 90, charging: true, thermal: 3)), "Mac · charging 90% · hot")
        XCTAssertEqual(caption(MacVitals(power: "ac", batteryPercent: 90, charging: false, thermal: 1)), "Mac · plugged in",
                       "Fair is not shown")
    }

    func testRunningNormallyGivesWayToASuffix() {
        XCTAssertEqual(caption(MacVitals(power: "ac", thermal: 3, load: "busy")), "Mac · hot · busy")
        XCTAssertEqual(caption(MacVitals(lowPowerMode: true)), "Mac · Low Power Mode")
    }

    func testCaptionsDropTheLeastImportantWordsFirst() {
        XCTAssertEqual(MacVitalsPresentation(heavy).captions, [
            "Mac · on battery 12% · warm · Low Power Mode · busy",
            "Mac · on battery 12% · warm · busy",
            "Mac · on battery 12% · busy",
            "on battery 12% · busy",
        ])
        XCTAssertEqual(MacVitalsPresentation(MacVitals(power: "ac", thermal: 0, lowPowerMode: false, load: "ok")).captions,
                       ["Mac · running normally"])
        XCTAssertEqual(MacVitalsPresentation(MacVitals(power: "ac", batteryPercent: 90, charging: true, thermal: 3)).captions,
                       ["Mac · charging 90% · hot", "charging 90% · hot"], "Hot is never dropped")
        XCTAssertEqual(MacVitalsPresentation(MacVitals(lowPowerMode: true)).captions,
                       ["Mac · Low Power Mode", "running normally"])
        for vitals in [heavy, MacVitals(), MacVitals(power: "battery", batteryPercent: 64, charging: false)] {
            let words = MacVitalsPresentation(vitals)
            XCTAssertEqual(words.captions.first, words.caption)
        }
    }

    func testSpokenSentence() {
        XCTAssertEqual(spoken(MacVitals(power: "battery", batteryPercent: 12, thermal: 0, lowPowerMode: true, load: "busy")),
                       "Your Mac: on battery, 12 percent, Low Power Mode, busy.")
        XCTAssertEqual(spoken(heavy), "Your Mac: on battery, 12 percent, warm, Low Power Mode, busy.")
        XCTAssertEqual(spoken(MacVitals(power: "ac", batteryPercent: 82, charging: true)), "Your Mac: charging, 82 percent.")
        XCTAssertEqual(spoken(MacVitals(power: "ac", batteryPercent: 80)), "Your Mac: plugged in.")
        XCTAssertEqual(spoken(MacVitals(power: "ac")), "Your Mac: running normally.")
        XCTAssertEqual(spoken(MacVitals(power: "ups", batteryPercent: 80, thermal: 3)), "Your Mac: on UPS power, 80 percent, hot.")
    }

    func testWarningTone() {
        XCTAssertFalse(warning(MacVitals(power: "battery", batteryPercent: 64)))
        XCTAssertTrue(warning(MacVitals(power: "battery", batteryPercent: 20)))
        XCTAssertTrue(warning(MacVitals(power: "battery", batteryPercent: 40, batteryWarning: 2)))
        XCTAssertFalse(warning(MacVitals(power: "ac", batteryPercent: 15, charging: true)))
        XCTAssertTrue(warning(MacVitals(thermal: 2)))
        XCTAssertFalse(warning(MacVitals(thermal: 1)))
        XCTAssertTrue(warning(MacVitals(load: "busy")))
        XCTAssertFalse(warning(MacVitals(lowPowerMode: true)))
        XCTAssertFalse(warning(MacVitals()))
    }

    func testDiagnosticsRows() {
        XCTAssertEqual(MacVitalsPresentation(heavy).rows, [
            Row(title: "Power", value: "Battery · 12% · macOS low-battery warning"),
            Row(title: "Temperature", value: "Warm"),
            Row(title: "Low Power Mode", value: "On"),
            Row(title: "Load", value: "Busy · processor"),
        ])
        XCTAssertEqual(MacVitalsPresentation(MacVitals(power: "ac", thermal: 0, lowPowerMode: false, load: "ok")).rows, [
            Row(title: "Power", value: "Power adapter"),
            Row(title: "Temperature", value: "Normal"),
            Row(title: "Low Power Mode", value: "Off"),
            Row(title: "Load", value: "Normal"),
        ])
        XCTAssertEqual(MacVitalsPresentation(MacVitals()).rows.map(\.value), Array(repeating: "Not reported", count: 4))
    }

    func testPowerRowVariants() {
        func power(_ vitals: MacVitals) -> String? { MacVitalsPresentation(vitals).rows.first?.value }
        XCTAssertEqual(power(MacVitals(power: "ac", batteryPercent: 82, charging: true)), "Power adapter · charging · 82%")
        XCTAssertEqual(power(MacVitals(power: "ac", batteryPercent: 80, charging: false)), "Power adapter · 80%")
        XCTAssertEqual(power(MacVitals(power: "battery", batteryPercent: 4, batteryWarning: 3)), "Battery · 4% · macOS final battery warning")
        XCTAssertEqual(power(MacVitals(power: "ups", batteryPercent: 80)), "UPS · 80%")
        XCTAssertEqual(power(MacVitals(power: "ups")), "UPS")
        XCTAssertEqual(MacVitalsPresentation(MacVitals(thermal: 3)).rows[1].value, "Hot")
        XCTAssertEqual(MacVitalsPresentation(MacVitals(load: "busy", loadCause: "memory")).rows[3].value, "Busy · memory")
        XCTAssertEqual(MacVitalsPresentation(MacVitals(load: "busy")).rows[3].value, "Busy")
    }

    func testUnknownWordsReadAsNotReported() {
        let future = MacVitals(power: "solar", load: "melting", loadCause: "gpu")
        XCTAssertEqual(caption(future), "Mac · running normally")
        XCTAssertEqual(MacVitalsPresentation(future).rows[0].value, "Not reported")
        XCTAssertEqual(MacVitalsPresentation(future).rows[3].value, "Not reported")
    }

    func testFixedCopy() {
        XCTAssertEqual(MacVitalsPresentation.tooOld, "Your Mac’s Farside is too old to report battery and load. Update it on your Mac.")
    }

    #if DEBUG
    func testPreviewsForLayoutChecks() throws {
        XCTAssertEqual(caption(try XCTUnwrap(MacVitalsPresentation.preview("battery12"))),
                       "Mac · on battery 12% · warm · Low Power Mode · busy")
        XCTAssertEqual(caption(try XCTUnwrap(MacVitalsPresentation.preview("battery64"))), "Mac · on battery 64%")
        XCTAssertEqual(caption(try XCTUnwrap(MacVitalsPresentation.preview("charging82"))), "Mac · charging 82%")
        XCTAssertEqual(caption(try XCTUnwrap(MacVitalsPresentation.preview("desktop"))), "Mac · running normally")
        XCTAssertNil(MacVitalsPresentation.preview("nonsense"))
        for name in ["battery12", "battery64", "charging82", "desktop"] {
            XCTAssertNoThrow(try MacVitalsPresentation.preview(name)?.validate())
        }
    }
    #endif
}
