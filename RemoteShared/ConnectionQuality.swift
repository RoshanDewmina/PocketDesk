import Foundation

/// A point where the Mac's cumulative encoded-frame count and the phone's cumulative
/// arrived-frame count were read together, as the Mac's summary reached the phone.
struct FrameMark: Equatable {
    var hostEncoded: Int
    var phoneArrived: Int
    var at: TimeInterval
}

/// What the monitor reads from one phone statistics report.
struct ConnectionQualitySample: Equatable {
    var at: TimeInterval
    var mark: FrameMark?
    /// Encoded-but-not-yet-drawn delay: the Mac's pacer, the phone's jitter buffer and decode.
    var pipelineMs: Double?
    /// A round trip measured since the previous report; nil when no new STUN response arrived.
    var rttSampleMs: Double?

    init(at: TimeInterval, mark: FrameMark? = nil, pipelineMs: Double? = nil, rttSampleMs: Double? = nil) {
        self.at = at
        self.mark = mark
        self.pipelineMs = pipelineMs
        self.rttSampleMs = rttSampleMs
    }

    init(_ report: StreamStatsReport, at: TimeInterval) {
        var mark: FrameMark?
        if (report.hostSummaryAgeMs ?? .infinity) <= 5_000, let host = report.hostFramesEncodedTotal, let phone = report.framesArrivedAtMark,
           let markAt = report.frameMarkAt {
            mark = FrameMark(hostEncoded: host, phoneArrived: phone, at: markAt)
        }
        let parts = [report.host?.pacerDelayMs, report.jitterBufferMs, report.decodeMs].compactMap { $0 }
        self.init(at: at, mark: mark, pipelineMs: parts.isEmpty ? nil : parts.reduce(0, +),
                  rttSampleMs: report.rttSampleMs)
    }
}

/// Moonlight's connection-status hysteresis (moonlight-common-c ControlStream.c) on Farside's own
/// measure: frames the Mac encoded that never reached the phone's renderer, over ~3 s windows
/// bounded by frame marks. Poor at 30 % in one measured window or 15 % in two in a row; clears at
/// 5 %. The first measured window after any reset is ignored, windows with too few frames are
/// skipped without touching state, and a still picture clears Poor after a quiet spell.
/// Round trip time gets the same treatment so a single slow second never shows.
struct ConnectionQualityMonitor: Equatable {
    enum Level: String, Equatable { case ok, poor }

    static let windowSeconds = 2.9
    static let minimumFrames = 60
    static let poorLossPercent = 30.0
    static let poorTwiceLossPercent = 15.0
    static let clearLossPercent = 5.0
    static let quietClearSeconds = 10.0
    static let previousWindowExpirySeconds = 10.0
    static let maximumMarkGapSeconds = 5.0
    static let maximumFramesInFlight = 15.0
    /// One main-thread and display hop the stage timings do not cover.
    static let hopMs = 16.0

    static let slowRoundTripMs = 150.0
    static let verySlowRoundTripMs = 300.0
    static let clearRoundTripMs = 110.0
    static let spreadSamples = 10

    private(set) var level: Level = .ok
    /// Loss in the most recently closed measured window, for Diagnostics and the log.
    private(set) var lastLossPercent: Double?
    private(set) var measuredWindows = 0
    private(set) var poorEntries = 0

    private var lastMark: FrameMark?
    private var lastRate: Double?
    private var windowStart: (mark: FrameMark, flight: Double)?
    private var settled = false
    private var previousLoss: (percent: Double, at: TimeInterval)?
    private var lastMeasuredAt: TimeInterval?
    private var poorSince: TimeInterval?

