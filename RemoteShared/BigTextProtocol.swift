import Foundation

enum BigTextLimits {
    static let maxSteps = 4
    static let widthRange: ClosedRange<Double> = 1...20_000
}

struct ScaleStep: Codable, Equatable {
    var width: Double
    var height: Double

    func validate(below baselineWidth: Double) throws {
        guard width.isFinite, height.isFinite, BigTextLimits.widthRange.contains(width),
              BigTextLimits.widthRange.contains(height), width < baselineWidth else { throw RemoteError.invalidMessage }
    }
}

enum BigTextError: String, Codable, CaseIterable {
    case noAccessibility, unsupported, disabled, busy, failed
}

extension DisplayDescriptor {
    func validateScale() throws {
        guard scaleSteps != nil || scaleBaselineWidth != nil || scaleCurrentWidth != nil else { return }
        guard let baseline = scaleBaselineWidth, baseline.isFinite, BigTextLimits.widthRange.contains(baseline),
              let steps = scaleSteps, steps.count <= BigTextLimits.maxSteps else { throw RemoteError.invalidMessage }
        try steps.forEach { try $0.validate(below: baseline) }
        if let current = scaleCurrentWidth, current != baseline, !steps.contains(where: { $0.width == current }) {
            throw RemoteError.invalidMessage
        }
    }
}
