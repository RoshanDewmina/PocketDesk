import SwiftUI
import Combine
import QuartzCore

/// On-screen pointer height, independent of desktop zoom so it stays readable in Fit.
enum PointerSizePreference: String, CaseIterable, Identifiable {
    case small, medium, large, extraLarge

    static let key = "pointerSize"
    var id: String { rawValue }

    /// The size in use: an explicit `defaults write … pointerSize` wins, otherwise Medium, or Large
    /// when the person uses an accessibility (Larger Text) size.
    static func resolved(stored: PointerSizePreference?, largerText: Bool) -> PointerSizePreference {
        stored ?? (largerText ? .large : .medium)
    }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    /// Height of the arrow in points. Medium is roughly five times the streamed macOS arrow at Fit.
    var arrowHeight: CGFloat {
        switch self {
        case .small: 26
        case .medium: 34
        case .large: 44
        case .extraLarge: 56
        }
    }
}

/// How the view moves to keep the pointer in sight while zoomed in. The pointer itself is never
/// eased: it is drawn inside the picture's own placement, so it can only ever sit where the Mac
/// pointer is over the Mac picture, however the camera moves.
enum PointerFollowStyle: String, CaseIterable, Identifiable {
    /// The picture eases after the pointer once it nears an edge (a short no-bounce spring).
    case smooth
    /// The picture moves in lockstep with the finger once the pointer reaches an edge; nothing
    /// moves after the finger stops.
    case rigid
    /// No automatic panning; two-finger pan and the mini map only.
    case off

    static let key = "pointerFollow"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .smooth: "Smooth"
        case .rigid: "Rigid"
        case .off: "Off"
        }
    }

    var follows: Bool { self != .off }

    /// Distance from the usable edge at which panning starts. Smooth needs room for the pointer
    /// to lead the eased picture during a fast stroke without leaving the screen.
    var margin: CGFloat {
        switch self {
        case .smooth: 48
        case .rigid: 32
        case .off: 0
        }
    }

    func animation(reduceMotion: Bool) -> Animation? {
        guard self == .smooth, !reduceMotion else { return nil }
        return .smooth(duration: 0.22, extraBounce: 0)
    }
}

/// Owns the predicted pointer and publishes only what the overlay draws, so pointer motion
/// never invalidates the rest of the session view.
@MainActor
final class PointerOverlayModel: ObservableObject {
    struct Render: Equatable {
        var point: CGPoint
        var shape: PointerShape
    }

    static let followInterval: TimeInterval = 1.0 / 120.0
    /// ProMotion is asked for while the pointer moves or a correction is blending, and released when idle.
    static let frameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    static let motionLinger: TimeInterval = 0.25

    @Published private(set) var render: Render?
    let followUpdates = PassthroughSubject<CGPoint, Never>()
    private(set) var predictor = PointerPredictor(bounds: .zero)
    private(set) var policy = PointerOverlayPolicy()
    private(set) var displayLink: CADisplayLink?
    private var lastFollowAt: TimeInterval = -.infinity
    private let clock: () -> TimeInterval
    #if DEBUG
    private var previewRender: Render?
    #endif

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    var hostSupported: Bool { policy.hostSupported }

    /// New session or geometry epoch: the host restarts its sample counter and move ordinals.
    func reset(sourceSize: CGSize) {
        predictor.reset(bounds: sourceSize)
        policy.reset()
        lastFollowAt = -.infinity
        refresh()
    }

    func hostCapability(_ sync: PointerSync?) {
        policy.hostCapability(sync, at: clock())
        refresh()
    }

    func receive(_ sync: PointerSync) {
        let now = clock()
        guard policy.telemetry(sync, at: now) else { return }
        if let x = sync.x, let y = sync.y {
            predictor.receive(point: CGPoint(x: x, y: y), applied: sync.applied, at: now)
        }
        refresh()
    }

