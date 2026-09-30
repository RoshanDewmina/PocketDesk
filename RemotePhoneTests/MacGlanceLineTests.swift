import XCTest
@testable import PocketDeskRemote

final class MacGlanceLineTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let britain = Locale(identifier: "en_GB")
    private let seen1141 = 1_790_768_490
    private let seen0905 = 1_790_759_100

    private func line(_ presence: MacPresence?, stale: Bool = false) -> String? {
        MacGlanceLine.text(for: presence, isStale: stale, timeZone: utc, locale: britain)
    }

    private func presence(_ state: String?, seen: Int? = nil, battery: Int? = nil) -> MacPresence {
        MacPresence(macState: state, macSeenUnix: seen, batteryPercent: battery, power: nil)
    }

    func testNoPresenceMeansNoLine() {
        XCTAssertNil(line(nil))
        XCTAssertNil(line(nil, stale: true))
    }

    func testAnAwakeMacShowsWhenItWasSeenAndItsBattery() {
        XCTAssertEqual(line(presence("awake", seen: seen1141, battery: 64)), "Mac · seen 11:41 · 64%")
        XCTAssertEqual(line(presence("awake", seen: seen1141)), "Mac · seen 11:41")
        XCTAssertEqual(line(presence("awake", seen: seen0905, battery: 100)), "Mac · seen 09:05 · 100%")
        XCTAssertEqual(line(presence("awake", seen: seen0905, battery: 1)), "Mac · seen 09:05 · 1%")
    }

    func testTwelveHourLocalesUseANarrowMarker() {
        let unitedStates = Locale(identifier: "en_US")
        let seen1259 = 1_790_773_170
        func line(_ presence: MacPresence) -> String? {
            MacGlanceLine.text(for: presence, isStale: false, timeZone: utc, locale: unitedStates)
        }
        let note = "ICU's narrow marker (spec Amendment 3); a runtime update may change the spacing, not the meaning"
        XCTAssertEqual(line(presence("awake", seen: seen1141, battery: 64)), "Mac · seen 11:41\u{202F}a · 64%", note)
        XCTAssertEqual(line(presence("awake", seen: seen1259, battery: 100)), "Mac · seen 12:59\u{202F}p · 100%")
        XCTAssertEqual(line(presence("asleep", seen: seen1259)), "Mac · asleep since 12:59\u{202F}p")
        XCTAssertEqual(line(presence("notSeen", seen: seen0905)), "Not seen since 9:05\u{202F}a")
    }

    func testAnAwakeMacWithoutASeenTimeIsNotSeen() {
        XCTAssertEqual(line(presence("awake", battery: 64)), "Mac not seen lately")
    }

    func testAStaleActivityShowsWhenTheMacWasLastSeen() {
        XCTAssertEqual(line(presence("awake", seen: seen1141, battery: 64), stale: true), "Not seen since 11:41")
        XCTAssertEqual(line(presence("asleep", seen: seen1141), stale: true), "Not seen since 11:41")
        XCTAssertEqual(line(presence("awake"), stale: true), "Mac not seen lately")
    }

    func testANotSeenMac() {
        XCTAssertEqual(line(presence("notSeen", seen: seen0905)), "Not seen since 09:05")
        XCTAssertEqual(line(presence("notSeen")), "Mac not seen lately")
        XCTAssertEqual(line(presence(nil, seen: seen1141, battery: 64)), "Not seen since 11:41")
    }

    func testAnAsleepMac() {
        XCTAssertEqual(line(presence("asleep", seen: seen1141)), "Mac · asleep since 11:41")
        XCTAssertEqual(line(presence("asleep")), "Mac · asleep")
    }

    func testStaleOrUnseenMacNeverLooksAwake() {
        let inputs: [(MacPresence, Bool)] = [
            (presence("awake", seen: seen1141, battery: 64), true),
            (presence("asleep", seen: seen1141, battery: 64), true),
            (presence("notSeen", seen: seen1141, battery: 64), false),
            (presence("notSeen", seen: seen1141, battery: 64), true),
            (presence("hibernating", seen: seen1141, battery: 64), false),
            (presence(nil, seen: seen1141, battery: 64), false),
            (presence("awake", battery: 64), false),
            (presence("notSeen"), false),
        ]
        for (presence, stale) in inputs {
            guard let text = line(presence, stale: stale) else {
                XCTFail("Known presence always gets a line: \(presence)")
                continue
            }
            XCTAssertNil(text.range(of: #"seen \d"#, options: .regularExpression), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("awake"), text)
            XCTAssertFalse(text.contains("%"), "A Mac that is not known to be up shows no battery: \(text)")
        }
    }

    func testMissingOrImpossibleBatteryIsOmitted() {
        for battery in [nil, 0, -5, 101, 250] {
            let text = line(presence("awake", seen: seen1141, battery: battery))
            XCTAssertEqual(text, "Mac · seen 11:41", "\(String(describing: battery))")
        }
        XCTAssertEqual(line(presence("awake", seen: seen1141, battery: 64)), "Mac · seen 11:41 · 64%")
    }

    func testAsleepNeverShowsBattery() {
        XCTAssertEqual(line(presence("asleep", seen: seen1141, battery: 64)), "Mac · asleep since 11:41")
        XCTAssertEqual(line(presence("asleep", battery: 64)), "Mac · asleep")
    }

    func testPresenceDecodesWhenFieldsAreMissingOrUnknown() throws {
        let empty = try JSONDecoder().decode(MacPresence.self, from: Data("{}".utf8))
        XCTAssertNil(empty.macState)
        XCTAssertNil(empty.macSeenUnix)
        XCTAssertNil(empty.batteryPercent)
        XCTAssertNil(empty.power)
        XCTAssertNil(empty.seenAt)
        XCTAssertEqual(empty.state, .notSeen)

        let unknown = try JSONDecoder().decode(MacPresence.self, from: Data(#"{"macState":"hibernating"}"#.utf8))
        XCTAssertEqual(unknown.state, .notSeen)

        let full = MacPresence(macState: "awake", macSeenUnix: seen1141, batteryPercent: 64, power: "battery")
        let decoded = try JSONDecoder().decode(MacPresence.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(decoded, full)
        XCTAssertEqual(decoded.state, .awake)
        XCTAssertEqual(decoded.seenAt, Date(timeIntervalSince1970: TimeInterval(seen1141)))
        XCTAssertEqual(presence("asleep").state, .asleep)
        XCTAssertEqual(presence("notSeen").state, .notSeen)
    }

    func testAFieldOfTheWrongTypeDecodesAsAbsentInsteadOfFailingTheState() throws {
        let wrong = #"{"macState":7,"macSeenUnix":"soon","batteryPercent":64.5,"power":false}"#
        let decoded = try JSONDecoder().decode(MacPresence.self, from: Data(wrong.utf8))
        XCTAssertEqual(decoded, MacPresence())
        XCTAssertEqual(decoded.state, .notSeen)
        let partly = try JSONDecoder().decode(MacPresence.self, from: Data(#"{"macState":"awake","macSeenUnix":"x","batteryPercent":64}"#.utf8))
        XCTAssertEqual(partly, MacPresence(macState: "awake", batteryPercent: 64))
        XCTAssertEqual(MacGlanceLine.text(for: partly, isStale: false, timeZone: utc, locale: britain), "Mac not seen lately",
                       "Awake without a readable seen time is not claimed")
    }

    func testPresenceEncodesToPlainStringsAndIntegers() throws {
        let full = MacPresence(macState: "awake", macSeenUnix: seen1141, batteryPercent: 64, power: "battery")
        let data = try JSONEncoder().encode(full)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["macState", "macSeenUnix", "batteryPercent", "power"])
        XCTAssertEqual(object as NSDictionary,
                       ["macState": "awake", "macSeenUnix": seen1141, "batteryPercent": 64, "power": "battery"] as NSDictionary)
        XCTAssertTrue(object["macState"] is String)
        XCTAssertTrue(object["power"] is String)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertNotNil(text.range(of: #""macSeenUnix":1790768490[,}]"#, options: .regularExpression),
                        "Seen time is integer Unix seconds on the wire: \(text)")
        XCTAssertNotNil(text.range(of: #""batteryPercent":64[,}]"#, options: .regularExpression),
                        "Battery is an integer on the wire: \(text)")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(MacPresence())) as? NSDictionary, [:] as NSDictionary,
                       "Absent fields are omitted, not sent as null")
    }
}
