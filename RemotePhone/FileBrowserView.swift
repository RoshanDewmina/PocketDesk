import SwiftUI

struct FileBrowserView: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var browser: PhoneFileBrowser
    @ObservedObject var files: PhoneFileTransfer
    @State private var folders: [FileBrowserEntry] = []
    @State private var filter = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if !folders.isEmpty {
                    Button("Back to " + (folders.dropLast().last?.name ?? "Shared folders")) {
                        folders.removeLast(); filter = ""; refresh()
                    }
                    HStack {
                        TextField("Filter filenames", text: $filter).autocorrectionDisabled()
                        Button("Filter", action: refresh).disabled(browser.busy)
                    }
                }
                if let notice = browser.notice { Text(notice).foregroundStyle(.secondary) }
                if !model.fileBrowserAvailable { Text("Folder browsing needs an active control session.").foregroundStyle(.secondary) }
                ForEach(browser.entries) { entry in
                    Button {
                        if entry.kind == .folder { folders.append(entry); filter = ""; refresh() }
                        else if entry.kind == .file { model.downloadBrowserFile(entry.id); dismiss() }
                    } label: {
                        HStack {
                            Image(systemName: entry.kind == .folder ? "folder" : entry.kind == .file ? "doc" : "nosign")
                            VStack(alignment: .leading) {
                                Text(entry.name).lineLimit(2)
                                if let bytes = entry.bytes { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                                if let modified = entry.modified, modified.isFinite { Text(Date(timeIntervalSince1970: modified), style: .date).font(.caption).foregroundStyle(.secondary) }
                                if entry.kind == .unsupported { Text("Unavailable item").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Image(systemName: entry.kind == .folder ? "chevron.right" : "arrow.down")
                        }
                    }
                    .disabled(entry.kind == .unsupported || browser.busy || !model.fileBrowserAvailable || files.isBusy)
                }
                if browser.busy { ProgressView() }
                if let offset = browser.nextOffset {
                    Button("Load more") { browser.query(entry: folders.last?.id, offset: offset, filter: filter) }.disabled(browser.busy)
                }
                if files.isBusy { Button("Cancel download", action: files.cancel) }
                if let notice = files.notice { Text(notice.message).font(.footnote) }
            }
            .navigationTitle(folders.last?.name ?? "Shared folders")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Refresh", action: refresh).disabled(browser.busy || !model.fileBrowserAvailable) }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: refresh)
            .onChange(of: model.fileBrowserAvailable) { _, available in if !available { browser.reset(); folders = [] } }
            .onDisappear { browser.reset() }
        }
    }
    private func refresh() { browser.query(entry: folders.last?.id, filter: filter) }
}
