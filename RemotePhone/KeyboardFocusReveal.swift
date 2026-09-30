import SwiftUI

/// What the view does with the focused Mac field while the phone keyboard is open.
enum KeyboardViewMode: String, CaseIterable, Identifiable {
    /// Reveal the field above the keyboard once, and keep it there through layout changes.
    case pinned
    /// Also re-measure after each text or key sent, following a field that grows or moves.
    case followTyping

    static let key = "keyboardViewMode"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned: "Pinned"
        case .followTyping: "Follow typing"
        }
    }
}

/// Decides which focused-field rect the view may reveal. A click's rect only counts for the keyboard
/// it opened; a manual pan or zoom wins until the next click or until the keyboard closes.
struct KeyboardFocusReveal {
    /// A rect that arrived this long before the keyboard opened still belongs to that keyboard.
    static let arrivalWindow: TimeInterval = 2
    static let margin: CGFloat = 16

    private(set) var target: FocusTarget?
    private(set) var manualOverride = false
    private var receivedAt: TimeInterval = -.infinity
    private var keyboardOpenedAt: TimeInterval?

    mutating func receive(_ target: FocusTarget?, at now: TimeInterval) {
        guard let target else {
            self.target = nil
            return
        }
        if target.refresh {
            guard self.target != nil, self.target?.epoch == target.epoch else { return }
        } else {
            manualOverride = false
        }
        self.target = target
        receivedAt = now
    }

    mutating func keyboard(open: Bool, at now: TimeInterval) {
        if open {
            if keyboardOpenedAt == nil { keyboardOpenedAt = now }
        } else {
            keyboardOpenedAt = nil
            target = nil
            manualOverride = false
        }
    }

    mutating func userMovedViewport() {
        if keyboardOpenedAt != nil && target != nil { manualOverride = true }
    }

    /// The source rect to keep visible now, or nil when nothing should move.
    func revealRect(epoch: UInt64, span: CGSize) -> CGRect? {
        guard let target, let opened = keyboardOpenedAt, !manualOverride, target.epoch == epoch,
              receivedAt >= opened - Self.arrivalWindow else { return nil }
        return FocusReveal.region(field: target.rect, anchor: target.anchor, span: span)
    }

    /// Pans `viewport` so the target clears the keyboard chrome. `usable` is the canvas above it.
    mutating func apply(to viewport: inout ViewportTransform, usable: CGRect, epoch: UInt64) -> Bool {
        guard viewport.scale > 0, usable.width > 0, usable.height > 0 else { return false }
        let inset = 2 * Self.margin / viewport.scale
        let span = CGSize(width: max(1, usable.width / viewport.scale - inset),
                          height: max(1, usable.height / viewport.scale - inset))
        guard let rect = revealRect(epoch: epoch, span: span) else { return false }
        return viewport.reveal(sourceRect: rect, in: usable, margin: Self.margin, transient: true)
    }
}

/// Everything that can change where the field should sit; any change re-applies the reveal.
struct KeyboardRevealLayout: Equatable {
    var keyboardOpen: Bool
    var barFrame: CGRect
    var safeInsets: ViewportInsets
    var canvasSize: CGSize
    var sourceSize: CGSize
    var targetRevision: UInt64?
}

/// Drives `KeyboardFocusReveal` from the session view, which passes its viewport binding and layout.
struct KeyboardFocusRevealModifier: ViewModifier {
    @ObservedObject var model: PhoneRemoteModel
    @Binding var viewport: ViewportTransform
    let keyboardOpen: Bool
    let barFrame: CGRect
    let canvasFrame: CGRect
    let manualViewportRevision: UInt64
    var preview = false
    @AppStorage(KeyboardViewMode.key) private var mode: KeyboardViewMode = .pinned
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = KeyboardFocusReveal()

    private var layout: KeyboardRevealLayout {
        KeyboardRevealLayout(keyboardOpen: keyboardOpen, barFrame: barFrame, safeInsets: viewport.safeInsets,
                             canvasSize: viewport.canvasSize, sourceSize: viewport.sourceSize,
                             targetRevision: model.focusTarget?.revision)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: model.focusTarget) { _, target in
                reveal.receive(target, at: ProcessInfo.processInfo.systemUptime)
            }
            .onChange(of: keyboardOpen, initial: true) { _, open in
                reveal.keyboard(open: open, at: ProcessInfo.processInfo.systemUptime)
                model.followTyping = open && mode == .followTyping
            }
            .onChange(of: mode) { _, mode in model.followTyping = keyboardOpen && mode == .followTyping }
            .onChange(of: manualViewportRevision) { _, _ in reveal.userMovedViewport() }
            .onChange(of: layout) { _, _ in apply() }
            #if DEBUG
            .overlay(alignment: .topLeading) {
                if preview, LaunchOptions.has("--ui-focus-preview"), let target = model.focusTarget {
                    FocusFieldPreview(frame: viewport.viewRect(fromSource: target.rect)).ignoresSafeArea()
                }
            }
            #endif
    }

    private func apply() {
        guard keyboardOpen, barFrame.height > 0, canvasFrame.height > 0 else { return }
        let usable = PointerFollowLayout.usableRect(safeRect: viewport.safeRect, canvasFrame: canvasFrame,
                                                   dockFrame: barFrame)
        var next = viewport
        guard reveal.apply(to: &next, usable: usable, epoch: model.geometryEpoch) else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.36, extraBounce: 0)) { viewport = next }
    }
}

extension NativeGestureCommand {
    /// A gesture that moves the picture itself; while the keyboard is open it overrides the reveal.
    var movesViewport: Bool {
        switch self {
        case .zoom, .zoomToggle, .navigate, .pan: true
        default: false
        }
    }
}

#if DEBUG
/// Offline screenshots only: stands in for the Mac field the preview pretends is focused.
private struct FocusFieldPreview: View {
    let frame: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: frame.height / 2)
            .fill(.white)
            .overlay(alignment: .leading) {
                Text("Search or enter website")
                    .font(.system(size: max(8, frame.height * 0.42)))
                    .foregroundStyle(.gray)
                    .padding(.leading, frame.height * 0.5)
            }
            .overlay { RoundedRectangle(cornerRadius: frame.height / 2).strokeBorder(.blue, lineWidth: 2) }
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
            .accessibilityIdentifier("remote.focusPreview")
    }
}
#endif

struct KeyboardViewSettingsSection: View {
    @AppStorage(KeyboardViewMode.key) private var mode: KeyboardViewMode = .pinned

    var body: some View {
        Section {
            Picker("When typing", selection: $mode) {
                ForEach(KeyboardViewMode.allCases) { Text($0.title).tag($0) }
            }
            .foregroundStyle(Farside.Palette.bone)
            .accessibilityIdentifier("remote.keyboardView")
            .listRowBackground(Farside.Palette.panel)
        } header: {
            Text("Keyboard")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Farside.Palette.ash)
                .textCase(nil)
        } footer: {
            Text("When a click opens the keyboard, the Mac field you clicked moves above it at your current zoom. Pinned keeps it there; Follow typing also moves with the field as you send text. Moving the picture yourself always wins until your next click. Your Mac shares only where the field is, never what it says.")
                .foregroundStyle(Farside.Palette.ash)
        }
    }
}