    /// An ordinal to tag the next move with, or nil for a legacy host.
    func reserveMoveOrdinal() -> UInt64? {
        policy.hostSupported ? predictor.reserveOrdinal() : nil
    }

    /// Moves the drawn pointer the instant the control channel accepts the delta.
    func localMove(ordinal: UInt64?, delta: CGSize, follow: Bool) {
        guard let ordinal else { return }
        let now = clock()
        predictor.applyLocalMove(ordinal: ordinal, delta: delta, at: now)
        refresh()
        guard follow, let point = predictor.displayed(at: now),
              now < lastFollowAt || now - lastFollowAt >= Self.followInterval else { return }
        lastFollowAt = now
        followUpdates.send(point)
    }

    /// Jumps the drawn pointer to an absolute placement (direct touch or a hardware pointer).
    /// The finger or the iPad pointer is already there, so the camera never follows it.
    func localWarp(ordinal: UInt64?, to point: CGPoint) {
        guard let ordinal else { return }
        predictor.applyLocalWarp(ordinal: ordinal, to: point)
        refresh()
    }

    func advertisement() -> PointerSync? { policy.advertisement(at: clock()) }

    /// The predicted Mac pointer position in source coordinates, drawn or not.
    var displayedPoint: CGPoint? { predictor.displayed(at: clock()) }

    func refresh() {
        #if DEBUG
        if let previewRender {
            if render != previewRender { render = previewRender }
            return
        }
        #endif
        let now = clock()
        let point = predictor.displayed(at: now)
        let next = policy.shouldDraw(at: now, hasPosition: point != nil)
            ? point.map { Render(point: $0, shape: policy.shape) } : nil
        if next != render { render = next }
        let moving = now >= predictor.lastLocalMoveAt && now - predictor.lastLocalMoveAt < Self.motionLinger
        setDisplayLink(active: next != nil && (moving || predictor.correcting(at: now)))
    }

    private func setDisplayLink(active: Bool) {
        if active, displayLink == nil {
            let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in
                                         guard let self else { return false }
                                         self.refresh()
                                         return true
                                     }, selector: #selector(DisplayLinkTarget.step(_:)))
            link.preferredFrameRateRange = Self.frameRateRange
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !active, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    #if DEBUG
    /// Offline layout checks draw a representative pointer without a Mac.
    func showPreview(_ render: Render?) {
        previewRender = render
        self.render = render
    }
    #endif
}

/// The display link retains its target; the target only weakly reaches the model and
/// stops the link if the model is gone.
private final class DisplayLinkTarget: NSObject {
    let action: () -> Bool
    init(_ action: @escaping () -> Bool) { self.action = action }
    @objc func step(_ link: CADisplayLink) {
        if !action() { link.invalidate() }
    }
}

/// Precomputed placement of a glyph so the hot spot lands exactly on the mapped point.
struct PointerGlyphMetrics {
    static let shadowPadding: CGFloat = 4

    let glyph: PointerGlyph
    let scale: CGFloat
    let canvasSize: CGSize
    let hotSpot: CGPoint

    init(shape: PointerShape, arrowHeight: CGFloat) {
        glyph = PointerGlyph.glyph(for: shape)
        scale = arrowHeight / PointerGlyph.nominalHeight
        let bounds = glyph.bounds
        let pad = Self.shadowPadding
        canvasSize = CGSize(width: bounds.width * scale + pad * 2, height: bounds.height * scale + pad * 2)
        hotSpot = CGPoint(x: -bounds.minX * scale + pad, y: -bounds.minY * scale + pad)
    }

    @MainActor private static var cache: [String: PointerGlyphMetrics] = [:]

    @MainActor static func cached(shape: PointerShape, arrowHeight: CGFloat) -> PointerGlyphMetrics {
        let key = "\(shape.rawValue)@\(arrowHeight)"
        if let metrics = cache[key] { return metrics }
        let metrics = PointerGlyphMetrics(shape: shape, arrowHeight: arrowHeight)
        cache[key] = metrics
        return metrics
    }

