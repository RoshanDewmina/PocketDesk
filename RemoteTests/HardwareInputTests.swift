import XCTest
import AppKit
import CoreGraphics

/// A hardware keyboard on the phone: HID usage to key name to Mac virtual key code.
final class HardwareKeyMapTests: XCTestCase {
    func testEveryPhoneKeyNameExistsOnTheMacWithTheRightVirtualKeyCode() {
        // Spot checks against Carbon's kVK_* constants.
        let expected: [Int: CGKeyCode] = [
            0x04: 0x00, 0x05: 0x0B, 0x1D: 0x06,            // A, B, Z
            0x1E: 0x12, 0x27: 0x1D,                         // 1, 0
            0x28: 0x24, 0x29: 0x35, 0x2A: 0x33, 0x2B: 0x30, 0x2C: 0x31,
            0x2D: 0x1B, 0x2E: 0x18, 0x2F: 0x21, 0x30: 0x1E, 0x31: 0x2A,
            0x33: 0x29, 0x34: 0x27, 0x35: 0x32, 0x36: 0x2B, 0x37: 0x2F, 0x38: 0x2C,
            0x3A: 0x7A, 0x45: 0x6F,                         // F1, F12
            0x4A: 0x73, 0x4B: 0x74, 0x4C: 0x75, 0x4D: 0x77, 0x4E: 0x79,
            0x4F: 0x7C, 0x50: 0x7B, 0x51: 0x7D, 0x52: 0x7E,
            0x58: 0x4C, 0x59: 0x53, 0x62: 0x52, 0x63: 0x41, 0x64: 0x0A,
            0x68: 0x69, 0x6F: 0x5A                          // F13, F20
        ]
        for (usage, keyCode) in expected {
            guard let name = HardwareKeyMap.name(forHIDUsage: usage) else { XCTFail("usage \(usage)"); continue }
            XCTAssertEqual(RemoteInputDriver.keys[name], keyCode, "usage 0x\(String(usage, radix: 16)) → \(name)")
        }
        for (usage, name) in HardwareKeyMap.names {
            XCTAssertNotNil(RemoteInputDriver.keys[name], "The Mac must accept every name the phone sends (0x\(String(usage, radix: 16)) \(name))")
            XCTAssertLessThanOrEqual(name.utf8.count, 32, "Key names fit the protocol bound")
        }
    }

    func testLegacyNamesAreExactlyTheOriginalTable() {
        XCTAssertEqual(HardwareKeyMap.legacyNames, Set(RemoteInputDriver.legacyKeys.keys))
        XCTAssertFalse(HardwareKeyMap.needsExtendedKeys("a"))
        XCTAssertFalse(HardwareKeyMap.needsExtendedKeys("escape"))
        XCTAssertTrue(HardwareKeyMap.needsExtendedKeys("7"))
        XCTAssertTrue(HardwareKeyMap.needsExtendedKeys("f5"))
    }

    func testModifiersAndCapsLockFollowTheMac() {
        XCTAssertTrue(HardwareKeyMap.isModifier(0xE3))
        XCTAssertTrue(HardwareKeyMap.isModifier(0xE4))
        XCTAssertFalse(HardwareKeyMap.isModifier(0x04))
        XCTAssertNil(HardwareKeyMap.name(forHIDUsage: 0xE0), "Modifiers travel as flags, never as keys")
        XCTAssertNil(HardwareKeyMap.name(forHIDUsage: 0x65), "The Menu key has no Mac equivalent")
        XCTAssertEqual(HardwareKeyMap.modifiers([], capsLock: true, for: "q"), ["shift"])
        XCTAssertEqual(HardwareKeyMap.modifiers(["command"], capsLock: true, for: "q"), ["command"],
                       "⌘Q stays ⌘Q with Caps Lock on")
        XCTAssertEqual(HardwareKeyMap.modifiers([], capsLock: true, for: "7"), [], "Caps Lock never shifts digits")
        XCTAssertEqual(HardwareKeyMap.modifiers(["control", "shift", "command"], capsLock: false, for: "a"),
                       ["command", "shift", "control"], "Wire order is canonical")
    }

