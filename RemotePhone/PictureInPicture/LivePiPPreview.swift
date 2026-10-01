import SwiftUI
import AVFoundation

/// A visible, accessible preroll surface for the real public sample-buffer PiP source. `inline` is the
/// session's own copy behind the picture (auto-start needs the content inline); a sheet preview borrows the
/// one layer while shown and hands it back to the inline host when dismantled.
struct LivePiPPreview: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer?
    var inline = false
    final class Preview: UIView {
        weak var sampleLayer: AVSampleBufferDisplayLayer?
        static weak var inlineHost: Preview?
        func attach(_ next: AVSampleBufferDisplayLayer?) {
            if let old = sampleLayer, old !== next, old.superlayer === layer {
                old.removeFromSuperlayer()
                if Self.inlineHost !== self, let host = Self.inlineHost, host.sampleLayer === old { host.layer.addSublayer(old); host.setNeedsLayout() }
            }
            sampleLayer = next
            if let next, next.superlayer !== layer { layer.addSublayer(next) }
            setNeedsLayout()
        }
        override func layoutSubviews() { super.layoutSubviews(); if sampleLayer?.superlayer === layer { sampleLayer?.frame = bounds } }
    }
    func makeUIView(context: Context) -> Preview {
        let view = Preview(); view.backgroundColor = .black
        if inline { Preview.inlineHost = view }
        view.attach(layer); return view
    }
    func updateUIView(_ view: Preview, context: Context) { view.attach(layer) }
    static func dismantleUIView(_ view: Preview, coordinator: ()) { view.attach(nil) }
}
