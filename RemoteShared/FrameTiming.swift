import Foundation
import CoreVideo
import WebRTC

/// Per-frame timing without touching the bitstream (perf pack 4a). The Mac lists each encoded frame's
/// local RTP timestamp, size and display/push/encoded times; the phone lists each received frame's wire
/// RTP timestamp, size and decode time. The wire timestamp is the local one plus a constant random
/// offset, which `FrameTimingJoin` recovers by matching sizes. Failure means no data, never a video change.
struct HostFrameRecord: Equatable {
    var localRtp: UInt32
    var bytes: Int
    /// ScreenCaptureKit display time in mach ms; 0 for the idle re-send of an unchanged frame.
    var displayMs: Double
    var pushMs: Double
    var encodedMs: Double

    var isResend: Bool { displayMs <= 0 }
    var hostLatencyMs: Double? { isResend ? nil : encodedMs - displayMs }
}

struct PhoneFrameRecord: Equatable {
    var wireRtp: UInt32
    var bytes: Int
    var arrivalMs: Double
    var decodedMs: Double?
}

/// The newest host records as parallel integer arrays, small enough for the 1 Hz capture status.
/// Times are tenths of a millisecond: `encoded` after `baseMs`, `display` and `push` before `encoded`.
struct FrameTimingRecords: Codable, Equatable {
    static let maximumCount = 64
    static let resend = -1
    static let offsetLimit = 600_000
    static let stageLimit = 100_000
    static let bytesLimit = 50_000_000

    var baseMs: Double
    var rtp: [UInt32]
    var bytes: [Int]
    var encoded: [Int]
    var display: [Int]
    var push: [Int]

    init?(_ records: [HostFrameRecord]) {
        let kept = records.suffix(Self.maximumCount).filter {
            $0.encodedMs.isFinite && $0.displayMs.isFinite && $0.pushMs.isFinite && $0.encodedMs > 0
        }
        guard let first = kept.first else { return nil }
        func tenths(_ ms: Double, _ limit: Int) -> Int {
            let scaled = ms * 10
            guard scaled > 0 else { return 0 }
            guard scaled.isFinite, scaled < Double(limit) else { return limit }
            return Int(scaled.rounded())
        }
        baseMs = first.encodedMs
        rtp = kept.map(\.localRtp)
        bytes = kept.map { min(Self.bytesLimit, max(0, $0.bytes)) }
        encoded = kept.map { tenths($0.encodedMs - first.encodedMs, Self.offsetLimit) }
        display = kept.map { $0.isResend ? Self.resend : tenths($0.encodedMs - $0.displayMs, Self.stageLimit) }
        push = kept.map { tenths($0.encodedMs - $0.pushMs, Self.stageLimit) }
    }

    var records: [HostFrameRecord] {
        rtp.indices.map { index in
            let encodedMs = baseMs + Double(encoded[index]) / 10
            return HostFrameRecord(localRtp: rtp[index], bytes: bytes[index],
                                   displayMs: display[index] == Self.resend ? 0 : encodedMs - Double(display[index]) / 10,
                                   pushMs: encodedMs - Double(push[index]) / 10, encodedMs: encodedMs)
        }
    }

    func validate() throws {
        let count = rtp.count
        guard (1...Self.maximumCount).contains(count), bytes.count == count, encoded.count == count,
              display.count == count, push.count == count,
              baseMs.isFinite, baseMs > 0, baseMs < 1e13,
              bytes.allSatisfy({ (0...Self.bytesLimit).contains($0) }),
              encoded.allSatisfy({ (0...Self.offsetLimit).contains($0) }),
              display.allSatisfy({ (Self.resend...Self.stageLimit).contains($0) }),
              push.allSatisfy({ (0...Self.stageLimit).contains($0) }) else {
            throw RemoteError.invalidMessage
        }
    }
}

/// Finds `offset = wire − local` (mod 2³²) by voting over records of equal size, then joins on it.
struct FrameTimingJoin {
    static let minimumVotes = 4

    struct Pair: Equatable {
        var host: HostFrameRecord
        var phone: PhoneFrameRecord
    }

    private(set) var offset: UInt32?

