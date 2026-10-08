import Foundation
import os

/// Internal, process-lifetime instrumentation switch. Explicit NO restores the earlier counters/logs.
/// No UI setting: set before process launch. Tests inject the resolved value into each collector.
enum DetailedDiagnostics {
    static let defaultsKey = "PocketDeskDetailedDiagnostics"
    static let enabled = isEnabled(defaults: .standard)
    static let maximumStageMs: Double = 10_000
    static let feedbackAllowlist: Set<String> = ["nack", "nack pli", "ccm fir", "goog-remb", "transport-cc"]

    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) == nil || defaults.bool(forKey: defaultsKey)
    }

    static func relayProtocol(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 3 else { return nil }
        let normalized = value.lowercased()
        return ["udp", "tcp", "tls"].contains(normalized) ? normalized : nil
    }

    static func stage(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...maximumStageMs).contains(value) else { return nil }
        return value
    }
}

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
    /// Selected candidate's explicit TURN leg only; ICE `protocol`/URLs never establish this.
    var relayProtocol: String?

    init(entries: [StreamStatsEntry], detailedDiagnosticsEnabled: Bool = DetailedDiagnostics.enabled) {
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
        if detailedDiagnosticsEnabled, selected?.type == "candidate-pair" {
            // W3C only requires local relayProtocol; a native implementation may expose the remote
            // candidate's evidence too. Accept only explicit, allowlisted values on the selected pair.
            for candidateID in [selected?.string("localCandidateId"), selected?.string("remoteCandidateId")] {
                guard let candidateID, let candidate = byID[candidateID],
                      ["local-candidate", "remote-candidate"].contains(candidate.type),
                      candidate.string("candidateType") == "relay",
                      let protocolName = DetailedDiagnostics.relayProtocol(candidate.string("relayProtocol")) else { continue }
                relayProtocol = protocolName; break
            }
        }
        timestamp = (outbound ?? inbound ?? selected ?? entries.first)?.timestamp ?? 0
    }
}

/// Application-side counters gathered between two statistics samples.
struct StreamCounterSnapshot {
    var interval: TimeInterval
    var captureFrames = 0
    var captureIdleFrames = 0
    /// Complete captures with a ScreenCaptureKit display time later than every earlier one: new source pixels.
    var uniqueSourceFrames = 0
    /// Re-pushes of the last unchanged frame to keep a static desktop visible; never new source pixels.
    var captureResends = 0
    var pushedFrames = 0
    var pushSkipped = 0
    var renderedFrames = 0
    /// Decoded frames handed to the renderer with an RTP timestamp not seen recently: excludes repeats,
    /// presentation redraws and Smooth motion frames, which never pass through the WebRTC renderer.
    var uniqueDecodedFrames = 0
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
    /// B0 (`ReconfigureStallTracker`): `SCStream.updateConfiguration` calls this window, and the longest stall ended in it.
    var reconfigures: Int?
    var reconfigureStallMs: Double?
    var presentedFrames = 0
    var supersededFrames = 0
    var presentLatencyP50Ms: Double?
    var presentLatencyP90Ms: Double?
    var presentGapP90Ms: Double?
    var displayMaxFPS: Int?
    // Phone-local stages; callback→presented and delivery→presented use actual Metal presentation.
    var decodeVTP95Ms: Double?
    var decodeVTSamples: Int?
    var ownershipDelayP99Ms: Double?
    var ownershipDelaySamples: Int?
    var deliveryDelayP99Ms: Double?
    var deliveryDelaySamples: Int?
    var decodedToPresentedP95Ms: Double?
    var decodedToPresentedSamples: Int?
    var deliveryToPresentedP95Ms: Double?
    var deliveryToPresentedSamples: Int?
    var drawableAcquireP99Ms: Double?
    var drawableAcquireSamples: Int?
    var rendererFenceWaitP99Ms: Double?
    var rendererFenceWaitSamples: Int?
    var displayLinkIntervalP95Ms: Double?
    var displayLinkIntervalSamples: Int?
    var leadingMotionLatencyP95Ms: Double?
    var leadingMotionLatencySamples: Int?
    var displayLinkIntervalP50Ms: Double?
    var displayLinkAt120Share: Double?

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
    /// The same frames, submit to VideoToolbox's own callback: the encode latency less the hop to the
    /// encoder's queue and the Annex B copy (owned encoder only).
    var encodeVTP90Ms: Double?
    var encodeInFlightMax: Int?
    var encodeAtCapMs: Double?
    var encodeBytesP50: Int?
    /// Bytes the encoder produced in this window (X17 sender-queue estimate).
    var encodedBytes = 0
    var keyFrameBytesMax: Int?
    var rateUpdates: Int?
    var encoderSessionAgeS: Double?
    var encoderDropped: Int?
    var encoderDeliveryDrops: Int?
    var encoderSilentDrops: Int?
    /// Mac audio source buffers the 120 ms age fence refused in this sample.
    var audioSourceDrops: Int?
    var encoderSubmitted: Int?
    var encoderSuperseded: Int?
    var encoderRetired: Int?
    var encoderOutputs: Int?
    var encoderEvidence: VideoEncoderEvidence?
    // Host input (perf pack 1b): data-channel arrival → handled on the main queue, and CGEvent post time.
    var inputMainDelayP50Ms: Double?
    var inputMainDelayP95Ms: Double?
    var inputMainDelayMaxMs: Double?
    var inputPostP95Ms: Double?
    var inputEvents: Int?
    /// Calibrated phone send → this packet's data-channel arrival; absent without usable timing.
    var phoneSendToArrivalP50Ms: Double?
    var phoneSendToArrivalP95Ms: Double?
    var phoneSendToArrivalMaxMs: Double?
    /// Largest clock uncertainty among samples in this window (path asymmetry bound, not measured error).
    var phoneSendToArrivalUncertaintyMs: Double?
    var phoneSendToArrivalSamples: Int?
    /// Owned encoder only: admitted preparation (including pixel conversion) and synchronous VT call.
    var encodePreparationP95Ms: Double?
    var encodePreparationSamples: Int?
    var encodeSubmitP95Ms: Double?
    var encodeSubmitSamples: Int?
}

/// Compact sender-side stages the Mac forwards to the phone overlay once per statistics sample.
struct HostStreamSummary: Codable, Equatable {
    var captureFPS: Double?
    var captureLatencyMs: Double?
    var captureGapP90Ms: Double?
    /// Largest observed source gap, including idle periods; absence is unknown on older hosts.
    var captureGapMaxMs: Double?
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
    /// Frames VideoToolbox dropped without a callback (retired by a later completion) in the last sample.
    var encoderDeliveryDrops: Int?
    var encoderSilentDrops: Int?
    /// Mac audio source buffers the 120 ms age fence refused in the last sample.
    var audioSourceDrops: Int?
    var encoderEvidence: VideoEncoderEvidence?
    /// Owned encoder (X04): frames handed to VideoToolbox, in-flight deltas a requested key frame
    /// replaced, entries retired after the 100 ms window without a callback, and outputs with a sample.
    var encoderSubmitted: Int?
    var encoderSuperseded: Int?
    var encoderRetired: Int?
    var encoderOutputs: Int?
    /// Input messages: data-channel arrival → handled on the Mac's main queue, and CGEvent post time.
    var inputMainDelayP50Ms: Double?
    var inputMainDelayP95Ms: Double?
    var inputMainDelayMaxMs: Double?
    var inputPostP95Ms: Double?
    var inputEvents: Int?
    /// Calibrated phone send → this packet's data-channel arrival; absent without usable timing.
    var phoneSendToArrivalP50Ms: Double?
    var phoneSendToArrivalP95Ms: Double?
    var phoneSendToArrivalMaxMs: Double?
    /// Largest clock uncertainty among samples in this window (path asymmetry bound, not measured error).
    var phoneSendToArrivalUncertaintyMs: Double?
    var phoneSendToArrivalSamples: Int?
    // Rate, load and region (G5/G4/G12; older phones ignore these).
    var targetFPS: Int?
    var displayRefreshHz: Double?
    var captureDisplay: String?
    var captureGapMedianMs: Double?
    /// The Mac's `ProcessInfo.thermalState` raw value, 0 (nominal) … 3 (critical).
    var thermalState: Int?
    var lowPowerMode: Bool?
    var lowDataPolicyActive: Bool? = false
    var ladder: LadderState?
    var busy: BusyState?
    var captureRegion: CaptureRegion?
    /// G4: stream pixels per displayed phone pixel (`ViewportCapturePolicy.deliveredSharpness`).
    var sharpness: Double?
    // Per-frame timing (perf pack 4a; older phones ignore these): display → encoded, and the newest records.
    var frameHostP50Ms: Double?
    var frameHostP95Ms: Double?
    var frameHostMaxMs: Double?
    var frameRecords: FrameTimingRecords?
    var framesEncodedTotal: Int?
    var macLink: String?
    var uniqueSourceFPS: Double?
    var resendFPS: Double?
    /// X16: the DSCP/priority the Mac asked WebRTC for (`TransportPriorityRequest.summary`). Requested,
    /// never measured on the wire.
    var transportPriorityRequested: String?
    /// X05: the estimate ceiling last applied, and whether the LAN multiplier is in it.
    var bweCeilingKbps: Double?
    var lanCeilingApplied: Bool?
    /// X17 estimates (`SenderQueueEstimate`): the pacer's send-side wait (the governor's trigger), the
    /// drain time of encoded-but-unsent bytes (overlay only), and the round trip above its baseline.
    var senderQueueMs: Double?
    var networkQueueMs: Double?
    var backlogDrainMs: Double?
    /// X17: the governor's mode and cap ("shadow, would cap: 30 fps", "LAN, inactive", "off").
    var senderQueueGovernor: String?

