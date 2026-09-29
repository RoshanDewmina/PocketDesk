import SwiftUI
import WebRTC

/// A small overview of the whole Mac display with the part the viewport shows. Drag the
/// rectangle to pan; tap anywhere on it to jump there. Shown on iPad (and optionally on iPhone
/// in landscape) while part of the display is off screen; it fades when the view is still.
struct MiniMapView<Thumbnail: View>: View {
    let viewport: ViewportTransform
    /// The Mac pointer, in display points, drawn as a small bone dot so it is easy to find.
    let pointer: CGPoint?
    let maxSize: CGSize
    @ViewBuilder let thumbnail: (CGSize) -> Thumbnail
    let onPan: (CGSize) -> Void
    let onJump: (CGPoint) -> Void
    let onTouch: (Bool) -> Void
    let onShowAll: () -> Void

    @State private var lastDrag: CGPoint?

    var body: some View {
        if let layout = MiniMapLayout(sourceSize: viewport.sourceSize, fitting: maxSize) {
            let visible = layout.viewportRect(for: viewport.visibleSourceRect)
            ZStack(alignment: .topLeading) {
                thumbnail(layout.mapSize)
                    .frame(width: layout.mapSize.width, height: layout.mapSize.height, alignment: .topLeading)
                    .clipped()
                    .accessibilityHidden(true)
                // Everything off screen sits under a void veil; the visible part stays clear.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: layout.mapSize))
                    path.addRect(visible)
                }
                .fill(Farside.Palette.void.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                // Positioned (not offset), with its accessibility applied before placement, so
                // VoiceOver and tests see the outline where it is drawn.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Farside.Palette.bone, lineWidth: 1.5)
                    .frame(width: visible.width, height: visible.height)
                    .accessibilityElement()
                    .accessibilityIdentifier("remote.minimap.viewport")
                    .accessibilityLabel("Visible area")
                    .accessibilityValue(description(of: viewport.visibleSourceRect))
                    .position(x: visible.midX, y: visible.midY)
                    .allowsHitTesting(false)
                if let pointer {
                    let point = layout.mapPoint(forSourcePoint: pointer)
                    Circle()
                        .fill(Farside.Palette.bone)
                        .overlay(Circle().strokeBorder(Farside.Palette.void, lineWidth: 1))
                        .frame(width: 6, height: 6)
                        .position(point)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: layout.mapSize.width, height: layout.mapSize.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(.rect)
            .gesture(drag(layout: layout, visible: visible))
            .padding(6)
            .farsidePlate(Farside.Radius.control, fill: Farside.Palette.panel.opacity(0.95), stroke: Farside.Palette.line2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mini map")
            .accessibilityHint("Drag the outlined area to move the view, or tap to jump there.")
            .accessibilityIdentifier("remote.minimap")
            .accessibilityAction(named: Text("Move view left")) { step(-0.5, 0) }
            .accessibilityAction(named: Text("Move view right")) { step(0.5, 0) }
            .accessibilityAction(named: Text("Move view up")) { step(0, -0.5) }
            .accessibilityAction(named: Text("Move view down")) { step(0, 0.5) }
            .accessibilityAction(named: Text("Show the whole screen"), onShowAll)
        }
    }

    private func drag(layout: MiniMapLayout, visible: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if let lastDrag {
                    let delta = CGSize(width: value.location.x - lastDrag.x, height: value.location.y - lastDrag.y)
                    if delta != .zero { onPan(layout.canvasPan(forMapDrag: delta, viewportScale: viewport.scale)) }
                } else {
                    onTouch(true)
                    // Grab the rectangle where it is; anywhere else jumps there first.
                    if !visible.insetBy(dx: -8, dy: -8).contains(value.startLocation) {
                        onJump(layout.sourcePoint(forMapPoint: value.startLocation))
                    }
                }
                lastDrag = value.location
            }
            .onEnded { _ in
                lastDrag = nil
                onTouch(false)
            }
    }

    /// Moves the view by a fraction of what is visible, for VoiceOver.
    private func step(_ dx: CGFloat, _ dy: CGFloat) {
        let visible = viewport.visibleSourceRect
        onJump(CGPoint(x: visible.midX + visible.width * dx, y: visible.midY + visible.height * dy))
    }

    private func description(of visible: CGRect) -> String {
        let size = viewport.sourceSize
        guard size.width > 0, size.height > 0, visible.width > 0 else { return "Nothing visible" }
        let share = Int((visible.width * visible.height / (size.width * size.height) * 100).rounded())
        let across = Int((visible.midX / size.width * 100).rounded())
        let down = Int((visible.midY / size.height * 100).rounded())
        return "\(share) percent of the screen, centred \(across) percent across and \(down) percent down"
    }
}

/// Re-renders only the mini map as the drawn pointer moves, never the whole session.
struct MiniMapPointerSource<Content: View>: View {
    @ObservedObject var model: PointerOverlayModel
    @ViewBuilder let content: (CGPoint?) -> Content

    var body: some View { content(model.render?.point) }
}

/// The live picture at mini map size: a second renderer on the same track, present only while
/// the mini map is on screen.
struct MiniMapVideo: UIViewRepresentable {
    let track: RTCVideoTrack

    final class Coordinator { var track: RTCVideoTrack? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFit
        view.isUserInteractionEnabled = false
        track.add(view)
        context.coordinator.track = track
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        guard context.coordinator.track !== track else { return }
        context.coordinator.track?.remove(view)
        track.add(view)
        context.coordinator.track = track
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
        coordinator.track = nil
    }
}
