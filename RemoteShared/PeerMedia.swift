import Foundation
import CoreVideo
import os
import WebRTC
import Network

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
    /// Public diagnostics accept only known types, never candidate addresses or arbitrary labels.
    static func publicPairSummary(local: String?, remote: String?, adapter: String?, network: String?) -> String {
        let candidates: Set<String> = ["host", "srflx", "prflx", "relay"]
        let interfaces: Set<String> = ["wifi", "ethernet", "cellular", "vpn", "loopback", "unknown"]
        func label(_ value: String?, in allowed: Set<String>) -> String {
            guard let value, allowed.contains(value) else { return "unknown" }
            return value
        }
        return "\(label(local, in: candidates))/\(label(remote, in: candidates)) adapter=\(label(adapter, in: interfaces)) network=\(label(network, in: interfaces))"
    }

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

/// X16: what the native host asks WebRTC for on the transport. DSCP marking (`enableDscp`, fixed at
/// peer creation) and a high `networkPriority` (which the DSCP value is derived from) are requested only
/// on a proven one-hop local link; relay and internet-direct routes stay unmarked at medium. A request,
/// not an effect: the OS, Wi-Fi and routers may strip or ignore the marking, and nothing here measures it.
struct TransportPriorityRequest: Equatable {
    var dscp: Bool
    var networkPriority: RTCPriority

    var summary: String {
        let priority: String
        switch networkPriority {
        case .veryLow: priority = "very-low"
        case .low: priority = "low"
        case .medium: priority = "medium"
        case .high: priority = "high"
        @unknown default: priority = "unknown"
        }
        return "DSCP \(dscp ? "on" : "off") · priority \(priority)"
    }
}

enum TransportPriorityPolicy {
    static func request(nativeDesktopCodecs: Bool, provenLocalLink: Bool) -> TransportPriorityRequest {
        let local = nativeDesktopCodecs && provenLocalLink
        return TransportPriorityRequest(dscp: local, networkPriority: local ? .high : .medium)
    }
}

/// The video sender's rate settings (G5). `maxFramerate` follows the session rate, lowered by the
/// ladder's rung; above 60 fps `highRefreshNoAdaptation` turns WebRTC's own degradation off
/// (`maintainFramerateAndResolution`, the header's successor to `disabled`) so the app's ladder
/// decides. At up to 60 fps, Performance favours frame rate; Quality keeps the tuning preference.
struct SenderRateParameters: Equatable {
    var maxFramerate: Int
    var degradationPreference: RTCDegradationPreference?

