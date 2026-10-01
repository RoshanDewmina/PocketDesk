import Foundation

/// An observed burst pattern; it does not identify which device or radio feature caused it.
struct WiFiStallTip: Equatable {
    enum Guidance: Equatable { case settings, causeOnly }
    static let defaultGuidance: Guidance = .settings
    var macWired = false
    var macWiFi = false
    var guidance: Guidance = Self.defaultGuidance
    let title = "Picture pauses about once a second"
    let observation = "Frames arrive in bursts with little measured packet loss. This pattern does not identify a cause."

    var detail: String { fix(device: "iPhone") }
    var message: String { "\(title) — \(detail)" }
    static var message: String { WiFiStallTip().message }
    var fix: String { fix(device: "iPhone") }

    func fix(device: String) -> String {
        if guidance == .causeOnly {
            return macWiFi ? "An Ethernet cable on your Mac can help steady the picture."
                : "Moving closer to the router can help steady the picture."
        }
        let target = macWiFi ? "your Mac" : "this \(device)"
        return "Setting AirDrop to Receiving Off on \(target) can help smooth this."
    }

    func secondary(device: String) -> String? {
        guard guidance == .settings else { return nil }
        let target = macWiFi ? "your Mac" : "this \(device)"
        return "AirDrop and Handoff can share the Wi-Fi radio. Turning off Handoff on \(target) can also help."
    }

    static func observed(_ report: StreamStatsReport) -> Self {
        let local = report.routeDetail == "lan"
        return Self(macWired: local && report.host?.macLink == "wired",
                    macWiFi: local && report.host?.macLink == "wifi")
    }
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
    static let minimumMotionFPS = 40.0
    static let maximumLossPercent = 1.0
    static let maximumHostCaptureGapMs = 40.0
    static let maximumHostPacerDelayMs = 30.0

    private(set) var recent: [Bool] = []
    private(set) var showing = false
    private var previousMotion = false
    private var previousMotionAt: TimeInterval?

    var tip: WiFiStallTip? { showing ? WiFiStallTip() : nil }

    /// Nil when the second does not count: no motion, loss, a relay route, or a Mac-side delay.
    static func stalled(_ report: StreamStatsReport) -> Bool? {
        guard report.route == "Direct",
              let fps = report.receivedFPS, fps.isFinite, fps >= minimumMotionFPS,
              let gap = report.renderGapMaxMs, gap.isFinite, gap >= 0,
              let loss = report.packetLossPercent, loss.isFinite, loss >= 0, loss <= maximumLossPercent,
              let age = report.hostSummaryAgeMs, age.isFinite, age >= 0, age <= 3_000,
              let host = report.host,
              let sourceFPS = host.captureFPS, sourceFPS.isFinite, sourceFPS >= minimumMotionFPS,
              let sourceGap = host.captureGapMaxMs, sourceGap.isFinite, sourceGap >= 0,
              sourceGap <= maximumHostCaptureGapMs,
              let pacer = host.pacerDelayMs, pacer.isFinite, pacer >= 0,
              pacer <= maximumHostPacerDelayMs else { return nil }
        return gap >= stallGapMs
    }

    /// True when `tip` changed.
    @discardableResult
    mutating func observe(_ report: StreamStatsReport, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        // A source-idle/burst or unknown second breaks the motion run. Keep truthful raw
        // cadence diagnostics; do not label a cross-window idle gap as a Wi-Fi stall.
        guard now.isFinite, now >= 0, let stalled = Self.stalled(report) else {
            let before = showing
            reset()
            return before
        }
        let contiguous = previousMotionAt.map { now >= $0 && now - $0 <= 2.5 } ?? false
        guard previousMotion, contiguous else {
            let before = showing
            recent = []; showing = false
            previousMotion = true; previousMotionAt = now
            return before
        }
        previousMotionAt = now
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
        previousMotion = false
        previousMotionAt = nil
    }
}
