import SwiftUI

@MainActor
final class ShortcutWorkspaceController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private var pending: (id: String, session: UUID, epoch: UInt64, chord: PersonalShortcut, posting: Bool)?
    private var timeout: Task<Void, Never>?
    var authority: () -> (session: UUID, epoch: UInt64)? = { nil }
    var transport: (WorkspaceFrame, UInt64) -> Bool = { _, _ in false }
    func retire() { timeout?.cancel(); timeout = nil; pending = nil; busy = false; message = "" }
    func run(_ chord: PersonalShortcut) {
        guard chord.valid, !busy, let context = authority() else { return }
        message = ""
        send(.init(operation: .context, bundleID: chord.bundleID), chord: chord, session: context.session, epoch: context.epoch, posting: false)
    }
    private func send(_ request: ScopedChordRequest, chord: PersonalShortcut, session: UUID, epoch: UInt64, posting: Bool) {
        let id = InputCausalEnvelope.identity()
        guard let frame = try? WorkspaceFrame(kind: .scopedChord, requestID: id, value: request) else { return }
        pending = (id, session, epoch, chord, posting); busy = true
        guard transport(frame, epoch) else { retire(); message = "Couldn’t reach your Mac."; return }
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.pending?.id == id else { return }
            self.pending = nil; self.busy = false
            self.message = posting ? "Delivery is uncertain. Check your Mac before trying again." : "Couldn’t confirm the current app."
        }
    }
    func receive(_ frame: WorkspaceFrame, epoch: UInt64) {
        guard frame.kind == .scopedChord, let pending, let current = authority(), pending.id == frame.requestID,
              pending.session == current.session, pending.epoch == current.epoch, epoch == pending.epoch,
              let reply = try? frame.decode(ScopedChordReply.self), (try? reply.validate()) != nil else { return }
        timeout?.cancel(); timeout = nil; self.pending = nil; busy = false
        if !pending.posting, reply.outcome == .ready, reply.bundleID == pending.chord.bundleID, let context = reply.context {
            send(.init(operation: .post, context: context, key: pending.chord.key, modifiers: pending.chord.modifiers),
                 chord: pending.chord, session: pending.session, epoch: pending.epoch, posting: true)
            return
        }
        switch reply.outcome {
        case .posted where pending.posting: message = "Chord posted. Check the app’s result."
        case .uncertain: message = "Delivery is uncertain. Check your Mac before trying again."
        default: message = "The app or permission changed. No chord was posted."
        }
    }
}

struct ShortcutWorkspaceView: View {
    @ObservedObject var model: PhoneRemoteModel
    @State private var label = ""
    @State private var key = "s"
    @State private var modifiers: Set<String> = ["command"]
    private var profile: ShortcutWorkspaceProfile? { model.personalShortcutProfile }
    var body: some View {
        Section("App") {
            Picker("Shortcut profile", selection: Binding(get: { model.personalShortcutBundleID }, set: { model.personalShortcutEditingBundle = $0 })) {
                Text("General Mac actions").tag("global")
                ForEach(Array(Set(ShortcutCatalog.apps.keys).union(model.frontmostApp?.bundleID.map { [$0] } ?? [])).sorted(), id: \.self) { bundle in Text(ShortcutWorkspaceStore.appLabel(bundle, current: model.frontmostApp)).tag(bundle) }
            }
        }
        Section("Pinned actions") {
            ForEach(model.personalShortcutCatalog) { chip in
                let id = ShortcutWorkspaceStore.catalogID(chip)
                HStack {
                    Button { model.togglePersonalShortcut(chip) } label: {
                        Label(chip.label, systemImage: profile?.hidden.contains(id) == true ? "pin.slash" : "pin.fill")
                    }
                    Spacer()
                    Button { model.movePersonalShortcut(chip, direction: -1) } label: { Image(systemName: "arrow.up") }
                        .accessibilityLabel("Move " + chip.label + " earlier")
                    Button { model.movePersonalShortcut(chip, direction: 1) } label: { Image(systemName: "arrow.down") }
                        .accessibilityLabel("Move " + chip.label + " later")
                }.frame(minHeight: 44).buttonStyle(.borderless)
            }
            Button("Restore defaults") { model.restorePersonalShortcuts() }
        }
        if model.personalShortcutBundleID != "global" {
            Section("One chord for this app") {
                TextField("Button name", text: $label).onChange(of: label) { _, value in label = String(value.prefix(40)) }
                Picker("Key", selection: $key) { ForEach(ScopedChordPolicy.keys, id: \.self) { Text($0).tag($0) } }
                ForEach(ScopedChordPolicy.modifiers, id: \.self) { modifier in
                    Toggle(modifier.capitalized, isOn: Binding(get: { modifiers.contains(modifier) }, set: { on in if on { modifiers.insert(modifier) } else { modifiers.remove(modifier) } }))
                }
                Text((modifiers.sorted().map { $0.capitalized } + [key]).joined(separator: " + ")).font(.footnote)
                Button("Add button") {
                    if model.addPersonalChord(label: label, key: key, modifiers: modifiers.sorted()) { label = "" }
                }.disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (profile?.custom.count ?? 0) >= 12)
                Text("Each button posts one chord only after the Mac confirms this app is still frontmost. Local app switching can race event routing; check the result before repeating.").font(.footnote)
            }
            Section("Your buttons") {
                ForEach(profile?.custom ?? []) { chord in
                    HStack {
                        Button(chord.label) { model.runPersonalChord(chord) }.disabled(!model.windowWorkspaceAllowed || model.shortcutWorkspace.busy)
                        Spacer()
                        Button("Remove", role: .destructive) { model.removePersonalChord(chord.id) }
                    }.frame(minHeight: 44).buttonStyle(.borderless)
                }
                if !model.shortcutWorkspace.message.isEmpty { Text(model.shortcutWorkspace.message).font(.footnote) }
            }
        } else {
            Section { Text("Choose an app profile to add its buttons. Editing stays on this phone; posting needs that exact app frontmost on the Mac.").font(.footnote) }
        }
    }
}
