import XCTest
import CryptoKit

@MainActor
final class EnrollmentCoordinatorTests: XCTestCase {
    private func fixture() throws -> (RemoteCoordinator, ScriptedSignaling, PhoneTrustStore, PairInvitation) {
        var old = try HostPair.create(server: "wss://offline.invalid/signal", name: "Mac",
            identity: HostIdentityRecord(hostID: String(repeating: "a", count: 64), localServiceName: "fixture")).rotated().invitation
        old.expires = Date().addingTimeInterval(120)
        let trust = PhoneTrustStore(records: MemoryPairStore(), legacy: MemoryPairStore())
        try trust.saveApproved(old)
        let signaling = ScriptedSignaling()
        let phone = RemoteCoordinator(isHost: false, store: PhonePairPersistence(trust: trust), signaling: signaling)
        phone.restore()
        return (phone, signaling, trust, old)
    }

    func testSameHostAndGrantChangedQRRequiresApprovalBeforeRetiringCurrentSession() throws {
        let (phone, signaling, trust, old) = try fixture()
        defer { phone.stop() }
        phone.start()
        var scanned = old; scanned.version = PairEnrollment.version; scanned.key = try SecureRandom.bytes(); scanned.token = try SecureRandom.token()
        XCTAssertThrowsError(try phone.enroll(scanned.code()))
        XCTAssertEqual(phone.invitation, old)
        XCTAssertEqual(signaling.connects.count, 1)
        XCTAssertEqual(try trust.snapshot().selected?.invitation, old)
        let request = try XCTUnwrap(trust.replacementRequest(for: scanned))
        try phone.enroll(scanned.code(), replacementApproval: PhoneTrustReplacementApproval(request: request, enrollment: scanned))
        XCTAssertEqual(phone.invitation, scanned)
        XCTAssertEqual(try trust.snapshot().selected?.invitation, old, "Enrollment is not saved before the host accepts")
        phone.stop()
        XCTAssertEqual(phone.invitation, old, "End must retire scanned authority and restore the persisted selection")
    }

    func testInterruptedEnrollmentDoesNotRetryAsUnscannedRotation() throws {
        let (phone, signaling, trust, old) = try fixture()
        defer { phone.stop() }
        var scanned = old; scanned.version = PairEnrollment.version; scanned.key = try SecureRandom.bytes()
        let request = try XCTUnwrap(trust.replacementRequest(for: scanned))
        try phone.enroll(scanned.code(), replacementApproval: PhoneTrustReplacementApproval(request: request, enrollment: scanned))
        signaling.onClose?()
        XCTAssertFalse(phone.isRunning)
        XCTAssertFalse(phone.reconnecting)
        XCTAssertEqual(phone.invitation, old)
        XCTAssertEqual(try trust.snapshot().selected?.invitation, old)
        phone.start()
        XCTAssertEqual(signaling.connects.last?.invitation, old)
    }

    func testForgetCapturedMacCannotDeleteLaterPersistentSelection() throws {
        let (phone, _, trust, old) = try fixture()
        defer { phone.stop() }
        let other = try HostPair.create(server: "wss://offline.invalid/signal", name: "Other Mac").rotated().invitation
        try trust.saveApproved(other)
        XCTAssertEqual(phone.invitation, old, "Simulate a persistent selection change while the owner prompt is pending")
        XCTAssertFalse(phone.revoke(expectedInvitation: old))
        XCTAssertEqual(try trust.snapshot().selected?.invitation, other)
        XCTAssertEqual(try trust.snapshot().hosts.count, 2)
    }
}


