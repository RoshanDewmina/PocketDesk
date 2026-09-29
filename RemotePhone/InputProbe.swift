#if DEBUG
import SwiftUI

/// Offline record of the control actions the phone would send, for UI tests and screenshots
/// (`--ui-layout-check --ui-input-probe`). Every action is validated exactly as the connection
/// would validate it; nothing is sent anywhere.
@MainActor
final class InputProbe: ObservableObject {
    /// "`sequence` description", newest last. The sequence lets a test read only what followed
    /// its own action, even after older entries scroll out.
    @Published private(set) var entries: [String] = []
    private(set) var actions: [RemoteAction] = []
    private var sequence = 0

    func record(_ action: RemoteAction) -> Bool {
        sequence += 1
        guard (try? action.validate()) != nil else {
            entries.append("\(sequence) invalid \(action.action)")
            return false
        }
        actions.append(action)
        entries.append("\(sequence) \(Self.describe(action))")
        if entries.count > 40 { entries.removeFirst(entries.count - 40) }
        if actions.count > 200 { actions.removeFirst(actions.count - 200) }
        return true
    }

    func clear() {
        entries.removeAll()
        actions.removeAll()
    }

    var lastSequence: Int { sequence }

    /// Compact, stable text: `moveTo 720.0 450.0`, `click 2`, `key w command+shift`.
    static func describe(_ action: RemoteAction) -> String {
        var parts = [action.action]
        switch action.action {
        case "moveTo", "move":
            parts.append(String(format: "%.1f %.1f", action.x, action.y))
        case "scroll":
            parts.append(action.interaction?.phase ?? "-")
            parts.append(String(format: "%.1f %.1f", action.x, action.y))
        case "click", "right", "double", "middle", "dragDown":
            parts.append("\(action.interaction?.clickCount ?? 1)")
        case "key":
            parts.append(action.key)
        case "display":
            parts.append("\(action.display ?? 0)")
        default:
            break
        }
        if !action.modifiers.isEmpty { parts.append(action.modifiers.sorted().joined(separator: "+")) }
        return parts.joined(separator: " ")
    }
}

/// Markers at known Mac points, drawn through the same viewport as the picture. A UI test taps a
/// marker's centre and checks that the recorded `moveTo` names the marker's Mac point.
struct InputProbeTargets: View {
    let viewport: ViewportTransform

    /// A 5 × 4 grid, so several targets stay on screen at any zoom or orientation.
    static let fractions: [CGPoint] = [0.15, 0.4, 0.6, 0.85].flatMap { y in
        [0.1, 0.3, 0.5, 0.7, 0.9].map { x in CGPoint(x: x, y: y) }
    }

    var body: some View {
        ForEach(Array(Self.fractions.enumerated()), id: \.offset) { index, fraction in
            let source = CGPoint(x: (viewport.sourceSize.width * fraction.x).rounded(),
                                 y: (viewport.sourceSize.height * fraction.y).rounded())
            let point = viewport.viewPoint(fromSource: source)
            Circle()
                .strokeBorder(Farside.Palette.ember, lineWidth: 2)
                .frame(width: 14, height: 14)
                .position(point)
                .accessibilityElement()
                .accessibilityIdentifier("probe.target.\(index)")
                .accessibilityLabel("Probe target \(index)")
                .accessibilityValue("x\(Int(source.x)) y\(Int(source.y))")
        }
    }
}

/// Exposes the probe log to UI tests as one accessibility element, drawn faintly on screen.
struct InputProbeOverlay: View {
    @ObservedObject var probe: InputProbe

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Clear", action: probe.clear)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Farside.Palette.bone)
                .accessibilityIdentifier("remote.inputProbe.clear")
            Text(probe.entries.suffix(6).joined(separator: "\n"))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Farside.Palette.bone.opacity(0.8))
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("remote.inputProbe")
                .accessibilityLabel("Input probe")
                .accessibilityValue(probe.entries.joined(separator: " | "))
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(Farside.Palette.void.opacity(0.6)).allowsHitTesting(false)
        }
    }
}
#endif
