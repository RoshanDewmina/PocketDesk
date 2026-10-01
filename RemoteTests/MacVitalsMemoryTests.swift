import XCTest

final class MacVitalsMemoryTests: XCTestCase {
    private let suite = "MacVitalsMemoryTests"
    private var defaults: UserDefaults!
    private var memory: MacVitalsMemory!
    private let noon = Date(timeIntervalSince1970: 1_790_000_000)
    private let room = "studio-room", otherRoom = "laptop-room"

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
        memory.record(battery(4), at: noon, room: room)
        let seen = try XCTUnwrap(memory.lastSeen(room: room, now: noon.addingTimeInterval(3600)))
        XCTAssertEqual(seen, MacVitalsMemory.LastSeen(percent: 4, at: noon))
        XCTAssertEqual(MacVitalsMemory.homeNote(seen), "Last seen on battery · 4%")
        XCTAssertEqual(MacVitalsMemory.sleepNote(seen), "It was on battery at 4%, which may be why.")
        XCTAssertNotNil(memory.lastSeen(room: room, now: noon.addingTimeInterval(3600)), "Reading does not consume it")
    }

    func testTenCountsElevenDoesNot() {
        memory.record(battery(10), at: noon, room: room)
        XCTAssertEqual(memory.lastSeen(room: room, now: noon)?.percent, 10)
        memory.record(battery(11), at: noon, room: room)
        XCTAssertNil(memory.lastSeen(room: room, now: noon))
    }

    func testExpiresAfterTwelveHours() {
        memory.record(battery(4), at: noon, room: room)
        XCTAssertNotNil(memory.lastSeen(room: room, now: noon.addingTimeInterval(12 * 3600 - 1)))
        XCTAssertNil(memory.lastSeen(room: room, now: noon.addingTimeInterval(12 * 3600 + 1)))
        XCTAssertNil(defaults.object(forKey: MacVitalsMemory.defaultsKey), "An expired entry is removed")
    }

    func testPluggedInUnknownOrMissingClears() {
        for other in [MacVitals(power: "ac", batteryPercent: 4, charging: true), MacVitals(power: "ups", batteryPercent: 4),
                      battery(nil), MacVitals()] {
            memory.record(battery(4), at: noon, room: room)
            memory.record(other, at: noon, room: room)
            XCTAssertNil(memory.lastSeen(room: room, now: noon), "\(other)")
        }
        memory.record(battery(4), at: noon, room: room)
        memory.record(nil, at: noon, room: room)
        XCTAssertNil(memory.lastSeen(room: room, now: noon))
    }

    func testFutureDatedEntryIsDiscarded() {
        memory.record(battery(4), at: noon.addingTimeInterval(7200), room: room)
        XCTAssertNil(memory.lastSeen(room: room, now: noon), "A clock change must not keep a note forever")
        memory.record(battery(4), at: noon.addingTimeInterval(60), room: room)
        XCTAssertNotNil(memory.lastSeen(room: room, now: noon), "A minute of skew is tolerated")
    }

    func testForget() {
        memory.record(battery(4), at: noon, room: room)
        memory.forget(room: room)
        XCTAssertNil(memory.lastSeen(room: room, now: noon))
    }

    func testCorruptStorageIsIgnored() {
        defaults.set(Data("not json".utf8), forKey: MacVitalsMemory.defaultsKey)
        XCTAssertNil(memory.lastSeen(room: room, now: noon))
        defaults.set("text", forKey: MacVitalsMemory.defaultsKey)
        XCTAssertNil(memory.lastSeen(room: room, now: noon))
    }

    func testEachMacKeepsItsOwnReading() throws {
        memory.record(battery(4), at: noon, room: room)
        XCTAssertNil(memory.lastSeen(room: otherRoom, now: noon), "Another Mac never shows this Mac's battery")
        memory.record(battery(7), at: noon, room: otherRoom)
        memory.record(nil, at: noon, room: otherRoom)
        XCTAssertEqual(memory.lastSeen(room: room, now: noon)?.percent, 4, "Another Mac's session never erases this one")
        memory.forget(room: otherRoom)
        XCTAssertEqual(memory.lastSeen(room: room, now: noon)?.percent, 4)
        defaults.set(Data("{}".utf8), forKey: MacVitalsMemory.legacyDefaultsKey)
        XCTAssertNil(MacVitalsMemory(defaults: defaults).defaults.object(forKey: MacVitalsMemory.legacyDefaultsKey),
                     "The old shared reading can't be attributed to a Mac")
    }

    func testOnlyPercentAndTimeAreStored() throws {
        memory.record(MacVitals(power: "battery", batteryPercent: 3, charging: false, batteryWarning: 3,
                                thermal: 2, lowPowerMode: true, load: "busy", loadCause: "memory"), at: noon, room: room)
        let data = try XCTUnwrap(defaults.data(forKey: MacVitalsMemory.defaultsKey))
        let all = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Array(all.keys), [MacVitalsMemory.macKey(room: room)], "Keyed by a digest, never the room")
        let object = try XCTUnwrap(all.values.first as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["percent", "at"])
    }
}
