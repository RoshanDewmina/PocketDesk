import SwiftUI

/// Shared native palette. Warmth belongs to app chrome, never to the streamed pixels.
struct PocketDeskPalette {
    let paper: Color
    let surface: Color
    let raised: Color
    let ink: Color
    let muted: Color
    let line: Color
    let accent: Color
    let sage: Color
    let warning: Color

    static func resolve(_ scheme: ColorScheme) -> Self {
        if scheme == .dark {
            return Self(paper: color(0x1C1B19), surface: color(0x272622), raised: color(0x302E29),
                        ink: color(0xF5F3EB), muted: color(0xB8B5AA), line: color(0x48453D),
                        accent: color(0xA9C5EE), sage: color(0xA5C9AB), warning: color(0xE6BCA3))
        }
        return Self(paper: color(0xFAF9F5), surface: color(0xF1F0E8), raised: color(0xFDFCF8),
                    ink: color(0x141413), muted: color(0x66655E), line: color(0xDDDACE),
                    accent: color(0x365C88), sage: color(0x3D6749), warning: color(0x865238))
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }
}