    mutating func match(host: [HostFrameRecord], phone: [PhoneFrameRecord]) -> [Pair] {
        var byRtp: [UInt32: PhoneFrameRecord] = [:]
        for record in phone { byRtp[record.wireRtp] = record }
        func pairs(_ offset: UInt32) -> [Pair] {
            host.compactMap { record in
                guard let match = byRtp[record.localRtp &+ offset], match.bytes == record.bytes else { return nil }
                return Pair(host: record, phone: match)
            }
        }
        if let offset {
            let joined = pairs(offset)
            if !joined.isEmpty { return joined }
        }
        var bySize: [Int: [UInt32]] = [:]
        for record in phone { bySize[record.bytes, default: []].append(record.wireRtp) }
        var votes: [UInt32: Int] = [:]
        var candidates = 0
        for record in host {
            guard let wires = bySize[record.bytes] else { continue }
            candidates += 1
            for wire in Set(wires) { votes[wire &- record.localRtp, default: 0] += 1 }
        }
        // Too little overlap to judge (the phone's ring and this batch barely meet): keep the lock.
        guard candidates >= Self.minimumVotes else { return [] }
        let ranked = votes.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= Self.minimumVotes,
              best.value >= 2 * (ranked.dropFirst().first?.value ?? 0) else {
            offset = nil
            return []
        }
        offset = best.key
        return pairs(best.key)
    }
}

/// Host bookkeeping from push to encoded output. The push is found again at `encode()` by its pixel
/// buffer (the video source translates timestamps, so the pushed one never reaches the encoder), and the
/// output by the encoder's own capture-time key, as `EncoderLatencyTrace` matches it.
final class HostFrameTimingLog: @unchecked Sendable {
    static let pendingLimit = 16

    struct Drain {
        var p50Ms: Double?
        var p95Ms: Double?
        var maxMs: Double?
        var records: FrameTimingRecords?
    }

    private let lock = NSLock()
    private var pushes: [(id: ObjectIdentifier, displayMs: Double, pushMs: Double)] = []
    private var submits: [(key: Int64, displayMs: Double, pushMs: Double)] = []
    private var records: [HostFrameRecord] = []
    private var latency = LatencyWindow()

    func pushed(_ buffer: ObjectIdentifier, displayMs: Double, pushMs: Double) {
        lock.lock(); defer { lock.unlock() }
        pushes.removeAll { $0.id == buffer }
        pushes.append((buffer, displayMs, pushMs))
        if pushes.count > Self.pendingLimit { pushes.removeFirst() }
    }

    func submitted(_ buffer: ObjectIdentifier?, key: Int64) {
        guard let buffer else { return }
        lock.lock(); defer { lock.unlock() }
        guard let index = pushes.lastIndex(where: { $0.id == buffer }) else { return }
        let push = pushes.remove(at: index)
        submits.removeAll { $0.key == key }
        submits.append((key, push.displayMs, push.pushMs))
        if submits.count > Self.pendingLimit { submits.removeFirst() }
    }

    func encoded(key: Int64, localRtp: UInt32, bytes: Int, atMs: Double) {
        lock.lock(); defer { lock.unlock() }
        guard let index = submits.firstIndex(where: { $0.key == key }) else { return }
        let submit = submits.remove(at: index)
        let record = HostFrameRecord(localRtp: localRtp, bytes: bytes, displayMs: submit.displayMs,
                                     pushMs: submit.pushMs, encodedMs: atMs)
        records.append(record)
        if records.count > FrameTimingRecords.maximumCount { records.removeFirst() }
        if let latencyMs = record.hostLatencyMs { latency.record(latencyMs) }
    }

    func drain() -> Drain {
        lock.lock(); defer { lock.unlock() }
        let window = latency.drainPercentiles()
        defer { records.removeAll(keepingCapacity: true) }
        return Drain(p50Ms: window.p50, p95Ms: window.p95, maxMs: window.max, records: FrameTimingRecords(records))
    }
}

/// Phone-local observations for one decoder delivery. Owned HEVC supplies all four stages;
/// stock H.264 exposes only outward delivery. Missing native stages remain unknown;
/// no clock is reconstructed from RTP, source timestamps, or another frame.
struct PhoneDecodeTrace: Sendable, Equatable {
    let submitMs: Double?
    let callbackMs: Double?
    let ownershipMs: Double?
    let deliveryMs: Double

