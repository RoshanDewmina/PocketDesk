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
    var routeDetail: String?

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
        routeDetail = MediaRoute.detail(selected: selected != nil, local: local, remote: remote)
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
    /// Median gap between ScreenCaptureKit display times of complete frames: the source's real cadence.
    var captureGapMedianMs: Double?
    var presentedFrames = 0
    var supersededFrames = 0
    var presentLatencyP50Ms: Double?
    var presentLatencyP90Ms: Double?
    var presentGapP90Ms: Double?
    var displayMaxFPS: Int?

    // Bench marker (G28): per presented frame, Mac display time → phone display time.
    var markerFrames = 0
    var markerDistinct = 0
    /// Glass samples: one per new marker value while the clock is synced (nil when not counted).
    var glassSamples: Int?
    var glassP50Ms: Double?
    var glassP95Ms: Double?
    var glassP99Ms: Double?
    var glassMaxMs: Double?
    var clockOffsetMs: Double?
    var clockUncertaintyMs: Double?
    var clockSamples = 0
    // True presentation cadence from MTLDrawable presented handlers.
    var presentedIntervalP50Ms: Double?
    var presentedIntervalP90Ms: Double?
    var presentedIntervalMinMs: Double?
    var presentedAt120Share: Double?
    var inputToPhotonP50Ms: Double?
    var inputToPhotonP95Ms: Double?
    var inputToPhotonSamples = 0
    var legibility: LegibilitySummary?
    // Host encoder trace: VideoToolbox submit → callback per frame.
    var encodeLatencyP50Ms: Double?
    var encodeLatencyP90Ms: Double?
    var encodeLatencyMaxMs: Double?
    var encodeInFlightMax: Int?
    var encodeBytesP50: Int?
    var keyFrameBytesMax: Int?
    var rateUpdates: Int?
    var encoderSessionAgeS: Double?
    var encoderDropped: Int?
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
    // Encoder trace (older phones ignore these).
    var encodeLatencyMs: Double?
    var encodeLatencyP90Ms: Double?
    var encodeInFlightMax: Int?
    var encodeBytesP50: Int?
    var keyFrameBytesMax: Int?
    var rateUpdates: Int?
    var encoderSessionAgeS: Double?
    /// Frames the encoder's newest-frame-wins gate dropped at submit in the last sample.
    var encoderDropped: Int?
    // Rate, load and region (G5/G4/G12; older phones ignore these).
    var targetFPS: Int?
    var displayRefreshHz: Double?
    var captureDisplay: String?
    var captureGapMedianMs: Double?
    /// The Mac's `ProcessInfo.thermalState` raw value, 0 (nominal) … 3 (critical).
    var thermalState: Int?
    var lowPowerMode: Bool?
    var ladder: LadderState?
    var busy: BusyState?
    var captureRegion: CaptureRegion?
    // Per-frame timing (perf pack 4a; older phones ignore these): display → encoded, and the newest records.
    var frameHostP50Ms: Double?
    var frameHostP95Ms: Double?
    var frameHostMaxMs: Double?
    var frameRecords: FrameTimingRecords?

    static let fpsRange = 1...240
    static let refreshRange = 0.0...1_000
    static let thermalRange = 0...3
    static let displayDescriptionBytes = 48

    func validate() throws {
        let numbers = [captureFPS, captureLatencyMs, captureGapP90Ms, encodedFPS, encodeMs, pacerDelayMs,
                       sentFPS, sentKbps, targetKbps, maxKbps, qpAverage,
                       encodeLatencyMs, encodeLatencyP90Ms, encoderSessionAgeS, captureGapMedianMs].compactMap { $0 }
        let integers = [pushSkipped, droppedBeforeEncode, sentWidth, sentHeight, encodeInFlightMax, rateUpdates,
                        encoderDropped].compactMap { $0 }
        let bytes = [encodeBytesP50, keyFrameBytesMax].compactMap { $0 }
        guard numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 10_000_000 }),
              integers.allSatisfy({ $0 >= 0 && $0 <= 100_000 }),
              bytes.allSatisfy({ $0 >= 0 && $0 <= 50_000_000 }),
              (encoder?.utf8.count ?? 0) <= 48, (qualityLimitation?.utf8.count ?? 0) <= 24,
              targetFPS.map({ Self.fpsRange.contains($0) }) ?? true,
              displayRefreshHz.map({ Self.refreshRange.contains($0) }) ?? true,
              thermalState.map({ Self.thermalRange.contains($0) }) ?? true,
              (captureDisplay?.utf8.count ?? 0) <= Self.displayDescriptionBytes else {
            throw RemoteError.invalidMessage
        }
        try ladder?.validate()
        try busy?.validate()
        try captureRegion?.validate()
        try validateFrameTiming()
    }
}