final class PairEnrollmentCryptoTests: XCTestCase {
    private struct Agreement {
        let invitation: PairInvitation
        let requestID: String
        let sessionID: String
        let phone: PairEnrollment.Ephemeral
        let host: PairEnrollment.Ephemeral
        let request: PairEnrollment.Request
        let challenge: PairEnrollment.Challenge
        func keys(isHost: Bool, invitation: PairInvitation? = nil, requestID: String? = nil,
                  sessionID: String? = nil, request: PairEnrollment.Request? = nil,
                  challenge: PairEnrollment.Challenge? = nil, reveal: PairEnrollment.Reveal? = nil) throws -> PairEnrollment.Keys {
            try PairEnrollment.derive(invitation: invitation ?? self.invitation, requestID: requestID ?? self.requestID,
                sessionID: sessionID ?? self.sessionID, request: request ?? self.request, challenge: challenge ?? self.challenge,
                phone: reveal ?? phone.reveal, ephemeral: isHost ? host : phone, isHost: isHost)
        }
    }
    private func agreement() throws -> Agreement {
        let invitation = try HostPair.create(server: "wss://offline.invalid/signal", name: "Mac").invitation
        let phone = try PairEnrollment.Ephemeral(), host = try PairEnrollment.Ephemeral()
        let requestID = try SecureRandom.token(), sessionID = try SecureRandom.token()
        let handshake = MacShareBlocker.Handshake.phone
        let commitment = try PairEnrollment.commitment(invitation: invitation, requestID: requestID,
            reveal: phone.reveal, handshake: handshake, phoneName: "Fixture iPhone")
        return Agreement(invitation: invitation, requestID: requestID, sessionID: sessionID, phone: phone, host: host,
            request: PairEnrollment.Request(commitment: commitment, handshake: handshake, phoneName: "Fixture iPhone"),
            challenge: PairEnrollment.Challenge(reveal: host.reveal))
    }
    func testBothScreensDeriveTheSameSixDigitsAndDomainSeparatedSecrets() throws {
        let a = try agreement(), phone = try a.keys(isHost: false), host = try a.keys(isHost: true)
        XCTAssertEqual(phone.comparisonCode, host.comparisonCode)
        XCTAssertEqual(phone.comparisonCode.filter(\.isNumber).count, 6)
        XCTAssertEqual(phone.comparisonCode.count, 7)
        XCTAssertEqual(phone.trustKey, host.trustKey)
        XCTAssertEqual(phone.trustToken, host.trustToken)
        XCTAssertEqual(phone.sessionKey, host.sessionKey)
        XCTAssertNotEqual(phone.sessionKey, phone.trustKey)
        XCTAssertNotEqual(phone.trustKey, a.invitation.key)
        XCTAssertTrue(host.confirms(phone.confirmation(role: "phone"), role: "phone"))
        XCTAssertFalse(host.confirms(phone.confirmation(role: "phone"), role: "host"), "Role reflection is rejected")
        XCTAssertFalse(host.confirms(Data(repeating: 0, count: 32), role: "phone"))
    }
    func testCommitmentPreventsChangingThePhoneKeyNameFeaturesQRAndRequestAfterTheHostKey() throws {
        let a = try agreement()
        XCTAssertThrowsError(try a.keys(isHost: true, reveal: PairEnrollment.Ephemeral().reveal))
        let changedName = PairEnrollment.Request(commitment: a.request.commitment, handshake: a.request.handshake, phoneName: "Other phone")
        XCTAssertThrowsError(try a.keys(isHost: true, request: changedName))
        var handshake = a.request.handshake; handshake.mode = "couch"
        let changedMode = PairEnrollment.Request(commitment: a.request.commitment, handshake: handshake, phoneName: a.request.phoneName)
        XCTAssertThrowsError(try a.keys(isHost: true, request: changedMode))
        var otherQR = a.invitation; otherQR.ownerPairID = try SecureRandom.token()
        XCTAssertThrowsError(try a.keys(isHost: true, invitation: otherQR))
        XCTAssertThrowsError(try a.keys(isHost: true, requestID: SecureRandom.token()))
    }
    func testSessionTranscriptAndIndependentCandidateCannotShareTrustOrConfirmation() throws {
        let a = try agreement(), keys = try a.keys(isHost: true)
        let anotherSession = try a.keys(isHost: true, sessionID: SecureRandom.token())
        XCTAssertNotEqual(keys.trustKey, anotherSession.trustKey)
        XCTAssertFalse(anotherSession.confirms(keys.confirmation(role: "host"), role: "host"))
        let other = try agreement().keys(isHost: true)
        XCTAssertNotEqual(keys.trustKey, other.trustKey)
        XCTAssertFalse(other.confirms(keys.confirmation(role: "phone"), role: "phone"))
    }
    func testFirst60ProofIsIgnoredByLegacyDecoderWithoutChangingKeys() throws {
        struct LegacyProof: Codable { let reveal: PairEnrollment.Reveal; let confirmation: Data }
        let a = try agreement()
        let phoneKeys = try a.keys(isHost: false)
        var proof = PairEnrollment.Proof(reveal: a.phone.reveal, confirmation: phoneKeys.confirmation(role: "phone"))
        proof.first60 = true
        proof.phoneLoadWindows = true
        let legacyProof = try JSONDecoder().decode(LegacyProof.self, from: PairEnrollment.encoded(proof))
        XCTAssertNil(a.request.handshake.first60, "New first60 opt-in never enters the enrollment transcript")
        let legacyHostKeys = try a.keys(isHost: true, reveal: legacyProof.reveal)
        XCTAssertTrue(legacyHostKeys.confirms(legacyProof.confirmation, role: "phone"))
        XCTAssertEqual(legacyHostKeys.sessionKey, phoneKeys.sessionKey)
        XCTAssertEqual(legacyHostKeys.trustKey, phoneKeys.trustKey)
        XCTAssertEqual(legacyHostKeys.comparisonCode, phoneKeys.comparisonCode)
    }

