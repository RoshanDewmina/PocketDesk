import CoreGraphics

struct DisplayModeInfo: Equatable {
    let ioModeID: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let usableForDesktopGUI: Bool

    var isHiDPI: Bool { pixelWidth == width * 2 && pixelHeight == height * 2 }
    var aspect: Double { Double(width) / Double(height) }
    var step: ScaleStep { ScaleStep(width: Double(width), height: Double(height)) }
}

enum BigTextSteps {
    static let nearestTolerance = 0.10
    static func steps(baseline: DisplayModeInfo, modes: [DisplayModeInfo]) -> [DisplayModeInfo] { [] }
    static func spread<T>(_ items: [T], count: Int) -> [T] { [] }
    static func nearest(to width: Double, in steps: [DisplayModeInfo]) -> DisplayModeInfo? { nil }
}
