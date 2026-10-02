import Foundation
import WebRTC

/// Feedback is video-only; it cannot grant input or advance a causal checkpoint.
struct VideoFeedback: Codable, Equatable {
    enum Operation: String, Codable { case ltrAck, refresh }
    var version = 1
    let operation: Operation
    let generation: String
    let nonce: String
    let token: Int64?
    let scopeEpoch: UInt64
    func validate() throws {
        guard version == 1, InputCausalEnvelope.validID(generation), InputCausalEnvelope.validID(nonce),
              scopeEpoch > 0, (operation == .ltrAck) == (token != nil) else { throw RemoteError.invalidMessage }
    }
}

/// Travels inside the compressed access unit, so native RTP timestamp rewriting is irrelevant.
struct VideoFrameTag: Codable, Equatable {
    var version = 1
    let generation: String
    let nonce: String
    let geometryEpoch: UInt64
    let scopeEpoch: UInt64
    let ltrToken: Int64?
    var refinement: VideoRefinementIdentity? = nil
    var timing: ExactVideoTiming? = nil
    /// The capture region this frame was captured under (b7-scroll, 2 Oct): the phone places the frame
    /// by it instead of by the `capture` status echo, which travels apart from the video. Nil from an
    /// older Mac; an older phone ignores it.
    var region: CaptureRegion? = nil
    func validate() throws {
        guard version == 1, InputCausalEnvelope.validID(generation), InputCausalEnvelope.validID(nonce),
              geometryEpoch > 0, scopeEpoch > 0 else { throw RemoteError.invalidMessage }
        try timing?.validate()
        try refinement?.validate()
        try region?.validate()
        if let refinement { guard refinement.generation == generation, refinement.geometryEpoch == geometryEpoch, refinement.scopeEpoch == scopeEpoch else { throw RemoteError.invalidMessage } }
    }
}

