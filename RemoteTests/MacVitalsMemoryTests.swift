import XCTest

final class MacVitalsMemoryTests: XCTestCase {
    private let suite = "MacVitalsMemoryTests"
    private var defaults: UserDefaults!
    private var memory: MacVitalsMemory!
    private let noon = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        memory = MacVitalsMemory(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func battery(_ percent: Int?) -> MacVitals { MacVitals(power: "battery", batteryPercent: percent, charging: false) }

    func testALowBatteryIsRememberedWithItsWords() throws {
        memory.record(battery(4), at: noon)
        let seen = try XCTUnwrap(memory.lastSeen(now: noon.addingTimeInterval(3600)))
        XCTAssertEqual(seen, MacVitalsMemory.LastSeen(percent: 4, at: noon))
        XCTAssertEqual(MacVitalsMemory.homeNote(seen), "Last seen on battery · 4%")
        XCTAssertEqual(MacVitalsMemory.sleepNote(seen), "It was on battery at 4%, which may be why.")
        XCTAssertNotNil(memory.lastSeen(now: noon.addingTimeInterval(3600)), "Reading does not consume it")
    }

    func testTenCountsElevenDoesNot() {
        memory.record(battery(10), at: noon)
        XCTAssertEqual(memory.lastSeen(now: noon)?.percent, 10)
        memory.record(battery(11), at: noon)
        XCTAssertNil(memory.lastSeen(now: noon))
    }

    func testExpiresAfterTwelveHours() {
        memory.record(battery(4), at: noon)
        XCTAssertNotNil(memory.lastSeen(now: noon.addingTimeInterval(12 * 3600 - 1)))
        XCTAssertNil(memory.lastSeen(now: noon.addingTimeInterval(12 * 3600 + 1)))
        XCTAssertNil(defaults.object(forKey: MacVitalsMemory.defaultsKey), "An expired entry is removed")
    }

    func testPluggedInUnknownOrMissingClears() {
        for other in [MacVitals(power: "ac", batteryPercent: 4, charging: true), MacVitals(power: "ups", batteryPercent: 4),
                      battery(nil), MacVitals()] {
            memory.record(battery(4), at: noon)
            memory.record(other, at: noon)
            XCTAssertNil(memory.lastSeen(now: noon), "\(other)")
        }
        memory.record(battery(4), at: noon)
        memory.record(nil, at: noon)
        XCTAssertNil(memory.lastSeen(now: noon))
    }

    func testFutureDatedEntryIsDiscarded() {
        memory.record(battery(4), at: noon.addingTimeInterval(7200))
        XCTAssertNil(memory.lastSeen(now: noon), "A clock change must not keep a note forever")
        memory.record(battery(4), at: noon.addingTimeInterval(60))
        XCTAssertNotNil(memory.lastSeen(now: noon), "A minute of skew is tolerated")
    }

    func testForget() {
        memory.record(battery(4), at: noon)
        memory.forget()
        XCTAssertNil(memory.lastSeen(now: noon))
    }

    func testCorruptStorageIsIgnored() {
        defaults.set(Data("not json".utf8), forKey: MacVitalsMemory.defaultsKey)
        XCTAssertNil(memory.lastSeen(now: noon))
        defaults.set("text", forKey: MacVitalsMemory.defaultsKey)
        XCTAssertNil(memory.lastSeen(now: noon))
    }

    func testOnlyPercentAndTimeAreStored() throws {
        memory.record(MacVitals(power: "battery", batteryPercent: 3, charging: false, batteryWarning: 3,
                                thermal: 2, lowPowerMode: true, load: "busy", loadCause: "memory"), at: noon)
        let data = try XCTUnwrap(defaults.data(forKey: MacVitalsMemory.defaultsKey))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["percent", "at"])
    }
}
