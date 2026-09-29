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
    var captureLatencyP50Ms: Double?
    var captureLatencyP90Ms: Double?
    var captureGapP90Ms: Double?
    var captureGapMaxMs: Double?
    var presentedFrames = 0
    var supersededFrames = 0
    var presentLatencyP50Ms: Double?
    var presentLatencyP90Ms: Double?
    var presentGapP90Ms: Double?
    var displayMaxFPS: Int?
}

/// Compact sender-side stages the Mac forwards to the phone overlay once per statistics sample.
struct HostStreamSummary: Codable, Equatable {
    var captureFPS: Double?
    var captureLatencyMs: Double?
    var captureGapP90Ms: Double?
    var pushSkipped: Int?
    var droppedBeforeEncode: Int?
    var encodedFPS: Double?
    var encodeMs: Double?
    var pacerDelayMs: Double?
    var sentFPS: Double?
    var sentKbps: Double?
    var targetKbps: Double?
    var maxKbps: Double?
    var qpAverage: Double?
    var sentWidth: Int?
    var sentHeight: Int?
    var encoder: String?
    var hardwareEncoder: Bool?
    var qualityLimitation: String?

    func validate() throws {
        let numbers = [captureFPS, captureLatencyMs, captureGapP90Ms, encodedFPS, encodeMs, pacerDelayMs,
                       sentFPS, sentKbps, targetKbps, maxKbps, qpAverage].compactMap { $0 }
        let integers = [pushSkipped, droppedBeforeEncode, sentWidth, sentHeight].compactMap { $0 }
        guard numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 10_000_000 }),
              integers.allSatisfy({ $0 >= 0 && $0 <= 100_000 }),
              (encoder?.utf8.count ?? 0) <= 48, (qualityLimitation?.utf8.count ?? 0) <= 24 else {
            throw RemoteError.invalidMessage
        }
    }
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

    // Per-stage timing. Sender: display→capture callback, frames lost before the encoder,
    // pacer queueing. Receiver: packet assembly and draw-call latency after decode.
    var captureLatencyMs: Double?
    var captureLatencyP90Ms: Double?
    var captureGapP90Ms: Double?
    var captureGapMaxMs: Double?
    var droppedBeforeEncode: Int?
    var pacerDelayMs: Double?
    var retransmittedPackets: Int?
    var maxKbps: Double?
    var tuning: String?
    var assemblyMs: Double?
    var presentedFPS: Double?
    var supersededFrames: Int?
    var presentLatencyMs: Double?
    var presentLatencyP90Ms: Double?
    var presentGapP90Ms: Double?
    var displayMaxFPS: Int?
    var host: HostStreamSummary?

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
            pacerDelayMs = Self.perItem(out["totalPacketSendDelay"], out["packetsSent"], scale: 1000)
            retransmittedPackets = out["retransmittedPacketsSent"].map { Int($0) }
            if let sourced = source["frames"], let encoded = out["framesEncoded"] {
                droppedBeforeEncode = max(0, Int(sourced - encoded))
            }

            receivedFPS = Self.rate(inbound["framesReceived"], seconds)
            decodedFPS = Self.rate(inbound["framesDecoded"], seconds)
            framesDropped = inbound["framesDropped"].map { Int($0) }
            receivedKbps = Self.rate(inbound["bytesReceived"].map { $0 * 8 / 1000 }, seconds)
            decodeMs = Self.perItem(inbound["totalDecodeTime"], inbound["framesDecoded"], scale: 1000)
            jitterBufferMs = Self.perItem(inbound["jitterBufferDelay"], inbound["jitterBufferEmittedCount"], scale: 1000)
            jitterBufferTargetMs = Self.perItem(inbound["jitterBufferTargetDelay"], inbound["jitterBufferEmittedCount"], scale: 1000)
            processingMs = Self.perItem(inbound["totalProcessingDelay"], inbound["framesDecoded"], scale: 1000)
            assemblyMs = Self.perItem(inbound["totalAssemblyTime"], inbound["framesAssembledFromMultiplePackets"], scale: 1000)
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
                captureLatencyMs = Self.round(counters.captureLatencyP50Ms)
                captureLatencyP90Ms = Self.round(counters.captureLatencyP90Ms)
                captureGapP90Ms = Self.round(counters.captureGapP90Ms)
                captureGapMaxMs = Self.round(counters.captureGapMaxMs)
            } else {
                renderedFPS = Self.round(Double(counters.renderedFrames) / seconds)
                renderGapMedianMs = Self.round(counters.renderGapMedianMs)
                renderGapP90Ms = Self.round(counters.renderGapP90Ms)
                renderGapMaxMs = Self.round(counters.renderGapMaxMs)
                coalescedMoves = counters.coalescedMoves
                displayMaxFPS = counters.displayMaxFPS
                if counters.presentedFrames > 0 || counters.supersededFrames > 0 {
                    presentedFPS = Self.round(Double(counters.presentedFrames) / seconds)
                    supersededFrames = counters.supersededFrames
                    presentLatencyMs = Self.round(counters.presentLatencyP50Ms)
                    presentLatencyP90Ms = Self.round(counters.presentLatencyP90Ms)
                    presentGapP90Ms = Self.round(counters.presentGapP90Ms)
                }
            }
            inputBufferedBytes = counters.inputBufferedBytes
            inputBufferedPeakBytes = counters.inputBufferedPeakBytes
        }
    }

    var hostSummary: HostStreamSummary {
        HostStreamSummary(captureFPS: captureFPS, captureLatencyMs: captureLatencyMs, captureGapP90Ms: captureGapP90Ms,
                          pushSkipped: pushSkipped, droppedBeforeEncode: droppedBeforeEncode,
                          encodedFPS: encodedFPS, encodeMs: encodeMs, pacerDelayMs: pacerDelayMs,
                          sentFPS: sentFPS, sentKbps: sentKbps, targetKbps: targetKbps, maxKbps: maxKbps,
                          qpAverage: qpAverage, sentWidth: sentWidth, sentHeight: sentHeight,
                          encoder: encoderImplementation.map { String($0.prefix(48)) },
                          hardwareEncoder: powerEfficientEncoder,
                          qualityLimitation: qualityLimitation.map { String($0.prefix(24)) })
    }

    /// Sum of the average stage delays from the Mac's display to the phone's draw call.
    /// A stage estimate, not a physical glass-to-glass measurement; it excludes the input path.
    var estimatedDisplayToDrawMs: Double? {
        guard let rttMs, let decodeMs else { return nil }
        let sender = host.map { ($0.captureLatencyMs ?? 0) + ($0.encodeMs ?? 0) + ($0.pacerDelayMs ?? 0) }
            ?? ((captureLatencyMs ?? 0) + (encodeMs ?? 0) + (pacerDelayMs ?? 0))
        return Self.round(sender + rttMs / 2 + (jitterBufferMs ?? 0) + decodeMs + (presentLatencyMs ?? 0))
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
        func hardware(_ flag: Bool?) -> String { flag == true ? "hw" : flag == false ? "sw?" : "hw?" }
        let refresh = displayMaxFPS.map { " · \($0)Hz" } ?? ""
        var lines = ["\(route ?? "Route pending") · \(codec ?? "codec?") \(h264ProfileLevel ?? "") · RTT \(value(rttMs, "ms"))\(refresh)"]
        if role == "host" {
            lines.append("capture \(value(captureFPS))fps lag \(value(captureLatencyMs, "ms")) p90 \(value(captureLatencyP90Ms, "ms")) · gap p90 \(value(captureGapP90Ms, "ms")) · cap \(captureMaximumDimension.map(String.init) ?? "–")")
            lines.append("pushed \(value(pushedFPS)) · skipped \(pushSkipped ?? 0) · dropped pre-encode \(droppedBeforeEncode ?? 0)")
            lines.append("encode \(value(encodedFPS))fps \(value(encodeMs, "ms")) · pacer \(value(pacerDelayMs, "ms")) · sent \(value(sentFPS))fps \(sentWidth ?? 0)×\(sentHeight ?? 0)")
            lines.append("\(value(sentKbps, "kbps")) · target \(value(targetKbps, "kbps")) · max \(value(maxKbps, "kbps")) · BWE \(value(availableOutgoingKbps, "kbps"))")
            lines.append("\(encoderImplementation ?? "encoder?") \(hardware(powerEfficientEncoder)) · limit \(qualityLimitation ?? "?") · QP \(value(qpAverage)) · rtx \(retransmittedPackets ?? 0)")
        } else {
            if let host {
                lines.append("Mac capture \(value(host.captureFPS))fps lag \(value(host.captureLatencyMs, "ms")) gap90 \(value(host.captureGapP90Ms, "ms")) · lost \((host.pushSkipped ?? 0) + (host.droppedBeforeEncode ?? 0))")
                // No QP here: skip-only screen frames report QP 51 whatever the visible quality.
                lines.append("Mac encode \(value(host.encodedFPS))fps \(value(host.encodeMs, "ms")) · pacer \(value(host.pacerDelayMs, "ms")) · kbps sent \(value(host.sentKbps)) target \(value(host.targetKbps)) max \(value(host.maxKbps))")
                lines.append("Mac \(host.encoder ?? "encoder?") \(hardware(host.hardwareEncoder)) \(host.sentWidth ?? 0)×\(host.sentHeight ?? 0) · limit \(host.qualityLimitation ?? "?")")
            }
            lines.append("recv \(value(receivedFPS)) · decoded \(value(decodedFPS)) · shown \(value(presentedFPS)) (replaced \(supersededFrames ?? 0)) · dropped \(framesDropped ?? 0)")
            lines.append("assemble \(value(assemblyMs, "ms")) · jitter \(value(jitterBufferMs, "ms")) · decode \(value(decodeMs, "ms")) · to-screen \(value(presentLatencyMs, "ms")) p90 \(value(presentLatencyP90Ms, "ms"))")
            lines.append("gap p50 \(value(renderGapMedianMs, "ms")) p90 \(value(renderGapP90Ms, "ms")) max \(value(renderGapMaxMs, "ms")) · shown gap p90 \(value(presentGapP90Ms, "ms"))")
            lines.append("\(receivedWidth ?? 0)×\(receivedHeight ?? 0) · \(value(receivedKbps, "kbps")) · loss \(value(packetLossPercent, "%")) · freezes \(freezes ?? 0) · \(decoderImplementation ?? "decoder?")")
            if let estimate = estimatedDisplayToDrawMs {
                lines.append("≈ Mac display → phone draw \(value(estimate, "ms")) (stage sum)")
            }
        }
        lines.append("input queue \(inputBufferedBytes ?? 0)B peak \(inputBufferedPeakBytes ?? 0)B · moves merged \(coalescedMoves ?? 0)")
        return lines
    }

    private static func profileLevel(_ fmtp: String) -> String? {
        fmtp.split(separator: ";").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("profile-level-id=") }
            .map { String($0.dropFirst("profile-level-id=".count)) }
    }

    fileprivate static func round(_ value: Double?) -> Double? {
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
        if let last, time >= last {
            if gaps.count == 1024 { gaps.removeFirst() }
            gaps.append((time - last) * 1000)
        }
        last = time
        frames += 1
    }

    mutating func drain() -> Summary {
        defer { gaps.removeAll(keepingCapacity: true); frames = 0 }
        guard !gaps.isEmpty else { return Summary(frames: frames) }
        let sorted = gaps.sorted()
        return Summary(frames: frames, medianGapMs: LatencyWindow.rank(sorted, 0.5),
                       p90GapMs: LatencyWindow.rank(sorted, 0.9), maxGapMs: sorted.last)
    }
}