/// One context per peer, retained by factories even when timing instrumentation is off.
/// No encoder token is acknowledged from host encode/RTC acceptance callbacks.
final class VideoFeedbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private var refinementAllowed = false
    private var timingAllowed = false
    private let timingPushes = HostExactVideoTimingLog()
    private let regionPushes = HostFrameRegionLog()
    private let timingReceiver = ExactVideoTimingReceiver()
    private let producer = VideoRefinementProducer()
    private var refinementImage: ((VideoRefinementImage) -> Void)?
    private var overlay: (VideoRefinementImage, CVPixelBuffer, Double)?
    private var ltrAllowed = false
    private var allowed = false
    private var ended = false
    private var geometry: UInt64 = 0, scope: UInt64 = 0
    private var generation = VideoFeedbackContext.id()
    private var tokens: [String: (VideoFrameTag, Double)] = [:]
    private var acknowledged: [Int64] = []
    private var acceptedAckCount = 0
    var receiverAcknowledgements: Int { lock.lock(); defer { lock.unlock() }; return acceptedAckCount }
    private var refresh = false
    private var decoderGeneration = UUID()
    private var retired: [UInt32: Double] = [:]
    private var pending: [UInt32: (VideoFrameTag, Double, UUID)] = [:]
    private var decoded: [(WeakFrame, VideoFrameTag, Double)] = []
    private var feedback: ((VideoFeedback, UInt64) -> Void)?
    private var lastRefresh = -Double.infinity
    private final class WeakFrame {
        weak var value: RTCVideoFrame?
        weak var pixels: CVPixelBuffer?
        let timestampNs: Int64
        init(_ value: RTCVideoFrame) {
            self.value = value; pixels = (value.buffer as? RTCCVPixelBuffer)?.pixelBuffer; timestampNs = value.timeStampNs
        }
        func matches(_ frame: RTCVideoFrame) -> Bool {
            if value === frame { return true }
            // Native fanout recreates Objective-C frame wrappers, while preserving the decoded CV buffer and timestamp.
            guard let pixels, let output = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { return false }
            return pixels === output && timestampNs == frame.timeStampNs
        }
        var alive: Bool { value != nil || pixels != nil }
    }
    static func id() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    func configure(allowed: Bool, ltr: Bool = true, refinement: Bool = false, timing: Bool = false, geometry: UInt64, scope: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        if self.geometry != geometry || self.scope != scope || self.allowed != allowed || ltrAllowed != ltr || refinementAllowed != refinement || timingAllowed != timing { clear() }
        self.allowed = allowed; ltrAllowed = ltr; refinementAllowed = refinement; timingAllowed = timing; self.geometry = geometry; self.scope = scope
    }
    private func clear() {
        overlay = nil
        timingPushes.reset(); regionPushes.reset(); timingReceiver.reset()
        producer.reset(terminal: ended)
        generation = Self.id(); tokens.removeAll(); acknowledged.removeAll(); refresh = false
        pending.removeAll(); retired.removeAll(); decoded.removeAll(); decoderGeneration = UUID(); lastRefresh = -.infinity
    }
    func end() { lock.lock(); refinementImage = nil; overlay = nil; ended = true; allowed = false; clear(); feedback = nil; lock.unlock() }
    var permitsLTR: Bool { lock.lock(); defer { lock.unlock() }; return allowed && ltrAllowed && !ended && geometry > 0 && scope > 0 }
    func disableRefinement() { lock.lock(); refinementAllowed = false; overlay = nil; producer.reset(); lock.unlock() }
    func beginEncoder() { lock.lock(); timingPushes.reset(); producer.reset(); generation = Self.id(); tokens.removeAll(); acknowledged.removeAll(); refresh = false; lock.unlock() }
    #if DEBUG
    var refinementProducerForTesting: VideoRefinementProducer { producer }
    #endif
    func beginDecoder() {
        lock.lock(); let now = ProcessInfo.processInfo.systemUptime
        retired = retired.filter { now >= $0.value && now - $0.value <= 5 }
        for wire in pending.keys where retired.count < 128 { retired[wire] = now }
        pending.removeAll(); decoded.removeAll(); timingReceiver.reset(); decoderGeneration = UUID(); lock.unlock()
    }
    func setFeedback(_ callback: ((VideoFeedback, UInt64) -> Void)?) { lock.lock(); feedback = callback; lock.unlock() }
    func encoded(token: Int64?, expected: VideoFrameTag? = nil, at now: Double = ProcessInfo.processInfo.systemUptime) -> VideoFrameTag? {
        lock.lock(); defer { lock.unlock() }
        guard allowed, !ended, geometry > 0, scope > 0, now.isFinite else { return nil }
        if let expected, expected.generation != generation || expected.geometryEpoch != geometry || expected.scopeEpoch != scope { return nil }
        tokens = tokens.filter { now >= $0.value.1 && now - $0.value.1 <= 5 }
        var tag = VideoFrameTag(generation: generation, nonce: expected?.nonce ?? Self.id(), geometryEpoch: geometry, scopeEpoch: scope, ltrToken: token)
        tag.refinement = expected?.refinement
        tag.timing = timingAllowed ? expected?.timing : nil
        tag.region = expected?.region
        if token != nil, tokens.count < 32 { tokens[tag.nonce] = (tag, now) }
        return tag
    }
    func permitsRefinement(_ identity: VideoRefinementIdentity, sender: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return allowed && refinementAllowed && !ended && identity.geometryEpoch == geometry && identity.scopeEpoch == scope &&
            (!sender || identity.generation == generation)
    }
    func setRefinementImage(_ callback: ((VideoRefinementImage) -> Void)?) { lock.lock(); refinementImage = callback; lock.unlock() }
    func prepareRefinement(_ buffer: CVPixelBuffer, tag: VideoFrameTag, at now: Double = ProcessInfo.processInfo.systemUptime) -> VideoFrameTag {
        // Admission and the producer's generation ticket are one operation with retirement.
        // Inspect hashes at most the bounded ROI; producer callbacks run asynchronously without its lock.
        lock.lock(); defer { lock.unlock() }
        let permitted = allowed && refinementAllowed && !ended && tag.generation == generation && tag.geometryEpoch == geometry && tag.scopeEpoch == scope
        guard permitted else { return tag }
        var result = tag
        result.refinement = producer.inspect(buffer, tag: tag, at: now) { [weak self] image in
            guard let self else { return }
            self.lock.lock()
            let current = self.allowed && self.refinementAllowed && !self.ended && image.identity.generation == self.generation &&
                image.identity.geometryEpoch == self.geometry && image.identity.scopeEpoch == self.scope
            let callback = current ? self.refinementImage : nil
            self.lock.unlock(); callback?(image)
        }
        return result
    }
    func acceptRefinement(_ image: VideoRefinementImage) {
        // Decode before final admission; public PNG dimensions/bytes are bounded before allocation.
        guard let pixels = VideoRefinementPNG.decode(image) else { return }
        lock.lock(); defer { lock.unlock() }
        guard allowed, refinementAllowed, !ended, image.identity.geometryEpoch == geometry, image.identity.scopeEpoch == scope else { return }
        overlay = (image, pixels, ProcessInfo.processInfo.systemUptime)
    }
    func refinement(for tag: VideoFrameTag, at now: Double) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard allowed, refinementAllowed, !ended, let overlay, now.isFinite, now >= overlay.2, now - overlay.2 <= 2,
              tag.geometryEpoch == geometry, tag.scopeEpoch == scope, tag.refinement == overlay.0.identity else { return nil }
        return overlay.1
    }
    func receive(_ message: VideoFeedback, epoch: UInt64, at now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard (try? message.validate()) != nil, allowed, !ended, epoch == geometry, message.scopeEpoch == scope,
              message.generation == generation, now.isFinite else { return }
        switch message.operation {
        case .ltrAck:
            guard let pending = tokens[message.nonce], now >= pending.1, now - pending.1 <= 5,
                  pending.0.ltrToken == message.token, let token = message.token else { return }
            tokens.removeValue(forKey: message.nonce)
            acceptedAckCount = min(1_000_000, acceptedAckCount + 1)
            if !acknowledged.contains(token) { acknowledged.append(token); if acknowledged.count > 32 { acknowledged.removeFirst() } }
        case .refresh:
            guard now - lastRefresh >= 0.5 else { return }; lastRefresh = now; refresh = true
        }
    }
    func takeOptions() -> (tokens: [Int64], refresh: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard allowed, !ended else { return ([], false) }
        let result = (acknowledged, refresh); acknowledged.removeAll(); refresh = false; return result
    }
    func received(_ tag: VideoFrameTag?, wire: UInt32, at now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard allowed, !ended, now.isFinite else { return }
        pending = pending.filter { now >= $0.value.1 && now - $0.value.1 <= 5 }
        retired = retired.filter { now >= $0.value && now - $0.value <= 5 }
        if pending[wire] != nil { pending.removeValue(forKey: wire); if retired.count < 128 { retired[wire] = now }; return } // Ambiguous input never proves a reference.
        if retired[wire] != nil || retired.count >= 128 { return }
        // Even an unmarked, malformed or stale AU can collide with an outstanding native decode.
        // Retire that association before accepting any metadata from the second submission.
        guard let tag, (try? tag.validate()) != nil, tag.geometryEpoch == geometry, tag.scopeEpoch == scope else { return }
        if pending.count < 128 { pending[wire] = (tag, now, decoderGeneration) }
    }
    func requestRefresh(_ tag: VideoFrameTag?) {
        lock.lock(); let now = ProcessInfo.processInfo.systemUptime
        guard allowed, ltrAllowed, !ended, let tag, tag.geometryEpoch == geometry, tag.scopeEpoch == scope,
              now - lastRefresh >= 0.5 else { lock.unlock(); return }
        lastRefresh = now; let callback = feedback; let epoch = geometry
        let packet = VideoFeedback(operation: .refresh, generation: tag.generation, nonce: tag.nonce, token: nil, scopeEpoch: tag.scopeEpoch)
        lock.unlock(); callback?(packet, epoch)
    }
    func rejected(wire: UInt32) { lock.lock(); pending.removeValue(forKey: wire); if retired.count < 128 { retired[wire] = ProcessInfo.processInfo.systemUptime }; lock.unlock() }
    #if DEBUG && AUDIO_LIFETIME_TESTS
    var beforeDecodedAdmissionForTesting: (() -> Void)?
    func withTimingAdmissionHeldForTesting(_ body: () -> Void) { lock.lock(); defer { lock.unlock() }; body() }
    #endif
    func decoded(_ frame: RTCVideoFrame, at now: Double = ProcessInfo.processInfo.systemUptime,
                 decodedAtMs: Double = MachClock.nowMs()) {
        // Default arguments are evaluated at native callback entry, before association/producer lock wait.
        #if DEBUG && AUDIO_LIFETIME_TESTS
        beforeDecodedAdmissionForTesting?()
        #endif
        lock.lock()
        guard allowed, !ended, let entry = pending.removeValue(forKey: UInt32(bitPattern: frame.timeStamp)),
              entry.2 == decoderGeneration, entry.0.geometryEpoch == geometry, entry.0.scopeEpoch == scope,
              now.isFinite, now >= entry.1, now - entry.1 <= 5 else { lock.unlock(); return }
        decoded = decoded.filter { $0.0.alive && now >= $0.2 && now - $0.2 <= 5 }
        if decoded.count >= 128 { decoded.removeFirst() }
        decoded.append((WeakFrame(frame), entry.0, now))
        if timingAllowed, let timing = entry.0.timing {
            timingReceiver.decoded(timing, generation: entry.0.generation, nonce: entry.0.nonce, atMs: decodedAtMs)
        }
        if retired.count < 128 { retired[UInt32(bitPattern: frame.timeStamp)] = now }
        let packet = entry.0.ltrToken.map { VideoFeedback(operation: .ltrAck, generation: entry.0.generation,
            nonce: entry.0.nonce, token: $0, scopeEpoch: entry.0.scopeEpoch) }
        let callback = feedback; let epoch = geometry
        lock.unlock()
        if let packet { callback?(packet, epoch) }
    }
    func pushedTiming(_ timing: ExactVideoTiming?, buffer: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard allowed, timingAllowed, !ended else { return }
        timingPushes.pushed(timing, buffer: buffer)
    }
    func submittedTiming(buffer: CVPixelBuffer, atMs: Double) -> ExactVideoTiming? {
        lock.lock(); defer { lock.unlock() }
        guard allowed, timingAllowed, !ended else { return nil }
        return timingPushes.submitted(buffer: buffer, atMs: atMs)
    }
    /// The capture region a pushed buffer was captured under, found again by the encoder at submission.
    func pushedRegion(_ region: CaptureRegion?, buffer: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard allowed, !ended, let region else { return }
        regionPushes.pushed(region, buffer: buffer)
    }
    /// Nil for a region that would not validate: it must never cost the frame its whole tag.
    func submittedRegion(buffer: CVPixelBuffer) -> CaptureRegion? {
        lock.lock(); defer { lock.unlock() }
        guard allowed, !ended, let region = regionPushes.submitted(buffer: buffer),
              (try? region.validate()) != nil else { return nil }
        return region
    }
    /// Caller must hold its actual public presentation fence; interpolated/redrawn outputs never enter here.
    func presentedTiming(_ tag: VideoFrameTag?, originalSource: Bool, newSubmission: Bool, presentedTime: Double, clock: ClockSyncEstimate?, observedAtMs: Double?, nowMs: Double = MachClock.nowMs()) {
        lock.lock(); defer { lock.unlock() }
        guard originalSource, newSubmission, presentedTime.isFinite, presentedTime > 0,
              allowed, timingAllowed, !ended, let tag, tag.geometryEpoch == geometry, tag.scopeEpoch == scope,
              let timing = tag.timing else { return }
        timingReceiver.presented(timing, generation: tag.generation, nonce: tag.nonce, atMs: presentedTime * 1000,
            clock: clock, clockRecordedAtMs: observedAtMs, nowMs: nowMs)
    }
    func drainTiming() -> ExactVideoTimingReceiver.Drain? {
        lock.lock(); defer { lock.unlock() }
        guard allowed, timingAllowed, !ended else { return nil }; return timingReceiver.drain()
    }
    func tag(for frame: RTCVideoFrame) -> VideoFrameTag? {
        lock.lock(); defer { lock.unlock() }
        guard allowed, !ended else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        decoded = decoded.filter { $0.0.alive && now >= $0.2 && now - $0.2 <= 5 }
        return decoded.last { $0.0.matches(frame) }?.1
    }
}

