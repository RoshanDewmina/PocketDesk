import AppKit
import ApplicationServices

/// Identifies the displayed Mac cursor using public API only.
///
/// Primary: `NSCursor.currentSystem` (soft-deprecated in the macOS 27 SDK, documented to
/// return nil "in a future version"). Its image is matched against AppKit's standard cursors
/// by aspect, normalized hot spot and a 64×64 alpha mask, so enlarged or recoloured
/// accessibility pointers still match; a three-level tone mask only breaks ties between
/// shapes with the same silhouette (for example the copy and not-allowed badges).
/// Fallback when it returns nil: the Accessibility role under the pointer
/// (text → I-beam, link → pointing hand). Otherwise the arrow.
struct CursorFingerprint: Equatable {
    static let side = 64
    let aspect: CGFloat
    let hotSpot: CGPoint
    let mask: [UInt8]
    let tone: [UInt8]

    init?(image: NSImage, hotSpot: NSPoint) {
        let size = image.size
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Self.side, pixelsHigh: Self.side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: Self.side * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        var mask = [UInt8](repeating: 0, count: Self.side * Self.side)
        var tone = mask
        for index in mask.indices {
            let alpha = Double(data[index * 4 + 3])
            guard alpha > 127 else { continue }
            mask[index] = 1
            let luminance = (0.2126 * Double(data[index * 4]) + 0.7152 * Double(data[index * 4 + 1])
                             + 0.0722 * Double(data[index * 4 + 2])) / alpha
            tone[index] = luminance < 0.35 ? 0 : luminance < 0.8 ? 1 : 2
        }
        self.aspect = size.width / size.height
        self.hotSpot = CGPoint(x: hotSpot.x / size.width, y: hotSpot.y / size.height)
        self.mask = mask
        self.tone = tone
    }

    /// Silhouette and tone differences in pixels, or nil when proportions or hot spot differ.
    func distance(to other: CursorFingerprint) -> (silhouette: Int, tone: Int)? {
        guard abs(aspect - other.aspect) <= 0.06,
              abs(hotSpot.x - other.hotSpot.x) <= 0.05, abs(hotSpot.y - other.hotSpot.y) <= 0.05 else { return nil }
        var silhouette = 0
        var toneDifference = 0
        for index in mask.indices {
            if mask[index] != other.mask[index] { silhouette += 1 }
            else if mask[index] == 1 && tone[index] != other.tone[index] { toneDifference += 1 }
        }
        return (silhouette, toneDifference)
    }
}

enum CursorShapeClassifier {
    /// About 6% of the mask; distinct standard cursors differ by far more.
    static let maximumDistance = 256
    /// Shapes whose silhouettes are this close are separated by tone instead.
    static let silhouetteTie = 48

    struct Reference {
        let shape: PointerShape
        let fingerprint: CursorFingerprint
    }

    @MainActor
    static func standardReferences() -> [Reference] {
        var cursors: [(PointerShape, NSCursor)] = [
            (.arrow, .arrow), (.iBeam, .iBeam), (.iBeamVertical, .iBeamCursorForVerticalLayout),
            (.pointingHand, .pointingHand), (.openHand, .openHand), (.closedHand, .closedHand),
            (.crosshair, .crosshair), (.notAllowed, .operationNotAllowed),
            (.contextualMenu, .contextualMenu), (.dragCopy, .dragCopy), (.dragLink, .dragLink),
            (.disappearingItem, .disappearingItem), (.zoomIn, .zoomIn), (.zoomOut, .zoomOut),
            (.resizeLeftRight, .columnResize), (.resizeUpDown, .rowResize),
            (.resizeLeftRight, .columnResize(directions: .left)), (.resizeLeftRight, .columnResize(directions: .right)),
            (.resizeUpDown, .rowResize(directions: .up)), (.resizeUpDown, .rowResize(directions: .down)),
            (.resizeLeftRight, .resizeLeftRight), (.resizeLeftRight, .resizeLeft), (.resizeLeftRight, .resizeRight),
            (.resizeUpDown, .resizeUpDown), (.resizeUpDown, .resizeUp), (.resizeUpDown, .resizeDown)
        ]
        let frames: [(NSCursor.FrameResizePosition, PointerShape)] = [
            (.left, .resizeLeftRight), (.right, .resizeLeftRight), (.top, .resizeUpDown), (.bottom, .resizeUpDown),
            (.topLeft, .resizeNorthWestSouthEast), (.bottomRight, .resizeNorthWestSouthEast),
            (.topRight, .resizeNorthEastSouthWest), (.bottomLeft, .resizeNorthEastSouthWest)
        ]
        for (position, shape) in frames {
            for directions: NSCursor.FrameResizeDirection.Set in [.all, .inward, .outward] {
                cursors.append((shape, .frameResize(position: position, directions: directions)))
            }
        }
        return cursors.compactMap { shape, cursor in
            CursorFingerprint(image: cursor.image, hotSpot: cursor.hotSpot).map { Reference(shape: shape, fingerprint: $0) }
        }
    }

