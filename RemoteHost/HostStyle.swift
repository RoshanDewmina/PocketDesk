import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// Paperwash washes, used only as quiet accents on otherwise system-styled host UI.
enum HostTone {
    case sage, sand, clay, blue

    func wash(_ scheme: ColorScheme) -> Color {
        let hex: UInt32 = switch (self, scheme == .dark) {
        case (.sage, false): 0xDCE9DD
        case (.sand, false): 0xF1EADA
        case (.clay, false): 0xF5DDD1
        case (.blue, false): 0xDCE6F5
        case (.sage, true): 0x2D3B30
        case (.sand, true): 0x3A3528
        case (.clay, true): 0x42302A
        case (.blue, true): 0x2A3442
        }
        return Color(hex: hex)
    }

    func ink(_ scheme: ColorScheme) -> Color {
        let hex: UInt32 = switch (self, scheme == .dark) {
        case (.sage, false): 0x3D6749
        case (.sand, false): 0x7A6433
        case (.clay, false): 0x9A5334
        case (.blue, false): 0x365C88
        case (.sage, true): 0xA5C9AB
        case (.sand, true): 0xE0D2AD
        case (.clay, true): 0xE7AA8E
        case (.blue, true): 0xA9C5EE
        }
        return Color(hex: hex)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}

extension Font {
    static let hostTitle = Font.system(size: 24, weight: .regular, design: .serif)
}

struct HostIconTile: View {
    @Environment(\.colorScheme) private var scheme
    let systemImage: String
    let tone: HostTone
    var size: CGFloat = 60

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tone.ink(scheme))
            .frame(width: size, height: size)
            .background(tone.wash(scheme), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct HostStatusLine: View {
    @Environment(\.colorScheme) private var scheme
    enum Kind { case waiting, done, attention }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            switch kind {
            case .waiting:
                ProgressView().controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(HostTone.sage.ink(scheme))
            case .attention:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(HostTone.clay.ink(scheme))
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(kind == .waiting ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct HostPermissionBadge: View {
    @Environment(\.colorScheme) private var scheme
    let status: HostPermissionStatus

    var body: some View {
        Label(status.isGranted ? "Allowed" : "Not allowed",
              systemImage: status.isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.callout)
            .foregroundStyle(status.isGranted ? HostTone.sage.ink(scheme) : HostTone.clay.ink(scheme))
    }
}

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
        HStack(alignment: .center, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 38)
    }
}

enum HostQRCode {
    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: image.extent.width, height: image.extent.height))
    }
}
