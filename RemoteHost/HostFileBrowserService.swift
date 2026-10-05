import Foundation
import UniformTypeIdentifiers

@MainActor
final class HostFileBrowserService {
    private let access: FileBrowserAccess
    private let queue = DispatchQueue(label: "Farside.file-browser", qos: .userInitiated)
    private var generation = UUID()
    private var busy = false
    private var activeBrowserTransfer: String?
    var allowed: () -> Bool = { false }
    var reply: ((WorkspaceFrame) -> Void)?
    var engine: FileTransferEngine?
    init(access: FileBrowserAccess) { self.access = access }
    func reset() {
        generation = UUID(); busy = false
        if let activeBrowserTransfer { engine?.cancel(activeBrowserTransfer) }
        activeBrowserTransfer = nil
        access.cancelEnumeration(); access.resetEntries()
    }
    func receive(_ frame: WorkspaceFrame) {
        guard let request = try? FileBrowserRequest.decode(frame) else { return }
        guard allowed() else { refuse(frame, request, .notAllowed); return }
        if request.operation == .cancel, let transfer = request.transfer { engine?.cancel(transfer); return }
        if request.operation == .roots { respond(frame, FileBrowserReply(status: .ok, entries: access.rootEntries())); return }
        guard !busy else { refuse(frame, request, .busy); return }
        busy = true
        let generation = self.generation, access = self.access
        queue.async { [weak self] in
            let page: Result<FileBrowserReply, Error>
            let prepared: Result<(DescriptorFileByteSource, String), Error>?
            if request.operation == .download {
                prepared = Result { try access.source(request.entry!) }; page = .success(FileBrowserReply(status: .ok))
            } else {
                prepared = nil; page = Result { try access.list(request.entry!, offset: request.offset, filter: request.filter) }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.generation == generation else {
                    if case .success(let item) = prepared { item.0.close() }; return
                }
                self.busy = false
                guard self.allowed() else {
                    if case .success(let item) = prepared { item.0.close() }
                    self.refuse(frame, request, .notAllowed); return
                }
                if let prepared, let transfer = request.transfer {
                    switch prepared {
                    case .success(let (source, name)):
                        guard let engine = self.engine else { source.close(); return }
                        switch engine.send(source, name: name, type: UTType(filenameExtension: (name as NSString).pathExtension)?.identifier, transfer: transfer) {
                        case .success: self.activeBrowserTransfer = transfer
                        case .failure(let status): engine.answerRequest(transfer, status)
                        }
                    case .failure: self.engine?.answerRequest(transfer, .unreadable)
                    }
                } else {
                    switch page {
                    case .success(let page): self.respond(frame, page)
                    case .failure(let error): self.respond(frame, FileBrowserReply(status: (error as? FileTransferStatus) == .busy ? .busy : .stale))
                    }
                }
            } }
        }
    }
    private func refuse(_ frame: WorkspaceFrame, _ request: FileBrowserRequest, _ status: FileBrowserReply.Status) {
        if request.operation == .download, let transfer = request.transfer {
            engine?.answerRequest(transfer, status == .busy ? .busy : .notAllowed)
        } else { respond(frame, FileBrowserReply(status: status)) }
    }
    private func respond(_ request: WorkspaceFrame, _ reply: FileBrowserReply) {
        if let frame = try? WorkspaceFrame(kind: .files, requestID: request.requestID, value: reply) {
            self.reply?(frame)
        } else if let bounded = try? WorkspaceFrame(kind: .files, requestID: request.requestID, value: FileBrowserReply(status: .busy)) {
            self.reply?(bounded)
        }
    }
}
