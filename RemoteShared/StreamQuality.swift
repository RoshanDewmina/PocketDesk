import Foundation

enum StreamQuality: String, Codable, CaseIterable {
    case balanced
    case sharp

    var title: String { self == .sharp ? "Sharper" : "Responsive" }
    var maximumDimension: Int { maximumDimension(at: 60) }

    /// Long-edge cap by frame rate. Above 60 fps the encoder budget, about 2.3 ms per megapixel on
    /// an M4, allows roughly 3 MP per frame, so the caps drop to 2048 (2.7 MP) and 1600 (1.7 MP).
    func maximumDimension(at fps: Int) -> Int {
        switch (self, fps > 60) {
        case (.sharp, false): return 2560
        case (.sharp, true): return 2048
        case (.balanced, false): return 1920
        case (.balanced, true): return 1600
        }
    }
}
