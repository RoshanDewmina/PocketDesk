import CoreImage
import CoreVideo
import ImageIO
import SwiftUI
import UIKit

/// One foreground still image. It owns no track, decoder, PiP, audio, feedback or input authority.
@MainActor
final class VirtualDisplayRotationHold: ObservableObject {
    @Published private(set) var image: UIImage?
    private(set) var policy = VirtualDisplayRotationPolicy()
    private var cached: VideoPresentedSource?
    private var expiry: Timer?
    private lazy var context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private weak var mountedView: UIImageView?
    var onChange: (() -> Void)?
    var isHolding: Bool { policy.isHolding }

    func record(_ source: VideoPresentedSource, admission: VideoPresentationAdmission, scope: UInt64,
                display: UInt32, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        expire(at: now)
        guard admission.permits(at: now), source.lifetime === admission.lifetime, source.lifetime.isActive,
              source.envelope.identity == admission.identity,
              let proof = source.rotationProof, proof.tagGeometry == admission.identity.geometryEpoch,
              proof.tagScope == scope, display > 0 else { return }
        if policy.presented(proof, current: admission.identity, scope: scope, display: display, now: now) {
            removeImage(); onChange?()
        }
        // Only one exact presented original source is retained; no per-frame image conversion.
        cached = source
    }
    func begin(_ request: VirtualDisplayResizeBegin, admission: VideoPresentationAdmission, scope: UInt64,
               display: UInt32, routeDeadline: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard admission.permits(at: now), let cached, cached.lifetime === admission.lifetime, cached.lifetime.isActive,
              let proof = cached.rotationProof,
              policy.start(request, frame: proof, current: admission.identity, scope: scope, display: display,
                           routeDeadline: routeDeadline, now: now) else { return false }
        guard let snapshot = makeImage(cached), cached.lifetime === admission.lifetime, cached.lifetime.isActive,
              admission.permits(at: ProcessInfo.processInfo.systemUptime),
              policy.active(at: ProcessInfo.processInfo.systemUptime) else { clear(); return false }
        self.cached = nil
        image = snapshot
        // Install synchronously when mounted; clearing the old live surface never waits for SwiftUI.
        mountedView?.image = snapshot; mountedView?.isHidden = false
        expiry?.invalidate()
        let timer = Timer(timeInterval: max(0.001, (policy.deadline ?? now) - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }
        expiry = timer; RunLoop.main.add(timer, forMode: .common)
        onChange?(); return true
    }
    func bind(token: String?, epoch: UInt64, scope: UInt64, display: UInt32, current: VideoPresentationIdentity,
              now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let accepted = policy.bind(token: token, epoch: epoch, scope: scope, display: display, current: current, now: now)
        if !accepted { clear() }
        return accepted
    }
    func cancel(token: String?) {
        guard token == policy.begin?.token else { return }; clear()
    }
    func expire(at now: TimeInterval) {
        if policy.expire(at: now) { removeImage(); cached = nil; onChange?() }
    }
    func clear() {
        guard isHolding || cached != nil || image != nil || expiry != nil else { return }
        policy.clear(); cached = nil; removeImage(); onChange?()
    }
    private func removeImage() {
        expiry?.invalidate(); expiry = nil
        // All terminal paths hide and drop UIKit pixels before publishing/removal callbacks.
        mountedView?.isHidden = true; mountedView?.image = nil
        image = nil
    }
    func mount(_ view: UIImageView) {
        mountedView = view; view.image = image; view.isHidden = image == nil
        view.isUserInteractionEnabled = false; view.accessibilityElementsHidden = true
    }
    private func makeImage(_ source: VideoPresentedSource) -> UIImage? {
        guard let pixels = source.envelope.pixels, let geometry = source.envelope.geometry,
              geometry.displaySize.width * geometry.displaySize.height <= CGFloat(VirtualDisplaySpecification.maximumPixels),
              let inputSpace = CGColorSpace(name: pixels.transfer == .srgb ? CGColorSpace.sRGB : CGColorSpace.itur_709),
              let outputSpace = CGColorSpace(name: CGColorSpace.itur_709) else { return nil }
        let height = CGFloat(CVPixelBufferGetHeight(pixels.buffer))
        var picture = CIImage(cvPixelBuffer: pixels.buffer, options: [.colorSpace: inputSpace])
        if let refinement = source.refinementPixels, let roi = source.envelope.videoTag?.refinement,
           let refinementSpace = CGColorSpace(name: roi.transfer == "srgb" ? CGColorSpace.sRGB : CGColorSpace.itur_709) {
            let overlay = CIImage(cvPixelBuffer: refinement, options: [.colorSpace: refinementSpace])
                .transformed(by: CGAffineTransform(translationX: CGFloat(roi.x), y: height - CGFloat(roi.y + roi.roiHeight)))
            picture = overlay.composited(over: picture)
        }
        let crop = CGRect(x: pixels.crop.minX, y: height - pixels.crop.maxY, width: pixels.crop.width, height: pixels.crop.height)
        picture = picture.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let orientation: CGImagePropertyOrientation
        switch geometry.rotation { case 90: orientation = .right; case 180: orientation = .down; case 270: orientation = .left; default: orientation = .up }
        picture = picture.oriented(orientation)
        guard let cg = context.createCGImage(picture, from: picture.extent, format: .BGRA8, colorSpace: outputSpace) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct VirtualDisplayRotationOverlay: UIViewRepresentable {
    @ObservedObject var owner: VirtualDisplayRotationHold
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(); view.contentMode = .scaleAspectFill; view.clipsToBounds = true
        owner.mount(view); return view
    }
    func updateUIView(_ view: UIImageView, context: Context) { owner.mount(view) }
    static func dismantleUIView(_ view: UIImageView, coordinator: ()) { view.isHidden = true; view.image = nil }
}