    static func make(targetFPS: Int, tuning: StreamTuning, ladderFPS: Int? = nil,
                     quality: StreamQuality = .sharp, legacyPictureSettings: Bool = false,
                     exactResolution: Bool = false) -> SenderRateParameters {
        let target = max(1, targetFPS)
        let noAdaptation = target > CaptureRatePolicy.standardFPS && tuning.highRefreshNoAdaptation
        let preference: RTCDegradationPreference? = target <= CaptureRatePolicy.standardFPS
            && !legacyPictureSettings && tuning.qualityBitrates
            && PictureMode(quality: quality).prioritizesFrameRate ? .maintainFramerate : tuning.degradationPreference
        return SenderRateParameters(maxFramerate: min(target, max(1, ladderFPS ?? target)),
                                    degradationPreference: noAdaptation ? .maintainFramerateAndResolution
                                                                        : (exactResolution ? .maintainResolution : preference))
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
    var onAudioPlaybackFailure: (() -> Void)?
    var onControl: ((Data) -> Void)?
    var onState: ((String) -> Void)?
    var onDiagnostics: ((String) -> Void)?
    var onStreamStatistics: ((StreamStatsReport) -> Void)?
    var onSenderStatistics: ((StreamStatsReport) -> Void)?
    var onGuestTransportStatistics: ((GuestTransportObservation) -> Void)? // main, exact peer instance
    private var guestTransportSampler = GuestTransportSampler()
    private var transportUsageSampler = TransportUsageSampler()
    func observeReplicatedGuestLoad(count: Int, kbps: Double?, at: TimeInterval) {
        resourceBudget.observeGuests(count: count, kbps: kbps, at: at)
    }
    /// `file` channel messages, delivered on WebRTC's thread; the receiver hops to its own queue.
    var onFileMessage: ((Data) -> Void)?
    private let fileReceiveLease = TransferEffectLease()
    /// Ingress must finish before close returns and a replacement session can admit bytes.
    /// This callback only snapshots the engine's IO admission and enqueues work; it never waits on main.
    private func deliverFileMessage(_ data: Data) {
        _ = fileReceiveLease.performIfActive { onFileMessage?(data) }
    }
    #if DEBUG && AUDIO_LIFETIME_TESTS
    func deliverFileMessageForTesting(_ data: Data) { deliverFileMessage(data) }
    func retireFileReceiveForTesting() { fileReceiveLease.retire() }
    #endif
    var onFileBufferedAmountChange: (() -> Void)?
    let counters = StreamCounters()
    private let resourceBudget = MediaResourceBudget()
    var captureMaximumDimension: Int?
    /// Phone: the latest sender stages forwarded by the Mac with its capture heartbeat.
    private(set) var remoteHostSummary: HostStreamSummary?
    private(set) var lastControlArrivedFrames: Int?
    private(set) var lastControlArrivedAt: TimeInterval?
    private var remoteFrameMark: FrameMark?
    private var linkMonitor: NWPathMonitor?
    private var linkInterfaces: [LocalPathInterface] = []
    private var selectedLocalAddress: String?
    private var selectedLocalCandidateType: String?

    func acceptHostSummary(_ summary: HostStreamSummary, arrivedFrames: Int?, arrivedAt: TimeInterval?) {
        let now = arrivedAt ?? ProcessInfo.processInfo.systemUptime
        remoteHostSummary = summary
        remoteHostSummaryAt = now
        remoteFrameMark = summary.framesEncodedTotal.flatMap { total in
            arrivedFrames.map { FrameMark(hostEncoded: total, phoneArrived: $0, at: now) }
        }
        frameTimingReceiver?.receive(summary.frameRecords, clock: counters.clockEstimate)
    }
    /// Perf pack 4a: host push → encoded records (nil when `StreamTuning.frameTiming` is off), and the
    /// phone's decoder log and join.
    let frameTimingLog: HostFrameTimingLog?
    let frameTimingReceiver: FrameTimingReceiver?
    private var remoteHostSummaryAt: TimeInterval?
    let tuning: StreamTuning
    private(set) var streamQuality: StreamQuality = .balanced
    private var hevcRun: HEVCRun?
    private var hevcDecodeWatchdog = HEVCDecodeWatchdog()
    private var onFirstPictureHEVCFailure: (() -> Void)?
    private var onFirstPictureHEVC444Failure: (() -> Void)?
    private var latestHostSummary: HostStreamSummary?
    private var bandwidthSeed = BandwidthSeedPolicy()
    private var ceilingRoute = CeilingRouteTracker()
    private var appliedBweMaxBps: Int?
    private let isHost: Bool
    private let nativeDesktopCodecs: Bool
    let transportPriority: TransportPriorityRequest
    private var previousSample: StreamStatsSample?
    private var cadenceRenderer: StreamCadenceRenderer?
    private var observedTrack: RTCVideoTrack?
    private var statisticsTimer: Timer?
    private var statisticsPending = false
    private static let codecRuntime: Void = {
        StreamTuning.prepareRuntime()
        RTCInitializeSSL()
    }()
    let videoFeedback = VideoFeedbackContext()
    private var sessionVideoFactory: RTCPeerConnectionFactory?
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
    // Cross-thread order: localRouteLock → audioLifetimeLock → device's PCM/consent lock.
    // Device dispatch is asynchronous and never reenters PeerMedia while these locks are held.
    // Every audio reference access and terminal fence uses this lock; video `closed` belongs
    // to captureLock and must not be read by the audio capture or ICE callback threads.
    private let audioLifetimeLock = NSLock()
    private var audioClosed = false
    #if os(macOS)
    private var systemAudioDevice: FPSystemAudioDevice?
    private var sessionAudioFactory: RTCPeerConnectionFactory?
    private var systemAudioTrack: RTCAudioTrack?
    #endif
    #if os(iOS)
    private var phoneAudioDevice: PhoneSystemAudioDevice?
    private var phoneAudioFactory: RTCPeerConnectionFactory?
    #endif
    private var remoteAudioTrack: RTCAudioTrack?
    private var remoteAudioMuted = true

    private func withAudioLifetime<T>(_ body: (Bool) -> T) -> T {
        localRouteLock.lock(); defer { localRouteLock.unlock() }
        audioLifetimeLock.lock(); defer { audioLifetimeLock.unlock() }
        return body(!audioClosed && (localLink == nil || localPathAuthorized))
    }

    /// Explicit local playback choice; the phone never creates a sending microphone track.
    func setRemoteAudioMuted(_ muted: Bool) {
        withAudioLifetime { permitted in
            remoteAudioMuted = muted
            #if os(iOS)
            phoneAudioDevice?.setConsent(!muted && permitted)
            #endif
        }
        refreshAudioTracks()
    }

    // Track setters may synchronously proxy to WebRTC's signaling thread. Run them on
    // main, outside both locks, so an ICE callback waiting for the lifetime fence cannot
    // deadlock a setter waiting for that callback thread. Every queued refresh reads current state.
    private func refreshAudioTracks() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshAudioTracks() }
            return
        }
        let remote = withAudioLifetime { permitted in (remoteAudioTrack, !remoteAudioMuted && permitted) }
        remote.0?.isEnabled = remote.1
        #if os(macOS)
        let system = withAudioLifetime { permitted in (systemAudioTrack, permitted && systemAudioDevice?.consentEnabled == true) }
        system.0?.isEnabled = system.1
        #endif
    }

    private func observeRemoteAudio() {
        guard !isHost else { return }
        let track = connection?.receivers.compactMap { $0.track as? RTCAudioTrack }.first
        withAudioLifetime { _ in
            guard !audioClosed else { return }
            remoteAudioTrack = track
        }
        refreshAudioTracks()
    }

    #if os(macOS)
    var systemAudioEnabled: Bool { withAudioLifetime { _ in systemAudioDevice?.consentEnabled == true } }
    func setSystemAudioEnabled(_ enabled: Bool) {
        withAudioLifetime { permitted in
            systemAudioDevice?.setConsent(enabled && permitted)
        }
        refreshAudioTracks()
    }
    func beginSystemAudioCapture() -> UInt64 {
        withAudioLifetime { permitted in permitted ? (systemAudioDevice?.beginCapture() ?? 0) : 0 }
    }
    func endSystemAudioCapture(_ epoch: UInt64) {
        withAudioLifetime { _ in systemAudioDevice?.endCapture(epoch) }
    }
    @discardableResult
    func submitSystemAudio(_ pcm: Data, epoch: UInt64, hostTime: UInt64) -> Bool {
        withAudioLifetime { permitted in
            guard permitted else { return false }
            return systemAudioDevice?.submitPCM(pcm, captureEpoch: epoch, hostTime: hostTime) ?? false
        }
    }
    #if DEBUG && AUDIO_LIFETIME_TESTS
    /// Test retained native-device state after actual PeerMedia teardown. No route authorization.
    var audioDeviceForLifetimeTesting: FPSystemAudioDevice? {
        withAudioLifetime { _ in systemAudioDevice }
    }
    func authorizeAudioPathForLifetimeTesting() { _ = authorizeLocalPath() }
    func cutAudioPathForLifetimeTesting() { _ = cutLocalPath() }
    #endif
    #endif
    private var connection: RTCPeerConnection?
    static let refinementChannelLabel = "refinement-1"
    private let refinementLock = NSLock()
    private var refinementChannel: RTCDataChannel?
    private var refinementEnded = false
    private var refinementUnavailable = false
    private let refinementQueue = DispatchQueue(label: "farside.video.refinement-channel")
    private let refinementQueueKey = DispatchSpecificKey<UInt8>()
    private let refinementPipe = VideoRefinementChannel()
    private var refinementTimer: DispatchSourceTimer?
    private var requestedRefinementCapture = false
    var refinementCaptureEnabled: Bool { refinementLock.lock(); defer { refinementLock.unlock() }; return !refinementEnded && !refinementUnavailable && requestedRefinementCapture }
    func requestRefinementCapture(_ enabled: Bool) {
        let admitted = !lowDataPolicyActive && HEVC444Policy.permitsRefinement(requested: enabled, fullColor: fullColorCaptureEnabled)
        refinementLock.lock(); if !refinementEnded { requestedRefinementCapture = admitted && !refinementUnavailable && nativeDesktopCodecs }; refinementLock.unlock()
    }
    func configureVideoRefinement(enabled: Bool, geometry: UInt64, scope: UInt64) {
        let requested = !lowDataPolicyActive && HEVC444Policy.permitsRefinement(requested: enabled, fullColor: fullColorCaptureEnabled)
        refinementLock.lock(); let admitted = requested && !refinementEnded && !refinementUnavailable; refinementLock.unlock()
        if !admitted { videoFeedback.disableRefinement() }
        if admitted && isHost { openRefinementChannel() }
        let operation = { self.refinementPipe.configure(enabled: admitted, geometry: geometry, scope: scope) }
        if DispatchQueue.getSpecific(key: refinementQueueKey) != nil { operation() } else { refinementQueue.sync(execute: operation) }
    }
    private func openRefinementChannel() {
        refinementLock.lock(); let needed = !refinementEnded && !refinementUnavailable && refinementChannel == nil; refinementLock.unlock()
        guard needed, let connection else { return }
        let config = RTCDataChannelConfiguration(); config.isOrdered = true
        guard let next = connection.dataChannel(forLabel: Self.refinementChannelLabel, configuration: config) else { return }
        refinementLock.lock(); let adopt = !refinementEnded && !refinementUnavailable && refinementChannel == nil
        if adopt { refinementChannel = next }; refinementLock.unlock()
        if adopt { next.delegate = self } else { next.close() }
    }
    private func adoptRefinementChannel(_ channel: RTCDataChannel) -> Bool {
        refinementLock.lock(); defer { refinementLock.unlock() }
        guard !isHost, nativeDesktopCodecs, !refinementEnded, !refinementUnavailable, refinementChannel == nil,
              channel.isOrdered, channel.isReliable else { return false }
        refinementChannel = channel; return true // Dormant until authenticated capture capabilities/epoch arrive.
    }
    private func isRefinementChannel(_ channel: RTCDataChannel) -> Bool {
        refinementLock.lock(); defer { refinementLock.unlock() }; return refinementChannel === channel
    }
    /// Runs on the refinement owner after all already-admitted sends. A failed optional
    /// lane is terminal for this peer, but must not indefinitely poison healthy file credit.
    private func retireClosedRefinementChannel(_ channel: RTCDataChannel) {
        guard channel.readyState == .closed else { return }
        refinementLock.lock(); let current = refinementChannel === channel; refinementLock.unlock()
        guard current else { return }
        refinementPipe.end(); videoFeedback.disableRefinement()
        refinementLock.lock()
        if refinementChannel === channel { refinementChannel = nil; refinementUnavailable = true; requestedRefinementCapture = false }
        refinementLock.unlock()
        channel.delegate = nil
        onFileBufferedAmountChange?()
    }
    #if DEBUG
    func closeRefinementChannelForTesting() {
        refinementLock.lock(); let target = refinementChannel; refinementLock.unlock(); target?.close()
    }
    var refinementChannelRetiredForTesting: Bool {
        refinementLock.lock(); defer { refinementLock.unlock() }; return refinementUnavailable && refinementChannel == nil
    }
    #endif
    private var aggregateBulkBuffered: UInt64? {
        fileLock.lock(); refinementLock.lock()
        let file = fileChannel, image = refinementChannel, ended = refinementEnded
        refinementLock.unlock(); fileLock.unlock()
        guard !ended, file == nil || file?.readyState == .open, image == nil || image?.readyState == .open else { return nil }
        // Retained native references stay alive; getters run outside Swift locks/callback ownership.
        let (total, overflow) = (file?.bufferedAmount ?? 0).addingReportingOverflow(image?.bufferedAmount ?? 0)
        return overflow ? nil : total
    }
    private func sendRefinement(_ data: Data) -> Bool {
        guard data.count <= BulkAdmissionPolicy.maximumMessageBytes, localGateOpen(),
              let packet = try? JSONDecoder().decode(VideoRefinementChunk.self, from: data),
              videoFeedback.permitsRefinement(packet.identity, sender: isHost && !packet.ack),
              resourceBudget.permits(bytes: data.count, at: ProcessInfo.processInfo.systemUptime,
                controlBuffered: inputBufferedAmount, fileBuffered: aggregateBulkBuffered) else { return false }
        refinementLock.lock()
        let target = refinementEnded ? nil : refinementChannel
        refinementLock.unlock()
        guard let target, target.readyState == .open, localGateOpen() else { return false }
        #if DEBUG && AUDIO_LIFETIME_TESTS
        refinementLock.lock(); let beforeSubmission = refinementBeforeSubmissionForTesting, submitted = refinementSubmittedForTesting; refinementLock.unlock()
        beforeSubmission?()
        #endif
        // Only the refinement owner queue sends; close drains that queue before detachment.
        // Never hold a Swift channel lock while entering a public native send/callback.
        return withNativeRouteSubmissionAuthority {
            guard target.readyState == .open,
                  videoFeedback.permitsRefinement(packet.identity, sender: isHost && !packet.ack) else { return false }
            #if DEBUG && AUDIO_LIFETIME_TESTS
            submitted?()
            #endif
            return target.sendData(RTCDataBuffer(data: data, isBinary: true))
        } ?? false
    }
    private let pointerLock = NSLock()
    private var pointerChannel: RTCDataChannel?
    private var pointerAllowed = false
    private var pointerEnded = false
    private var pendingPointer: (data: Data, arrivedMs: Double)?
    private var pointerDeliveryScheduled = false
    var onPointerMessage: ((Data) -> Void)?
    /// Paired with the pointer packet currently delivered; nil outside its callback.
    private(set) var pointerArrivalMs: Double?
    static let pointerChannelLabel = "pointer-causal-1"

    func allowPointerChannel() { pointerLock.lock(); if !pointerEnded { pointerAllowed = true }; pointerLock.unlock() }
    func openPointerChannel() {
        allowPointerChannel()
        guard isHost, let connection else { return }
        let config = RTCDataChannelConfiguration(); config.isOrdered = false; config.maxRetransmits = 0
        guard let created = connection.dataChannel(forLabel: Self.pointerChannelLabel, configuration: config) else { return }
        pointerLock.lock()
        let adopt = !pointerEnded && pointerAllowed && pointerChannel == nil
        if adopt { pointerChannel = created }
        pointerLock.unlock()
        if adopt { created.delegate = self } else { created.close() }
    }
    private func adoptPointerChannel(_ channel: RTCDataChannel) -> Bool {
        guard channel.label == Self.pointerChannelLabel else { return false }
        pointerLock.lock(); defer { pointerLock.unlock() }
        guard !isHost, !pointerEnded, pointerAllowed, pointerChannel == nil, !channel.isOrdered, channel.maxRetransmits == 0 else { return false }
        pointerChannel = channel
        return true
    }
    private func isPointerChannel(_ channel: RTCDataChannel) -> Bool {
        pointerLock.lock(); defer { pointerLock.unlock() }
        return pointerChannel === channel
    }
    func sendPointer(_ data: Data) -> Bool {
        guard data.count <= 16384, localGateOpen() else { return false }
        pointerLock.lock(); defer { pointerLock.unlock() }
        guard !pointerEnded, let pointerChannel, pointerChannel.readyState == .open,
              pointerChannel.bufferedAmount + UInt64(data.count) <= 32 * 1024 else { return false }
        return pointerChannel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }
    #if DEBUG
    func receivePointerFixtureForTesting(_ data: Data, arrivedMs: Double) {
        receivePointer(data, arrivedMs: arrivedMs)
    }
    #endif
    private func receivePointer(_ data: Data, arrivedMs: Double) {
        guard data.count <= 16384, localGateOpen() else { return }
        pointerLock.lock()
        guard !pointerEnded else { pointerLock.unlock(); return }
        pendingPointer = (data, arrivedMs) // The newest full prefix recovers motion omitted from this mailbox.
        if pointerDeliveryScheduled { pointerLock.unlock(); return }
        pointerDeliveryScheduled = true
        pointerLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pointerLock.lock()
            let value = self.pendingPointer; self.pendingPointer = nil; self.pointerDeliveryScheduled = false
            let ended = self.pointerEnded
            self.pointerLock.unlock()
            if !ended, self.localGateOpen(), let value {
                self.pointerArrivalMs = value.arrivedMs
                defer { self.pointerArrivalMs = nil }
                self.onPointerMessage?(value.data)
            }
        }
    }
    private var channel: RTCDataChannel?
    // Main owns mutations; bulk admission reads the channel lifetime from its I/O queue.
    private let controlLock = NSLock()
    /// Guarded by `fileLock`: file sends and receives run off the main thread.
    private var fileChannel: RTCDataChannel?
    private let fileLock = NSLock()
    private let acceptsFileChannel: Bool
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

    /// Serializes the final native effect with callback-thread path retirement.
    /// Public DataChannel Send proxies to the network thread; observer notifications post
    /// to signaling rather than synchronously acquiring this authority lock from Send.
    /// No channel lock or owner-queue drain is held inside callback-thread retirement.
    func withNativeRouteSubmissionAuthority<T>(_ operation: () -> T) -> T? {
        localRouteLock.lock()
        defer { localRouteLock.unlock() }
        #if DEBUG && AUDIO_LIFETIME_TESTS
        let requiresAuthority = localLink != nil || forcedNativeRouteAuthorityForTesting
        #else
        let requiresAuthority = localLink != nil
        #endif
        guard !requiresAuthority || localPathAuthorized else { return nil }
        return operation()
    }
    #if DEBUG && AUDIO_LIFETIME_TESTS
    private var forcedNativeRouteAuthorityForTesting = false
    private var refinementBeforeSubmissionForTesting: (() -> Void)?
    private var refinementSubmittedForTesting: (() -> Void)?
    /// Explicit test injection into an already-connected loopback peer, never a real local proof.
    func forceNativeRouteAuthorityForTesting() {
        localRouteLock.lock(); forcedNativeRouteAuthorityForTesting = true; localPathAuthorized = true; localPathEverAuthorized = true; localRouteLock.unlock()
    }
    func installRefinementSubmissionHooksForTesting(before: (() -> Void)?, submitted: (() -> Void)?) {
        refinementLock.lock(); refinementBeforeSubmissionForTesting = before; refinementSubmittedForTesting = submitted; refinementLock.unlock()
    }
    func authorizeRefinementPathForTesting() { _ = authorizeLocalPath() }
    func cutRefinementPathForTesting() { _ = cutLocalPath() }
    func submitNativeRefinementEffectForTesting(before: () -> Void, effect: () -> Bool) -> Bool {
        before(); return withNativeRouteSubmissionAuthority(effect) ?? false
    }
    #endif

    /// The media path is the proven one-hop local link and is still selected.
    var provenLocalLinkActive: Bool { localLink != nil && localGateOpen() }

    private func authorizeLocalPath() -> Bool {
        localRouteLock.lock(); defer { localRouteLock.unlock() }
        guard !localPathEverAuthorized || localPathAuthorized else { return false }
        localPathAuthorized = true
        localPathEverAuthorized = true
        return true
    }

    /// Runs on the WebRTC callback thread before any main-actor status notification.
    private func cutLocalPath() -> Bool {
        localRouteLock.lock()
        let hadAuthorized = localPathEverAuthorized
        localPathAuthorized = false
        audioLifetimeLock.lock()
        #if os(iOS)
        phoneAudioDevice?.setConsent(false)
        #endif
        #if os(macOS)
        systemAudioDevice?.setConsent(false)
        #endif
        audioLifetimeLock.unlock()
        localRouteLock.unlock()
        refreshAudioTracks()
        return hadAuthorized
    }
    private var connectedPublished = false
    private(set) var controlCounters = ControlChannelCounters()
    /// Control messages that arrive before this side's first local-path authorization. The peer's
    /// gate can open first and it sends one-time state (geometry, viewing) immediately; dropping it
    /// left the phone without a geometry epoch, so input never enabled. Released only on authorization.
    private var preGateControl: [(data: Data, arrivedFrames: Int, arrivedAt: TimeInterval, arrivedMs: Double)] = []
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
    /// DTLS refused the peer: its certificate did not match the fingerprint in the sealed remote description.
    private(set) var dtlsRejected = false
    /// Standardized ICE state (signaling thread). Unlike `iceConnectionState` it stays connected when only DTLS fails.
    private var standardizedICE: RTCIceConnectionState = .new
    private static let restartGrace: TimeInterval = 15
    private let captureLock = NSLock()
    private var receivingBudget: H264FrameBudget?
    private var adaptedFormat: SenderOutputFormat?
    private var appliedRate: SenderRateParameters?
    private var closed = false
    private var frameTransform: ((CVPixelBuffer, Int64) -> CVPixelBuffer?)?
    private let arrivalLock = NSLock()
    private var lastControlArrivalMs: Double?

    /// Mach ms when the packet currently delivered reached the data channel, before its main-queue
    /// hop and decoding. Nil outside delivery; a later sibling can never overwrite this stamp.
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

    private(set) var fullColorCaptureEnabled = false
    let textClarity: TextClarityContext
    func captureContentChanged() { textClarity.contentChanged() }
    init(isHost: Bool, servers: [ICEServerConfiguration], forceRelay: Bool = false, nativeDesktopCodecs: Bool = true,
         localLink: ProvenLocalLink? = nil, fileChannel: Bool = false, hevc: Bool? = nil, hevc444: Bool? = nil, videoLTR: Bool = false,
         textClarity: Bool = false, capabilitySnapshot: NativeVideoCapabilitySnapshot? = nil) {
        self.isHost = isHost
        self.textClarity = TextClarityContext(enabled: isHost && nativeDesktopCodecs && textClarity)
        acceptsFileChannel = fileChannel
        self.forceRelay = forceRelay
        self.localLink = localLink
        self.nativeDesktopCodecs = nativeDesktopCodecs
        transportPriority = TransportPriorityPolicy.request(nativeDesktopCodecs: nativeDesktopCodecs, provenLocalLink: localLink != nil)
        tuning = nativeDesktopCodecs ? StreamTuning.current : .legacy
        frameTimingLog = isHost && nativeDesktopCodecs && (FrameTimingSwitch.override ?? tuning.frameTiming)
            ? HostFrameTimingLog() : nil
        frameTimingReceiver = !isHost && nativeDesktopCodecs && (tuning.frameTiming || PhoneRenderTiming.enabled)
            ? FrameTimingReceiver(log: PhoneFrameTimingLog()) : nil
        super.init()
        if isHost {
            let monitor = NWPathMonitor()
            linkMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    self.linkInterfaces = path.localInterfaces
                }
            }
            monitor.start(queue: DispatchQueue(label: "farside.quality.link"))
        }
        refinementQueue.setSpecific(key: refinementQueueKey, value: 1)
        refinementPipe.send = { [weak self] data, _ in self?.sendRefinement(data) ?? false }
        refinementPipe.image = { [weak self] image in self?.videoFeedback.acceptRefinement(image) }
        videoFeedback.setRefinementImage { [weak self] image in
            self?.refinementQueue.async { [weak self] in self?.refinementPipe.offer(image, at: ProcessInfo.processInfo.systemUptime) }
        }
        let timer = DispatchSource.makeTimerSource(queue: refinementQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.refinementPipe.pump(at: ProcessInfo.processInfo.systemUptime) }
        refinementTimer = timer; timer.resume()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.enableDscp = transportPriority.dscp
        configuration.iceTransportPolicy = forceRelay ? .relay : .all
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceServers = servers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username ?? "", credential: $0.credential ?? "") }
        // Context is owned by this peer, including negotiation that starts after another
        // peer is created. Never publish a process-global 'next encoder' binding.
        _ = Self.codecRuntime
        // Freeze one value for both factories and format admission. Direct callers without
        // Connect readiness get a conservative nonjoining snapshot. NO passes nil throughout.
        let capabilities = NativeVideoCapabilitySnapshot.enabled
            ? (capabilitySnapshot ?? NativeVideoCapabilitySnapshot.current(isHost: isHost)) : nil
        let useHEVC = hevc ?? (nativeDesktopCodecs && NativeHEVCCapability.permits(isHost: isHost, snapshot: capabilities))
        let useFullColor = nativeDesktopCodecs && (hevc444 ?? NativeHEVC444Capability.permits(isHost: isHost, snapshot: capabilities))
        fullColorCaptureEnabled = isHost && useFullColor
        let fullColorFailure: () -> Void = { [weak self] in
            NativeHEVC444Capability.failed() // Fresh negotiation may use Main1 or H264, never active-byte relabeling.
            DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; self.onState?("failed") }
        }
        let hevcRun = NativeHEVCCapability.begin()
        self.hevcRun = useHEVC ? hevcRun : nil
        let codecFailure: () -> Void = { [weak self] in
            NativeHEVCCapability.failed(hevcRun) // The reconnect negotiates H264; never relabel active HEVC bytes.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { return }
                self.onState?("failed")
            }
        }
        onFirstPictureHEVCFailure = useHEVC ? codecFailure : nil
        onFirstPictureHEVC444Failure = useFullColor ? fullColorFailure : nil
        let ownedEncoderFactory = PocketDeskVideoEncoderFactory(hevc: useHEVC, hevc444: useFullColor, onHEVC444Failure: fullColorFailure, counters: counters, frameTiming: frameTimingLog, onHEVCFailure: codecFailure, videoFeedback: videoFeedback, preferLTR: videoLTR, textClarity: self.textClarity, capabilitySnapshot: capabilities)
        let ownedDecoderFactory = PocketDeskVideoDecoderFactory(hevc: useHEVC, hevc444: useFullColor, onHEVC444Failure: fullColorFailure, frameTiming: frameTimingReceiver?.log, onHEVCFailure: codecFailure, videoFeedback: videoFeedback, capabilitySnapshot: capabilities)
        var configuredFactory: RTCPeerConnectionFactory?
        #if os(macOS)
        if isHost {
            let device = FPSystemAudioDevice()
            // One ADM per peer: the shared video factories must never share captured samples.
            let factory = RTCPeerConnectionFactory(encoderFactory: nativeDesktopCodecs ? ownedEncoderFactory : RTCDefaultVideoEncoderFactory(),
                                               decoderFactory: nativeDesktopCodecs ? ownedDecoderFactory : RTCDefaultVideoDecoderFactory(),
                                               audioDevice: device)
            configuredFactory = factory
            sessionAudioFactory = factory
            withAudioLifetime { _ in systemAudioDevice = device }
            #if DEBUG
            E2EMedia.restrictToLoopbackIfNeeded(factory)
            #endif
        }
        #endif
        #if os(iOS)
        if !isHost {
            let device = PhoneSystemAudioDevice()
            device.onFailure = { [weak self] in self?.onAudioPlaybackFailure?() }
            let factory = RTCPeerConnectionFactory(encoderFactory: nativeDesktopCodecs ? ownedEncoderFactory : RTCDefaultVideoEncoderFactory(),
                                               decoderFactory: nativeDesktopCodecs ? ownedDecoderFactory : RTCDefaultVideoDecoderFactory(), audioDevice: device)
            configuredFactory = factory
            withAudioLifetime { _ in phoneAudioDevice = device }; phoneAudioFactory = factory
            #if DEBUG
            E2EMedia.restrictToLoopbackIfNeeded(factory)
            #endif
        }
        #endif
        let factory = configuredFactory ?? (nativeDesktopCodecs
            ? RTCPeerConnectionFactory(encoderFactory: ownedEncoderFactory, decoderFactory: ownedDecoderFactory)
            : Self.compatibleFactory)
        #if DEBUG
        E2EMedia.restrictToLoopbackIfNeeded(factory)
        #endif
        sessionVideoFactory = factory
        connection = factory.peerConnection(with: configuration, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        if isHost {
            let mediaStreamIDs = Self.audioVideoStreamIDs(enabled: Self.avSyncGroupEnabled,
                zeroPlayoutDelay: tuning.playoutDelayMinMs == 0 && tuning.playoutDelayMaxMs == 0, sessionID: UUID().uuidString)
            #if os(macOS)
            let audioConstraints = RTCMediaConstraints(mandatoryConstraints: [
                "googEchoCancellation": "false", "googAutoGainControl": "false",
                "googNoiseSuppression": "false", "googHighpassFilter": "false"
            ], optionalConstraints: nil)
            let audioSource = factory.audioSource(with: audioConstraints)
            let audio = factory.audioTrack(with: audioSource, trackId: "mac-system-output")
            audio.isEnabled = false
            withAudioLifetime { _ in systemAudioTrack = audio }
            let audioInit = RTCRtpTransceiverInit()
            audioInit.direction = .sendOnly
            audioInit.streamIds = mediaStreamIDs
            _ = connection?.addTransceiver(with: audio, init: audioInit)
            #endif
            let source = factory.videoSource(forScreenCast: true)
            self.source = source; capturer = RTCVideoCapturer(delegate: source)
            let track = factory.videoTrack(with: source, trackId: "desktop")
            video = track
            let videoInit = RTCRtpTransceiverInit(); videoInit.direction = .sendOnly
            videoInit.streamIds = mediaStreamIDs
            _ = connection?.addTransceiver(with: track, init: videoInit)
            let config = RTCDataChannelConfiguration(); config.isOrdered = true
            controlLock.lock()
            channel = connection?.dataChannel(forLabel: "control", configuration: config)
            controlLock.unlock()
            channel?.delegate = self
            if fileChannel {
                // A separate ordered channel bounds file buffering independently. Older
                // phones close any channel not labelled "control", which leaves their session untouched.
                let fileConfig = RTCDataChannelConfiguration(); fileConfig.isOrdered = true
                let file = connection?.dataChannel(forLabel: Self.fileChannelLabel, configuration: fileConfig)
                file?.delegate = self
                self.fileChannel = file
            }
        }
    }
    func offer() {
        guard configureRepairPreferences() else { return }
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
    var repairPreferenceFailureForTesting = false
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

    // Stereo is on in Roshan's combined .7 device test (3 Oct); explicit NO restores the legacy policy.
    // The A/V sync group stays opt-in: it lets libwebrtc hold desktop video for audio, and smoothness is
    // the product's first complaint, so it waits for a glass-to-glass measurement. Snapshot once per process.
    private static let opusStereoEnabled = audioExperimentEnabled("PocketDeskOpusStereo", unsetReadsOn: true)
    private static let avSyncGroupEnabled = audioExperimentEnabled("PocketDeskAVSyncGroup", unsetReadsOn: false)
    static func audioExperimentEnabled(_ key: String, unsetReadsOn: Bool, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? unsetReadsOn : defaults.bool(forKey: key)
    }

    @objc(opusSDP:sender:enabled:)
    static func opusSDP(_ sdp: String, sender: Bool, enabled: Bool) -> String {
        guard enabled else { return sdp }
        let newline = sdp.contains("\r\n") ? "\r\n" : "\n"
        var sections: [[String]] = [[]]
        for line in sdp.components(separatedBy: newline) {
            if line.hasPrefix("m=") { sections.append([]) }
            sections[sections.count - 1].append(line)
        }
        for index in sections.indices {
            var lines = sections[index]
            guard let media = lines.first, media.hasPrefix("m=audio ") else { continue }
            let fields = media.split(separator: " ")
            guard fields.count >= 4, fields[1] != "0" else { continue }
            let offered = Set(fields.dropFirst(3).map(String.init))
            let payloads = lines.compactMap { line -> String? in
                guard line.hasPrefix("a=rtpmap:") else { return nil }
                let fields = line.dropFirst("a=rtpmap:".count).split(separator: " ")
                guard fields.count == 2, fields[1].lowercased() == "opus/48000/2",
                      offered.contains(String(fields[0])) else { return nil }
                return String(fields[0])
            }
            guard !payloads.isEmpty else { continue }
            // RFC7587: sprop-* describes this sender. All other hints describe this receiver.
            // Keep FEC and unrelated codec parameters; never rewrite video/DTMF payloads.
            let policy: [(String, String)] = sender
                ? [("sprop-stereo", "1"), ("sprop-maxcapturerate", "48000")]
                : [("stereo", "1"), ("maxplaybackrate", "48000"), ("maxaveragebitrate", "128000"),
                   ("cbr", "0"), ("usedtx", "0")]
            let keys = Set(policy.map { $0.0 })
            for payload in payloads {
                let prefix = "a=fmtp:\(payload) "
                let existing = lines.firstIndex { $0.hasPrefix(prefix) }
                var parameters = existing.map { lines[$0].dropFirst(prefix.count).components(separatedBy: ";") } ?? []
                parameters = parameters.map { $0.trimmingCharacters(in: .whitespaces) }.filter {
                    !$0.isEmpty && !keys.contains($0.split(separator: "=", maxSplits: 1).first?.lowercased() ?? "")
                }
                parameters += policy.map { "\($0.0)=\($0.1)" }
                let fmtp = prefix + parameters.joined(separator: ";")
                if let existing { lines[existing] = fmtp }
                else { lines.insert(fmtp, at: lines.firstIndex(of: "") ?? lines.endIndex) }
            }
            if !sender {
                lines.removeAll { $0.hasPrefix("a=ptime:") }
                lines.insert("a=ptime:20", at: lines.firstIndex(of: "") ?? lines.endIndex)
            }
            sections[index] = lines
        }
        return sections.flatMap { $0 }.joined(separator: newline)
    }

    /// A shared stream ID asks libwebrtc to synchronise video playout to audio; under the tuned forced
    /// 0/0 playout delay that would only add video lag, so the group is never formed there.
    static func audioVideoStreamIDs(enabled: Bool, zeroPlayoutDelay: Bool = false, sessionID: String) -> [String] {
        enabled && !zeroPlayoutDelay ? [sessionID] : []
    }

    private func setLocal(_ description: RTCSessionDescription?, error: Error?) {
        guard !closed, let description, error == nil else { onState?("failed"); return }
        let local = Self.opusStereoEnabled
            ? RTCSessionDescription(type: description.type, sdp: Self.opusSDP(description.sdp, sender: isHost, enabled: true))
            : description
        connection?.setLocalDescription(local) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                guard error == nil else { self.onState?("failed"); return }
                self.onSignal?(MediaSignal(kind: local.type == .offer ? "offer" : "answer", sdp: local.sdp))
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
                self.resourceBudget.observePeerMaxMessageSize(BulkAdmissionPolicy.maxMessageSize(sdp: sdp))
                self.remoteDescriptionReady = true
                self.remoteDescriptionsApplied += 1
                self.configureNativeSender()
                for candidate in self.candidates { self.connection?.add(candidate, completionHandler: { _ in }) }
                self.candidates.removeAll()
                if signal.kind == "offer" {
                    guard self.configureRepairPreferences() else { return }
                    self.connection?.answer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"], optionalConstraints: nil)) { [weak self] description, error in
                        DispatchQueue.main.async { self?.setLocal(description, error: error) }
                    }
                }
                self.observeRemoteAudio()
                if let track = self.connection?.receivers.compactMap({ $0.track as? RTCVideoTrack }).first {
                    self.observeRemoteVideo(track)
                    if self.localGateOpen() { self.onRemoteVideo?(track) }
                }
            }
        }
    }
    private(set) var repairCodecNegotiationRequested = false
    private var repairOfferPending = false
    private var lastRepairPolicy: Bool?
    private func configureRepairPreferences() -> Bool {
        guard !closed, let factory = sessionVideoFactory, let connection else { return false }
        let allow = isHost ? PacketRepairPreferences.maySend(native: nativeDesktopCodecs, provenLocal: localLink != nil, selectedRelay: selectedRepairRelay) : nativeDesktopCodecs && localLink == nil
        let capabilities = isHost ? factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo) : factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
        let codecs = capabilities.codecs.filter { allow || $0.name.lowercased() != "flexfec-03" }
        guard !codecs.isEmpty else { return retireRepairPreferenceFailure() }
        var applied = false
        for transceiver in connection.transceivers where transceiver.mediaType == .video {
            #if DEBUG
            if repairPreferenceFailureForTesting { return retireRepairPreferenceFailure() }
            #endif
            do { try transceiver.setCodecPreferences(codecs, error: ()); applied = true }
            catch { return retireRepairPreferenceFailure() } // Old/default preferences may still contain forbidden FEC.
        }
        lastRepairPolicy = allow
        repairCodecNegotiationRequested = allow && applied && codecs.contains { $0.name.lowercased() == "flexfec-03" }
        return applied
    }
    private func retireRepairPreferenceFailure() -> Bool {
        repairCodecNegotiationRequested = false; repairOfferPending = false
        let callback = onState
        close() // Fence capture and stop RTP before reporting a failed policy application.
        callback?("failed")
        return false
    }
    private var selectedRepairRelay: Bool {
        #if DEBUG
        if let routeOverrideForTesting { return routeOverrideForTesting == "Relay" }
        #endif
        return lastRoute == "Relay" // Requested/forced ICE policy alone is not an observed selected route.
    }
    private func followRepairRoute() {
        guard isHost, nativeDesktopCodecs, localLink == nil, PacketRepairPreferences.activeThisLaunch, !closed,
              remoteDescriptionReady, let connection else { return }
        let desired = selectedRepairRelay
        guard desired != lastRepairPolicy else { return }
        if connection.signalingState != .stable { repairOfferPending = true; return }
        repairOfferPending = false; offer() // Public codec preferences renegotiation; no ICE generation rewrite.
    }
    private let lowDataLock = NSLock()
    private var constrainedMedia = false
    var lowDataPolicyActive: Bool {
        lowDataLock.lock(); defer { lowDataLock.unlock() }; return constrainedMedia
    }
    /// Main queue, both sides. The sender ceiling and bulk budget restore without changing quality.
    func applyLowDataPolicy(_ active: Bool) {
        lowDataLock.lock()
        let changed = constrainedMedia != active
        constrainedMedia = active
        lowDataLock.unlock()
        guard changed else { return }
        resourceBudget.observeLowData(active: active)
        if active {
            requestRefinementCapture(false)
            configureVideoRefinement(enabled: false, geometry: 1, scope: 1)
        }
        if isHost, !closed, remoteDescriptionReady { configureNativeSender() }
    }

    private func configureNativeSender() {
        guard isHost, nativeDesktopCodecs, let sender = connection?.senders.first(where: { $0.track?.kind == "video" }) else { return }
        let parameters = sender.parameters
        let ceiling = LowDataPolicy.ceiling(tuning.qualityBitrates ? tuning.maximumBitrateBps(for: streamQuality) : 12_000_000, active: lowDataPolicyActive)
        let rate = currentSenderRate
        for encoding in parameters.encodings {
            encoding.networkPriority = transportPriority.networkPriority
            encoding.maxFramerate = NSNumber(value: rate.maxFramerate)
            encoding.maxBitrateBps = NSNumber(value: ceiling)
        }
        if let preference = rate.degradationPreference {
            parameters.degradationPreference = NSNumber(value: preference.rawValue)
        } else if appliedRate?.degradationPreference != nil {
            parameters.degradationPreference = nil
        }
        sender.parameters = parameters
        appliedRate = rate
        if tuning.qualityBitrates {
            let maximum = bandwidthCeilingBps
            _ = connection?.setBweMinBitrateBps(lanFloorBps.map { NSNumber(value: min($0, maximum)) }, currentBitrateBps: nil,
                                                 maxBitrateBps: NSNumber(value: maximum))
            appliedBweMaxBps = maximum
        }
    }

    /// The estimate ceiling for the current picture mode and route class (`BandwidthCeilingPolicy`).
    private var bandwidthCeilingBps: Int {
        let ceiling = tuning.maximumBitrateBps(for: streamQuality)
        if lowDataPolicyActive { return LowDataPolicy.ceiling(ceiling, active: true) }
        return BandwidthCeilingPolicy.maxBitrateBps(ceiling: ceiling,
            route: ceilingRoute.route, provenLocal: ceilingRoute.provenLocal, tuning: tuning)
    }

    /// X05: whether the LAN ceiling multiplier is what the estimate ceiling carries right now.
    private var lanCeilingApplied: Bool {
        !lowDataPolicyActive && BandwidthCeilingPolicy.lanMultiplier(route: ceilingRoute.route, provenLocal: ceilingRoute.provenLocal, tuning: tuning) > 1
            && appliedBweMaxBps == bandwidthCeilingBps
    }

    /// Re-applies the ceiling when the route class or the local proof changed (LAN multiplier on, or back
    /// off after an ICE restart onto relay or a cut local path). The current estimate is left alone, so
    /// nothing is re-seeded.
    private func followCeilingRoute(detail: String?, rttMs: Double?) {
        guard isHost, nativeDesktopCodecs, tuning.qualityBitrates,
              ceilingRoute.observe(detail: detail, rttMs: rttMs, provenLocal: provenLocalLinkActive),
              !closed, remoteDescriptionReady else { return }
        let maximum = bandwidthCeilingBps
        guard maximum != appliedBweMaxBps else { return }
        _ = connection?.setBweMinBitrateBps(lanFloorBps.map { NSNumber(value: min($0, maximum)) }, currentBitrateBps: nil,
                                             maxBitrateBps: NSNumber(value: maximum))
        appliedBweMaxBps = maximum
    }

    /// The `LANBitrateFloor` in force, nil while the link is not trusted. Every bitrate-settings call
    /// carries the floor and the ceiling together: libwebrtc keeps the last settings as a whole.
    private var lanFloorBps: Int?
    private var lanTrust = LANTrustTracker()
    private var lastRoundTripMeasurements: Double?

    /// Judges the link once a second (RTCP round trip when there is one, the STUN one otherwise) and
    /// publishes the verdict; the floor is on while trusted and back to libwebrtc's own minimum the
    /// sample it is not, never above the ceiling, and follows a changed start rate.
    private func followLANFloor(_ stats: inout StreamStatsReport) {
        guard isHost, nativeDesktopCodecs, !closed else { return }
        // An RTCP round trip repeats until the next receiver report; a repeat is not a second strike.
        // Only an RTCP reading can be a repeat; a STUN fallback sample is always its own reading.
        let fresh = stats.rtcpRttMs == nil || stats.rtcpRttMeasurements.map { $0 != lastRoundTripMeasurements } ?? true
        if stats.rtcpRttMs != nil { lastRoundTripMeasurements = stats.rtcpRttMeasurements }
        let trusted = lanTrust.observe(provenLocalLink: provenLocalLinkActive, lossPercent: stats.remoteLossPercent,
                                       rttMs: stats.rtcpRttMs ?? stats.rttMs, roundTripFresh: fresh,
                                       pacerDelayMs: stats.pacerDelayMs)
        stats.lanTrusted = trusted
        guard tuning.qualityBitrates, remoteDescriptionReady,
              var floor = LANBitrateFloor.bps(startBitrateBps: streamQuality.startBitrateBps(for: .lan)) else { return }
        if let maximum = appliedBweMaxBps { floor = min(floor, maximum) }
        let next = trusted ? floor : nil
        guard next != lanFloorBps else { return }
        _ = connection?.setBweMinBitrateBps(NSNumber(value: next ?? 0), currentBitrateBps: nil,
                                             maxBitrateBps: appliedBweMaxBps.map { NSNumber(value: $0) })
        lanFloorBps = next
    }

    /// G5: the capture session's target rate and display. Written on the main queue under
    /// `captureLock`, because `pushFrame` reads the rate and the ladder on the capture queue.
    private(set) var targetFPS = CaptureRatePolicy.standardFPS
    private var exactCaptureResolution = false
    private(set) var displayRefreshHz: Double?
    private(set) var captureDisplay: String?
    /// G12: the rung last applied with `applyLadder`, nil after a capture (re)start.
    private(set) var ladderState: LadderState?
    /// Host: what the Mac reports on `capture` status, copied into every statistics sample.
    var busyState: BusyState?
    /// Host: the X17 governor's status from the load monitor, copied into every statistics sample.
    var senderQueueGovernorStatus: String?
    var senderQueueGovernorShedding = false
    var captureRegion: CaptureRegion?
    var captureSharpness: Double?

    private var currentSenderRate: SenderRateParameters {
        SenderRateParameters.make(targetFPS: targetFPS, tuning: tuning, ladderFPS: ladderState?.fps,
                                  quality: streamQuality,
                                  legacyPictureSettings: UserDefaults.standard.bool(forKey: PictureMode.legacyKey),
                                  exactResolution: exactCaptureResolution)
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
    func applyCaptureRate(targetFPS: Int, displayRefreshHz: Double?, display: String?, exactResolution: Bool = false) {
        let fps = max(1, targetFPS)
        captureLock.lock()
        if fps != self.targetFPS { adaptedFormat = nil }
        self.targetFPS = fps
        exactCaptureResolution = exactResolution
        ladderState = nil
        captureLock.unlock()
        observeLadder(nil)
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
        observeLadder(applied)
        reconfigureSenderRate()
    }

    /// DF10: the host's own rung, or on the phone the Mac's rung from its capture status. A step down backs files off.
    func observeLadder(_ state: LadderState?) {
        resourceBudget.observeLadder(steppedDown: (state?.rung ?? 0) > 0)
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

    /// A resume after the phone's background pause starts the estimate near libwebrtc's minimum
    /// (1 Oct 2026: target 33 kbps, a 3.1 s pacer queue, 2-9 sent fps for 12 s), and both seed
    /// attempts were spent at session start. Arms the seed again for the resumed stream on a proven
    /// local link only: off the LAN the seed rate could exceed the path.
    func rearmBandwidthSeed() {
        guard BandwidthSeedRearmSwitch.isOn, provenLocalLinkActive else { return }
        bandwidthSeed = BandwidthSeedPolicy()
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
        let maximum = bandwidthCeilingBps
        let seed = min(seedBps, maximum)
        _ = connection?.setBweMinBitrateBps(lanFloorBps.map { NSNumber(value: min($0, seed)) },
                                             currentBitrateBps: NSNumber(value: seed), maxBitrateBps: NSNumber(value: maximum))
        appliedBweMaxBps = maximum
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

    /// Host: the network priority actually set on the video sender's encodings.
    var appliedNetworkPriority: RTCPriority? {
        guard isHost, let sender = connection?.senders.first(where: { $0.track?.kind == "video" }) else { return nil }
        return sender.parameters.encodings.first?.networkPriority
    }

    /// Host: the degradation preference actually applied to the video sender.
    var appliedDegradationPreference: RTCDegradationPreference? {
        guard isHost, let sender = connection?.senders.first(where: { $0.track?.kind == "video" }) else { return nil }
        return sender.parameters.degradationPreference.flatMap { RTCDegradationPreference(rawValue: $0.intValue) }
    }

    /// Host: the newest sender summary, returned once so the capture heartbeat forwards each sample once.
    func takeHostSummary() -> HostStreamSummary? {
        defer { latestHostSummary = nil }
        guard var summary = latestHostSummary else { return nil }
        if nativeDesktopCodecs && tuning.encoderRestart {
            summary.framesEncodedTotal = min(counters.encodedTotal, HostStreamSummary.maximumFrameTotal)
        }
        summary.macLink = MacNetworkLink.resolve(localAddress: selectedLocalAddress,
            candidateType: selectedLocalCandidateType, addresses: MacNetworkLink.interfaceAddresses(),
            interfaces: linkInterfaces)?.rawValue
        return summary
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

    static let fileChannelLabel = "file"

    private var openFileChannel: RTCDataChannel? {
        fileLock.lock(); defer { fileLock.unlock() }
        guard let fileChannel, fileChannel.readyState == .open else { return nil }
        return fileChannel
    }

    var fileChannelOpen: Bool { openFileChannel != nil }

    /// True when the selected route runs through a TURN relay.
    var isRelayRoute: Bool { needsRelayRefresh }

    var controlBufferedAmount: UInt64? {
        controlLock.lock(); defer { controlLock.unlock() }
        guard let channel, channel.readyState == .open else { return nil }
        return channel.bufferedAmount
    }
    /// Control plus pointer queues: bulk yields to either kind of input.
    private var inputBufferedAmount: UInt64? {
        guard let control = controlBufferedAmount else { return nil }
        pointerLock.lock(); let pointer = pointerEnded ? nil : pointerChannel; pointerLock.unlock()
        guard let pointer, pointer.readyState == .open else { return control }
        let (total, overflow) = control.addingReportingOverflow(pointer.bufferedAmount)
        return overflow ? nil : total
    }
    /// `displayMs` is the frame's ScreenCaptureKit display time in mach ms, 0 for a re-send.
    func pushFrame(_ buffer: CVPixelBuffer, timeStampNs: Int64, displayMs: Double = 0, exactTiming: ExactVideoTiming? = nil,
                   region: CaptureRegion? = nil) {
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
        videoFeedback.pushedTiming(exactTiming, buffer: output)
        videoFeedback.pushedRegion(region, buffer: output)
        frameTimingLog?.pushed(ObjectIdentifier(output), displayMs: displayMs, pushMs: MachClock.nowMs())
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
                self.selectedLocalAddress = localAddress
                self.selectedLocalCandidateType = localType
                let adapterType = local?.values["networkAdapterType"] as? String
                let networkType = local?.values["networkType"] as? String
                let vpn = (local?.values["vpn"] as? NSNumber)?.boolValue
                if pair != nil {
                    let pairLog = MediaRoute.publicPairSummary(local: localType, remote: remoteType,
                                                              adapter: adapterType, network: networkType)
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
                        SessionLog.log.error("\(self.role, privacy: .public) media failed: selected pair is not the proven local link (\(self.lastPairLog ?? "?", privacy: .public))")
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
                self.followRepairRoute()
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
        recoverUndecodableFirstPicture(entries)
        guard !closed else { return }
        let counts = counters.drain(inputBufferedBytes: controlBufferedAmount)
        var stats = StreamStatsReport(role: isHost ? "host" : "phone", previous: previousSample,
                                      current: sample, counters: previousSample == nil ? nil : counts)
        stats.captureMaximumDimension = captureMaximumDimension
        stats.tuning = tuning.liveSummary
        stats.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        stats.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        stats.lowDataPolicyActive = lowDataPolicyActive
        let transport = entries.first { $0.type == "transport" && $0.string("selectedCandidatePairId") == sample.pair?.id }
        let transportRate = guestTransportSampler.sample(identity: transport.flatMap { item in sample.pair.map { item.id + "/" + $0.id } },
            timestamp: transport?.timestamp, bytesSent: transport?.number("bytesSent"), rttMs: stats.rttMs)
        let observedAt = ProcessInfo.processInfo.systemUptime
        stats.transportUsage = transportUsageSampler.sample(identity: transport.flatMap { item in sample.pair.map { item.id + "/" + $0.id } },
            timestamp: transport?.timestamp, bytesSent: transport?.number("bytesSent"), bytesReceived: transport?.number("bytesReceived"), at: observedAt)
        stats.transportUsage?.mediaByEntry = TransportByteSplit.media(entries)
        stats.transportUsage?.fileByEntry = TransportByteSplit.files(entries, label: Self.fileChannelLabel)
        if isHost {
            onGuestTransportStatistics?(GuestTransportObservation(at: observedAt, totalKbps: transportRate.kbps,
                capacityKbps: stats.availableOutgoingKbps, rttMs: stats.rttMs, baselineRTTMs: transportRate.baselineRTT,
                pacerDelayMs: stats.pacerDelayMs, controlBufferedBytes: controlBufferedAmount))
        }
        let senderMaxKbps = isHost ? appliedSenderMaxKbps : nil
        resourceBudget.observe(MediaCapacityObservation(at: observedAt,
            // A receive-only phone has no outbound-video GCC estimate for its file uploads.
            // The transport's camera bootstrap estimate is not observed upload capacity.
            route: sample.route, capacityKbps: isHost ? stats.availableOutgoingKbps : nil,
            videoKbps: transportRate.kbps ?? stats.sentKbps, totalTransportKbps: transportRate.kbps, rttMs: stats.rttMs, pacerDelayMs: stats.pacerDelayMs,
            routeDetail: sample.routeDetail, rttSampleMs: stats.rttSampleMs, senderMaxKbps: senderMaxKbps,
            senderQueueMs: isHost ? stats.senderQueueMs : nil, governorDegraded: isHost && senderQueueGovernorShedding))
        if isHost {
            if nativeDesktopCodecs {
                stats.targetFPS = targetFPS
                stats.displayRefreshHz = displayRefreshHz
                stats.captureDisplay = captureDisplay
                stats.ladder = ladderState
                stats.busy = busyState
                stats.captureRegion = captureRegion
                stats.sharpness = captureSharpness
                stats.senderQueueGovernor = senderQueueGovernorStatus
            }
            stats.maxKbps = appliedSenderMaxKbps
            if nativeDesktopCodecs { stats.transportPriorityRequested = transportPriority.summary }
            followCeilingRoute(detail: sample.routeDetail, rttMs: stats.rttMs)
            seedBandwidthEstimate(stats, route: sample.route, detail: sample.routeDetail)
            followLANFloor(&stats)
            stats.networkQueueMs = SenderQueueEstimate.networkQueueMs(rttMs: stats.rttMs, baselineRTTMs: transportRate.baselineRTT)
                .map { ($0 * 10).rounded() / 10 }
            if nativeDesktopCodecs && tuning.qualityBitrates {
                stats.bweCeilingKbps = appliedBweMaxBps.map { Double($0) / 1000 }
                stats.lanCeilingApplied = lanCeilingApplied
                stats.lanFloorKbps = lanFloorBps.map { Double($0) / 1000 }
            }
            let frameTiming = frameTimingLog?.drain()
            if let frameTiming { stats.applyHostFrameTiming(frameTiming) }
            latestHostSummary = stats.hostSummary
            if let frameTiming { latestHostSummary?.applyFrameTiming(frameTiming) }
        } else {
            stats.host = remoteHostSummary
            stats.host?.frameRecords = nil
            if let frameTiming = frameTimingReceiver?.drain() { stats.applyPhoneFrameTiming(frameTiming) }
            if let exact = videoFeedback.drainTiming() { stats.applyExactVideoTiming(exact) }
            stats.hostFramesEncodedTotal = remoteFrameMark?.hostEncoded
            stats.framesArrivedAtMark = remoteFrameMark?.phoneArrived
            stats.frameMarkAt = remoteFrameMark?.at
            stats.hostSummaryAgeMs = remoteHostSummaryAt.map { ((ProcessInfo.processInfo.systemUptime - $0) * 10_000).rounded() / 10 }
        }
        previousSample = sample
        if isHost || onStreamStatistics == nil { StreamDebug.record(stats) }
        onStreamStatistics?(stats)
        if isHost { onSenderStatistics?(stats) }
    }

    static func firstPictureDecodeObservation(_ entries: [StreamStatsEntry]) -> HEVCDecodeWatchdog.Observation? {
        if let inbound = entries.first(where: { $0.type == "inbound-rtp" && $0.isVideo }),
           let codecID = inbound.string("codecId"),
           let codec = entries.first(where: { $0.type == "codec" && $0.id == codecID }),
           let negotiated = HEVCDecodeWatchdog.Codec.negotiated(mimeType: codec.string("mimeType"), fmtp: codec.string("sdpFmtpLine")),
           let received = inbound.number("framesReceived"), let decoded = inbound.number("framesDecoded") {
            return HEVCDecodeWatchdog.Observation(identity: .init(inboundID: inbound.id, codecID: codecID, codec: negotiated),
                timestamp: inbound.timestamp, framesReceived: received, framesDecoded: decoded)
        }
        return nil
    }

    private func recoverUndecodableFirstPicture(_ entries: [StreamStatsEntry]) {
        guard !closed, !isHost, nativeDesktopCodecs, connectedPublished else { return }
        guard let failedCodec = hevcDecodeWatchdog.observe(Self.firstPictureDecodeObservation(entries)) else { return }
        let failure = failedCodec == .fullColor444 ? onFirstPictureHEVC444Failure : onFirstPictureHEVCFailure
        guard let failure else { return }
        SessionLog.log.error("\(self.role, privacy: .public) first picture recovery: \(failedCodec.rawValue, privacy: .public) received frames for 5 s without decoding")
        failure() // Existing terminal path negotiates a fresh authorized session with the failed codec disabled.
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
        for message in held {
            guard !closed, localGateOpen() else { return }
            lastControlArrivedFrames = message.arrivedFrames
            lastControlArrivedAt = message.arrivedAt
            arrivalLock.lock(); lastControlArrivalMs = message.arrivedMs; arrivalLock.unlock()
            onControl?(message.data)
            arrivalLock.lock(); lastControlArrivalMs = nil; arrivalLock.unlock()
        }
    }

    /// Lock order for input: executor authority → local route → control lifetime.
    /// A route cut/close cannot pass the final check while a CGEvent is being posted.
    func withInputPostingAuthority<T>(_ post: () -> T) -> T? {
        localRouteLock.lock(); defer { localRouteLock.unlock() }
        controlLock.lock(); defer { controlLock.unlock() }
        guard localLink == nil || localPathAuthorized,
              let channel, channel.readyState == .open else { return nil }
        return post()
    }

    private var localPathNeverAuthorized: Bool {
        localRouteLock.lock(); defer { localRouteLock.unlock() }
        return !localPathEverAuthorized
    }

    func close() {
        fileReceiveLease.retire()
        if let hevcRun { NativeHEVCCapability.ended(hevcRun) }
        videoFeedback.end()
        let retireRefinement = { () -> RTCDataChannel? in
            self.refinementPipe.end()
            self.refinementLock.lock(); self.refinementEnded = true
            let retired = self.refinementChannel; self.refinementChannel = nil; self.refinementLock.unlock()
            return retired
        }
        let refinement = DispatchQueue.getSpecific(key: refinementQueueKey) != nil ? retireRefinement() : refinementQueue.sync(execute: retireRefinement)
        refinement?.delegate = nil; refinement?.close()
        refinementTimer?.cancel(); refinementTimer = nil
        pointerLock.lock(); pointerEnded = true; pointerAllowed = false; pendingPointer = nil
        let pointer = pointerChannel; pointerChannel = nil; pointerLock.unlock()
        pointer?.delegate = nil; pointer?.close()
        resourceBudget.end()
        linkMonitor?.cancel(); linkMonitor = nil
        let retiredAudioTracks: [RTCAudioTrack] = withAudioLifetime { _ in
            // Fence queued native PCM/render blocks before detaching stored references.
            var retired = remoteAudioTrack.map { [$0] } ?? []
            audioClosed = true
            #if os(iOS)
            phoneAudioDevice?.setConsent(false); phoneAudioDevice = nil
            #endif
            remoteAudioTrack = nil
            #if os(macOS)
            systemAudioDevice?.setConsent(false); systemAudioDevice = nil
            if let systemAudioTrack { retired.append(systemAudioTrack) }
            systemAudioTrack = nil
            #endif
            return retired
        }
        // Production teardown is main-thread owned; device consent above fences PCM immediately.
        if Thread.isMainThread { retiredAudioTracks.forEach { $0.isEnabled = false } }
        else { DispatchQueue.main.async { retiredAudioTracks.forEach { $0.isEnabled = false } } }
        preGateControl.removeAll(); preGateBytes = 0
        statisticsTimer?.invalidate(); statisticsTimer = nil
        if let cadenceRenderer { observedTrack?.remove(cadenceRenderer) }
        cadenceRenderer = nil; observedTrack = nil
        captureLock.lock(); closed = true; source = nil; capturer = nil; frameTransform = nil; captureLock.unlock()
        controlLock.lock(); let control = channel; channel = nil; controlLock.unlock()
        control?.delegate = nil; control?.close()
        fileLock.lock(); let file = fileChannel; fileChannel = nil; fileLock.unlock()
        file?.delegate = nil; file?.close()
        connection?.delegate = nil; connection?.close(); connection = nil
        candidates.removeAll(); video = nil
        videoFeedback.end()
        sessionVideoFactory = nil
        #if os(iOS)
        phoneAudioFactory = nil
        #endif
        #if os(macOS)
        sessionAudioFactory = nil
        #endif
    }
}
extension PeerMedia: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        guard stateChanged == .stable else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            if self.restartPending { self.restartICE() }
            else if self.repairOfferPending { self.followRepairRoute() }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.observeRemoteAudio()
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
    func peerConnection(_ peerConnection: RTCPeerConnection, didChangeStandardizedIceConnectionState newState: RTCIceConnectionState) {
        standardizedICE = newState
    }
    /// DTLS checks the peer's certificate against the remote description's fingerprint, which only the
    /// paired peer can seal. A mismatch fails the connection while ICE itself has not failed, and the legacy
    /// ICE state never reaches connected without DTLS, so the ICE handler never reports it; without this
    /// the session would sit until the handshake timer.
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        guard newState == .failed, standardizedICE != .failed, standardizedICE != .closed else { return }
        SessionLog.log.error("\(self.role, privacy: .public) media failed: DTLS failed while ICE had not")
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            // The certificate is checked only at the handshake; a DTLS failure after connecting is an ordinary drop.
            self.dtlsRejected = !self.connectedPublished
            self.onState?("failed")
        }
    }
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
        if dataChannel.label == Self.refinementChannelLabel {
            if !adoptRefinementChannel(dataChannel) { dataChannel.delegate = nil; dataChannel.close() }; return
        }
        if dataChannel.label == Self.pointerChannelLabel {
            if !adoptPointerChannel(dataChannel) { dataChannel.delegate = nil; dataChannel.close() }
            return
        }
        if dataChannel.label == Self.fileChannelLabel, adoptFileChannel(dataChannel) { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, dataChannel.label == "control", self.channel == nil else {
                dataChannel.delegate = nil; dataChannel.close(); return
            }
            self.controlLock.lock(); self.channel = dataChannel; self.controlLock.unlock()
            if dataChannel.readyState == .open {
                self.localPathStartedAt = ProcessInfo.processInfo.systemUptime
                self.startDiagnostics(); self.publishConnectedIfReady()
            }
        }
    }
}
extension PeerMedia: FileChannelLink {
    /// Phone: adopts the host's `file` channel synchronously, so no early chunk finds it unowned.
    fileprivate func adoptFileChannel(_ dataChannel: RTCDataChannel) -> Bool {
        fileLock.lock(); defer { fileLock.unlock() }
        guard !isHost, acceptsFileChannel, fileChannel == nil, dataChannel.isOrdered else { return false }
        fileChannel = dataChannel
        return true
    }