    private var rttWindow: [Double] = []
    private var rttWindowStart: TimeInterval?
    private var previousRTTMedian: Double?
    private(set) var slowRoundTrip = false
    private(set) var roundTripMedianMs: Double?
    private var recentRTT: [Double] = []
    private var lastRTTAt: TimeInterval?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.level == rhs.level && lhs.lastLossPercent == rhs.lastLossPercent && lhs.slowRoundTrip == rhs.slowRoundTrip
            && lhs.roundTripMedianMs == rhs.roundTripMedianMs && lhs.measuredWindows == rhs.measuredWindows
    }

    var isPoor: Bool { level == .poor }

    /// The latched slow round trip, nil unless the hysteresis says slow.
    var slowRoundTripMs: Int? {
        guard slowRoundTrip, let roundTripMedianMs else { return nil }
        return Int(roundTripMedianMs.rounded())
    }

    /// Standard deviation of the last few fresh round trips.
    var roundTripSpreadMs: Double? {
        guard recentRTT.count >= 3 else { return nil }
        let mean = recentRTT.reduce(0, +) / Double(recentRTT.count)
        let variance = recentRTT.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(recentRTT.count)
        return (variance.squareRoot() * 10).rounded() / 10
    }

    /// True when `level` or `slowRoundTrip` changed.
    @discardableResult
    mutating func observe(_ sample: ConnectionQualitySample) -> Bool {
        let before = (level, slowRoundTrip)
        if let mark = sample.mark { observe(mark, pipelineMs: sample.pipelineMs) }
        if level == .poor, sample.at - (lastMeasuredAt ?? poorSince ?? sample.at) >= Self.quietClearSeconds {
            level = .ok
            poorSince = nil
        }
        if let lastRTTAt, sample.at - lastRTTAt > Self.quietClearSeconds {
            rttWindow = []
            rttWindowStart = nil
            previousRTTMedian = nil
            slowRoundTrip = false
            roundTripMedianMs = nil
            recentRTT = []
            self.lastRTTAt = nil
        }
        if let rtt = sample.rttSampleMs, rtt.isFinite, rtt >= 0, rtt <= 10_000_000 { observeRoundTrip(rtt, at: sample.at) }
        return before != (level, slowRoundTrip)
    }

    mutating func reset() {
        level = .ok
        lastLossPercent = nil
        lastMark = nil
        lastRate = nil
        windowStart = nil
        settled = false
        previousLoss = nil
        lastMeasuredAt = nil
        poorSince = nil
        rttWindow = []
        rttWindowStart = nil
        previousRTTMedian = nil
        slowRoundTrip = false
        roundTripMedianMs = nil
        recentRTT = []
        lastRTTAt = nil
    }

    // MARK: Frame loss

    private mutating func observe(_ mark: FrameMark, pipelineMs: Double?) {
        if let last = lastMark {
            guard mark.at != last.at else { return }
            if mark.at < last.at || mark.at - last.at > Self.maximumMarkGapSeconds
                || mark.hostEncoded < last.hostEncoded || mark.phoneArrived < last.phoneArrived {
                restartFrames(at: mark)
                return
            }
            lastRate = Double(mark.hostEncoded - last.hostEncoded) / (mark.at - last.at)
        }
        lastMark = mark
        let pipeline = pipelineMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
        let flight = min(Self.maximumFramesInFlight, max(0, (lastRate ?? 0) * (pipeline + Self.hopMs) / 1000))
        guard let start = windowStart else {
            windowStart = (mark, flight)
            return
        }
        guard mark.at - start.mark.at >= Self.windowSeconds else { return }
        windowStart = (mark, flight)
        let encoded = mark.hostEncoded - start.mark.hostEncoded
        guard encoded >= Self.minimumFrames else { return }
        let arrived = mark.phoneArrived - start.mark.phoneArrived
        let missing = Double(encoded - arrived) - (flight - start.flight)
        let loss = min(100, max(0, missing / Double(encoded) * 100))
        guard settled else {
            settled = true
            return
        }
        evaluate(loss: (loss * 10).rounded() / 10, at: mark.at)
    }

    private mutating func restartFrames(at mark: FrameMark) {
        level = .ok
        lastLossPercent = nil
        lastMeasuredAt = nil
        poorSince = nil
        lastMark = mark
        lastRate = nil
        windowStart = (mark, 0)
        settled = false
        previousLoss = nil
    }

    private mutating func evaluate(loss: Double, at: TimeInterval) {
        let previous = previousLoss.flatMap { at - $0.at <= Self.previousWindowExpirySeconds ? $0.percent : nil }
        if level != .poor, loss >= Self.poorLossPercent
            || (loss >= Self.poorTwiceLossPercent && (previous ?? 0) >= Self.poorTwiceLossPercent) {
            level = .poor
            poorSince = at
            poorEntries += 1
        } else if level == .poor, loss <= Self.clearLossPercent {
            level = .ok
            poorSince = nil
        }
        previousLoss = (loss, at)
        lastLossPercent = loss
        lastMeasuredAt = at
        measuredWindows += 1
    }

    // MARK: Round trip

    private mutating func observeRoundTrip(_ rtt: Double, at: TimeInterval) {
        lastRTTAt = at
        recentRTT.append(rtt)
        if recentRTT.count > Self.spreadSamples { recentRTT.removeFirst(recentRTT.count - Self.spreadSamples) }
        guard let start = rttWindowStart else {
            rttWindowStart = at
            rttWindow = [rtt]
            return
        }
        rttWindow.append(rtt)
        guard at - start >= Self.windowSeconds else { return }
        let samples = rttWindow
        rttWindowStart = at
        rttWindow = []
        guard samples.count >= 2 else { return }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        if !slowRoundTrip, median >= Self.verySlowRoundTripMs
            || (median >= Self.slowRoundTripMs && (previousRTTMedian ?? 0) >= Self.slowRoundTripMs) {
            slowRoundTrip = true
        } else if slowRoundTrip, median <= Self.clearRoundTripMs {
            slowRoundTrip = false
        }
        previousRTTMedian = median
        roundTripMedianMs = median
    }
}

