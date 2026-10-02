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

    private func host(room: String, identity: String?, record: String = "local-record") throws -> PhoneHostTrust {
        var invitation = try HostPair.create(server: "wss://offline.invalid/signal", name: "Mac").rotated().invitation
        invitation.room = room
        invitation.durableHostID = identity
        return PhoneHostTrust(id: record, durableHostID: identity, ownerPairID: nil,
                              invitation: invitation, legacyAliases: [])
    }

    func testTrustedMacMemorySurvivesRePairingAndStaysPhoneLocal() throws {
        let memory = BigTextMemory(defaults: defaults)
        let old = try host(room: "room-a", identity: "mac-a")
        let replacement = try host(room: "room-b", identity: "mac-a", record: "another-record")
        memory.remember(1024, forHost: old, display: builtIn, among: [builtIn])
        XCTAssertEqual(memory.width(forHost: replacement, display: builtIn, among: [builtIn]), 1024)
        XCTAssertNil(memory.width(forHost: try host(room: "room-b", identity: "mac-b"), display: builtIn, among: [builtIn]))
        let otherPhone = UserDefaults(suiteName: "BigTextMemoryTests-other-\(UUID().uuidString)")!
        XCTAssertNil(BigTextMemory(defaults: otherPhone).width(forHost: old, display: builtIn, among: [builtIn]))
    }

    func testKnownRoomMigrationPreservesExplicitOffAcrossRePairing() throws {
        let memory = BigTextMemory(defaults: defaults)
        memory.remember(nil, forRoom: "room-a", display: builtIn, among: [builtIn])
        let trusted = try host(room: "room-a", identity: "mac-a")
        memory.migrate(host: trusted)
        let replacement = try host(room: "room-b", identity: "mac-a")
        XCTAssertTrue(memory.hasSavedChoice(forHost: replacement, display: builtIn, among: [builtIn]))
        XCTAssertNil(memory.width(forHost: replacement, display: builtIn, among: [builtIn]))
        XCTAssertTrue(memory.hasSavedChoice(forRoom: "room-a", display: builtIn, among: [builtIn]), "room shadow supports rollback")
    }

    func testMigratedRoomNeverOverwritesStableManualChoice() throws {
        let memory = BigTextMemory(defaults: defaults)
        let old = try host(room: "room-a", identity: "mac-a")
        memory.remember(nil, forHost: old, display: builtIn, among: [builtIn])
        memory.remember(1280, forRoom: "room-b", display: builtIn, among: [builtIn])
        let replacement = try host(room: "room-b", identity: "mac-a")
        XCTAssertNil(memory.width(forHost: replacement, display: builtIn, among: [builtIn]))
        XCTAssertTrue(memory.hasSavedChoice(forHost: replacement, display: builtIn, among: [builtIn]))
    }

    func testUnknownOldRoomIsNeverAssignedToATrustedMac() throws {
        let memory = BigTextMemory(defaults: defaults)
        memory.remember(1024, forRoom: "unknown-old-room", display: builtIn, among: [builtIn])
        XCTAssertFalse(memory.hasSavedChoice(forHost: try host(room: "current-room", identity: "mac-a"), display: builtIn, among: [builtIn]))
        XCTAssertEqual(memory.width(forRoom: "unknown-old-room", display: builtIn, among: [builtIn]), 1024)
    }

    func testSameTrustedLegacyRecordCarriesItsChoiceIntoDurableIdentity() throws {
        let memory = BigTextMemory(defaults: defaults)
        let legacy = try host(room: "room-a", identity: nil, record: "same-record")
        memory.remember(1024, forHost: legacy, display: builtIn, among: [builtIn])
        let upgraded = try host(room: "room-a", identity: "mac-a", record: "same-record")
        XCTAssertEqual(memory.width(forHost: upgraded, display: builtIn, among: [builtIn]), 1024)
        let replacement = try host(room: "room-b", identity: "mac-a", record: "same-record")
        XCTAssertEqual(memory.width(forHost: replacement, display: builtIn, among: [builtIn]), 1024)
        memory.forget(host: replacement)
        XCTAssertNil(memory.width(forRoom: "room-a", display: builtIn, among: [builtIn]))
    }

    func testForgettingTrustedMacClearsStableAndCurrentRoomChoices() throws {
        let memory = BigTextMemory(defaults: defaults)
        let trusted = try host(room: "room-a", identity: "mac-a")
        memory.remember(1024, forHost: trusted, display: builtIn, among: [builtIn])
        memory.remember(1280, forRoom: "room-a", display: studio, among: [studio])
        memory.forget(host: trusted)
        XCTAssertFalse(memory.hasSavedChoice(forHost: trusted, display: builtIn, among: [builtIn]))
        XCTAssertNil(memory.width(forRoom: "room-a", display: studio, among: [studio]))
    }

    func testForgettingReplacementClearsOnlyKnownRoomShadowsForThatMac() throws {
        let memory = BigTextMemory(defaults: defaults)
        let old = try host(room: "room-a", identity: "mac-a")
        memory.remember(1024, forHost: old, display: builtIn, among: [builtIn])
        let replacement = try host(room: "room-b", identity: "mac-a")
        memory.migrate(host: replacement)
        memory.remember(1280, forRoom: "unknown-room", display: builtIn, among: [builtIn])
        memory.forget(host: replacement)
        XCTAssertNil(memory.width(forRoom: "room-a", display: builtIn, among: [builtIn]))
        XCTAssertNil(memory.width(forRoom: "room-b", display: builtIn, among: [builtIn]))
        XCTAssertEqual(memory.width(forRoom: "unknown-room", display: builtIn, among: [builtIn]), 1280)
    }

    func testStableMemoryKillSwitchKeepsRoomBehavior() throws {
        defaults.set(true, forKey: BigTextMemory.stableMemoryDisabledKey)
        let memory = BigTextMemory(defaults: defaults)
        let trusted = try host(room: "room-a", identity: "mac-a")
        memory.remember(1024, forHost: trusted, display: builtIn, among: [builtIn])
        XCTAssertEqual(memory.width(forRoom: "room-a", display: builtIn, among: [builtIn]), 1024)
        XCTAssertNil(memory.width(forHost: try host(room: "room-b", identity: "mac-a"), display: builtIn, among: [builtIn]))
    }

    func testStableMemoryRollbackRetainsMigratedAndNewManualChoices() throws {
        let memory = BigTextMemory(defaults: defaults)
        let trusted = try host(room: "room-a", identity: "mac-a")
        memory.remember(1024, forRoom: "room-a", display: builtIn, among: [builtIn])
        memory.migrate(host: trusted)
        defaults.set(true, forKey: BigTextMemory.stableMemoryDisabledKey)
        XCTAssertEqual(memory.width(forHost: trusted, display: builtIn, among: [builtIn]), 1024)
        defaults.set(false, forKey: BigTextMemory.stableMemoryDisabledKey)
        memory.remember(nil, forHost: trusted, display: builtIn, among: [builtIn])
        let replacement = try host(room: "room-b", identity: "mac-a")
        memory.migrate(host: replacement)
        defaults.set(true, forKey: BigTextMemory.stableMemoryDisabledKey)
        XCTAssertTrue(memory.hasSavedChoice(forHost: trusted, display: builtIn, among: [builtIn]))
        XCTAssertNil(memory.width(forHost: trusted, display: builtIn, among: [builtIn]))
        XCTAssertTrue(memory.hasSavedChoice(forHost: replacement, display: builtIn, among: [builtIn]), "replacement room has the authoritative rollback shadow")
        XCTAssertNil(memory.width(forHost: replacement, display: builtIn, among: [builtIn]))
    }

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
