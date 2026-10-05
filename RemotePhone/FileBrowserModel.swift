import Foundation
import SwiftUI

@MainActor
final class PhoneFileBrowser: ObservableObject {
    @Published private(set) var entries: [FileBrowserEntry] = []
    @Published private(set) var nextOffset: Int?
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    private var pending: String?
    private var timeout: Task<Void, Never>?
    var send: ((WorkspaceFrame) -> Bool)?
    func query(entry: String? = nil, offset: Int = 0, filter: String = "") {
        guard !busy else { return }
        let request = FileBrowserRequest(operation: entry == nil ? .roots : .list, entry: entry, offset: offset, filter: filter)
        guard (try? request.validate()) != nil, let frame = try? WorkspaceFrame(kind: .files, requestID: InputCausalEnvelope.identity(), value: request) else { return }
        pending = frame.requestID; busy = true; notice = nil
        if offset == 0 { entries = []; nextOffset = nil }
        guard send?(frame) == true else { reset(); notice = "Folder browsing is unavailable right now."; return }
        timeout?.cancel(); timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, self?.pending == frame.requestID else { return }
            self?.pending = nil; self?.busy = false; self?.notice = "Your Mac did not answer. Try again."
        }
    }
    func receive(_ frame: WorkspaceFrame) {
        guard frame.kind == .files, pending == frame.requestID,
              let reply = try? frame.decode(FileBrowserReply.self), reply.entries.count <= 32,
              reply.entries.allSatisfy({ InputCausalEnvelope.validID($0.id) && !$0.name.isEmpty && $0.name.utf8.count <= 384 && !($0.name.contains("/") || $0.name.contains("\0")) }),
              reply.nextOffset.map({ (0...100_000).contains($0) }) ?? true else { return }
        timeout?.cancel(); timeout = nil; pending = nil; busy = false
        if reply.status == .ok {
            entries.append(contentsOf: reply.entries); nextOffset = reply.nextOffset
            if entries.isEmpty { notice = "No files here. Choose a shared folder on your Mac if none are listed." }
        } else { entries = []; nextOffset = nil; notice = reply.status == .stale ? "This folder changed or is unavailable. Go back and reopen it." : "Folder browsing is unavailable right now." }
    }
    func reset() { timeout?.cancel(); timeout = nil; pending = nil; busy = false; entries = []; nextOffset = nil; notice = nil }
}
