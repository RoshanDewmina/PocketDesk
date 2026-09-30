import XCTest

final class MacVitalsProtocolTests: XCTestCase {
    private let laptop = MacVitals(power: "battery", batteryPercent: 64, charging: false, batteryWarning: 1,
                                   thermal: 0, lowPowerMode: false, load: "ok")

    func testCaptureStatusCarriesVitals() {
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, epoch: 2, macVitals: laptop).validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, epoch: 2, macVitals: MacVitals()).validate(),
                         "A Mac that read nothing sends an empty object")
        let busy = MacVitals(power: "ac", load: "busy", loadCause: "memory")
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, epoch: 2, macVitals: busy).validate())
    }

    func testVitalsRideOnlyOnCaptureStatus() {
        let valid = [
            RemoteAction(action: "heartbeat", epoch: 2),
            RemoteAction(action: "displays", epoch: 2),
            RemoteAction(action: "display", epoch: 2, display: 1),
            RemoteAction(action: "pause", epoch: 2),
            RemoteAction(action: "click", epoch: 2),
        ]
        for base in valid {
            XCTAssertNoThrow(try base.validate(), "\(base.action) must be valid on its own")
            var carrying = base
            carrying.macVitals = laptop
            XCTAssertThrowsError(try carrying.validate(), "\(base.action) must not carry vitals")
        }
    }

    func testOutOfRangeValuesAreRejected() {
        let invalid = [
            MacVitals(batteryPercent: 101), MacVitals(batteryPercent: -1),
            MacVitals(batteryWarning: 0), MacVitals(batteryWarning: 4),
            MacVitals(thermal: -1), MacVitals(thermal: 4),
            MacVitals(power: ""), MacVitals(power: "batterybattery"), MacVitals(power: "b@ttery"),
            MacVitals(power: "on battery"), MacVitals(load: "busy\n"), MacVitals(loadCause: "prøcessor"),
        ]
        for vitals in invalid {
            XCTAssertThrowsError(try vitals.validate(), "\(vitals)")
            XCTAssertThrowsError(try RemoteAction(action: "capture", epoch: 2, macVitals: vitals).validate(), "\(vitals)")
        }
    }

    func testUnknownWordsBecomeNil() throws {
        let future = MacVitals(power: "solar", thermal: 2, load: "melting", loadCause: "gpu")
        XCTAssertNoThrow(try future.validate(), "A newer Mac's word must not end the session")
        XCTAssertNil(future.powerSource)
        XCTAssertNil(future.loadLevel)
        XCTAssertNil(future.cause)
        XCTAssertEqual(future.thermalLevel, .serious)
    }

    func testClampedAlwaysValidates() {
        let wild = MacVitals(power: "averyveryverylongword", batteryPercent: 250, charging: true, batteryWarning: 9,
                             thermal: -3, lowPowerMode: true, load: "b u s y", loadCause: "")
        let clamped = wild.clamped()
        XCTAssertNoThrow(try clamped.validate())
        XCTAssertEqual(clamped.batteryPercent, 100)
        XCTAssertEqual(clamped.batteryWarning, 3)
        XCTAssertEqual(clamped.thermal, 0)
        XCTAssertNil(clamped.power, "A word that fails the charset or length check is dropped, not truncated")
        XCTAssertNil(clamped.load)
        XCTAssertNil(clamped.loadCause)
        XCTAssertEqual(clamped.charging, true)
        XCTAssertEqual(clamped.lowPowerMode, true)
        XCTAssertEqual(laptop.clamped(), laptop, "Valid vitals are unchanged")
        XCTAssertEqual(MacVitals(batteryPercent: -4).clamped().batteryPercent, 0)
    }

    func testOlderPhonesIgnoreTheField() throws {
        struct OldAction: Decodable { var action: String; var epoch: UInt64 }
        let data = try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 5, macVitals: laptop))
        XCTAssertEqual(try JSONDecoder().decode(OldAction.self, from: data).epoch, 5)
        let json = #"{"action":"capture","x":1,"y":0,"text":"","key":"","modifiers":[],"epoch":5}"#
        XCTAssertNil(try JSONDecoder().decode(RemoteAction.self, from: Data(json.utf8)).macVitals,
                     "An older Mac's status decodes with no vitals")
    }

    func testRoundTrip() throws {
        let action = RemoteAction(action: "capture", x: 1, epoch: 5, macVitals: laptop)
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(action))
        XCTAssertEqual(decoded.macVitals, laptop)
        XCTAssertNoThrow(try decoded.validate())
    }

    func testFeatureIsAdvertised() {
        XCTAssertEqual(SessionFeature.macVitals, "vitals.1")
        XCTAssertTrue(SessionFeature.host.contains(SessionFeature.macVitals))
        XCTAssertLessThanOrEqual(SessionFeature.host.count, 16, "The phone rejects more than 16 features")
    }
}