    func testOldPhoneTypedRequestAndProofStillDeriveNewHostKeysWithoutWindowOptIn() throws {
        struct OldHandshake: Codable { let features: [String]; let mode: String?; let options: [String]? }
        struct OldRequest: Codable { let version: Int; let commitment: Data; let handshake: OldHandshake; let phoneName: String? }
        struct OldProof: Codable { let reveal: PairEnrollment.Reveal; let confirmation: Data }
        let a = try agreement()
        let oldRequest = try JSONDecoder().decode(OldRequest.self, from: PairEnrollment.encoded(a.request))
        let decoded = try PairEnrollment.decode(PairEnrollment.Request.self, body: PairEnrollment.encoded(oldRequest))
        XCTAssertNil(decoded.handshake.phoneLoadWindows)
        XCTAssertEqual(try PairEnrollment.encoded(decoded), try PairEnrollment.encoded(a.request))
        let phoneKeys = try a.keys(isHost: false)
        let oldProof = OldProof(reveal: a.phone.reveal, confirmation: phoneKeys.confirmation(role: "phone"))
        let proof = try PairEnrollment.decode(PairEnrollment.Proof.self, body: PairEnrollment.encoded(oldProof))
        XCTAssertNil(proof.phoneLoadWindows)
        let hostKeys = try a.keys(isHost: true, request: decoded, reveal: proof.reveal)
        XCTAssertTrue(hostKeys.confirms(proof.confirmation, role: "phone"))
        XCTAssertEqual(hostKeys.sessionKey, phoneKeys.sessionKey)
        XCTAssertEqual(hostKeys.trustKey, phoneKeys.trustKey)
        XCTAssertEqual(hostKeys.comparisonCode, phoneKeys.comparisonCode)
    }

    func testVersionExpiryBoundsAndInvalidCurvePointsFailClosed() throws {
        let a = try agreement()
        var expired = a.invitation; expired.expires = .distantPast
        XCTAssertThrowsError(try a.keys(isHost: true, invitation: expired))
        var old = a.invitation; old.version = 1
        XCTAssertThrowsError(try a.keys(isHost: true, invitation: old))
        var oldChallenge = a.challenge; oldChallenge.version = 1
        XCTAssertThrowsError(try a.keys(isHost: false, challenge: oldChallenge))
        let zero = PairEnrollment.Challenge(reveal: PairEnrollment.Reveal(publicKey: Data(repeating: 0, count: 32), nonce: a.host.reveal.nonce))
        XCTAssertThrowsError(try a.keys(isHost: false, challenge: zero))
        var oversized = a.request.handshake; oversized.features = Array(repeating: "f", count: 9)
        XCTAssertThrowsError(try PairEnrollment.validate(PairEnrollment.Request(commitment: a.request.commitment,
            handshake: oversized, phoneName: nil)))
        XCTAssertThrowsError(try PairEnrollment.decode(PairEnrollment.Proof.self, body: Data(repeating: 0, count: 4097)))
    }
}

@MainActor
private final class ComparisonEnrollmentRig {
    let hostSignal = ScriptedSignaling(), phoneSignal = ScriptedSignaling()
    let hostStore = MemoryPairStore(), phoneStore = MemoryPairStore()
    let host: RemoteCoordinator
    let phone: RemoteCoordinator
    let invitation: PairInvitation
    private var hostQueue: [RelayMessage] = [], phoneQueue: [RelayMessage] = []
    /// Connect awaits the codec capability snapshot; instant probes keep that wait well inside the
    /// short handshake timeouts these fixtures use, independent of this Mac's cold VideoToolbox probes.
    private let previousProbes: NativeVideoCapabilityProbes?
    init(handshakeTimeoutNanoseconds: UInt64 = 15_000_000_000) throws {
        let previous = NativeVideoCapabilityProbes.installForTesting(
            NativeVideoCapabilityProbes(level52: { true }, hevcDecode: { true }, hevcEncode: { true }))
        previousProbes = previous
        var invitationCreated = false
        defer { if !invitationCreated { _ = NativeVideoCapabilityProbes.installForTesting(previous) } } // init threw: no leak
        host = RemoteCoordinator(isHost: true, store: hostStore, signaling: hostSignal, handshakeTimeoutNanoseconds: handshakeTimeoutNanoseconds)
        phone = RemoteCoordinator(isHost: false, store: phoneStore, signaling: phoneSignal, handshakeTimeoutNanoseconds: handshakeTimeoutNanoseconds)
        host.allowLegacyPrivateRoute = true; phone.allowLegacyPrivateRoute = true
        phone.localDisplayName = "Fixture iPhone"
        invitation = try host.createPair(server: "wss://offline.invalid/signal", name: "Mac")
        invitationCreated = true
        hostSignal.respond = { [weak self] in if $0.type == "signal" { self?.phoneQueue.append($0) } }
        phoneSignal.respond = { [weak self] in if $0.type == "signal" { self?.hostQueue.append($0) } }
        host.start(); hostSignal.deliver(RelayMessage(type: "registered", role: "host"))
    }
    func begin() throws {
        try beginRequestOnly()
        pump()
    }
    func beginRequestOnly() throws {
        try phone.enroll(invitation.code())
        phoneSignal.deliver(RelayMessage(type: "peer", online: true))
        hostSignal.deliver(hostQueue.removeFirst()) // Withhold challenge/proof to exercise handshake timeout.
    }
    func pump() {
        for _ in 0..<32 {
            if !hostQueue.isEmpty { hostSignal.deliver(hostQueue.removeFirst()) }
            else if !phoneQueue.isEmpty { phoneSignal.deliver(phoneQueue.removeFirst()) }
            else { return }
        }
        XCTFail("Enrollment signaling did not settle")
    }
    /// Connect awaits the codec capability snapshot (PocketDeskAsyncCapabilitySnapshot) before media
    /// exists; keep pumping while that readiness task runs. Bounded; returns whether `condition` held.
    func settle(_ description: String, seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
            pump()
        }
        return condition()
    }
    func stop() { host.stop(); phone.stop(); _ = NativeVideoCapabilityProbes.installForTesting(previousProbes) }
    deinit { _ = NativeVideoCapabilityProbes.installForTesting(previousProbes) } // never leak the override into later test classes
}