    init(submitMs: Double, callbackMs: Double, ownershipMs: Double, deliveryMs: Double) {
        self.submitMs = submitMs; self.callbackMs = callbackMs
        self.ownershipMs = ownershipMs; self.deliveryMs = deliveryMs
    }

    init(deliveryMs: Double) {
        submitMs = nil; callbackMs = nil; ownershipMs = nil; self.deliveryMs = deliveryMs
    }

    var isValid: Bool {
        guard deliveryMs.isFinite, deliveryMs >= 0 else { return false }
        guard let submitMs, let callbackMs, let ownershipMs else {
            return submitMs == nil && callbackMs == nil && ownershipMs == nil
        }
        return submitMs.isFinite && callbackMs.isFinite && ownershipMs.isFinite
            && submitMs >= 0 && submitMs <= callbackMs && callbackMs <= ownershipMs && ownershipMs <= deliveryMs
    }
}

/// Internal instrumentation A/B switch; does not change admission or frame delivery.
enum PhoneRenderTiming {
    static let disabledKey = "phoneRenderTimingDisabled"
    static var enabled: Bool { !UserDefaults.standard.bool(forKey: disabledKey) }
}

/// Phone ring of received frames, fed from the decoder thread.
final class PhoneFrameTimingLog: @unchecked Sendable {
    static let capacity = 512
    private static let decodeSearchDepth = 32

    private let lock = NSLock()
    private var ring: [PhoneFrameRecord] = []
    private var next = 0
    private var active = true
    let renderTimingEnabled: Bool
    private let detailedDiagnosticsEnabled: Bool
    private var pendingReceives: [(rtp: UInt32, atMs: Double?)] = []
    private var receiveToDecoded = LatencyWindow()
    private struct DecodeEntry {
        let rtp: Int32
        let timeStampNs: Int64
        let ownerID: UUID?
        var trace: PhoneDecodeTrace?
    }
    private var decodeTraces: [DecodeEntry] = []

    init(renderTimingEnabled: Bool = PhoneRenderTiming.enabled,
         detailedDiagnosticsEnabled: Bool = DetailedDiagnostics.enabled) {
        self.renderTimingEnabled = renderTimingEnabled
        self.detailedDiagnosticsEnabled = detailedDiagnosticsEnabled
    }

    /// Stored immediately before the outward callback. Separate from heuristic host timing:
    /// `isActive == false` must not disable a phone-local observation.
    func decodedDelivery(rtp: Int32, timeStampNs: Int64, trace: PhoneDecodeTrace, ownerID: UUID? = nil) {
        guard renderTimingEnabled, trace.isValid else { return }
        lock.lock(); defer { lock.unlock() }
        if let index = decodeTraces.firstIndex(where: { $0.rtp == rtp && $0.timeStampNs == timeStampNs }) {
            // Identical source identity cannot distinguish two outward deliveries; quarantine it.
            decodeTraces[index].trace = nil
            return
        }
        decodeTraces.append(DecodeEntry(rtp: rtp, timeStampNs: timeStampNs, ownerID: ownerID, trace: trace))
        if decodeTraces.count > Self.capacity { decodeTraces.removeFirst() }
    }

    /// A retired wrapper cannot lend an unread observation to a later callback or decoder.
    /// Keep tombstones, and leave every other decoder's observations untouched.
    func retireDecodeTraces(ownerID: UUID) {
        lock.lock(); defer { lock.unlock() }
        for index in decodeTraces.indices where decodeTraces[index].ownerID == ownerID {
            decodeTraces[index].trace = nil
        }
    }

    /// One outward delivery owns one trace. A repeated RTP with different source timestamp,
    /// duplicate identity, evicted entry or already-consumed trace supplies nil, rather than a nearest estimate.
    func takeDecodeTrace(rtp: Int32, timeStampNs: Int64) -> PhoneDecodeTrace? {
        guard renderTimingEnabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let index = decodeTraces.lastIndex(where: { $0.rtp == rtp && $0.timeStampNs == timeStampNs }) else { return nil }
        let trace = decodeTraces[index].trace
        decodeTraces[index].trace = nil // Keep a bounded tombstone so a replay cannot supply a fresh trace.
        return trace
    }

    private(set) var receivedFrames = 0
    private(set) var decodedFrames = 0

