import XCTest

final class MediaDiagnosticsTests: XCTestCase {
    func testMissingOrUnknownCandidatesCannotClaimDirect() {
        XCTAssertEqual(MediaRoute.classify(selected: false, local: "host", remote: "host"), "Route pending")
        XCTAssertEqual(MediaRoute.classify(selected: true, local: nil, remote: nil), "Route pending")
        XCTAssertEqual(MediaRoute.classify(selected: true, local: "host", remote: nil), "Route pending")
        XCTAssertEqual(MediaRoute.classify(selected: true, local: "host", remote: "unknown"), "Route pending")
    }
    func testRouteUsesObservedCandidateTypes() {
        XCTAssertEqual(MediaRoute.classify(selected: true, local: "host", remote: "srflx"), "Direct")
        XCTAssertEqual(MediaRoute.classify(selected: true, local: "prflx", remote: "host"), "Direct")
        XCTAssertEqual(MediaRoute.classify(selected: true, local: "relay", remote: "host"), "Relay")
        XCTAssertEqual(MediaRoute.classify(selected: true, local: "host", remote: "relay"), "Relay")
    }
}
