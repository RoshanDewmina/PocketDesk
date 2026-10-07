import AppKit
import SwiftUI

/// Owner-local grants are distinct from OS filesystem permission. Production host is unsandboxed;
/// minimal bookmarks retain folder identity without adding sandbox or Full Disk Access entitlements.
@MainActor
final class HostFileBrowserFolders: ObservableObject {
    #if HOST_UI_SNAPSHOT_TESTS
    static let shared = HostFileBrowserFolders(defaults: HostFileBrowserSnapshotDefaults.defaults)
    #elseif DEBUG
    static let shared = HostFileBrowserFolders(defaults: HostE2E.active?.defaults ?? .standard)
    #else
    static let shared = HostFileBrowserFolders()
    #endif
    let access = FileBrowserAccess()
    @Published private(set) var folders: [FileBrowserEntry] = []
    @Published private(set) var notice: String?
    var didRevoke: (() -> Void)?
    private struct Saved: Codable { let id: String; let bookmark: Data; let device: Int32; let inode: UInt64 }
    private let defaults: UserDefaults
    private var saved: [Saved] = []
    private var panel: NSOpenPanel?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "FarsideSharedFolderGrants"), let records = try? JSONDecoder().decode([Saved].self, from: data), records.count <= 16 {
            for record in records {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: record.bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale), !stale,
                      let id = try? access.grant(url, id: record.id) else { continue }
                guard let identity = access.rootIdentity(id), identity.device == record.device, UInt64(identity.inode) == record.inode else { access.revoke(id); continue }
                saved.append(record)
            }
        }
        folders = access.rootEntries()
    }
    func chooseFolder() {
        guard panel == nil else { return }
        let panel = NSOpenPanel(); self.panel = panel
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.resolvesAliases = false; panel.treatsFilePackagesAsDirectories = false
        panel.title = "Share a folder read-only"; panel.prompt = "Share Folder"
        panel.message = "Your connected phone can browse and download local files in this folder while you allow control."
        panel.begin { [weak self, weak panel] result in
            MainActor.assumeIsolated {
                guard let self, let panel, self.panel === panel else { return }; self.panel = nil
                guard result == .OK, let url = panel.url else { return }
                do {
                    let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                    let id = try self.access.grant(url)
                    guard let identity = self.access.rootIdentity(id) else { self.access.revoke(id); throw FileTransferStatus.invalid }
                    self.saved.append(Saved(id: id, bookmark: bookmark, device: identity.device, inode: UInt64(identity.inode)))
                    self.persist(); self.folders = self.access.rootEntries(); self.notice = nil
                } catch { self.notice = "That folder cannot be shared. Choose a local folder you can read." }
            }
        }
        panel.orderFrontRegardless()
    }
    func revoke(_ id: String) {
        didRevoke?() // Close bulk admission before waiting for any disk enumeration/read.
        access.cancelEnumeration(); access.revoke(id); access.resetEntries()
        saved.removeAll { $0.id == id }; persist(); folders = access.rootEntries()
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(saved), forKey: "FarsideSharedFolderGrants") }
}
struct HostFileBrowserFoldersView: View {
    @ObservedObject private var folders = HostFileBrowserFolders.shared
    var body: some View {
        HostSettingsSection("Shared folders", footer: folders.notice
            ?? "Your phone can open and download files in these folders. It can't change or delete anything.") {
            if folders.folders.isEmpty {
                HostSettingsRow("No folders shared", subtitle: "Add a folder to open its files from your phone", systemImage: "folder") {
                    addButton(kind: .primary)
                }
            } else {
                ForEach(folders.folders) { folder in
                    HostSettingsRow(folder.name, subtitle: "View and download only", systemImage: "folder") {
                        Button("Remove") { folders.revoke(folder.id) }
                            .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
                            .accessibilityLabel("Stop sharing \(folder.name)")
                    }
                }
                HostSettingsRow("Share another folder", systemImage: "plus") { addButton(kind: .plate) }
            }
        }
    }

    private func addButton(kind: HostButtonStyle.Kind) -> some View {
        Button("Add…", action: folders.chooseFolder)
            .buttonStyle(HostButtonStyle(kind: kind, height: 30))
            .accessibilityLabel("Add a shared folder")
            .accessibilityIdentifier("farside.settings.sharedFolder.add")
    }
}
