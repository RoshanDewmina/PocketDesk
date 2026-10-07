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
        peer.setRemoteRouteLANProof(ProvenLocalLink(localAddress: "192.168.1.10", peerAddress: "192.168.1.20"))
        XCTAssertFalse(peer.provenLocalLinkActive, "couch admission and the presentation lease never see it")
        XCTAssertFalse(peer.remoteRouteLANPairSelected, "evidence waits for a sample whose selected pair is the proven one")
        XCTAssertEqual(peer.transportPriority.summary, "DSCP off · priority medium")
        peer.setRemoteRouteLANProof(nil)
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

    // MARK: The Mac, against a scripted phone

    @MainActor private struct MacRig {
        let host: RemoteCoordinator
        let signaling: ScriptedSignaling
        let cipher: SignalCipher
        let request: String
        let session: String

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
        let rig = MacRig(host: host, signaling: signaling, cipher: cipher, request: request, session: challenge.session)
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
        XCTAssertEqual(rig.host.media?.remoteRouteLANLink?.peerAddress, "192.168.1.20", "a pass before media is handed over")
        XCTAssertFalse(rig.host.provenLocalLinkActive, "never the authority-bearing proven link")
        rig.host.endRemoteRouteLANProofForTesting()
        XCTAssertNil(rig.host.media?.remoteRouteLANLink)
        rig.host.applyRemoteRouteLANProofForTesting(link)
        XCTAssertNotNil(rig.host.media?.remoteRouteLANLink, "a pass after media reaches the live peer")
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
}
