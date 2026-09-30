import Foundation
import CoreGraphics

/// What the Test Pad bench window shows (Docs/perf/INSTRUMENTS-DESIGN.md §1), and when the marker
/// strip may take a new time value.
///
/// The strip ticks only while motion or scroll is on, or once after an event (chart change, flash,
/// page jump, motion or scroll switched). A static bench therefore holds its last marker and does not
/// redraw, so ScreenCaptureKit sees an idle screen exactly as on a real static desktop.
struct BenchState: Equatable {
    static let sweepsPerSecond = 0.5
    static let scrollPointsPerSecond = 1000.0
    /// A stalled main thread advances motion and scroll by at most this much per tick.
    static let maximumStepMs = 250.0
    /// Camera kit: auto-flash toggles the flash target at a seeded, uniformly jittered interval in
    /// this range, far longer than any latency it measures, so camera pairing is unambiguous.
    static let autoFlashMinimumMs = 400.0
    static let autoFlashMaximumMs = 700.0

    private(set) var seed: UInt16
    private(set) var motion = false
    private(set) var scroll = false
    private(set) var flash = false
    private(set) var autoFlash = false
    private var nextAutoFlashMs: Double?
    private var autoFlashRandom = SplitMix64(seed: 0)
    private(set) var motionSeconds = 0.0
    private(set) var scrollOffset = 0.0
    /// The strip as last drawn, and the mach time it carries; nil before the first frame.
    private(set) var shownMarker: BenchMarker?
    private(set) var shownTimeMs: Double?
    private var pendingEvent = true
    private var lastTickMs: Double?

    init(seed: UInt16) {
        self.seed = seed & BenchMarker.seedMask
    }

    var isMoving: Bool { motion || scroll }
    var wantsFrames: Bool { isMoving || pendingEvent || autoFlash }
    var boxFraction: Double { Self.boxFraction(motionSeconds: motionSeconds) }

    /// 0 at the left end of the lane and 1 at the right; one sweep is one traversal.
    static func boxFraction(motionSeconds: Double) -> Double {
        let sweeps = (motionSeconds * sweepsPerSecond).truncatingRemainder(dividingBy: 2)
        return sweeps <= 1 ? sweeps : 2 - sweeps
    }

    /// False for the current chart and for seeds outside the real-chart range.
    @discardableResult
    mutating func setChart(seed newSeed: UInt16) -> Bool {
        guard LegibilityChart.seedRange.contains(newSeed), newSeed != seed else { return false }
        seed = newSeed
        pendingEvent = true
        return true
    }

    @discardableResult
    mutating func setMotion(_ on: Bool) -> Bool {
        guard on != motion else { return false }
        motion = on
        pendingEvent = true
        return true
    }

    @discardableResult
    mutating func setScroll(_ on: Bool) -> Bool {
        guard on != scroll else { return false }
        scroll = on
        pendingEvent = true
        return true
    }

    mutating func toggleFlash() {
        flash.toggle()
        pendingEvent = true
    }

    @discardableResult
    mutating func setAutoFlash(_ on: Bool, now: Double, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) -> Bool {
        guard on != autoFlash else { return false }
        autoFlash = on
        if on {
            autoFlashRandom = SplitMix64(seed: seed)
            nextAutoFlashMs = now + nextAutoFlashInterval()
        } else {
            nextAutoFlashMs = nil
        }
        pendingEvent = true
        return true
    }

    private mutating func nextAutoFlashInterval() -> Double {
        let unit = Double(autoFlashRandom.next() >> 11) / Double(1 << 53)
        return Self.autoFlashMinimumMs + (Self.autoFlashMaximumMs - Self.autoFlashMinimumMs) * unit
    }

    mutating func jump(by points: Double) {
        scrollOffset += max(0, points)
        pendingEvent = true
    }

    /// The display-link decision for a frame whose target display time is `now` (mach ms): the
    /// strip's new time while something moves or after an event, nil when the strip must keep its
    /// last value and nothing may redraw.
    mutating func markerTime(now: Double) -> Double? {
        if autoFlash, let due = nextAutoFlashMs, now >= due {
            toggleFlash()
            nextAutoFlashMs = now + nextAutoFlashInterval()
        }
        guard isMoving || pendingEvent else {
            lastTickMs = nil
            return nil
        }
        if isMoving, let last = lastTickMs {
            let step = min(max(0, now - last), Self.maximumStepMs) / 1000
            if motion { motionSeconds += step }
            if scroll { scrollOffset += step * Self.scrollPointsPerSecond }
        }
        lastTickMs = isMoving ? now : nil
        pendingEvent = false
        shownTimeMs = now
        shownMarker = BenchMarker(hostTimeMs: now, chartSeed: seed, flash: flash, motion: isMoving)
        return now
    }

    /// The chart a `bench.chart` seed asks for, nil when out of range. Seed 0 is the marker's
    /// "no chart", so asking for it picks a random chart like an absent seed.
    static func chartSeed(requested value: Int, current: UInt16) -> UInt16? {
        if value == Int(LegibilityChart.noChartSeed) { return randomSeed(excluding: current) }
        guard let seed = UInt16(exactly: value), LegibilityChart.seedRange.contains(seed) else { return nil }
        return seed
    }

    /// A random real chart that differs from the one on screen, so every new chart is a visible change.
    static func randomSeed(excluding current: UInt16) -> UInt16 {
        var seed = LegibilityChart.randomSeed()
        while seed == current { seed = LegibilityChart.randomSeed() }
        return seed
    }
}

/// Seeded generator for the auto-flash schedule (Steele, Lea and Flood's SplitMix64).
struct SplitMix64: Equatable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Where the bench window puts its human-facing parts, in display points with a top-left origin.
/// The marker strip and the chart come from the shared contracts; everything else keeps clear of both.
struct BenchPadLayout: Equatable {
    static let margin: CGFloat = 24
    static let flashSide: CGFloat = 220
    static let laneHeight: CGFloat = 90
    static let boxSide: CGFloat = 70

    let size: CGSize
    let marker: CGRect
    let chart: CGRect
    /// The area the clock may use; the clock view takes as much of its height as its font needs.
    let clock: CGRect
    let lane: CGRect
    let codePane: CGRect
    let flash: CGRect

    init(size: CGSize, safeTop: CGFloat = 0) {
        let margin = Self.margin
        self.size = size
        marker = BenchMarker.layout(width: Double(size.width), height: Double(size.height)).frame
        chart = LegibilityChart.layout(displayPointSize: size).frame
        let top = max(safeTop + 8, marker.minY)
        let rightX = max(chart.maxX, marker.maxX) + margin
        flash = CGRect(x: size.width - margin - Self.flashSide, y: size.height - margin - Self.flashSide,
                       width: Self.flashSide, height: Self.flashSide)
        codePane = CGRect(x: rightX, y: top, width: max(0, size.width - margin - rightX),
                          height: max(0, flash.minY - margin - top))
        lane = CGRect(x: margin, y: size.height - margin - Self.laneHeight,
                      width: max(0, rightX - 2 * margin), height: Self.laneHeight)
        let clockTop = max(chart.maxY, marker.maxY) + margin
        clock = CGRect(x: chart.minX, y: clockTop, width: chart.width, height: max(0, lane.minY - margin - clockTop))
    }

    var parts: [String: CGRect] {
        ["clock": clock, "lane": lane, "codePane": codePane, "flash": flash]
    }
}
