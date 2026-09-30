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

    static let watchSurfaces: [Surface] = []
    static let carPlaySurfaces: [Surface] = []
    static var allSurfaces: [Surface] { watchSurfaces + carPlaySurfaces }

    static func lineWidth(in size: CGSize) -> CGFloat { 0 }
    static func titleWidth(in size: CGSize) -> CGFloat { 0 }
}
