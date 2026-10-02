import SwiftUI

/// Device copy follows the hardware even when an iPad window is compact.
/// Phone strings remain byte-for-byte identical.
enum DeviceWord {
    static var current: String { name(for: UIDevice.current.userInterfaceIdiom) }
    static func name(for idiom: UIUserInterfaceIdiom) -> String { idiom == .pad ? "iPad" : "iPhone" }
    static func copy(_ phoneCopy: String, idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> String {
        idiom == .pad ? phoneCopy.replacingOccurrences(of: "iPhone", with: "iPad") : phoneCopy
    }
}

/// Internal rollback for the regular-width shell; no user-facing setting.
enum FarsideShellLayout {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "ipad.shellEnabled") as? Bool ?? true }
    static func twoColumns(horizontal: UserInterfaceSizeClass?, typeSize: DynamicTypeSize, enabled: Bool) -> Bool {
        enabled && horizontal == .regular && !typeSize.isAccessibilitySize
    }
    static func columns(windowWidth: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        let available = max(0, min(1040, windowWidth) - 40 - 20)
        return (min(560, available * 560 / 960), min(400, available * 400 / 960))
    }
}

extension Farside.Palette {
    /// Ink for text and glyphs on bone surfaces.
    static let ink = Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
    /// Secondary ink on bone surfaces.
    static let inkMuted = Color(red: 106 / 255, green: 102 / 255, blue: 96 / 255)
}

// MARK: - Brand

/// The dot-matrix pointer mark. Its tip is the ember contact dot (the mark's one exception
/// to "ember only for contact").
struct FarsideMark: View {
    var height: CGFloat = 18
    var inverted = false

    private static let large = ["#", "##", "###", "####", "#####", "######", "#######", "########",
                                "#########", "##########", "######", "##.##", "#...##", "....##",
                                ".....##", ".....##"]
    private static let small = ["#", "##", "###", "####", "#####", "######", "###", "#.##", "...#"]

    var body: some View {
        let rows = height <= 20 ? Self.small : Self.large
        let unit = height / CGFloat(rows.count)
        let columns = CGFloat(rows.map(\.count).max() ?? 1)
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, character) in row.enumerated() where character == "#" {
                    let tip = x == 0 && y == 0
                    let radius = unit * (tip ? 0.5 : 0.42)
                    let center = CGPoint(x: (CGFloat(x) + 0.5) * unit, y: (CGFloat(y) + 0.5) * unit)
                    let color = tip ? Farside.Palette.ember : (inverted ? Farside.Palette.ink : Farside.Palette.bone)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                        width: radius * 2, height: radius * 2)),
                                 with: .color(color))
                }
            }
        }
        .frame(width: unit * columns, height: height)
        .accessibilityHidden(true)
    }
}

/// Mark plus the lowercase dot-matrix wordmark. Doto stays at 28 pt or larger.
struct FarsideWordmark: View {
    var size: CGFloat = 28

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.32) {
            FarsideMark(height: size * 0.72)
            Text("farside")
                .font(Farside.Typeface.display(size))
                .foregroundStyle(Farside.Palette.bone)
                .fixedSize()
        }
        .dynamicTypeSize(.large)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Farside")
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Type

extension View {
    /// Mono uppercase caption for technical readouts and labels.
    func farsideCaption(_ color: Color = Farside.Palette.ash, style: Font.TextStyle = .caption2) -> some View {
        font(Farside.Typeface.caption(style).weight(.medium))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(color)
    }
}

/// A display heading: words in dot-matrix Doto, punctuation in SF, and at most one accent word
/// in Instrument Serif Italic. VoiceOver reads the plain sentence.
struct FarsideHeading: View {
    let text: String
    var accent: String?
    var size: CGFloat = 34
    var alignment: TextAlignment = .leading
    @ScaledMetric private var scaled: CGFloat

    init(_ text: String, accent: String? = nil, size: CGFloat = 34, alignment: TextAlignment = .leading) {
        self.text = text
        self.accent = accent
        self.size = max(28, size)
        self.alignment = alignment
        _scaled = ScaledMetric(wrappedValue: max(28, size), relativeTo: .largeTitle)
    }