    /// Off while the host sends no records (an older Mac or its switch off): nothing is kept.
    var isActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return active }
        set {
            lock.lock(); defer { lock.unlock() }
            active = newValue
            if !newValue { ring.removeAll(); next = 0 }
        }
    }

    var counts: (received: Int, decoded: Int) {
        lock.lock(); defer { lock.unlock() }
        return (receivedFrames, decodedFrames)
    }

    func received(wireRtp: UInt32, bytes: Int, atMs: Double) {
        lock.lock(); defer { lock.unlock() }
        receivedFrames += 1
        if detailedDiagnosticsEnabled {
            // Repeated pending RTP has no unique receive witness: quarantine until its completion.
            let ambiguous = pendingReceives.contains { $0.rtp == wireRtp }
            pendingReceives.removeAll { $0.rtp == wireRtp }
            pendingReceives.append((wireRtp, !ambiguous && atMs.isFinite && atMs >= 0 ? atMs : nil))
            if pendingReceives.count > Self.capacity { pendingReceives.removeFirst() }
        }
        guard active else { return }
        let record = PhoneFrameRecord(wireRtp: wireRtp, bytes: bytes, arrivalMs: atMs)
        if ring.count < Self.capacity { ring.append(record) } else { ring[next] = record }
        next = (next + 1) % Self.capacity
    }

    func decoded(rtp: Int32, atMs: Double) {
        let wire = UInt32(bitPattern: rtp)
        lock.lock(); defer { lock.unlock() }
        decodedFrames += 1
        if detailedDiagnosticsEnabled, let index = pendingReceives.firstIndex(where: { $0.rtp == wire }) {
            let receive = pendingReceives.remove(at: index)
            if let arrival = receive.atMs, let milliseconds = DetailedDiagnostics.stage(atMs - arrival) {
                receiveToDecoded.record(milliseconds)
            }
        }
        guard active, !ring.isEmpty else { return }
        for step in 1...min(ring.count, Self.decodeSearchDepth) {
            let index = (next - step + ring.count) % ring.count
            if ring[index].wireRtp == wire, ring[index].decodedMs == nil {
                ring[index].decodedMs = atMs
                return
            }
        }
    }

    func snapshot() -> [PhoneFrameRecord] {
        lock.lock(); defer { lock.unlock() }
        guard ring.count == Self.capacity else { return ring }
        return Array(ring[next...] + ring[..<next])
    }

    struct CompletionDrain {
        var p95Ms: Double?
        var samples: Int?
    }

    /// Independent of host timing and clock calibration, including while host records are absent.
    func drainReceiveToDecoded() -> CompletionDrain {
        lock.lock(); defer { lock.unlock() }
        let value = receiveToDecoded.drainPercentiles()
        return CompletionDrain(p95Ms: value.p95, samples: value.count > 0 ? value.count : nil)
    }
}

/// Phone side: joins each batch of host records to the ring and keeps Mac display → decoded here.
final class FrameTimingReceiver {
    struct Drain: Equatable {
        var p50Ms: Double?
        var p95Ms: Double?
        var maxMs: Double?
        var count: Int
        var locked: Bool
        var hostRecordsObserved = true
        var receiveToDecodedP95Ms: Double?
        var receiveToDecodedSamples: Int?
    }

    let log: PhoneFrameTimingLog
    private var join = FrameTimingJoin()
    private var window = LatencyWindow()
    private var sawRecords = false
    private(set) var joinedFrames = 0
    private(set) var joinedResends = 0
    private(set) var timedFrames = 0
    private(set) var nonNegativeFrames = 0

    init(log: PhoneFrameTimingLog) { self.log = log }

    var isLocked: Bool { join.offset != nil }

    func receive(_ records: FrameTimingRecords?, clock: ClockSyncEstimate?) {
        guard let records, (try? records.validate()) != nil else { log.isActive = false; return }
        log.isActive = true
        sawRecords = true
        for pair in join.match(host: records.records, phone: log.snapshot()) {
            joinedFrames += 1
            if pair.host.isResend { joinedResends += 1 }
            guard !pair.host.isResend, let decodedMs = pair.phone.decodedMs, let clock else { continue }
            let ms = decodedMs + clock.offsetMs - pair.host.displayMs
            guard ms.isFinite else { continue }
            timedFrames += 1
            if ms >= 0 { nonNegativeFrames += 1 }
            window.record(ms)
        }
    }

