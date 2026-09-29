import SwiftUI
import AppKit
import CoreText
import CoreImage.CIFilterBuiltins

/// Host-only additions to the shared Farside tokens in RemoteShared/FarsideTheme.swift.
enum HostTheme {
    static let popoverWidth: CGFloat = 360
    static let setupSize = CGSize(width: 800, height: 520)
    static let railWidth: CGFloat = 280
    static let settingsWidth: CGFloat = 480

    /// Reach's popover and setup-window grounds; one step up from the void so the dots read.
    static let popoverBackground = gray(0x16)
    static let windowBackground = gray(0x10)
    static let railBackground = Color.black
    /// Text and knobs drawn on bone or ember.
    static let ink = gray(0x0A)

    private static func gray(_ value: UInt8) -> Color {
        Color(red: Double(value) / 255, green: Double(value) / 255, blue: Double(value) / 255)
    }
}

/// Everyday text is SF Pro and SF Mono. Doto and Instrument Serif Italic are the two accents, bundled
/// with the app under the SIL OFL 1.1 and registered by `HostFonts`.
enum HostType {
    /// Display words only (28 pt and larger); keep punctuation in `punctuation(_:)`.
    static func display(_ size: CGFloat) -> Font {
        HostFonts.registerBundledFonts()
        return Farside.Typeface.display(size)
    }

    /// The one italic accent word in a heading.
    static func accent(_ size: CGFloat) -> Font {
        HostFonts.registerBundledFonts()
        return Farside.Typeface.accent(size * 1.1)
    }

    static func punctuation(_ size: CGFloat) -> Font { .system(size: size * 0.94, weight: .semibold) }

    static func caption(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
}

/// The accent faces ship in `Contents/Resources` (the same files as the phone's `RemotePhone/Fonts`) and
/// are registered by code, for this process only, rather than through `ATSApplicationFontsPath`:
/// the host's Info.plist is generated from build settings and stays untouched, the exact files are
/// named so a missing one is reported instead of silently falling back to the system font, and the
/// unit tests run this same path (an Info.plist key only applies to the launched app).
enum HostFonts {
    static let bundledFiles = ["Doto-Variable.ttf", "InstrumentSerif-Italic.ttf"]

    private final class BundleToken {}

    /// Where the accent faces are found: the app bundle, or the test bundle that contains this code.
    static func bundledURLs() -> [URL] {
        let bundles = [Bundle.main, Bundle(for: BundleToken.self)]
        return bundledFiles.compactMap { file in
            bundles.lazy.compactMap { $0.url(forResource: file, withExtension: nil) }.first
        }
    }

    /// Registers the accent faces once per process; safe to call from anywhere, any number of times.
    /// Returns whether every bundled file was found and registered.
    @discardableResult
    static func registerBundledFonts() -> Bool { registered }