struct StreamStatsReport: Codable, Equatable {
    var role: String
    var route: String?
    var routeDetail: String?
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
    /// Age of `host` when this report was made: the summary rides the Mac's 1 s heartbeat.
    var hostSummaryAgeMs: Double?

    // Bench marker: per presented frame, Mac display time → phone display time on the synced clock.
    var markerFrames: Int?
    var markerDistinctFPS: Double?
    var glassSamples: Int?
    var glassP50Ms: Double?
    var glassP95Ms: Double?
    var glassP99Ms: Double?
    var glassMaxMs: Double?
    var clockOffsetMs: Double?
    var clockUncertaintyMs: Double?
    var clockSamples: Int?
    var presentedIntervalP50Ms: Double?
    var presentedIntervalP90Ms: Double?
    var presentedIntervalMinMs: Double?
    var presentedAt120Share: Double?
    var inputToPhotonP50Ms: Double?
    var inputToPhotonP95Ms: Double?
    var inputToPhotonSamples: Int?
    var legibility: LegibilitySummary?
    // Host encoder trace.
    var encodeLatencyMs: Double?
    var encodeLatencyP90Ms: Double?
    var encodeLatencyMaxMs: Double?
    var encodeInFlightMax: Int?
    var encodeBytesP50: Int?
    var keyFrameBytesMax: Int?
    var rateUpdates: Int?
    var encoderSessionAgeS: Double?
    var encoderDropped: Int?
    // Rate, load and region. This device's thermal state and Low Power Mode on both roles; the
    // rest is the host's (the phone sees the Mac's through `host`).
    var targetFPS: Int?
    var displayRefreshHz: Double?
    var captureDisplay: String?
    var captureGapMedianMs: Double?
    var thermalState: Int?
    var lowPowerMode: Bool?
    var ladder: LadderState?
    var busy: BusyState?
    var captureRegion: CaptureRegion?
    // Per-frame timing (perf pack 4a). Host: display → encoded; phone: Mac display → decoded here.
    var frameHostP50Ms: Double?
    var frameHostP95Ms: Double?
    var frameHostMaxMs: Double?
    var frameToPhoneP50Ms: Double?
    var frameToPhoneP95Ms: Double?
    var frameToPhoneMaxMs: Double?
    var frameTimedCount: Int?
    var frameJoinLocked: Bool?

