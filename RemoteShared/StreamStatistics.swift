import Foundation
import os

struct StreamStatsEntry {
    let id: String
    let type: String
    let values: [String: Any]
    var timestamp: TimeInterval = 0

    init(id: String, type: String, values: [String: Any], timestamp: TimeInterval = 0) {
        self.id = id
        self.type = type
        self.values = values
        self.timestamp = timestamp
    }

    func number(_ key: String) -> Double? { (values[key] as? NSNumber)?.doubleValue }
    func string(_ key: String) -> String? { values[key] as? String ?? (values[key] as? NSString).map { $0 as String } }
    func bool(_ key: String) -> Bool? { (values[key] as? NSNumber)?.boolValue }
    var isVideo: Bool { string("kind") == "video" || string("mediaType") == "video" }
}

/// Cumulative WebRTC counters at one getStats() instant.
struct StreamStatsSample {
    var timestamp: TimeInterval = 0
    var outbound: StreamStatsEntry?
    var mediaSource: StreamStatsEntry?
    var inbound: StreamStatsEntry?
    var remoteInbound: StreamStatsEntry?
    var codec: StreamStatsEntry?
    var pair: StreamStatsEntry?
    var route = "Route pending"

    init(entries: [StreamStatsEntry]) {
        var byID: [String: StreamStatsEntry] = [:]
        for entry in entries { byID[entry.id] = entry }
        outbound = entries.first { $0.type == "outbound-rtp" && $0.isVideo }
        inbound = entries.first { $0.type == "inbound-rtp" && $0.isVideo }
        remoteInbound = entries.first { $0.type == "remote-inbound-rtp" && $0.isVideo }
        mediaSource = outbound?.string("mediaSourceId").flatMap { byID[$0] }
            ?? entries.first { $0.type == "media-source" && $0.isVideo }
        codec = (outbound ?? inbound)?.string("codecId").flatMap { byID[$0] }
        let selected = entries.first { $0.type == "transport" && $0.string("selectedCandidatePairId") != nil }?
            .string("selectedCandidatePairId").flatMap { byID[$0] }
        pair = selected
        let local = selected?.string("localCandidateId").flatMap { byID[$0] }?.string("candidateType")
        let remote = selected?.string("remoteCandidateId").flatMap { byID[$0] }?.string("candidateType")
        route = MediaRoute.classify(selected: selected != nil, local: local, remote: remote)
        timestamp = (outbound ?? inbound ?? selected ?? entries.first)?.timestamp ?? 0
    }
}

/// Application-side counters gathered between two statistics samples.
struct StreamCounterSnapshot {
    var interval: TimeInterval
    var captureFrames = 0
    var captureIdleFrames = 0
    var pushedFrames = 0
    var pushSkipped = 0
    var renderedFrames = 0
    var renderGapMedianMs: Double?
    var renderGapP90Ms: Double?
    var renderGapMaxMs: Double?
    var inputBufferedBytes: UInt64?
    var inputBufferedPeakBytes: UInt64?
    var coalescedMoves = 0
}

struct StreamStatsReport: Codable, Equatable {
    var role: String
    var route: String?
    var codec: String?
    var h264ProfileLevel: String?
    var captureMaximumDimension: Int?

    var captureFPS: Double?
    var captureIdleFPS: Double?
    var pushedFPS: Double?
    var pushSkipped: Int?
    var sourceFPS: Double?
    var encodedFPS: Double?
    var sentFPS: Double?
    var encodeMs: Double?
    var qpAverage: Double?
    var encoderImplementation: String?
    var powerEfficientEncoder: Bool?
    var qualityLimitation: String?
    var sentWidth: Int?
    var sentHeight: Int?
    var sentKbps: Double?
    var targetKbps: Double?
    var availableOutgoingKbps: Double?
    var keyFrames: Int?
    var nackReceived: Int?
    var pliReceived: Int?
    var remoteLossPercent: Double?

