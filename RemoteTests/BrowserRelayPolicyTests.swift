import XCTest

final class BrowserRelayPolicyTests: XCTestCase {
    private func stun() -> ICEServerConfiguration {
        ICEServerConfiguration(urls: ["stun:stun.example:3478"], username: nil, credential: nil)
    }
    private func turn() -> ICEServerConfiguration {
        ICEServerConfiguration(urls: ["turn:turn.example:3478"], username: "u", credential: "c")
    }
    private func turns() -> ICEServerConfiguration {
        ICEServerConfiguration(urls: ["turns:turn.example:5349"], username: "u", credential: "c")
    }

    func testAllPolicyNeverForcesRelayRegardlessOfServers() {
        XCTAssertEqual(BrowserRelayPolicy.relayDecision(servers: [], policy: "all"), .proceed(forceRelay: false))
        XCTAssertEqual(BrowserRelayPolicy.relayDecision(servers: [stun()], policy: "all"), .proceed(forceRelay: false))
        XCTAssertEqual(BrowserRelayPolicy.relayDecision(servers: [turn()], policy: "all"), .proceed(forceRelay: false))
    }

    func testRelayPolicyWithNoServersFailsClosed() {
        XCTAssertEqual(BrowserRelayPolicy.relayDecision(servers: [], policy: "relay"), .relayRequiredUnavailable)
    }

    func testRelayPolicyWithOnlyStunFailsClosed() {
        XCTAssertEqual(BrowserRelayPolicy.relayDecision(servers: [stun()], policy: "relay"), .relayRequiredUnavailable)
    }

    func testRelayPolicyWithTurnProceedsForcingRelay() {
        XCTAssertEqual(BrowserRelayPolicy.relayDecision(servers: [stun(), turn()], policy: "relay"), .proceed(forceRelay: true))
    }

    func testRelayPolicyWithTurnsProceedsForcingRelay() {
        XCTAssertEqual(BrowserRelayPolicy.relayDecision(servers: [turns()], policy: "relay"), .proceed(forceRelay: true))
    }
}
