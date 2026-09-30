import XCTest
import CoreVideo
import WebRTC
import CryptoKit

private final class GuestLoopbackReceiver: NSObject, RTCPeerConnectionDelegate, RTCVideoRenderer, @unchecked Sendable {
    var connection: RTCPeerConnection!
    var candidate: ((RTCIceCandidate) -> Void)?
    private let lock = NSLock()
    private var frames = 0
    private var connected = false
    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }
    private var size = CGSize.zero
    var track: RTCVideoTrack?
    var received: (Int, CGSize) { lock.lock(); defer { lock.unlock() }; return (frames, size) }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) { guard let frame else { return }; lock.lock(); frames += 1; size = CGSize(width: Int(frame.width), height: Int(frame.height)); lock.unlock() }
    func peerConnection(_ p: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ p: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        XCTAssertTrue(stream.audioTracks.isEmpty)
        if let track = stream.videoTracks.first { self.track = track; track.add(self) }
    }
    func peerConnection(_ p: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ p: RTCPeerConnection) {}
    func peerConnection(_ p: RTCPeerConnection, didChange newState: RTCIceConnectionState) { lock.lock(); connected = newState == .connected || newState == .completed; lock.unlock() }
    func peerConnection(_ p: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ p: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) { if E2EMedia.allows(candidate: candidate.sdp) { self.candidate?(candidate) } }
    func peerConnection(_ p: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ p: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { XCTFail("Guest has no data channels"); dataChannel.close() }
}

