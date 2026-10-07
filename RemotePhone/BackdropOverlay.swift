import SwiftUI
import UIKit

/// Draws the store's snapshot when it shows this display; observes only the store.
struct BackdropLayer: View {
    @ObservedObject var store: BackdropStore
    let display: CGSize
    let coverage: BackdropCoverage
    let region: CaptureRegion?
    let scale: CGFloat
    let featherPoints: CGFloat

    var body: some View {
        if let backdrop = store.image, backdrop.matches(display: display) {
            BackdropOverlay(image: backdrop.image, coverage: coverage, region: region, scale: scale, featherPoints: featherPoints)
        }
    }
}

/// Idea 2: the soft whole-display backdrop, drawn above the crisp picture through a mask that is clear
/// over the crisp crop and opaque outside it, with a feathered band at the crop's inner edges. Masking
/// this still layer (not the Metal picture) keeps the picture's present path untouched.
struct BackdropOverlay: UIViewRepresentable {
    let image: CGImage
    let coverage: BackdropCoverage
    let region: CaptureRegion?
    /// Container points per Mac point.
    let scale: CGFloat
    let featherPoints: CGFloat

    func makeUIView(context: Context) -> BackdropOverlayView { BackdropOverlayView() }

    func updateUIView(_ view: BackdropOverlayView, context: Context) {
        // The layers are placed at their final geometry; while SwiftUI eases the container they would
        // not match the picture, so an animated change hides them until it has settled.
        if context.transaction.animation != nil, view.appliedCoverage.map({ $0.bounds != coverage.bounds || $0.crisp != coverage.crisp }) ?? false {
            view.suspend(for: 0.45)
        }
        view.apply(image: image, coverage: coverage, region: region, scale: scale, featherPoints: featherPoints,
                   at: CACurrentMediaTime())
    }
}

final class BackdropOverlayView: UIView {
    let imageLayer = CALayer()
    private let maskRoot = CALayer()
    private let currentMask = BackdropMaskLayer()
    private(set) var fadingMasks: [(entry: BackdropFade.Entry, layer: BackdropMaskLayer)] = []
    private var fade = BackdropFade()
    private var image: CGImage?
    private(set) var appliedCoverage: BackdropCoverage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear
        imageLayer.actions = BackdropMaskLayer.noActions
        maskRoot.actions = BackdropMaskLayer.noActions
        // Image and mask change a few times a second at most; the cache spares a masked offscreen pass
        // on every picture frame.
        imageLayer.shouldRasterize = true
        maskRoot.addSublayer(currentMask)
        imageLayer.mask = maskRoot
        layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(image: CGImage, coverage: BackdropCoverage, region: CaptureRegion?, scale: CGFloat,
               featherPoints: CGFloat, at now: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if self.image !== image { self.image = image; imageLayer.contents = image }
        // Only the visible part is drawn, so the masked layer is never larger than the screen.
        let drawn = coverage.visible, bounds = coverage.bounds
        imageLayer.frame = drawn
        imageLayer.contentsRect = CGRect(x: (drawn.minX - bounds.minX) / bounds.width, y: (drawn.minY - bounds.minY) / bounds.height,
                                         width: drawn.width / bounds.width, height: drawn.height / bounds.height)
        imageLayer.rasterizationScale = window?.screen.scale ?? traitCollection.displayScale
        maskRoot.frame = CGRect(origin: .zero, size: drawn.size)
        maskRoot.bounds = drawn
        currentMask.layout(coverage)
        appliedCoverage = coverage
        if let previous = fade.observe(region, at: now) {
            let layer = BackdropMaskLayer()
            maskRoot.addSublayer(layer)
            layer.opacity = 0
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1; animation.toValue = 0; animation.duration = BackdropFade.duration
            layer.add(animation, forKey: "fade")
            fadingMasks.append((BackdropFade.Entry(region: previous, startedAt: now), layer))
            DispatchQueue.main.asyncAfter(deadline: .now() + BackdropFade.duration + 0.05) { [weak self] in
                self?.pruneFades(at: CACurrentMediaTime())
            }
        }
        pruneFades(at: now)
        for fading in fadingMasks {
            let crisp = CGRect(x: fading.entry.region.x * scale, y: fading.entry.region.y * scale,
                               width: fading.entry.region.width * scale, height: fading.entry.region.height * scale)
            if let old = BackdropComposite.coverage(bounds: coverage.bounds, crisp: crisp, visible: .null,
                                                    cropped: true, featherPoints: featherPoints) {
                fading.layer.layout(old)
            }
        }
    }

    private var suspendedUntil: TimeInterval = 0

    func suspend(for duration: TimeInterval) {
        suspendedUntil = CACurrentMediaTime() + duration
        isHidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, CACurrentMediaTime() >= self.suspendedUntil - 0.01 else { return }
            self.isHidden = false
        }
    }

    private func pruneFades(at now: TimeInterval) {
        fade.prune(at: now)
        let live = fade.fading
        fadingMasks.removeAll { fading in
            guard !live.contains(fading.entry) else { return false }
            fading.layer.removeFromSuperlayer()
            return true
        }
    }
}

/// Opaque outside `crisp` (an even-odd shape) plus one gradient strip per feathered inner edge.
final class BackdropMaskLayer: CALayer {
    static let noActions: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(),
                                                 "path": NSNull(), "hidden": NSNull(), "frame": NSNull()]
    private let outside = CAShapeLayer()
    private let strips = (0..<4).map { _ in CAGradientLayer() }

    override init() {
        super.init()
        actions = Self.noActions
        outside.fillRule = .evenOdd
        outside.fillColor = UIColor.black.cgColor
        outside.actions = Self.noActions
        addSublayer(outside)
        for strip in strips {
            strip.colors = [UIColor.black.cgColor, UIColor.black.withAlphaComponent(0.45).cgColor, UIColor.clear.cgColor]
            strip.locations = [0, 0.4, 1]
            strip.actions = Self.noActions
            addSublayer(strip)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func layout(_ coverage: BackdropCoverage) {
        frame = CGRect(origin: .zero, size: coverage.bounds.size)
        let crisp = coverage.crisp, feather = coverage.feather
        let path = CGMutablePath()
        path.addRect(coverage.bounds)
        if crisp.width > 0, crisp.height > 0 { path.addRect(crisp) }
        outside.frame = bounds
        outside.path = path
        let edges: [(CGRect, CGPoint, CGPoint)] = [
            (CGRect(x: crisp.minX, y: crisp.minY, width: crisp.width, height: feather.top), CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)),
            (CGRect(x: crisp.minX, y: crisp.maxY - feather.bottom, width: crisp.width, height: feather.bottom), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
            (CGRect(x: crisp.minX, y: crisp.minY, width: feather.left, height: crisp.height), CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
            (CGRect(x: crisp.maxX - feather.right, y: crisp.minY, width: feather.right, height: crisp.height), CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
        ]
        for (strip, edge) in zip(strips, edges) {
            strip.isHidden = edge.0.width <= 0 || edge.0.height <= 0
            strip.frame = edge.0
            strip.startPoint = edge.1
            strip.endPoint = edge.2
        }
    }
}
