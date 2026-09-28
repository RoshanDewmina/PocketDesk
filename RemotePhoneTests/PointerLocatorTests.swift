import XCTest
@testable import PocketDeskRemote

@MainActor
final class PointerLocatorTests: XCTestCase {
    func testResumedMotionCannotFollowAnIdleProbe() {
        let locator = PointerLocator()
        var follows = 0
        let subscription = locator.followUpdates.sink { _ in follows += 1 }
        defer { subscription.cancel() }
        locator.moved(at: 1)
        locator.stopFollowing()
        let idleProbe = locator.poll(at: 1.01, available: true)!
        locator.moved(at: 1.02)
        let activeProbe = locator.poll(at: 1.02, available: true)
        XCTAssertNotNil(activeProbe)
        locator.receive(RemoteAction(action: "heartbeat", pointerProbe: idleProbe,
            pointerLocation: PointerLocation(x: 99, y: 50)), at: 1.03,
            sourceSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(follows, 0)
    }

    func testFollowRequiresFreshActiveMotionAndStopsWithoutLatePan() {
        let locator = PointerLocator()
        var followed: [CGPoint] = []
        let subscription = locator.followUpdates.sink { followed.append($0) }
        defer { subscription.cancel() }
        locator.moved(at: 1)
        let probe = locator.poll(at: 1, available: true)!
        locator.receive(RemoteAction(action: "heartbeat", pointerProbe: probe,
            pointerLocation: PointerLocation(x: 99, y: 50)), at: 1.04,
            sourceSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(followed, [CGPoint(x: 99, y: 50)])

        let pending = locator.poll(at: 1.05, available: true)!
        locator.stopFollowing()
        locator.receive(RemoteAction(action: "heartbeat", pointerProbe: pending,
            pointerLocation: PointerLocation(x: 98, y: 50)), at: 1.06,
            sourceSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(followed.count, 1, "A response after lift or ownership change cannot pan")

        locator.moved(at: 2)
        let resumed = locator.poll(at: 2, available: true)!
        locator.receive(RemoteAction(action: "heartbeat", pointerProbe: resumed,
            pointerLocation: PointerLocation(x: 90, y: 50)), at: 2.10,
            sourceSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(followed.last, CGPoint(x: 90, y: 50),
                       "A held finger can finish following a valid delayed probe")
        locator.moved(at: 2.11)
        let current = locator.poll(at: 2.11, available: true)!
        locator.receive(RemoteAction(action: "heartbeat", pointerProbe: current,
            pointerLocation: PointerLocation(x: 85, y: 50)), at: 2.13,
            sourceSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(followed.last, CGPoint(x: 85, y: 50))
    }

    func testHighlightRequiresRecentMovementAndCurrentResponse() {
        let locator = PointerLocator()
        XCTAssertNil(locator.poll(at: 10, available: true))
        locator.moved(at: 10)
        let probe = locator.poll(at: 10, available: true)!
        locator.receive(RemoteAction(action: "heartbeat", pointerProbe: probe,
                                    pointerLocation: PointerLocation(x: 25, y: 40)),
                        at: 10.1, sourceSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(locator.point, CGPoint(x: 25, y: 40))
        _ = locator.poll(at: 10.4, available: true)
        XCTAssertNil(locator.point, "A delayed stream must not leave a persistent locator")
        XCTAssertNil(locator.poll(at: 10.9, available: true), "Polling ends shortly after motion stops")
    }

    func testContextChangeDiscardsOutstandingResponse() {
        let locator = PointerLocator()
        locator.moved(at: 10)
        let probe = locator.poll(at: 10, available: true)!
        locator.clear()
        locator.receive(RemoteAction(action: "heartbeat", pointerProbe: probe,
                                    pointerLocation: PointerLocation(x: 25, y: 40)),
                        at: 10.1, sourceSize: CGSize(width: 100, height: 100))
        XCTAssertNil(locator.point)
        locator.moved(at: 11)
        XCTAssertNil(locator.poll(at: 11, available: false))
        XCTAssertNil(locator.poll(at: 11.1, available: true), "Fresh motion is required after authority returns")
    }
}
