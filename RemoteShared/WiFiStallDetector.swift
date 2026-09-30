import Foundation

/// A gentle Connection Health tip for the once-a-second Wi-Fi stall that AWDL (AirDrop, Handoff,
/// iPhone Mirroring) causes: the radio leaves the channel about every second, so frames that left
/// the Mac on time reach the phone in a bunch after a ~100 ms gap, with no packet loss
/// (Docs/perf/BASELINE-2026-09-29.md finding 3; efficiency audit P16).
struct WiFiStallTip: Equatable {
    static let message = "Wi-Fi hiccups every second — turning off AirDrop/Handoff on your Mac can smooth this"
    let title = "Wi-Fi hiccups every second"
    let detail = "Turning off AirDrop/Handoff on your Mac can smooth this."
    var message: String { Self.message }
}

/// Reads the phone's per-second statistics reports and decides whether to show `WiFiStallTip`.
/// Only seconds with motion count (a static picture has long gaps by design). A counted second is a
/// stall when its largest frame-arrival gap is long while loss is near zero and the Mac says it
/// captured and paced on time, i.e. the hold-up was in the air, not on either device. The tip shows
/// once most of the last `window` motion seconds stalled, and clears only when few do.
struct WiFiStallDetector: Equatable {
    static let window = 10
    static let showAtStalls = 7
    static let hideAtStalls = 2
    static let stallGapMs = 80.0
    static let minimumMotionFPS = 20.0
    static let maximumLossPercent = 1.0
    static let maximumHostCaptureGapMs = 40.0
    static let maximumHostPacerDelayMs = 30.0

    private(set) var recent: [Bool] = []
    private(set) var showing = false

    var tip: WiFiStallTip? { showing ? WiFiStallTip() : nil }

    /// Nil when the second does not count: no motion, loss, a relay route, or a Mac-side delay.
    static func stalled(_ report: StreamStatsReport) -> Bool? {
        guard report.route != "Relay",
              let fps = report.receivedFPS, fps >= minimumMotionFPS,
              let gap = report.renderGapMaxMs,
              (report.packetLossPercent ?? 0) <= maximumLossPercent else { return nil }
        if let host = report.host {
            if let captureGap = host.captureGapP90Ms, captureGap > maximumHostCaptureGapMs { return nil }
            if let pacer = host.pacerDelayMs, pacer > maximumHostPacerDelayMs { return nil }
        }
        return gap >= stallGapMs
    }

    /// True when `tip` changed.
    @discardableResult
    mutating func observe(_ report: StreamStatsReport) -> Bool {
        guard let stalled = Self.stalled(report) else { return false }
        recent.append(stalled)
        if recent.count > Self.window { recent.removeFirst(recent.count - Self.window) }
        let stalls = recent.filter { $0 }.count
        let before = showing
        if !showing, recent.count >= Self.window, stalls >= Self.showAtStalls {
            showing = true
        } else if showing, stalls <= Self.hideAtStalls {
            showing = false
        }
        return showing != before
    }

    mutating func reset() {
        recent = []
        showing = false
    }
}