/// Bounded distribution of per-frame stage latencies in milliseconds.
struct LatencyWindow {
    private var samples: [Double] = []
    static let capacity = 2048

    mutating func record(_ milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0, samples.count < Self.capacity else { return }
        samples.append(milliseconds)
    }

    mutating func drain() -> (p50: Double?, p90: Double?, count: Int) {
        defer { samples.removeAll(keepingCapacity: true) }
        guard !samples.isEmpty else { return (nil, nil, 0) }
        let sorted = samples.sorted()
        return (Self.rank(sorted, 0.5), Self.rank(sorted, 0.9), sorted.count)
    }

    static func rank(_ sorted: [Double], _ fraction: Double) -> Double {
        sorted[max(0, min(sorted.count - 1, Int((fraction * Double(sorted.count)).rounded(.up)) - 1))]
    }
}

/// Thread-safe counters fed from capture, WebRTC and renderer threads.
final class StreamCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var snapshot = StreamCounterSnapshot(interval: 0)
    private var cadence = FrameCadenceWindow()
    private var captureCadence = FrameCadenceWindow()
    private var captureLatency = LatencyWindow()
    private var presentLatency = LatencyWindow()
    private var presentCadence = FrameCadenceWindow()
    private var displayMaxFPS: Int?

    /// The refresh rate the video view presents at, fixed once the view is on screen.
    func setDisplayMaxFPS(_ fps: Int) { lock.lock(); displayMaxFPS = fps; lock.unlock() }

    /// `displayLatencyMs` is the time from the window server displaying the frame to its capture callback.
    func captured(idle: Bool, displayLatencyMs: Double? = nil,
                  at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        if idle { snapshot.captureIdleFrames += 1; return }
        snapshot.captureFrames += 1
        captureCadence.record(at: time)
        if let displayLatencyMs { captureLatency.record(displayLatencyMs) }
    }

    func pushed() { lock.lock(); snapshot.pushedFrames += 1; lock.unlock() }
    func pushSkipped() { lock.lock(); snapshot.pushSkipped += 1; lock.unlock() }
    func coalescedMove() { lock.lock(); snapshot.coalescedMoves += 1; lock.unlock() }

    func rendered(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        snapshot.renderedFrames += 1
        cadence.record(at: time)
    }

    /// A decoded frame reached a draw call. `latencyMs` runs from the renderer callback to that draw.
    func presented(latencyMs: Double?, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        snapshot.presentedFrames += 1
        presentCadence.record(at: time)
        if let latencyMs { presentLatency.record(latencyMs) }
    }

    /// A decoded frame was replaced by a newer one before any draw call showed it.
    func superseded(_ count: Int = 1) {
        guard count > 0 else { return }
        lock.lock(); snapshot.supersededFrames += count; lock.unlock()
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
        let captureGaps = captureCadence.drain()
        result.captureGapP90Ms = captureGaps.p90GapMs
        result.captureGapMaxMs = captureGaps.maxGapMs
        let capture = captureLatency.drain()
        result.captureLatencyP50Ms = capture.p50
        result.captureLatencyP90Ms = capture.p90
        let present = presentLatency.drain()
        result.presentLatencyP50Ms = present.p50
        result.presentLatencyP90Ms = present.p90
        result.presentGapP90Ms = presentCadence.drain().p90GapMs
        result.displayMaxFPS = displayMaxFPS
        snapshot = StreamCounterSnapshot(interval: 0)
        startedAt = time
        return result
    }
}

/// Hidden stream diagnostics. Enable with the phone's "Stream statistics" switch,
/// `defaults write <bundle id> PocketDeskStreamStats -bool YES`, or the launch
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