    private static let registered: Bool = {
        let urls = bundledURLs()
        guard urls.count == bundledFiles.count else { return false }
        var failed = false
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { errors, _ in
            let alreadyRegistered = Int(CTFontManagerError.alreadyRegistered.rawValue)
            if (errors as? [NSError])?.contains(where: { $0.code != alreadyRegistered }) == true { failed = true }
            return true
        }
        return !failed
    }()
}

extension Text {
    /// Mono, tracked, uppercase: captions, latencies and technical readouts.
    func hostCaption(_ size: CGFloat = 11, color: Color = Farside.Palette.ash) -> some View {
        font(HostType.caption(size))
            .tracking(size * 0.14)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

extension View {
    @ViewBuilder
    func hostDefaultAction(_ enabled: Bool) -> some View {
        if enabled { keyboardShortcut(.defaultAction) } else { self }
    }
}

// MARK: Headings

/// A heading built from display words, SF punctuation and at most one serif accent word.
struct HostHeading: View {
    enum Part {
        case display(String)
        case accent(String)
        case plain(String)
    }

    let parts: [Part]
    var size: CGFloat = 32

    var body: some View {
        Text(attributed)
            .foregroundStyle(Farside.Palette.bone)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    /// Doto sets the words and every space, so the gaps keep one rhythm; punctuation is set in SF because
    /// Doto draws it badly, and only the accent word itself is Instrument Serif.
    private var attributed: AttributedString {
        parts.reduce(into: AttributedString()) { heading, part in
            switch part {
            case .display(let words):
                heading += run(words, HostType.display(size))
            case .accent(let text):
                for piece in Self.spaced(text) { heading += run(piece.text, piece.isSpace ? HostType.display(size) : HostType.accent(size)) }
            case .plain(let text):
                for piece in Self.spaced(text) { heading += run(piece.text, piece.isSpace ? HostType.display(size) : HostType.punctuation(size)) }
            }
        }
    }

    private func run(_ text: String, _ font: Font) -> AttributedString {
        var run = AttributedString(text)
        run.font = font
        return run
    }

    /// Text cut into alternating runs of whitespace and everything else.
    private static func spaced(_ text: String) -> [(text: String, isSpace: Bool)] {
        var pieces: [(text: String, isSpace: Bool)] = []
        for character in text {
            if pieces.last?.isSpace == character.isWhitespace {
                pieces[pieces.count - 1].text.append(character)
            } else {
                pieces.append((String(character), character.isWhitespace))
            }
        }
        return pieces
    }
}

// MARK: Status marks

/// The ember live light. Shown only while a phone is connected.
struct HostLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(Farside.Palette.ember)
            .frame(width: size, height: size)
            .shadow(color: Farside.Palette.ember.opacity(0.9), radius: size * 0.7)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

struct HostGrantedBadge: View {
    var text = "Granted"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(HostTheme.ink)
                .frame(width: 18, height: 18)
                .background(Farside.Palette.bone, in: Circle())
            Text(text).hostCaption(color: Farside.Palette.bone)
        }
        .accessibilityElement(children: .combine)
    }
}

struct HostIconTile: View {
    let systemImage: String
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.4, weight: .regular))
            .foregroundStyle(Farside.Palette.bone)
            .frame(width: size, height: size)
            .background(Farside.Palette.panel2, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(Farside.Palette.line2, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

// MARK: Controls

/// Bone for the main action, a plate for the rest, ember only for ending something live.
/// `link` is a quiet footer link; `inline` is an underlined action inside running text.
struct HostButtonStyle: ButtonStyle {
    enum Kind { case primary, plate, ember, link, inline }

    var kind: Kind
    var height: CGFloat = 40
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        HostButtonBody(configuration: configuration, kind: kind, height: height, fullWidth: fullWidth)
    }
}

private struct HostButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    let configuration: ButtonStyleConfiguration
    let kind: HostButtonStyle.Kind
    let height: CGFloat
    let fullWidth: Bool

    private var isText: Bool { kind == .link || kind == .inline }

    var body: some View {
        configuration.label
            .font(.system(size: isText || height <= 30 ? 13 : 14, weight: isText ? .regular : .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, isText ? 0 : (height <= 30 ? 12 : 16))
            .padding(.bottom, kind == .inline ? 2 : 0)
            .overlay(alignment: .bottom) {
                if kind == .inline {
                    Rectangle()
                        .fill(hovering ? Farside.Palette.bone : Farside.Palette.line2)
                        .frame(height: 1)
                }
            }
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: isText ? nil : height)
            .background {
                if !isText {
                    RoundedRectangle(cornerRadius: height > 36 ? 12 : 10, style: .continuous).fill(fill)
                }
            }
            .overlay {
                if kind == .plate {
                    RoundedRectangle(cornerRadius: height > 36 ? 12 : 10, style: .continuous)
                        .strokeBorder(Farside.Palette.line2, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !isText ? 0.98 : 1)
            .animation(Farside.Motion.easeOut(Farside.Motion.micro), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary, .ember: HostTheme.ink
        case .plate, .inline: Farside.Palette.bone
        case .link: hovering && isEnabled ? Farside.Palette.bone : Farside.Palette.ash
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: configuration.isPressed ? Farside.Palette.bone.opacity(0.85) : Farside.Palette.bone
        case .ember: configuration.isPressed ? Farside.Palette.emberDeep : Farside.Palette.ember
        case .plate: hovering && isEnabled ? Farside.Palette.panel2 : Color.clear
        case .link, .inline: .clear
        }
    }
}

/// Reach's "Open Settings →" pill: bone, with the arrow in a void circle.
struct HostArrowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Farside.Palette.bone)
                .frame(width: 26, height: 26)
                .background(HostTheme.ink, in: Circle())
                .accessibilityHidden(true)
        }
        .foregroundStyle(HostTheme.ink)
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Farside.Palette.bone.opacity(configuration.isPressed ? 0.85 : 1), in: Capsule())
        .contentShape(Capsule())
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(Farside.Motion.easeOut(Farside.Motion.micro), value: configuration.isPressed)
    }
}

/// Bone track with an ink knob when on; a plate track when off. Accessibility sees a native toggle.
struct HostSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 12)
                HostSwitchTrack(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// Just the switch, for rows that already show their own title.
struct HostSwitch: View {
    let label: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: set))
            .toggleStyle(HostTrackOnlyToggleStyle())
    }
}

private struct HostTrackOnlyToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HostSwitchTrack(isOn: configuration.isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

private struct HostSwitchTrack: View {
    @Environment(\.isEnabled) private var isEnabled
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Farside.Palette.bone : Farside.Palette.panel2)
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : Farside.Palette.line2, lineWidth: 1))
            .frame(width: 40, height: 24)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? HostTheme.ink : Farside.Palette.ash)
                    .frame(width: 18, height: 18)
                    .padding(3)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .animation(Farside.Motion.easeOut(Farside.Motion.micro), value: isOn)
    }
}

/// A toggle row with a title and a one-line explanation, used in the popover and Settings.
struct HostToggleRow: View {
    let title: String
    var subtitle: String?
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Farside.Palette.bone)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Farside.Palette.ash)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(HostSwitchToggleStyle())
    }
}

/// Rows between hairlines, as in the popover's toggle list; each child view is one row.
struct HostHairlineList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HostHairline()
                    row.padding(.vertical, 10)
                }
            }
            HostHairline()
        }
    }
}

struct HostHairline: View {
    var body: some View {
        Rectangle()
            .fill(Farside.Palette.line)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

// MARK: Settings rows

struct HostSettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    @ViewBuilder let accessory: Accessory

    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(Farside.Palette.ash)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Farside.Palette.bone)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Farside.Palette.ash)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
    }
}

// MARK: Pairing code

enum HostQRCode {
    /// The pairing code as void modules on bone: high contrast, on brand.
    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let tint = CIFilter.falseColor()
        tint.inputImage = code
        tint.color0 = CIColor(red: 5 / 255, green: 5 / 255, blue: 5 / 255)
        tint.color1 = CIColor(red: 237 / 255, green: 232 / 255, blue: 223 / 255)
        guard let output = tint.outputImage,
              let cg = CIContext().createCGImage(output, from: code.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: code.extent.width, height: code.extent.height))
    }
}
