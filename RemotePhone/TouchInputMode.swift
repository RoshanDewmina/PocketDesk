import Foundation

/// How one-finger touches drive the Mac pointer while controlling. View mode (local pan and
/// zoom) is separate and unchanged by this choice.
enum TouchInputMode: String, CaseIterable, Identifiable {
    /// The screen is a trackpad: the pointer moves relative to the finger. Precise on small targets.
    case trackpad
    /// The pointer goes where you touch: tap clicks there, drag click-drags from there.
    case direct

    static let key = "touchInputMode"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .trackpad: "Trackpad"
        case .direct: "Direct"
        }
    }
}