    var receivedFPS: Double?
    var decodedFPS: Double?
    var framesDropped: Int?
    var receivedKbps: Double?
    var decodeMs: Double?
    var jitterBufferMs: Double?
    var jitterBufferTargetMs: Double?
    var processingMs: Double?
    var packetLossPercent: Double?
    var freezes: Int?
    var decoderImplementation: String?
    var powerEfficientDecoder: Bool?
    var receivedWidth: Int?
    var receivedHeight: Int?
    var renderedFPS: Double?
    var renderGapMedianMs: Double?
    var renderGapP90Ms: Double?
    var renderGapMaxMs: Double?

    var rttMs: Double?
    var inputBufferedBytes: UInt64?
    var inputBufferedPeakBytes: UInt64?
    var coalescedMoves: Int?

    init(role: String, previous: StreamStatsSample?, current: StreamStatsSample,
         counters: StreamCounterSnapshot?) {
        self.role = role
        route = current.route
        codec = current.codec?.string("mimeType")
        h264ProfileLevel = current.codec?.string("sdpFmtpLine").flatMap(Self.profileLevel)
        rttMs = Self.round((current.pair?.number("currentRoundTripTime")
            ?? current.remoteInbound?.number("roundTripTime")).map { $0 * 1000 })
        availableOutgoingKbps = Self.round(current.pair?.number("availableOutgoingBitrate").map { $0 / 1000 })

        if let out = current.outbound {
            encoderImplementation = out.string("encoderImplementation")
            powerEfficientEncoder = out.bool("powerEfficientEncoder")
            qualityLimitation = out.string("qualityLimitationReason")
            sentWidth = out.number("frameWidth").map { Int($0) }
            sentHeight = out.number("frameHeight").map { Int($0) }
            targetKbps = Self.round(out.number("targetBitrate").map { $0 / 1000 })
        }
        if let inbound = current.inbound {
            decoderImplementation = inbound.string("decoderImplementation")
            powerEfficientDecoder = inbound.bool("powerEfficientDecoder")
            receivedWidth = inbound.number("frameWidth").map { Int($0) }
            receivedHeight = inbound.number("frameHeight").map { Int($0) }
        }
        remoteLossPercent = Self.round(current.remoteInbound?.number("fractionLost").map { $0 * 100 })

        if let previous, current.timestamp > previous.timestamp {
            let seconds = current.timestamp - previous.timestamp
            let out = Delta(previous.outbound, current.outbound)
            let source = Delta(previous.mediaSource, current.mediaSource)
            let inbound = Delta(previous.inbound, current.inbound)
            sourceFPS = Self.rate(source["frames"], seconds)
            encodedFPS = Self.rate(out["framesEncoded"], seconds)
            sentFPS = Self.rate(out["framesSent"], seconds)
            encodeMs = Self.perItem(out["totalEncodeTime"], out["framesEncoded"], scale: 1000)
            qpAverage = Self.perItem(out["qpSum"], out["framesEncoded"])
            sentKbps = Self.rate(out["bytesSent"].map { $0 * 8 / 1000 }, seconds)
            keyFrames = out["keyFramesEncoded"].map { Int($0) }
            nackReceived = out["nackCount"].map { Int($0) }
            pliReceived = out["pliCount"].map { Int($0) }

            receivedFPS = Self.rate(inbound["framesReceived"], seconds)
            decodedFPS = Self.rate(inbound["framesDecoded"], seconds)
            framesDropped = inbound["framesDropped"].map { Int($0) }
            receivedKbps = Self.rate(inbound["bytesReceived"].map { $0 * 8 / 1000 }, seconds)
            decodeMs = Self.perItem(inbound["totalDecodeTime"], inbound["framesDecoded"], scale: 1000)
            jitterBufferMs = Self.perItem(inbound["jitterBufferDelay"], inbound["jitterBufferEmittedCount"], scale: 1000)
            jitterBufferTargetMs = Self.perItem(inbound["jitterBufferTargetDelay"], inbound["jitterBufferEmittedCount"], scale: 1000)
            processingMs = Self.perItem(inbound["totalProcessingDelay"], inbound["framesDecoded"], scale: 1000)
            freezes = inbound["freezeCount"].map { Int($0) }
            if let lost = inbound["packetsLost"], let received = inbound["packetsReceived"], lost + received > 0 {
                packetLossPercent = Self.round(max(0, lost) / (max(0, lost) + received) * 100)
            }
        }

        if let counters, counters.interval > 0 {
            let seconds = counters.interval
            if role == "host" {
                captureFPS = Self.round(Double(counters.captureFrames) / seconds)
                captureIdleFPS = Self.round(Double(counters.captureIdleFrames) / seconds)
                pushedFPS = Self.round(Double(counters.pushedFrames) / seconds)
                pushSkipped = counters.pushSkipped
            } else {
                renderedFPS = Self.round(Double(counters.renderedFrames) / seconds)
                renderGapMedianMs = Self.round(counters.renderGapMedianMs)
                renderGapP90Ms = Self.round(counters.renderGapP90Ms)
                renderGapMaxMs = Self.round(counters.renderGapMaxMs)
                coalescedMoves = counters.coalescedMoves
            }
            inputBufferedBytes = counters.inputBufferedBytes
            inputBufferedPeakBytes = counters.inputBufferedPeakBytes
        }
    }

