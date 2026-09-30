import Foundation
import CoreVideo
import WebRTC

/// Separate, strictly video-only peer. No owner data channels/audio sources or owner media callbacks.
final class GuestMediaPeer: NSObject, @unchecked Sendable {
    let counters = StreamCounters()
    let lease: GuestCaptureLease
    var onSignal: ((MediaSignal) -> Void)? // main thread, root rechecks exact grant/session
    var onEnded: (() -> Void)?
    private var transportSampler = GuestTransportSampler()
    private var statisticsPending = false
    func sampleTransport(_ completion: @escaping (GuestTransportObservation) -> Void) {
        precondition(Thread.isMainThread)
        guard !statisticsPending, let connection = liveConnection() else { return }
        statisticsPending = true
        connection.statistics { [weak self] report in
            DispatchQueue.main.async {
                guard let self, self.liveConnection() === connection else { return }
                self.statisticsPending = false
                let entries = report.statistics.values.map { StreamStatsEntry(id: $0.id, type: $0.type, values: $0.values, timestamp: $0.timestamp_us / 1_000_000) }
                let sample = StreamStatsSample(entries: entries)
                let transport = entries.first { $0.type == "transport" && $0.string("selectedCandidatePairId") == sample.pair?.id }
                let rate = self.transportSampler.sample(identity: transport.flatMap { item in sample.pair.map { item.id + "/" + $0.id } },
                    timestamp: transport?.timestamp, bytesSent: transport?.number("bytesSent"), rttMs: nil)
                completion(GuestTransportObservation(at: ProcessInfo.processInfo.systemUptime, totalKbps: rate.kbps,
                    capacityKbps: sample.pair?.number("availableOutgoingBitrate").map { $0 / 1000 }, rttMs: nil, baselineRTTMs: nil, pacerDelayMs: nil, controlBufferedBytes: nil))
            }
        }
    }
    private let lock = NSLock()
    private var closed = false
    private var factory: RTCPeerConnectionFactory?
    private var connection: RTCPeerConnection?
    private var source: RTCVideoSource?
    private var capturer: RTCVideoCapturer?
    private var track: RTCVideoTrack?
    private var lastFrame: Double = -.infinity
    private var adaptedSize = CGSize.zero
    private var remoteReady = false // main only
    private var candidates: [RTCIceCandidate] = [] // main only
    private var ceiling: Double = GuestBudgetPolicy.maximumKbps

