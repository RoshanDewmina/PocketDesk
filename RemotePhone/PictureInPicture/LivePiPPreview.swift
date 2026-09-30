import SwiftUI
import AVFoundation

/// A visible, accessible preroll surface for the real public sample-buffer PiP source.
struct LivePiPPreview: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer?
    final class Preview: UIView {
        weak var sampleLayer: AVSampleBufferDisplayLayer?
        func attach(_ next: AVSampleBufferDisplayLayer?) {
            guard sampleLayer !== next else { return }
            sampleLayer?.removeFromSuperlayer(); sampleLayer = next
            if let next { layer.addSublayer(next) }; setNeedsLayout()
        }
        override func layoutSubviews() { super.layoutSubviews(); sampleLayer?.frame = bounds }
    }
    func makeUIView(context: Context) -> Preview { let view = Preview(); view.backgroundColor = .black; view.attach(layer); return view }
    func updateUIView(_ view: Preview, context: Context) { view.attach(layer) }
    static func dismantleUIView(_ view: Preview, coordinator: ()) { view.attach(nil) }
}