    var logLine: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "PDSTATS " + json
    }

    var summaryLines: [String] {
        func value(_ number: Double?, _ unit: String = "") -> String {
            guard let number else { return "–" }
            return number >= 100 ? "\(Int(number.rounded()))\(unit)" : String(format: "%.1f%@", number, unit)
        }
        var lines = ["\(route ?? "Route pending") · \(codec ?? "codec?") \(h264ProfileLevel ?? "") · RTT \(value(rttMs, "ms"))"]
        if role == "host" {
            lines.append("capture \(value(captureFPS)) · pushed \(value(pushedFPS)) · skipped \(pushSkipped ?? 0) · cap \(captureMaximumDimension.map(String.init) ?? "–")")
            lines.append("encode \(value(encodedFPS))fps \(value(encodeMs, "ms")) · sent \(value(sentFPS))fps \(sentWidth ?? 0)×\(sentHeight ?? 0)")
            lines.append("\(value(sentKbps, "kbps")) · target \(value(targetKbps, "kbps")) · BWE \(value(availableOutgoingKbps, "kbps"))")
            lines.append("\(encoderImplementation ?? "encoder?") hw=\(powerEfficientEncoder.map(String.init) ?? "?") · limit \(qualityLimitation ?? "?") · QP \(value(qpAverage))")
        } else {
            lines.append("recv \(value(receivedFPS)) · decoded \(value(decodedFPS)) · rendered \(value(renderedFPS)) · dropped \(framesDropped ?? 0)")
            lines.append("gap p50 \(value(renderGapMedianMs, "ms")) p90 \(value(renderGapP90Ms, "ms")) max \(value(renderGapMaxMs, "ms"))")
            lines.append("jitter buf \(value(jitterBufferMs, "ms")) (target \(value(jitterBufferTargetMs, "ms"))) · decode \(value(decodeMs, "ms")) · e2e-rx \(value(processingMs, "ms"))")
            lines.append("\(receivedWidth ?? 0)×\(receivedHeight ?? 0) · \(value(receivedKbps, "kbps")) · loss \(value(packetLossPercent, "%")) · freezes \(freezes ?? 0)")
            lines.append("\(decoderImplementation ?? "decoder?") · moves coalesced \(coalescedMoves ?? 0)")
        }
        lines.append("input buffered \(inputBufferedBytes ?? 0)B peak \(inputBufferedPeakBytes ?? 0)B")
        return lines
    }

    private static func profileLevel(_ fmtp: String) -> String? {
        fmtp.split(separator: ";").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("profile-level-id=") }
            .map { String($0.dropFirst("profile-level-id=".count)) }
    }

    private static func round(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return (value * 10).rounded() / 10
    }

    private static func rate(_ delta: Double?, _ seconds: Double) -> Double? {
        guard let delta, seconds > 0 else { return nil }
        return round(delta / seconds)
    }

    private static func perItem(_ total: Double?, _ count: Double?, scale: Double = 1) -> Double? {
        guard let total, let count, count > 0 else { return nil }
        return round(total / count * scale)
    }

    /// Counter deltas; nil when a counter is missing or went backwards (stream restarted).
    private struct Delta {
        let previous: StreamStatsEntry?
        let current: StreamStatsEntry?
        init(_ previous: StreamStatsEntry?, _ current: StreamStatsEntry?) {
            self.previous = previous
            self.current = current
        }
        subscript(key: String) -> Double? {
            guard let before = previous?.number(key), let after = current?.number(key), after >= before else { return nil }
            return after - before
        }
    }
}

