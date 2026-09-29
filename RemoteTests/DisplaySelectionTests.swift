import XCTest

final class DisplaySelectionProtocolTests: XCTestCase {
    private let builtIn = DisplayDescriptor(id: 1, name: "Built-in Retina Display", width: 1470, height: 956,
                                            pixelWidth: 2940, pixelHeight: 1912, main: true)
    private let studio = DisplayDescriptor(id: 7, name: "Studio Display", width: 2560, height: 1440,
                                           pixelWidth: 5120, pixelHeight: 2880)

    func testListRequestAndSwitchRoundTripAndValidate() throws {
        let request = RemoteAction(action: "displays", epoch: 4)
        XCTAssertNoThrow(try request.validate())
        let reply = RemoteAction(action: "displays", epoch: 4, displays: [builtIn, studio], display: 1)
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(reply))
        XCTAssertEqual(decoded.displays, [builtIn, studio])
        XCTAssertEqual(decoded.display, 1)
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertNoThrow(try RemoteAction(action: "display", epoch: 4, display: 7).validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, display: 7).validate(), "Capture names the streamed display")
    }

    func testMalformedDisplayMessagesAreRejected() {
        var tooMany = (1...17).map { DisplayDescriptor(id: UInt32($0), name: "D\($0)", width: 100, height: 100) }
        let invalid: [RemoteAction] = [
            RemoteAction(action: "display", epoch: 1),
            RemoteAction(action: "display", epoch: 1, display: 0),
            RemoteAction(action: "display", epoch: 1, displays: [builtIn], display: 1),
            RemoteAction(action: "displays", epoch: 1, displays: tooMany),
            RemoteAction(action: "displays", epoch: 1, displays: [builtIn, builtIn]),
            RemoteAction(action: "displays", epoch: 1, displays: [DisplayDescriptor(id: 3, name: "", width: 1, height: 1)]),
            RemoteAction(action: "displays", epoch: 1, displays: [DisplayDescriptor(id: 3, name: "Bad\u{7}", width: 1, height: 1)]),
            RemoteAction(action: "displays", epoch: 1, displays: [DisplayDescriptor(id: 3, name: "X", width: .nan, height: 1)]),
            RemoteAction(action: "displays", epoch: 1, displays: [DisplayDescriptor(id: 0, name: "X", width: 10, height: 10)]),
            RemoteAction(action: "displays", x: 5, epoch: 1),
            RemoteAction(action: "displays", key: "a", epoch: 1),
            RemoteAction(action: "display", epoch: 1, interaction: NativeInteraction(token: "t"), display: 2),
            RemoteAction(action: "click", epoch: 1, display: 2),
            RemoteAction(action: "heartbeat", epoch: 1, displays: [builtIn]),
            RemoteAction(action: "capture", displays: [builtIn])
        ]
        for action in invalid {
            XCTAssertThrowsError(try action.validate(), "\(action.action) \(String(describing: action.display))")
        }
        tooMany.removeLast()
        XCTAssertNoThrow(try RemoteAction(action: "displays", epoch: 1, displays: tooMany).validate(), "Sixteen is the limit")
    }

    func testOlderPeersNeverSeeTheNewFieldsUnlessTheyAsked() throws {
        // A capture status with `display` still decodes for a phone that predates it (unknown keys are ignored).
        let data = try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, display: 7))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["display"] as? Int, 7)
        XCTAssertTrue(SessionFeature.host.contains(SessionFeature.displaySelection))
    }

    func testResolutionReadsNaturally() {
        XCTAssertEqual(builtIn.resolution, "1470 × 956 · 2940 × 1912 px")
        XCTAssertEqual(DisplayDescriptor(id: 2, name: "Old", width: 1920, height: 1080, pixelWidth: 1920,
                                         pixelHeight: 1080).resolution, "1920 × 1080")
    }
}

final class HostDisplayCatalogTests: XCTestCase {
    func testListPutsTheMainDisplayFirstAndCleansNames() {
        let list = HostDisplayCatalog.descriptors([
            .init(id: 9, name: "LG UltraFine", width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, main: false),
            .init(id: 1, name: " Built-in\nRetina ", width: 1470, height: 956, pixelWidth: 2940, pixelHeight: 1912, main: true),
            .init(id: 9, name: "Duplicate", width: 10, height: 10, pixelWidth: nil, pixelHeight: nil, main: false),
            .init(id: 4, name: "", width: 1920, height: 1080, pixelWidth: nil, pixelHeight: nil, main: false),
            .init(id: 5, name: "Broken", width: .infinity, height: 1080, pixelWidth: nil, pixelHeight: nil, main: false)
        ])
        XCTAssertEqual(list.map(\.id), [1, 4, 9])
        XCTAssertEqual(list[0].name, "Built-inRetina")
        XCTAssertEqual(list[1].name, "Display 4")
        XCTAssertTrue(list[0].main)
        XCTAssertNoThrow(try RemoteAction(action: "displays", displays: list, display: 1).validate())
        let long = HostDisplayCatalog.cleanName(String(repeating: "é", count: 60), id: 3)
        XCTAssertLessThanOrEqual(long.utf8.count, 64)
    }

    func testOnlyAPhoneWithControlMaySwitchToAnotherKnownDisplay() {
        XCTAssertEqual(HostDisplayCatalog.decide(requested: 9, available: [1, 9], streaming: 1, controlEffective: true),
                       .switchTo(9))
        XCTAssertEqual(HostDisplayCatalog.decide(requested: 9, available: [1, 9], streaming: 1, controlEffective: false),
                       .resendList, "A view-only phone keeps the display the Mac chose")
        XCTAssertEqual(HostDisplayCatalog.decide(requested: 3, available: [1, 9], streaming: 1, controlEffective: true),
                       .resendList)
        XCTAssertEqual(HostDisplayCatalog.decide(requested: 1, available: [1, 9], streaming: 1, controlEffective: true),
                       .resendList, "Already streaming it")
    }
}

final class DisplayMemoryTests: XCTestCase {
    func testChoiceIsRememberedPerMacAndMatchedByIdThenName() {
        let defaults = UserDefaults(suiteName: "DisplayMemoryTests-\(UUID().uuidString)")!
        let memory = DisplayMemory(defaults: defaults)
        let roomA = String(repeating: "a", count: 64)
        let roomB = String(repeating: "b", count: 64)
        memory.remember(.init(id: 7, name: "Studio Display"), forRoom: roomA)
        XCTAssertEqual(memory.choice(forRoom: roomA), .init(id: 7, name: "Studio Display"))
        XCTAssertNil(memory.choice(forRoom: roomB), "Each Mac keeps its own choice")
        XCTAssertFalse(DisplayMemory.macKey(room: roomA).contains(roomA), "The pairing room itself is never stored")

        let displays = [DisplayDescriptor(id: 1, name: "Built-in", width: 1470, height: 956),
                        DisplayDescriptor(id: 12, name: "Studio Display", width: 2560, height: 1440)]
        XCTAssertEqual(DisplayMemory.match(.init(id: 7, name: "Studio Display"), in: displays)?.id, 12,
                       "A reconnected monitor with a new id is found by name")
        XCTAssertEqual(DisplayMemory.match(.init(id: 1, name: "Renamed"), in: displays)?.id, 1)
        XCTAssertNil(DisplayMemory.match(.init(id: 99, name: "Gone"), in: displays))
        let twins = displays + [DisplayDescriptor(id: 13, name: "Studio Display", width: 2560, height: 1440)]
        XCTAssertNil(DisplayMemory.match(.init(id: 7, name: "Studio Display"), in: twins), "Ambiguous names never guess")
    }
}
