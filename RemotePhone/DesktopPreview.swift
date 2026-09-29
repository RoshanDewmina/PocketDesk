import SwiftUI

/// Offline stand-in for a Mac display, drawn in source points. The menu bar, window corners
/// and Dock make Fill cropping and safe-area reachability visible in layout checks.
struct DesktopPreview: View {
    let size: CGSize

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.17, green: 0.27, blue: 0.45),
                                    Color(red: 0.47, green: 0.42, blue: 0.62),
                                    Color(red: 0.91, green: 0.64, blue: 0.52)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                menuBar
                Spacer(minLength: 0)
                dock.padding(.bottom, 10)
            }
            window
                .frame(width: size.width * 0.58, height: size.height * 0.56)
            ForEach(Corner.allCases, id: \.self) { corner in
                Text(corner.label)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.35), in: .rect(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                    .padding(.top, corner.isTop ? 44 : 0)
                    .padding(.bottom, corner.isTop ? 0 : 12)
                    .padding(.horizontal, 12)
            }
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
    }

    private var menuBar: some View {
        HStack(spacing: 22) {
            Image(systemName: "apple.logo")
            Text("Finder").fontWeight(.bold)
            ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0) }
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("Mon 9:41")
        }
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(height: 34)
        .background(.black.opacity(0.22))
    }

    private var window: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.85)).frame(width: 14, height: 14)
                }
                Spacer()
                Text("Notes — Offline preview").font(.system(size: 16, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 60, height: 1)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(white: 0.95))
            VStack(alignment: .leading, spacing: 18) {
                Text("Farside").font(.system(size: 44, weight: .semibold, design: .serif))
                Text("Offline preview · no remote actions")
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                ForEach(0..<6, id: \.self) { row in
                    Capsule()
                        .fill(Color(white: 0.86))
                        .frame(width: [640, 560, 600, 480, 610, 380][row], height: 14)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white)
        }
        .foregroundStyle(.black)
        .clipShape(.rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
    }

    private var dock: some View {
        HStack(spacing: 14) {
            ForEach(Array(Self.dockApps.enumerated()), id: \.offset) { _, app in
                Image(systemName: app.symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(app.color.gradient, in: .rect(cornerRadius: 15))
            }
        }
        .padding(10)
        .background(.white.opacity(0.28), in: .rect(cornerRadius: 22))
    }

    private static let dockApps: [(symbol: String, color: Color)] = [
        ("face.smiling", .blue), ("safari", .cyan), ("message.fill", .green),
        ("envelope.fill", .indigo), ("note.text", .orange), ("terminal.fill", .gray),
        ("music.note", .pink), ("gearshape.fill", .secondary)
    ]

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var isTop: Bool { self == .topLeft || self == .topRight }
        var alignment: Alignment {
            switch self {
            case .topLeft: .topLeading
            case .topRight: .topTrailing
            case .bottomLeft: .bottomLeading
            case .bottomRight: .bottomTrailing
            }
        }
        var label: String {
            switch self {
            case .topLeft: "↖ top left"
            case .topRight: "top right ↗"
            case .bottomLeft: "↙ bottom left"
            case .bottomRight: "bottom right ↘"
            }
        }
    }
}