    fileprivate func isFileChannel(_ dataChannel: RTCDataChannel) -> Bool {
        fileLock.lock(); defer { fileLock.unlock() }
        return fileChannel === dataChannel
    }

    /// Lock order: transfer effect → local route → file channel lifetime. Native observer callbacks
    /// enqueue owner work; they must never synchronously call a native send while inside a callback.
    func sendFile(_ data: Data) -> Bool {
        guard data.count <= FileTransferLimits.maximumOutgoingMessageBytes else { return false }
        let message = RTCDataBuffer(data: data, isBinary: true)
        return withNativeRouteSubmissionAuthority {
            fileLock.lock(); defer { fileLock.unlock() }
            guard let fileChannel, fileChannel.readyState == .open else { return false }
            return fileChannel.sendData(message)
        } ?? false
    }

    var fileBufferedAmount: UInt64? { openFileChannel?.bufferedAmount }

    func permitsFileSend(bytes: Int, at now: TimeInterval) -> Bool {
        guard localGateOpen() else { return false }
        return resourceBudget.permits(bytes: bytes, at: now,
            controlBuffered: inputBufferedAmount, fileBuffered: fileChannelOpen ? aggregateBulkBuffered : nil)
    }

    func fileMessageBytes(at now: TimeInterval) -> Int { resourceBudget.messageBytes(at: now) }

