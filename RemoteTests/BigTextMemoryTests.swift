import XCTest

final class BigTextMemoryTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "BigTextMemoryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private let builtIn = DisplayDescriptor(id: 1, name: "Built-in Retina Display", width: 1470, height: 956)
    private let studio = DisplayDescriptor(id: 7, name: "Studio Display", width: 2560, height: 1440)

    func testRememberedPerMacAndPerDisplay() {
        let memory = BigTextMemory(defaults: defaults)
        memory.remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn, studio])
        memory.remember(2048, forRoom: "room-a", display: studio, among: [builtIn, studio])
        XCTAssertEqual(memory.width(forRoom: "room-a", display: builtIn, among: [builtIn, studio]), 1280)
        XCTAssertEqual(memory.width(forRoom: "room-a", display: studio, among: [builtIn, studio]), 2048)
        XCTAssertNil(memory.width(forRoom: "room-b", display: builtIn, among: [builtIn]), "another Mac has its own level")
    }

    func testRenumberedDisplayMatchesByUniqueName() {
        let memory = BigTextMemory(defaults: defaults)
        memory.remember(2048, forRoom: "room-a", display: studio, among: [builtIn, studio])
        let renumbered = DisplayDescriptor(id: 9, name: "Studio Display", width: 2560, height: 1440)
        XCTAssertEqual(memory.width(forRoom: "room-a", display: renumbered, among: [builtIn, renumbered]), 2048)
    }

    func testAmbiguousNamesNeverGuess() {
        let memory = BigTextMemory(defaults: defaults)
        let left = DisplayDescriptor(id: 3, name: "DELL U2720Q", width: 2560, height: 1440)
        memory.remember(2048, forRoom: "room-a", display: left, among: [left])
        let twinA = DisplayDescriptor(id: 11, name: "DELL U2720Q", width: 2560, height: 1440)
        let twinB = DisplayDescriptor(id: 12, name: "DELL U2720Q", width: 2560, height: 1440)
        XCTAssertNil(memory.width(forRoom: "room-a", display: twinA, among: [twinA, twinB]))
    }

    func testAnIdReusedByAnotherMonitorNeverInheritsItsLevel() {
        let memory = BigTextMemory(defaults: defaults)
        let dell = DisplayDescriptor(id: 3, name: "DELL U2720Q", width: 2560, height: 1440)
        memory.remember(2048, forRoom: "room-a", display: dell, among: [dell])
        let lg = DisplayDescriptor(id: 3, name: "LG UltraFine", width: 2560, height: 1440)
        XCTAssertNil(memory.width(forRoom: "room-a", display: lg, among: [lg]))
        memory.remember(1600, forRoom: "room-a", display: lg, among: [lg])
        let dellBack = DisplayDescriptor(id: 5, name: "DELL U2720Q", width: 2560, height: 1440)
        XCTAssertEqual(memory.width(forRoom: "room-a", display: dellBack, among: [dellBack]), 2048,
                       "saving a level for the other monitor keeps the first monitor's level")
    }

    func testTwinsKeepTheirOwnLevelsOnceSavedWhileBothAreConnected() {
        let memory = BigTextMemory(defaults: defaults)
        let twinA = DisplayDescriptor(id: 11, name: "DELL U2720Q", width: 2560, height: 1440)
        let twinB = DisplayDescriptor(id: 12, name: "DELL U2720Q", width: 2560, height: 1440)
        memory.remember(2048, forRoom: "room-a", display: twinA, among: [twinA, twinB])
        memory.remember(1600, forRoom: "room-a", display: twinB, among: [twinA, twinB])
        XCTAssertEqual(memory.width(forRoom: "room-a", display: twinA, among: [twinA, twinB]), 2048)
        XCTAssertEqual(memory.width(forRoom: "room-a", display: twinB, among: [twinA, twinB]), 1600)
        let alone = DisplayDescriptor(id: 20, name: "DELL U2720Q", width: 2560, height: 1440)
        XCTAssertNil(memory.width(forRoom: "room-a", display: alone, among: [alone]),
                     "two saved twins with new ids could be either monitor")
    }

    func testOffClearsOneDisplaysWidthAndForgetClearsTheMac() {
        let memory = BigTextMemory(defaults: defaults)
        memory.remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn, studio])
        memory.remember(2048, forRoom: "room-a", display: studio, among: [builtIn, studio])
        memory.remember(nil, forRoom: "room-a", display: builtIn, among: [builtIn, studio])
        XCTAssertNil(memory.width(forRoom: "room-a", display: builtIn, among: [builtIn, studio]))
        XCTAssertEqual(memory.width(forRoom: "room-a", display: studio, among: [builtIn, studio]), 2048)
        memory.forget(room: "room-a")
        XCTAssertNil(memory.width(forRoom: "room-a", display: studio, among: [builtIn, studio]))
        XCTAssertNil(defaults.data(forKey: BigTextMemory.defaultsKey), "nothing left behind after the last Mac is forgotten")
    }

    func testReplacingALevelKeepsOneEntry() {
        let memory = BigTextMemory(defaults: defaults)
        memory.remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn])
        memory.remember(1024, forRoom: "room-a", display: builtIn, among: [builtIn])
        XCTAssertEqual(memory.width(forRoom: "room-a", display: builtIn, among: [builtIn]), 1024)
    }

    func testInvalidWidthsForgetTheDisplayWithoutLosingOthers() {
        let memory = BigTextMemory(defaults: defaults)
        memory.remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn, studio])
        memory.remember(2048, forRoom: "room-a", display: studio, among: [builtIn, studio])
        for bad in [Double.infinity, .nan, 0, -5, 20_001] {
            memory.remember(bad, forRoom: "room-a", display: builtIn, among: [builtIn, studio])
        }
        XCTAssertNil(memory.width(forRoom: "room-a", display: builtIn, among: [builtIn, studio]))
        XCTAssertEqual(memory.width(forRoom: "room-a", display: studio, among: [builtIn, studio]), 2048)
    }

    func testRoomIsHashed() {
        XCTAssertFalse(BigTextMemory.macKey(room: "room-a").contains("room-a"))
        XCTAssertNotEqual(BigTextMemory.macKey(room: "room-a"), DisplayMemory.macKey(room: "room-a"))
    }

    func testExplicitOffIsAChoiceAndForgetRemovesIt() {
        let memory = BigTextMemory(defaults: defaults)
        XCTAssertFalse(memory.hasSavedChoice(forRoom: "room-a", display: builtIn, among: [builtIn]))
        memory.remember(nil, forRoom: "room-a", display: builtIn, among: [builtIn])
        XCTAssertTrue(BigTextMemory(defaults: defaults).hasSavedChoice(forRoom: "room-a", display: builtIn, among: [builtIn]))
        XCTAssertNil(memory.width(forRoom: "room-a", display: builtIn, among: [builtIn]), "existing Off UI still has no saved width")
        let renumbered = DisplayDescriptor(id: 9, name: builtIn.name, width: 1470, height: 956)
        XCTAssertTrue(memory.hasSavedChoice(forRoom: "room-a", display: renumbered, among: [renumbered]))
        memory.forget(room: "room-a")
        XCTAssertFalse(memory.hasSavedChoice(forRoom: "room-a", display: builtIn, among: [builtIn]))
    }
}
