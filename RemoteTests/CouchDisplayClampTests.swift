import XCTest
import AppKit
import CoreGraphics

private final class ClampRecorder {
    var pointer: CGPoint
    var events: [RemoteInputEventSink.MouseEvent] = []
    init(start: CGPoint) { pointer = start }

    var sink: RemoteInputEventSink {
        RemoteInputEventSink(
            pointerLocation: { [weak self] in self?.pointer ?? .zero },
            mouseSequence: { [weak self] events in
                self?.events.append(contentsOf: events)
                if let last = events.last { self?.pointer = last.point }
                return true
            },
            scroll: { _, _, _ in true },
            scrollDetailed: { _, _, _, _ in true },
            text: { _ in true },
            key: { _, _ in true }
        )
    }
}

final class CouchDisplayClampTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1470, height: 956)
    /// A TV to the right, raised so there is a gap below it next to the laptop.
    private let tv = CGRect(x: 1470, y: -300, width: 1920, height: 1080)

    private func driver(_ recorder: ClampRecorder, displays: [CGRect]) -> RemoteInputDriver {
        let driver = RemoteInputDriver(eventSink: recorder.sink, isTrusted: { true })
        driver.enabled = true
        driver.configure(displays: displays)
        return driver
    }

    func testNearestDisplayClamp() {
        let rects = [main, tv]
        XCTAssertEqual(RemoteInputDriver.clamp(CGPoint(x: 100, y: 100), toNearestOf: rects), CGPoint(x: 100, y: 100))
        XCTAssertEqual(RemoteInputDriver.clamp(CGPoint(x: 2000, y: 0), toNearestOf: rects), CGPoint(x: 2000, y: 0))
        let gap = RemoteInputDriver.clamp(CGPoint(x: 1600, y: 900), toNearestOf: rects)
        XCTAssertEqual(gap, CGPoint(x: 1600, y: tv.maxY.nextDown), "120 pt to the TV beats 130 pt to the laptop")
        XCTAssertEqual(RemoteInputDriver.clamp(CGPoint(x: -2000, y: -2000), toNearestOf: rects), .zero)
        XCTAssertEqual(RemoteInputDriver.clamp(CGPoint(x: CGFloat.nan, y: 5), toNearestOf: rects), CGPoint(x: main.midX, y: main.midY))
    }

    func testRelativeMotionCrossesOntoTheTVAndStopsAtItsFarEdge() {
        let recorder = ClampRecorder(start: CGPoint(x: 1400, y: 500))
        let driver = driver(recorder, displays: [main, tv])
        XCTAssertTrue(driver.handle(RemoteAction(action: "move", x: 200, y: 0), now: 1).accepted)
        XCTAssertEqual(recorder.events.last?.point, CGPoint(x: 1600, y: 500))
        XCTAssertTrue(driver.handle(RemoteAction(action: "move", x: 5000, y: 0), now: 2).accepted)
        XCTAssertEqual(recorder.events.last?.point, CGPoint(x: tv.maxX.nextDown, y: 500))
    }

    func testMotionIntoTheGapLandsOnTheNearestDisplay() {
        let recorder = ClampRecorder(start: CGPoint(x: 1400, y: 900))
        let driver = driver(recorder, displays: [main, tv])
        XCTAssertTrue(driver.handle(RemoteAction(action: "move", x: 200, y: 0), now: 1).accepted)
        XCTAssertEqual(recorder.events.last?.point, CGPoint(x: 1600, y: tv.maxY.nextDown))
    }

    func testAPictureConfigurationForgetsTheOtherDisplays() {
        let recorder = ClampRecorder(start: CGPoint(x: 100, y: 100))
        let driver = driver(recorder, displays: [main, tv])
        driver.configure(bounds: main)
        XCTAssertEqual(driver.displayRects, [])
        XCTAssertTrue(driver.handle(RemoteAction(action: "move", x: 5000, y: 0), now: 1).accepted)
        XCTAssertEqual(recorder.events.last?.point.x, main.maxX.nextDown)
    }

    func testASingleDisplayBehavesLikeBounds() {
        let recorder = ClampRecorder(start: CGPoint(x: 100, y: 100))
        let driver = driver(recorder, displays: [main])
        XCTAssertTrue(driver.handle(RemoteAction(action: "move", x: -500, y: 5000), now: 1).accepted)
        XCTAssertEqual(recorder.events.last?.point, CGPoint(x: 0, y: main.maxY.nextDown))
    }

    func testConfiguringDisplaysReleasesAHeldButton() {
        let recorder = ClampRecorder(start: CGPoint(x: 100, y: 100))
        let driver = driver(recorder, displays: [main, tv])
        XCTAssertTrue(driver.handle(RemoteAction(action: "dragDown"), now: 1).accepted)
        XCTAssertTrue(driver.held)
        driver.configure(displays: [main])
        XCTAssertFalse(driver.held)
        XCTAssertEqual(recorder.events.last?.type, .leftMouseUp)
    }

    func testNoUsableDisplayRefusesMotion() {
        let recorder = ClampRecorder(start: CGPoint(x: 100, y: 100))
        let driver = driver(recorder, displays: [CGRect(x: 0, y: 0, width: 0, height: 10)])
        XCTAssertFalse(driver.handle(RemoteAction(action: "move", x: 5, y: 5), now: 1).accepted)
        XCTAssertTrue(recorder.events.isEmpty)
    }
}
