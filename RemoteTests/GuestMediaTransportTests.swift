import XCTest
import CoreVideo
import WebRTC

private final class GuestLoopbackReceiver: NSObject, RTCPeerConnectionDelegate, RTCVideoRenderer, @unchecked Sendable {
    var connection: RTCPeerConnection!
    var candidate: ((RTCIceCandidate) -> Void)?
    private let lock = NSLock()
    private var frames = 0
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
    func peerConnection(_ p: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
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
                XCTAssertFalse(sdp.contains("m=audio")); XCTAssertFalse(sdp.contains("m=application")); XCTAssertTrue(sdp.contains("a=sendonly"))
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
}
