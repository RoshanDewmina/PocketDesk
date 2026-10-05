import Foundation
import SwiftUI

struct SavedTaskView: Codable, Equatable, Identifiable {
    let id: UUID
    var label: String
    let hostKey: String
    let displayHint: String
    let width: Double
    let height: Double
    let mode: String
    let zoom: Double
    let focusX: Double
    let focusY: Double
    let atBaseline: Bool
    let viewOnly: Bool
    init?(label: String, host: PhoneHostTrust, display: DisplayDescriptor, viewport: ResumeViewport) {
        guard Self.validLabel(label),
              (try? display.validate()) != nil else { return nil }
        id = UUID(); self.label = label; hostKey = AwayMemory.macKey(host: host); displayHint = display.name
        width = display.width; height = display.height; mode = viewport.mode.rawValue; zoom = Double(viewport.zoom)
        focusX = viewport.focus.x; focusY = viewport.focus.y; atBaseline = viewport.atBaseline; viewOnly = viewport.viewOnly
        guard self.viewport != nil else { return nil }
    }
    var viewport: ResumeViewport? {
        guard let mode = ViewportMode(rawValue: mode), zoom.isFinite, (0.05...20).contains(zoom), focusX.isFinite, focusY.isFinite,
              (0...1).contains(focusX), (0...1).contains(focusY), width.isFinite, height.isFinite,
              (1...20_000).contains(width), (1...20_000).contains(height), Self.validLabel(label), displayHint.utf8.count <= 512 else { return nil }
        // Stored viewing state can keep or reduce authority, never grant it. The view does not apply viewOnly=false.
        return ResumeViewport(mode: mode, zoom: zoom, focus: CGPoint(x: focusX, y: focusY), atBaseline: atBaseline, viewOnly: viewOnly)
    }
    func matchesGeometry(_ size: CGSize) -> Bool { abs(width - size.width) < 0.5 && abs(height - size.height) < 0.5 }
    static func validLabel(_ label: String) -> Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && label.count <= 40 && label.utf8.count <= 256 &&
        label.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
struct TaskViewWorkspaceStore {
    static let defaultsKey = "namedTaskViews.v1"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func all(host: PhoneHostTrust) -> [SavedTaskView] { load().filter { $0.hostKey == AwayMemory.macKey(host: host) } }
    @discardableResult
    func save(_ view: SavedTaskView, host: PhoneHostTrust) -> Bool {
        guard view.hostKey == AwayMemory.macKey(host: host), view.viewport != nil else { return false }
        var entries = load().filter { $0.id != view.id }
        guard entries.filter({ $0.hostKey == view.hostKey }).count < 20, entries.count < 128 else { return false }
        entries.append(view); return persist(entries)
    }
    func rename(_ id: UUID, label: String, host: PhoneHostTrust) {
        guard SavedTaskView.validLabel(label) else { return }
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == id && $0.hostKey == AwayMemory.macKey(host: host) }) else { return }
        entries[index].label = label; persist(entries)
    }
    func delete(_ id: UUID, host: PhoneHostTrust) { persist(load().filter { !($0.id == id && $0.hostKey == AwayMemory.macKey(host: host)) }) }
    func forget(host: PhoneHostTrust) { persist(load().filter { $0.hostKey != AwayMemory.macKey(host: host) }) }
    private func load() -> [SavedTaskView] {
        guard let data = defaults.data(forKey: Self.defaultsKey), data.count <= 128 * 1024,
              let entries = try? JSONDecoder().decode([SavedTaskView].self, from: data), entries.count <= 128,
              Set(entries.map(\.id)).count == entries.count else { return [] }
        return entries.filter { $0.viewport != nil && SecureRandom.isToken($0.hostKey) }
    }
    @discardableResult
    private func persist(_ entries: [SavedTaskView]) -> Bool {
        guard let data = try? JSONEncoder().encode(entries), data.count <= 128 * 1024 else { return false }
        defaults.set(data, forKey: Self.defaultsKey); return true
    }
}

/// An explicit display selection is required on every restoration; a durable display ID is never trusted.
struct TaskViewRestoreIntent: Equatable {
    let id: UUID
    let view: SavedTaskView
    let hostKey: String
    let session: UUID
    let display: UInt32
    let requestedEpoch: UInt64
    let startedAt: TimeInterval
    enum Decision: Equatable { case wait, restore(ResumeViewport), fit, cancel }
    func decision(hostKey: String?, session: UUID, epoch: UInt64, display: UInt32?, size: CGSize,
                  pendingDisplay: Bool, geometrySettled: Bool, allowed: Bool, now: TimeInterval) -> Decision {
        guard allowed, hostKey == self.hostKey, session == self.session, now >= startedAt, now - startedAt <= 10 else { return .cancel }
        guard !pendingDisplay, display == self.display, geometrySettled, epoch >= requestedEpoch else { return .wait }
        guard view.hostKey == self.hostKey, let viewport = view.viewport else { return .cancel }
        return view.matchesGeometry(size) ? .restore(viewport) : .fit
    }
}

struct TaskViewWorkspaceView: View {
    @ObservedObject var model: PhoneRemoteModel
    let viewport: ResumeViewport?
    let canSave: Bool
    let manualRevision: UInt64
    let restore: (SavedTaskView, UInt32, Bool) -> Void
    @State private var label = ""
    @State private var selected: SavedTaskView?
    @State private var renameID: UUID?
    @State private var renameLabel = ""
    @State private var fitOnRemap = false
    var body: some View {
        Section("Save this view") {
            TextField("Name, such as Terminal", text: $label).onChange(of: label) { _, value in label = String(value.prefix(40)) }
            Button("Save current view", systemImage: "bookmark") {
                if let viewport, model.saveTaskView(label: label, viewport: viewport) { label = "" }
            }.disabled(!canSave || viewport == nil || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.savedTaskViews.count >= 20)
        }
        Section("Saved views") {
            ForEach(model.savedTaskViews) { view in
                VStack(alignment: .leading) {
                    Button(view.label) { selected = view; fitOnRemap = false }
                    Text(view.displayHint + " · " + String(Int(view.width)) + " × " + String(Int(view.height))).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Rename") { renameID = view.id; renameLabel = view.label }
                        Button("Delete", role: .destructive) { model.deleteTaskView(view.id); if selected?.id == view.id { selected = nil } }
                    }.font(.caption)
                }.frame(minHeight: 44).buttonStyle(.borderless)
            }
        }
        if let selected {
            Section("Choose a display for “" + selected.label + "”") {
                Text("Choose the current display deliberately. Names and old display IDs cannot reliably identify the same monitor after reconnecting.").font(.footnote)
                Toggle("Use a whole-display Fit view", isOn: $fitOnRemap)
                ForEach(model.displays) { display in
                    Button(display.name + " · " + display.resolution) { restore(selected, display.id, fitOnRemap); self.selected = nil }
                        .disabled(!model.canChooseDisplay || !model.windowWorkspaceAllowed)
                }
            }
        }
        if let renameID {
            Section("Rename view") {
                TextField("Name", text: $renameLabel).onChange(of: renameLabel) { _, value in renameLabel = String(value.prefix(40)) }
                Button("Save name") { model.renameTaskView(renameID, label: renameLabel); self.renameID = nil }
            }
        }
        if !model.taskViewMessage.isEmpty { Section { Text(model.taskViewMessage).font(.footnote) } }
        Section { Text("Only your label, display hint and viewport numbers are saved on this phone. End preserves named views. Forgetting this Mac removes them. No Mac input is replayed.").font(.footnote) }
    }
}
