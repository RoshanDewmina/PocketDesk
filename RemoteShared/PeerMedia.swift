import Foundation
import CoreVideo
import os
import WebRTC

enum SessionLog {
    static let log = Logger(subsystem: "com.roshan.PocketDesk", category: "session")
}

enum InputLog {
    static let log = Logger(subsystem: "com.roshan.PocketDesk", category: "input")
    static func sampled(_ count: Int) -> Bool { count <= 3 || count % 50 == 0 }
}

/// Control-channel counts for diagnostics; no content.
struct ControlChannelCounters {
    var sent = 0
    var refused: [String: Int] = [:]
    var received = 0
    var heldBeforeGate = 0
    var releasedAfterGate = 0
    var droppedAtGate = 0

    var summary: String {
        let refusals = refused.keys.sorted().map { "\($0)=\(refused[$0] ?? 0)" }.joined(separator: " ")
        return "sent=\(sent) refused=[\(refusals)] received=\(received) heldBeforeGate=\(heldBeforeGate) releasedAfterGate=\(releasedAfterGate) droppedAtGate=\(droppedAtGate)"
    }
}

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

    /// Finer than `classify`: "lan" (host candidates on both ends), "p2p" (reflexive on either end),
    /// "relay", or nil while pending.
    static func detail(selected: Bool, local: String?, remote: String?) -> String? {
        switch classify(selected: selected, local: local, remote: remote) {
        case "Relay": return "relay"
        case "Direct": return local == "host" && remote == "host" ? "lan" : "p2p"
        default: return nil
        }
    }
}

enum LocalMediaRoute {
    /// The selected pair must be exactly the proven host-candidate address pair. WebRTC's adapter
    /// label is only a veto: on macOS it reports en0 as "unknown" (it names only iOS `en*` as Wi-Fi),
    /// so an explicit VPN, cellular or loopback label, or the `vpn` flag, fails; "unknown" does not.
    /// A VPN interface cannot carry the proven physical IPv4 address, so the address match is the boundary.
    static func matches(_ link: ProvenLocalLink, localType: String?, remoteType: String?,
                        localAddress: String?, remoteAddress: String?, adapterType: String?,
                        networkType: String? = nil, vpn: Bool? = nil) -> Bool {
        let allowed: Set<String> = ["wifi", "ethernet", "unknown"]
        let labels = [adapterType, networkType].compactMap { $0 }
        return !labels.isEmpty && labels.allSatisfy(allowed.contains) && vpn != true &&
            localType == "host" && remoteType == "host" &&
            localAddress == link.localAddress && remoteAddress == link.peerAddress
    }

    /// The proof covers one IPv4 address pair, but WebRTC also gathers IPv6 and other interfaces and
    /// may nominate a same-LAN IPv6 pair that `matches` then rejects. Trickling only the proven
    /// addresses keeps the only possible pair the proven one.
    static func allows(candidate sdp: String, address: String) -> Bool {
        let fields = sdp.split(separator: " ")
        guard fields.count > 7, fields[6] == "typ", fields[7] == "host" else { return false }
        return fields[4] == address
    }
}

/// The video sender's rate settings (G5). `maxFramerate` follows the session rate, lowered by the
/// ladder's rung; above 60 fps `highRefreshNoAdaptation` turns WebRTC's own degradation off
/// (`maintainFramerateAndResolution`, the header's successor to `disabled`) so the app's ladder
/// decides. At 60 this is exactly the tuned policy: 60 fps and `tuning.degradationPreference`.
struct SenderRateParameters: Equatable {
    var maxFramerate: Int
    var degradationPreference: RTCDegradationPreference?

    static func make(targetFPS: Int, tuning: StreamTuning, ladderFPS: Int? = nil) -> SenderRateParameters {
        let target = max(1, targetFPS)
        let noAdaptation = target > CaptureRatePolicy.standardFPS && tuning.highRefreshNoAdaptation
        return SenderRateParameters(maxFramerate: min(target, max(1, ladderFPS ?? target)),
                                    degradationPreference: noAdaptation ? .maintainFramerateAndResolution
                                                                        : tuning.degradationPreference)
    }
}

