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

    static func steps(baseline: DisplayModeInfo, modes: [DisplayModeInfo]) -> [DisplayModeInfo] {
        var seen = Set<[Int]>()
        let candidates = modes
            .filter { $0.usableForDesktopGUI && $0.isHiDPI && $0.width < baseline.width }
            .filter { abs($0.aspect - baseline.aspect) <= baseline.aspect * 0.005 }
            .filter { abs($0.refreshRate - baseline.refreshRate) < 0.5 }
            .sorted { $0.width > $1.width }
            .filter { seen.insert([$0.width, $0.height]).inserted }
        return spread(candidates, count: BigTextLimits.maxSteps)
    }

    static func spread<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count, count > 1 else { return Array(items.prefix(count)) }
        let last = items.count - 1
        return (0..<count).map { items[Int((Double($0) * Double(last) / Double(count - 1)).rounded())] }
    }

    static func nearest(to width: Double, in steps: [DisplayModeInfo]) -> DisplayModeInfo? {
        guard width > 0, let best = steps.min(by: { abs(Double($0.width) - width) < abs(Double($1.width) - width) })
        else { return nil }
        return abs(Double(best.width) - width) <= width * nearestTolerance ? best : nil
    }
}