    /// Host join fields stay absent until records arrive. Phone-local completions need no host clock.
    func drain() -> Drain? {
        let completion = log.drainReceiveToDecoded()
        guard sawRecords || completion.samples != nil else { return nil }
        let window = window.drainPercentiles()
        return Drain(p50Ms: window.p50, p95Ms: window.p95, maxMs: window.max, count: window.count, locked: isLocked,
            hostRecordsObserved: sawRecords,
            receiveToDecodedP95Ms: completion.p95Ms, receiveToDecodedSamples: completion.samples)
    }
}

/// Test hook: forces the host's frame timing on or off regardless of `StreamTuning.current`.
enum FrameTimingSwitch {
    nonisolated(unsafe) static var override: Bool?
}

/// Pass-through H.264 decoder that logs each frame's wire timestamp, size, arrival and decode time.
final class TimedH264Decoder: NSObject, RTCVideoDecoder {
    private let inner: any RTCVideoDecoder
    private weak var log: PhoneFrameTimingLog?
    private let deliveryTiming = H264DeliveryTimingAdmission()

    init(log: PhoneFrameTimingLog, inner: any RTCVideoDecoder = RTCVideoDecoderH264()) {
        self.log = log; self.inner = inner
        super.init()
    }

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        inner.setCallback { [weak log, deliveryTiming] frame in
            log?.decoded(rtp: frame.timeStamp, atMs: MachClock.nowMs())
            if let log, log.renderTimingEnabled {
                deliveryTiming.performIfActive {
                    // Stock RTC has no public native VT/ownership callbacks. Observe only delivery.
                    log.decodedDelivery(rtp: frame.timeStamp, timeStampNs: frame.timeStampNs,
                                        trace: PhoneDecodeTrace(deliveryMs: MachClock.nowMs()), ownerID: deliveryTiming.ownerID)
                }
            }
            callback(frame)
        }
    }

    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        inner.startDecode(withNumberOfCores: numberOfCores)
    }

    func release() -> Int {
        deliveryTiming.retire { log?.retireDecodeTraces(ownerID: deliveryTiming.ownerID) }
        return inner.release()
    }

    func decode(_ encodedImage: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any RTCCodecSpecificInfo)?,
                renderTimeMs: Int64) -> Int {
        log?.received(wireRtp: encodedImage.timeStamp, bytes: encodedImage.buffer.count, atMs: MachClock.nowMs())
        return inner.decode(encodedImage, missingFrames: missingFrames, codecSpecificInfo: info, renderTimeMs: renderTimeMs)
    }

    func implementationName() -> String { inner.implementationName() }
}

/// Retires instrumentation without changing stock decoder callback or release behavior.
/// Reusing a released wrapper leaves timing unknown rather than admitting an old callback.
private final class H264DeliveryTimingAdmission: @unchecked Sendable {
    private let lock = NSLock()
    let ownerID = UUID()
    private var active = true
    func performIfActive(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if active { body() }
    }
    func retire(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        active = false
        body()
    }
}

final class WeakFrameTimingBox<Value: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: Value?
    var value: Value? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

extension HostStreamSummary {
    func validateFrameTiming() throws {
        let numbers = [frameHostP50Ms, frameHostP95Ms, frameHostMaxMs].compactMap { $0 }
        guard numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 10_000_000 }) else { throw RemoteError.invalidMessage }
        try frameRecords?.validate()
    }

    mutating func applyFrameTiming(_ drain: HostFrameTimingLog.Drain) {
        frameHostP50Ms = FrameTimingFormat.round(drain.p50Ms)
        frameHostP95Ms = FrameTimingFormat.round(drain.p95Ms)
        frameHostMaxMs = FrameTimingFormat.round(drain.maxMs)
        frameRecords = drain.records
    }
}

extension StreamStatsReport {
    mutating func applyHostFrameTiming(_ drain: HostFrameTimingLog.Drain) {
        frameHostP50Ms = FrameTimingFormat.round(drain.p50Ms)
        frameHostP95Ms = FrameTimingFormat.round(drain.p95Ms)
        frameHostMaxMs = FrameTimingFormat.round(drain.maxMs)
    }

