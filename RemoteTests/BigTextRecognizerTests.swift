import CoreGraphics
import XCTest

final class BigTextRecognizerTests: XCTestCase {
    private let target = DisplayModeInfo(ioModeID: 42, width: 1280, height: 832, pixelWidth: 2560, pixelHeight: 1664,
                                         refreshRate: 60, usableForDesktopGUI: true)
    private let other = DisplayModeInfo(ioModeID: 7, width: 1470, height: 956, pixelWidth: 2940, pixelHeight: 1912,
                                        refreshRate: 60, usableForDesktopGUI: true)

    private func recognizer() -> OwnChangeRecognizer {
        OwnChangeRecognizer(display: 1, target: target, onlineBefore: [1, 2], startedAt: 100)
    }

    func testSetModeOnOurDisplayReachingTheTargetIsOurs() {
        var r = recognizer()
        r.observe(DisplayReconfigurationEvent(display: 1, flags: [.beginConfigurationFlag]))
        XCTAssertEqual(r.verdict(now: 100.2, online: [1, 2], current: target), .pending, "before-change callbacks do not count")
        r.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag, .desktopShapeChangedFlag]))
        r.observe(DisplayReconfigurationEvent(display: 2, flags: [.movedFlag]))
        XCTAssertEqual(r.verdict(now: 100.4, online: [1, 2], current: target), .ours, "neighbours moving is part of our change")
    }

    func testModeNotYetAtTargetIsPending() {
        var r = recognizer()
        r.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag]))
        XCTAssertEqual(r.verdict(now: 101, online: [1, 2], current: other), .pending)
    }

    func testSetModeOnAnotherDisplayDoesNotCount() {
        var r = recognizer()
        r.observe(DisplayReconfigurationEvent(display: 2, flags: [.setModeFlag]))
        XCTAssertEqual(r.verdict(now: 101, online: [1, 2], current: target), .foreign)
    }

    func testAddedDisplayIsForeign() {
        var r = recognizer()
        r.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag]))
        r.observe(DisplayReconfigurationEvent(display: 3, flags: [.addFlag]))
        XCTAssertEqual(r.verdict(now: 101, online: [1, 2, 3], current: target), .foreign)
    }

    func testOnlineListChangeIsForeign() {
        var r = recognizer()
        r.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag]))
        XCTAssertEqual(r.verdict(now: 101, online: [1], current: target), .foreign)
    }

    func testTimeoutIsForeign() {
        let r = recognizer()
        XCTAssertEqual(r.verdict(now: 100 + OwnChangeRecognizer.timeout + 0.1, online: [1, 2], current: other), .foreign)
    }

    func testPreparationRejectsModeEventsBeforeOurConfigurationCall() {
        var r = OwnChangeRecognizer(display: 1, target: target, onlineBefore: [1, 2], startedAt: 100, preparing: true)
        r.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag]))
        XCTAssertEqual(r.verdict(now: 101, online: [1, 2], current: target), .foreign)
    }

    @MainActor
    func testLiveSwitcherReadsTheMainDisplayWithoutChangingIt() {
        let switcher = LiveDisplayModeSwitcher()
        let main = CGMainDisplayID()
        let before = switcher.currentMode(of: main)
        XCTAssertNotNil(before)
        XCTAssertTrue(switcher.modes(of: main).contains { $0.ioModeID == before?.ioModeID })
        XCTAssertTrue(switcher.onlineDisplays().contains(main))
    }
}