@MainActor
final class ComparisonEnrollmentCoordinatorTests: XCTestCase {
    func testCodeAppearsBeforeExistingAllowAndQRHolderCannotDecryptPublishedTrust() throws {
        let rig = try ComparisonEnrollmentRig(); defer { rig.stop() }
        try rig.begin()
        XCTAssertTrue(rig.host.awaitingApproval)
        XCTAssertEqual(rig.host.pendingPairingPhoneName, "Fixture iPhone")
        XCTAssertNotNil(rig.host.pairingComparisonCode)
        XCTAssertEqual(rig.phone.pairingComparisonCode, rig.host.pairingComparisonCode)
        XCTAssertNil(rig.phoneStore.data, "Scanning and matching code never saves trust before Mac approval")
        XCTAssertNil(rig.host.media); XCTAssertNil(rig.phone.media)
        let count = rig.hostSignal.sent.count
        rig.host.approve()
        let accepted = try XCTUnwrap(rig.hostSignal.sent.dropFirst(count).first { $0.type == "signal" })
        let exposedQR = try SignalCipher(key: rig.invitation.key, room: rig.invitation.room)
        XCTAssertThrowsError(try exposedQR.open(try XCTUnwrap(accepted.payload), sender: "host"))
        rig.pump()
        let savedHost = try XCTUnwrap(rig.hostStore.read(HostPair.self))
        let savedPhone = try XCTUnwrap(rig.phoneStore.read(PairInvitation.self))
        XCTAssertTrue(savedHost.paired); XCTAssertEqual(savedHost.invitation, savedPhone)
        XCTAssertEqual(savedPhone.version, 1, "Saved peers keep the existing reconnect protocol")
        XCTAssertNotEqual(savedPhone.key, rig.invitation.key)
        XCTAssertNil(rig.host.pairingComparisonCode); XCTAssertNil(rig.phone.pairingComparisonCode)
        XCTAssertFalse(rig.phone.enrollmentPending)
    }
    func testFirst60ApprovalPersistsTrustAndWaitsWithoutMediaThenResumes() async throws {
        let rig = try ComparisonEnrollmentRig(handshakeTimeoutNanoseconds: 30_000_000)
        defer { rig.stop() }
        var ready = false
        var open = true
        rig.host.shareBlocker = { ready ? nil : .screenRecordingOff }
        rig.host.first60SetupStatus = {
            .init(open: open, permission: ready ? nil : .init(stage: .screenRecording), mediaReady: ready)
        }
        try rig.begin()
        XCTAssertNil(rig.phone.permissionWait, "No setup status or authority before explicit Mac Allow")
        XCTAssertNil(rig.phoneStore.data)
        rig.host.approve(); rig.pump()
        XCTAssertNotNil(rig.phoneStore.data, "Trust survives an OS-required host restart")
        XCTAssertEqual(rig.phone.permissionWait?.stage, .screenRecording)
        XCTAssertEqual(rig.phone.setupInProgress, true)
        XCTAssertNil(rig.host.media); XCTAssertNil(rig.phone.media)
        XCTAssertFalse(rig.host.mediaPreparationPending, "No media preparation may start before the Mac's permission wait ends")
        // The ordinary media/handshake deadline cannot race a human permission wait.
        try await Task.sleep(nanoseconds: 90_000_000)
        for _ in 0..<3 { rig.host.refreshFirst60SetupStatus(); rig.pump() }
        XCTAssertTrue(rig.phone.isRunning); XCTAssertTrue(rig.host.isRunning)
        XCTAssertNil(rig.host.media); XCTAssertNil(rig.phone.media)
        XCTAssertFalse(rig.host.mediaPreparationPending)
        ready = true
        rig.host.refreshFirst60SetupStatus(); rig.pump()
        XCTAssertNil(rig.phone.permissionWait)
        let mediaReady = await rig.settle("media after readiness") { rig.host.media != nil && rig.phone.media != nil }
        XCTAssertTrue(mediaReady, "both peers create media once the Mac's permission wait ends")
        XCTAssertEqual(rig.phone.setupInProgress, true, "Picture readiness does not finish the Done exercise")
        open = false
        rig.host.refreshFirst60SetupStatus(); rig.pump()
        XCTAssertEqual(rig.phone.setupInProgress, false)
    }