    mutating func applyPhoneFrameTiming(_ drain: FrameTimingReceiver.Drain) {
        frameToPhoneP50Ms = FrameTimingFormat.round(drain.p50Ms)
        frameToPhoneP95Ms = FrameTimingFormat.round(drain.p95Ms)
        frameToPhoneMaxMs = FrameTimingFormat.round(drain.maxMs)
        // A local completion drain before any host records must not manufacture host-join evidence.
        if drain.hostRecordsObserved {
            frameTimedCount = drain.count
            frameJoinLocked = drain.locked
        }
        if detailedDiagnosticsEnabled == true {
            receiveToDecodedP95Ms = FrameTimingFormat.round(drain.receiveToDecodedP95Ms)
            receiveToDecodedSamples = drain.receiveToDecodedSamples
        }
    }

    /// `frame host p50/p95 · to phone p50/p95 (n, ±clock)`; nil when neither side has frame timing.
    var frameTimingLine: String? {
        func value(_ number: Double?) -> String {
            guard let number else { return "–" }
            return number >= 100 ? "\(Int(number.rounded()))ms" : String(format: "%.1fms", number)
        }
        let hostP50 = role == "host" ? frameHostP50Ms : host?.frameHostP50Ms
        let hostP95 = role == "host" ? frameHostP95Ms : host?.frameHostP95Ms
        let hostMax = role == "host" ? frameHostMaxMs : host?.frameHostMaxMs
        if role == "host" {
            guard hostP50 != nil else { return nil }
            return "frame host p50 \(value(hostP50)) p95 \(value(hostP95)) max \(value(hostMax))"
        }
        guard hostP50 != nil || frameJoinLocked != nil else { return nil }
        let phone = frameJoinLocked == true
            ? "to phone p50 \(value(frameToPhoneP50Ms)) p95 \(value(frameToPhoneP95Ms)) (n \(frameTimedCount ?? 0), ±\(value(clockUncertaintyMs)))"
            : "to phone – (join pending)"
        return "heuristic RTP/size join · frame host p50 \(value(hostP50)) p95 \(value(hostP95)) · " + phone
    }
}

enum FrameTimingFormat {
    static func round(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return (value * 10).rounded() / 10
    }
}


/// Confined to the ScreenCaptureKit output queue. Repeated complete callbacks and idle sends
/// retain one opaque source identity for the actual public displayTime, independent of AU nonce.
struct CaptureSourceTiming {
    static let capacity = 512
    private var sources: [(ticks: UInt64, id: String)] = []
    private var latest: ExactVideoTiming?
    mutating func captured(displayTicks: UInt64, atMs: Double) -> ExactVideoTiming? {
        let display = MachClock.milliseconds(fromMachTicks: displayTicks)
        guard displayTicks > 0, atMs.isFinite, atMs >= display, atMs - display <= 10_000 else { latest = nil; return nil }
        let id = sources.first { $0.ticks == displayTicks }?.id ?? VideoFeedbackContext.id()
        if !sources.contains(where: { $0.ticks == displayTicks }) {
            sources.append((displayTicks, id)); if sources.count > Self.capacity { sources.removeFirst() }
        }
        let timing = ExactVideoTiming(sourceID: id, displayMs: display, capturedMs: atMs,
            pushedMs: atMs, submittedMs: atMs, encodedMs: atMs, resend: false)
        latest = timing
        return timing
    }
    func resent() -> ExactVideoTiming? {
        latest.map { ExactVideoTiming(sourceID: $0.sourceID, displayMs: $0.displayMs, capturedMs: $0.capturedMs,
            pushedMs: $0.pushedMs, submittedMs: $0.submittedMs, encodedMs: $0.encodedMs, resend: true) }
    }
    mutating func reset() { latest = nil; sources.removeAll() }
}

