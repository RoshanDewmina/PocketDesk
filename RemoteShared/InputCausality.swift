import Foundation
import os

/// Opt-in numeric timing only. Never feeds input admission, ACKs or posting authority.
/// Collect the host's input log to compare calibrated phone sends with callback arrival
/// and posting-queue cadence. No pointer coordinates, text, keys or peer identifiers.
enum InputCadenceTrace {
    static let defaultsKey = "couchInputTimingTraceEnabled"
    #if DEBUG
    static let enabled = UserDefaults.standard.bool(forKey: defaultsKey)
    #else
    static let enabled = false
    #endif
    private static let log = Logger(subsystem: "com.roshan.PocketDesk", category: "couchTiming")

    static func key(_ context: InputCausalEnvelope) -> String {
        "\(context.nonce.prefix(8)).\(context.anchor.prefix(8)).\(context.epoch)"
    }
    static func arrival(_ packet: ControlPacket, atMs: Double, lane: String) {
        guard enabled, let context = packet.input, !context.segments.isEmpty else { return }
        let message = "couchTiming stage=arrival key=\(key(context)) applied=\(context.applied) first=\(context.segments.first!.ordinal) sequence=\(packet.sequence) lane=\(lane) send=\(packet.inputTiming?.isValid == true ? packet.inputTiming!.sendHostMs : -1) uncertainty=\(packet.inputTiming?.isValid == true ? packet.inputTiming!.uncertaintyMs : -1) arrival=\(atMs) main=\(MachClock.nowMs()) segments=\(context.segments.count)"
        log.info("\(message, privacy: .public)")
    }
    static func posted(_ context: InputCausalEnvelope, ordinal: UInt64, coalesced: Int,
                       startedMs: Double, endedMs: Double, accepted: Bool, arrivalMs: Double?) {
        guard enabled else { return }
        let message = "couchTiming stage=post key=\(key(context)) applied=\(ordinal) sourceArrival=\(arrivalMs ?? -1) at=\(startedMs) end=\(endedMs) coalesced=\(coalesced) accepted=\(accepted ? 1 : 0)"
        log.info("\(message, privacy: .public)")
    }
    static func sent(_ packet: ControlPacket, lane: String, bytes: Int, buffered: UInt64) {
        guard enabled, let context = packet.input, !context.segments.isEmpty else { return }
        let message = "couchTiming stage=send key=\(key(context)) applied=\(context.applied) sequence=\(packet.sequence) lane=\(lane) at=\(MachClock.nowMs()) segments=\(context.segments.count) bytes=\(bytes) buffered=\(buffered)"
        log.info("\(message, privacy: .public)")
    }
    static func touch(ms: Double, sampleCount: Int) {
        guard enabled else { return }
        let message = "couchTiming stage=touch sample=\(ms) callback=\(MachClock.nowMs()) samples=\(sampleCount)"
        log.info("\(message, privacy: .public)")
    }
    static func pump(offeredMs: Double, sendMs: Double, count: Int) {
        guard enabled else { return }
        let message = "couchTiming stage=pump offer=\(offeredMs) at=\(sendMs) actions=\(count)"
        log.info("\(message, privacy: .public)")
    }
    static func permission(_ api: String, probe: () -> Bool) -> Bool {
        guard enabled else { return probe() }
        let start = MachClock.nowMs()
        let granted = probe()
        let message = "couchTiming stage=permission api=\(api) at=\(start) end=\(MachClock.nowMs()) granted=\(granted ? 1 : 0)"
        log.info("\(message, privacy: .public)")
        return granted
    }
}

