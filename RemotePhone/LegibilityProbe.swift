import CoreImage
import CoreVideo
import Foundation

/// When to score the bench chart (Docs/perf/INSTRUMENTS-DESIGN.md §2): +0.3 s, +1 s and +3 s after
/// the marker's chart seed changes, then every 5 s while it holds, never two scorings at once.
/// A slot that passes while a scoring is still running is folded into the next scoring.
struct LegibilityScheduler: Equatable {
    static let settleOffsetsMs: [Double] = [300, 1_000, 3_000]
    static let steadyIntervalMs: Double = 5_000
    /// The native-pixel ("decoded") surface is scored once per chart, at the +3 s slot.
    static let decodedSlot = 2
    /// Seed 0 means the bench window is not showing a chart.
    static let noChart: UInt16 = 0

    struct Job: Equatable {
        let seed: UInt16
        /// Time since the seed changed, when the scored frame arrived.
        let ageMs: Double
        let scoresDecoded: Bool
    }

    private(set) var seed: UInt16?
    private(set) var inFlight = false
    private var changedAtMs = 0.0
    private var nextSlot = 0

    static func offsetMs(slot: Int) -> Double {
        if slot < settleOffsetsMs.count { return settleOffsetsMs[slot] }
        return settleOffsetsMs[settleOffsetsMs.count - 1] + Double(slot - settleOffsetsMs.count + 1) * steadyIntervalMs
    }

    /// `markerSeed` is nil when the frame's marker could not be read; that changes nothing.
    mutating func frame(markerSeed: UInt16?, atMs now: Double) -> Job? {
        guard let markerSeed else { return nil }
        guard markerSeed != Self.noChart else { seed = nil; return nil }
        if markerSeed != seed {
            seed = markerSeed
            changedAtMs = now
            nextSlot = 0
        }
        let age = now - changedAtMs
        guard !inFlight, age >= Self.offsetMs(slot: nextSlot) else { return nil }
        let first = nextSlot
        while Self.offsetMs(slot: nextSlot) <= age { nextSlot += 1 }
        inFlight = true
        return Job(seed: markerSeed, ageMs: age, scoresDecoded: (first..<nextSlot).contains(Self.decodedSlot))
    }

    mutating func finished() { inFlight = false }

    /// Forgets the chart but not a scoring still running, so a restart never overlaps it.
    mutating func forgetChart() {
        seed = nil
        nextSlot = 0
    }
}

/// Scores the legibility chart in decoded frames while Stream statistics is on. Frames arrive on
/// WebRTC's decode thread; at a scheduled moment the chart crop of that frame is rendered on a
/// utility queue (the decoder's buffer is held only for that one render), then scored with Vision
/// as "displayed" (resampled to the picture's on-screen pixel size) and, at +3 s, "decoded".
final class LegibilityProbe: @unchecked Sendable {
    static let displayedSurface = "displayed"
    static let decodedSurface = "decoded"

    private static let queue = DispatchQueue(label: "Farside.legibility", qos: .utility)
    private static let context = CIContext(options: [.cacheIntermediates: false])

    private let lock = NSLock()
    private var scheduler = LegibilityScheduler()
    private var enabled = false
    private var counters: StreamCounters?
    private var sourceSize = CGSize.zero
    private var displayedPixelWidth: CGFloat = 0

    func configure(enabled: Bool, counters: StreamCounters?, sourceSize: CGSize, displayedPixelWidth: CGFloat) {
        lock.lock(); defer { lock.unlock() }
        if !enabled || counters !== self.counters { scheduler.forgetChart() }
        self.enabled = enabled
        self.counters = counters
        self.sourceSize = sourceSize
        self.displayedPixelWidth = displayedPixelWidth
    }