/// Exact borrowed CV identity only, never a guessed RTP/size join or a retained pixel cache.
/// Reusing a buffer before submission is ambiguous, so both associations are quarantined.
final class HostExactVideoTimingLog {
    private final class Entry {
        weak var buffer: CVPixelBuffer?
        let timing: ExactVideoTiming?
        let pushedAtMs: Double
        init(_ buffer: CVPixelBuffer, _ timing: ExactVideoTiming?, atMs: Double) {
            self.buffer = buffer; self.timing = timing; pushedAtMs = atMs
        }
    }
    private var pushes: [Entry] = [] // Context's lock owns this bounded lane.
    static let capacity = 16
    func pushed(_ timing: ExactVideoTiming?, buffer: CVPixelBuffer, atMs: Double = MachClock.nowMs()) {
        pushes.removeAll { $0.buffer == nil || atMs < $0.pushedAtMs || atMs - $0.pushedAtMs > 5_000 }
        // A second push of the same buffer for the same source is ambiguous; a different source means
        // ScreenCaptureKit recycled the buffer, so the newer identity replaces the stale entry.
        let collision = pushes.contains { $0.buffer === buffer && ($0.timing == nil || $0.timing?.sourceID == timing?.sourceID) }
        pushes.removeAll { $0.buffer === buffer }
        let stamped = timing.map { ExactVideoTiming(sourceID: $0.sourceID, displayMs: $0.displayMs,
            capturedMs: $0.capturedMs, pushedMs: atMs, submittedMs: atMs, encodedMs: atMs, resend: $0.resend) }
        pushes.append(Entry(buffer, collision ? nil : stamped, atMs: atMs))
        if pushes.count > Self.capacity { pushes.removeFirst() }
    }
    func submitted(buffer: CVPixelBuffer, atMs: Double) -> ExactVideoTiming? {
        guard let index = pushes.firstIndex(where: { $0.buffer === buffer }) else { return nil }
        let entry = pushes.remove(at: index)
        guard let timing = entry.timing, atMs >= entry.pushedAtMs, atMs - entry.pushedAtMs <= 5_000 else { return nil }
        let result = ExactVideoTiming(sourceID: timing.sourceID, displayMs: timing.displayMs, capturedMs: timing.capturedMs,
            pushedMs: timing.pushedMs, submittedMs: atMs, encodedMs: atMs, resend: timing.resend)
        return (try? result.validate()) != nil ? result : nil
    }
    func reset() { pushes.removeAll() }
}

/// Host side: the capture region each pushed buffer was captured under, keyed by the buffer like the
/// timing lane (the video source rewrites timestamps, so the buffer is the only identity that reaches the
/// encoder). A re-pushed buffer (the idle re-send) carries the region of its latest push.
final class HostFrameRegionLog {
    private final class Entry {
        weak var buffer: CVPixelBuffer?
        let region: CaptureRegion
        let pushedAtMs: Double
        init(_ buffer: CVPixelBuffer, _ region: CaptureRegion, atMs: Double) {
            self.buffer = buffer; self.region = region; pushedAtMs = atMs
        }
    }
    private var pushes: [Entry] = [] // Context's lock owns this bounded lane.
    static let capacity = 16
    func pushed(_ region: CaptureRegion, buffer: CVPixelBuffer, atMs: Double = MachClock.nowMs()) {
        pushes.removeAll { $0.buffer == nil || $0.buffer === buffer || atMs < $0.pushedAtMs || atMs - $0.pushedAtMs > 5_000 }
        pushes.append(Entry(buffer, region, atMs: atMs))
        if pushes.count > Self.capacity { pushes.removeFirst() }
    }
    func submitted(buffer: CVPixelBuffer) -> CaptureRegion? {
        guard let index = pushes.firstIndex(where: { $0.buffer === buffer }) else { return nil }
        return pushes.remove(at: index).region
    }
    func reset() { pushes.removeAll() }
}


extension StreamStatsReport {
    mutating func applyExactVideoTiming(_ value: ExactVideoTimingReceiver.Drain) {
        exactDecoded = value.decoded; exactPresented = value.presented; exactUniqueSources = value.uniqueSources
        exactResends = value.resends; exactTimed = value.timed; exactMissingClock = value.missingClock
        exactSourceToDecodeP50Ms = FrameTimingFormat.round(value.captureToDecodeP50Ms)
        exactSourceToDecodeP95Ms = FrameTimingFormat.round(value.captureToDecodeP95Ms)
        exactSourceToPresentP50Ms = FrameTimingFormat.round(value.captureToPresentP50Ms)
        exactSourceToPresentP95Ms = FrameTimingFormat.round(value.captureToPresentP95Ms)
        exactClockUncertaintyMs = FrameTimingFormat.round(value.maximumClockUncertaintyMs)
    }
}