    var relayProtocol: String?
    /// Nil means unknown. RTCCodecStats in the pinned WebRTC API does not expose negotiated feedback.
    var negotiatedFeedback: [String]?
    var encodePreparationP95Ms: Double?
    var encodePreparationSamples: Int?
    var encodeSubmitP95Ms: Double?
    var encodeSubmitSamples: Int?

    static let maximumFrameTotal = 1_000_000_000_000
    static let fpsRange = 1...240
    static let refreshRange = 0.0...1_000
    static let thermalRange = 0...3
    static let displayDescriptionBytes = 48
    static let transportPriorityBytes = 40
    static let governorStatusBytes = 40

    func validate() throws {
        guard relayProtocol.map({ DetailedDiagnostics.relayProtocol($0) == $0 }) ?? true,
              negotiatedFeedback.map({ !$0.isEmpty && $0.count <= DetailedDiagnostics.feedbackAllowlist.count
                  && Set($0).count == $0.count && $0.allSatisfy { DetailedDiagnostics.feedbackAllowlist.contains($0) } }) ?? true,
              [encodePreparationP95Ms, encodeSubmitP95Ms].compactMap({ $0 })
                  .allSatisfy({ DetailedDiagnostics.stage($0) != nil }),
              [encodePreparationSamples, encodeSubmitSamples].compactMap({ $0 })
                  .allSatisfy({ (1...LatencyWindow.capacity).contains($0) }) else { throw RemoteError.invalidMessage }
        let numbers = [captureFPS, captureLatencyMs, captureGapP90Ms, captureGapMaxMs, encodedFPS, encodeMs, pacerDelayMs,
                       sentFPS, sentKbps, targetKbps, maxKbps, qpAverage,
                       encodeLatencyMs, encodeLatencyP90Ms, encoderSessionAgeS, captureGapMedianMs,
                       inputMainDelayP50Ms, inputMainDelayP95Ms, inputMainDelayMaxMs, inputPostP95Ms,
                       phoneSendToArrivalP50Ms, phoneSendToArrivalP95Ms, phoneSendToArrivalMaxMs, phoneSendToArrivalUncertaintyMs,
                       uniqueSourceFPS, resendFPS,
                       bweCeilingKbps, senderQueueMs, networkQueueMs, backlogDrainMs].compactMap { $0 }
        let integers = [pushSkipped, droppedBeforeEncode, sentWidth, sentHeight, encodeInFlightMax, rateUpdates,
                        encoderDropped, encoderSilentDrops, encoderDeliveryDrops, audioSourceDrops, inputEvents,
                        encoderSubmitted, encoderSuperseded, encoderRetired, encoderOutputs].compactMap { $0 }
        let bytes = [encodeBytesP50, keyFrameBytesMax].compactMap { $0 }
        guard numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 10_000_000 }),
              integers.allSatisfy({ $0 >= 0 && $0 <= 100_000 }),
              bytes.allSatisfy({ $0 >= 0 && $0 <= 50_000_000 }),
              (encoder?.utf8.count ?? 0) <= 48, (qualityLimitation?.utf8.count ?? 0) <= 24,
              targetFPS.map({ Self.fpsRange.contains($0) }) ?? true,
              displayRefreshHz.map({ Self.refreshRange.contains($0) }) ?? true,
              thermalState.map({ Self.thermalRange.contains($0) }) ?? true,
              (captureDisplay?.utf8.count ?? 0) <= Self.displayDescriptionBytes,
              (transportPriorityRequested?.utf8.count ?? 0) <= Self.transportPriorityBytes,
              (senderQueueGovernor?.utf8.count ?? 0) <= Self.governorStatusBytes,
              framesEncodedTotal.map({ (0...Self.maximumFrameTotal).contains($0) }) ?? true,
              macLink.map({ $0.utf8.count <= MacNetworkLink.maximumBytes && MacNetworkLink(rawValue: $0) != nil }) ?? true,
              sharpness.map({ $0.isFinite && (0...1000).contains($0) }) ?? true else {
            throw RemoteError.invalidMessage
        }
        guard [phoneSendToArrivalP50Ms, phoneSendToArrivalP95Ms, phoneSendToArrivalMaxMs].compactMap({ $0 })
                  .allSatisfy({ $0 <= InputSendTiming.maximumLatencyMs }),
              phoneSendToArrivalUncertaintyMs.map({ $0 <= InputSendTiming.maximumUncertaintyMs }) ?? true,
              phoneSendToArrivalSamples.map({ (1...LatencyWindow.capacity).contains($0) }) ?? true else {
            throw RemoteError.invalidMessage
        }
        try ladder?.validate()
        try busy?.validate()
        try captureRegion?.validate()
        try encoderEvidence?.validate()
        try validateFrameTiming()
    }
}

struct StreamStatsReport: Codable, Equatable {
    /// Phone-local provenance survives the MainActor callback hop; never used as a Mac clock.
    var phoneLoadSample: PhoneLoadSampleStamp? = nil
    var role: String
    var route: String?
    var routeDetail: String?
    var codec: String?
    var h264ProfileLevel: String?
    var captureMaximumDimension: Int?

    var captureFPS: Double?
    var captureIdleFPS: Double?
    var uniqueSourceFPS: Double?
    var captureResendFPS: Double?
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
    var transportUsage: TransportUsage?
    var availableOutgoingKbps: Double?
    var keyFrames: Int?
    var nackReceived: Int?
    var pliReceived: Int?
    var remoteLossPercent: Double?
    /// The RTCP receiver report's round trip (about once a second); `rttMs` is the candidate pair's STUN one.
    var rtcpRttMs: Double?
    var rtcpRttMeasurements: Double?