    func fileQueueBytes(at now: TimeInterval) -> UInt64 { resourceBudget.queueBytes(at: now) }
}
extension PeerMedia: RTCDataChannelDelegate {
    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        if isRefinementChannel(dataChannel) { onFileBufferedAmountChange?(); return }
        guard isFileChannel(dataChannel) else { return }
        onFileBufferedAmountChange?()
    }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if isRefinementChannel(dataChannel) {
            refinementQueue.async { [weak self] in self?.retireClosedRefinementChannel(dataChannel) }
            return
        }
        if isPointerChannel(dataChannel) { return }
        if isFileChannel(dataChannel) {
            if dataChannel.readyState == .closed { onFileBufferedAmountChange?() }
            return
        }
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
        let arrivedMs = MachClock.nowMs()
        if isRefinementChannel(dataChannel) {
            guard buffer.isBinary, buffer.data.count <= BulkAdmissionPolicy.maximumMessageBytes, localGateOpen(),
                  let packet = try? JSONDecoder().decode(VideoRefinementChunk.self, from: buffer.data), packet.ack == isHost else { return }
            refinementQueue.async { [weak self] in
                guard let self, self.localGateOpen() else { return }
                self.refinementPipe.receive(buffer.data, at: ProcessInfo.processInfo.systemUptime)
            }
            return
        }
        if isPointerChannel(dataChannel) {
            if buffer.isBinary { receivePointer(buffer.data, arrivedMs: arrivedMs) }
            return
        }
        if isFileChannel(dataChannel) {
            guard buffer.isBinary, buffer.data.count <= FileTransferLimits.maximumMessageBytes, localGateOpen() else { return }
            deliverFileMessage(buffer.data)
            return
        }
        let arrivedFrames = counters.arrivedTotal
        let arrivedAt = ProcessInfo.processInfo.systemUptime
        if PeerControlIngress.processEnabled {
            // didOpen schedules adoption before any early delivery. Until then only a valid
            // control candidate may enter; once adopted, stale/foreign channels cannot spend
            // this peer's budget or trigger its terminal failure.
            controlLock.lock()
            let permitted = PeerControlIngress.permitsSource(current: channel, source: dataChannel,
                label: dataChannel.label, ordered: dataChannel.isOrdered, reliable: dataChannel.isReliable)
            controlLock.unlock()
            guard permitted else { return }
        }
        let ingress = PeerControlIngress.forPeer(self) { [weak self] in
            PeerControlIngress(schedule: { DispatchQueue.main.async(execute: $0) }, deliver: { [weak self] value in
                guard let dataChannel = value.source as? RTCDataChannel else { return }
                guard let self, !self.closed, self.channel === dataChannel else { return }
                self.controlCounters.received += 1
                guard self.localGateOpen() else {
                    if self.localLink != nil, self.localPathNeverAuthorized, self.preGateControl.count < 64,
                       self.preGateBytes + value.data.count <= 256 * 1024 {
                        self.preGateControl.append((value.data, value.frames, value.at, value.ms)); self.preGateBytes += value.data.count
                        self.controlCounters.heldBeforeGate += 1
                        InputLog.log.info("\(self.role, privacy: .public) control held until local path authorization (\(self.preGateControl.count, privacy: .public) held)")
                    } else {
                        self.controlCounters.droppedAtGate += 1
                        if self.localLink != nil, self.localPathNeverAuthorized {
                            PeerControlIngress.refusePeer(self) // Never authorize a reliable prefix with holes.
                        }
                        if InputLog.sampled(self.controlCounters.droppedAtGate) {
                            InputLog.log.error("\(self.role, privacy: .public) control dropped at local gate count=\(self.controlCounters.droppedAtGate, privacy: .public)")
                        }
                    }
                    return
                }
                if InputLog.sampled(self.controlCounters.received) {
                    InputLog.log.info("\(self.role, privacy: .public) received control #\(self.controlCounters.received, privacy: .public)")
                }
                self.lastControlArrivedFrames = value.frames
                self.lastControlArrivedAt = value.at
                self.arrivalLock.lock(); self.lastControlArrivalMs = value.ms; self.arrivalLock.unlock()
                defer { self.arrivalLock.lock(); self.lastControlArrivalMs = nil; self.arrivalLock.unlock() }
                self.onControl?(value.data)
            }, fail: { [weak self] value in
                guard let self else { return }
                if let value { // Exact legacy invalid-message path when the switch is NO.
                    guard let dataChannel = value.source as? RTCDataChannel, self.channel === dataChannel else { return }
                } else {
                    guard !self.closed else { return }
                    self.controlCounters.droppedAtGate += 1
                }
                self.onState?("failed")
            })
        }
        ingress.offer(.init(data: buffer.data, frames: arrivedFrames, at: arrivedAt, ms: arrivedMs, source: dataChannel),
            valid: buffer.isBinary && buffer.data.count <= 16384)
    }
}