    /// The SwiftUI `position` (view centre) that puts the hot spot at `point`.
    func center(forHotSpotAt point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - hotSpot.x + canvasSize.width / 2, y: point.y - hotSpot.y + canvasSize.height / 2)
    }
}

/// Draws the pointer inside the picture's placement: positions are picture points (source × scale),
/// so an eased camera pan moves picture and pointer as one. A move of the pointer itself never
/// carries the camera's animation, or SwiftUI's additive position animation would accumulate every
/// pan step into the glyph and push it off screen while the finger leads the picture.
struct PointerOverlayView: View {
    @ObservedObject var model: PointerOverlayModel
    let viewport: ViewportTransform
    let size: PointerSizePreference

    var body: some View {
        if let render = model.render {
            let mapped = viewport.viewPoint(fromSource: render.point)
            let limit = size.arrowHeight * 2
            if mapped.x >= -limit, mapped.y >= -limit,
               mapped.x <= viewport.canvasSize.width + limit, mapped.y <= viewport.canvasSize.height + limit {
                let metrics = PointerGlyphMetrics.cached(shape: render.shape, arrowHeight: size.arrowHeight)
                PointerGlyphView(shape: render.shape, arrowHeight: size.arrowHeight)
                    .position(metrics.center(forHotSpotAt: Self.picturePoint(render.point, scale: viewport.scale)))
                    .transaction(value: render.point) { $0.disablesAnimations = true }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// A source point in the picture container's coordinates.
    static func picturePoint(_ source: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: source.x * scale, y: source.y * scale)
    }
}

struct PointerGlyphView: View {
    let shape: PointerShape
    let arrowHeight: CGFloat

    var body: some View {
        let metrics = PointerGlyphMetrics.cached(shape: shape, arrowHeight: arrowHeight)
        Canvas { context, _ in
            context.translateBy(x: metrics.hotSpot.x, y: metrics.hotSpot.y)
            context.scaleBy(x: metrics.scale, y: metrics.scale)
            Self.draw(metrics.glyph, in: context)
        }
        .frame(width: metrics.canvasSize.width, height: metrics.canvasSize.height)
        .shadow(color: .black.opacity(0.38), radius: max(1, arrowHeight / 26), y: max(0.6, arrowHeight / 40))
    }

    /// SwiftUI mirror of `PointerGlyphRenderer`: every layer's outlines, then its bodies and details.
    private static func draw(_ glyph: PointerGlyph, in context: GraphicsContext) {
        for layer in glyph.layers {
            for part in layer.parts {
                let path = Path(part.path)
                let width: CGFloat
                switch part.kind {
                case .fill: width = glyph.outline * 2
                case .stroke(let line): width = line + glyph.outline * 2
                }
                context.stroke(path, with: .color(color(part.tone.outline)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            for part in layer.parts + layer.details {
                let path = Path(part.path)
                switch part.kind {
                case .fill:
                    context.fill(path, with: .color(color(part.tone.body)))
                case .stroke(let line):
                    context.stroke(path, with: .color(color(part.tone.body)),
                                   style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private static func color(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Color {
        Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }
}

#if DEBUG
/// Offline visual check of every glyph at the chosen size (`--ui-pointer-gallery`).
struct PointerGlyphGallery: View {
    let size: PointerSizePreference

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(PointerShape.allCases, id: \.self) { shape in
                PointerGlyphView(shape: shape, arrowHeight: size.arrowHeight)
                    .frame(maxWidth: .infinity, minHeight: size.arrowHeight * 1.6)
                    .background(shape.rawValue.count.isMultiple(of: 2) ? Color.white : Color(white: 0.2))
            }
        }
        .padding(16)
        .allowsHitTesting(false)
        .accessibilityIdentifier("remote.pointerGallery")
    }
}
#endif
