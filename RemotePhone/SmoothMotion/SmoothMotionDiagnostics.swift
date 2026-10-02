import Foundation

/// Per-session smooth-motion evidence for Settings → Diagnostics, the stream statistics overlay
/// and the unified log. Thread-safe: fed from the decode thread, the interpolator's queue and draws.
final class SmoothMotionDiagnostics: @unchecked Sendable {
    struct Snapshot: Equatable {
        var mode: SmoothMotionMode = .defaultMode
        var state = "starting"
        /// Share of streaming time (frames arriving) with interpolation engaged.
        var activeShare: Double?
        /// Source-frame hold from arrival to hand-off while engaged.
        var addedLatencyP50Ms: Double?
        var addedLatencyP95Ms: Double?
        var processingP50Ms: Double?
        var processingP95Ms: Double?
        var interpolatedFrames = 0
        var droppedFrames = 0
        var busyFrames = 0
        var fallbacks = 0
        var lastFallback: String?
        var setup: String?
        var sessionStartMs: Double?
        var drawableWaitP50Ms: Double?
        var drawableWaitP95Ms: Double?
        var drawableWaitMaxMs: Double?
        var drawableWaitSamples = 0
        var rendererFallbackCreations = 0

        var overlayLine: String {
            func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "–" }
            let share = activeShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
            var line = "smooth \(mode.rawValue) \(state) · on \(share) · +lat p50 \(ms(addedLatencyP50Ms)) p95 \(ms(addedLatencyP95Ms))ms"
                + " · proc \(ms(processingP50Ms))/\(ms(processingP95Ms))ms · interp \(interpolatedFrames)"
                + " · drop \(droppedFrames) · busy \(busyFrames) · fallback \(fallbacks)"
            if let lastFallback { line += " (\(lastFallback))" }
            line += " · drawable p50/p95/max \(ms(drawableWaitP50Ms))/\(ms(drawableWaitP95Ms))/\(ms(drawableWaitMaxMs))ms n \(drawableWaitSamples) · renderer fallback \(rendererFallbackCreations)"
            return line
        }

        var settingsLines: [String] {
            func ms(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "–" }
            return [
                "State: \(state)" + (setup.map { " · \($0)" } ?? ""),
                "Active: " + (activeShare.map { "\(Int(($0 * 100).rounded()))% of streaming time" } ?? "–"),
                "Added latency: p50 \(ms(addedLatencyP50Ms)) · p95 \(ms(addedLatencyP95Ms))",
                "Processing: p50 \(ms(processingP50Ms)) · p95 \(ms(processingP95Ms))"
                    + (sessionStartMs.map { String(format: " · start %.0f ms", $0) } ?? ""),
                "Frames: \(interpolatedFrames) interpolated · \(droppedFrames) dropped · \(busyFrames) shown directly while busy",
                "Fallbacks: \(fallbacks)" + (lastFallback.map { " · last: \($0)" } ?? ""),
                "Drawable wait: p50 \(ms(drawableWaitP50Ms)) · p95 \(ms(drawableWaitP95Ms)) · max \(ms(drawableWaitMaxMs)) · \(drawableWaitSamples) samples",
                "Renderer fallback views created: \(rendererFallbackCreations)",
            ]
        }
    }

    static let sampleCapacity = 1024
    /// Gaps longer than this are a static picture, not streaming time.
    static let streamingGap: TimeInterval = 0.25

    private let lock = NSLock()
    private var current = Snapshot()
    private var streamingTime: TimeInterval = 0
    private var engagedTime: TimeInterval = 0
    private var lastFrameAt: TimeInterval?
    private var added = SampleRing(capacity: sampleCapacity)
    private var processing = SampleRing(capacity: sampleCapacity)
    private var drawableWaits = SampleRing(capacity: sampleCapacity)

    func reset(mode: SmoothMotionMode) {
        lock.lock(); defer { lock.unlock() }
        current = Snapshot(mode: mode)
        streamingTime = 0
        engagedTime = 0
        lastFrameAt = nil
        added = SampleRing(capacity: Self.sampleCapacity)
        processing = SampleRing(capacity: Self.sampleCapacity)
        drawableWaits = SampleRing(capacity: Self.sampleCapacity)
    }

    func frameArrived(engaged: Bool, state: String, mode: SmoothMotionMode, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if let last = lastFrameAt, now > last {
            let gap = min(now - last, Self.streamingGap)
            streamingTime += gap
            if engaged { engagedTime += gap }
        }
        lastFrameAt = now
        current.state = state
        current.mode = mode
    }

    func addedLatency(_ seconds: TimeInterval) {
        lock.lock(); added.record(seconds * 1000); lock.unlock()
    }

    func processed(ms: Double, interpolated: Bool) {
        lock.lock()
        processing.record(ms)
        if interpolated { current.interpolatedFrames += 1 }
        lock.unlock()
    }

    func drawableAcquisition(ms: Double) {
        lock.lock(); drawableWaits.record(ms); lock.unlock()
    }

    func adoptDrawableWaits(_ samples: SampleRing, fallbackCreations: Int) {
        lock.lock(); defer { lock.unlock() }
        drawableWaits = samples
        current.rendererFallbackCreations = fallbackCreations
    }

    func rendererFallbackCreated() {
        lock.lock(); current.rendererFallbackCreations += 1; lock.unlock()
    }

    func dropped(_ count: Int) {
        guard count > 0 else { return }
        lock.lock(); current.droppedFrames += count; lock.unlock()
    }

    func busy() {
        lock.lock(); current.busyFrames += 1; lock.unlock()
    }

    func fallback(_ reason: String) {
        lock.lock()
        current.fallbacks += 1
        current.lastFallback = reason
        lock.unlock()
        InterpolationAvailability.logger.notice("smooth-motion fallback: \(reason, privacy: .public)")
    }

    func sessionStarted(setup: String, ms: Double) {
        lock.lock()
        current.setup = setup
        current.sessionStartMs = ms
        lock.unlock()
        InterpolationAvailability.logger.notice("smooth-motion session \(setup, privacy: .public) started in \(ms, format: .fixed(precision: 1)) ms")
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var result = current
        result.activeShare = streamingTime > 0 ? engagedTime / streamingTime : nil
        result.addedLatencyP50Ms = added.percentile(0.5)
        result.addedLatencyP95Ms = added.percentile(0.95)
        result.processingP50Ms = processing.percentile(0.5)
        result.processingP95Ms = processing.percentile(0.95)
        result.drawableWaitP50Ms = drawableWaits.percentile(0.5)
        result.drawableWaitP95Ms = drawableWaits.percentile(0.95)
        result.drawableWaitMaxMs = drawableWaits.percentile(1)
        result.drawableWaitSamples = drawableWaits.count
        return result
    }
}

/// The most recent samples, for session percentiles without unbounded growth.
struct SampleRing {
    private var samples: [Double] = []
    private var next = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        samples.reserveCapacity(capacity)
    }

    var count: Int { samples.count }

    mutating func record(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        if samples.count < capacity {
            samples.append(value)
        } else {
            samples[next] = value
            next = (next + 1) % capacity
        }
    }

    func percentile(_ fraction: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        return LatencyWindow.rank(samples.sorted(), fraction)
    }
}
