import Foundation
import Darwin
import UniformTypeIdentifiers

/// Descriptor authority for explicitly granted folders. All operations are serialized; cancellation
/// has its own lease and fences enumeration without waiting for the directory queue.
final class FileBrowserAccess {
    struct Identity: Equatable {
        let device: dev_t; let inode: ino_t; let mode: mode_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino; mode = value.st_mode & S_IFMT }
    }
    private struct Component { let name: String; let identity: Identity }
    private struct Root {
        let id: String; let name: String; let descriptor: Int32
        let absolute: [Component]; let lease: TransferEffectLease
    }
    private struct Entry { let root: String; let components: [Component] }
    private let lock = NSLock()
    private var roots: [String: Root] = [:]
    private var entries: [String: Entry] = [:]
    private var sources: [String: [DescriptorFileByteSource]] = [:]
    private let leaseLock = NSLock()
    private var enumerationLease = TransferEffectLease()

    @discardableResult func grant(_ url: URL, id: String = InputCausalEnvelope.identity()) throws -> String {
        guard InputCausalEnvelope.validID(id), url.isFileURL else { throw FileTransferStatus.invalid }
        // Owner-local URL only. Resolve neither aliases nor symlink components.
        let names = url.pathComponents.filter { $0 != "/" }
        guard !names.isEmpty else { throw FileTransferStatus.denied }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FileTransferStatus.unreadable }
        var components: [Component] = []
        do {
            for name in names {
                guard Self.safe(name) else { throw FileTransferStatus.denied }
                var before = stat()
                guard fstatat(fd, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
                      before.st_mode & S_IFMT == S_IFDIR,
                      !Self.unsupportedMetadata(name: name, info: before) else { throw FileTransferStatus.unsupported }
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw FileTransferStatus.denied }
                close(fd); fd = child
                let info = try Self.info(fd)
                guard Identity(info) == Identity(before), !Self.unsupported(fd, name: name, info: info) else { throw FileTransferStatus.unsupported }
                components.append(Component(name: name, identity: Identity(info)))
            }
            var volume = statfs()
            guard fstatfs(fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw FileTransferStatus.unsupported }
            lock.lock(); defer { lock.unlock() }
            guard roots.count < 16, roots[id] == nil else { throw FileTransferStatus.busy }
            roots[id] = Root(id: id, name: Self.displayName(url.lastPathComponent), descriptor: fd,
                             absolute: components, lease: TransferEffectLease())
            return id
        } catch { close(fd); throw error }
    }
    func rootIdentity(_ id: String) -> Identity? {
        lock.lock(); defer { lock.unlock() }
        guard let root = roots[id], let info = try? Self.info(root.descriptor) else { return nil }
        return Identity(info)
    }
    func rootEntries() -> [FileBrowserEntry] {
        lock.lock(); defer { lock.unlock() }
        return roots.values.sorted { $0.name < $1.name }.map { FileBrowserEntry(id: $0.id, name: $0.name, kind: .folder, bytes: nil) }
    }
    func cancelEnumeration() { leaseLock.lock(); let lease = enumerationLease; leaseLock.unlock(); lease.closeAdmission() }
    func resetEntries() {
        cancelEnumeration()
        lock.lock(); defer { lock.unlock() }
        leaseLock.lock(); enumerationLease = TransferEffectLease(); leaseLock.unlock(); entries.removeAll()
        for group in sources.values { group.forEach { $0.close() } }; sources.removeAll()
    }
    func revoke(_ id: String) {
        // Admission closes before a queued list/open can produce any new effect.
        lock.lock(); defer { lock.unlock() }
        guard let root = roots.removeValue(forKey: id) else { return }
        root.lease.closeAdmission(); close(root.descriptor)
        entries = entries.filter { $0.value.root != id }
        sources.removeValue(forKey: id)?.forEach { $0.close() }
    }
    func list(_ id: String, offset: Int, filter: String, authorized: () -> Bool = { true }) throws -> FileBrowserReply {
        lock.lock(); defer { lock.unlock() }
        leaseLock.lock(); let lease = enumerationLease; leaseLock.unlock()
        guard lease.isActive, authorized() else { throw FileTransferStatus.notAllowed }
        let (root, components) = try resolve(id)
        let fd = try openEntry(root, components)
        guard let directory = fdopendir(fd) else { close(fd); throw FileTransferStatus.unreadable }
        defer { closedir(directory) }
        var index = 0, scanned = 0, result: [FileBrowserEntry] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while let pointer = readdir(directory) {
            guard lease.isActive, root.lease.isActive, authorized() else { throw FileTransferStatus.notAllowed }
            if index < offset {
                index += 1
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw FileTransferStatus.busy }
                continue
            }
            index += 1; scanned += 1
            let name = withUnsafePointer(to: &pointer.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if Self.safe(name), !name.hasPrefix("."), filter.isEmpty || name.localizedCaseInsensitiveContains(filter) {
                var metadata = stat()
                if fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
                    let identity = Identity(metadata)
                    var kind: FileBrowserEntry.Kind = identity.mode == S_IFDIR ? .folder : .file
                    if Self.unsupportedMetadata(name: name, info: metadata) { kind = .unsupported }
                    else {
                        let child = openat(fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                        if child < 0 { kind = .unsupported }
                        else {
                            defer { close(child) }
                            if let opened = try? Self.info(child) {
                                if Identity(opened) != identity || Self.unsupported(child, name: name, info: opened) { kind = .unsupported }
                            } else { kind = .unsupported }
                        }
                    }
                    // IDs are bounded and scoped to this host session's entry map.
                    guard entries.count < 4096 else { throw FileTransferStatus.busy }
                    let entryID = InputCausalEnvelope.identity()
                    if kind != .unsupported { entries[entryID] = Entry(root: root.id, components: components + [Component(name: name, identity: identity)]) }
                    result.append(FileBrowserEntry(id: entryID, name: Self.displayName(name), kind: kind,
                                                   bytes: kind == .file ? Int64(metadata.st_size) : nil, modified: Double(metadata.st_mtimespec.tv_sec)))
                }
            }
            if result.count >= 16 || scanned >= 1024 || ProcessInfo.processInfo.systemUptime >= deadline {
                return FileBrowserReply(status: .ok, entries: result, nextOffset: index)
            }
        }
        return FileBrowserReply(status: .ok, entries: result)
    }
    func source(_ id: String, authorized: @escaping () -> Bool = { true }) throws -> (DescriptorFileByteSource, String) {
        lock.lock(); defer { lock.unlock() }
        let (root, components) = try resolve(id)
        guard !components.isEmpty, root.lease.isActive, authorized() else { throw FileTransferStatus.denied }
        let fd = try openEntry(root, components)
        do {
            let source = try DescriptorFileByteSource(descriptor: fd, authorized: { root.lease.isActive && authorized() })
            sources[root.id, default: []].removeAll { $0.isClosed }
            sources[root.id, default: []].append(source)
            return (source, components.last!.name)
        } catch { close(fd); throw error }
    }
    private func resolve(_ id: String) throws -> (Root, [Component]) {
        if let root = roots[id] { return (root, []) }
        guard let entry = entries[id], let root = roots[entry.root] else { throw FileTransferStatus.invalid }
        return (root, entry.components)
    }
    private func openEntry(_ root: Root, _ components: [Component]) throws -> Int32 {
        guard root.lease.isActive else { throw FileTransferStatus.notAllowed }
        // Validate the original root and every absolute ancestor; renamed/replaced roots go stale.
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FileTransferStatus.unreadable }
        do {
            for component in root.absolute + components {
                var before = stat()
                guard fstatat(fd, component.name, &before, AT_SYMLINK_NOFOLLOW) == 0,
                      Identity(before) == component.identity,
                      !Self.unsupportedMetadata(name: component.name, info: before) else { throw FileTransferStatus.invalid }
                let child = openat(fd, component.name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw FileTransferStatus.denied }
                close(fd); fd = child
                let metadata = try Self.info(fd)
                guard Identity(metadata) == component.identity,
                      !Self.unsupported(fd, name: component.name, info: metadata) else { throw FileTransferStatus.invalid }
            }
            guard root.lease.isActive else { throw FileTransferStatus.notAllowed }
            return fd
        } catch { close(fd); throw error }
    }
    private static func displayName(_ name: String) -> String {
        let sanitized = FileNameSanitizer.sanitize(name)
        var result = ""
        for character in sanitized {
            guard result.utf8.count + String(character).utf8.count <= 128 else { break }
            result.append(character)
        }
        return result.isEmpty ? FileNameSanitizer.fallback : result
    }
    private static func safe(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") }
    private static func info(_ fd: Int32) throws -> stat {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw FileTransferStatus.unreadable }; return value
    }
    private static func unsupportedMetadata(name: String, info: stat) -> Bool {
        let mode = info.st_mode & S_IFMT
        guard mode == S_IFDIR || mode == S_IFREG else { return true }
        // SF_DATALESS: opening never requests hydration; reject placeholders before any read.
        if info.st_flags & 0x40000000 != 0 || name.hasSuffix(".icloud") { return true }
        let ext = (name as NSString).pathExtension
        if ["app", "bundle", "framework", "pkg", "photoslibrary", "rtfd"].contains(ext.lowercased()) || UTType(filenameExtension: ext)?.conforms(to: .package) == true { return true }
        return false
    }
    private static func unsupported(_ fd: Int32, name: String, info: stat) -> Bool {
        if unsupportedMetadata(name: name, info: info) { return true }
        var finderInfo = [UInt8](repeating: 0, count: 32)
        let count = finderInfo.withUnsafeMutableBytes { fgetxattr(fd, "com.apple.FinderInfo", $0.baseAddress, 32, 0, 0) }
        return count == 32 && finderInfo[8] & 0x80 != 0 // Finder alias flag.
    }
    deinit { for root in roots.values { close(root.descriptor) }; sources.values.flatMap { $0 }.forEach { $0.close() } }
}