    var body: some View {
        FarsideHeading.compose(text, accent: accent, size: min(scaled, size * 1.6))
            .foregroundStyle(Farside.Palette.bone)
            .multilineTextAlignment(alignment)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }

    static func compose(_ text: String, accent: String?, size: CGFloat) -> Text {
        var result = Text(verbatim: "")
        for run in runs(text, accent: accent) {
            let piece: Text
            switch run.kind {
            case .dots: piece = Text(verbatim: run.text).font(.custom(Farside.Typeface.dotMatrix, fixedSize: size))
            case .mark: piece = Text(verbatim: run.text).font(.system(size: size * 0.9, weight: .bold))
            case .accent: piece = Text(verbatim: run.text).font(.custom(Farside.Typeface.serifItalic, fixedSize: size * 1.12))
            }
            result = Text("\(result)\(piece)")
        }
        return result
    }

    struct Run: Equatable {
        enum Kind { case dots, mark, accent }
        var kind: Kind
        var text: String
    }

    /// Splits a sentence so Doto only ever receives letters, digits and spaces.
    static func runs(_ text: String, accent: String?) -> [Run] {
        var runs: [Run] = []
        func append(_ kind: Run.Kind, _ piece: String) {
            if let last = runs.last, last.kind == kind { runs[runs.count - 1].text += piece }
            else { runs.append(Run(kind: kind, text: piece)) }
        }
        var remaining = Substring(text)
        if let accent, !accent.isEmpty, let range = text.range(of: accent) {
            let before = text[text.startIndex..<range.lowerBound]
            for character in before { append(isDotSafe(character) ? .dots : .mark, String(character)) }
            append(.accent, accent)
            remaining = text[range.upperBound...]
        }
        for character in remaining { append(isDotSafe(character) ? .dots : .mark, String(character)) }
        return runs
    }

    static func isDotSafe(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == " "
    }
}

// MARK: - Surfaces

extension View {
    /// A solid plate for anything with words. Text never sits directly on dots.
    func farsidePlate(_ radius: CGFloat = Farside.Radius.card, fill: Color = Farside.Palette.panel,
                      stroke: Color = Farside.Palette.line) -> some View {
        background(fill, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }

    func farsideSheet() -> some View {
        modifier(FarsideSheetModifier())
    }

    /// For presentations that had no Farside plate on compact-width phones.
    func farsideRegularSheet() -> some View {
        modifier(FarsideSheetModifier(regularOnly: true))
    }

    /// Compact presentations retain their existing detents; regular forms use their natural size.
    func farsideCompactDetents(_ detents: Set<PresentationDetent>) -> some View {
        modifier(FarsideCompactDetentsModifier(detents: detents))
    }
}

private struct FarsideCompactDetentsModifier: ViewModifier {
    var detents: Set<PresentationDetent>
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ViewBuilder func body(content: Content) -> some View {
        if SessionChromePolicy.form(regular: horizontalSizeClass == .regular, enabled: FarsideShellLayout.enabled) {
            content
        } else {
            content.presentationDetents(detents)
        }
    }
}

private struct FarsideSheetModifier: ViewModifier {
    var regularOnly = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ViewBuilder func body(content: Content) -> some View {
        let plate = content.presentationBackground(Farside.Palette.void2)
            .presentationCornerRadius(Farside.Radius.sheet)
        if SessionChromePolicy.form(regular: horizontalSizeClass == .regular, enabled: FarsideShellLayout.enabled) {
            plate.presentationSizing(.form)
        } else if regularOnly {
            content
        } else {
            plate
        }
    }
}

/// Screen ground: the void, edge to edge.
struct FarsideBackground: View {
    var body: some View {
        Farside.Palette.void.ignoresSafeArea()
    }
}

// MARK: - Buttons

/// The main action: a bone pill with ink text.
struct FarsidePrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 56

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration) { pressed, enabled in
            configuration.label
                .font(.headline)
                .foregroundStyle(Farside.Palette.ink)
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(Farside.Palette.bone.opacity(pressed ? 0.82 : 1), in: .capsule)
                .opacity(enabled ? 1 : 0.35)
                .scaleEffect(pressed ? 0.98 : 1)
        }
    }
}