    static func classify(_ fingerprint: CursorFingerprint, references: [Reference]) -> PointerShape {
        let candidates = references.compactMap { reference -> (PointerShape, Int, Int)? in
            guard let distance = fingerprint.distance(to: reference.fingerprint),
                  distance.silhouette <= maximumDistance else { return nil }
            return (reference.shape, distance.silhouette, distance.tone)
        }
        guard let closest = candidates.map(\.1).min() else { return .unknown }
        return candidates.filter { $0.1 <= closest + silhouetteTie }
            .min { ($0.2, $0.1) < ($1.2, $1.1) }?.0 ?? .unknown
    }

    /// Conservative role mapping for the Accessibility fallback. Labels stay arrows.
    static func shape(role: String?, subrole: String?) -> PointerShape {
        switch role.map(NSAccessibility.Role.init(rawValue:)) {
        case .textField?, .textArea?, .comboBox?: return .iBeam
        case .link?: return .pointingHand
        case .splitter?: return .resizeLeftRight
        default:
            let editable: [NSAccessibility.Subrole] = [.searchField, .secureTextField]
            return subrole.map { editable.contains(NSAccessibility.Subrole(rawValue: $0)) } == true ? .iBeam : .arrow
        }
    }
}

/// Samples the current cursor shape on the main thread; the Accessibility fallback runs
/// off-main with one query in flight so an unresponsive app cannot stall telemetry.
@MainActor
final class HostCursorShapeSampler {
    private lazy var references = CursorShapeClassifier.standardReferences()
    /// Holds the image strongly so identity comparison can never match a reused address.
    private var cache: (image: NSImage, hotSpot: NSPoint, shape: PointerShape)?
    private let accessibilityQueue = DispatchQueue(label: "PocketDesk.cursor-accessibility", qos: .userInitiated)
    private var accessibilityInFlight = false
    private var accessibilityShape: PointerShape = .arrow
    private var lastAccessibilityPoint: CGPoint?
    private var lastAccessibilityAt: TimeInterval = -.infinity
    private(set) var usingFallback = false

    func reset() {
        cache = nil
        accessibilityShape = .arrow
        lastAccessibilityPoint = nil
        lastAccessibilityAt = -.infinity
        usingFallback = false
    }

    /// `globalPoint` is only used by the Accessibility fallback.
    func currentShape(at globalPoint: CGPoint?, now: TimeInterval) -> PointerShape {
        if let cursor = NSCursor.currentSystem {
            usingFallback = false
            let image = cursor.image
            if let cache, cache.image === image, cache.hotSpot == cursor.hotSpot { return cache.shape }
            let shape = CursorFingerprint(image: image, hotSpot: cursor.hotSpot)
                .map { CursorShapeClassifier.classify($0, references: references) } ?? .unknown
            cache = (image, cursor.hotSpot, shape)
            return shape
        }
        usingFallback = true
        refreshAccessibilityShape(at: globalPoint, now: now)
        return accessibilityShape
    }

    private func refreshAccessibilityShape(at point: CGPoint?, now: TimeInterval) {
        guard let point, !accessibilityInFlight, AXIsProcessTrusted(),
              now - lastAccessibilityAt >= 0.15, point != lastAccessibilityPoint else { return }
        accessibilityInFlight = true
        lastAccessibilityAt = now
        lastAccessibilityPoint = point
        accessibilityQueue.async { [weak self] in
            let shape = Self.accessibilityShape(at: point)
            DispatchQueue.main.async {
                guard let self else { return }
                self.accessibilityInFlight = false
                self.accessibilityShape = shape
            }
        }
    }

    nonisolated private static func accessibilityShape(at point: CGPoint) -> PointerShape {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else { return .arrow }
        _ = AXUIElementSetMessagingTimeout(element, 0.1)
        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        return CursorShapeClassifier.shape(role: string(kAXRoleAttribute), subrole: string(kAXSubroleAttribute))
    }
}