    func testKeysValidateAsProtocolActions() {
        for name in Set(HardwareKeyMap.names.values) {
            XCTAssertNoThrow(try RemoteAction(action: "key", key: name, modifiers: ["command", "shift", "option", "control"]).validate(), name)
        }
    }

    func testFunctionAndKeypadKeysCarryTheFlagsAMacKeyboardSets() {
        XCTAssertEqual(RemoteInputDriver.intrinsicFlags(for: "f5"), .maskSecondaryFn)
        XCTAssertEqual(RemoteInputDriver.intrinsicFlags(for: "pageDown"), .maskSecondaryFn)
        XCTAssertEqual(RemoteInputDriver.intrinsicFlags(for: "keypad7"), .maskNumericPad)
        XCTAssertEqual(RemoteInputDriver.intrinsicFlags(for: "left"), [.maskSecondaryFn, .maskNumericPad])
        XCTAssertEqual(RemoteInputDriver.intrinsicFlags(for: "a"), [])
        XCTAssertEqual(RemoteInputDriver.intrinsicFlags(for: "forwardDelete"), .maskSecondaryFn)

        var posted: [(CGKeyCode, CGEventFlags)] = []
        let sink = RemoteInputEventSink(pointerLocation: { .zero }, mouseSequence: { _ in true },
                                        scroll: { _, _, _ in true }, text: { _ in true },
                                        key: { code, flags in posted.append((code, flags)); return true })
        let driver = RemoteInputDriver(eventSink: sink, isTrusted: { true })
        driver.enabled = true
        driver.configure(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(driver.handle(RemoteAction(action: "key", key: "f5", modifiers: ["shift"])).accepted)
        XCTAssertEqual(posted.last?.0, 0x60)
        XCTAssertEqual(posted.last?.1, [.maskShift, .maskSecondaryFn])
        XCTAssertTrue(driver.handle(RemoteAction(action: "key", key: "c", modifiers: ["command"])).accepted)
        XCTAssertEqual(posted.last?.1, .maskCommand)
        XCTAssertFalse(driver.handle(RemoteAction(action: "key", key: "menu")).accepted)
    }

    /// macOS matches ⌃-arrow system hotkeys (Spaces, Mission Control, App windows) only when the
    /// arrow carries Fn, as a physical Mac keyboard sends it. Plain ⌃ never switched a Space.
    func testControlArrowsCarryFnSoMissionControlAndSpacesHotkeysMatch() {
        var posted: [(CGKeyCode, CGEventFlags)] = []
        let sink = RemoteInputEventSink(pointerLocation: { .zero }, mouseSequence: { _ in true },
                                        scroll: { _, _, _ in true }, text: { _ in true },
                                        key: { code, flags in posted.append((code, flags)); return true })
        let driver = RemoteInputDriver(eventSink: sink, isTrusted: { true })
        driver.enabled = true
        driver.configure(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        for (key, code) in [("left", CGKeyCode(123)), ("right", 124), ("down", 125), ("up", 126)] {
            XCTAssertTrue(driver.handle(RemoteAction(action: "key", key: key, modifiers: ["control"])).accepted, key)
            XCTAssertEqual(posted.last?.0, code, key)
            XCTAssertEqual(posted.last?.1, [.maskControl, .maskSecondaryFn, .maskNumericPad], key)
        }
        XCTAssertTrue(driver.handle(RemoteAction(action: "key", key: "left", modifiers: ["shift"])).accepted)
        XCTAssertEqual(posted.last?.1, [.maskShift, .maskSecondaryFn, .maskNumericPad],
                       "Shift-arrow selection keeps its shift and gains only the keyboard's own flags")
    }
}

final class ShortcutRemapTests: XCTestCase {
    func testControlOptionStandsInForCommandOnReservedShortcuts() {
        XCTAssertEqual(resolve("tab", ["option", "control"]).modifiers, ["command"])
        XCTAssertEqual(resolve("tab", ["shift", "option", "control"]).modifiers, ["command", "shift"],
                       "⌃⌥⇧Tab switches apps backwards")
        XCTAssertEqual(resolve("space", ["control", "option"]).modifiers, ["command"])
        XCTAssertEqual(resolve("d", ["control", "option"]).modifiers, ["command", "option"])
        XCTAssertEqual(resolve("3", ["control", "option"]).modifiers, ["command", "shift"])
        XCTAssertEqual(resolve("3", ["control", "option"]).key, "3")
    }

    func testOtherChordsAndDisabledRemapPassThroughUntouched() {
        XCTAssertEqual(resolve("tab", ["command"]).modifiers, ["command"])
        XCTAssertEqual(resolve("a", ["control", "option"]).modifiers, ["control", "option"], "Only listed keys remap")
        XCTAssertEqual(resolve("tab", ["command", "control", "option"]).modifiers, ["command", "control", "option"])
        XCTAssertEqual(resolve("tab", ["option"]).modifiers, ["option"])
        XCTAssertEqual(ShortcutRemap.resolve(key: "tab", modifiers: ["control", "option"], enabled: false).modifiers,
                       ["control", "option"])
    }

    func testEveryDefaultIsUniqueAndSendsAValidAction() {
        XCTAssertEqual(Set(ShortcutRemap.defaults.map(\.key)).count, ShortcutRemap.defaults.count)
        for remap in ShortcutRemap.defaults {
            XCTAssertNotNil(RemoteInputDriver.keys[remap.key], remap.key)
            XCTAssertNoThrow(try RemoteAction(action: "key", key: remap.key, modifiers: remap.sends).validate())
            XCTAssertTrue(remap.sends.contains("command"), "\(remap.title) is a ⌘ shortcut on the Mac")
        }
    }

    private func resolve(_ key: String, _ modifiers: [String]) -> (key: String, modifiers: [String]) {
        ShortcutRemap.resolve(key: key, modifiers: modifiers, enabled: true)
    }
}

final class HardwareKeyRepeatTests: XCTestCase {
    func testShortcutChordsNeverRepeat() {
        var keyRepeat = HardwareKeyRepeat()
        for modifiers in [["command"], ["control"], ["command", "shift"], ["option", "control"]] {
            keyRepeat.pressed(usage: 0x2A, key: "delete", modifiers: modifiers, at: 10)
            XCTAssertFalse(keyRepeat.isRepeating, "\(modifiers) + delete must act once")
            XCTAssertNil(keyRepeat.due(at: 11))
        }
        keyRepeat.pressed(usage: 0x4F, key: "right", modifiers: ["shift", "option"], at: 10)
        XCTAssertEqual(keyRepeat.due(at: 10.5)?.modifiers, ["shift", "option"], "Selection and word moves still repeat")
    }

    func testHeldKeyRepeatsAfterTheDelayAtTheInterval() {
        var keyRepeat = HardwareKeyRepeat()
        keyRepeat.pressed(usage: 0x2A, key: "delete", modifiers: [], at: 10)
        XCTAssertNil(keyRepeat.due(at: 10.45), "An ordinary press is released well before the delay")
        XCTAssertEqual(keyRepeat.due(at: 10.5)?.key, "delete")
        XCTAssertNil(keyRepeat.due(at: 10.52))
        XCTAssertEqual(keyRepeat.due(at: 10.57)?.key, "delete")
        keyRepeat.released(usage: 0x2A)
        XCTAssertNil(keyRepeat.due(at: 11))
    }

    func testOnlyTheLatestKeyRepeatsAndLateTicksNeverBurst() {
        var keyRepeat = HardwareKeyRepeat()
        keyRepeat.pressed(usage: 0x04, key: "a", modifiers: [], at: 0)
        keyRepeat.pressed(usage: 0x05, key: "b", modifiers: ["shift"], at: 0.1)
        keyRepeat.released(usage: 0x04)
        let first = keyRepeat.due(at: 0.6)
        XCTAssertEqual(first?.key, "b")
        XCTAssertEqual(first?.modifiers, ["shift"])
        XCTAssertNotNil(keyRepeat.due(at: 5), "A late tick sends one repeat")
        XCTAssertNil(keyRepeat.due(at: 5.001), "…not a burst of missed ones")
    }

    func testEscapeFunctionKeysAndIMEKeysDoNotRepeat() {
        for key in ["escape", "f5", "f12", "help", "jisKana", "keypadClear"] {
            var keyRepeat = HardwareKeyRepeat()
            keyRepeat.pressed(usage: 1, key: key, modifiers: [], at: 0)
            XCTAssertNil(keyRepeat.due(at: 2), key)
        }
        for key in ["left", "delete", "forwardDelete", "space", "a", "7", "pageDown"] {
            XCTAssertTrue(HardwareKeyMap.repeats(key), key)
        }
    }
}

/// A mouse or trackpad on iPad, in canvas coordinates.
final class HardwarePointerRouterTests: XCTestCase {
    func testHoverPlacesThePointerAndClickLandsThere() {
        let log = CommandLog()
        let router = makeRouter(log)
        router.hover(to: CGPoint(x: 40, y: 50))
        router.hover(to: CGPoint(x: 40, y: 50))
        XCTAssertEqual(log.points, [CGPoint(x: 40, y: 50)], "An unmoved pointer sends nothing")
        router.down(.primary, at: CGPoint(x: 41, y: 50), count: 1, time: 1)
        router.up(.primary, at: CGPoint(x: 41, y: 50), time: 1.08)
        XCTAssertEqual(log.trace, ["pointTo", "pointTo", "click1"])
    }

    func testDoubleAndTripleClicksKeepUIKitsCount() {
        let log = CommandLog()
        let router = makeRouter(log)
        for (count, time) in [(1, 1.0), (2, 1.2), (3, 1.4)] {
            router.down(.primary, at: CGPoint(x: 10, y: 10), count: count, time: time)
            router.up(.primary, at: CGPoint(x: 10, y: 10), time: time + 0.05)
        }
        XCTAssertEqual(log.clicks, [1, 2, 3])
        router.down(.primary, at: CGPoint(x: 10, y: 10), count: 7, time: 2)
        router.up(.primary, at: CGPoint(x: 10, y: 10), time: 2.05)
        XCTAssertEqual(log.clicks.last, 3, "Counts are bounded to what the Mac accepts")
    }

    func testPressAndMoveDragsFromThePressPoint() {
        let log = CommandLog()
        let router = makeRouter(log)
        router.down(.primary, at: CGPoint(x: 100, y: 100), count: 1, time: 1)
        router.moved(to: CGPoint(x: 101, y: 101), time: 1.02)
        XCTAssertEqual(log.dragBegins, 0, "Within the slop it is still a click")
        router.moved(to: CGPoint(x: 120, y: 100), time: 1.05)
        router.moved(to: CGPoint(x: 160, y: 130), time: 1.1)
        router.up(.primary, at: CGPoint(x: 170, y: 130), time: 1.2)
        XCTAssertEqual(log.trace, ["pointTo", "dragBegan1", "pointTo", "pointTo", "pointTo", "dragEnded"])
        XCTAssertTrue(log.clicks.isEmpty)
    }

    func testStillPressBecomesAHoldAndDoubleClickDragKeepsCountTwo() {
        let log = CommandLog()
        let router = makeRouter(log)
        router.down(.primary, at: CGPoint(x: 5, y: 5), count: 1, time: 1)
        router.tick(at: 1.2)
        XCTAssertEqual(log.dragBegins, 0)
        router.tick(at: 1.36)
        XCTAssertEqual(log.dragCounts, [1])
        router.up(.primary, at: CGPoint(x: 5, y: 5), time: 2)
        XCTAssertEqual(log.dragEnds, 1)

        router.down(.primary, at: CGPoint(x: 5, y: 5), count: 2, time: 3)
        router.moved(to: CGPoint(x: 30, y: 5), time: 3.05)
        XCTAssertEqual(log.dragCounts, [1, 2])
    }

    func testSecondaryClickAndMiddleClick() {
        let log = CommandLog()
        let router = makeRouter(log)
        router.down(.secondary, at: CGPoint(x: 70, y: 80), count: 1, time: 1)
        router.moved(to: CGPoint(x: 90, y: 80), time: 1.05)
        router.up(.secondary, at: CGPoint(x: 90, y: 80), time: 1.1)
        XCTAssertEqual(log.trace, ["pointTo", "right"], "No right-drag: the click lands where it was pressed")
        router.middleClick()
        XCTAssertEqual(log.middle, 1)
    }

    func testOutsideThePictureNothingIsPressed() {
        let log = CommandLog()
        log.rejectPoint = { $0.x < 20 }
        let router = makeRouter(log)
        router.down(.primary, at: CGPoint(x: 10, y: 10), count: 1, time: 1)
        router.moved(to: CGPoint(x: 60, y: 10), time: 1.05)
        router.up(.primary, at: CGPoint(x: 60, y: 10), time: 1.1)
        XCTAssertTrue(log.clicks.isEmpty)
        XCTAssertEqual(log.dragBegins, 0)
    }

    func testScrollPhasesAndCancellationOnDisable() {
        let log = CommandLog()
        let router = makeRouter(log)
        router.scroll(CGSize(width: 0, height: -4), phase: .began)
        router.scroll(CGSize(width: 0, height: -6), phase: .changed)
        router.scroll(.zero, phase: .changed)
        router.scroll(.zero, phase: .ended)
        XCTAssertEqual(log.scrollPhases, ["began", "changed", "ended"])

        router.scroll(CGSize(width: 2, height: 0), phase: .began)
        router.down(.primary, at: CGPoint(x: 50, y: 50), count: 1, time: 5)
        router.moved(to: CGPoint(x: 80, y: 50), time: 5.1)
        router.setEnabled(false)
        XCTAssertEqual(log.scrollPhases.suffix(2), ["began", "cancelled"])
        XCTAssertEqual(log.dragEnds, 1, "Losing control releases a held button exactly once")
        router.up(.primary, at: CGPoint(x: 80, y: 50), time: 5.2)
        XCTAssertEqual(log.dragEnds, 1)
        XCTAssertTrue(log.clicks.isEmpty)
    }

    func testTrackpadPinchZoomsLocallyAndSettlesOnce() {
        let log = CommandLog()
        let router = makeRouter(log)
        router.pinch(factor: 1.1, at: CGPoint(x: 200, y: 200), ended: false)
        router.pinch(factor: 1.05, at: CGPoint(x: 200, y: 200), ended: false)
        router.pinch(factor: 1, at: CGPoint(x: 200, y: 200), ended: true)
        router.pinch(factor: 1, at: CGPoint(x: 200, y: 200), ended: true)
        XCTAssertEqual(log.zooms, 2)
        XCTAssertEqual(log.zoomEnds, 1)
        XCTAssertTrue(log.points.isEmpty, "Zooming the picture never moves the Mac pointer")
    }

    func testDisabledRouterSendsNothing() {
        let log = CommandLog()
        let router = HardwarePointerRouter(onCommand: { log.record($0) })
        router.hover(to: CGPoint(x: 1, y: 1))
        router.down(.primary, at: CGPoint(x: 1, y: 1), count: 1, time: 0)
        router.up(.primary, at: CGPoint(x: 1, y: 1), time: 0.1)
        router.scroll(CGSize(width: 0, height: 3), phase: .began)
        router.middleClick()
        XCTAssertTrue(log.trace.isEmpty)
    }

    private func makeRouter(_ log: CommandLog) -> HardwarePointerRouter {
        let router = HardwarePointerRouter(onCommand: { log.record($0) })
        router.setEnabled(true)
        return router
    }
}