/// Public native pass-through. ACK happens only at native successful output, not decode submission.
final class VideoFeedbackDecoder: NSObject, RTCVideoDecoder {
    private let inner: any RTCVideoDecoder
    private let context: VideoFeedbackContext
    private let hevc: Bool
    init(inner: any RTCVideoDecoder, context: VideoFeedbackContext, hevc: Bool = false) { self.inner = inner; self.context = context; self.hevc = hevc; super.init() }
    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        inner.setCallback { [context] frame in context.decoded(frame); callback(frame) }
    }
    func startDecode(withNumberOfCores cores: Int32) -> Int { context.beginDecoder(); return inner.startDecode(withNumberOfCores: cores) }
    func release() -> Int { context.beginDecoder(); return inner.release() }
    func decode(_ image: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        let tag = H26xVideoMarker.read(image.buffer, hevc: hevc)
        context.received(tag, wire: image.timeStamp)
        if missingFrames && !hevc { context.requestRefresh(tag) }
        let result = inner.decode(image, missingFrames: missingFrames, codecSpecificInfo: info, renderTimeMs: renderTimeMs)
        if result != 0 { context.rejected(wire: image.timeStamp); if !hevc { context.requestRefresh(tag) } }
        return result
    }
    func implementationName() -> String { inner.implementationName() }
}