    func testFirst60PermissionWaitEndsOnRevocation() throws {
        let rig = try ComparisonEnrollmentRig(); defer { rig.stop() }
        rig.host.shareBlocker = { .screenRecordingOff }
        rig.host.first60SetupStatus = { .init(open: true, permission: .init(stage: .screenRecording), mediaReady: false) }
        try rig.begin(); rig.host.approve(); rig.pump()
        XCTAssertEqual(rig.phone.permissionWait?.stage, .screenRecording)
        _ = rig.host.revoke()
        XCTAssertNil(rig.host.permissionWait)
        XCTAssertNil(rig.host.media); XCTAssertFalse(rig.host.mediaPreparationPending)
        rig.host.refreshFirst60SetupStatus()
        XCTAssertNil(rig.host.media, "A stale grant after revoke cannot start a peer")
        XCTAssertFalse(rig.host.mediaPreparationPending, "nor schedule one")
    }

    func testNewPhoneAndOldHostDoNotWaitForAnUnsupportedSetupMessage() async throws {
        let rig = try ComparisonEnrollmentRig(); defer { rig.stop() }
        try rig.begin(); rig.host.approve(); rig.pump()
        XCTAssertNil(rig.phone.setupInProgress)
        XCTAssertNil(rig.phone.permissionWait)
        let phoneMedia = await rig.settle("phone media") { rig.phone.media != nil }
        XCTAssertTrue(phoneMedia)
    }

