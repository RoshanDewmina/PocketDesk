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

final class NativeRelayPolicyTests: XCTestCase {
    private let stun = ICEServerConfiguration(urls: ["stun:stun.cloudflare.com:3478"], username: nil, credential: nil)
    private let turn = ICEServerConfiguration(
        urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"],
        username: "u", credential: "c")

    func testNoPolicyAndNoLocalOverrideNeverForcesRelay() {
        XCTAssertEqual(NativeRelayPolicy.decide(servers: [], policy: nil, localForce: false), .proceed(forceRelay: false))
        XCTAssertEqual(NativeRelayPolicy.decide(servers: [stun, turn], policy: "all", localForce: false), .proceed(forceRelay: false))
    }

    func testServerRelayPolicyForcesRelayWhenATurnServerIsPresent() {
        XCTAssertEqual(NativeRelayPolicy.decide(servers: [stun, turn], policy: "relay", localForce: false), .proceed(forceRelay: true))
    }

    func testServerRelayPolicyWithoutTurnFailsClosed() {
        XCTAssertEqual(NativeRelayPolicy.decide(servers: [stun], policy: "relay", localForce: false),
                       .relayRequiredUnavailable(serverRequired: true))
        XCTAssertEqual(NativeRelayPolicy.decide(servers: [], policy: "relay", localForce: false),
                       .relayRequiredUnavailable(serverRequired: true))
    }

    func testLocalRelayOnlyToggleKeepsItsOwnBehavior() {
        XCTAssertEqual(NativeRelayPolicy.decide(servers: [stun, turn], policy: nil, localForce: true), .proceed(forceRelay: true))
        XCTAssertEqual(NativeRelayPolicy.decide(servers: [stun], policy: nil, localForce: true),
                       .relayRequiredUnavailable(serverRequired: false))
    }

    func testOnlyKnownPoliciesAreAccepted() {
        XCTAssertTrue(NativeRelayPolicy.isValid(nil))
        XCTAssertTrue(NativeRelayPolicy.isValid("all"))
        XCTAssertTrue(NativeRelayPolicy.isValid("relay"))
        XCTAssertFalse(NativeRelayPolicy.isValid("direct"))
        XCTAssertFalse(NativeRelayPolicy.isValid(""))
    }

    func testIceMessageDecodesWithAndWithoutPolicySoOlderServicesStayCompatible() throws {
        let body = #"{"type":"ice","servers":[{"urls":["turn:turn.cloudflare.com:3478"],"username":"u","credential":"c"}]"#
        let legacy = try JSONDecoder().decode(RelayMessage.self, from: Data((body + "}").utf8))
        XCTAssertNil(legacy.policy)
        XCTAssertEqual(legacy.servers?.count, 1)
        let forced = try JSONDecoder().decode(RelayMessage.self, from: Data((body + #","policy":"relay"}"#).utf8))
        XCTAssertEqual(forced.policy, "relay")
    }

    func testOutboundMessagesOmitThePolicyField() throws {
        let data = try JSONEncoder().encode(RelayMessage(type: "signal", payload: "abc"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("policy"))
    }
}
