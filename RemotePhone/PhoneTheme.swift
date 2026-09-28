import SwiftUI
import UIKit

/// Apple-native surfaces with a faint Paperwash warmth. Text and controls use system
/// colors and materials; the warm paper tone and sage/sand/clay only carry meaning.
enum PhoneTheme {
    static let background = dynamic(light: 0xF7F5F0, dark: 0x0F0F0E)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x1D1C1A)
    static let tint = dynamic(light: 0x2F5E9A, dark: 0x8FB5EA)
    static let ready = dynamic(light: 0x4A8558, dark: 0x8FC79B)
    static let busy = dynamic(light: 0xA9822F, dark: 0xE2CB8E)
    static let caution = dynamic(light: 0xB0603C, dark: 0xE8AB8F)
    static let letterbox = Color.black

    static let titleFont = Font.system(.largeTitle, design: .serif, weight: .semibold)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 255) / 255,
                  green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

/// A small status dot whose meaning is always repeated in adjacent text.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}