    func testEarlyAllowAndReplayedCompetingRequestCannotReplaceTheDisplayedCandidate() throws {
        let rig = try ComparisonEnrollmentRig(); defer { rig.stop() }
        try rig.begin()
        let code = rig.host.pairingComparisonCode
        let request = try XCTUnwrap(rig.phoneSignal.sent.first { $0.type == "signal" })
        rig.hostSignal.deliver(request)
        XCTAssertTrue(rig.host.awaitingApproval); XCTAssertEqual(rig.host.pairingComparisonCode, code)
        XCTAssertNil(rig.phoneStore.data)
        let fresh = try ComparisonEnrollmentRig(); defer { fresh.stop() }
        fresh.host.approve()
        XCTAssertTrue(fresh.host.isRunning, "Allow without a candidate preserves the registered listener")
        XCTAssertTrue(fresh.host.hostRegistered)
        XCTAssertFalse(fresh.host.awaitingApproval)
        XCTAssertNil(fresh.host.pairingComparisonCode)
        XCTAssertNil(fresh.host.media)
        XCTAssertNil(fresh.phoneStore.data)
        XCTAssertFalse(try XCTUnwrap(fresh.hostStore.read(HostPair.self)).paired)
    }
    func testDeclineRetiresTheQRAndBothCodesWithoutSavingPhoneTrust() throws {
        let rig = try ComparisonEnrollmentRig(); defer { rig.stop() }
        try rig.begin(); rig.host.reject(); rig.pump()
        XCTAssertNil(rig.host.pairingComparisonCode); XCTAssertNil(rig.phone.pairingComparisonCode)
        XCTAssertNil(rig.phoneStore.data)
        XCTAssertFalse(rig.phone.isRunning)
        XCTAssertLessThan(try XCTUnwrap(rig.hostStore.read(HostPair.self)).invitation.expires, Date())
        rig.host.start()
        XCTAssertFalse(rig.host.isRunning, "The declined QR cannot start a replacement candidate")
    }
    func testExpiryAtTheExistingAllowActionDeniesApprovalAndSavesNoPhoneTrust() throws {
        let rig = try ComparisonEnrollmentRig(); defer { rig.stop() }
        try rig.begin()
        XCTAssertTrue(rig.host.awaitingApproval)
        var expired = try XCTUnwrap(rig.hostStore.read(HostPair.self))
        expired.invitation.expires = .distantPast
        try rig.hostStore.save(expired)
        rig.host.restore() // Inject the authoritative expired record without waiting for a wall clock.
        rig.host.approve()
        XCTAssertFalse(rig.host.isRunning); XCTAssertFalse(rig.host.awaitingApproval)
        XCTAssertNil(rig.host.pairingComparisonCode); XCTAssertNil(rig.host.media)
        XCTAssertNil(rig.phoneStore.data)
        XCTAssertFalse(try XCTUnwrap(rig.hostStore.read(HostPair.self)).paired)
    }
    func testIncompleteHandshakeTimeoutRetiresTheInvitationAndAllEphemeralState() async throws {
        let rig = try ComparisonEnrollmentRig(handshakeTimeoutNanoseconds: 0); defer { rig.stop() }
        let timeout = expectation(description: "Unfinished committed handshake expires")
        let observer = rig.host.$status.sink { status in
            if status == "Pairing was interrupted. Create a fresh code." { timeout.fulfill() }
        }
        defer { observer.cancel() }
        try rig.beginRequestOnly()
        await fulfillment(of: [timeout], timeout: 2)
        XCTAssertFalse(rig.host.isRunning); XCTAssertFalse(rig.host.awaitingApproval)
        XCTAssertNil(rig.host.pairingComparisonCode); XCTAssertNil(rig.host.media)
        XCTAssertNil(rig.phoneStore.data)
        let saved = try XCTUnwrap(rig.hostStore.read(HostPair.self))
        XCTAssertFalse(saved.paired); XCTAssertLessThan(saved.invitation.expires, Date())
        rig.host.approve()
        XCTAssertFalse(try XCTUnwrap(rig.hostStore.read(HostPair.self)).paired)
    }
    func testTransportLossRetiresPendingCodesAndNeverRetriesEnrollmentAsSavedTrust() throws {
        let rig = try ComparisonEnrollmentRig(); defer { rig.stop() }
        try rig.begin()
        rig.phone.simulateTransportLossForTesting()
        rig.hostSignal.deliver(RelayMessage(type: "peer", online: false))
        XCTAssertFalse(rig.phone.isRunning); XCTAssertFalse(rig.phone.reconnecting)
        XCTAssertNil(rig.phone.invitation); XCTAssertNil(rig.phone.pairingComparisonCode)
        XCTAssertNil(rig.phoneStore.data); XCTAssertNil(rig.phone.media)
        XCTAssertFalse(rig.host.isRunning); XCTAssertNil(rig.host.pairingComparisonCode)
        let saved = try XCTUnwrap(rig.hostStore.read(HostPair.self))
        XCTAssertFalse(saved.paired); XCTAssertLessThan(saved.invitation.expires, Date())
    }
    func testHostTransportLossRetiresQRBeforeRetryAndCannotApproveTheOldCandidate() throws {
        let rig = try ComparisonEnrollmentRig(); defer { rig.stop() }
        try rig.begin()
        rig.host.simulateTransportLossForTesting()
        XCTAssertFalse(rig.host.isRunning); XCTAssertFalse(rig.host.reconnecting)
        XCTAssertFalse(rig.host.awaitingApproval); XCTAssertNil(rig.host.pairingComparisonCode)
        XCTAssertNil(rig.phoneStore.data); XCTAssertNil(rig.host.media)
        let retired = try XCTUnwrap(rig.hostStore.read(HostPair.self))
        XCTAssertFalse(retired.paired); XCTAssertLessThan(retired.invitation.expires, Date())
        rig.host.approve()
        XCTAssertFalse(try XCTUnwrap(rig.hostStore.read(HostPair.self)).paired)
    }
    func testLegacyPhoneHandshakeCannotBypassNewHostComparisonOrPublishTrust() throws {
        let rig = try ComparisonEnrollmentRig(); defer { rig.stop() }
        let cipher = try SignalCipher(key: rig.invitation.key, room: rig.invitation.room)
        let legacy = ProtectedMessage(kind: "request", request: try SecureRandom.token(), session: "", sequence: 0,
            body: try PairEnrollment.encoded(MacShareBlocker.Handshake.phone))
        rig.hostSignal.deliver(RelayMessage(type: "signal", payload: try cipher.seal(legacy, sender: "client")))
        XCTAssertFalse(rig.host.awaitingApproval); XCTAssertNil(rig.host.pairingComparisonCode)
        XCTAssertNil(rig.phoneStore.data); XCTAssertNil(rig.host.media)
        XCTAssertFalse(rig.host.isRunning)
        XCTAssertFalse(try XCTUnwrap(rig.hostStore.read(HostPair.self)).paired)
        XCTAssertTrue(rig.hostSignal.sent.filter { $0.type == "signal" }.isEmpty, "No legacy challenge or accepted trust is published")
    }
    /// A protocol peer with its own ephemeral private key completes a real phone's commit/reveal,
    /// then uses the DERIVED cipher. This tests acceptance bindings beyond merely failing QR decryption.
    private func authenticatedPhone() throws -> (RemoteCoordinator, MemoryPairStore, ScriptedSignaling, SignalCipher, ProtectedMessage, PairInvitation) {
        let store = MemoryPairStore(), signal = ScriptedSignaling()
        let phone = RemoteCoordinator(isHost: false, store: store, signaling: signal)
        phone.allowLegacyPrivateRoute = true
        let invitation = try HostPair.create(server: "wss://offline.invalid/signal", name: "Mac").invitation
        try phone.enroll(invitation.code())
        signal.deliver(RelayMessage(type: "peer", online: true))
        let qr = try SignalCipher(key: invitation.key, room: invitation.room)
        let requestMessage = try qr.open(try XCTUnwrap(signal.sent.last?.payload), sender: "client")
        // Decode the actual new phone request through the old host's shapes, then re-encode
        // exactly the legacy request used in its commitment and key transcript.
        struct LegacyHandshake: Codable { let features: [String]; let mode: String?; let options: [String]? }
        struct LegacyRequest: Codable { let version: Int; let commitment: Data; let handshake: LegacyHandshake; let phoneName: String? }
        let actualRequest = try PairEnrollment.decode(PairEnrollment.Request.self, body: requestMessage.body)
        XCTAssertNil(actualRequest.handshake.first60)
        XCTAssertNil(actualRequest.handshake.shortcutChips, "Opt-in must stay outside the legacy crypto transcript")
        XCTAssertNil(actualRequest.handshake.phoneLoadWindows, "Window opt-in must also stay outside the typed legacy transcript")
        XCTAssertNil(actualRequest.handshake.keysOnDemand, "Keys-on-demand opt-in must also stay outside the typed legacy transcript")
        let legacy = try PairEnrollment.decode(LegacyRequest.self, body: requestMessage.body)
        let request = try PairEnrollment.decode(PairEnrollment.Request.self, body: PairEnrollment.encoded(legacy))
        XCTAssertEqual(try PairEnrollment.encoded(request), try PairEnrollment.encoded(actualRequest),
                       "The sender's v2 transcript must survive the old host's decode/encode")
        let ephemeral = try PairEnrollment.Ephemeral(), session = try SecureRandom.token()
        let challenge = PairEnrollment.Challenge(reveal: ephemeral.reveal)
        signal.deliver(RelayMessage(type: "signal", payload: try qr.seal(ProtectedMessage(kind: "enrollmentChallenge",
            request: requestMessage.request, session: session, sequence: 0, body: try PairEnrollment.encoded(challenge)), sender: "host")))
        let proofMessage = try qr.open(try XCTUnwrap(signal.sent.last?.payload), sender: "client")
        struct LegacyProof: Codable { let reveal: PairEnrollment.Reveal; let confirmation: Data }
        let actualProof = try PairEnrollment.decode(PairEnrollment.Proof.self, body: proofMessage.body)
        XCTAssertEqual(actualProof.first60, true)
        XCTAssertEqual(actualProof.shortcutChips, ShortcutChips.isEnabled() ? true : nil)
        XCTAssertEqual(actualProof.phoneLoadWindows, true)
        let proof = try PairEnrollment.decode(LegacyProof.self, body: proofMessage.body)
        let keys = try PairEnrollment.derive(invitation: invitation, requestID: requestMessage.request, sessionID: session,
            request: request, challenge: challenge, phone: proof.reveal, ephemeral: ephemeral, isHost: true)
        XCTAssertTrue(keys.confirms(proof.confirmation, role: "phone"))
        let derived = try SignalCipher(key: keys.sessionKey, room: invitation.room)
        signal.deliver(RelayMessage(type: "signal", payload: try derived.seal(ProtectedMessage(kind: "enrollmentReady",
            request: requestMessage.request, session: session, sequence: 0, body: keys.confirmation(role: "host")), sender: "host")))
        XCTAssertEqual(phone.pairingComparisonCode, keys.comparisonCode,
                       "The actual new sender and the legacy host derive identical comparison and session keys")
        var saved = invitation; saved.version = 1; saved.key = keys.trustKey; saved.token = keys.trustToken; saved.expires = .distantFuture
        let accepted = ProtectedMessage(kind: "accepted", request: requestMessage.request, session: session, sequence: 1, body: nil)
        return (phone, store, signal, derived, accepted, saved)
    }