    var receivedFPS: Double?
    var decodedFPS: Double?
    var uniqueDecodedFPS: Double?
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
    var rttSampleMs: Double?
    var hostFramesEncodedTotal: Int?
    var framesArrivedAtMark: Int?
    var frameMarkAt: TimeInterval?
    var frameHealthPercent: Double?
    var connectionQuality: String?
    var qualityMeasuredWindows: Int?
    var qualityPoorEntries: Int?
    var rttStdDevMs: Double?
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
    /// Replacement rate over the actual counter window; `supersededFrames` remains its raw count.
    var supersededPerSecond: Double?
    var presentLatencyMs: Double?
    var presentLatencyP90Ms: Double?
    var presentGapP90Ms: Double?
    var displayMaxFPS: Int?
    // Phone-local stages; callback→presented and delivery→presented use actual Metal presentation.
    var decodeVTP95Ms: Double?
    var decodeVTSamples: Int?
    var ownershipDelayP99Ms: Double?
    var ownershipDelaySamples: Int?
    var deliveryDelayP99Ms: Double?
    var deliveryDelaySamples: Int?
    var decodedToPresentedP95Ms: Double?
    var decodedToPresentedSamples: Int?
    var deliveryToPresentedP95Ms: Double?
    var deliveryToPresentedSamples: Int?
    var drawableAcquireP99Ms: Double?
    var drawableAcquireSamples: Int?
    var rendererFenceWaitP99Ms: Double?
    var rendererFenceWaitSamples: Int?
    var displayLinkIntervalP95Ms: Double?
    var displayLinkIntervalSamples: Int?
    var leadingMotionLatencyP95Ms: Double?
    var leadingMotionLatencySamples: Int?
    var displayLinkIntervalP50Ms: Double?
    var displayLinkAt120Share: Double?
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
    var encodeVTP90Ms: Double?
    var encodeInFlightMax: Int?
    /// Local trace only; deliberately excluded from HostStreamSummary / control messages.
    var encodeAtCapShare: Double?
    var encodeBytesP50: Int?
    var keyFrameBytesMax: Int?
    var rateUpdates: Int?
    var encoderSessionAgeS: Double?
    var encoderDropped: Int?
    var encoderDeliveryDrops: Int?
    var encoderSilentDrops: Int?
    /// Mac audio source buffers the 120 ms age fence refused in this sample.
    var audioSourceDrops: Int?
    var encoderSubmitted: Int?
    var encoderSuperseded: Int?
    var encoderRetired: Int?
    var encoderOutputs: Int?
    var encoderEvidence: VideoEncoderEvidence?
    var inputMainDelayP50Ms: Double?
    var inputMainDelayP95Ms: Double?
    var inputMainDelayMaxMs: Double?
    var inputPostP95Ms: Double?
    var inputEvents: Int?
    /// Calibrated phone send → this packet's data-channel arrival; absent without usable timing.
    var phoneSendToArrivalP50Ms: Double?
    var phoneSendToArrivalP95Ms: Double?
    var phoneSendToArrivalMaxMs: Double?
    /// Largest clock uncertainty among samples in this window (path asymmetry bound, not measured error).
    var phoneSendToArrivalUncertaintyMs: Double?
    var phoneSendToArrivalSamples: Int?
    // Rate, load and region. This device's thermal state and Low Power Mode on both roles; the
    // rest is the host's (the phone sees the Mac's through `host`).
    var targetFPS: Int?
    var displayRefreshHz: Double?
    var captureDisplay: String?
    var captureGapMedianMs: Double?
    var thermalState: Int?
    var lowPowerMode: Bool?
    var lowDataPolicyActive: Bool? = false
    var ladder: LadderState?
    var busy: BusyState?
    var captureRegion: CaptureRegion?
    var sharpness: Double?
    var transportPriorityRequested: String?
    var bweCeilingKbps: Double?
    var lanCeilingApplied: Bool?
    /// `LANTrustTracker`'s verdict this second (host only); the ladder reads it from here.
    var lanTrusted: Bool?
    /// Host, remote route: whether the selected pair is the remote-route proof's address pair; nil
    /// when no such proof passed (`StreamTuning.remoteRouteLANProof` off, a local route, or no pass).
    var remoteRouteLANPair: Bool?
    /// The `LANBitrateFloor` under the estimate this second, nil while the link is not trusted.
    var lanFloorKbps: Double?
    /// Host, local log only (B0, `ReconfigureStallTracker`): capture reconfigurations requested this window and
    /// the longest request → first-frame stall that ended in it; both nil when neither happened.
    var reconfigures: Int?
    var reconfigureStallMs: Double?
    var senderQueueMs: Double?
    var networkQueueMs: Double?
    var backlogDrainMs: Double?
    var senderQueueGovernor: String?
    // Per-frame timing (perf pack 4a). Host: display → encoded; phone: Mac display → decoded here.
    var frameHostP50Ms: Double?
    var frameHostP95Ms: Double?
    var frameHostMaxMs: Double?
    var frameToPhoneP50Ms: Double?
    var frameToPhoneP95Ms: Double?
    var frameToPhoneMaxMs: Double?
    var frameTimedCount: Int?
    var frameJoinLocked: Bool?
    // In-band exact software timing, independent of heuristic RTP/size joins and pixel bench markers.
    var exactDecoded: Int?
    var exactPresented: Int?
    var exactUniqueSources: Int?
    var exactResends: Int?
    var exactTimed: Int?
    var exactMissingClock: Int?
    var exactSourceToDecodeP50Ms: Double?
    var exactSourceToDecodeP95Ms: Double?
    var exactSourceToPresentP50Ms: Double?
    var exactSourceToPresentP95Ms: Double?
    var exactClockUncertaintyMs: Double?

    /// Present only when the added process-lifetime instrumentation is on; absent restores old logs.
    var detailedDiagnosticsEnabled: Bool?
    var relayProtocol: String?
    /// Unknown with this pinned getStats API; counters, requested policy and SDP are not substitutes.
    var negotiatedFeedback: [String]?
    var encodePreparationP95Ms: Double?
    var encodePreparationSamples: Int?
    var encodeSubmitP95Ms: Double?
    var encodeSubmitSamples: Int?
    /// Encoded image receive observation → decoded output observation; includes work and scheduling.
    /// This is not an isolated decoder queue-wait measurement.
    var receiveToDecodedP95Ms: Double?
    var receiveToDecodedSamples: Int?