/// What the host's video source adapts captured frames to: the receiver's H.264 level fitted at
/// the session rate (rung 0), scaled by the ladder's size fraction and dropped to its rate. Never
/// above the rung-0 size; even dimensions. Nil when there is nothing to adapt (no level budget and
/// no ladder), which leaves frames untouched as before.
struct SenderOutputFormat: Equatable {
    var width: Int
    var height: Int
    var fps: Int

    static func make(width: Int, height: Int, budget: H264FrameBudget?, targetFPS: Int,
                     ladder: LadderState?) -> SenderOutputFormat? {
        let target = max(1, targetFPS)
        let step = ladder.flatMap { $0.fps < target || $0.sizeFraction < 1 ? $0 : nil }
        let base: (width: Int, height: Int)
        if let budget {
            base = budget.fitted(width: width, height: height, fps: target)
        } else if step != nil, width >= 2, height >= 2 {
            base = (width, height)
        } else {
            return nil
        }
        guard let step else { return SenderOutputFormat(width: base.width, height: base.height, fps: target) }
        let fraction = step.sizeFraction.isFinite ? min(1, max(0.1, step.sizeFraction)) : 1
        func scaled(_ edge: Int) -> Int { min(edge, max(2, Int((Double(edge) * fraction).rounded(.down)) & ~1)) }
        return SenderOutputFormat(width: scaled(base.width), height: scaled(base.height),
                                  fps: min(target, max(1, step.fps)))
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
    /// Phone: the latest sender stages forwarded by the Mac with its capture heartbeat.
    var remoteHostSummary: HostStreamSummary? {
        didSet { remoteHostSummaryAt = ProcessInfo.processInfo.systemUptime }
    }
    private var remoteHostSummaryAt: TimeInterval?
    let tuning: StreamTuning
    private(set) var streamQuality: StreamQuality = .balanced
    private var latestHostSummary: HostStreamSummary?
    private var bandwidthSeed = BandwidthSeedPolicy()
    private let isHost: Bool
    private let nativeDesktopCodecs: Bool
    private var previousSample: StreamStatsSample?
    private var cadenceRenderer: StreamCadenceRenderer?
    private var observedTrack: RTCVideoTrack?
    private var statisticsTimer: Timer?
    private var statisticsPending = false
    private static let factory: RTCPeerConnectionFactory = {
        StreamTuning.prepareRuntime()
        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory(encoderFactory: PocketDeskVideoEncoderFactory(),
                                               decoderFactory: PocketDeskVideoDecoderFactory())
        #if DEBUG
        E2EMedia.restrictToLoopbackIfNeeded(factory)
        #endif
        return factory
    }()
    private static let compatibleFactory: RTCPeerConnectionFactory = {
        StreamTuning.prepareRuntime()
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        if let h264 = encoder.supportedCodecs().first(where: { $0.name == "H264" }) { encoder.preferredCodec = h264 }
        let factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: RTCDefaultVideoDecoderFactory())
        #if DEBUG
        E2EMedia.restrictToLoopbackIfNeeded(factory)
        #endif
        return factory
    }()
    private var connection: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var source: RTCVideoSource?
    private var capturer: RTCVideoCapturer?
    private var video: RTCVideoTrack?
    private var remoteDescriptionReady = false
    private var candidates: [RTCIceCandidate] = []
    private let forceRelay: Bool
    private let localLink: ProvenLocalLink?
    private let localRouteLock = NSLock()
    private var localPathAuthorized = false
    private var localPathEverAuthorized = false
    private var localPathStartedAt: TimeInterval?

    private func localGateOpen() -> Bool {
        guard localLink != nil else { return true }
        localRouteLock.lock(); defer { localRouteLock.unlock() }
        return localPathAuthorized
    }

