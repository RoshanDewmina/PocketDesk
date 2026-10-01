import XCTest
@testable import PocketDeskRemote

@MainActor
final class MacWidgetSnapshotTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000)

    private func defaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "widget-\(UUID().uuidString)"))
    }

    func testTheSnapshotHoldsTheNamePresenceAndTimesOnly() throws {
        let snapshot = MacWidgetSnapshot(macName: "Studio Mac", presence: .awake, presenceAt: start, lastReached: start)
        let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(snapshot))
        let keys = Set(try XCTUnwrap(object as? [String: Any]).keys)
        XCTAssertEqual(keys, ["macName", "presence", "presenceAt", "lastReached"], "No keys, tokens, rooms or addresses")
    }

    func testAnEmptyOrDamagedGroupLeavesTheGenericWidget() throws {
        let store = try defaults()
        XCTAssertNil(MacWidgetSnapshot.load(from: store))
        XCTAssertNil(MacWidgetSnapshot.load(from: nil))
        store.set(Data("nope".utf8), forKey: MacWidgetSnapshot.defaultsKey)
        XCTAssertNil(MacWidgetSnapshot.load(from: store))
        XCTAssertFalse(MacWidgetSnapshot.store(MacWidgetSnapshot(macName: "Studio Mac"), in: nil),
                       "Without the App Group nothing is written")
    }

    func testStoringReportsOnlyRealChanges() throws {
        let store = try defaults()
        let snapshot = MacWidgetSnapshot(macName: "Studio Mac", presence: .asleep, presenceAt: start)
        XCTAssertTrue(MacWidgetSnapshot.store(snapshot, in: store))
        XCTAssertFalse(MacWidgetSnapshot.store(snapshot, in: store))
        XCTAssertEqual(MacWidgetSnapshot.load(from: store), snapshot)
        XCTAssertTrue(MacWidgetSnapshot.store(nil, in: store))
        XCTAssertNil(MacWidgetSnapshot.load(from: store))
    }

    func testALongNameIsBoundedAndAPresenceNeedsItsTime() {
        let long = MacWidgetSnapshot(macName: String(repeating: "M", count: 200))
        XCTAssertEqual(long.macName.count, MacWidgetSnapshot.maximumNameLength)
        XCTAssertNil(MacWidgetSnapshot(macName: "Studio Mac", presenceAt: start).presenceAt)
    }

    func testOnlyObservedFactsBecomeAPresence() {
        XCTAssertEqual(MacWidgetSync.observedPresence(connected: true, departure: .sleeping, failure: .unreachable), .awake)
        XCTAssertEqual(MacWidgetSync.observedPresence(connected: false, departure: .sleeping, failure: nil), .asleep)
        XCTAssertEqual(MacWidgetSync.observedPresence(connected: false, departure: .locked, failure: nil), .locked)
        XCTAssertEqual(MacWidgetSync.observedPresence(connected: false, departure: .switchedUser, failure: nil), .otherUser)
        XCTAssertEqual(MacWidgetSync.observedPresence(connected: false, departure: nil, failure: .unreachable), .notAnswering,
                       "Silence is 'not answering', never 'asleep'")
        XCTAssertEqual(MacWidgetSync.observedPresence(connected: false, departure: nil, failure: .screenRecordingOff),
                       .screenRecordingOff)
        XCTAssertNil(MacWidgetSync.observedPresence(connected: false, departure: .displayAsleep, failure: .declined))
        XCTAssertEqual(MacWidgetSync.presence(for: .answering), .awake)
        XCTAssertEqual(MacWidgetSync.presence(for: .notAnswering), .notAnswering)
        XCTAssertNil(MacWidgetSync.presence(for: .serviceUnreachable), "This iPhone being offline says nothing about the Mac")
    }

    func testTheNextSnapshotKeepsTheLastPresenceAndDatesNewOnes() {
        let first = MacWidgetSync.next(previous: nil, macName: "Studio Mac", observed: .awake, now: start, lastReached: start)
        XCTAssertEqual(first?.presence, .awake)
        XCTAssertEqual(first?.presenceAt, start)
        let later = start.addingTimeInterval(60)
        let repeated = MacWidgetSync.next(previous: first, macName: "Studio Mac", observed: .awake, now: later, lastReached: start)
        XCTAssertEqual(repeated?.presenceAt, start, "The same presence is not re-dated every minute")
        let kept = MacWidgetSync.next(previous: first, macName: "Studio Mac", observed: nil, now: later, lastReached: start)
        XCTAssertEqual(kept?.presence, .awake, "No new observation keeps the last one with its own time")
        XCTAssertEqual(kept?.presenceAt, start)
        let changed = MacWidgetSync.next(previous: first, macName: "Studio Mac", observed: .asleep, now: later, lastReached: start)
        XCTAssertEqual(changed?.presenceAt, later)
        let stale = MacWidgetSync.next(previous: first, macName: "Studio Mac", observed: .awake,
                                       now: start.addingTimeInterval(MacWidgetSync.refreshInterval + 1), lastReached: start)
        XCTAssertEqual(stale?.presenceAt, start.addingTimeInterval(MacWidgetSync.refreshInterval + 1))
        let otherMac = MacWidgetSync.next(previous: first, macName: "Laptop", observed: nil, now: later, lastReached: nil)
        XCTAssertNil(otherMac?.presence, "Another Mac never inherits a presence")
        XCTAssertNil(MacWidgetSync.next(previous: first, macName: nil, observed: .awake, now: later, lastReached: start),
                     "Unpaired clears the widget")
    }

    func testSyncReloadsTheWidgetOnlyWhenTheSnapshotChanged() throws {
        let sync = MacWidgetSync()
        sync.defaults = try defaults()
        var reloads = 0
        sync.reload = { reloads += 1 }
        sync.now = { self.start }
        sync.lastReached = { _ in nil }
        sync.update(macName: "Studio Mac", room: "studio-room", observed: .awake)
        sync.update(macName: "Studio Mac", room: "studio-room", observed: .awake)
        sync.update(macName: "Studio Mac", room: "studio-room", observed: nil)
        XCTAssertEqual(reloads, 1)
        sync.update(macName: nil, room: nil, observed: nil)
        XCTAssertEqual(reloads, 2)
    }
}