    func testPhoneLoadWindowOptInComesOnlyFromTheConfirmedEnrollmentProof() throws {
        let rig = try ComparisonEnrollmentRig(); defer { rig.stop() }
        try rig.beginRequestOnly()
        XCTAssertFalse(rig.host.phoneLoadWindowsRequested)
        rig.pump()
        XCTAssertTrue(rig.host.phoneLoadWindowsRequested)
        rig.stop()
        XCTAssertFalse(rig.host.phoneLoadWindowsRequested)
    }

    func testNewEnrollmentNegotiatesShortcutIdentityOnlyAfterConfirmedProof() throws {
        let rig = try ComparisonEnrollmentRig(); defer { rig.stop() }
        try rig.beginRequestOnly()
        XCTAssertFalse(rig.host.peerFeatures.contains(SessionFeature.shortcutChips))
        rig.pump()
        XCTAssertEqual(rig.host.peerFeatures.contains(SessionFeature.shortcutChips), ShortcutChips.isEnabled())
        XCTAssertTrue(rig.host.awaitingApproval, "Opt-in grants no pairing or control authority")
        XCTAssertNil(rig.host.media)
    }

    func testActualNewPhoneEmitterEnrollsWithLegacyHostWithoutSetupCapabilityAck() async throws {
        let (phone, store, signal, derived, template, legitimate) = try authenticatedPhone()
        defer { phone.stop() }
        var accepted = template
        accepted.body = try PairEnrollment.encoded(legitimate)
        signal.deliver(RelayMessage(type: "signal", payload: try derived.seal(accepted, sender: "host")))
        XCTAssertEqual(try store.read(PairInvitation.self), legitimate)
        XCTAssertNil(phone.setupInProgress)
        XCTAssertNil(phone.permissionWait)
        let deadline = ContinuousClock.now + .seconds(5)
        while phone.media == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNotNil(phone.media, "An older host sends no setup extension; the new phone continues ordinary media admission")
    }