    /// `visible` is the frame's crop in buffer pixels with a top-left origin.
    func frameArrived(_ pixelBuffer: CVPixelBuffer, visible: CGRect, marker: BenchMarker?,
                      atMs now: Double = MachClock.nowMs()) {
        lock.lock()
        guard enabled, let counters, sourceSize.width > 0, sourceSize.height > 0,
              let job = scheduler.frame(markerSeed: marker?.chartSeed, atMs: now) else {
            lock.unlock()
            return
        }
        let source = sourceSize
        let onScreenWidth = displayedPixelWidth
        lock.unlock()
        let frame = CIImage(cvPixelBuffer: pixelBuffer)
        let bufferSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        Self.queue.async { [self] in
            let zoom = Self.displayedZoom(onScreenPixelWidth: onScreenWidth, frameWidth: visible.width)
            let surfaces = Self.surfaces(of: frame, bufferSize: bufferSize, visible: visible, sourceSize: source,
                                         zoom: zoom, includeDecoded: job.scoresDecoded)
            // Vision runs in a separate block so the decoder's buffer is released as soon as the
            // crops are copied out, not after the much slower scoring.
            Self.queue.async { [self] in
                defer { lock.lock(); scheduler.finished(); lock.unlock() }
                for surface in surfaces { report(job, surface, to: counters) }
            }
        }
    }

    private struct Surface {
        let image: CGImage
        let name: String
        let zoom: Double
    }

    private static func surfaces(of frame: CIImage, bufferSize: CGSize, visible: CGRect, sourceSize: CGSize,
                                 zoom: Double, includeDecoded: Bool) -> [Surface] {
        guard let crop = chartCrop(frame, bufferSize: bufferSize, visible: visible, sourceSize: sourceSize) else { return [] }
        var surfaces: [Surface] = []
        if let displayed = render(resampled(crop, by: zoom)) {
            surfaces.append(Surface(image: displayed, name: displayedSurface, zoom: zoom))
        }
        if includeDecoded, let decoded = render(crop) {
            surfaces.append(Surface(image: decoded, name: decodedSurface, zoom: 1))
        }
        return surfaces
    }

    private func report(_ job: LegibilityScheduler.Job, _ surface: Surface, to counters: StreamCounters) {
        guard let result = try? LegibilityScore.score(image: surface.image, seed: job.seed) else { return }
        counters.legibilityScored(LegibilitySummary(seed: Int(job.seed), ageMs: job.ageMs.rounded(), surface: surface.name,
                                                    zoom: (surface.zoom * 100).rounded() / 100, cer: result.cerBySize))
    }

    /// On-screen device pixels per stream pixel; 1 when the on-screen size is unknown.
    static func displayedZoom(onScreenPixelWidth: CGFloat, frameWidth: CGFloat) -> Double {
        guard onScreenPixelWidth > 0, frameWidth > 0 else { return 1 }
        return Double(onScreenPixelWidth / frameWidth)
    }

    /// The chart in frame pixels, top-left origin: its display-point layout scaled by the frame
    /// size over the Mac display's point size.
    static func chartRect(visible: CGRect, sourceSize: CGSize) -> CGRect? {
        guard sourceSize.width > 0, sourceSize.height > 0, !visible.isEmpty else { return nil }
        let chart = LegibilityChart.layout(displayPointSize: sourceSize).frame
        let scaleX = visible.width / sourceSize.width, scaleY = visible.height / sourceSize.height
        let rect = CGRect(x: visible.minX + chart.minX * scaleX, y: visible.minY + chart.minY * scaleY,
                          width: chart.width * scaleX, height: chart.height * scaleY).integral
        let clipped = rect.intersection(visible)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    /// Core Image puts the origin at the bottom left.
    static func coreImageRect(_ rect: CGRect, bufferHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: bufferHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func chartCrop(_ frame: CIImage, bufferSize: CGSize, visible: CGRect, sourceSize: CGSize) -> CIImage? {
        guard let rect = chartRect(visible: visible, sourceSize: sourceSize) else { return nil }
        let area = coreImageRect(rect, bufferHeight: bufferSize.height)
        return frame.cropped(to: area).transformed(by: CGAffineTransform(translationX: -area.minX, y: -area.minY))
    }

    /// Bilinear, like the Metal view's texture sampling.
    private static func resampled(_ image: CIImage, by zoom: Double) -> CIImage {
        guard zoom != 1 else { return image }
        let size = CGSize(width: (image.extent.width * zoom).rounded(.down), height: (image.extent.height * zoom).rounded(.down))
        return image.clampedToExtent().samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Not deferred: the pixels are copied now, so the CGImage keeps no reference to the frame.
    private static func render(_ image: CIImage) -> CGImage? {
        guard image.extent.width >= 1, image.extent.height >= 1, image.extent.width.isFinite else { return nil }
        return context.createCGImage(image, from: image.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false)
    }
}
