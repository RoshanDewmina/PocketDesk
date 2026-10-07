import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Idea 2 (LATENCY-PLAN §2.2): a soft whole-display backdrop behind the crisp viewport crop, so a pan
/// past the crop's margin shows the desktop at low resolution instead of the void.
///
/// Transport: HEIC (JPEG where HEIC is unavailable) snapshots of a second, 640 px ScreenCaptureKit
/// stream on their own `backdrop.1` data channel, not a second `RTCVideoTrack`. A second video sender
/// would share the owned encoder/decoder factories, the frame-feedback, LTR, refinement and timing
/// contexts, `senders.first(where: video)` rate control and the outbound-rtp statistics, all built for
/// one desktop track; a channel the host opens at session start needs no renegotiation and touches none
/// of that. The host's agreement is the channel itself, so no `capture` feature slot (32-name bound) is
/// spent: an old phone never asks, and a phone whose request was not honoured simply never sees one.
extension SessionFeature {
    /// Phone request only, as `Handshake.backdrop`: `features` and `options` are at the bound older Macs
    /// decode. Honoured only with the Mac's `StreamTuning.backdropTrack`.
    static let backdrop = "video.backdrop.1"
}

/// Phone flag (`defaults write com.roshan.PocketDesk.Remote PocketDeskBackdrop -bool YES`, or the
/// launch argument `-PocketDeskBackdrop YES`). Off by default: the phone never asks for a backdrop.
enum BackdropRequest {
    static let defaultsKey = "PocketDeskBackdrop"
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }
    static let isOn = isEnabled()
}

enum BackdropCapturePolicy {
    static let longEdge = 640
    static let framesPerSecond: Int32 = 4
    /// Sent snapshot bytes are held to this average (token bucket), whatever the screen does.
    static let bitsPerSecond = 400_000.0

    /// The Mac honours a phone's request only with its own flag on; the phone adopts a channel only
    /// after asking for one.
    static func negotiated(isHost: Bool, peerFeatures: Set<String>, requested: Set<String>,
                           tuning: StreamTuning = .current) -> Bool {
        isHost ? tuning.backdropTrack && peerFeatures.contains(SessionFeature.backdrop) : requested.contains(SessionFeature.backdrop)
    }

    /// A scoped (window or app) session never gets a whole-display backdrop.
    static func runs(negotiated: Bool, scoped: Bool) -> Bool { negotiated && !scoped }

    /// The backdrop's pixel size: the display's aspect at a 640 px long edge, even dimensions.
    static func outputSize(contentSize: CGSize, longEdge: Int = longEdge) -> (width: Int, height: Int)? {
        guard contentSize.width.isFinite, contentSize.height.isFinite, contentSize.width > 0, contentSize.height > 0 else { return nil }
        let scale = Double(longEdge) / Double(max(contentSize.width, contentSize.height))
        func even(_ value: CGFloat) -> Int { max(2, Int((Double(value) * scale / 2).rounded()) * 2) }
        return (even(contentSize.width), even(contentSize.height))
    }
}

/// Wire format on the `backdrop.1` channel: version, sequence, the display size in points the image
/// covers, then the encoded image.
struct BackdropSnapshot: Equatable {
    static let version: UInt8 = 1
    static let headerBytes = 9
    static let maximumMessageBytes = 64 * 1024
    static let maximumLongEdge = 1024

    var sequence: UInt32
    var displayWidth: UInt16
    var displayHeight: UInt16
    var image: Data

    init(sequence: UInt32, displaySize: CGSize, image: Data) {
        self.sequence = sequence
        func points(_ value: CGFloat) -> UInt16 { UInt16(clamping: Int(value.isFinite ? value.rounded() : 0)) }
        displayWidth = points(displaySize.width); displayHeight = points(displaySize.height)
        self.image = image
    }

    var displaySize: CGSize { CGSize(width: Int(displayWidth), height: Int(displayHeight)) }