    func testForgedAcceptedRejectsWrongTrustAndEveryOwnerIdentityBindingWithoutSaving() throws {
        for mutation in 0..<8 {
            let (phone, store, signal, derived, template, legitimate) = try authenticatedPhone()
            defer { phone.stop() }
            var changed = legitimate
            switch mutation {
            case 0: changed.key = try SecureRandom.bytes()
            case 1: changed.token = try SecureRandom.token()
            case 2: changed.room = try SecureRandom.token()
            case 3: changed.server = "wss://other.invalid/signal"
            case 4: changed.durableHostID = try SecureRandom.token()
            case 5: changed.ownerPairID = try SecureRandom.token()
            case 6: changed.localServiceName = "another-mac"
            default: changed.version = PairEnrollment.version
            }
            var accepted = template; accepted.body = try PairEnrollment.encoded(changed)
            signal.deliver(RelayMessage(type: "signal", payload: try derived.seal(accepted, sender: "host")))
            XCTAssertNil(store.data, "Forged binding \(mutation) must never become saved trust")
            XCTAssertFalse(phone.isRunning); XCTAssertNil(phone.pairingComparisonCode); XCTAssertNil(phone.media)
        }
    }
    func testAcceptanceSealedOnlyWithQRSecretAndReplayedSessionCannotSaveTrust() throws {
        let (phone, store, signal, derived, template, legitimate) = try authenticatedPhone(); defer { phone.stop() }
        let invitation = try XCTUnwrap(phone.invitation)
        var accepted = template; accepted.body = try PairEnrollment.encoded(legitimate)
        let qr = try SignalCipher(key: invitation.key, room: invitation.room)
        signal.deliver(RelayMessage(type: "signal", payload: try qr.seal(accepted, sender: "host")))
        XCTAssertNil(store.data); XCTAssertTrue(phone.isRunning); XCTAssertNotNil(phone.pairingComparisonCode)
        accepted.session = try SecureRandom.token()
        signal.deliver(RelayMessage(type: "signal", payload: try derived.seal(accepted, sender: "host")))
        XCTAssertNil(store.data); XCTAssertTrue(phone.isRunning); XCTAssertNotNil(phone.pairingComparisonCode)
        XCTAssertNil(phone.media)
    }
    func testNewPhoneRejectsOldEnrollmentButRestoresExistingSavedTrust() throws {
        let store = MemoryPairStore(), signaling = ScriptedSignaling()
        let saved = try HostPair.create(server: "wss://offline.invalid/signal", name: "Mac").rotated().invitation
        try store.save(saved)
        let phone = RemoteCoordinator(isHost: false, store: store, signaling: signaling); defer { phone.stop() }
        phone.restore()
        var oldQR = saved; oldQR.expires = Date().addingTimeInterval(120)
        XCTAssertThrowsError(try phone.enroll(oldQR.code())) { error in
            XCTAssertEqual((error as? RemoteError)?.localizedDescription, RemoteError.pairingUpgradeRequired.localizedDescription)
        }
        XCTAssertEqual(phone.invitation, saved)
        phone.start()
        XCTAssertTrue(phone.isRunning); XCTAssertEqual(signaling.connects.last?.invitation, saved)
    }
}