    init(role: String, previous: StreamStatsSample?, current: StreamStatsSample,
         counters: StreamCounterSnapshot?, detailedDiagnosticsEnabled: Bool = DetailedDiagnostics.enabled) {
        self.role = role
        if detailedDiagnosticsEnabled {
            self.detailedDiagnosticsEnabled = true
            relayProtocol = current.relayProtocol
        }
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
        rtcpRttMs = Self.round(current.remoteInbound?.number("roundTripTime").map { $0 * 1000 })
        rtcpRttMeasurements = current.remoteInbound?.number("roundTripTimeMeasurements")

        var sentBytes: Double?
        if let previous, current.timestamp > previous.timestamp {
            let seconds = current.timestamp - previous.timestamp
            let out = Delta(previous.outbound, current.outbound)
            let source = Delta(previous.mediaSource, current.mediaSource)
            let inbound = Delta(previous.inbound, current.inbound)
            if previous.pair?.id == current.pair?.id {
                let pair = Delta(previous.pair, current.pair)
                rttSampleMs = Self.perItem(pair["totalRoundTripTime"], pair["responsesReceived"], scale: 1000)
            }
            sourceFPS = Self.rate(source["frames"], seconds)
            encodedFPS = Self.rate(out["framesEncoded"], seconds)
            sentFPS = Self.rate(out["framesSent"], seconds)
            encodeMs = Self.perItem(out["totalEncodeTime"], out["framesEncoded"], scale: 1000)
            qpAverage = Self.perItem(out["qpSum"], out["framesEncoded"])
            sentKbps = Self.rate(out["bytesSent"].map { $0 * 8 / 1000 }, seconds)
            sentBytes = out["bytesSent"].flatMap { $0 >= 0 ? $0 : nil }
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

        if let counters, counters.interval.isFinite, counters.interval > 0 {
            let seconds = counters.interval
            if role == "host" {
                captureFPS = Self.round(Double(counters.captureFrames) / seconds)
                captureIdleFPS = Self.round(Double(counters.captureIdleFrames) / seconds)
                uniqueSourceFPS = Self.round(Double(counters.uniqueSourceFrames) / seconds)
                captureResendFPS = Self.round(Double(counters.captureResends) / seconds)
                pushedFPS = Self.round(Double(counters.pushedFrames) / seconds)
                pushSkipped = counters.pushSkipped
                captureLatencyMs = Self.round(counters.captureLatencyP50Ms)
                captureLatencyP90Ms = Self.round(counters.captureLatencyP90Ms)
                captureGapP90Ms = Self.round(counters.captureGapP90Ms)
                captureGapMaxMs = Self.round(counters.captureGapMaxMs)
                captureGapMedianMs = Self.round(counters.captureGapMedianMs)
                reconfigures = counters.reconfigures.map { min($0, 100_000) }
                reconfigureStallMs = Self.round(counters.reconfigureStallMs.map { min($0, 10_000_000) })
                encodeLatencyMs = Self.round(counters.encodeLatencyP50Ms)
                encodeLatencyP90Ms = Self.round(counters.encodeLatencyP90Ms)
                encodeLatencyMaxMs = Self.round(counters.encodeLatencyMaxMs)
                encodeVTP90Ms = Self.round(counters.encodeVTP90Ms)
                if detailedDiagnosticsEnabled {
                    encodePreparationP95Ms = Self.round(DetailedDiagnostics.stage(counters.encodePreparationP95Ms))
                    encodePreparationSamples = counters.encodePreparationSamples
                    encodeSubmitP95Ms = Self.round(DetailedDiagnostics.stage(counters.encodeSubmitP95Ms))
                    encodeSubmitSamples = counters.encodeSubmitSamples
                }
                encodeInFlightMax = counters.encodeInFlightMax
                encodeAtCapShare = counters.encodeAtCapMs.map { min(1, max(0, $0 / (seconds * 1000))) }
                encodeBytesP50 = counters.encodeBytesP50
                keyFrameBytesMax = counters.keyFrameBytesMax
                rateUpdates = counters.rateUpdates
                encoderSessionAgeS = Self.round(counters.encoderSessionAgeS)
                encoderDropped = counters.encoderDropped
                encoderDeliveryDrops = counters.encoderDeliveryDrops
                encoderSilentDrops = counters.encoderSilentDrops
                audioSourceDrops = counters.audioSourceDrops
                encoderSubmitted = counters.encoderSubmitted
                encoderSuperseded = counters.encoderSuperseded
                encoderRetired = counters.encoderRetired
                encoderOutputs = counters.encoderOutputs
                encoderEvidence = counters.encoderEvidence
                if let evidence = encoderEvidence { powerEfficientEncoder = evidence.hardwareReported }
                inputMainDelayP50Ms = Self.round(counters.inputMainDelayP50Ms)
                inputMainDelayP95Ms = Self.round(counters.inputMainDelayP95Ms)
                inputMainDelayMaxMs = Self.round(counters.inputMainDelayMaxMs)
                inputPostP95Ms = Self.round(counters.inputPostP95Ms)
                inputEvents = counters.inputEvents
                phoneSendToArrivalP50Ms = Self.round(Self.inputTimingValue(counters.phoneSendToArrivalP50Ms))
                phoneSendToArrivalP95Ms = Self.round(Self.inputTimingValue(counters.phoneSendToArrivalP95Ms))
                phoneSendToArrivalMaxMs = Self.round(Self.inputTimingValue(counters.phoneSendToArrivalMaxMs))
                phoneSendToArrivalUncertaintyMs = Self.round(Self.inputTimingValue(counters.phoneSendToArrivalUncertaintyMs,
                    maximum: InputSendTiming.maximumUncertaintyMs))
                phoneSendToArrivalSamples = counters.phoneSendToArrivalSamples
                senderQueueMs = pacerDelayMs
                backlogDrainMs = Self.round(SenderQueueEstimate.backlogDrainMs(encodedBytes: Double(counters.encodedBytes),
                    sentBytes: sentBytes, availableKbps: availableOutgoingKbps))
            } else {
                renderedFPS = Self.round(Double(counters.renderedFrames) / seconds)
                uniqueDecodedFPS = Self.round(Double(counters.uniqueDecodedFrames) / seconds)
                renderGapMedianMs = Self.round(counters.renderGapMedianMs)
                renderGapP90Ms = Self.round(counters.renderGapP90Ms)
                renderGapMaxMs = Self.round(counters.renderGapMaxMs)
                coalescedMoves = counters.coalescedMoves
                displayMaxFPS = counters.displayMaxFPS
                decodeVTP95Ms = Self.round(counters.decodeVTP95Ms)
                decodeVTSamples = counters.decodeVTSamples
                ownershipDelayP99Ms = Self.round(counters.ownershipDelayP99Ms)
                ownershipDelaySamples = counters.ownershipDelaySamples
                deliveryDelayP99Ms = Self.round(counters.deliveryDelayP99Ms)
                deliveryDelaySamples = counters.deliveryDelaySamples
                decodedToPresentedP95Ms = Self.round(counters.decodedToPresentedP95Ms)
                decodedToPresentedSamples = counters.decodedToPresentedSamples
                deliveryToPresentedP95Ms = Self.round(counters.deliveryToPresentedP95Ms)
                deliveryToPresentedSamples = counters.deliveryToPresentedSamples
                drawableAcquireP99Ms = Self.round(counters.drawableAcquireP99Ms)
                drawableAcquireSamples = counters.drawableAcquireSamples
                rendererFenceWaitP99Ms = Self.round(counters.rendererFenceWaitP99Ms)
                rendererFenceWaitSamples = counters.rendererFenceWaitSamples
                displayLinkIntervalP95Ms = Self.round(counters.displayLinkIntervalP95Ms)
                displayLinkIntervalSamples = counters.displayLinkIntervalSamples
                leadingMotionLatencyP95Ms = Self.round(counters.leadingMotionLatencyP95Ms)
                leadingMotionLatencySamples = counters.leadingMotionLatencySamples
                displayLinkIntervalP50Ms = Self.round(counters.displayLinkIntervalP50Ms)
                displayLinkAt120Share = counters.displayLinkAt120Share
                if counters.presentedFrames > 0 || counters.supersededFrames > 0 {
                    presentedFPS = Self.round(Double(counters.presentedFrames) / seconds)
                    supersededFrames = counters.supersededFrames
                    let replacementRate = Double(counters.supersededFrames) / seconds
                    supersededPerSecond = replacementRate.isFinite ? replacementRate : nil
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
                          captureGapMaxMs: captureGapMaxMs.map { min($0, 10_000_000) },
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
                          encoderDeliveryDrops: encoderDeliveryDrops.map { min($0, 100_000) },
                          encoderSilentDrops: encoderSilentDrops.map { min($0, 100_000) },
                          audioSourceDrops: audioSourceDrops.map { min($0, 100_000) },
                          encoderEvidence: encoderEvidence,
                          encoderSubmitted: encoderSubmitted.map { min($0, 100_000) },
                          encoderSuperseded: encoderSuperseded.map { min($0, 100_000) },
                          encoderRetired: encoderRetired.map { min($0, 100_000) },
                          encoderOutputs: encoderOutputs.map { min($0, 100_000) },
                          inputMainDelayP50Ms: inputMainDelayP50Ms.map { min($0, 10_000_000) },
                          inputMainDelayP95Ms: inputMainDelayP95Ms.map { min($0, 10_000_000) },
                          inputMainDelayMaxMs: inputMainDelayMaxMs.map { min($0, 10_000_000) },
                          inputPostP95Ms: inputPostP95Ms.map { min($0, 10_000_000) },
                          inputEvents: inputEvents.map { min($0, 100_000) },
                          phoneSendToArrivalP50Ms: Self.inputTimingValue(phoneSendToArrivalP50Ms),
                          phoneSendToArrivalP95Ms: Self.inputTimingValue(phoneSendToArrivalP95Ms),
                          phoneSendToArrivalMaxMs: Self.inputTimingValue(phoneSendToArrivalMaxMs),
                          phoneSendToArrivalUncertaintyMs: Self.inputTimingValue(phoneSendToArrivalUncertaintyMs,
                              maximum: InputSendTiming.maximumUncertaintyMs),
                          phoneSendToArrivalSamples: phoneSendToArrivalSamples.flatMap { (1...LatencyWindow.capacity).contains($0) ? $0 : nil },
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
                          lowDataPolicyActive: lowDataPolicyActive,
                          ladder: ladder.flatMap { (try? $0.validate()) == nil ? nil : $0 },
                          busy: busy.flatMap { (try? $0.validate()) == nil ? nil : $0 },
                          captureRegion: captureRegion.flatMap { (try? $0.validate()) == nil ? nil : $0 },
                          sharpness: sharpness.flatMap { $0.isFinite ? min(max(0, $0), 1000) : nil },
                          uniqueSourceFPS: uniqueSourceFPS.map { min($0, 10_000_000) },
                          resendFPS: captureResendFPS.map { min($0, 10_000_000) },
                          transportPriorityRequested: transportPriorityRequested.map {
                              Self.truncated($0, bytes: HostStreamSummary.transportPriorityBytes)
                          },
                          bweCeilingKbps: bweCeilingKbps.flatMap { $0.isFinite ? min(max(0, $0), 10_000_000) : nil },
                          lanCeilingApplied: lanCeilingApplied,
                          senderQueueMs: senderQueueMs.flatMap { $0.isFinite ? min(max(0, $0), 10_000_000) : nil },
                          networkQueueMs: networkQueueMs.flatMap { $0.isFinite ? min(max(0, $0), 10_000_000) : nil },
                          backlogDrainMs: backlogDrainMs.flatMap { $0.isFinite ? min(max(0, $0), 10_000_000) : nil },
                          senderQueueGovernor: senderQueueGovernor.map {
                              Self.truncated($0, bytes: HostStreamSummary.governorStatusBytes)
                          },
                          relayProtocol: detailedDiagnosticsEnabled == true ? DetailedDiagnostics.relayProtocol(relayProtocol) : nil,
                          negotiatedFeedback: detailedDiagnosticsEnabled == true ? negotiatedFeedback.flatMap {
                              !$0.isEmpty && $0.count <= DetailedDiagnostics.feedbackAllowlist.count && Set($0).count == $0.count
                                  && $0.allSatisfy { DetailedDiagnostics.feedbackAllowlist.contains($0) } ? $0 : nil
                          } : nil,
                          encodePreparationP95Ms: detailedDiagnosticsEnabled == true ? DetailedDiagnostics.stage(encodePreparationP95Ms) : nil,
                          encodePreparationSamples: detailedDiagnosticsEnabled == true ? encodePreparationSamples.flatMap {
                              (1...LatencyWindow.capacity).contains($0) ? $0 : nil
                          } : nil,
                          encodeSubmitP95Ms: detailedDiagnosticsEnabled == true ? DetailedDiagnostics.stage(encodeSubmitP95Ms) : nil,
                          encodeSubmitSamples: detailedDiagnosticsEnabled == true ? encodeSubmitSamples.flatMap {
                              (1...LatencyWindow.capacity).contains($0) ? $0 : nil
                          } : nil)
    }

    private static func inputTimingValue(_ value: Double?, maximum: Double = InputSendTiming.maximumLatencyMs) -> Double? {
        guard let value, value.isFinite, (0...maximum).contains(value) else { return nil }
        return value
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
        var exported = self
        // A newer host may still send the added fields to a phone running with its switch off.
        // Keep that phone's persisted stream log at the prior instrumentation surface too.
        if detailedDiagnosticsEnabled != true {
            exported.host?.relayProtocol = nil; exported.host?.negotiatedFeedback = nil
            exported.host?.encodePreparationP95Ms = nil; exported.host?.encodePreparationSamples = nil
            exported.host?.encodeSubmitP95Ms = nil; exported.host?.encodeSubmitSamples = nil
        }
        let json = (try? encoder.encode(exported)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "PDSTATS " + json
    }

    var summaryLines: [String] {
        func value(_ number: Double?, _ unit: String = "") -> String {
            guard let number else { return "–" }
            return number >= 100 ? "\(Int(number.rounded()))\(unit)" : String(format: "%.1f%@", number, unit)
        }
        func hardware(_ flag: Bool?) -> String { flag == true ? "hw" : flag == false ? "sw?" : "hw?" }
        func inputLine(_ prefix: String, _ events: Int?, _ p50: Double?, _ p95: Double?, _ maximum: Double?,
                       _ post: Double?) -> String? {
            guard let events, events > 0 else { return nil }
            return "\(prefix)input main p50 \(value(p50, "ms")) p95 \(value(p95, "ms")) max \(value(maximum, "ms")) · post p95 \(value(post, "ms")) · n \(events)"
        }
        func dropped(_ count: Int?, _ silent: Int? = nil, audio: Int? = nil) -> String {
            (count.map { " · dropped \($0)/s" } ?? "") + (silent.map { " · VT lost \($0)" } ?? "")
                + (audio.map { " · audio stale \($0)" } ?? "")
        }
        func queueLine(_ pacer: Double?, _ backlog: Double?, _ network: Double?) -> String? {
            guard pacer != nil || backlog != nil || network != nil else { return nil }
            return "queue estimate: pacer \(value(pacer, "ms")) · unsent backlog ≈\(value(backlog, "ms")) · network ≈\(value(network, "ms"))"
        }
        func gate(_ submitted: Int?, _ outputs: Int?, _ superseded: Int?, _ retired: Int?) -> String? {
            guard let submitted else { return nil }
            return "VT in \(submitted) out \(outputs ?? 0) · superseded \(superseded ?? 0) · retired \(retired ?? 0)"
        }
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
        if detailedDiagnosticsEnabled == true {
            lines.append("relay transport \(relayProtocol?.uppercased() ?? "unknown") · negotiated feedback \(negotiatedFeedback?.joined(separator: ", ") ?? "unknown")")
        }
        let preparation = role == "host" ? encodePreparationP95Ms : host?.encodePreparationP95Ms
        let preparationCount = role == "host" ? encodePreparationSamples : host?.encodePreparationSamples
        let submit = role == "host" ? encodeSubmitP95Ms : host?.encodeSubmitP95Ms
        let submitCount = role == "host" ? encodeSubmitSamples : host?.encodeSubmitSamples
        if detailedDiagnosticsEnabled == true, preparationCount != nil || submitCount != nil {
            lines.append("encode preparation p95 \(value(preparation, "ms")) (n \(preparationCount ?? 0)) · synchronous VT submit p95 \(value(submit, "ms")) (n \(submitCount ?? 0))")
        }
        if detailedDiagnosticsEnabled == true, let count = receiveToDecodedSamples {
            lines.append("receive → decoded completion p95 \(value(receiveToDecodedP95Ms, "ms")) · n \(count) (includes decoding; queue wait unknown)")
        }
        if let connectionQuality {
            lines.append("picture \(connectionQuality) · missed \(value(frameHealthPercent, "%")) · RTT spread \(value(rttStdDevMs, "ms"))")
        }
        if role == "host" {
            if let rate = rateLine("", target: targetFPS, refresh: displayRefreshHz, display: captureDisplay,
                                   gapMedian: captureGapMedianMs, thermal: thermalState, lowPower: lowPowerMode) {
                lines.append(rate)
            }
            lines.append("capture \(value(captureFPS))fps lag \(value(captureLatencyMs, "ms")) p90 \(value(captureLatencyP90Ms, "ms")) · gap p90 \(value(captureGapP90Ms, "ms")) · cap \(captureMaximumDimension.map(String.init) ?? "–")")
            lines.append("unique source \(value(uniqueSourceFPS))fps · idle resends \(value(captureResendFPS))/s")
            lines.append("pushed \(value(pushedFPS)) · skipped \(pushSkipped ?? 0) · dropped pre-encode \(droppedBeforeEncode ?? 0)")
            lines.append("encode \(value(encodedFPS))fps \(value(encodeMs, "ms")) · pacer \(value(pacerDelayMs, "ms")) · sent \(value(sentFPS))fps \(sentWidth ?? 0)×\(sentHeight ?? 0)")
            if let queue = queueLine(senderQueueMs, backlogDrainMs, networkQueueMs) { lines.append(queue) }
            if let senderQueueGovernor { lines.append("governor: \(senderQueueGovernor)") }
            lines.append("\(value(sentKbps, "kbps")) · target \(value(targetKbps, "kbps")) · max \(value(maxKbps, "kbps")) · BWE \(value(availableOutgoingKbps, "kbps"))"
                         + (bweCeilingKbps.map { " · ceiling \(value($0, "kbps"))" + (lanCeilingApplied == true ? " (LAN raised)" : "") } ?? ""))
            lines.append("\(encoderImplementation ?? "encoder?") \(hardware(powerEfficientEncoder)) · limit \(qualityLimitation ?? "?") · QP \(value(qpAverage)) · rtx \(retransmittedPackets ?? 0)")
            if let encoderEvidence { lines.append(encoderEvidence.summary) }
            if encodeLatencyMs != nil || encoderDropped != nil {
                lines.append("VT lat p50 \(value(encodeLatencyMs, "ms")) p90 \(value(encodeLatencyP90Ms, "ms")) max \(value(encodeLatencyMaxMs, "ms")) · in-flight ≤\(encodeInFlightMax ?? 0) · bytes p50 \(encodeBytesP50 ?? 0) · key ≤\((keyFrameBytesMax ?? 0) / 1024)KB · rate upd \(rateUpdates ?? 0) · session \(value(encoderSessionAgeS, "s"))"
                             + dropped(encoderDropped, encoderSilentDrops, audio: audioSourceDrops))
            }
            if let gate = gate(encoderSubmitted, encoderOutputs, encoderSuperseded, encoderRetired) { lines.append(gate) }
            if let load = loadLine("", ladder: ladder, busy: busy, region: captureRegion) { lines.append(load) }
            if let transportPriorityRequested { lines.append("QoS requested (not measured): \(transportPriorityRequested)") }
            if let input = inputLine("", inputEvents, inputMainDelayP50Ms, inputMainDelayP95Ms, inputMainDelayMaxMs,
                                     inputPostP95Ms) {
                lines.append(input)
            }
            if let count = phoneSendToArrivalSamples {
                lines.append("phone send → arrival p50 \(value(phoneSendToArrivalP50Ms, "ms")) p95 \(value(phoneSendToArrivalP95Ms, "ms")) max \(value(phoneSendToArrivalMaxMs, "ms")) ±\(value(phoneSendToArrivalUncertaintyMs, "ms")) · n \(count)")
            }
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
                if let queue = queueLine(host.senderQueueMs, host.backlogDrainMs, host.networkQueueMs) { lines.append("Mac " + queue) }
                if let governor = host.senderQueueGovernor { lines.append("Mac governor: \(governor)") }
                lines.append("Mac \(host.encoder ?? "encoder?") \(hardware(host.hardwareEncoder)) \(host.sentWidth ?? 0)×\(host.sentHeight ?? 0) · limit \(host.qualityLimitation ?? "?") · age \(value(hostSummaryAgeMs, "ms"))")
                if let evidence = host.encoderEvidence { lines.append("Mac " + evidence.summary) }
                if host.encodeLatencyMs != nil || host.encoderDropped != nil {
                    lines.append("Mac VT lat p50 \(value(host.encodeLatencyMs, "ms")) p90 \(value(host.encodeLatencyP90Ms, "ms")) · in-flight ≤\(host.encodeInFlightMax ?? 0) · bytes p50 \(host.encodeBytesP50 ?? 0) · key ≤\((host.keyFrameBytesMax ?? 0) / 1024)KB · rate upd \(host.rateUpdates ?? 0) · session \(value(host.encoderSessionAgeS, "s"))"
                                 + dropped(host.encoderDropped, host.encoderSilentDrops, audio: host.audioSourceDrops))
                }
                if let gate = gate(host.encoderSubmitted, host.encoderOutputs, host.encoderSuperseded, host.encoderRetired) {
                    lines.append("Mac " + gate)
                }
                if let load = loadLine("Mac ", ladder: host.ladder, busy: host.busy, region: host.captureRegion) {
                    lines.append(load)
                }
                if let requested = host.transportPriorityRequested {
                    lines.append("Mac QoS requested (not measured): \(requested)")
                }
                if let input = inputLine("Mac ", host.inputEvents, host.inputMainDelayP50Ms, host.inputMainDelayP95Ms,
                                         host.inputMainDelayMaxMs, host.inputPostP95Ms) {
                    lines.append(input)
                }
                if let count = host.phoneSendToArrivalSamples {
                    lines.append("phone send → Mac arrival p50 \(value(host.phoneSendToArrivalP50Ms, "ms")) p95 \(value(host.phoneSendToArrivalP95Ms, "ms")) max \(value(host.phoneSendToArrivalMaxMs, "ms")) ±\(value(host.phoneSendToArrivalUncertaintyMs, "ms")) · n \(count)")
                }
            }
            if let own = rateLine("phone ", target: nil, refresh: nil, display: nil, gapMedian: nil,
                                  thermal: thermalState, lowPower: lowPowerMode) {
                lines.append(own)
            }
            lines.append("unique source \(value(host?.uniqueSourceFPS))fps (Mac) · unique decoded \(value(uniqueDecodedFPS))fps · Mac resends \(value(host?.resendFPS))/s")
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
        if let exactDecoded {
            lines.append("exact tagged software source→decode p50/p95 \(value(exactSourceToDecodeP50Ms, "ms"))/\(value(exactSourceToDecodeP95Ms, "ms")) · source→public presentation \(value(exactSourceToPresentP50Ms, "ms"))/\(value(exactSourceToPresentP95Ms, "ms")) ±\(value(exactClockUncertaintyMs, "ms"))")
            lines.append("tagged records decoded \(exactDecoded) · original presented \(exactPresented ?? 0) · unique sources \(exactUniqueSources ?? 0) · resends \(exactResends ?? 0) · timed \(exactTimed ?? 0) · clock unavailable \(exactMissingClock ?? 0)")
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

/// B0: the capture stall an `SCStream.updateConfiguration` costs, from the request to the first complete frame
/// that can show it: displayed after the newest request and, when the output size changed, at the new size. A
/// request while one is still open keeps the earlier start, so back-to-back updates are one stall ending at the
/// newest size. A crop that keeps its pixel size ends at the first frame displayed after the request, which may
/// still be an old-region frame, so that case can read short. A stall still open after `abandonAfterMs` is
/// recorded as `abandonAfterMs` (a floor) when complete frames kept arriving without qualifying, and dropped when
/// none arrived (a still screen sends none). A failed update reverts to the stall that was open before it; a
/// retired capture cancels the open stall.
struct ReconfigureStallTracker {
    static let abandonAfterMs = 3_000.0
    private struct Pending {
        var startedMs: Double
        var latestRequestMs: Double
        var width: Int
        var height: Int
        var sizeChanged: Bool
        var sawFrame = false
    }
    private var pending: Pending?
    private var beforeLatest: Pending?
    private var requests = 0
    private var longestMs: Double?

    mutating func requested(atMs now: Double, width: Int, height: Int, previousWidth: Int, previousHeight: Int) {
        expire(atMs: now)
        requests += 1
        beforeLatest = pending
        let changed = width != previousWidth || height != previousHeight
        if var open = pending {
            open.latestRequestMs = now
            open.sizeChanged = open.sizeChanged || changed
            open.width = width; open.height = height
            pending = open
        } else {
            pending = Pending(startedMs: now, latestRequestMs: now, width: width, height: height, sizeChanged: changed)
        }
    }

    /// The newest request failed: the stall open before it, if any, still waits for its own frame.
    mutating func failed() {
        if pending != nil { pending = beforeLatest }
        beforeLatest = nil
    }

    mutating func cancel() { pending = nil; beforeLatest = nil }

    /// A complete frame reached the capture callback at `now`; `displayMs` is its ScreenCaptureKit display time (0 unknown).
    mutating func frame(atMs now: Double, displayMs: Double, width: Int, height: Int) {
        expire(atMs: now)
        guard var open = pending else { return }
        guard displayMs <= 0 || displayMs >= open.latestRequestMs,
              !open.sizeChanged || (width == open.width && height == open.height) else {
            open.sawFrame = true; pending = open
            return
        }
        pending = nil; beforeLatest = nil
        record(max(0, now - open.startedMs))
    }

    mutating func drain(atMs now: Double) -> (reconfigures: Int?, longestStallMs: Double?) {
        expire(atMs: now)
        defer { requests = 0; longestMs = nil }
        return (requests > 0 ? requests : nil, longestMs)
    }

    private mutating func record(_ stallMs: Double) { longestMs = max(longestMs ?? 0, stallMs) }

    private mutating func expire(atMs now: Double) {
        guard let open = pending, now - open.startedMs > Self.abandonAfterMs else { return }
        pending = nil; beforeLatest = nil
        if open.sawFrame { record(Self.abandonAfterMs) }
    }
}

/// X17: sender-queue estimates from per-window statistics. None is a wire measurement.
/// - `senderQueueMs` (the governor's trigger) = the pacer's mean per-packet send delay this window.
/// - `backlogDrainMs` (overlay only) = max(0, bytes the encoder produced this window − outbound-rtp
///   `bytesSent` this window) × 8 / `availableOutgoingBitrate` (kbps, so bits per ms). A key frame that
///   straddles two windows or misaligned counter/stats windows inflate it, so nothing acts on it.
/// - `networkQueueMs` = current RTT − the lowest RTT seen on this transport (floored at 0): queueing
///   beyond the Mac, the delay-based signal congestion control also reads.
enum SenderQueueEstimate {
    static func backlogDrainMs(encodedBytes: Double?, sentBytes: Double?, availableKbps: Double?) -> Double? {
        guard let encodedBytes, let sentBytes, let availableKbps, availableKbps > 0,
              encodedBytes.isFinite, sentBytes.isFinite, availableKbps.isFinite else { return nil }
        return max(0, encodedBytes - sentBytes) * 8 / availableKbps
    }

    static func networkQueueMs(rttMs: Double?, baselineRTTMs: Double?) -> Double? {
        guard let rttMs, let baselineRTTMs, rttMs.isFinite, baselineRTTMs.isFinite else { return nil }
        return max(0, rttMs - baselineRTTMs)
    }
}

/// A local observed duration. Decode stages are added once for a delivered trace; presentation
/// stages belong only to original frames confirmed by the Metal drawable presented handler.
enum PhoneRenderTimingMetric: CaseIterable, Hashable, Sendable {
    case decodeVT, ownershipDelay, deliveryDelay, decodedToPresented, deliveryToPresented
    case drawableAcquire, rendererFenceWait, displayLinkInterval, leadingMotionLatency
}

/// Thread-safe counters fed from capture, WebRTC and renderer threads.
final class StreamCounters: @unchecked Sendable {
    private let lock = NSLock()
    private let phoneRenderTimingEnabled: Bool
    let detailedDiagnosticsEnabled: Bool
    private var phoneRenderWindows: [PhoneRenderTimingMetric: LatencyWindow] = [:]
    private var displayLinkAt120 = 0
    private var displayLinkIntervals = 0

    init(phoneRenderTimingEnabled: Bool = PhoneRenderTiming.enabled,
         detailedDiagnosticsEnabled: Bool = DetailedDiagnostics.enabled) {
        self.phoneRenderTimingEnabled = phoneRenderTimingEnabled
        self.detailedDiagnosticsEnabled = detailedDiagnosticsEnabled
    }

    func phoneDecodeTrace(_ trace: PhoneDecodeTrace) {
        guard phoneRenderTimingEnabled, trace.isValid,
              let submitMs = trace.submitMs, let callbackMs = trace.callbackMs,
              let ownershipMs = trace.ownershipMs else { return }
        lock.lock(); defer { lock.unlock() }
        phoneRenderWindows[.decodeVT, default: LatencyWindow()].record(callbackMs - submitMs)
        phoneRenderWindows[.ownershipDelay, default: LatencyWindow()].record(ownershipMs - callbackMs)
        phoneRenderWindows[.deliveryDelay, default: LatencyWindow()].record(trace.deliveryMs - callbackMs)
    }

    func phoneRenderTiming(_ metric: PhoneRenderTimingMetric, milliseconds: Double) {
        guard phoneRenderTimingEnabled, milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        phoneRenderWindows[metric, default: LatencyWindow()].record(milliseconds)
        if metric == .displayLinkInterval, displayLinkIntervals < LatencyWindow.capacity {
            displayLinkIntervals += 1
            if milliseconds <= 9 { displayLinkAt120 += 1 }
        }
    }

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
    private var encodeVTLatency = LatencyWindow()
    private var encodePreparation = LatencyWindow()
    private var encodeSubmit = LatencyWindow()
    private var encodeBytes = LatencyWindow()
    private var lastPresentedMs: Double?
    private var lastMarkerTime: UInt32?
    private var lastFlash: Bool?
    private var lastClickSentMs: Double?
    private var clock: ClockSyncEstimate?
    private var clockObservedAtMs: Double?
    private var legibility: LegibilitySummary?
    private var presentedAt120 = 0
    private var presentedIntervalCount = 0
    private var encodeInFlightMax = 0
    private var encodeAtCapSinceMs: Double?
    private var encodeAtCapAccumulatedMs = 0.0
    private var encodeCapacityObserved = false
    private var keyFrameBytesMax = 0
    private var rateUpdates = 0
    private var encoderDropped = 0
    private var encoderDeliveryDrops = 0
    private var encoderSilentDrops = 0
    private var audioSourceDrops = 0
    private var gateSubmitted = 0
    private var gateSuperseded = 0
    private var gateRetired = 0
    private var gateOutputs = 0
    private var inputMainDelay = LatencyWindow()
    private var inputPost = LatencyWindow()
    private var phoneSendToArrival = LatencyWindow()
    private var phoneSendToArrivalUncertainty = LatencyWindow()
    private var encoderEvidence: VideoEncoderEvidence?
    private var encoderSessionStartedMs: Double?
    private var encodedFramesTotal = 0
    private var arrivedFramesTotal = 0
    private var resumeCaptureBeganAt: TimeInterval?
    private var lastSourceDisplayMs: Double?
    private var recentDecodedRtp: [UInt32] = []
    static let decodedRtpMemory = 32
    private var reconfigureStall = ReconfigureStallTracker()

    /// Host (B0): the capture asked ScreenCaptureKit for a new configuration of `width`×`height`.
    func captureReconfigureRequested(atMs now: Double, width: Int, height: Int, previousWidth: Int, previousHeight: Int) {
        lock.lock(); defer { lock.unlock() }
        reconfigureStall.requested(atMs: now, width: width, height: height, previousWidth: previousWidth, previousHeight: previousHeight)
    }

    func captureReconfigureFailed() { lock.lock(); reconfigureStall.failed(); lock.unlock() }
    func captureReconfigureCancelled() { lock.lock(); reconfigureStall.cancel(); lock.unlock() }

    /// Host (B0): a complete frame of `width`×`height` reached the capture callback.
    func captureFrameDelivered(atMs now: Double, displayMs: Double, width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        reconfigureStall.frame(atMs: now, displayMs: displayMs, width: width, height: height)
    }

    func beginResumeCapture(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); resumeCaptureBeganAt = time; lock.unlock()
    }

    var encodedTotal: Int { lock.lock(); defer { lock.unlock() }; return encodedFramesTotal }
    var arrivedTotal: Int { lock.lock(); defer { lock.unlock() }; return arrivedFramesTotal }

    func encodedFrameAccepted() {
        lock.lock(); defer { lock.unlock() }
        encodedFramesTotal = min(HostStreamSummary.maximumFrameTotal, encodedFramesTotal + 1)
    }

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
        if let began = resumeCaptureBeganAt, time >= began {
            resumeCaptureBeganAt = nil
            let elapsed = Int(((time - began) * 1000).rounded())
            SessionLog.log.info("host resume to first capture callback \(elapsed, privacy: .public) ms")
        }
        captureCadence.record(at: time)
        if let displayLatencyMs { captureLatency.record(displayLatencyMs) }
        if let displayTimeMs, displayTimeMs.isFinite, displayTimeMs > 0 {
            captureDisplayCadence.record(at: displayTimeMs / 1000)
            if displayTimeMs > (lastSourceDisplayMs ?? 0) {
                lastSourceDisplayMs = displayTimeMs
                snapshot.uniqueSourceFrames += 1
            }
        }
    }

    func idleResent() { lock.lock(); snapshot.captureResends += 1; lock.unlock() }

    func pushed() { lock.lock(); snapshot.pushedFrames += 1; lock.unlock() }
    func pushSkipped() { lock.lock(); snapshot.pushSkipped += 1; lock.unlock() }
    func coalescedMove() { lock.lock(); snapshot.coalescedMoves += 1; lock.unlock() }

    func rendered(rtp: UInt32? = nil, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        snapshot.renderedFrames += 1
        if let rtp, !recentDecodedRtp.contains(rtp) {
            recentDecodedRtp.append(rtp)
            if recentDecodedRtp.count > Self.decodedRtpMemory { recentDecodedRtp.removeFirst() }
            snapshot.uniqueDecodedFrames += 1
        }
        arrivedFramesTotal = min(HostStreamSummary.maximumFrameTotal, arrivedFramesTotal + 1)
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

    func clockUpdated(_ estimate: ClockSyncEstimate?, observedAtMs: Double = MachClock.nowMs()) {
        lock.lock(); clock = estimate; clockObservedAtMs = estimate != nil ? observedAtMs : nil; lock.unlock()
    }

    var clockObservation: (estimate: ClockSyncEstimate?, atMs: Double?) {
        lock.lock(); defer { lock.unlock() }; return (clock, clockObservedAtMs)
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

    /// Called at every owned-encoder occupancy transition. Drain also accounts for a stalled
    /// pipeline with no callback, so a permanently full cap cannot disappear from the trace.
    func encoderCapacity(inFlight: Int, limit: Int?, atMs now: Double = MachClock.nowMs()) {
        lock.lock(); defer { lock.unlock() }
        accumulateEncoderCapacity(atMs: now)
        encodeInFlightMax = max(encodeInFlightMax, inFlight)
        encodeCapacityObserved = limit != nil
        encodeAtCapSinceMs = limit.map { inFlight >= $0 } == true ? now : nil
    }

    private func accumulateEncoderCapacity(atMs now: Double) {
        if let since = encodeAtCapSinceMs {
            encodeAtCapAccumulatedMs += max(0, now - since)
            encodeAtCapSinceMs = now
        }
    }

    func encoded(latencyMs: Double, vtLatencyMs: Double? = nil, bytes: Int, isKeyFrame: Bool, inFlight: Int) {
        lock.lock(); defer { lock.unlock() }
        encodeLatency.record(latencyMs)
        if let vtLatencyMs { encodeVTLatency.record(vtLatencyMs) }
        encodeBytes.record(Double(bytes))
        snapshot.encodedBytes += max(0, bytes)
        encodeInFlightMax = max(encodeInFlightMax, inFlight)
        if isKeyFrame { keyFrameBytesMax = max(keyFrameBytesMax, bytes) }
    }

    func encoderPreparation(milliseconds: Double) {
        guard detailedDiagnosticsEnabled, let milliseconds = DetailedDiagnostics.stage(milliseconds) else { return }
        lock.lock(); defer { lock.unlock() }
        encodePreparation.record(milliseconds)
    }

    /// Duration of the synchronous public VT call, regardless of accepted/error status.
    func encoderSubmit(milliseconds: Double) {
        guard detailedDiagnosticsEnabled, let milliseconds = DetailedDiagnostics.stage(milliseconds) else { return }
        lock.lock(); defer { lock.unlock() }
        encodeSubmit.record(milliseconds)
    }

    func encoderRateUpdated() {
        lock.lock(); rateUpdates += 1; lock.unlock()
    }

    /// The encoder dropped a frame at submit because enough were already inside VideoToolbox.
    func droppedBeforeEncode() {
        lock.lock(); encoderDropped += 1; lock.unlock()
    }

    /// Host: Mac audio source buffers the 120 ms age fence refused (PocketDeskAudioSourceAge).
    func audioSourceDropped(_ count: Int = 1) {
        guard count > 0 else { return }
        lock.lock(); audioSourceDrops += count; lock.unlock()
    }

    /// Host: one input message handled; `mainDelayMs` from data-channel arrival, `postMs` in the driver.
    func inputHandled(mainDelayMs: Double?, postMs: Double) {
        lock.lock(); defer { lock.unlock() }
        if let mainDelayMs { inputMainDelay.record(mainDelayMs) }
        inputPost.record(postMs)
    }

    /// Counts delivered input packets, including reliable recovery prefixes, never individual replayed segments.
    func phoneInputArrived(timing: InputSendTiming, arrivedHostMs: Double) {
        guard let duration = timing.latency(arrivedHostMs: arrivedHostMs) else { return }
        lock.lock(); defer { lock.unlock() }
        phoneSendToArrival.record(duration)
        phoneSendToArrivalUncertainty.record(timing.uncertaintyMs)
    }

    /// VideoToolbox dropped frames without a callback; a later completion retired them.
    func encoderSilentlyDropped(_ count: Int) {
        lock.lock(); encoderSilentDrops += max(0, count); lock.unlock()
    }

    /// Encoded outputs replaced in the bounded delivery mailbox, separate from VT drops.
    func encoderDeliveryDropped() { lock.lock(); encoderDeliveryDrops += 1; lock.unlock() }

    func encoderSubmitted(_ count: Int = 1) { lock.lock(); gateSubmitted += max(0, count); lock.unlock() }
    func encoderSuperseded(_ count: Int) { lock.lock(); gateSuperseded += max(0, count); lock.unlock() }
    func encoderRetired(_ count: Int) { lock.lock(); gateRetired += max(0, count); lock.unlock() }
    func encoderOutput() { lock.lock(); gateOutputs += 1; lock.unlock() }

    func recordEncoderEvidence(_ evidence: VideoEncoderEvidence?) {
        lock.lock(); encoderEvidence = evidence
        if evidence == nil {
            // Close the active segment without erasing occupancy earlier in this window.
            accumulateEncoderCapacity(atMs: MachClock.nowMs())
            encodeAtCapSinceMs = nil; encodeCapacityObserved = false
        }
        lock.unlock()
    }

    func encoderSessionStarted(atMs ms: Double = MachClock.nowMs()) {
        lock.lock(); encoderSessionStartedMs = ms; lock.unlock()
    }

    func drain(inputBufferedBytes: UInt64?, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> StreamCounterSnapshot {
        lock.lock(); defer { lock.unlock() }
        accumulateEncoderCapacity(atMs: MachClock.nowMs())
        var result = snapshot
        result.encodeAtCapMs = encodeCapacityObserved || encodeAtCapAccumulatedMs > 0 ? encodeAtCapAccumulatedMs : nil
        encodeAtCapAccumulatedMs = 0
        result.encoderEvidence = encoderEvidence
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
        let reconfigure = reconfigureStall.drain(atMs: MachClock.nowMs())
        result.reconfigures = reconfigure.reconfigures
        result.reconfigureStallMs = reconfigure.longestStallMs
        let capture = captureLatency.drain()
        result.captureLatencyP50Ms = capture.p50
        result.captureLatencyP90Ms = capture.p90
        let present = presentLatency.drain()
        result.presentLatencyP50Ms = present.p50
        result.presentLatencyP90Ms = present.p90
        result.presentGapP90Ms = presentCadence.drain().p90GapMs
        result.displayMaxFPS = displayMaxFPS
        let decodeVT = phoneRenderWindows[.decodeVT, default: LatencyWindow()].drainPercentiles()
        result.decodeVTP95Ms = decodeVT.p95
        result.decodeVTSamples = decodeVT.count > 0 ? decodeVT.count : nil
        let ownershipDelay = phoneRenderWindows[.ownershipDelay, default: LatencyWindow()].drainPercentiles()
        result.ownershipDelayP99Ms = ownershipDelay.p99
        result.ownershipDelaySamples = ownershipDelay.count > 0 ? ownershipDelay.count : nil
        let deliveryDelay = phoneRenderWindows[.deliveryDelay, default: LatencyWindow()].drainPercentiles()
        result.deliveryDelayP99Ms = deliveryDelay.p99
        result.deliveryDelaySamples = deliveryDelay.count > 0 ? deliveryDelay.count : nil
        let decodedToPresented = phoneRenderWindows[.decodedToPresented, default: LatencyWindow()].drainPercentiles()
        result.decodedToPresentedP95Ms = decodedToPresented.p95
        result.decodedToPresentedSamples = decodedToPresented.count > 0 ? decodedToPresented.count : nil
        let deliveryToPresented = phoneRenderWindows[.deliveryToPresented, default: LatencyWindow()].drainPercentiles()
        result.deliveryToPresentedP95Ms = deliveryToPresented.p95
        result.deliveryToPresentedSamples = deliveryToPresented.count > 0 ? deliveryToPresented.count : nil
        let drawableAcquire = phoneRenderWindows[.drawableAcquire, default: LatencyWindow()].drainPercentiles()
        result.drawableAcquireP99Ms = drawableAcquire.p99
        result.drawableAcquireSamples = drawableAcquire.count > 0 ? drawableAcquire.count : nil
        let rendererFenceWait = phoneRenderWindows[.rendererFenceWait, default: LatencyWindow()].drainPercentiles()
        result.rendererFenceWaitP99Ms = rendererFenceWait.p99
        result.rendererFenceWaitSamples = rendererFenceWait.count > 0 ? rendererFenceWait.count : nil
        let displayLinkInterval = phoneRenderWindows[.displayLinkInterval, default: LatencyWindow()].drainPercentiles()
        result.displayLinkIntervalP95Ms = displayLinkInterval.p95
        result.displayLinkIntervalSamples = displayLinkInterval.count > 0 ? displayLinkInterval.count : nil
        let leadingMotionLatency = phoneRenderWindows[.leadingMotionLatency, default: LatencyWindow()].drainPercentiles()
        result.leadingMotionLatencyP95Ms = leadingMotionLatency.p95
        result.leadingMotionLatencySamples = leadingMotionLatency.count > 0 ? leadingMotionLatency.count : nil
        result.displayLinkIntervalP50Ms = displayLinkInterval.p50
        result.displayLinkAt120Share = displayLinkIntervals > 0 ? Double(displayLinkAt120) / Double(displayLinkIntervals) : nil
        displayLinkAt120 = 0
        displayLinkIntervals = 0
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
        result.encodeVTP90Ms = encodeVTLatency.drainPercentiles().p90
        let preparation = encodePreparation.drainPercentiles()
        result.encodePreparationP95Ms = preparation.p95
        result.encodePreparationSamples = preparation.count > 0 ? preparation.count : nil
        let submit = encodeSubmit.drainPercentiles()
        result.encodeSubmitP95Ms = submit.p95
        result.encodeSubmitSamples = submit.count > 0 ? submit.count : nil
        result.encodeInFlightMax = encode.count > 0 || encodeInFlightMax > 0 ? encodeInFlightMax : nil
        result.encodeBytesP50 = encodeBytes.drainPercentiles().p50.map { Int($0) }
        result.keyFrameBytesMax = keyFrameBytesMax > 0 ? keyFrameBytesMax : nil
        result.rateUpdates = encode.count > 0 || rateUpdates > 0 ? rateUpdates : nil
        result.encoderSessionAgeS = encoderSessionStartedMs.map { max(0, (MachClock.nowMs() - $0) / 1000) }
        result.encoderDropped = encode.count > 0 || encoderDropped > 0 ? encoderDropped : nil
        result.encoderDeliveryDrops = encoderDeliveryDrops > 0 ? encoderDeliveryDrops : nil
        result.encoderSilentDrops = encode.count > 0 || encoderSilentDrops > 0 ? encoderSilentDrops : nil
        result.audioSourceDrops = audioSourceDrops > 0 ? audioSourceDrops : nil
        let gateActive = gateSubmitted > 0 || gateSuperseded > 0 || gateRetired > 0 || gateOutputs > 0
        result.encoderSubmitted = gateActive ? gateSubmitted : nil
        result.encoderSuperseded = gateActive ? gateSuperseded : nil
        result.encoderRetired = gateActive ? gateRetired : nil
        result.encoderOutputs = gateActive ? gateOutputs : nil
        let phoneArrival = phoneSendToArrival.drainPercentiles()
        result.phoneSendToArrivalP50Ms = phoneArrival.p50
        result.phoneSendToArrivalP95Ms = phoneArrival.p95
        result.phoneSendToArrivalMaxMs = phoneArrival.max
        result.phoneSendToArrivalUncertaintyMs = phoneSendToArrivalUncertainty.drainPercentiles().max
        result.phoneSendToArrivalSamples = phoneArrival.count > 0 ? phoneArrival.count : nil
        let mainDelay = inputMainDelay.drainPercentiles()
        let post = inputPost.drainPercentiles()
        result.inputMainDelayP50Ms = mainDelay.p50
        result.inputMainDelayP95Ms = mainDelay.p95
        result.inputMainDelayMaxMs = mainDelay.max
        result.inputPostP95Ms = post.p95
        result.inputEvents = post.count > 0 ? post.count : nil
        encodeInFlightMax = 0
        keyFrameBytesMax = 0
        rateUpdates = 0
        encoderDropped = 0
        encoderDeliveryDrops = 0
        encoderSilentDrops = 0
        audioSourceDrops = 0
        gateSubmitted = 0
        gateSuperseded = 0
        gateRetired = 0
        gateOutputs = 0
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
