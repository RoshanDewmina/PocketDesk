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

/// Phone ring of received frames, fed from the decoder thread.
final class PhoneFrameTimingLog: @unchecked Sendable {
    static let capacity = 512
    private static let decodeSearchDepth = 32

    private let lock = NSLock()
    private var ring: [PhoneFrameRecord] = []
    private var next = 0
    private var active = true
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
        guard active else { return }
        let record = PhoneFrameRecord(wireRtp: wireRtp, bytes: bytes, arrivalMs: atMs)
        if ring.count < Self.capacity { ring.append(record) } else { ring[next] = record }
        next = (next + 1) % Self.capacity
    }

    func decoded(rtp: Int32, atMs: Double) {
        let wire = UInt32(bitPattern: rtp)
        lock.lock(); defer { lock.unlock() }
        decodedFrames += 1
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
}

/// Phone side: joins each batch of host records to the ring and keeps Mac display → decoded here.
final class FrameTimingReceiver {
    struct Drain: Equatable {
        var p50Ms: Double?
        var p95Ms: Double?
        var maxMs: Double?
        var count: Int
        var locked: Bool
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

    /// Nil until the host has sent records, so an older Mac adds no fields.
    func drain() -> Drain? {
        guard sawRecords else { return nil }
        let window = window.drainPercentiles()
        return Drain(p50Ms: window.p50, p95Ms: window.p95, maxMs: window.max, count: window.count, locked: isLocked)
    }
}

/// Test hook: forces the host's frame timing on or off regardless of `StreamTuning.current`.
enum FrameTimingSwitch {
    nonisolated(unsafe) static var override: Bool?
}

/// Pass-through H.264 decoder that logs each frame's wire timestamp, size, arrival and decode time.
final class TimedH264Decoder: NSObject, RTCVideoDecoder {
    private let inner = RTCVideoDecoderH264()
    private weak var log: PhoneFrameTimingLog?

    init(log: PhoneFrameTimingLog) {
        self.log = log
        super.init()
    }

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        inner.setCallback { [weak log] frame in
            log?.decoded(rtp: frame.timeStamp, atMs: MachClock.nowMs())
            callback(frame)
        }
    }

    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        inner.startDecode(withNumberOfCores: numberOfCores)
    }

    func release() -> Int { inner.release() }

    func decode(_ encodedImage: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any RTCCodecSpecificInfo)?,
                renderTimeMs: Int64) -> Int {
        log?.received(wireRtp: encodedImage.timeStamp, bytes: encodedImage.buffer.count, atMs: MachClock.nowMs())
        return inner.decode(encodedImage, missingFrames: missingFrames, codecSpecificInfo: info, renderTimeMs: renderTimeMs)
    }

    func implementationName() -> String { inner.implementationName() }
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
        frameTimedCount = drain.count
        frameJoinLocked = drain.locked
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
        return "frame host p50 \(value(hostP50)) p95 \(value(hostP95)) · " + phone
    }
}

enum FrameTimingFormat {
    static func round(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return (value * 10).rounded() / 10
    }
}