/// Inter-frame gap distribution for frames handed to the renderer.
struct FrameCadenceWindow {
    private var last: TimeInterval?
    private var gaps: [Double] = []
    private var frames = 0

    struct Summary {
        var frames: Int
        var medianGapMs: Double?
        var p90GapMs: Double?
        var maxGapMs: Double?
    }

    mutating func record(at time: TimeInterval) {
        if let last, time >= last { gaps.append((time - last) * 1000) }
        last = time
        frames += 1
    }

    mutating func drain() -> Summary {
        defer { gaps.removeAll(keepingCapacity: true); frames = 0 }
        guard !gaps.isEmpty else { return Summary(frames: frames) }
        let sorted = gaps.sorted()
        func rank(_ fraction: Double) -> Double {
            sorted[max(0, min(sorted.count - 1, Int((fraction * Double(sorted.count)).rounded(.up)) - 1))]
        }
        return Summary(frames: frames, medianGapMs: rank(0.5), p90GapMs: rank(0.9), maxGapMs: sorted.last)
    }
}

/// Thread-safe counters fed from capture, WebRTC and renderer threads.
final class StreamCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var snapshot = StreamCounterSnapshot(interval: 0)
    private var cadence = FrameCadenceWindow()

    func captured(idle: Bool) {
        lock.lock(); defer { lock.unlock() }
        if idle { snapshot.captureIdleFrames += 1 } else { snapshot.captureFrames += 1 }
    }

    func pushed() { lock.lock(); snapshot.pushedFrames += 1; lock.unlock() }
    func pushSkipped() { lock.lock(); snapshot.pushSkipped += 1; lock.unlock() }
    func coalescedMove() { lock.lock(); snapshot.coalescedMoves += 1; lock.unlock() }

    func rendered(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        snapshot.renderedFrames += 1
        cadence.record(at: time)
    }

    func inputBuffered(_ bytes: UInt64) {
        lock.lock(); defer { lock.unlock() }
        snapshot.inputBufferedPeakBytes = max(snapshot.inputBufferedPeakBytes ?? 0, bytes)
    }

    func drain(inputBufferedBytes: UInt64?, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> StreamCounterSnapshot {
        lock.lock(); defer { lock.unlock() }
        var result = snapshot
        result.interval = time - startedAt
        result.inputBufferedBytes = inputBufferedBytes
        if let inputBufferedBytes {
            result.inputBufferedPeakBytes = max(result.inputBufferedPeakBytes ?? 0, inputBufferedBytes)
        }
        let gaps = cadence.drain()
        result.renderGapMedianMs = gaps.medianGapMs
        result.renderGapP90Ms = gaps.p90GapMs
        result.renderGapMaxMs = gaps.maxGapMs
        snapshot = StreamCounterSnapshot(interval: 0)
        startedAt = time
        return result
    }
}

/// Hidden stream diagnostics. Enable with
/// `defaults write <bundle id> PocketDeskStreamStats -bool YES` or the launch
/// argument `-PocketDeskStreamStats YES`.
enum StreamDebug {
    static let defaultsKey = "PocketDeskStreamStats"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    private static let logger = Logger(subsystem: "com.roshan.PocketDesk", category: "stream-stats")
    private static let fileQueue = DispatchQueue(label: "PocketDesk.stream-stats-log")

    static var logFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PocketDeskStreamStats.jsonl")
    }

    static func record(_ report: StreamStatsReport) {
        guard enabled else { return }
        let line = report.logLine
        logger.notice("\(line, privacy: .public)")
        guard let url = logFileURL else { return }
        fileQueue.async {
            let data = Data((line.dropFirst("PDSTATS ".count) + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                if (try? handle.seekToEnd()) ?? 0 > 32 * 1024 * 1024 { try? handle.truncate(atOffset: 0) }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