    private func authorizeLocalPath() -> Bool {
        localRouteLock.lock(); defer { localRouteLock.unlock() }
        guard !localPathEverAuthorized || localPathAuthorized else { return false }
        localPathAuthorized = true
        localPathEverAuthorized = true
        return true
    }

    /// Runs on the WebRTC callback thread before any main-actor status notification.
    private func cutLocalPath() -> Bool {
        localRouteLock.lock(); defer { localRouteLock.unlock() }
        let hadAuthorized = localPathEverAuthorized
        localPathAuthorized = false
        return hadAuthorized
    }
    private var connectedPublished = false
    private(set) var controlCounters = ControlChannelCounters()
    /// Control messages that arrive before this side's first local-path authorization. The peer's
    /// gate can open first and it sends one-time state (geometry, viewing) immediately; dropping it
    /// left the phone without a geometry epoch, so input never enabled. Released only on authorization.
    private var preGateControl: [Data] = []
    private var preGateBytes = 0
    private var lastPairLog: String?
    private var role: String { isHost ? "host" : "phone" }
    private var lastRoute = "Route pending"
    private var restartPending = false
    private var restartGraceUntil: TimeInterval = 0
    /// How many times fresh relay credentials were applied to the live connection.
    private(set) var iceConfigurationUpdates = 0
    /// How many ICE restarts this side started or answered.
    private(set) var iceRestarts = 0
    /// Remote descriptions applied so far: 1 after the first connection, one more per completed renegotiation.
    private(set) var remoteDescriptionsApplied = 0
    private static let restartGrace: TimeInterval = 15
    private let captureLock = NSLock()
    private var receivingBudget: H264FrameBudget?
    private var adaptedFormat: SenderOutputFormat?
    private var appliedRate: SenderRateParameters?
    private var closed = false
    private var frameTransform: ((CVPixelBuffer, Int64) -> CVPixelBuffer?)?
    private let arrivalLock = NSLock()
    private var lastControlArrivalMs: Double?

    /// Mach ms when the newest control message reached the data channel, before its main-queue hop
    /// and decoding; the clock probes stamp with this so thread hops do not count as network time.
    var controlArrivalMs: Double? {
        arrivalLock.lock(); defer { arrivalLock.unlock() }
        return lastControlArrivalMs
    }

    var nativeCaptureBudget: H264FrameBudget? {
        guard nativeDesktopCodecs else { return nil }
        captureLock.lock(); defer { captureLock.unlock() }
        return receivingBudget
    }

    func setFrameTransform(_ transform: ((CVPixelBuffer, Int64) -> CVPixelBuffer?)?) {
        captureLock.lock(); defer { captureLock.unlock() }; frameTransform = transform
    }