/// Per-peer admission before the main hop. A bounded drain preserves reliable order.
/// Associated with the peer so no other lane's peer state/teardown region changes.
final class PeerControlIngress {
    struct Value {
        let data: Data; let frames: Int; let at: TimeInterval; let ms: Double; let source: NSObject?
        init(data: Data, frames: Int, at: TimeInterval, ms: Double, source: NSObject? = nil) {
            self.data = data; self.frames = frames; self.at = at; self.ms = ms; self.source = source
        }
    }
    static let defaultsKey = "PocketDeskControlIngressBudget"
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil || defaults.bool(forKey: defaultsKey)
    }
    static let processEnabled = isEnabled()
    private static let associationLock = NSLock()
    private static var associationKey: UInt8 = 0
    static func forPeer(_ peer: NSObject, create: () -> PeerControlIngress) -> PeerControlIngress {
        associationLock.lock(); defer { associationLock.unlock() }
        if let value = objc_getAssociatedObject(peer, &associationKey) as? PeerControlIngress { return value }
        let value = create()
        objc_setAssociatedObject(peer, &associationKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }
    static func permitsSource(current: NSObject?, source: NSObject, label: String, ordered: Bool, reliable: Bool) -> Bool {
        if let current { return current === source }
        return label == "control" && ordered && reliable
    }
    static func refusePeer(_ peer: NSObject) {
        associationLock.lock()
        let value = objc_getAssociatedObject(peer, &associationKey) as? PeerControlIngress
        associationLock.unlock()
        guard let value, value.enabled else { return }
        value.offer(.init(data: Data(), frames: 0, at: 0, ms: 0), valid: false)
    }
    private let enabled: Bool
    private let schedule: (@escaping () -> Void) -> Void
    private let deliver: (Value) -> Void
    private let fail: (Value?) -> Void
    private let lock = NSLock()
    private var values: [Value] = []
    private var count = 0, bytes = 0
    private var scheduled = false, failed = false, failureDelivered = false
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var pendingBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    init(enabled: Bool = PeerControlIngress.processEnabled,
         schedule: @escaping (@escaping () -> Void) -> Void,
         deliver: @escaping (Value) -> Void, fail: @escaping (Value?) -> Void) {
        self.enabled = enabled; self.schedule = schedule; self.deliver = deliver; self.fail = fail
    }
    func offer(_ value: Value, valid: Bool = true) {
        guard enabled else {
            if valid { schedule { [self] in deliver(value) } }
            else {
                let failure = Value(data: Data(), frames: 0, at: 0, ms: 0, source: value.source)
                schedule { [self] in fail(failure) }
            }
            return
        }
        lock.lock()
        guard !failed else { lock.unlock(); return }
        if !valid || count >= 64 || value.data.count > 256 * 1024 - bytes {
            failed = true
            count -= values.count; bytes -= values.reduce(0) { $0 + $1.data.count }
            values.removeAll(keepingCapacity: false)
        } else { values.append(value); count += 1; bytes += value.data.count }
        let enqueue = !scheduled; scheduled = true
        lock.unlock()
        if enqueue { schedule { [self] in drain() } }
    }
    private func drain() {
        for _ in 0..<16 {
            lock.lock()
            guard !failed, !values.isEmpty else { lock.unlock(); break }
            let value = values.removeFirst()
            lock.unlock()
            deliver(value)
            // Keep an in-flight value charged until its synchronous delivery completes.
            lock.lock(); count -= 1; bytes -= value.data.count; lock.unlock()
        }
        lock.lock()
        let report = failed && !failureDelivered
        if report { failureDelivered = true }
        let again = !failed && !values.isEmpty
        if !again { scheduled = false }
        lock.unlock()
        if report { fail(nil) }
        if again { schedule { [self] in drain() } }
    }
}

/// Counts frames WebRTC hands to renderers; RTCMTLVideoView draws the newest of these on its display link.
final class StreamCadenceRenderer: NSObject, RTCVideoRenderer {
    private let counters: StreamCounters
    init(counters: StreamCounters) { self.counters = counters }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        counters.rendered(rtp: UInt32(bitPattern: frame.timeStamp))
    }
}
