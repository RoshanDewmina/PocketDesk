import SwiftUI

/// Farside "Reach" design tokens. Source of truth: design/FARSIDE-DESIGN-SYSTEM.md.
/// Dark only for 1.0. Ember is reserved for contact: live, click, stop.
enum Farside {
    enum Palette {
        static let void = rgb(0x050505)
        static let void2 = rgb(0x0B0B0B)
        static let panel = rgb(0x121212)
        static let panel2 = rgb(0x191919)
        static let bone = rgb(0xEDE8DF)
        static let ash = rgb(0x8C877F)
        static let dim = rgb(0x4A4742)
        static let line = rgb(0xEDE8DF, opacity: 0.12)
        static let line2 = rgb(0xEDE8DF, opacity: 0.22)
        static let ember = rgb(0xFF5B1F)
        static let emberDeep = rgb(0xC23D0E)

        private static func rgb(_ hex: UInt32, opacity: Double = 1) -> Color {
            Color(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
        }
    }

    /// Bundled accent faces (SIL OFL 1.1). Everyday UI uses the system font.
    /// If a face is not bundled, SwiftUI falls back to the system font.
    enum Typeface {
        static let dotMatrix = "Doto"
        static let serifItalic = "InstrumentSerif-Italic"

        /// Dot-matrix display text, 28 pt and larger. Keep punctuation out of Doto strings.
        static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
            .custom(dotMatrix, size: size, relativeTo: style).weight(.heavy)
        }

        /// The single italic accent word in a heading.
        static func accent(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
            .custom(serifItalic, size: size, relativeTo: style)
        }

        /// Captions, latencies and technical readouts.
        static func caption(_ style: Font.TextStyle = .caption) -> Font {
            .system(style, design: .monospaced)
        }
    }

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let control: CGFloat = 12
        static let card: CGFloat = 20
        static let sheet: CGFloat = 28
        static let pill: CGFloat = 999
    }

    enum Motion {
        static let micro: Double = 0.14
        static let standard: Double = 0.32
        static let entrance: Double = 0.8

        /// cubic-bezier(.16, 1, .3, 1)
        static func easeOut(_ duration: Double = standard) -> Animation {
            .timingCurve(0.16, 1, 0.3, 1, duration: duration)
        }

        /// cubic-bezier(.22, 1, .36, 1)
        static func reveal(_ duration: Double = entrance) -> Animation {
            .timingCurve(0.22, 1, 0.36, 1, duration: duration)
        }
    }
}
