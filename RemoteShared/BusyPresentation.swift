import Foundation

/// The words for a `BusyState`, shared by the phone's pill and the Mac's popover: what is slow and
/// what the stream is now ("Your Mac is busy", "30 fps at 1440 px · encoding"), never whose fault it is.
struct BusyPresentation: Equatable {
    var title: String
    var detail: String?
    var accessibilityLabel: String
    var symbol: String

    /// nil for `ok`. `device` is the phone's kind as its owner calls it, "iPhone" or "iPad".
    init?(_ state: BusyState, device: String = "iPhone") {
        guard state.isVisible else { return nil }
        let reason = LadderReason(rawValue: state.reason)
        let busy = state.level == .busy
        switch reason {
        case .thermal:
            title = "Your Mac is running warm"
            symbol = "thermometer.medium"
        case .network:
            title = busy ? "The connection is slow" : "The connection is a little slow"
            symbol = "wifi"
        case .phone:
            title = busy ? "Your \(device) is busy" : "Your \(device) is working hard"
            symbol = device.lowercased().hasPrefix("ipad") ? "ipad" : "iphone"
        case .encoding, .capture, nil:
            title = busy ? "Your Mac is busy" : "Your Mac is working hard"
            symbol = "laptopcomputer"
        }
        // The other reasons are already named by the title.
        let cause: String? = switch reason {
        case .encoding: "encoding"
        case .capture: "screen capture"
        default: nil
        }

        let rate = state.fps > 0 ? "\(state.fps) fps" : nil
        let size = state.longEdge > 0 ? "\(state.longEdge) px" : nil
        let picture = [rate, size].compactMap { $0 }.joined(separator: " at ")
        let line = [picture.isEmpty ? nil : picture, cause].compactMap { $0 }.joined(separator: " · ")
        detail = line.isEmpty ? nil : line

        let spokenRate = state.fps > 0 ? "\(state.fps) frames per second" : nil
        let spokenSize = state.longEdge > 0 ? "\(state.longEdge) pixels" : nil
        var spoken = [spokenRate, spokenSize].compactMap { $0 }.joined(separator: " at ")
        if let cause { spoken += spoken.isEmpty ? "Limited by \(cause)" : ", limited by \(cause)" }
        accessibilityLabel = spoken.isEmpty ? "\(title)." : "\(title). \(spoken)."
    }
}