    init(role: String, previous: StreamStatsSample?, current: StreamStatsSample,
         counters: StreamCounterSnapshot?) {
        self.role = role
        route = current.route
        routeDetail = current.routeDetail
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
                captureGapMedianMs = Self.round(counters.captureGapMedianMs)
                encodeLatencyMs = Self.round(counters.encodeLatencyP50Ms)
                encodeLatencyP90Ms = Self.round(counters.encodeLatencyP90Ms)
                encodeLatencyMaxMs = Self.round(counters.encodeLatencyMaxMs)
                encodeInFlightMax = counters.encodeInFlightMax
                encodeBytesP50 = counters.encodeBytesP50
                keyFrameBytesMax = counters.keyFrameBytesMax
                rateUpdates = counters.rateUpdates
                encoderSessionAgeS = Self.round(counters.encoderSessionAgeS)
                encoderDropped = counters.encoderDropped
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
                if counters.markerFrames > 0 {
                    markerFrames = counters.markerFrames
                    markerDistinctFPS = Self.round(Double(counters.markerDistinct) / seconds)
                    glassSamples = counters.glassSamples
                    glassP50Ms = Self.round(counters.glassP50Ms)
                    glassP95Ms = Self.round(counters.glassP95Ms)
                    glassP99Ms = Self.round(counters.glassP99Ms)
                    glassMaxMs = Self.round(counters.glassMaxMs)
                }
                if counters.clockSamples > 0 {
                    clockOffsetMs = Self.round(counters.clockOffsetMs)
                    clockUncertaintyMs = Self.round(counters.clockUncertaintyMs)
                    clockSamples = counters.clockSamples
                }
                presentedIntervalP50Ms = Self.round(counters.presentedIntervalP50Ms)
                presentedIntervalP90Ms = Self.round(counters.presentedIntervalP90Ms)
                presentedIntervalMinMs = Self.round(counters.presentedIntervalMinMs)
                presentedAt120Share = counters.presentedAt120Share.map { ($0 * 100).rounded() / 100 }
                if counters.inputToPhotonSamples > 0 {
                    inputToPhotonP50Ms = Self.round(counters.inputToPhotonP50Ms)
                    inputToPhotonP95Ms = Self.round(counters.inputToPhotonP95Ms)
                    inputToPhotonSamples = counters.inputToPhotonSamples
                }
                legibility = counters.legibility
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
                          qualityLimitation: qualityLimitation.map { String($0.prefix(24)) },
                          encodeLatencyMs: encodeLatencyMs.map { min($0, 10_000_000) },
                          encodeLatencyP90Ms: encodeLatencyP90Ms.map { min($0, 10_000_000) },
                          encodeInFlightMax: encodeInFlightMax.map { min($0, 100_000) },
                          encodeBytesP50: encodeBytesP50.map { min($0, 50_000_000) },
                          keyFrameBytesMax: keyFrameBytesMax.map { min($0, 50_000_000) },
                          rateUpdates: rateUpdates.map { min($0, 100_000) },
                          encoderSessionAgeS: encoderSessionAgeS.map { min($0, 10_000_000) },
                          encoderDropped: encoderDropped.map { min($0, 100_000) },
                          targetFPS: targetFPS.map { Self.clamp($0, HostStreamSummary.fpsRange) },
                          displayRefreshHz: displayRefreshHz.flatMap {
                              $0.isFinite ? Self.clamp($0, HostStreamSummary.refreshRange) : nil
                          },
                          captureDisplay: captureDisplay.map {
                              Self.truncated($0, bytes: HostStreamSummary.displayDescriptionBytes)
                          },
                          captureGapMedianMs: captureGapMedianMs.map { min($0, 10_000_000) },
                          thermalState: thermalState.map { Self.clamp($0, HostStreamSummary.thermalRange) },
                          lowPowerMode: lowPowerMode,
                          ladder: ladder.flatMap { (try? $0.validate()) == nil ? nil : $0 },
                          busy: busy.flatMap { (try? $0.validate()) == nil ? nil : $0 },
                          captureRegion: captureRegion.flatMap { (try? $0.validate()) == nil ? nil : $0 })
    }

    static func thermalName(_ state: Int?) -> String? {
        guard let state, HostStreamSummary.thermalRange.contains(state) else { return nil }
        return ["nominal", "fair", "serious", "critical"][state]
    }

    private static func clamp<Value: Comparable>(_ value: Value, _ range: ClosedRange<Value>) -> Value {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private static func truncated(_ text: String, bytes: Int) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + character.utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
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
        func dropped(_ count: Int?) -> String { count.map { " · dropped \($0)/s" } ?? "" }
        func rateLine(_ prefix: String, target: Int?, refresh: Double?, display: String?, gapMedian: Double?,
                      thermal: Int?, lowPower: Bool?) -> String? {
            var parts: [String] = []
            if let target { parts.append("target \(target)fps") }
            if let display {
                parts.append(display)
            } else if let refresh {
                parts.append(String(format: "%.0fHz", refresh))
            }
            if let gapMedian { parts.append("capture Δ p50 \(value(gapMedian, "ms"))") }
            if let name = Self.thermalName(thermal) { parts.append("thermal \(name)") }
            if lowPower == true { parts.append("low power") }
            return parts.isEmpty ? nil : prefix + parts.joined(separator: " · ")
        }
        func loadLine(_ prefix: String, ladder: LadderState?, busy: BusyState?, region: CaptureRegion?) -> String? {
            var parts: [String] = []
            if let ladder {
                let size = String(format: "%.2f", ladder.sizeFraction)
                let reason = ladder.reason.map { " (\($0))" } ?? ""
                parts.append("ladder \(ladder.rung) \(ladder.fps)fps ×\(size)\(reason)")
            }
            if let busy {
                let state = "\(busy.level.rawValue) \(busy.fps)fps \(busy.longEdge)px (\(busy.reason))"
                parts.append(busy.isVisible ? state : "not busy")
            }
            if let region {
                let output = "\(region.outputWidth)×\(region.outputHeight)"
                if region.isWholeDisplay {
                    parts.append("whole display → \(output)")
                } else {
                    let rect = [region.x, region.y, region.width, region.height].map { Int($0.rounded()) }
                    parts.append("region #\(region.epoch) \(rect[0]),\(rect[1]) \(rect[2])×\(rect[3])pt → \(output)")
                }
            }
            return parts.isEmpty ? nil : prefix + parts.joined(separator: " · ")
        }
        let refresh = displayMaxFPS.map { " · \($0)Hz" } ?? ""
        var lines = ["\(route ?? "Route pending") · \(codec ?? "codec?") \(h264ProfileLevel ?? "") · RTT \(value(rttMs, "ms"))\(refresh)"]
        if role == "host" {
            if let rate = rateLine("", target: targetFPS, refresh: displayRefreshHz, display: captureDisplay,
                                   gapMedian: captureGapMedianMs, thermal: thermalState, lowPower: lowPowerMode) {
                lines.append(rate)
            }
            lines.append("capture \(value(captureFPS))fps lag \(value(captureLatencyMs, "ms")) p90 \(value(captureLatencyP90Ms, "ms")) · gap p90 \(value(captureGapP90Ms, "ms")) · cap \(captureMaximumDimension.map(String.init) ?? "–")")
            lines.append("pushed \(value(pushedFPS)) · skipped \(pushSkipped ?? 0) · dropped pre-encode \(droppedBeforeEncode ?? 0)")
            lines.append("encode \(value(encodedFPS))fps \(value(encodeMs, "ms")) · pacer \(value(pacerDelayMs, "ms")) · sent \(value(sentFPS))fps \(sentWidth ?? 0)×\(sentHeight ?? 0)")
            lines.append("\(value(sentKbps, "kbps")) · target \(value(targetKbps, "kbps")) · max \(value(maxKbps, "kbps")) · BWE \(value(availableOutgoingKbps, "kbps"))")
            lines.append("\(encoderImplementation ?? "encoder?") \(hardware(powerEfficientEncoder)) · limit \(qualityLimitation ?? "?") · QP \(value(qpAverage)) · rtx \(retransmittedPackets ?? 0)")
            if encodeLatencyMs != nil || encoderDropped != nil {
                lines.append("VT lat p50 \(value(encodeLatencyMs, "ms")) p90 \(value(encodeLatencyP90Ms, "ms")) max \(value(encodeLatencyMaxMs, "ms")) · in-flight ≤\(encodeInFlightMax ?? 0) · bytes p50 \(encodeBytesP50 ?? 0) · key ≤\((keyFrameBytesMax ?? 0) / 1024)KB · rate upd \(rateUpdates ?? 0) · session \(value(encoderSessionAgeS, "s"))"
                             + dropped(encoderDropped))
            }
            if let load = loadLine("", ladder: ladder, busy: busy, region: captureRegion) { lines.append(load) }
        } else {
            if let host {
                if let rate = rateLine("Mac ", target: host.targetFPS, refresh: host.displayRefreshHz,
                                       display: host.captureDisplay, gapMedian: host.captureGapMedianMs,
                                       thermal: host.thermalState, lowPower: host.lowPowerMode) {
                    lines.append(rate)
                }
                lines.append("Mac capture \(value(host.captureFPS))fps lag \(value(host.captureLatencyMs, "ms")) gap90 \(value(host.captureGapP90Ms, "ms")) · lost \((host.pushSkipped ?? 0) + (host.droppedBeforeEncode ?? 0))")
                // No QP here: skip-only screen frames report QP 51 whatever the visible quality.
                lines.append("Mac encode \(value(host.encodedFPS))fps \(value(host.encodeMs, "ms")) · pacer \(value(host.pacerDelayMs, "ms")) · kbps sent \(value(host.sentKbps)) target \(value(host.targetKbps)) max \(value(host.maxKbps))")
                lines.append("Mac \(host.encoder ?? "encoder?") \(hardware(host.hardwareEncoder)) \(host.sentWidth ?? 0)×\(host.sentHeight ?? 0) · limit \(host.qualityLimitation ?? "?") · age \(value(hostSummaryAgeMs, "ms"))")
                if host.encodeLatencyMs != nil || host.encoderDropped != nil {
                    lines.append("Mac VT lat p50 \(value(host.encodeLatencyMs, "ms")) p90 \(value(host.encodeLatencyP90Ms, "ms")) · in-flight ≤\(host.encodeInFlightMax ?? 0) · bytes p50 \(host.encodeBytesP50 ?? 0) · key ≤\((host.keyFrameBytesMax ?? 0) / 1024)KB · rate upd \(host.rateUpdates ?? 0) · session \(value(host.encoderSessionAgeS, "s"))"
                                 + dropped(host.encoderDropped))
                }
                if let load = loadLine("Mac ", ladder: host.ladder, busy: host.busy, region: host.captureRegion) {
                    lines.append(load)
                }
            }
            if let own = rateLine("phone ", target: nil, refresh: nil, display: nil, gapMedian: nil,
                                  thermal: thermalState, lowPower: lowPowerMode) {
                lines.append(own)
            }
            lines.append("recv \(value(receivedFPS)) · decoded \(value(decodedFPS)) · shown \(value(presentedFPS)) (replaced \(supersededFrames ?? 0)) · dropped \(framesDropped ?? 0)")
            lines.append("assemble \(value(assemblyMs, "ms")) · jitter \(value(jitterBufferMs, "ms")) · decode \(value(decodeMs, "ms")) · to-screen \(value(presentLatencyMs, "ms")) p90 \(value(presentLatencyP90Ms, "ms"))")
            lines.append("gap p50 \(value(renderGapMedianMs, "ms")) p90 \(value(renderGapP90Ms, "ms")) max \(value(renderGapMaxMs, "ms")) · shown gap p90 \(value(presentGapP90Ms, "ms"))")
            lines.append("\(receivedWidth ?? 0)×\(receivedHeight ?? 0) · \(value(receivedKbps, "kbps")) · loss \(value(packetLossPercent, "%")) · freezes \(freezes ?? 0) · \(decoderImplementation ?? "decoder?")")
            if let estimate = estimatedDisplayToDrawMs {
                lines.append("≈ Mac display → phone draw \(value(estimate, "ms")) (stage sum)")
            }
            if let markerFrames, markerFrames > 0, (markerDistinctFPS ?? 0) == 0 {
                lines.append("glass — · no new Mac frame · shown \(markerFrames)")
            } else if let markerFrames, markerFrames > 0 {
                lines.append("glass p50 \(value(glassP50Ms, "ms")) p95 \(value(glassP95Ms, "ms")) max \(value(glassMaxMs, "ms")) ±\(value(clockUncertaintyMs, "ms")) · n \(glassSamples ?? markerFrames) · distinct \(value(markerDistinctFPS))/s")
            } else if clockSamples != nil {
                lines.append("clock offset \(value(clockOffsetMs, "ms")) ±\(value(clockUncertaintyMs, "ms")) (\(clockSamples ?? 0) probes) · no bench marker in view")
            }
            if presentedIntervalP50Ms != nil {
                let share = presentedAt120Share.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
                lines.append("shownΔ p50 \(value(presentedIntervalP50Ms, "ms")) p90 \(value(presentedIntervalP90Ms, "ms")) min \(value(presentedIntervalMinMs, "ms")) · at 120Hz \(share)")
            }
            if (inputToPhotonSamples ?? 0) > 0 || legibility != nil {
                var parts: [String] = []
                if let samples = inputToPhotonSamples, samples > 0 {
                    parts.append("click→photon p50 \(value(inputToPhotonP50Ms, "ms")) p95 \(value(inputToPhotonP95Ms, "ms")) n \(samples)")
                }
                if let legibility {
                    let sizes = ["9pt", "11pt", "13pt", "15pt", "coloured11pt"].compactMap { key in
                        legibility.cer[key].map { "\(key) \(Int($0.rounded()))%" }
                    }
                    parts.append("CER " + sizes.joined(separator: " ") + String(format: " (+%.1fs %@)", legibility.ageMs / 1000, legibility.surface))
                }
                lines.append(parts.joined(separator: " · "))
            }
        }
        if let frameTimingLine { lines.append(frameTimingLine) }
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

    struct Percentiles {
        var p50: Double?
        var p90: Double?
        var p95: Double?
        var p99: Double?
        var min: Double?
        var max: Double?
        var count = 0
    }

    mutating func drainPercentiles() -> Percentiles {
        defer { samples.removeAll(keepingCapacity: true) }
        guard !samples.isEmpty else { return Percentiles() }
        let sorted = samples.sorted()
        return Percentiles(p50: Self.rank(sorted, 0.5), p90: Self.rank(sorted, 0.9), p95: Self.rank(sorted, 0.95),
                           p99: Self.rank(sorted, 0.99), min: sorted.first, max: sorted.last, count: sorted.count)
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
    private var captureDisplayCadence = FrameCadenceWindow()
    private var captureLatency = LatencyWindow()
    private var presentLatency = LatencyWindow()
    private var presentCadence = FrameCadenceWindow()
    private var displayMaxFPS: Int?
    private var glassLatency = LatencyWindow()
    private var presentedIntervals = LatencyWindow()
    private var inputToPhoton = LatencyWindow()
    private var encodeLatency = LatencyWindow()
    private var encodeBytes = LatencyWindow()
    private var lastPresentedMs: Double?
    private var lastMarkerTime: UInt32?
    private var lastFlash: Bool?
    private var lastClickSentMs: Double?
    private var clock: ClockSyncEstimate?
    private var legibility: LegibilitySummary?
    private var presentedAt120 = 0
    private var presentedIntervalCount = 0
    private var encodeInFlightMax = 0
    private var keyFrameBytesMax = 0
    private var rateUpdates = 0
    private var encoderDropped = 0
    private var encoderSessionStartedMs: Double?

    /// The refresh rate the video view presents at, fixed once the view is on screen.
    func setDisplayMaxFPS(_ fps: Int) { lock.lock(); displayMaxFPS = fps; lock.unlock() }

    /// `displayLatencyMs` is the time from the window server displaying the frame to its capture callback;
    /// `displayTimeMs` is that display time (ScreenCaptureKit's `displayTime` in mach ms), whose gaps
    /// give the source's own cadence without the callback's scheduling jitter.
    func captured(idle: Bool, displayLatencyMs: Double? = nil, displayTimeMs: Double? = nil,
                  at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        if idle { snapshot.captureIdleFrames += 1; return }
        snapshot.captureFrames += 1
        captureCadence.record(at: time)
        if let displayLatencyMs { captureLatency.record(displayLatencyMs) }
        if let displayTimeMs, displayTimeMs.isFinite, displayTimeMs > 0 {
            captureDisplayCadence.record(at: displayTimeMs / 1000)
        }
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

    // MARK: Bench marker, presentation cadence and input-to-photon (phone)

    func clockUpdated(_ estimate: ClockSyncEstimate?) {
        lock.lock(); clock = estimate; lock.unlock()
    }

    var clockEstimate: ClockSyncEstimate? {
        lock.lock(); defer { lock.unlock() }; return clock
    }

    /// The phone sent a click at `ms` (phone mach ms); the next flash-bit flip is timed against it.
    func clickSent(atMs ms: Double) {
        lock.lock(); lastClickSentMs = ms; lock.unlock()
    }

    /// A frame reached the display at `presentedMs` (phone mach ms, `MTLDrawable.presentedTime`).
    /// `marker` is the bench strip it carried, if any. A marker value seen before (the Mac's idle
    /// re-push of an unchanged frame) is that frame's age, not a latency, so only the first
    /// appearance of each value feeds glass, input-to-photon and the distinct count.
    func presentedFrame(atMs presentedMs: Double, marker: BenchMarker?) {
        lock.lock(); defer { lock.unlock() }
        if let last = lastPresentedMs, presentedMs > last {
            let interval = presentedMs - last
            presentedIntervals.record(interval)
            presentedIntervalCount += 1
            if interval <= 9 { presentedAt120 += 1 }
        }
        lastPresentedMs = presentedMs
        guard let marker else { return }
        snapshot.markerFrames += 1
        guard marker.timeMs != lastMarkerTime else { return }
        snapshot.markerDistinct += 1
        lastMarkerTime = marker.timeMs
        if let clock {
            let hostNow = presentedMs + clock.offsetMs
            glassLatency.record(hostNow - marker.unwrappedTimeMs(near: hostNow))
        }
        if let lastFlash, marker.flash != lastFlash, let click = lastClickSentMs,
           presentedMs >= click, presentedMs - click <= 1_000 {
            inputToPhoton.record(presentedMs - click)
            lastClickSentMs = nil
        }
        lastFlash = marker.flash
    }

    func legibilityScored(_ summary: LegibilitySummary) {
        lock.lock(); legibility = summary; lock.unlock()
    }

    // MARK: Encoder trace (host)

    func encoded(latencyMs: Double, bytes: Int, isKeyFrame: Bool, inFlight: Int) {
        lock.lock(); defer { lock.unlock() }
        encodeLatency.record(latencyMs)
        encodeBytes.record(Double(bytes))
        encodeInFlightMax = max(encodeInFlightMax, inFlight)
        if isKeyFrame { keyFrameBytesMax = max(keyFrameBytesMax, bytes) }
    }

    func encoderRateUpdated() {
        lock.lock(); rateUpdates += 1; lock.unlock()
    }

    /// The encoder dropped a frame at submit because enough were already inside VideoToolbox.
    func droppedBeforeEncode() {
        lock.lock(); encoderDropped += 1; lock.unlock()
    }

    func encoderSessionStarted(atMs ms: Double = MachClock.nowMs()) {
        lock.lock(); encoderSessionStartedMs = ms; lock.unlock()
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
        result.captureGapMedianMs = captureDisplayCadence.drain().medianGapMs
        let capture = captureLatency.drain()
        result.captureLatencyP50Ms = capture.p50
        result.captureLatencyP90Ms = capture.p90
        let present = presentLatency.drain()
        result.presentLatencyP50Ms = present.p50
        result.presentLatencyP90Ms = present.p90
        result.presentGapP90Ms = presentCadence.drain().p90GapMs
        result.displayMaxFPS = displayMaxFPS
        let glass = glassLatency.drainPercentiles()
        result.glassSamples = glass.count
        result.glassP50Ms = glass.p50
        result.glassP95Ms = glass.p95
        result.glassP99Ms = glass.p99
        result.glassMaxMs = glass.max
        result.clockOffsetMs = clock?.offsetMs
        result.clockUncertaintyMs = clock?.uncertaintyMs
        result.clockSamples = clock?.samples ?? 0
        let intervals = presentedIntervals.drainPercentiles()
        result.presentedIntervalP50Ms = intervals.p50
        result.presentedIntervalP90Ms = intervals.p90
        result.presentedIntervalMinMs = intervals.min
        result.presentedAt120Share = presentedIntervalCount > 0 ? Double(presentedAt120) / Double(presentedIntervalCount) : nil
        presentedAt120 = 0
        presentedIntervalCount = 0
        let input = inputToPhoton.drainPercentiles()
        result.inputToPhotonP50Ms = input.p50
        result.inputToPhotonP95Ms = input.p95
        result.inputToPhotonSamples = input.count
        result.legibility = legibility
        let encode = encodeLatency.drainPercentiles()
        result.encodeLatencyP50Ms = encode.p50
        result.encodeLatencyP90Ms = encode.p90
        result.encodeLatencyMaxMs = encode.max
        result.encodeInFlightMax = encode.count > 0 ? encodeInFlightMax : nil
        result.encodeBytesP50 = encodeBytes.drainPercentiles().p50.map { Int($0) }
        result.keyFrameBytesMax = keyFrameBytesMax > 0 ? keyFrameBytesMax : nil
        result.rateUpdates = encode.count > 0 || rateUpdates > 0 ? rateUpdates : nil
        result.encoderSessionAgeS = encoderSessionStartedMs.map { max(0, (MachClock.nowMs() - $0) / 1000) }
        result.encoderDropped = encode.count > 0 || encoderDropped > 0 ? encoderDropped : nil
        encodeInFlightMax = 0
        keyFrameBytesMax = 0
        rateUpdates = 0
        encoderDropped = 0
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
    /// Phone: read the bench marker and score the chart while statistics are on (default on); off
    /// leaves the statistics but removes the instruments' own touch on the frame path.
    static let markerReadingKey = "PocketDeskMarkerReading"
    static var markerReading: Bool {
        UserDefaults.standard.object(forKey: markerReadingKey) == nil || UserDefaults.standard.bool(forKey: markerReadingKey)
    }

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