/// The one plain fact named beside measured frame loss. It is the condition Farside observed, never
/// proof of what caused the loss, and never an authority for routes or access.
enum ConnectionQualityCause: String, Equatable, Hashable, CaseIterable {
    case relay, phoneCellular, phoneWeakWiFi, macOnWiFi, unknown

    static func pick(routeDetail: String?, phoneLink: NetworkLinkHint?, macLink: String?) -> Self {
        if routeDetail == "relay" { return .relay }
        if let phoneLink {
            if phoneLink.kind == .cellularOrExpensive && phoneLink.cellular { return .phoneCellular }
            if phoneLink.kind == .weakWiFi { return .phoneWeakWiFi }
        }
        if routeDetail == "lan", macLink == MacNetworkLink.wifi.rawValue { return .macOnWiFi }
        return .unknown
    }

    func title(device: String) -> String {
        switch self {
        case .relay: "Connected through relay"
        case .phoneCellular: "This \(device) is on cellular"
        case .phoneWeakWiFi: "This \(device)’s Wi-Fi is weak"
        case .macOnWiFi: "Your Mac is on Wi-Fi"
        case .unknown: "Picture struggling"
        }
    }

    var fix: String {
        switch self {
        case .relay: "Joining your Mac’s Wi-Fi usually lets Farside connect directly."
        case .phoneCellular: "Wi-Fi usually gives a steadier picture."
        case .phoneWeakWiFi: "Move closer to the router."
        case .macOnWiFi: "An Ethernet cable on your Mac can help steady the picture."
        case .unknown: "Moving either device closer to the router usually helps."
        }
    }
}

/// Poor quality with its one named condition, for the banner and Connection Health.
struct ConnectionQualityVerdict: Equatable {
    var cause: ConnectionQualityCause
    var lossPercent: Int

    func title(device: String) -> String { cause.title(device: device) }
    var fix: String { cause.fix }

    var detail: String {
        let seen = "\(lossPercent)% of frames did not reach the picture in the last measured window"
        switch cause {
        case .relay: return "\(seen), on a relayed route."
        case .unknown: return "\(seen). The cause is unknown."
        default: return "\(seen)."
        }
    }
}
