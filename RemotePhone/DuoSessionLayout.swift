import SwiftUI
import UIKit

/// Window-local Duo facts. No display/device-name guesses, hinge-angle thresholds or session changes.
/// The iPad lane owns the ordinary size-class/coverage layout; this seam only overrides a real fold.
struct DuoSessionLayout: Equatable {
    enum Posture: String { case unavailable, folded, unfolded, partiallyOpen }
    enum Axis: Equatable { case horizontal, vertical }
    struct Division: Equatable {
        let axis: Axis
        let picture: CGRect
        let trackpad: CGRect
        let hinge: CGRect
    }

    static let disabledKey = "disableDuoSessionLayout"
    var posture: Posture = .unavailable
    var bounds: CGRect = .zero
    var divisions: [CGRect] = []
    var occlusions: [CGRect] = []
    var orientation = "unknown"

    /// A split window wholly on one side of the hinge retains the ordinary window layout.
    /// Reserved frames already include Apple's interactive margins; never add them twice.
    var division: Division? {
        guard posture == .partiallyOpen, Self.valid(bounds), divisions.count == 1 else { return nil }
        let hinge = divisions[0].intersection(bounds)
        guard Self.valid(hinge) else { return nil }
        if hinge.width > hinge.height {
            guard hinge.minY > bounds.minY, hinge.maxY < bounds.maxY else { return nil }
            return Division(axis: .vertical,
                picture: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: hinge.minY - bounds.minY),
                trackpad: CGRect(x: bounds.minX, y: hinge.maxY, width: bounds.width, height: bounds.maxY - hinge.maxY), hinge: hinge)
        }
        guard hinge.minX > bounds.minX, hinge.maxX < bounds.maxX else { return nil }
        return Division(axis: .horizontal,
            picture: CGRect(x: bounds.minX, y: bounds.minY, width: hinge.minX - bounds.minX, height: bounds.height),
            trackpad: CGRect(x: hinge.maxX, y: bounds.minY, width: bounds.maxX - hinge.maxX, height: bounds.height), hinge: hinge)
    }

    func stacked(ordinary: Bool) -> Bool {
        if posture == .folded { return false }
        return division != nil || ordinary
    }

    var reservedFrames: [CGRect] {
        (occlusions + divisions).compactMap { rect in
            guard Self.valid(rect), Self.valid(bounds) else { return nil }
            let clipped = rect.intersection(bounds)
            return Self.valid(clipped) ? clipped : nil
        }
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite &&
        rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }
}

/// Attach to the stable session stage, at its full bounds, before laying out picture and pad.
/// Publishing is deferred/coalesced so UIKit callbacks never mutate SwiftUI during a layout pass.
struct DuoSessionProbe: UIViewRepresentable {
    private static let layoutEnabled = !UserDefaults.standard.bool(forKey: DuoSessionLayout.disabledKey)
    var enabled = true
    let update: (DuoSessionLayout) -> Void

    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ view: ProbeView, context: Context) {
        view.onUpdate = update
        view.enabled = enabled && Self.layoutEnabled
        view.refresh()
    }
    static func dismantleUIView(_ view: ProbeView, coordinator: ()) {
        view.onUpdate = nil
        view.stopObservingScene()
    }

    final class ProbeView: UIView {
        var onUpdate: ((DuoSessionLayout) -> Void)?
        var enabled = true
        private var last: DuoSessionLayout?
        private var pending = false
        private weak var observedScene: UIWindowScene?
        private var geometryObservation: NSKeyValueObservation?
        #if FARSIDE_DUO_SDK
        private var hingeInteraction: UIInteraction?
        private var posture: DuoSessionLayout.Posture = .unavailable
        #endif

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            backgroundColor = .clear
            #if FARSIDE_DUO_SDK
            if #available(iOS 27.1, *) {
                let interaction = UIHingeInteraction { [weak self] _, update in
                    guard let self else { return }
                    switch update.hinge?.status {
                    case .closed: self.posture = .folded
                    case .fullyOpen: self.posture = .unfolded
                    case .partiallyOpen: self.posture = .partiallyOpen
                    default: self.posture = .unavailable
                    }
                    self.refresh()
                }
                hingeInteraction = interaction
                addInteraction(interaction)
            }
            #endif
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); refresh() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); refresh() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let scene = window?.windowScene
            if scene !== observedScene {
                stopObservingScene()
                observedScene = scene
                // A flip between landscape sides can keep bounds and safe-area insets
                // unchanged. Observe the authoritative scene geometry as well as layout.
                geometryObservation = scene?.observe(\.effectiveGeometry) { [weak self] _, _ in
                    DispatchQueue.main.async { [weak self] in self?.refresh() }
                }
            }
            refresh()
        }

        func stopObservingScene() {
            geometryObservation?.invalidate()
            geometryObservation = nil
            observedScene = nil
        }

        func refresh() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                var state = DuoSessionLayout(bounds: self.bounds)
                switch self.window?.windowScene?.effectiveGeometry.interfaceOrientation {
                case .portrait: state.orientation = "portrait"
                case .portraitUpsideDown: state.orientation = "portraitUpsideDown"
                case .landscapeLeft: state.orientation = "landscapeLeft"
                case .landscapeRight: state.orientation = "landscapeRight"
                default: break
                }
                #if FARSIDE_DUO_SDK
                if #available(iOS 27.1, *), self.enabled, self.window != nil {
                    state.posture = self.posture
                    state.divisions = self.reservedRegions(kind: .division).filter(\.isActive).map(\.frame)
                    state.occlusions = self.reservedRegions(kind: .occlusion).filter(\.isActive).map(\.frame)
                }
                #endif
                guard state != self.last, let update = self.onUpdate else { return }
                self.last = state
                update(state)
            }
        }
    }
}

/// A transparent hit-test shield only over system-reserved regions, including hinge margins.
/// The rest of the canvas and each chrome control remain separately reachable.
struct DuoReservedRegionShield: UIViewRepresentable {
    let layout: DuoSessionLayout
    func makeUIView(context: Context) -> ShieldView { ShieldView() }
    func updateUIView(_ view: ShieldView, context: Context) { view.regions = layout.reservedFrames }
    final class ShieldView: UIView {
        var regions: [CGRect] = []
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            regions.contains { $0.contains(point) }
        }
    }
}
