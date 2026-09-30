import Foundation

enum BigTextLimits {
    static let maxSteps = 4
    static let widthRange: ClosedRange<Double> = 1...20_000
}

struct ScaleStep: Codable, Equatable {
    var width: Double
    var height: Double

    func validate(below baselineWidth: Double) throws {}
}

enum BigTextError: String, Codable, CaseIterable {
    case noAccessibility, unsupported, disabled, busy, failed
}
