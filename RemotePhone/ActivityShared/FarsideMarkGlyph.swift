import SwiftUI

/// The Farside pointer with its tip: the mark, small enough for the compact island. The Watch glance
/// draws the tip in bone, because a Watch face may tint colour and needs-you is not contact.
struct FarsideMarkGlyph: View {
    var height: CGFloat = 16
    var tip: Color = Farside.Palette.ember

    private struct Pointer: Shape {
        func path(in rect: CGRect) -> Path {
            let points: [CGPoint] = [.init(x: 0, y: 0), .init(x: 0, y: 250), .init(x: 60, y: 196), .init(x: 98, y: 284),
                                     .init(x: 134, y: 268), .init(x: 96, y: 180), .init(x: 176, y: 180)]
            var path = Path()
            let scale = rect.height / 284
            path.addLines(points.map { CGPoint(x: rect.minX + $0.x * scale, y: rect.minY + $0.y * scale) })
            path.closeSubpath()
            return path
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Pointer().fill(Farside.Palette.bone)
            Circle()
                .fill(tip)
                .frame(width: height * 0.3, height: height * 0.3)
                .offset(x: -height * 0.02, y: -height * 0.02)
        }
        .frame(width: height * 0.62, height: height)
        .accessibilityHidden(true)
    }
}
