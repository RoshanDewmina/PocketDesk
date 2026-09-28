import XCTest
import CoreGraphics

final class PointerLocationTests: XCTestCase {
    func testProbeAcceptsOnlyMatchingFreshResponseAndExpiresItsPoint() {
        var state = PointerProbeState()
        let probe = try! XCTUnwrap(state.begin(at: 10))
        XCTAssertNil(state.begin(at: 10.1), "Only one challenge may be outstanding")
        XCTAssertFalse(state.receive(probe: "wrong", location: PointerLocation(x: 4, y: 5),
                                     at: 10.1, sourceSize: CGSize(width: 100, height: 100)))
        XCTAssertEqual(state.pending, probe)
        XCTAssertTrue(state.receive(probe: probe, location: PointerLocation(x: 4, y: 5),
                                    at: 10.249, sourceSize: CGSize(width: 100, height: 100)))
        XCTAssertEqual(state.point, CGPoint(x: 4, y: 5))
        state.expire(at: 10.5)
        XCTAssertNil(state.point)
    }

    func testExpiredAndSupersededProbeCannotRestoreLocation() {
        var state = PointerProbeState()
        let old = try! XCTUnwrap(state.begin(at: 1))
        XCTAssertFalse(state.receive(probe: old, location: PointerLocation(x: 2, y: 3),
                                     at: 1.251, sourceSize: CGSize(width: 10, height: 10)))
        XCTAssertNil(state.point)

        let current = try! XCTUnwrap(state.begin(at: 2))
        XCTAssertFalse(state.receive(probe: old, location: PointerLocation(x: 2, y: 3),
                                     at: 2.1, sourceSize: CGSize(width: 10, height: 10)))
        XCTAssertTrue(state.receive(probe: current, location: PointerLocation(x: 8, y: 9),
                                    at: 2.1, sourceSize: CGSize(width: 10, height: 10)))
        XCTAssertEqual(state.point, CGPoint(x: 8, y: 9))
        XCTAssertFalse(state.receive(probe: current, location: PointerLocation(x: 1, y: 1),
                                     at: 2.2, sourceSize: CGSize(width: 10, height: 10)),
                       "A response cannot be replayed")
    }

    func testMalformedLocatorFieldsAreRejectedAndLegacyActionDecodes() throws {
        let legacy = Data(#"{"action":"heartbeat","x":0,"y":0,"text":"","key":"","modifiers":[],"epoch":1}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: legacy)
        XCTAssertNil(decoded.pointerProbe)
        XCTAssertNil(decoded.pointerLocation)
        XCTAssertNil(decoded.pointerLocatorSupported)
        XCTAssertNoThrow(try decoded.validate())

        XCTAssertNoThrow(try RemoteAction(action: "capture", pointerLocatorSupported: true).validate())
        XCTAssertNoThrow(try RemoteAction(action: "heartbeat", pointerProbe: "probe",
                                        pointerLocation: PointerLocation(x: 1, y: 2)).validate())
        XCTAssertThrowsError(try RemoteAction(action: "move", pointerProbe: "probe").validate())
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", pointerProbe: String(repeating: "p", count: 65)).validate())
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", pointerLocation: PointerLocation(x: 1, y: 2)).validate())
        XCTAssertThrowsError(try RemoteAction(action: "capture", pointerProbe: "probe").validate())
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", pointerProbe: "probe",
                                              pointerLocation: PointerLocation(x: .nan, y: 2)).validate())
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", pointerProbe: "probe",
                                              pointerLocation: PointerLocation(x: 20001, y: 2)).validate())
    }

    func testSelectedDisplayMappingRejectsOutsideAndNonFinitePoints() {
        let frame = CGRect(x: -100, y: 200, width: 100, height: 50)
        XCTAssertEqual(HostPointerLocator.location(for: CGPoint(x: -75, y: 225), in: frame),
                       PointerLocation(x: 25, y: 25))
        XCTAssertNil(HostPointerLocator.location(for: CGPoint(x: -101, y: 225), in: frame))
        XCTAssertNil(HostPointerLocator.location(for: CGPoint(x: 0, y: 225), in: frame))
        XCTAssertNil(HostPointerLocator.location(for: CGPoint(x: -75, y: 250), in: frame))
        XCTAssertNil(HostPointerLocator.location(for: CGPoint(x: CGFloat.infinity, y: 225), in: frame))
    }

    func testHostDropsSurplusQueriesAndResetsForNewSession() {
        var locator = HostPointerLocator()
        XCTAssertTrue(locator.admit(at: 1))
        XCTAssertFalse(locator.admit(at: 1.01))
        XCTAssertTrue(locator.admit(at: 1.04))
        XCTAssertFalse(locator.admit(at: 1.02), "A clock regression is not a new query slot")
        locator.reset()
        XCTAssertTrue(locator.admit(at: 1.02))
    }
}
