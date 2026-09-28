import Foundation

enum StreamQuality: String, Codable, CaseIterable {
    case balanced
    case sharp

    var title: String { self == .sharp ? "Sharper" : "Responsive" }
    var maximumDimension: Int { self == .sharp ? 3840 : 1920 }
}