    init(isHost: Bool, servers: [ICEServerConfiguration], forceRelay: Bool = false, nativeDesktopCodecs: Bool = true,
         localLink: ProvenLocalLink? = nil) {
        self.isHost = isHost
        self.forceRelay = forceRelay
        self.localLink = localLink
        self.nativeDesktopCodecs = nativeDesktopCodecs
        tuning = nativeDesktopCodecs ? StreamTuning.current : .legacy
        super.init()
        if isHost, nativeDesktopCodecs { DesktopH264Encoder.sharedCounters = counters }
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
    /// True while the connection may depend on a TURN allocation, so refreshed credentials only help
    /// once ICE gathers again.
    var needsRelayRefresh: Bool {
        #if DEBUG
        if let routeOverrideForTesting { return routeOverrideForTesting == "Relay" }
        #endif
        return forceRelay || lastRoute == "Relay"
    }

    #if DEBUG
    /// Loopback tests cannot produce a real relay route; this stands in for one.
    var routeOverrideForTesting: String?
    #endif

    /// Applies fresh relay credentials to the live connection without touching the media. They take
    /// effect the next time ICE gathers, which is the next restart from either side.
    @discardableResult
    func updateICEServers(_ servers: [ICEServerConfiguration]) -> Bool {
        guard !closed, let connection else { return false }
        let configuration = connection.configuration
        configuration.iceServers = servers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username ?? "", credential: $0.credential ?? "")
        }
        guard connection.setConfiguration(configuration) else { return false }
        iceConfigurationUpdates += 1
        return true
    }

    /// Host only: starts a new ICE generation with the credentials now in the configuration. The old
    /// candidate pair keeps carrying the media until the new one is confirmed, so nothing is dropped.
    @discardableResult
    func restartICE() -> Bool {
        guard isHost, !closed, let connection else { return false }
        guard remoteDescriptionReady, connection.signalingState == .stable else { restartPending = true; return false }
        restartPending = false
        restartGraceUntil = ProcessInfo.processInfo.systemUptime + Self.restartGrace
        iceRestarts += 1
        // Candidates for the new generation can arrive before the answer is applied; hold them.
        remoteDescriptionReady = false
        connection.restartIce()
        offer()
        return true
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
            #if DEBUG
            guard E2EMedia.allows(candidate: candidate) else { return }
            #endif
            if let link = localLink, !LocalMediaRoute.allows(candidate: candidate, address: link.peerAddress) { return }
            let value = RTCIceCandidate(sdp: candidate, sdpMLineIndex: line, sdpMid: signal.mid)
            if remoteDescriptionReady {
                connection.add(value) { [weak self] error in
                    guard error != nil else { return }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        // A late candidate from the ICE generation a restart just replaced is expected.
                        if ProcessInfo.processInfo.systemUptime < self.restartGraceUntil { return }
                        self.onState?("failed")
                    }
                }
            }
            else if candidates.count < 128 { candidates.append(value) }
            else { onState?("failed") }
            return
        }
        guard ["offer", "answer"].contains(signal.kind), let sdp = signal.sdp, sdp.utf8.count <= 96 * 1024,
              sdp.contains("a=fingerprint:sha-256 ") else { onState?("failed"); return }
        if signal.kind == "offer", remoteDescriptionReady {
            // Local proof is bound to the current ICE generation. A new offer needs a new proof.
            if localLink != nil { onState?("failed"); return }
            iceRestarts += 1
            restartGraceUntil = ProcessInfo.processInfo.systemUptime + Self.restartGrace
        }
        // Candidates that follow a renegotiation must wait for its description, not race it.
        remoteDescriptionReady = false
        connection.setRemoteDescription(RTCSessionDescription(type: signal.kind == "offer" ? .offer : .answer, sdp: sdp)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.closed, error == nil else { self?.onState?("failed"); return }
                self.captureLock.lock()
                self.receivingBudget = H264FrameBudget.receivingLimit(sdp: sdp)
                self.adaptedFormat = nil
                self.captureLock.unlock()
                self.remoteDescriptionReady = true
                self.remoteDescriptionsApplied += 1
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
                    if self.localGateOpen() { self.onRemoteVideo?(track) }
                }
            }
        }
    }
    private func configureNativeSender() {
        guard isHost, nativeDesktopCodecs, let sender = connection?.senders.first(where: { $0.track?.kind == "video" }) else { return }
        let parameters = sender.parameters
        let ceiling = tuning.maximumBitrateBps(for: streamQuality)
        let rate = currentSenderRate
        for encoding in parameters.encodings {
            encoding.maxFramerate = NSNumber(value: rate.maxFramerate)
            encoding.maxBitrateBps = NSNumber(value: tuning.qualityBitrates ? ceiling : 12_000_000)
        }
        if let preference = rate.degradationPreference {
            parameters.degradationPreference = NSNumber(value: preference.rawValue)
        } else if appliedRate?.degradationPreference != nil {
            parameters.degradationPreference = nil
        }
        sender.parameters = parameters
        appliedRate = rate
        if tuning.qualityBitrates {
            _ = connection?.setBweMinBitrateBps(nil, currentBitrateBps: nil,
                                                 maxBitrateBps: NSNumber(value: ceiling * max(1, tuning.bandwidthHeadroom)))
        }
    }

    /// G5: the capture session's target rate and display. Written on the main queue under
    /// `captureLock`, because `pushFrame` reads the rate and the ladder on the capture queue.
    private(set) var targetFPS = CaptureRatePolicy.standardFPS
    private(set) var displayRefreshHz: Double?
    private(set) var captureDisplay: String?
    /// G12: the rung last applied with `applyLadder`, nil after a capture (re)start.
    private(set) var ladderState: LadderState?
    /// Host: what the Mac reports on `capture` status, copied into every statistics sample.
    var busyState: BusyState?
    var captureRegion: CaptureRegion?

    private var currentSenderRate: SenderRateParameters {
        SenderRateParameters.make(targetFPS: targetFPS, tuning: tuning, ladderFPS: ladderState?.fps)
    }

    /// The capture applies a size rung itself (`RemoteCapture.setLadder`), so the sender scales only
    /// the rate; `ladderState` keeps the real fraction for the statistics.
    private var senderLadder: LadderState? {
        guard var state = ladderState else { return nil }
        state.sizeFraction = 1
        return state
    }

    /// Host, main queue: the capture session's rate (on every capture start, including a display
    /// switch). Clears the ladder to rung 0 and re-applies the sender when the rate settings change.
    func applyCaptureRate(targetFPS: Int, displayRefreshHz: Double?, display: String?) {
        let fps = max(1, targetFPS)
        captureLock.lock()
        if fps != self.targetFPS { adaptedFormat = nil }
        self.targetFPS = fps
        ladderState = nil
        captureLock.unlock()
        self.displayRefreshHz = displayRefreshHz
        captureDisplay = display
        reconfigureSenderRate()
    }

    /// Host, main queue: one ladder rung (G12). The rate goes to the sender's `maxFramerate` and the
    /// source adapter, the size fraction scales the adapted picture; the encoder session is not
    /// restarted (a size step still re-initialises it inside libwebrtc, with a key frame). Rung 0,
    /// the session rate at full size, is exactly the format `applyCaptureRate` set.
    func applyLadder(_ state: LadderState) {
        var applied = state
        applied.fps = min(targetFPS, max(1, state.fps))
        applied.sizeFraction = state.sizeFraction.isFinite ? min(1, max(0.1, state.sizeFraction)) : 1
        captureLock.lock()
        ladderState = applied
        captureLock.unlock()
        reconfigureSenderRate()
    }

    private func reconfigureSenderRate() {
        guard !closed, remoteDescriptionReady, currentSenderRate != appliedRate else { return }
        configureNativeSender()
    }

    /// Host: the picture mode the capture session actually applied. Updates the encoder ceiling
    /// without restarting the stream.
    func applyStreamQuality(_ quality: StreamQuality) {
        guard quality != streamQuality else { return }
        streamQuality = quality
        guard !closed, remoteDescriptionReady else { return }
        configureNativeSender()
    }

    /// Seed the bandwidth estimate once the selected route is known (see `BandwidthSeedPolicy`).
    /// Without `routeAwareSeed`, only "Direct" routes are seeded, at the mode's rate, and relay keeps
    /// libwebrtc's ramp; with it, LAN, internet P2P and relay each get their own start rate.
    private func seedBandwidthEstimate(_ stats: StreamStatsReport, route: String, detail: String?) {
        guard isHost, nativeDesktopCodecs, tuning.qualityBitrates else { return }
        let seedRoute: SeedRoute? = tuning.routeAwareSeed
            ? SeedRoute.classify(detail: detail, rttMs: stats.rttMs)
            : (route == "Direct" ? .lan : nil)
        let seedBps = seedRoute.map { streamQuality.startBitrateBps(for: $0) } ?? streamQuality.startBitrateBps
        guard bandwidthSeed.observe(eligible: seedRoute != nil, estimateKbps: stats.availableOutgoingKbps,
                                    lossPercent: stats.remoteLossPercent, seedKbps: Double(seedBps) / 1000) else { return }
        _ = connection?.setBweMinBitrateBps(nil, currentBitrateBps: NSNumber(value: seedBps),
                                             maxBitrateBps: NSNumber(value: tuning.maximumBitrateBps(for: streamQuality) * max(1, tuning.bandwidthHeadroom)))
    }

    /// Host: the encoder ceiling actually applied to the video sender, in kbps.
    var appliedSenderMaxKbps: Double? {
        guard isHost, let sender = connection?.senders.first(where: { $0.track?.kind == "video" }) else { return nil }
        return sender.parameters.encodings.first?.maxBitrateBps.map { $0.doubleValue / 1000 }
    }

    /// Host: the frame-rate cap actually applied to the video sender.
    var appliedSenderMaxFramerate: Int? {
        guard isHost, let sender = connection?.senders.first(where: { $0.track?.kind == "video" }) else { return nil }
        return sender.parameters.encodings.first?.maxFramerate?.intValue
    }

    /// Host: the degradation preference actually applied to the video sender.
    var appliedDegradationPreference: RTCDegradationPreference? {
        guard isHost, let sender = connection?.senders.first(where: { $0.track?.kind == "video" }) else { return nil }
        return sender.parameters.degradationPreference.flatMap { RTCDegradationPreference(rawValue: $0.intValue) }
    }

    /// Host: the newest sender summary, returned once so the capture heartbeat forwards each sample once.
    func takeHostSummary() -> HostStreamSummary? {
        defer { latestHostSummary = nil }
        return latestHostSummary
    }

    func sendControl(_ data: Data) -> Bool {
        let refusal: String? = closed ? "closed" : !localGateOpen() ? "gate" : data.count > 16384 ? "size"
            : channel == nil ? "no-channel" : channel?.readyState != .open ? "channel-not-open"
            : (channel?.bufferedAmount ?? 0) >= 64 * 1024 ? "buffered" : nil
        if let refusal {
            controlCounters.refused[refusal, default: 0] += 1
            let count = controlCounters.refused[refusal] ?? 0
            if InputLog.sampled(count) {
                InputLog.log.error("\(self.role, privacy: .public) send refused: \(refusal, privacy: .public) count=\(count, privacy: .public) channel=\(self.channel.map { String(describing: $0.readyState.rawValue) } ?? "nil", privacy: .public)")
            }
            return false
        }
        guard let channel else { return false }
        controlCounters.sent += 1
        if InputLog.sampled(controlCounters.sent) {
            InputLog.log.info("\(self.role, privacy: .public) sent control #\(self.controlCounters.sent, privacy: .public)")
        }
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
        guard !closed, localGateOpen(), let source, let capturer else { return }
        let output: CVPixelBuffer
        if let frameTransform { guard let transformed = frameTransform(buffer, timeStampNs) else { return }; output = transformed }
        else { output = buffer }
        if nativeDesktopCodecs,
           let format = SenderOutputFormat.make(width: CVPixelBufferGetWidth(output),
                                                height: CVPixelBufferGetHeight(output), budget: receivingBudget,
                                                targetFPS: targetFPS, ladder: senderLadder),
           format != adaptedFormat {
            source.adaptOutputFormat(toWidth: Int32(format.width), height: Int32(format.height), fps: Int32(format.fps))
            adaptedFormat = format
        }
        guard localGateOpen() else { return }
        source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: output), rotation: ._0, timeStampNs: timeStampNs))
        counters.pushed()
    }
    func startDiagnostics() {
        guard statisticsTimer == nil else { return }
        statisticsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sampleStatistics() }
        statisticsTimer?.tolerance = 0.1
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
                let localAddress = (local?.values["address"] as? String) ?? (local?.values["ip"] as? String)
                let remoteAddress = (remote?.values["address"] as? String) ?? (remote?.values["ip"] as? String)
                let adapterType = local?.values["networkAdapterType"] as? String
                let networkType = local?.values["networkType"] as? String
                let vpn = (local?.values["vpn"] as? NSNumber)?.boolValue
                if pair != nil {
                    let pairLog = "\(localType ?? "?")/\(remoteType ?? "?") \(localAddress ?? "?")->\(remoteAddress ?? "?") adapter=\(adapterType ?? "nil") network=\(networkType ?? "nil") vpn=\(vpn.map(String.init) ?? "nil")"
                    if pairLog != self.lastPairLog {
                        self.lastPairLog = pairLog
                        SessionLog.log.info("\(self.role, privacy: .public) selected pair \(pairLog, privacy: .public)")
                    }
                }
                if let link = self.localLink {
                    let matches = LocalMediaRoute.matches(link, localType: localType, remoteType: remoteType,
                                                           localAddress: localAddress, remoteAddress: remoteAddress,
                                                           adapterType: adapterType, networkType: networkType, vpn: vpn)
                    if pair != nil && !matches {
                        SessionLog.log.error("\(self.role, privacy: .public) media failed: selected pair is not the proven local link (\(self.lastPairLog ?? "?", privacy: .public); proven \(link.localAddress, privacy: .public)->\(link.peerAddress, privacy: .public))")
                        self.onState?("failed"); return
                    }
                    if matches {
                        guard self.authorizeLocalPath() else {
                            SessionLog.log.error("\(self.role, privacy: .public) media failed: local path re-authorization refused")
                            self.onState?("failed"); return
                        }
                        self.releasePreGateControl()
                        self.publishConnectedIfReady()
                    } else if let started = self.localPathStartedAt,
                              ProcessInfo.processInfo.systemUptime - started > 6 {
                        SessionLog.log.error("\(self.role, privacy: .public) media failed: no selected pair 6 s after the data channel opened")
                        self.onState?("failed"); return
                    }
                }
                let route = MediaRoute.classify(selected: pair != nil, local: localType, remote: remoteType)
                self.lastRoute = route
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
        stats.tuning = tuning.liveSummary
        stats.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        stats.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        if isHost {
            if nativeDesktopCodecs {
                stats.targetFPS = targetFPS
                stats.displayRefreshHz = displayRefreshHz
                stats.captureDisplay = captureDisplay
                stats.ladder = ladderState
                stats.busy = busyState
                stats.captureRegion = captureRegion
            }
            stats.maxKbps = appliedSenderMaxKbps
            seedBandwidthEstimate(stats, route: sample.route, detail: sample.routeDetail)
            latestHostSummary = stats.hostSummary
        } else {
            stats.host = remoteHostSummary
            stats.hostSummaryAgeMs = remoteHostSummaryAt.map { ((ProcessInfo.processInfo.systemUptime - $0) * 10_000).rounded() / 10 }
        }
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

    private func publishConnectedIfReady() {
        guard !closed, !connectedPublished, localGateOpen(),
              channel?.readyState == .open else { return }
        connectedPublished = true
        if let track = observedTrack { onRemoteVideo?(track) }
        onState?("connected")
    }

    private func releasePreGateControl() {
        guard !preGateControl.isEmpty, localGateOpen() else { return }
        let held = preGateControl
        preGateControl.removeAll(); preGateBytes = 0
        controlCounters.releasedAfterGate += held.count
        InputLog.log.info("\(self.role, privacy: .public) released \(held.count, privacy: .public) control messages held until the local path was authorized")
        for data in held {
            guard !closed, localGateOpen() else { return }
            onControl?(data)
        }
    }

    private var localPathNeverAuthorized: Bool {
        localRouteLock.lock(); defer { localRouteLock.unlock() }
        return !localPathEverAuthorized
    }

    func close() {
        preGateControl.removeAll(); preGateBytes = 0
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
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        guard stateChanged == .stable else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, self.restartPending else { return }
            self.restartICE()
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.observeRemoteVideo(track)
                if self.localGateOpen() { self.onRemoteVideo?(track) }
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        SessionLog.log.info("\(self.role, privacy: .public) ICE connection state \(newState.rawValue, privacy: .public) (0 new,1 checking,2 connected,3 completed,4 failed,5 disconnected,6 closed)")
        if localLink != nil && newState == .checking {
            let wasAuthorized = cutLocalPath()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { return }
                if wasAuthorized { self.onState?("failed") }
            }
        }
        if [.failed, .disconnected, .closed].contains(newState) {
            if localLink != nil { _ = cutLocalPath() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // An ICE restart can report a passing `disconnected` while the new pair is checked;
                // a real failure still ends the session through `failed`.
                if newState == .disconnected, ProcessInfo.processInfo.systemUptime < self.restartGraceUntil { return }
                self.onState?(newState == .failed ? "failed" : newState == .closed ? "closed" : "disconnected")
            }
        }
    }
    @objc(peerConnection:didChangeLocalCandidate:remoteCandidate:lastReceivedMs:changeReason:)
    func peerConnection(_ peerConnection: RTCPeerConnection, didChangeLocalCandidate local: RTCIceCandidate,
                        remoteCandidate remote: RTCIceCandidate, lastReceivedMs: Int32,
                        changeReason reason: String) {
        SessionLog.log.info("\(self.role, privacy: .public) selected candidate pair changed: reason=\(reason, privacy: .public)")
        guard localLink != nil else { return }
        let wasAuthorized = cutLocalPath()
        if wasAuthorized {
            SessionLog.log.error("\(self.role, privacy: .public) media failed: selected pair changed after local authorization")
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { return }
                self.onState?("failed")
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        #if DEBUG
        guard E2EMedia.allows(candidate: candidate.sdp) else { return }
        #endif
        if let link = localLink, !LocalMediaRoute.allows(candidate: candidate.sdp, address: link.localAddress) { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.onSignal?(MediaSignal(kind: "candidate", candidate: candidate.sdp, mid: candidate.sdpMid, line: candidate.sdpMLineIndex))
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Attach before returning: the Mac sends its one-time geometry and viewing messages as soon
        // as the channel opens, and the WebRTC wrapper drops any message that arrives while the
        // channel has no delegate. Main-queue order still adopts the channel before its messages.
        dataChannel.delegate = self
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, dataChannel.label == "control", self.channel == nil else {
                dataChannel.delegate = nil; dataChannel.close(); return
            }
            self.channel = dataChannel
            if dataChannel.readyState == .open {
                self.localPathStartedAt = ProcessInfo.processInfo.systemUptime
                self.startDiagnostics(); self.publishConnectedIfReady()
            }
        }
    }
}
extension PeerMedia: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, self.channel === dataChannel else { return }
            if dataChannel.readyState == .open {
                self.localPathStartedAt = ProcessInfo.processInfo.systemUptime
                self.startDiagnostics(); self.publishConnectedIfReady()
            }
            else if dataChannel.readyState == .closed { self.onState?("closed") }
        }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        arrivalLock.lock(); lastControlArrivalMs = MachClock.nowMs(); arrivalLock.unlock()
        guard buffer.isBinary, buffer.data.count <= 16384 else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.channel === dataChannel else { return }
                self.onState?("failed")
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, self.channel === dataChannel else { return }
            self.controlCounters.received += 1
            guard self.localGateOpen() else {
                if self.localLink != nil, self.localPathNeverAuthorized, self.preGateControl.count < 64,
                   self.preGateBytes + buffer.data.count <= 256 * 1024 {
                    self.preGateControl.append(buffer.data); self.preGateBytes += buffer.data.count
                    self.controlCounters.heldBeforeGate += 1
                    InputLog.log.info("\(self.role, privacy: .public) control held until local path authorization (\(self.preGateControl.count, privacy: .public) held)")
                } else {
                    self.controlCounters.droppedAtGate += 1
                    if InputLog.sampled(self.controlCounters.droppedAtGate) {
                        InputLog.log.error("\(self.role, privacy: .public) control dropped at local gate count=\(self.controlCounters.droppedAtGate, privacy: .public)")
                    }
                }
                return
            }
            if InputLog.sampled(self.controlCounters.received) {
                InputLog.log.info("\(self.role, privacy: .public) received control #\(self.controlCounters.received, privacy: .public)")
            }
            self.onControl?(buffer.data)
        }
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
