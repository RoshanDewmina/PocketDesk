import Foundation
import CoreVideo
import WebRTC

struct ICEServerConfiguration: Codable {
    var urls: [String]
    var username: String?
    var credential: String?
}
struct MediaSignal: Codable {
    var kind: String
    var sdp: String?
    var candidate: String?
    var mid: String?
    var line: Int32?
}

enum NativeRelayPolicy {
    enum Decision: Equatable {
        case proceed(forceRelay: Bool)
        case relayRequiredUnavailable(serverRequired: Bool)
    }

    static func isValid(_ policy: String?) -> Bool {
        policy == nil || policy == "all" || policy == "relay"
    }

    static func hasRelay(_ servers: [ICEServerConfiguration]) -> Bool {
        servers.contains { $0.urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") } }
    }

    static func decide(servers: [ICEServerConfiguration], policy: String?, localForce: Bool) -> Decision {
        let serverRequires = policy == "relay"
        guard serverRequires || localForce else { return .proceed(forceRelay: false) }
        return hasRelay(servers) ? .proceed(forceRelay: true) : .relayRequiredUnavailable(serverRequired: serverRequires)
    }
}

enum MediaRoute {
    static func classify(selected: Bool, local: String?, remote: String?) -> String {
        guard selected else { return "Route pending" }
        if local == "relay" || remote == "relay" { return "Relay" }
        let directTypes: Set<String> = ["host", "srflx", "prflx"]
        guard let local, let remote, directTypes.contains(local), directTypes.contains(remote) else {
            return "Route pending"
        }
        return "Direct"
    }
}

final class PeerMedia: NSObject {
    var onSignal: ((MediaSignal) -> Void)?
    var onRemoteVideo: ((RTCVideoTrack) -> Void)?
    var onControl: ((Data) -> Void)?
    var onState: ((String) -> Void)?
    var onDiagnostics: ((String) -> Void)?
    var onStreamStatistics: ((StreamStatsReport) -> Void)?
    var onSenderStatistics: ((StreamStatsReport) -> Void)?
    let counters = StreamCounters()
    var captureMaximumDimension: Int?
    private let isHost: Bool
    private let nativeDesktopCodecs: Bool
    private var previousSample: StreamStatsSample?
    private var cadenceRenderer: StreamCadenceRenderer?
    private var observedTrack: RTCVideoTrack?
    private var statisticsTimer: Timer?
    private var statisticsPending = false
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: PocketDeskVideoEncoderFactory(),
                                        decoderFactory: PocketDeskVideoDecoderFactory())
    }()
    private static let compatibleFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        if let h264 = encoder.supportedCodecs().first(where: { $0.name == "H264" }) { encoder.preferredCodec = h264 }
        return RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
    private var connection: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var source: RTCVideoSource?
    private var capturer: RTCVideoCapturer?
    private var video: RTCVideoTrack?
    private var remoteDescriptionReady = false
    private var candidates: [RTCIceCandidate] = []
    private let captureLock = NSLock()
    private var receivingBudget: H264FrameBudget?
    private var adaptedSize: (Int, Int)?
    private var closed = false
    private var frameTransform: ((CVPixelBuffer, Int64) -> CVPixelBuffer?)?

    var nativeCaptureBudget: H264FrameBudget? {
        guard nativeDesktopCodecs else { return nil }
        captureLock.lock(); defer { captureLock.unlock() }
        return receivingBudget
    }

    func setFrameTransform(_ transform: ((CVPixelBuffer, Int64) -> CVPixelBuffer?)?) {
        captureLock.lock(); defer { captureLock.unlock() }; frameTransform = transform
    }

    init(isHost: Bool, servers: [ICEServerConfiguration], forceRelay: Bool = false, nativeDesktopCodecs: Bool = true) {
        self.isHost = isHost
        self.nativeDesktopCodecs = nativeDesktopCodecs
        super.init()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceTransportPolicy = forceRelay ? .relay : .all
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceServers = servers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username ?? "", credential: $0.credential ?? "") }
        let factory = nativeDesktopCodecs ? Self.factory : Self.compatibleFactory
        connection = factory.peerConnection(with: configuration, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        if isHost {
            let source = factory.videoSource(forScreenCast: true)
            self.source = source; capturer = RTCVideoCapturer(delegate: source)
            let track = factory.videoTrack(with: source, trackId: "desktop")
            video = track; connection?.add(track, streamIds: ["desktop"])
            let config = RTCDataChannelConfiguration(); config.isOrdered = true
            channel = connection?.dataChannel(forLabel: "control", configuration: config)
            channel?.delegate = self
        }
    }
    func offer() {
        connection?.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"], optionalConstraints: nil)) { [weak self] description, error in
            DispatchQueue.main.async { self?.setLocal(description, error: error) }
        }
    }
    private func setLocal(_ description: RTCSessionDescription?, error: Error?) {
        guard !closed, let description, error == nil else { onState?("failed"); return }
        connection?.setLocalDescription(description) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                guard error == nil else { self.onState?("failed"); return }
                self.onSignal?(MediaSignal(kind: description.type == .offer ? "offer" : "answer", sdp: description.sdp))
            }
        }
    }
    func receive(_ signal: MediaSignal) {
        guard !closed, let connection else { return }
        if signal.kind == "candidate" {
            guard let candidate = signal.candidate, candidate.utf8.count <= 8192, let line = signal.line, line >= 0, line < 16 else { onState?("failed"); return }
            let value = RTCIceCandidate(sdp: candidate, sdpMLineIndex: line, sdpMid: signal.mid)
            if remoteDescriptionReady { connection.add(value) { [weak self] error in if error != nil { DispatchQueue.main.async { self?.onState?("failed") } } } }
            else if candidates.count < 128 { candidates.append(value) }
            else { onState?("failed") }
            return
        }
        guard ["offer", "answer"].contains(signal.kind), let sdp = signal.sdp, sdp.utf8.count <= 96 * 1024,
              sdp.contains("a=fingerprint:sha-256 ") else { onState?("failed"); return }
        connection.setRemoteDescription(RTCSessionDescription(type: signal.kind == "offer" ? .offer : .answer, sdp: sdp)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.closed, error == nil else { self?.onState?("failed"); return }
                self.captureLock.lock()
                self.receivingBudget = H264FrameBudget.receivingLimit(sdp: sdp)
                self.adaptedSize = nil
                self.captureLock.unlock()
                self.remoteDescriptionReady = true
                self.configureNativeSender()
                for candidate in self.candidates { self.connection?.add(candidate, completionHandler: { _ in }) }
                self.candidates.removeAll()
                if signal.kind == "offer" {
                    self.connection?.answer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "true"], optionalConstraints: nil)) { [weak self] description, error in
                        DispatchQueue.main.async { self?.setLocal(description, error: error) }
                    }
                }
                if let track = self.connection?.receivers.compactMap({ $0.track as? RTCVideoTrack }).first {
                    self.observeRemoteVideo(track)
                    self.onRemoteVideo?(track)
                }
            }
        }
    }
    private func configureNativeSender() {
        guard isHost, nativeDesktopCodecs, let sender = connection?.senders.first(where: { $0.track?.kind == "video" }) else { return }
        let parameters = sender.parameters
        for encoding in parameters.encodings {
            encoding.maxFramerate = 60
            encoding.maxBitrateBps = 12_000_000
        }
        sender.parameters = parameters
    }

    func sendControl(_ data: Data) -> Bool {
        guard !closed, data.count <= 16384, let channel, channel.readyState == .open, channel.bufferedAmount < 64 * 1024 else { return false }
        let sent = channel.sendData(RTCDataBuffer(data: data, isBinary: true))
        counters.inputBuffered(channel.bufferedAmount)
        return sent
    }

    var controlBufferedAmount: UInt64? {
        guard !closed, let channel, channel.readyState == .open else { return nil }
        return channel.bufferedAmount
    }
    func pushFrame(_ buffer: CVPixelBuffer, timeStampNs: Int64) {
        guard captureLock.try() else { counters.pushSkipped(); return }
        defer { captureLock.unlock() }
        guard !closed, let source, let capturer else { return }
        let output: CVPixelBuffer
        if let frameTransform { guard let transformed = frameTransform(buffer, timeStampNs) else { return }; output = transformed }
        else { output = buffer }
        if nativeDesktopCodecs, let budget = receivingBudget {
            let fitted = budget.fitted(width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
            if adaptedSize?.0 != fitted.width || adaptedSize?.1 != fitted.height {
                source.adaptOutputFormat(toWidth: Int32(fitted.width), height: Int32(fitted.height), fps: 60)
                adaptedSize = (fitted.width, fitted.height)
            }
        }
        source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: output), rotation: ._0, timeStampNs: timeStampNs))
        counters.pushed()
    }
    func startDiagnostics() {
        guard statisticsTimer == nil else { return }
        statisticsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sampleStatistics() }
        sampleStatistics()
    }
    private func sampleStatistics() {
        guard !closed, !statisticsPending, let connection else { return }
        statisticsPending = true
        connection.statistics { [weak self] report in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                self.statisticsPending = false
                let stats = report.statistics
                let selectedID = stats.values.filter { $0.type == "transport" }.compactMap { $0.values["selectedCandidatePairId"] as? String }.first
                let pair = selectedID.flatMap { stats[$0] }
                let local = (pair?.values["localCandidateId"] as? String).flatMap { stats[$0] }
                let remote = (pair?.values["remoteCandidateId"] as? String).flatMap { stats[$0] }
                let localType = local?.values["candidateType"] as? String
                let remoteType = remote?.values["candidateType"] as? String
                let route = MediaRoute.classify(selected: pair != nil, local: localType, remote: remoteType)
                let rtp = stats.values.first { ($0.type == "inbound-rtp" || $0.type == "outbound-rtp") && ($0.values["kind"] as? String == "video" || $0.values["mediaType"] as? String == "video") }
                let codec = (rtp?.values["codecId"] as? String).flatMap { stats[$0]?.values["mimeType"] as? String } ?? "codec pending"
                let fps = (rtp?.values["framesPerSecond"] as? NSNumber).map { String(format: "%.0f fps", $0.doubleValue) } ?? "fps pending"
                let rtt = (pair?.values["currentRoundTripTime"] as? NSNumber).map { String(format: "%.0f ms network RTT", $0.doubleValue * 1000) } ?? "RTT pending"
                let implementation = (rtp?.values["encoderImplementation"] as? String) ?? (rtp?.values["decoderImplementation"] as? String) ?? "codec implementation unreported"
                self.onDiagnostics?("\(route) · \(codec) · \(fps) · \(rtt) · \(implementation)")
                self.publishStreamStatistics(report)
            }
        }
    }
    private func publishStreamStatistics(_ report: RTCStatisticsReport) {
        let entries = report.statistics.values.map {
            StreamStatsEntry(id: $0.id, type: $0.type, values: $0.values, timestamp: $0.timestamp_us / 1_000_000)
        }
        let sample = StreamStatsSample(entries: entries)
        let counts = counters.drain(inputBufferedBytes: controlBufferedAmount)
        var stats = StreamStatsReport(role: isHost ? "host" : "phone", previous: previousSample,
                                      current: sample, counters: previousSample == nil ? nil : counts)
        stats.captureMaximumDimension = captureMaximumDimension
        previousSample = sample
        StreamDebug.record(stats)
        onStreamStatistics?(stats)
        if isHost { onSenderStatistics?(stats) }
    }

    private func observeRemoteVideo(_ track: RTCVideoTrack) {
        guard cadenceRenderer == nil else { return }
        let renderer = StreamCadenceRenderer(counters: counters)
        cadenceRenderer = renderer
        observedTrack = track
        track.add(renderer)
    }

    func close() {
        statisticsTimer?.invalidate(); statisticsTimer = nil
        if let cadenceRenderer { observedTrack?.remove(cadenceRenderer) }
        cadenceRenderer = nil; observedTrack = nil
        captureLock.lock(); closed = true; source = nil; capturer = nil; frameTransform = nil; captureLock.unlock()
        channel?.delegate = nil; channel?.close(); channel = nil
        connection?.delegate = nil; connection?.close(); connection = nil
        candidates.removeAll(); video = nil
    }
}
extension PeerMedia: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first {
            DispatchQueue.main.async { [weak self] in self?.observeRemoteVideo(track); self?.onRemoteVideo?(track) }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if [.failed, .disconnected, .closed].contains(newState) {
            DispatchQueue.main.async { [weak self] in self?.onState?(newState == .failed ? "failed" : newState == .closed ? "closed" : "disconnected") }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.onSignal?(MediaSignal(kind: "candidate", candidate: candidate.sdp, mid: candidate.sdpMid, line: candidate.sdpMLineIndex))
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, dataChannel.label == "control", self.channel == nil else { dataChannel.close(); return }
            self.channel = dataChannel; dataChannel.delegate = self
            if dataChannel.readyState == .open { self.startDiagnostics(); self.onState?("connected") }
        }
    }
}
extension PeerMedia: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            if dataChannel.readyState == .open { self.startDiagnostics(); self.onState?("connected") }
            else if dataChannel.readyState == .closed { self.onState?("closed") }
        }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard buffer.isBinary, buffer.data.count <= 16384 else { DispatchQueue.main.async { [weak self] in self?.onState?("failed") }; return }
        DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; self.onControl?(buffer.data) }
    }
}

/// Counts frames WebRTC hands to renderers; RTCMTLVideoView draws the newest of these on its display link.
final class StreamCadenceRenderer: NSObject, RTCVideoRenderer {
    private let counters: StreamCounters
    init(counters: StreamCounters) { self.counters = counters }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        counters.rendered()
    }
}