    func encoded() -> Data {
        var data = Data([Self.version])
        withUnsafeBytes(of: sequence.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: displayWidth.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: displayHeight.bigEndian) { data.append(contentsOf: $0) }
        data.append(image)
        return data
    }

    static func decode(_ data: Data) -> BackdropSnapshot? {
        guard data.count > headerBytes, data.count <= maximumMessageBytes else { return nil }
        let bytes = [UInt8](data.prefix(headerBytes))
        guard bytes[0] == version else { return nil }
        let sequence = bytes[1...4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let width = UInt16(bytes[5]) << 8 | UInt16(bytes[6]), height = UInt16(bytes[7]) << 8 | UInt16(bytes[8])
        guard width > 0, height > 0 else { return nil }
        var snapshot = BackdropSnapshot(sequence: sequence, displaySize: .zero, image: Data(data.dropFirst(headerBytes)))
        snapshot.displayWidth = width; snapshot.displayHeight = height
        return snapshot
    }

    /// HEIC at quality 0.5, JPEG where this OS has no HEIC encoder, then once more at 0.3 if the
    /// first try does not fit a message.
    static func encodeImage(_ image: CGImage) -> Data? {
        let heic = UTType.heic.identifier as CFString
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        let type = types.contains(heic as String) ? heic : UTType.jpeg.identifier as CFString
        let limit = maximumMessageBytes - headerBytes
        for quality in [0.5, 0.3] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if output.length <= limit { return output as Data }
        }
        return nil
    }

    /// Checks the declared size before decoding, and decodes now so drawing never does.
    static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (2...maximumLongEdge).contains(width), (2...maximumLongEdge).contains(height) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

@MainActor
final class BackdropStore: ObservableObject {
    @Published var image: BackdropImage?
}

/// A decoded backdrop, as the phone draws it.
struct BackdropImage {
    let image: CGImage
    let sequence: UInt32
    let displaySize: CGSize

    /// A snapshot of another display (or from before a display switch) is never drawn.
    func matches(display: CGSize) -> Bool {
        abs(display.width - displaySize.width) <= 1 && abs(display.height - displaySize.height) <= 1
    }
}

/// Average send rate for snapshots: a send needs a positive balance and may overdraw it once, so a
/// snapshot larger than one second's allowance still goes out, and the average stays at `rate`.
struct BackdropByteBudget {
    let bytesPerSecond: Double
    private(set) var balance: Double
    private var updatedAt: TimeInterval?

    init(bitsPerSecond: Double = BackdropCapturePolicy.bitsPerSecond) {
        bytesPerSecond = bitsPerSecond / 8
        balance = bytesPerSecond
    }

    mutating func permits(at now: TimeInterval) -> Bool { refill(at: now); return balance > 0 }

    mutating func spend(_ bytes: Int, at now: TimeInterval) { refill(at: now); balance -= Double(bytes) }

    private mutating func refill(at now: TimeInterval) {
        if let updatedAt, now > updatedAt { balance = min(bytesPerSecond, balance + (now - updatedAt) * bytesPerSecond) }
        updatedAt = max(updatedAt ?? now, now)
    }
}

struct BackdropEdges: Equatable {
    var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0
}

/// Where the backdrop shows, in picture-container points (the whole display at the current scale).
/// The phone draws it above the crisp picture, opaque outside `crisp` and fading to clear across a
/// `feather` band just inside it; an edge of `crisp` on the display's own edge has no band.
struct BackdropCoverage: Equatable {
    var bounds: CGRect
    var crisp: CGRect
    var feather: BackdropEdges
    /// Part of the visible desktop has no crisp pixels under it.
    var uncovered: Bool
    /// The part of `bounds` on screen (all of it when unknown); only this much is drawn.
    var visible: CGRect
}

enum BackdropComposite {
    static let featherPixels: CGFloat = 24