/// Independent motion replay and application state. Ordered semantic packets retain control v1.
/// A prefix recovers dropped packets without replacing relative movement with a lossy endpoint.
struct InputMotionSegment: Codable {
    var ordinal: UInt64
    var action: RemoteAction
    func validate(epoch: UInt64) throws {
        guard ordinal > 0, ["move", "moveTo"].contains(action.action), action.epoch == epoch else { throw RemoteError.invalidMessage }
        try action.validate()
    }
}
struct InputCausalEnvelope: Codable {
    static let maximumSegments = 24
    var version = 1
    var kind: String
    var nonce: String
    var anchor: String
    var epoch: UInt64
    var applied: UInt64 = 0
    var segments: [InputMotionSegment] = []
    static func identity() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    static func validID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func validate() throws {
        guard version == 1, ["offer", "accept", "anchor", "ack", "motion", "barrier", "rebase"].contains(kind),
              Self.validID(nonce), Self.validID(anchor), epoch > 0, segments.count <= Self.maximumSegments else { throw RemoteError.invalidMessage }
        if !["motion", "barrier"].contains(kind), !segments.isEmpty { throw RemoteError.invalidMessage }
        var previous: UInt64?
        for segment in segments {
            try segment.validate(epoch: epoch)
            if let previous, previous == UInt64.max || segment.ordinal != previous + 1 { throw RemoteError.invalidMessage }
            previous = segment.ordinal
        }
        if let last = segments.last, last.ordinal != applied { throw RemoteError.invalidMessage }
    }
}

struct InputMotionReplay {
    private var newest: UInt64 = 0
    private var seen: Set<UInt64> = []
    mutating func accepts(_ sequence: UInt64) -> Bool {
        guard sequence > 0, sequence >= (newest > 128 ? newest - 128 : 0), seen.insert(sequence).inserted else { return false }
        newest = max(newest, sequence)
        seen = seen.filter { $0 >= (newest > 128 ? newest - 128 : 0) }
        return true
    }
}

struct InputAppliedLedger {
    private(set) var applied: UInt64 = 0
    mutating func reset() { applied = 0 }
    mutating func discard(through ordinal: UInt64) { applied = max(applied, ordinal) }
    /// Gap means the bounded prefix cannot recover the required state; never post a stale semantic.
    func missing(from envelope: InputCausalEnvelope) throws -> [InputMotionSegment] {
        try envelope.validate()
        let missing = envelope.segments.filter { $0.ordinal > applied }
        if let first = missing.first, applied == UInt64.max || first.ordinal != applied + 1 { throw RemoteError.stale }
        if envelope.applied > applied, missing.last?.ordinal != envelope.applied { throw RemoteError.stale }
        return missing
    }
    mutating func recordPosted(_ ordinal: UInt64) throws {
        guard applied < UInt64.max, ordinal == applied + 1 else { throw RemoteError.stale }
        applied = ordinal
    }
}

/// Retain exactly the unacknowledged ordered prefix. Overflow recovers it on reliable control
/// before accepting more motion; the caller must not discard accepted displacement.
struct InputMotionPrefix {
    private(set) var next: UInt64 = 0
    private(set) var segments: [InputMotionSegment] = []
    /// Leave room for the reliable semantic payload (including JSON escapes) and envelope.
    static let maximumEncodedSegmentsBytes = 8 * 1024
    private var segmentSizes: [Int] = []
    private var encodedSegmentsBytes: Int { 2 + segmentSizes.reduce(0, +) + max(0, segments.count - 1) }
    func canAppend(_ action: RemoteAction) -> Bool {
        guard segments.count < InputCausalEnvelope.maximumSegments, next < UInt64.max,
              let size = try? JSONEncoder().encode(InputMotionSegment(ordinal: next + 1, action: action)).count else { return false }
        return encodedSegmentsBytes + size + (segments.isEmpty ? 0 : 1) <= Self.maximumEncodedSegmentsBytes
    }
    mutating func append(_ action: RemoteAction) throws {
        guard canAppend(action) else { throw RemoteError.stale }
        let segment = InputMotionSegment(ordinal: next + 1, action: action)
        try segment.validate(epoch: action.epoch)
        let size = try JSONEncoder().encode(segment).count
        next += 1
        segments.append(segment)
        segmentSizes.append(size)
    }
    mutating func acknowledge(_ ordinal: UInt64) throws {
        guard ordinal <= next else { throw RemoteError.stale }
        let removed = segments.prefix { $0.ordinal <= ordinal }.count
        segments.removeFirst(removed); segmentSizes.removeFirst(removed)
    }
}
