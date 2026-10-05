import SwiftUI

@MainActor
final class WindowWorkspaceController: ObservableObject {
    struct Focus: Equatable { let geometry: FocusGeometry; let epoch: UInt64; let requestID: String }
    @Published private(set) var entries: [WindowWorkspaceEntry] = []
    @Published private(set) var message = ""
    @Published private(set) var busy = false
    @Published private(set) var focus: Focus?
    private var revision: String?
    private var pending: (id: String, request: WindowWorkspaceRequest, session: UUID, epoch: UInt64)?
    private var timeout: Task<Void, Never>?
    var authority: () -> (session: UUID, epoch: UInt64)? = { nil }
    var transport: (WorkspaceFrame, UInt64) -> Bool = { _, _ in false }
    func list() { send(.init(operation: .list)) }
    func focusCurrent() { send(.init(operation: .focusCurrent)) }
    func activate(_ entry: WindowWorkspaceEntry) {
        guard let revision else { return }
        send(.init(operation: .activate, revision: revision, handle: entry.id))
    }
    func retire() {
        timeout?.cancel(); timeout = nil; pending = nil; entries = []; revision = nil; busy = false; focus = nil; message = ""
    }
    func close() {
        if let context = authority(), let frame = try? WorkspaceFrame(kind: .windows, requestID: InputCausalEnvelope.identity(), value: WindowWorkspaceRequest(operation: .close)) {
            _ = transport(frame, context.epoch)
        }
        // Keep only a current geometry result; no titles or retained target handles survive closing.
        let currentFocus = focus
        retire(); focus = currentFocus
    }
    private func send(_ request: WindowWorkspaceRequest) {
        guard let context = authority(), !busy else { return }
        let id = InputCausalEnvelope.identity()
        guard let frame = try? WorkspaceFrame(kind: .windows, requestID: id, value: request) else { return }
        pending = (id, request, context.session, context.epoch); busy = true; message = ""
        if request.operation == .list { entries = []; revision = nil }
        guard transport(frame, context.epoch) else { retire(); message = "Couldn’t reach your Mac."; return }
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.pending?.id == id else { return }
            self.pending = nil; self.busy = false; self.message = "Your Mac didn’t respond. Try again." 
        }
    }
    func receive(_ frame: WorkspaceFrame, epoch: UInt64) {
        guard frame.kind == .windows, let pending, let current = authority(), frame.requestID == pending.id,
              epoch == pending.epoch, epoch == current.epoch, pending.session == current.session,
              let reply = try? frame.decode(WindowWorkspaceReply.self), (try? reply.validate()) != nil,
              reply.operation == pending.request.operation else { return }
        timeout?.cancel(); timeout = nil; self.pending = nil; busy = false
        switch reply.operation {
        case .list: entries = reply.entries; revision = reply.revision
        case .focusCurrent:
            if let geometry = reply.geometry, reply.outcome == .confirmed { focus = .init(geometry: geometry, epoch: epoch, requestID: frame.requestID) }
        case .activate, .close: break
        }
        switch reply.outcome {
        case .confirmed: message = reply.operation == .activate ? "Mac focus confirmed." : ""
        case .requested: message = "Switch requested. Check the Mac picture before typing."
        case .stale: entries = []; revision = nil; message = "That target changed. Refresh the list."
        case .unsupported: message = "This app doesn’t expose a supported window. Use its app row or the Mac picture."
        case .notAllowed: retire(); message = "Window tools need a live desktop you can control."
        case .timedOut: message = "Your Mac didn’t respond. Try again."
        }
    }
}

struct WindowWorkspaceView: View {
    @ObservedObject var controller: WindowWorkspaceController
    let allowed: Bool
    @State private var query = ""
    var body: some View {
        Section {
            Button("Focus current window", systemImage: "viewfinder") { controller.focusCurrent() }
                .disabled(!allowed || controller.busy)
                .accessibilityIdentifier("remote.workspace.focusCurrent")
            Text("Fits the current window into your phone view. Mac windows stay where they are.").font(.footnote)
        }
        Section("Running apps and windows") {
            TextField("Search apps and windows", text: $query)
            Button("Refresh", systemImage: "arrow.clockwise") { controller.list() }.disabled(!allowed || controller.busy)
            if controller.busy { ProgressView() }
            ForEach(controller.entries.filter { query.isEmpty || ($0.app + " " + ($0.title ?? "")).localizedCaseInsensitiveContains(query) }) { entry in
                Button { controller.activate(entry) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.app)
                        Text(entry.title?.isEmpty == false ? entry.title! : (entry.exactWindow ? "Untitled window" : "Switch to app"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }.disabled(!allowed || controller.busy)
            }
        }
        if !controller.message.isEmpty { Section { Text(controller.message).font(.footnote) } }
        Section { Text("Window labels are fetched only while this page is open and cleared when it closes. An app row is available when exact window switching is unsupported.").font(.footnote) }
    }
}
