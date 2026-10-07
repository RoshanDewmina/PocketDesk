import CoreGraphics
import CoreVideo
import Foundation
import os

/// Main thread only. The model feeds finger scroll and the Mac's `scrollRegion`; the main picture's
/// renderer asks it for the shift of each redraw and tells it about every new frame (`LocalScrollEcho`).
final class LocalScrollEchoController {
    private(set) var state: LocalScrollEcho
    /// The Mac-point rect of the last drawn picture, for a frame whose own tag carries no region.
    var picture: CGRect = .zero
    /// The main picture's renderer, told when the slide moved.
    weak var renderer: OwnedMetalVideoView?
    private var previousSamples: [UInt8]?
    private var previousKey: SampleKey?
    private var lastFrameID: UUID?
    /// This gesture's slide redraws, and real frames drawn while one of them was still on its way to the
    /// display (each of those may have shown one refresh late). Logged when the next gesture begins.
    var slideDraws = 0
    var framesBehindSlide = 0
    private static let logger = Logger(subsystem: "com.roshan.PocketDesk", category: "local-scroll")

    private struct SampleKey: Equatable { let picture: CGRect; let region: CGRect; let size: CGSize }

    init(enabled: Bool = LocalScrollSwitch.isEnabled()) { state = LocalScrollEcho(enabled: enabled) }

    var enabled: Bool { state.enabled }

    func setRegion(_ rect: CGRect?) {
        guard state.setRegion(rect) else { return }
        renderer?.localScrollChanged()
    }

    /// A finger scroll the phone sent (direct touch or a two-finger trackpad scroll), in Mac points.
    func scrolled(_ delta: CGSize, phase: String, pointer: CGPoint? = nil,
                  at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if phase == "began" {
            if slideDraws > 0 {
                Self.logger.notice("gesture slides \(self.slideDraws, privacy: .public) framesBehindSlide \(self.framesBehindSlide, privacy: .public) stopped \(self.state.stopped, privacy: .public)")
            }
            slideDraws = 0; framesBehindSlide = 0
            previousSamples = nil; previousKey = nil
        }
        let wasEchoing = state.isEchoing
        guard state.scrolled(delta, phase: phase, pointer: pointer, at: now) else { return }
        renderer?.localScrollChanged()
        if !wasEchoing {
            DispatchQueue.main.asyncAfter(deadline: .now() + LocalScrollEcho.staleAfter + 0.005) { [weak self] in
                self?.expire()
            }
        }
    }

    func expire(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard state.expire(at: now) else { return }
        renderer?.localScrollChanged()
    }

    /// Once per decoded frame, however often its draw is retried.
    func frameArrived(_ id: UUID, original: Bool, at now: TimeInterval) {
        guard id != lastFrameID else { return }
        lastFrameID = id
        state.frameArrived(original: original, at: now)
    }

    func uniform(picture: CGRect, pixels: CGSize) -> LocalScrollUniform? { state.uniform(picture: picture, pixels: pixels) }

    var wantsChangeCheck: Bool { state.wantsChangeCheck }

    func redrawAllowed(at now: TimeInterval, refresh: TimeInterval) -> Bool { state.redrawAllowed(at: now, refresh: refresh) }

    /// After an original frame is committed: compare a sparse luma grid inside the region with the last one.
    func observe(_ pixels: VideoFrameEnvelope.Pixels, geometry: VideoPixelGeometry, picture: CGRect,
                 at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard state.wantsChangeCheck, let region = state.region, picture.width > 0, picture.height > 0 else { return }
        let clip = region.intersection(picture)
        guard !clip.isNull, clip.width > 0, clip.height > 0 else { return }
        let local = CGRect(x: (clip.minX - picture.minX) / picture.width, y: (clip.minY - picture.minY) / picture.height,
                           width: clip.width / picture.width, height: clip.height / picture.height)
        let key = SampleKey(picture: picture, region: clip, size: geometry.displaySize)
        guard let samples = Self.luma(pixels, geometry: geometry, at: LocalScrollEcho.samplePoints(in: local)) else { return }
        defer { previousSamples = samples; previousKey = key }
        guard previousKey == key, let previousSamples,
              let changed = LocalScrollEcho.regionChanged(previousSamples, samples) else { return }
        state.observed(changed: changed, at: now)
    }

    /// Luma (or green, for BGRA) at each picture point, read from the decoded buffer's first plane.
    static func luma(_ pixels: VideoFrameEnvelope.Pixels, geometry: VideoPixelGeometry, at points: [CGPoint]) -> [UInt8]? {
        let buffer = pixels.buffer
        guard !points.isEmpty, CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let row = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let stride = pixels.bgra ? 4 : 1, channel = pixels.bgra ? 1 : 0
        guard width > 0, height > 0, row >= width * stride else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        return points.map { point in
            let uv = geometry.bufferUV(x: point.x, y: point.y)
            let x = min(width - 1, max(0, Int(uv.x * CGFloat(width)))), y = min(height - 1, max(0, Int(uv.y * CGFloat(height))))
            return bytes[y * row + x * stride + channel]
        }
    }
}