/// Everything else: a plate with a stronger hairline.
struct FarsideSecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 52
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration) { pressed, enabled in
            configuration.label
                .font(.headline)
                .foregroundStyle(Farside.Palette.bone)
                .padding(.horizontal, 18)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
                .background(pressed ? Farside.Palette.panel2 : Farside.Palette.panel, in: .capsule)
                .overlay(Capsule().strokeBorder(Farside.Palette.line2, lineWidth: 1))
                .opacity(enabled ? 1 : 0.4)
        }
    }
}

/// Stop and End: ember outline, the only red-hot control on screen.
struct FarsideEndButtonStyle: ButtonStyle {
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration) { pressed, enabled in
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(pressed ? Farside.Palette.void : Farside.Palette.ember)
                .padding(.horizontal, 16)
                .frame(minHeight: height)
                .background(pressed ? Farside.Palette.ember : .clear, in: .capsule)
                .overlay(Capsule().strokeBorder(Farside.Palette.ember.opacity(0.6), lineWidth: 1))
                .opacity(enabled ? 1 : 0.4)
        }
    }
}

/// Quiet text action with a hairline underline.
struct FarsideLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration) { pressed, enabled in
            configuration.label
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Farside.Palette.bone.opacity(pressed ? 0.6 : 1))
                .padding(.bottom, 3)
                .overlay(alignment: .bottom) { Rectangle().fill(Farside.Palette.line2).frame(height: 1) }
                .frame(minHeight: 44)
                .contentShape(.rect)
                .opacity(enabled ? 1 : 0.4)
        }
    }
}

/// A small round hairline button, such as help or close.
struct FarsideRoundButtonStyle: ButtonStyle {
    var diameter: CGFloat = 38

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration) { pressed, enabled in
            configuration.label
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Farside.Palette.ash)
                .frame(width: diameter, height: diameter)
                .background(pressed ? Farside.Palette.panel2 : .clear, in: .circle)
                .overlay(Circle().strokeBorder(Farside.Palette.line2, lineWidth: 1))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
                .opacity(enabled ? 1 : 0.4)
        }
    }
}

