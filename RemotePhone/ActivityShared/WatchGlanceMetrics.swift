import CoreGraphics

enum WatchGlanceMetrics {
    struct Surface: Equatable {
        let name: String
        let size: CGSize
    }

    static let titleSize: CGFloat = 15
    static let detailSize: CGFloat = 13
    static let noteSize: CGFloat = 12
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 6
    static let glyphHeight: CGFloat = 13
    static let glyphSpacing: CGFloat = 5
    static let lineSpacing: CGFloat = 2
    static let titleMinimumScale: CGFloat = 0.7
    static let lineMinimumScale: CGFloat = 0.85

    static var ringDiameter: CGFloat { glyphHeight + 6 }

    static let watchSurfaces: [Surface] = [
        Surface(name: "watch-40mm", size: CGSize(width: 152, height: 69.5)),
        Surface(name: "watch-41mm", size: CGSize(width: 165, height: 72.5)),
        Surface(name: "watch-44mm", size: CGSize(width: 173, height: 76.5)),
        Surface(name: "watch-45mm", size: CGSize(width: 184, height: 80.5)),
        Surface(name: "watch-49mm", size: CGSize(width: 191, height: 81.5)),
    ]
    static let carPlaySurfaces: [Surface] = [
        Surface(name: "carplay-170x78", size: CGSize(width: 170, height: 78)),
        Surface(name: "carplay-240x78", size: CGSize(width: 240, height: 78)),
        Surface(name: "carplay-240x100", size: CGSize(width: 240, height: 100)),
    ]
    static var allSurfaces: [Surface] { watchSurfaces + carPlaySurfaces }

    static func lineWidth(in size: CGSize) -> CGFloat { size.width - 2 * horizontalPadding }

    /// The glyph column is reserved at ring width for both marks, so a title never shifts when the ring appears.
    static func titleWidth(in size: CGSize) -> CGFloat { lineWidth(in: size) - ringDiameter - glyphSpacing }
}
