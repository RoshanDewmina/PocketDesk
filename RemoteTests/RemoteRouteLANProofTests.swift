import XCTest
import Foundation

/// Remote-route LAN proof: off by default on both ends, each end must opt in, and the proof never
/// gates, restricts or fails the session. A pass is LAN evidence only, never `provenLocalLinkActive`.
@MainActor
final class RemoteRouteLANProofTests: XCTestCase {
    private func defaults(_ values: [String: Bool] = [:]) throws -> UserDefaults {
        let suite = "RemoteRouteLANProofTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        for (key, value) in values { defaults.set(value, forKey: key) }
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    private var bothOn: [String: Bool] {
        [StreamTuning.remoteRouteLANProofKey: true, RemoteRouteLANProofRequest.defaultsKey: true]
    }

    private func routeMessage(room: String, access: String) throws -> RelayMessage {
        let deadline = Int64((Date().timeIntervalSince1970 + 60) * 1000)
        let json = """
        {"type":"route","version":1,"room":"\(room)","epoch":"\(String(repeating: "c", count: 32))","revision":1,"access":"\(access)","expiresAt":\(deadline)}
        """
        return try JSONDecoder().decode(RelayMessage.self, from: Data(json.utf8))
    }

    private func endpointBody() throws -> Data {
        try JSONEncoder().encode(LocalProbeEndpoint(address: "192.0.2.20", port: 45000))
    }

    final class PairBuilds: @unchecked Sendable {
        private let lock = NSLock()
        private var bound: [String] = []
        func begin(_ address: String) { lock.lock(); bound.append(address); lock.unlock() }
        var addresses: [String] { lock.lock(); defer { lock.unlock() }; return bound }
    }

    final class BuildCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func begin() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func waitFor(_ description: String, seconds: Double = 5, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), description)
    }

    func testFlagsAreOffByDefaultAndTheTuningRecordsTheArm() throws {
        let empty = try defaults()
        XCTAssertFalse(RemoteRouteLANProofRequest.isEnabled(empty))
        XCTAssertFalse(StreamTuning.resolve(defaults: empty).remoteRouteLANProof)
        XCTAssertFalse(StreamTuning.resolve(defaults: empty).summary.contains("LAN proof"))
        let on = try defaults(bothOn)
        XCTAssertTrue(RemoteRouteLANProofRequest.isEnabled(on))
        XCTAssertTrue(StreamTuning.resolve(defaults: on).summary.contains("remote-route LAN proof"))
        XCTAssertTrue(StreamTuning.experimentKeys.contains(StreamTuning.remoteRouteLANProofKey))
    }

    func testTheOfferIsAnOptionalKeyOutsideTheCappedLists() throws {
        var handshake = MacShareBlocker.Handshake.phoneRequest([SessionFeature.videoRefinement, SessionFeature.textClarity],
                                                               defaults: try defaults())
        XCTAssertNil(handshake.lanProof)
        let plain = try JSONEncoder().encode(handshake)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("lanProof"), "off sends exactly today's request")
        XCTAssertFalse(MacShareBlocker.Handshake.supportsRemoteRouteLANProof(in: plain))
        handshake.lanProof = true
        let offered = try JSONEncoder().encode(handshake)
        XCTAssertLessThanOrEqual(offered.count, 1024, "older Macs drop a request body over 1 KB")
        XCTAssertTrue(MacShareBlocker.Handshake.supportsRemoteRouteLANProof(in: offered))
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: offered), MacShareBlocker.Handshake.features(in: plain))
        XCTAssertFalse(MacShareBlocker.Handshake.supportsRemoteRouteLANProof(in: nil))
        XCTAssertFalse(MacShareBlocker.Handshake.supportsRemoteRouteLANProof(in: Data(repeating: 0, count: 1025)))
    }

    func testAPassedProofIsNeverAProvenLocalLinkNorAPriorityChange() {
        let peer = PeerMedia(isHost: true, servers: [])
        defer { peer.close() }
        peer.setRemoteRouteLANProof([ProvenLocalLink(localAddress: "192.168.1.10", peerAddress: "192.168.1.20")])
        XCTAssertFalse(peer.provenLocalLinkActive, "couch admission and the presentation lease never see it")
        XCTAssertFalse(peer.remoteRouteLANPairSelected, "evidence waits for a sample whose selected pair is the proven one")
        XCTAssertEqual(peer.transportPriority.summary, "DSCP off · priority medium")
        peer.setRemoteRouteLANProof([])
        XCTAssertFalse(peer.remoteRouteLANPairSelected)
    }

    func testOnlyTheExactProvenPairCountsOnARemoteRoute() {
        let link = ProvenLocalLink(localAddress: "192.168.1.10", peerAddress: "192.168.1.20")
        func matches(_ local: String, _ remote: String, adapter: String = "wifi", vpn: Bool? = nil) -> Bool {
            LocalMediaRoute.matches(link, localType: "host", remoteType: "host", localAddress: local,
                                    remoteAddress: remote, adapterType: adapter, vpn: vpn)
        }
        XCTAssertTrue(matches("192.168.1.10", "192.168.1.20"))
        XCTAssertFalse(matches("100.101.102.103", "100.64.0.7"), "a Tailscale host pair is not the proven pair")
        XCTAssertFalse(matches("192.168.1.10", "192.168.1.21"), "another device on the LAN is not the proven peer")
        XCTAssertFalse(matches("192.168.1.10", "192.168.1.20", adapter: "cellular"))
        XCTAssertFalse(matches("192.168.1.10", "192.168.1.20", vpn: true))
    }

    // MARK: The selected pair (device test, 7 Oct 17:06)

    /// Both flags on, iPhone and Mac on one Wi-Fi: the IPv4 proof passed on en0 at 17:06:10.852, then all
    /// 75 samples read host/host adapter=unknown network=unknown, Direct/lan, remoteRouteLANPair false.
    /// The network is dual-stack (one /64) and WebRTC ranks an IPv6 host candidate above IPv4, so the
    /// stream's pair was IPv6 and never the proven IPv4 pair. Documentation addresses stand in for it.
    private let proven1706 = ProvenLocalLink(localAddress: "10.0.0.92", peerAddress: "10.0.0.40")
    private let macIPv6 = "2001:db8:fe00:853d:14f2:818f:835e:c2e2"
    private let phoneIPv6 = "2001:db8:fe00:853d:a5eb:39d8:abab:7d53"

    func testThe1706PairWasAnUnprovenIPv6PairAndProvingThatPairMakesItCount() {
        let peer = PeerMedia(isHost: true, servers: [])
        defer { peer.close() }
        var asked: [[String]] = []
        peer.onRemoteRouteLANUnprovenPair = { asked.append([$0, $1]) }
        func sample(_ local: String, _ remote: String) -> Bool {
            peer.followRemoteRouteLANPair(localType: "host", remoteType: "host", localAddress: local, remoteAddress: remote,
                                          adapterType: "unknown", networkType: "unknown", vpn: false)
            return peer.remoteRouteLANPairSelected
        }
        peer.setRemoteRouteLANProof([proven1706])
        XCTAssertFalse(sample(macIPv6, phoneIPv6), "17:06: the IPv4 proof never covers the IPv6 pair the stream selected")
        XCTAssertFalse(sample(macIPv6, phoneIPv6))
        XCTAssertEqual(asked, [[macIPv6, phoneIPv6]], "asked once to prove that exact pair")
        XCTAssertTrue(sample("10.0.0.92", "10.0.0.40"), "the proven IPv4 pair still counts")
        peer.setRemoteRouteLANProof([proven1706, ProvenLocalLink(localAddress: macIPv6, peerAddress: phoneIPv6)])
        XCTAssertTrue(sample(macIPv6, phoneIPv6), "once the selected pair is itself proven, its samples are LAN evidence")
        XCTAssertTrue(sample(macIPv6.uppercased(), "2001:0db8:fe00:853d:a5eb:39d8:abab:7d53"), "one spelling per address")
        XCTAssertFalse(sample(macIPv6, "2001:db8:fe00:853d::fa07"), "another IPv6 neighbour is not the proven peer")
        XCTAssertEqual(asked.last, [macIPv6, "2001:db8:fe00:853d::fa07"])
        peer.setRemoteRouteLANProof([])
        XCTAssertFalse(sample(macIPv6, phoneIPv6), "the evidence ends with the proofs")
    }

    func testOnlyAPhysicalHostPairOfOneFamilyAsksForItsOwnProof() {
        let peer = PeerMedia(isHost: true, servers: [])
        defer { peer.close() }
        var asked = 0
        peer.onRemoteRouteLANUnprovenPair = { _, _ in asked += 1 }
        func sample(_ local: String = "2001:db8::92", _ remote: String = "2001:db8::40", types: (String, String) = ("host", "host"),
                    network: String = "unknown", vpn: Bool = false) {
            peer.followRemoteRouteLANPair(localType: types.0, remoteType: types.1, localAddress: local, remoteAddress: remote,
                                          adapterType: "unknown", networkType: network, vpn: vpn)
        }
        sample()
        XCTAssertEqual(asked, 0, "nothing before the first proof passed")
        peer.setRemoteRouteLANProof([proven1706])
        sample(types: ("relay", "host")); sample(types: ("srflx", "prflx"))
        sample("fd7a:115c:a1e0::1", "fd7a:115c:a1e0::2", network: "vpn"); sample(vpn: true)
        sample("10.0.0.92", "2001:db8::40"); sample("fe80::1", "fe80::2")
        XCTAssertEqual(asked, 0, "relay, reflexive, VPN, mixed-family and link-local pairs are never proven")
        sample()
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(peer.remoteRouteLANPairSelected)
    }

    func testAddressesCompareInOneSpellingAndThePairFieldIsOptionalOnTheWire() throws {
        XCTAssertEqual(LocalProbeAddress.canonical("2001:0DB8:0:0::1"), "2001:db8::1")
        XCTAssertEqual(LocalProbeAddress.canonical("10.0.0.92"), "10.0.0.92")
        XCTAssertEqual(LocalProbeAddress.family("2001:db8::1"), AF_INET6)
        XCTAssertNil(LocalProbeAddress.canonical("fe80::1"), "link-local needs a scope; it is never bound or probed")
        XCTAssertNil(LocalProbeAddress.canonical("fe80::1%en0"))
        XCTAssertNil(LocalProbeAddress.canonical("relay.example"))
        for refused in ["::", "::1", "ff02::1", "::ffff:10.0.0.40"] { XCTAssertNil(LocalProbeAddress.family(refused), refused) }
        XCTAssertTrue(LocalProbeSubnet.contains("2001:db8:fe00:853d::40", network: "2001:db8:fe00:853d::92", prefixLength: 64))
        XCTAssertFalse(LocalProbeSubnet.contains("2001:db8:fe00:853e::40", network: "2001:db8:fe00:853d::92", prefixLength: 64))
        XCTAssertFalse(LocalProbeSubnet.contains("10.0.0.40", network: "2001:db8:fe00:853d::92", prefixLength: 64))
        XCTAssertFalse(LocalProbeSubnet.contains("2001:db8::40", network: "2001:db8::92", prefixLength: 0))
        let plain = try JSONEncoder().encode(LocalProbeEndpoint(address: "10.0.0.92", port: 45000))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("peerAddress"), "the first proof's endpoint is unchanged")
        let pair = try JSONEncoder().encode(LocalProbeEndpoint(address: macIPv6, port: 45000, peerAddress: phoneIPv6))
        XCTAssertEqual(try JSONDecoder().decode(LocalProbeEndpoint.self, from: pair).peerAddress, phoneIPv6)
        XCTAssertNil(try JSONDecoder().decode(LocalProbeEndpoint.self, from: plain).peerAddress)
    }

    // MARK: The Mac, against a scripted phone

    @MainActor private struct MacRig {
        let host: RemoteCoordinator
        let signaling: ScriptedSignaling
        let cipher: SignalCipher
        let request: String
        let session: String
        let room: String
        let key: Data

        func seal(_ kind: String, sequence: UInt64, body: Data? = nil) throws -> RelayMessage {
            RelayMessage(type: "signal", payload: try cipher.seal(ProtectedMessage(kind: kind, request: request,
                session: session, sequence: sequence, body: body), sender: "client"))
        }
        var kindsSent: [String] {
            signaling.sent.compactMap { $0.payload.flatMap { try? cipher.open($0, sender: "host").kind } }
        }
    }

    private func macRig(_ values: [String: Bool], offer: Bool, access: String = "remote",
                        builds: BuildCounter) throws -> MacRig {
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair)
        let signaling = ScriptedSignaling()
        let host = RemoteCoordinator(isHost: true, store: store, retryLimit: 2, retryBaseNanoseconds: 10_000_000,
                                     registrationStableNanoseconds: 50_000_000, signaling: signaling,
                                     renewalScheduler: ManualScheduler(), defaults: try defaults(values),
                                     localProofBuilder: { _, _, _, _ in builds.begin(); return nil })
        host.restore(); host.start()
        signaling.deliver(RelayMessage(type: "registered", role: "host"))
        signaling.deliver(RelayMessage(type: "ice", servers: []))
        signaling.deliver(try routeMessage(room: pair.invitation.room, access: access))
        let cipher = try SignalCipher(key: pair.invitation.key, room: pair.invitation.room)
        let request = try SecureRandom.token()
        var handshake = MacShareBlocker.Handshake.phone
        handshake.lanProof = offer ? true : nil
        signaling.deliver(RelayMessage(type: "peer", online: true))
        signaling.deliver(RelayMessage(type: "signal", payload: try cipher.seal(ProtectedMessage(kind: "request",
            request: request, session: "", sequence: 0, body: try JSONEncoder().encode(handshake)), sender: "client")))
        let challenge = try cipher.open(try XCTUnwrap(signaling.sent.last?.payload), sender: "host")
        let rig = MacRig(host: host, signaling: signaling, cipher: cipher, request: request, session: challenge.session,
                         room: pair.invitation.room, key: pair.invitation.key)
        signaling.deliver(try rig.seal("proof", sequence: 0))
        signaling.deliver(try rig.seal("acceptedAck", sequence: 1))
        return rig
    }

    func testTheMacAttemptsOnlyWithItsFlagAndThePhonesOffer() async throws {
        let arms: [([String: Bool], Bool, Bool)] = [([:], true, false), (bothOn, false, false), (bothOn, true, true)]
        for (values, offer, attempts) in arms {
            let builds = BuildCounter()
            let rig = try macRig(values, offer: offer, builds: builds)
            defer { rig.host.stop() }
            XCTAssertEqual(rig.host.remoteRouteLANProofAttemptedForTesting, attempts)
            if attempts { try await waitFor("the proof was built off the main actor") { builds.count == 1 } }
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(builds.count, attempts ? 1 : 0)
            XCTAssertFalse(rig.kindsSent.contains("localEndpoint"), "no path, no endpoint")
            XCTAssertTrue(rig.host.isRunning)
            XCTAssertNil(rig.host.lastSessionFailure, "an unproven link is today's session, not a failure")
        }
    }

    func testTheMacNeverRunsItOnALocalRoute() throws {
        let builds = BuildCounter()
        let rig = try macRig(bothOn, offer: true, access: "local", builds: builds)
        defer { rig.host.stop() }
        XCTAssertFalse(rig.host.remoteRouteLANProofAttemptedForTesting, "a local route keeps its mandatory proof")
    }

    func testTheMacStillDropsAnUnsolicitedEndpointButIgnoresALateAnswer() async throws {
        let off = try macRig([:], offer: true, builds: BuildCounter())
        defer { off.host.stop() }
        try await waitFor("media starts") { off.host.media != nil }
        off.signaling.deliver(try off.seal("localEndpoint", sequence: 2, body: try endpointBody()))
        XCTAssertNil(off.host.media, "with the flag off, a remote-route endpoint breaks the protocol as before")

        let on = try macRig(bothOn, offer: true, builds: BuildCounter())
        defer { on.host.stop() }
        try await waitFor("media starts") { on.host.media != nil }
        on.signaling.deliver(try on.seal("localEndpoint", sequence: 2, body: try endpointBody()))
        XCTAssertNotNil(on.host.media, "an answer after the Mac's own attempt ended is not a fault")
        XCTAssertNil(on.host.lastSessionFailure)
    }

    func testAPassReachesTheMediaPeerWhenEverItIsCreatedAndItsEndClearsIt() async throws {
        let link = ProvenLocalLink(localAddress: "192.168.1.10", peerAddress: "192.168.1.20")
        let rig = try macRig(bothOn, offer: true, builds: BuildCounter())
        defer { rig.host.stop() }
        rig.host.applyRemoteRouteLANProofForTesting(link)
        try await waitFor("media starts") { rig.host.media != nil }
        XCTAssertEqual(rig.host.media?.remoteRouteLANLinks.map(\.peerAddress), ["192.168.1.20"], "a pass before media is handed over")
        XCTAssertFalse(rig.host.provenLocalLinkActive, "never the authority-bearing proven link")
        rig.host.endRemoteRouteLANProofForTesting()
        XCTAssertEqual(rig.host.media?.remoteRouteLANLinks.isEmpty, true)
        rig.host.applyRemoteRouteLANProofForTesting(link)
        XCTAssertEqual(rig.host.media?.remoteRouteLANLinks.count, 1, "a pass after media reaches the live peer")
        XCTAssertNil(rig.host.lastSessionFailure)
    }

    func testTheMacProvesTheSelectedPairOnlyAfterItsFirstProofAndAtMostTwice() async throws {
        let rig = try macRig(bothOn, offer: true, builds: BuildCounter())
        defer { rig.host.stop() }
        let pairs = PairBuilds()
        rig.host.remoteRouteLANPairProofBuilder = { _, _, _, _, local in pairs.begin(local); return nil }
        rig.host.remoteRouteLANPeerIsOnLink = { _ in true }
        try await waitFor("media starts") { rig.host.media != nil }
        let media = try XCTUnwrap(rig.host.media)
        func sample(_ remote: String) {
            media.followRemoteRouteLANPair(localType: "host", remoteType: "host", localAddress: macIPv6, remoteAddress: remote,
                                           adapterType: "unknown", networkType: "unknown", vpn: false)
        }
        sample(phoneIPv6)
        XCTAssertEqual(rig.host.remoteRouteLANPairAttemptsForTesting, 0, "nothing before the first proof passed")
        rig.host.applyRemoteRouteLANProofForTesting(proven1706)
        sample(phoneIPv6)
        try await waitFor("the pair's proof is built on the Mac's own address in it") { pairs.addresses == [macIPv6] }
        try await waitFor("an unbuildable proof ends only that attempt") { rig.host.remoteRouteLANPairForTesting == nil }
        sample(phoneIPv6)
        sample("2001:db8:fe00:853d::fa07")
        try await waitFor("a different pair is a second attempt") { pairs.addresses.count == 2 }
        try await waitFor("which ends too") { rig.host.remoteRouteLANPairForTesting == nil }
        sample("2001:db8:fe00:853d::fa08")
        XCTAssertEqual(rig.host.remoteRouteLANPairAttemptsForTesting, 2, "at most two per session")
        XCTAssertNil(rig.host.remoteRouteLANPairForTesting)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(pairs.addresses.count, 2)
        XCTAssertEqual(rig.host.remoteRouteLANLinksForTesting.count, 1, "the first proof's evidence stands")
        XCTAssertNil(rig.host.lastSessionFailure)
        XCTAssertNotNil(rig.host.media)
    }

    func testTheMacIgnoresAPairAnswerItDidNotAskFor() async throws {
        let rig = try macRig(bothOn, offer: true, builds: BuildCounter())
        defer { rig.host.stop() }
        try await waitFor("media starts") { rig.host.media != nil }
        let answer = try JSONEncoder().encode(LocalProbeEndpoint(address: phoneIPv6, port: 45000, peerAddress: macIPv6))
        rig.signaling.deliver(try rig.seal("localEndpoint", sequence: 2, body: answer))
        XCTAssertNotNil(rig.host.media, "an unasked pair answer is stale, never a fault")
        XCTAssertNil(rig.host.lastSessionFailure)
        XCTAssertTrue(rig.host.isRunning)
    }

    /// The whole Mac side with real sockets: a stand-in phone proof answers on a second address of this
    /// Mac (route probe bypassed, as in the test below). The request names the phone's address, the
    /// matching answer is accepted, the pass makes that exact pair count, and the pair's end ends it.
    func testAProvenSelectedPairCountsUntilItsOwnProofEnds() async throws {
        let addresses = Set(MacNetworkLink.interfaceAddresses().filter { $0.name.hasPrefix("en") }
            .compactMap { LocalProbeAddress.canonical(MacNetworkLink.normalized($0.address)) }
            .filter { LocalProbeAddress.family($0) == AF_INET6 }).sorted()
        guard addresses.count >= 2 else { throw XCTSkip("needs two IPv6 addresses on a physical interface") }
        let mac = addresses[0], phone = addresses[1]
        let rig = try macRig(bothOn, offer: true, builds: BuildCounter())
        defer { rig.host.stop() }
        rig.host.remoteRouteLANPeerIsOnLink = { _ in true }
        rig.host.remoteRouteLANPairProofBuilder = { room, epoch, session, key, local in
            let proof = LocalLinkProof.make(room: room, epoch: epoch, session: session, pairingKey: key, boundTo: local)
            proof?.bypassRouteProbeForTesting = true
            return proof
        }
        try await waitFor("media starts") { rig.host.media != nil }
        let media = try XCTUnwrap(rig.host.media)
        func sample() -> Bool {
            media.followRemoteRouteLANPair(localType: "host", remoteType: "host", localAddress: mac, remoteAddress: phone,
                                           adapterType: "unknown", networkType: "unknown", vpn: false)
            return media.remoteRouteLANPairSelected
        }
        rig.host.applyRemoteRouteLANProofForTesting(proven1706)
        XCTAssertFalse(sample())
        try await waitFor("the Mac sent its pair request", seconds: 5) { rig.kindsSent.filter { $0 == "localEndpoint" }.count == 1 }
        let sent = try XCTUnwrap(rig.signaling.sent.compactMap { $0.payload.flatMap { try? rig.cipher.open($0, sender: "host") } }
            .last { $0.kind == "localEndpoint" })
        let request = try JSONDecoder().decode(LocalProbeEndpoint.self, from: try XCTUnwrap(sent.body))
        XCTAssertEqual(request.address, mac)
        XCTAssertEqual(request.peerAddress, phone, "the phone is told which of its addresses the stream uses")
        let epoch = String(repeating: "c", count: 32), room = rig.room, session = rig.session, key = rig.key
        let built = await Task.detached {
            LocalLinkProof.make(room: room, epoch: epoch, session: session, pairingKey: key, boundTo: phone)
        }.value
        let stand = try XCTUnwrap(built)
        defer { stand.close() }
        stand.bypassRouteProbeForTesting = true
        stand.setPeer(LocalProbeEndpoint(address: request.address, port: request.port))
        let answer = LocalProbeEndpoint(address: phone, port: stand.endpoint.port, peerAddress: mac)
        rig.signaling.deliver(try rig.seal("localEndpoint", sequence: 2, body: try JSONEncoder().encode(answer)))
        try await waitFor("the selected pair passed", seconds: 6) { rig.host.remoteRouteLANLinksForTesting.count == 2 }
        XCTAssertTrue(sample(), "the stream's own pair is now LAN evidence")
        XCTAssertFalse(rig.host.provenLocalLinkActive)
        rig.host.remoteRouteLANPairProofForTesting?.invalidateForTesting("test-path-change")
        try await waitFor("a path change under a proven pair ends all evidence") { rig.host.remoteRouteLANLinksForTesting.isEmpty }
        XCTAssertFalse(sample())
        XCTAssertNil(rig.host.lastSessionFailure)
        XCTAssertNotNil(rig.host.media)
    }

    func testAPairAttemptThatFailsBeforePassingKeepsTheFirstProofsEvidence() async throws {
        let addresses = Set(MacNetworkLink.interfaceAddresses().filter { $0.name.hasPrefix("en") }
            .compactMap { LocalProbeAddress.canonical(MacNetworkLink.normalized($0.address)) }
            .filter { LocalProbeAddress.family($0) == AF_INET6 }).sorted()
        guard let mac = addresses.first else { throw XCTSkip("needs an IPv6 address on a physical interface") }
        let rig = try macRig(bothOn, offer: true, builds: BuildCounter())
        defer { rig.host.stop() }
        rig.host.remoteRouteLANPeerIsOnLink = { _ in true }
        rig.host.remoteRouteLANPairProofBuilder = { room, epoch, session, key, local in
            let proof = LocalLinkProof.make(room: room, epoch: epoch, session: session, pairingKey: key, boundTo: local)
            proof?.bypassRouteProbeForTesting = true
            return proof
        }
        try await waitFor("media starts") { rig.host.media != nil }
        rig.host.applyRemoteRouteLANProofForTesting(proven1706)
        rig.host.media?.followRemoteRouteLANPair(localType: "host", remoteType: "host", localAddress: mac, remoteAddress: phoneIPv6,
                                                 adapterType: "unknown", networkType: "unknown", vpn: false)
        try await waitFor("the pair proof is running", seconds: 5) { rig.host.remoteRouteLANPairProofForTesting != nil }
        rig.host.remoteRouteLANPairProofForTesting?.invalidateForTesting("test-route-failed")
        try await waitFor("only the attempt ended") { rig.host.remoteRouteLANPairForTesting == nil }
        XCTAssertEqual(rig.host.remoteRouteLANLinksForTesting.count, 1, "the IPv4 evidence stands")
        XCTAssertEqual(rig.host.media?.remoteRouteLANLinks.count, 1)
        XCTAssertNil(rig.host.lastSessionFailure)
    }

    // MARK: The phone, against a scripted Mac

    private func acceptedPhone(_ values: [String: Bool], access: String, onLink: Bool = true,
                               builds: BuildCounter) throws -> (RemoteCoordinator, ScriptedSignaling, SignalCipher, ProtectedMessage, String) {
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair.invitation)
        let signaling = ScriptedSignaling()
        let phone = RemoteCoordinator(isHost: false, store: store, retryLimit: 0, signaling: signaling,
                                      renewalScheduler: ManualScheduler(), defaults: try defaults(values),
                                      localProofBuilder: { _, _, _, _ in builds.begin(); return nil })
        phone.remoteRouteLANPeerIsOnLink = { _ in onLink }
        phone.restore(); phone.start()
        signaling.deliver(try routeMessage(room: pair.invitation.room, access: access))
        signaling.deliver(RelayMessage(type: "peer", online: true))
        let cipher = try SignalCipher(key: pair.invitation.key, room: pair.invitation.room)
        let request = try cipher.open(try XCTUnwrap(signaling.sent.last?.payload), sender: "client")
        let session = try SecureRandom.token()
        func seal(_ kind: String, _ sequence: UInt64) throws -> RelayMessage {
            RelayMessage(type: "signal", payload: try cipher.seal(ProtectedMessage(kind: kind, request: request.request,
                session: session, sequence: sequence), sender: "host"))
        }
        signaling.deliver(try seal("challenge", 0))
        signaling.deliver(try seal("accepted", 1))
        return (phone, signaling, cipher, request, session)
    }

    func testThePhoneOffersOnlyWithItsFlagOnARemoteRoute() throws {
        for (values, access, offers) in [([String: Bool](), "remote", false), (bothOn, "remote", true), (bothOn, "local", false)] {
            let (phone, _, _, request, _) = try acceptedPhone(values, access: access, builds: BuildCounter())
            defer { phone.stop() }
            XCTAssertEqual(request.kind, "request")
            XCTAssertEqual(MacShareBlocker.Handshake.supportsRemoteRouteLANProof(in: request.body), offers, "\(values) \(access)")
            XCTAssertEqual(phone.remoteRouteLANProofOfferedForTesting, offers)
        }
    }

    func testThePhoneAnswersTheMacsEndpointOnceAndNeverFailsForIt() async throws {
        let builds = BuildCounter()
        let (phone, signaling, cipher, request, session) = try acceptedPhone(bothOn, access: "remote", builds: builds)
        defer { phone.stop() }
        func endpoint(_ sequence: UInt64) throws -> RelayMessage {
            RelayMessage(type: "signal", payload: try cipher.seal(ProtectedMessage(kind: "localEndpoint", request: request.request,
                session: session, sequence: sequence, body: try endpointBody()), sender: "host"))
        }
        signaling.deliver(try endpoint(2))
        try await waitFor("the phone built its answering proof") { builds.count == 1 }
        signaling.deliver(try endpoint(3))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(builds.count, 1, "a repeated endpoint is stale, not a second attempt")
        XCTAssertTrue(phone.isRunning, "no path to prove is today's session")

        let (unasked, unaskedSignaling, unaskedCipher, unaskedRequest, unaskedSession) = try acceptedPhone([:], access: "remote", builds: BuildCounter())
        defer { unasked.stop() }
        unaskedSignaling.deliver(RelayMessage(type: "signal", payload: try unaskedCipher.seal(ProtectedMessage(kind: "localEndpoint",
            request: unaskedRequest.request, session: unaskedSession, sequence: 2, body: try endpointBody()), sender: "host")))
        XCTAssertFalse(unasked.isRunning, "a phone that did not offer still fails closed, as before")
    }

    func testThePhoneNeverProbesAMacEndpointOutsideItsOwnLAN() async throws {
        let builds = BuildCounter()
        let (phone, signaling, cipher, request, session) = try acceptedPhone(bothOn, access: "remote", onLink: false, builds: builds)
        defer { phone.stop() }
        signaling.deliver(RelayMessage(type: "signal", payload: try cipher.seal(ProtectedMessage(kind: "localEndpoint",
            request: request.request, session: session, sequence: 2, body: try endpointBody()), sender: "host")))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(builds.count, 0, "another network's private address is never probed")
        XCTAssertTrue(phone.isRunning)
        XCTAssertTrue(LocalProbeSubnet.contains("192.168.1.20", network: "192.168.1.10", mask: "255.255.255.0"))
        XCTAssertFalse(LocalProbeSubnet.contains("192.168.2.20", network: "192.168.1.10", mask: "255.255.255.0"))
        XCTAssertFalse(LocalProbeSubnet.contains("100.64.0.7", network: "192.168.1.10", mask: "255.255.255.0"))
        XCTAssertFalse(LocalProbeSubnet.contains("192.168.1.20", network: "192.168.1.10", mask: "0.0.0.0"))
    }

    func testThePhoneProvesARequestedPairOnlyAfterItsFirstAttemptAndOnItsOwnLAN() async throws {
        let builds = BuildCounter(), pairs = PairBuilds()
        let (phone, signaling, cipher, request, session) = try acceptedPhone(bothOn, access: "remote", builds: builds)
        defer { phone.stop() }
        phone.remoteRouteLANPairProofBuilder = { _, _, _, _, local in pairs.begin(local); return nil }
        func deliver(_ endpoint: LocalProbeEndpoint, _ sequence: UInt64) throws {
            signaling.deliver(RelayMessage(type: "signal", payload: try cipher.seal(ProtectedMessage(kind: "localEndpoint",
                request: request.request, session: session, sequence: sequence, body: try JSONEncoder().encode(endpoint)), sender: "host")))
        }
        let pairRequest = LocalProbeEndpoint(address: macIPv6, port: 45001, peerAddress: phoneIPv6.uppercased())
        try deliver(pairRequest, 2)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(pairs.addresses.isEmpty, "no pair proof before this session's first attempt")
        XCTAssertTrue(phone.isRunning, "an early pair request is stale, not a fault")
        try deliver(LocalProbeEndpoint(address: "192.0.2.20", port: 45000), 3)
        try await waitFor("the first proof was attempted") { builds.count == 1 }
        try deliver(pairRequest, 4)
        try await waitFor("the phone binds its own address in the Mac's selected pair") { pairs.addresses == [phoneIPv6] }
        try await waitFor("an unbuildable proof ends only that attempt") { phone.remoteRouteLANPairForTesting == nil }
        phone.remoteRouteLANPeerIsOnLink = { _ in false }
        try deliver(LocalProbeEndpoint(address: "2001:db8:ffff::92", port: 45002, peerAddress: phoneIPv6), 5)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(pairs.addresses.count, 1, "a Mac address outside this phone's own prefixes is never probed")
        XCTAssertTrue(phone.isRunning)
        XCTAssertNil(phone.lastSessionFailure)
    }

    // MARK: Both ends, real sockets

    @MainActor private final class RemoteRouteBridge {
        let host = ScriptedSignaling()
        let phone = ScriptedSignaling()
        private var hostUp = false, phoneUp = false, peerAnnounced = false
        private var revision = 0

        init() {
            host.onConnect = { [weak self] connect in self?.registered(self?.host, role: "host", room: connect.invitation.room) }
            phone.onConnect = { [weak self] connect in self?.registered(self?.phone, role: "client", room: connect.invitation.room) }
            host.respond = { [weak self] message in
                guard message.type == "signal" else { return }
                Task { @MainActor in self?.phone.deliver(message) }
            }
            phone.respond = { [weak self] message in
                guard message.type == "signal" else { return }
                Task { @MainActor in self?.host.deliver(message) }
            }
        }

        private func decode(_ json: String) -> RelayMessage {
            try! JSONDecoder().decode(RelayMessage.self, from: Data(json.utf8))
        }

        private func registered(_ side: ScriptedSignaling?, role: String, room: String) {
            guard let side else { return }
            revision += 1
            let deadline = Int64((Date().timeIntervalSince1970 + 120) * 1000)
            side.deliver(decode(#"{"type":"registered","role":"\#(role)"}"#))
            side.deliver(decode(#"{"type":"route","version":1,"room":"\#(room)","epoch":"\#(String(repeating: "e", count: 32))","revision":\#(revision),"access":"remote","expiresAt":\#(deadline)}"#))
            side.deliver(decode(#"{"type":"ice","servers":[]}"#))
            if side === host { hostUp = true } else { phoneUp = true }
            if hostUp && phoneUp && !peerAnnounced {
                peerAnnounced = true
                let online = decode(#"{"type":"peer","online":true}"#)
                host.deliver(online); phone.deliver(online)
            }
        }
    }

    func testAnUnprovableLinkEndsOnlyTheProofNotTheSession() async throws {
        let bridge = RemoteRouteBridge()
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        let hostStore = MemoryPairStore(), phoneStore = MemoryPairStore()
        try hostStore.save(pair); try phoneStore.save(pair.invitation)
        let host = RemoteCoordinator(isHost: true, store: hostStore, retryLimit: 3, retryBaseNanoseconds: 10_000_000,
                                     retriesIndefinitely: true, registrationStableNanoseconds: 50_000_000,
                                     signaling: bridge.host, defaults: try defaults(bothOn), localProofTimeoutNanoseconds: 300_000_000)
        let phone = RemoteCoordinator(isHost: false, store: phoneStore, retryLimit: 0, signaling: bridge.phone,
                                      defaults: try defaults(bothOn), localProofTimeoutNanoseconds: 300_000_000)
        defer { withExtendedLifetime(bridge) {}; host.stop(); phone.stop() }
        host.restore(); phone.restore()
        host.start(); phone.start()
        try await waitFor("the Mac attempted the proof beside the stream") { host.remoteRouteLANProofAttemptedForTesting }
        // Both ends run on one machine: the peer endpoint is this machine's own address, which the
        // proof refuses, so it can never pass and its bound ends it. With no single physical path it
        // never starts. Either way only the proof ends.
        let started = Date()
        while host.remoteRouteLANProofForTesting == nil, Date().timeIntervalSince(started) < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let ran = host.remoteRouteLANProofForTesting != nil
        try await waitFor("the proof ended on its own", seconds: 10) { host.remoteRouteLANProofForTesting == nil && host.media != nil }
        print("remote-route proof on this machine: \(ran ? "ran and timed out" : "had no single physical path")")
        XCTAssertNil(host.remoteRouteLANProofForTesting)
        XCTAssertNil(host.lastSessionFailure)
        XCTAssertFalse(host.provenLocalLinkActive)
        XCTAssertNotNil(host.media)
        XCTAssertTrue(phone.isRunning)
    }

    /// Two of this Mac's own IPv6 addresses on its one physical interface stand in for the two ends: real
    /// sockets, hop limit, arrival interface, source address and port, HMAC and nonce. A socket bound to
    /// that interface reports it as the arrival interface even here; only the route probe is bypassed,
    /// because the path to this machine's own address is loopback (it reads `no-physical`).
    func testAnIPv6ProofPassesBetweenTheExactBoundAddresses() async throws {
        final class Proven: @unchecked Sendable { var links: [ProvenLocalLink] = [] }
        let addresses = Set(MacNetworkLink.interfaceAddresses().filter { $0.name.hasPrefix("en") }
            .compactMap { LocalProbeAddress.canonical(MacNetworkLink.normalized($0.address)) }
            .filter { LocalProbeAddress.family($0) == AF_INET6 }).sorted()
        guard addresses.count >= 2 else { throw XCTSkip("needs two IPv6 addresses on a physical interface") }
        let room = try SecureRandom.token(), session = try SecureRandom.token(), epoch = String(repeating: "e", count: 32)
        let key = Data(repeating: 7, count: 32)
        let (first, second, foreign) = await Task.detached {
            (LocalLinkProof.make(room: room, epoch: epoch, session: session, pairingKey: key, boundTo: addresses[0]),
             LocalLinkProof.make(room: room, epoch: epoch, session: session, pairingKey: key, boundTo: addresses[1]),
             LocalLinkProof.make(room: room, epoch: epoch, session: session, pairingKey: key, boundTo: "2001:db8::1"))
        }.value
        guard let first, let second else {
            first?.close(); second?.close()
            throw XCTSkip("no single physical path here")
        }
        defer { first.close(); second.close() }
        XCTAssertEqual(first.endpoint.address, addresses[0])
        XCTAssertNil(foreign, "an address this Mac does not have is never bound")
        let proven = Proven()
        first.bypassRouteProbeForTesting = true
        second.bypassRouteProbeForTesting = true
        first.onProven = { proven.links.append($0) }
        second.onProven = { proven.links.append($0) }
        first.setPeer(second.endpoint)
        second.setPeer(first.endpoint)
        try await waitFor("both ends proved the exact pair", seconds: 6) { proven.links.count == 2 }
        print("IPv6 pair proof on this machine: \(proven.links.count == 2 ? "passed" : first.stageSummary())")
        XCTAssertTrue(proven.links.contains { $0.localAddress == addresses[0] && $0.peerAddress == addresses[1] })
        XCTAssertTrue(proven.links.contains { $0.localAddress == addresses[1] && $0.peerAddress == addresses[0] })
    }
}