    /// Nil when the backdrop is not drawn: no crop is active and the crisp picture covers the view.
    static func coverage(viewport: ViewportTransform, region: CaptureRegion?, displayScale: CGFloat) -> BackdropCoverage? {
        guard displayScale.isFinite, displayScale > 0 else { return nil }
        return coverage(bounds: CGRect(origin: .zero, size: viewport.contentRect.size),
                        crisp: viewport.picturePlacement(for: region),
                        visible: viewport.pictureRect(fromSource: viewport.visibleSourceRect),
                        cropped: region.map { !$0.isWholeDisplay } ?? false,
                        featherPoints: featherPixels / displayScale)
    }

    static func coverage(bounds: CGRect, crisp: CGRect, visible: CGRect, cropped: Bool, featherPoints: CGFloat) -> BackdropCoverage? {
        guard isFinite(bounds), isFinite(crisp), bounds.width > 0, bounds.height > 0, featherPoints.isFinite else { return nil }
        let tolerance: CGFloat = 0.5
        let clipped = crisp.intersection(bounds)
        let picture = clipped.isNull || clipped.width <= 0 || clipped.height <= 0 ? CGRect.zero : clipped
        var feather = BackdropEdges()
        if picture.width > 0 {
            let across = max(0, min(featherPoints, picture.width / 2)), down = max(0, min(featherPoints, picture.height / 2))
            if picture.minY > bounds.minY + tolerance { feather.top = down }
            if picture.maxY < bounds.maxY - tolerance { feather.bottom = down }
            if picture.minX > bounds.minX + tolerance { feather.left = across }
            if picture.maxX < bounds.maxX - tolerance { feather.right = across }
        }
        let shown = isFinite(visible) ? visible.intersection(bounds) : .null
        let sharp = CGRect(x: picture.minX + feather.left, y: picture.minY + feather.top,
                           width: max(0, picture.width - feather.left - feather.right),
                           height: max(0, picture.height - feather.top - feather.bottom))
        let uncovered = !shown.isNull && shown.width > tolerance && shown.height > tolerance
            && !sharp.insetBy(dx: -tolerance, dy: -tolerance).contains(shown)
        guard cropped || uncovered else { return nil }
        let drawn = shown.isNull || shown.width <= 0 || shown.height <= 0 ? bounds : shown
        return BackdropCoverage(bounds: bounds, crisp: picture, feather: feather, uncovered: uncovered, visible: drawn)
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        !rect.isNull && [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
    }
}

/// When the first frame of a new crop is drawn, the backdrop over the area it newly covers fades out
/// instead of popping to sharp: the previous crop's coverage stays in the mask at falling opacity.
struct BackdropFade {
    static let duration: TimeInterval = 0.15
    static let maximumFading = 3

    struct Entry: Equatable {
        var region: CaptureRegion
        var startedAt: TimeInterval
    }

    private(set) var current: CaptureRegion?
    private(set) var fading: [Entry] = []

    /// The previous crop when a fade starts. Entering a crop, or leaving one for the whole display (the
    /// crisp picture then covers everything), fades nothing; an unchanged rect is no change.
    mutating func observe(_ region: CaptureRegion?, at now: TimeInterval) -> CaptureRegion? {
        prune(at: now)
        let next = region.flatMap { $0.isWholeDisplay ? nil : $0 }
        guard next?.rect != current?.rect else { current = next; return nil }
        let previous = current
        current = next
        guard let previous, next != nil else { fading.removeAll(); return nil }
        fading.append(Entry(region: previous, startedAt: now))
        if fading.count > Self.maximumFading { fading.removeFirst(fading.count - Self.maximumFading) }
        return previous
    }

    mutating func prune(at now: TimeInterval) {
        fading.removeAll { now - $0.startedAt >= Self.duration }
    }

    static func opacity(startedAt: TimeInterval, at now: TimeInterval) -> Double {
        max(0, min(1, 1 - (now - startedAt) / duration))
    }
}