final class GuestMediaTransportTests: XCTestCase {
    @MainActor
    func testActualGuestPeerSendsVideoOverPublicLoopbackRTPAndTerminalRevokeStopsSubmissions() async throws {
        RTCInitializeSSL()
        let old = E2EMedia.loopbackOnly; E2EMedia.loopbackOnly = true; defer { E2EMedia.loopbackOnly = old }
        let lease = GuestCaptureLease(grantID: String(repeating: "a", count: 64), ownerSessionID: String(repeating: "b", count: 64), scopeEpoch: "1", geometryEpoch: "1", expiresAt: ProcessInfo.processInfo.systemUptime + 40)
        let guest = GuestMediaPeer(servers: [], lease: lease)
        let receiver = GuestLoopbackReceiver()
        let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
        E2EMedia.restrictToLoopbackIfNeeded(factory)
        let config = RTCConfiguration(); config.sdpSemantics = .unifiedPlan
        receiver.connection = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: receiver)
        defer { guest.close(); receiver.track?.remove(receiver); receiver.connection.close() }
        var remoteReady = false, queued: [RTCIceCandidate] = [], answered = false
        receiver.candidate = { candidate in DispatchQueue.main.async { guest.receive(MediaSignal(kind: "candidate", candidate: candidate.sdp, mid: candidate.sdpMid, line: candidate.sdpMLineIndex)) } }
        guest.onEnded = { XCTFail("Video-only guest unexpectedly terminated") }
        guest.onSignal = { signal in
            if signal.kind == "candidate", let text = signal.candidate, let line = signal.line {
                let candidate = RTCIceCandidate(sdp: text, sdpMLineIndex: line, sdpMid: signal.mid)
                if remoteReady { receiver.connection.add(candidate) { _ in } } else { queued.append(candidate) }
            } else if signal.kind == "offer", let sdp = signal.sdp {
                XCTAssertFalse(sdp.lowercased().contains("flexfec-03")); XCTAssertFalse(sdp.contains("m=audio")); XCTAssertFalse(sdp.contains("m=application")); XCTAssertTrue(sdp.contains("a=sendonly"))
                receiver.connection.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { error in
                    XCTAssertNil(error)
                    receiver.connection.answer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "false"], optionalConstraints: nil)) { answer, error in
                        XCTAssertNil(error); guard let answer else { return }
                        XCTAssertFalse(answer.sdp.contains("m=audio")); XCTAssertTrue(answer.sdp.contains("a=recvonly"))
                        receiver.connection.setLocalDescription(answer) { error in
                            XCTAssertNil(error)
                            DispatchQueue.main.async {
                                if receiver.track == nil, let track = receiver.connection.receivers.compactMap({ $0.track as? RTCVideoTrack }).first {
                                    receiver.track = track; track.add(receiver)
                                }
                                remoteReady = true
                                for candidate in queued { receiver.connection.add(candidate) { _ in } }; queued.removeAll()
                                guest.receive(MediaSignal(kind: "answer", sdp: answer.sdp)); answered = true
                            }
                        }
                    }
                }
            }
        }
        guest.offer()
        let deadline = Date().addingTimeInterval(15)
        while !answered && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(answered)
        while !receiver.isConnected && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(receiver.isConnected)
        // Strictly zero media: actual ICE/DTLS connected path, lease still paused and no source frames.
        var cold: GuestTransportObservation?
        for _ in 0..<4 {
            guest.sampleTransport { cold = $0 }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertEqual(receiver.received.0, 0)
        let sample = try XCTUnwrap(cold)
        XCTAssertNotNil(sample.totalKbps, "Selected transport cumulative zero-media bytes need consecutive real samples")
        let admitted = GuestBudgetPolicy.boundedCeilingKbps(ownerCeiling: 1000, guest: sample, at: ProcessInfo.processInfo.systemUptime)
        print("GUEST COLD TRANSPORT: totalKbps=\(String(describing: sample.totalKbps)) capacityKbps=\(String(describing: sample.capacityKbps)) admitted=\(String(describing: admitted)) frames=\(receiver.received.0)")
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 1600, 900, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, []); for plane in 0..<2 { memset(CVPixelBufferGetBaseAddressOfPlane(frame, plane), plane == 0 ? 120 : 128, CVPixelBufferGetBytesPerRowOfPlane(frame, plane) * CVPixelBufferGetHeightOfPlane(frame, plane)) }; CVPixelBufferUnlockBaseAddress(frame, [])
        for _ in 0..<150 where receiver.received.0 < 3 {
            lease.permit(until: ProcessInfo.processInfo.systemUptime + 1)
            guest.pushFrame(frame, at: ProcessInfo.processInfo.systemUptime)
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        XCTAssertGreaterThanOrEqual(receiver.received.0, 3, "Actual fixture pixels decoded through native video RTP")
        XCTAssertLessThanOrEqual(max(receiver.received.1.width, receiver.received.1.height), 1280)
        guest.close(); XCTAssertFalse(lease.deliver { XCTFail("Terminal grant admitted old queued pixels") })
        lease.permit(until: ProcessInfo.processInfo.systemUptime + 1)
        guest.pushFrame(frame, at: ProcessInfo.processInfo.systemUptime)
        XCTAssertFalse(lease.deliver {})
    }
    @MainActor
    func testActualControllerAdmitsFirstFrameFromColdGuestStatsWithoutManualPermit() async throws {
        RTCInitializeSSL()
        let old = E2EMedia.loopbackOnly; E2EMedia.loopbackOnly = true; defer { E2EMedia.loopbackOnly = old }
        let controller = HostGuestController()
        let owner = PeerMedia(isHost: true, servers: [], nativeDesktopCodecs: false)
        controller.ownerPeer = { owner }
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        let context = HostGuestContext(room: a, hostID: b, origin: "https://fixture.invalid", ownerSessionID: a,
            scopeEpoch: "1", geometryEpoch: "2", scopeKind: "window", deadline: Date().addingTimeInterval(900))
        controller.context = { context }
        var outgoing: [GuestRelayFrame] = []
        controller.send = { outgoing.append($0); return true }
        controller.create(); let invite = try XCTUnwrap(outgoing.first), id = try XCTUnwrap(invite.grantID)
        controller.receive(GuestRelayFrame(operation: "created", grantID: id, expiresAt: invite.expiresAt))
        let signing = P256.Signing.PrivateKey(), agreement = P256.KeyAgreement.PrivateKey()
        let publicKey = signing.publicKey.x963Representation.base64EncodedString(), agreementKey = agreement.publicKey.x963Representation.base64EncodedString()
        controller.receive(GuestRelayFrame(operation: "pending", grantID: id, publicKey: publicKey, requestID: a,
            agreementKey: agreementKey, nonce: b, signature: try GuestCrypto.sign(["request", context.origin, a, id, publicKey, agreementKey, b], key: signing)))
        controller.approve(id)
        let grant = try XCTUnwrap(outgoing.last?.grant), session = GuestCrypto.hash(GuestCrypto.canonical(grant.signedFields))
        let key = try GuestCrypto.sharedKey(privateKey: agreement, publicKey: grant.hostAgreementKey, grant: grant)
        let receiver = GuestLoopbackReceiver(), factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
        E2EMedia.restrictToLoopbackIfNeeded(factory)
        let config = RTCConfiguration(); config.sdpSemantics = .unifiedPlan
        receiver.connection = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: receiver)
        defer { controller.endAll(); owner.close(); receiver.track?.remove(receiver); receiver.connection.close() }
        var sequence: UInt64 = 0, remoteReady = false, queued: [RTCIceCandidate] = []
        func sendToController(_ signal: MediaSignal) {
            do {
                sequence += 1
                let envelope = try GuestCrypto.seal(JSONEncoder().encode(signal), key: key, grantID: id, sessionID: session, direction: "guest", sequence: sequence)
                controller.receive(GuestRelayFrame(operation: "signal", grantID: id, sessionID: session, envelope: envelope))
            } catch { XCTFail("Actual recipient signaling seal failed: \(error)") }
        }
        receiver.candidate = { candidate in DispatchQueue.main.async { sendToController(MediaSignal(kind: "candidate", candidate: candidate.sdp, mid: candidate.sdpMid, line: candidate.sdpMLineIndex)) } }
        controller.send = { frame in
            outgoing.append(frame)
            if frame.operation == "check" {
                // Injected backend proof; real backend approval/proof/eviction is separately exercised by workerd.
                controller.receive(GuestRelayFrame(operation: "alive", grantID: id, expiresAt: grant.expiresAt, nonce: frame.nonce, sessionID: session))
            } else if frame.operation == "signal" {
                do {
                    let bytes = try GuestCrypto.open(try XCTUnwrap(frame.envelope), key: key, grantID: id, sessionID: session, direction: "host")
                    let signal = try JSONDecoder().decode(MediaSignal.self, from: bytes)
                    if signal.kind == "candidate", let text = signal.candidate, let line = signal.line {
                        let candidate = RTCIceCandidate(sdp: text, sdpMLineIndex: line, sdpMid: signal.mid)
                        if remoteReady { receiver.connection.add(candidate) { _ in } } else { queued.append(candidate) }
                    } else if signal.kind == "offer", let sdp = signal.sdp {
                        XCTAssertFalse(sdp.lowercased().contains("flexfec-03")); XCTAssertFalse(sdp.contains("m=audio")); XCTAssertFalse(sdp.contains("m=application"))
                        receiver.connection.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { error in
                            XCTAssertNil(error)
                            receiver.connection.answer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "false"], optionalConstraints: nil)) { answer, error in
                                XCTAssertNil(error); guard let answer else { return }
                                receiver.connection.setLocalDescription(answer) { error in
                                    XCTAssertNil(error)
                                    DispatchQueue.main.async {
                                        if let track = receiver.connection.receivers.compactMap({ $0.track as? RTCVideoTrack }).first { receiver.track = track; track.add(receiver) }
                                        remoteReady = true; for candidate in queued { receiver.connection.add(candidate) { _ in } }; queued.removeAll()
                                        sendToController(MediaSignal(kind: "answer", sdp: answer.sdp))
                                    }
                                }
                            }
                        }
                    }
                } catch { XCTFail("Actual owner signaling failed: \(error)") }
            }
            return true
        }
        controller.receive(GuestRelayFrame(operation: "ready", grantID: id, expiresAt: grant.expiresAt, sessionID: session,
            servers: [ICEServerConfiguration(urls: ["stun:127.0.0.1:9"])]))
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 256, 128, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, []); memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)); CVPixelBufferUnlockBaseAddress(buffer, [])
        let deadline = Date().addingTimeInterval(12)
        while receiver.received.0 < 3 && Date() < deadline {
            controller.refreshAuthority()
            // Inject only known owner residual/current noncongestion, never guest stats or media lease.
            owner.onGuestTransportStatistics?(GuestTransportObservation(at: ProcessInfo.processInfo.systemUptime, totalKbps: 1000,
                capacityKbps: 10000, rttMs: 1, baselineRTTMs: 1, pacerDelayMs: 0, controlBufferedBytes: 0))
            controller.fanout.deliver(buffer, at: ProcessInfo.processInfo.systemUptime)
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertGreaterThanOrEqual(receiver.received.0, 3, "Production controller must admit first frame from genuine cold guest transport stats; no test lease permit")
        XCTAssertEqual(controller.rows.count, 1)
        controller.endAll(); let before = receiver.received.0
        controller.fanout.deliver(buffer, at: ProcessInfo.processInfo.systemUptime)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertLessThanOrEqual(receiver.received.0, before + 2, "Only already queued RTP may finish after local revoke")
    }

}
