import XCTest
@testable import PocketDeskRemote

final class FarsideRouteTests: XCTestCase {
    private var savedHosts: Set<String>!

    override func setUp() {
        super.setUp()
        savedHosts = FarsideRoute.associatedHosts
        FarsideRoute.associatedHosts = ["farside.example"]
    }

    override func tearDown() {
        FarsideRoute.associatedHosts = savedHosts
        super.tearDown()
    }

    private func route(_ text: String) -> FarsideRoute? {
        URL(string: text).flatMap(FarsideRoute.init(url:))
    }

    func testTheCustomSchemeRoutes() {
        XCTAssertEqual(route("\(FarsideRoute.scheme)://session"), .resumeSession)
        XCTAssertEqual(route("\(FarsideRoute.scheme)://open"), .openMac)
        XCTAssertEqual(route("\(FarsideRoute.scheme)://help/h_20af"), .agentAlert(id: "h_20af"))
        XCTAssertEqual(route("\(FarsideRoute.scheme)://open/h_20af"), .agentAlert(id: "h_20af"), "A help request id opens its alert")
        XCTAssertEqual(route("\(FarsideRoute.scheme)://open/9f3c2a71"), .openMac, "Any other link id is navigation to the Mac only")
        XCTAssertEqual(route("\(FarsideRoute.scheme.uppercased())://SESSION"), .resumeSession, "Scheme and host are case-insensitive")
    }

    func testUniversalLinksAreAcceptedOnlyFromAnAssociatedHost() {
        XCTAssertEqual(route("https://farside.example/open/h_20af"), .agentAlert(id: "h_20af"))
        XCTAssertEqual(route("https://farside.example/open"), .openMac)
        XCTAssertEqual(route("https://farside.example/open/abc123"), .openMac)
        XCTAssertNil(route("https://evil.example/open/h_20af"), "A foreign host never routes")
        XCTAssertNil(route("http://farside.example/open/h_20af"), "Only https")
        FarsideRoute.associatedHosts = []
        XCTAssertNil(route("https://farside.example/open/h_20af"), "No domain chosen means no universal links")
    }

    func testMalformedOrUnknownRoutesAreRefused() {
        XCTAssertNil(route("\(FarsideRoute.scheme)://"))
        XCTAssertNil(route("\(FarsideRoute.scheme)://help"))
        XCTAssertNil(route("\(FarsideRoute.scheme)://help/"))
        XCTAssertNil(route("\(FarsideRoute.scheme)://help/a/b"))
        XCTAssertNil(route("\(FarsideRoute.scheme)://help/h_20af/extra"))
        XCTAssertNil(route("\(FarsideRoute.scheme)://session/extra"))
        XCTAssertNil(route("\(FarsideRoute.scheme)://unknown"))
        XCTAssertNil(route("\(FarsideRoute.scheme)://help/h 20af"))
        XCTAssertNil(route("\(FarsideRoute.scheme)://help/h_%00"))
        XCTAssertNil(route("\(FarsideRoute.scheme)://help/" + String(repeating: "a", count: 65)))
        XCTAssertNil(route("mailto:someone@example.com"))
        XCTAssertNil(route("javascript:alert(1)"))
    }

    func testEveryRouteSurvivesARoundTripThroughItsURL() {
        let all: [FarsideRoute] = [.openMac, .resumeSession, .agentAlert(id: "h_1")]
        for route in all {
            XCTAssertEqual(FarsideRoute(url: route.url), route, "Routes survive a round trip through their URL")
        }
    }

    func testIsolatedBetaSchemeRejectsProductionLinksAndProductionRejectsBetaLinks() {
        let other = FarsideBeta.isEnabled ? "farside" : "farside-beta"
        XCTAssertNil(route("\(other)://open"))
        XCTAssertNil(route("\(other)://session"))
        XCTAssertNil(route("\(other)://help/h_20af"))
        XCTAssertEqual(FarsideRoute.openMac.url.scheme, FarsideBeta.urlScheme)
        XCTAssertEqual(SessionActivityLinks.session.scheme, FarsideBeta.urlScheme)
        XCTAssertEqual(ConnectWidgetLink.url.scheme, FarsideBeta.urlScheme)
    }

    func testHelpRequestIds() {
        XCTAssertTrue(FarsideRoute.isHelpRequestID("h_20af"))
        XCTAssertFalse(FarsideRoute.isHelpRequestID("h_"))
        XCTAssertFalse(FarsideRoute.isHelpRequestID("x_20af"))
        XCTAssertTrue(FarsideRoute.isValidID("A-z_09"))
        XCTAssertFalse(FarsideRoute.isValidID(""))
        XCTAssertFalse(FarsideRoute.isValidID("a b"))
    }
}