    init(servers: [ICEServerConfiguration], lease: GuestCaptureLease) {
        self.lease = lease
        super.init()
        let factory = RTCPeerConnectionFactory(encoderFactory: PocketDeskVideoEncoderFactory(counters: counters), decoderFactory: RTCDefaultVideoDecoderFactory())
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherOnce
        configuration.iceServers = servers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username ?? "", credential: $0.credential ?? "") }
        #if DEBUG
        E2EMedia.restrictToLoopbackIfNeeded(factory)
        #endif
        let source = factory.videoSource(forScreenCast: true), capturer = RTCVideoCapturer(delegate: source)
        let track = factory.videoTrack(with: source, trackId: "guest-video")
        let connection = factory.peerConnection(with: configuration, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        let transceiver = RTCRtpTransceiverInit(); transceiver.direction = .sendOnly
        _ = connection?.addTransceiver(with: track, init: transceiver)
        self.factory = factory; self.connection = connection; self.source = source; self.capturer = capturer; self.track = track
    }
    private func liveConnection() -> RTCPeerConnection? { lock.lock(); defer { lock.unlock() }; return closed ? nil : connection }
    func offer() {
        precondition(Thread.isMainThread)
        guard let connection = liveConnection() else { return }
        connection.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"], optionalConstraints: nil)) { [weak self] description, _ in
            guard let self, let description, !description.sdp.contains("m=audio"), !description.sdp.contains("m=application") else { self?.endFromCallback(); return }
            connection.setLocalDescription(description) { [weak self] error in
                guard let self, error == nil else { self?.endFromCallback(); return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.liveConnection() === connection else { return }
                    self.applyCeiling(); self.onSignal?(MediaSignal(kind: "offer", sdp: description.sdp))
                }
            }
        }
    }
    func receive(_ signal: MediaSignal) {
        precondition(Thread.isMainThread)
        guard let connection = liveConnection() else { return }
        if signal.kind == "candidate", let text = signal.candidate, text.utf8.count <= 8192,
           let line = signal.line, line >= 0, line <= 16, (signal.mid?.utf8.count ?? 0) <= 32 {
            let candidate = RTCIceCandidate(sdp: text, sdpMLineIndex: line, sdpMid: signal.mid)
            if remoteReady { connection.add(candidate) { [weak self] error in if error != nil { self?.endFromCallback() } } }
            else if candidates.count < 64 { candidates.append(candidate) }
            else { endFromCallback() }
            return
        }
        guard signal.kind == "answer", !remoteReady, let sdp = signal.sdp, sdp.utf8.count <= 96 * 1024,
              !sdp.contains("m=audio"), !sdp.contains("m=application"), sdp.components(separatedBy: "m=video").count == 2,
              sdp.contains("a=recvonly"), sdp.contains("a=fingerprint:") else { endFromCallback(); return }
        connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.liveConnection() === connection else { return }
                guard error == nil else { self.endFromCallback(); return }
                self.remoteReady = true
                for candidate in self.candidates { connection.add(candidate) { [weak self] error in if error != nil { self?.endFromCallback() } } }
                self.candidates.removeAll(); self.applyCeiling()
            }
        }
    }
    func setCeiling(kbps: Double) {
        precondition(Thread.isMainThread)
        guard kbps.isFinite, kbps >= 128 else { lease.pause(); return }
        ceiling = min(GuestBudgetPolicy.maximumKbps, kbps); applyCeiling()
    }
    private func applyCeiling() {
        guard let sender = liveConnection()?.senders.first(where: { $0.track?.kind == "video" }) else { return }
        let parameters = sender.parameters
        for encoding in parameters.encodings { encoding.maxBitrateBps = NSNumber(value: Int(ceiling * 1000)); encoding.maxFramerate = NSNumber(value: GuestBudgetPolicy.maximumFPS) }
        parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
        sender.parameters = parameters
    }
    /// Capture queue. Never wait on a slow guest; terminal lease still synchronizes revoke with submission.
    func pushFrame(_ buffer: CVPixelBuffer, at now: Double) {
        lease.deliver {
            guard lock.try() else { return }; defer { lock.unlock() }
            guard !closed, now.isFinite, now - lastFrame >= 1 / Double(GuestBudgetPolicy.maximumFPS), let source, let capturer else { return }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            guard width > 0, height > 0 else { return }
            let ratio = min(1, Double(GuestBudgetPolicy.maximumDimension) / Double(max(width, height)))
            let size = CGSize(width: max(2, Int(Double(width) * ratio) / 2 * 2), height: max(2, Int(Double(height) * ratio) / 2 * 2))
            if size != adaptedSize { source.adaptOutputFormat(toWidth: Int32(size.width), height: Int32(size.height), fps: Int32(GuestBudgetPolicy.maximumFPS)); adaptedSize = size }
            lastFrame = now
            source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: Int64(now * 1_000_000_000)))
        }
    }
    func close() {
        precondition(Thread.isMainThread)
        lease.close() // capture scope → lease → peer ordering, no peer-lock → lease nesting
        lock.lock(); closed = true
        let old = connection, oldTrack = track
        connection = nil; source = nil; capturer = nil; track = nil; factory = nil
        lock.unlock()
        oldTrack?.isEnabled = false; old?.delegate = nil; old?.close()
        candidates.removeAll(); onSignal = nil; onEnded = nil
    }
    private func endFromCallback() {
        DispatchQueue.main.async { [weak self] in guard let self, self.liveConnection() != nil else { return }; let callback = self.onEnded; self.close(); callback?() }
    }
}

extension GuestMediaPeer: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) { endFromCallback() }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if [.failed, .disconnected, .closed].contains(newState) { endFromCallback() }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        #if DEBUG
        guard E2EMedia.allows(candidate: candidate.sdp) else { return }
        #endif
        DispatchQueue.main.async { [weak self] in
            guard let self, self.liveConnection() === peerConnection else { return }
            self.onSignal?(MediaSignal(kind: "candidate", candidate: candidate.sdp, mid: candidate.sdpMid, line: candidate.sdpMLineIndex))
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { dataChannel.close(); endFromCallback() }
}
