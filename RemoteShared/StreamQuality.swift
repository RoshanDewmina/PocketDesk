import Foundation

enum StreamQuality: String, Codable, CaseIterable {
    case balanced
    case sharp

    var title: String { self == .sharp ? "Sharper" : "Responsive" }
    var maximumDimension: Int { self == .sharp ? 2560 : 1920 }
}