/// Dock tile: a 58 pt key with a mono label beneath. `on` means live (listening), so it is ember.
struct FarsideTileButtonStyle: ButtonStyle {
    var on = false
    var emphasized = false
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration) { pressed, enabled in
            configuration.label
                .labelStyle(TileLabelStyle(on: on, emphasized: emphasized, selected: selected, pressed: pressed))
                .opacity(enabled ? 1 : 0.35)
        }
    }

    private struct TileLabelStyle: LabelStyle {
        let on: Bool
        let emphasized: Bool
        let selected: Bool
        let pressed: Bool

        func makeBody(configuration: Configuration) -> some View {
            VStack(spacing: 8) {
                configuration.icon
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(on ? .white : (emphasized ? Farside.Palette.ink : Farside.Palette.bone))
                    .frame(width: 58, height: 58)
                    .background(on ? Farside.Palette.ember : (emphasized ? Farside.Palette.bone : (pressed ? Farside.Palette.void2 : Farside.Palette.panel2)),
                                in: .rect(cornerRadius: 19, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(on || emphasized ? .clear : (selected ? Farside.Palette.bone : Farside.Palette.line),
                                      lineWidth: selected ? 1.5 : 1))
                    .shadow(color: on ? Farside.Palette.ember.opacity(0.45) : .clear, radius: 12)
                configuration.title
                    .font(.caption.weight(.medium))
                    .foregroundStyle(on || selected ? Farside.Palette.bone : Farside.Palette.ash)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(minWidth: 58)
            .contentShape(.rect)
        }
    }
}

/// Gives button styles access to press and enabled state.
private struct StyledLabel<Content: View>: View {
    let configuration: ButtonStyleConfiguration
    let content: (Bool, Bool) -> Content
    @Environment(\.isEnabled) private var isEnabled

    init(configuration: ButtonStyleConfiguration, @ViewBuilder content: @escaping (Bool, Bool) -> Content) {
        self.configuration = configuration
        self.content = content
    }

    var body: some View {
        content(configuration.isPressed, isEnabled)
            .animation(Farside.Motion.easeOut(Farside.Motion.micro), value: configuration.isPressed)
    }
}

// MARK: - Status

/// The live dot. Ember only while in contact with the Mac; its meaning is always repeated in text.
struct LiveDot: View {
    enum State { case idle, busy, live, attention }
    var state: State
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.State private var dimmed = false

    var body: some View {
        Group {
            switch state {
            case .idle:
                Circle().strokeBorder(Farside.Palette.ash, lineWidth: 1.2)
            case .busy:
                Circle().fill(Farside.Palette.ash).opacity(dimmed ? 0.3 : 1)
            case .live:
                Circle().fill(Farside.Palette.ember)
                    .shadow(color: Farside.Palette.ember.opacity(0.9), radius: size * 0.8)
                    .opacity(dimmed ? 0.45 : 1)
            case .attention:
                Circle().fill(Farside.Palette.bone)
            }
        }
        .frame(width: size, height: size)
        .id(state)
        .onAppear(perform: pulse)
        .onChange(of: state) { _, _ in pulse() }
        .accessibilityHidden(true)
    }

    private func pulse() {
        dimmed = false
        guard !reduceMotion, state == .busy || state == .live else { return }
        withAnimation(.easeInOut(duration: state == .busy ? 0.7 : 1).repeatForever(autoreverses: true)) {
            dimmed = true
        }
    }
}

/// Internal rollback for the accessibility-only layouts; never exposed as a setting.
enum FarsideAccessibilityLayout {
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "accessibility.adaptiveLayoutsEnabled") as? Bool ?? true
    }
}

/// Segmented control in the Reach style. Each option is a real button.
struct FarsideSegmented<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var accessibilityStacked = false
    /// Fuller names for VoiceOver and Voice Control when the visible title is one short word.
    var spokenTitles: [Value: String] = [:]
    /// Optional leading symbols, so the choice reads at a glance.
    var symbols: [Value: String] = [:]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var stacked: Bool {
        accessibilityStacked && dynamicTypeSize.isAccessibilitySize && FarsideAccessibilityLayout.enabled
    }

    var body: some View {
        Group {
            if stacked {
                VStack(spacing: 0) { segments }
            } else {
                HStack(spacing: 0) { segments }
            }
        }
        .padding(3)
        .background(Farside.Palette.ink, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Farside.Palette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var segments: some View {
        ForEach(options, id: \.value) { option in
            let selected = option.value == selection
            Button { selection = option.value } label: {
                HStack(spacing: 5) {
                    if let symbol = symbols[option.value] {
                        Image(systemName: symbol)
                            .font(.caption.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    Text(option.title)
                }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(selected ? Farside.Palette.bone : Farside.Palette.ash)
                    .lineLimit(stacked ? nil : 1)
                    .minimumScaleFactor(stacked ? 1 : 0.8)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(selected ? Farside.Palette.panel2 : .clear, in: .rect(cornerRadius: 11, style: .continuous))
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Farside.Palette.line2, lineWidth: 1)
                        }
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spokenTitles[option.value] ?? option.title)
            .accessibilityInputLabels([spokenTitles[option.value] ?? option.title, option.title])
            .accessibilityShowsLargeContentViewer()
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// A short message on a plate, used for toasts and inline feedback.
struct FarsideNotice: View {
    enum Tone { case info, success, caution }
    let message: String
    var tone: Tone = .info

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Farside.Palette.bone)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Farside.Palette.bone)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .farsidePlate(Farside.Radius.card, fill: Farside.Palette.panel.opacity(0.97), stroke: Farside.Palette.line2)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch tone {
        case .info: "info.circle"
        case .success: "checkmark"
        case .caution: "exclamationmark.circle"
        }
    }
}
