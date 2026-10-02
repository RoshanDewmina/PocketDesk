import AppKit
import ApplicationServices

protocol VirtualDisplayWindowAccess: AnyObject, Sendable {
    func snapshot(frontmostOnly: Bool, identities: [VirtualDisplayWindowIdentity], budget: HostAXBudget) -> VirtualDisplayWindowSnapshot
    func setFrame(_ frame: CGRect, identity: VirtualDisplayWindowIdentity, budget: HostAXBudget) -> Bool
}

protocol VirtualDisplayWindowJournalStore: AnyObject, Sendable {
    func load() throws -> VirtualDisplayWindowJournal?
    func save(_ journal: VirtualDisplayWindowJournal) throws
    func remove() throws
}

enum VirtualDisplayWindowError: Error {
    case unsupported, pendingRestore, unmovable, invalidBounds
}

/// AX and disk work stay on one bounded serial lane. Journal writes finish before any frame write.
/// Cancellation never abandons cleanup midway: the host must await restore before releasing a display.
final class VirtualDisplayWindowKeeper: @unchecked Sendable {
    static var defaultJournalURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PocketDesk/virtual-display-window-restore.json")
    }

    static var journalExists: Bool { FileManager.default.fileExists(atPath: defaultJournalURL.path) }

    private let access: VirtualDisplayWindowAccess
    private let store: VirtualDisplayWindowJournalStore
    private let queue = DispatchQueue(label: "farside.virtual-display.windows", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = false
    private var journal: VirtualDisplayWindowJournal?
    private var loadFailed = false

    convenience init(journalURL: URL? = nil) {
        let url = journalURL ?? Self.defaultJournalURL
        self.init(access: LiveVirtualDisplayWindowAccess(), store: FileVirtualDisplayWindowJournalStore(url: url))
    }

    init(access: VirtualDisplayWindowAccess, store: VirtualDisplayWindowJournalStore) {
        self.access = access
        self.store = store
        do {
            journal = try store.load()
            if let journal, journal.version != 1 || journal.records.count > VirtualDisplayWindowPolicy.maximumWindows
                || Set(journal.records.map(\.identity)).count != journal.records.count
                || journal.records.contains(where: { !VirtualDisplayWindowPolicy.valid($0.original) || !VirtualDisplayWindowPolicy.valid($0.requested)
                    || $0.applied.map({ !VirtualDisplayWindowPolicy.valid($0) }) == true
                    || $0.identity.pid <= 0 || !$0.identity.launchTime.isFinite || $0.identity.windowID == 0
                    || ($0.virtualBounds.isEmpty && ($0.applied != nil || $0.requested != $0.original))
                    || $0.virtualBounds.count > 8 || $0.virtualBounds.contains(where: { !VirtualDisplayWindowPolicy.valid($0) }) }) {
                loadFailed = true
            }
        } catch { loadFailed = true }
        pending = loadFailed || !(journal?.records.isEmpty ?? true)
    }

    var hasPendingRestore: Bool { lock.withLock { pending } }

    /// Must be awaited before the adapter creates a display: creation itself may reflow windows.
    func prepareFrontmostWindows() async throws {
        try await run {
            guard !self.loadFailed, self.journal == nil else { throw VirtualDisplayWindowError.pendingRestore }
            let snapshot = self.access.snapshot(frontmostOnly: true, identities: [], budget: HostAXBudget(total: 1.5))
            guard snapshot.complete, !snapshot.stageManagerEnabled, !snapshot.windows.isEmpty,
                  snapshot.windows.count <= VirtualDisplayWindowPolicy.maximumWindows,
                  Set(snapshot.windows.map(\.identity)).count == snapshot.windows.count else { throw VirtualDisplayWindowError.unsupported }
            let records = snapshot.windows.sorted { $0.identity.windowID < $1.identity.windowID }.map { window in
                VirtualDisplayWindowJournal.Record(identity: window.identity, original: window.frame,
                    requested: window.frame, applied: nil, virtualBounds: [])
            }
            let journal = VirtualDisplayWindowJournal(records: records)
            try self.store.save(journal)
            self.journal = journal
            self.markPending()
        }
    }

    func moveFrontmostWindows(to bounds: CGRect) async throws {
        try await run {
            guard !self.loadFailed, self.journal == nil || self.journal?.isPrepared == true else { throw VirtualDisplayWindowError.pendingRestore }
            guard VirtualDisplayWindowPolicy.valid(bounds) else { throw VirtualDisplayWindowError.invalidBounds }
            let snapshot = self.access.snapshot(frontmostOnly: true, identities: self.journal?.records.map(\.identity) ?? [], budget: HostAXBudget(total: 1.5))
            guard snapshot.complete, !snapshot.stageManagerEnabled, !snapshot.windows.isEmpty,
                  snapshot.windows.count <= VirtualDisplayWindowPolicy.maximumWindows,
                  Set(snapshot.windows.map(\.identity)).count == snapshot.windows.count else { throw VirtualDisplayWindowError.unsupported }
            var journal: VirtualDisplayWindowJournal
            if var prepared = self.journal {
                for index in prepared.records.indices {
                    guard snapshot.windows.filter({ $0.identity == prepared.records[index].identity }).count == 1 else { throw VirtualDisplayWindowError.unsupported }
                    prepared.records[index].requested = VirtualDisplayWindowPolicy.destination(for: prepared.records[index].original, in: bounds, index: index)
                    prepared.records[index].virtualBounds = [bounds]
                }
                journal = prepared
            } else {
                let records = snapshot.windows.sorted { $0.identity.windowID < $1.identity.windowID }.enumerated().map { index, window in
                    VirtualDisplayWindowJournal.Record(identity: window.identity, original: window.frame,
                        requested: VirtualDisplayWindowPolicy.destination(for: window.frame, in: bounds, index: index), applied: nil, virtualBounds: [bounds])
                }
                journal = VirtualDisplayWindowJournal(records: records)
            }
            guard VirtualDisplayWindowPolicy.distinctFrames(journal.records.map(\.requested)) else { throw VirtualDisplayWindowError.unsupported }
            try self.store.save(journal)
            self.journal = journal
            self.markPending()
            try self.apply(bounds: bounds)
        }
    }

    /// The caller admits this only after authenticated phone input changes the frontmost app.
    /// Existing originals remain intact, and only newly enrolled windows are moved.
    func includeFrontmostWindows(to bounds: CGRect) async throws {
        try await run {
            guard !self.loadFailed else { throw VirtualDisplayWindowError.pendingRestore }
            guard VirtualDisplayWindowPolicy.valid(bounds) else { throw VirtualDisplayWindowError.invalidBounds }
            var journal = self.journal ?? VirtualDisplayWindowJournal(records: [])
            guard !journal.isPrepared else { throw VirtualDisplayWindowError.pendingRestore }
            let snapshot = self.access.snapshot(frontmostOnly: true, identities: [], budget: HostAXBudget(total: 1.5))
            guard snapshot.complete, !snapshot.stageManagerEnabled, !snapshot.windows.isEmpty,
                  Set(snapshot.windows.map(\.identity)).count == snapshot.windows.count else { throw VirtualDisplayWindowError.unsupported }
            let existing = Set(journal.records.map(\.identity))
            let additions = snapshot.windows.filter { !existing.contains($0.identity) }.sorted { $0.identity.windowID < $1.identity.windowID }
            guard !additions.isEmpty else { return }
            guard journal.records.count + additions.count <= VirtualDisplayWindowPolicy.maximumWindows else { throw VirtualDisplayWindowError.unsupported }
            let firstIndex = journal.records.count
            journal.records += additions.enumerated().map { index, window in
                VirtualDisplayWindowJournal.Record(identity: window.identity, original: window.frame,
                    requested: VirtualDisplayWindowPolicy.destination(for: window.frame, in: bounds, index: firstIndex + index),
                    applied: nil, virtualBounds: [bounds])
            }
            guard VirtualDisplayWindowPolicy.distinctFrames(journal.records.map(\.requested)) else { throw VirtualDisplayWindowError.unsupported }
            try self.store.save(journal)
            self.journal = journal
            self.markPending()
            try self.apply(bounds: bounds, moving: Set(additions.map(\.identity)))
        }
    }

    func resize(to bounds: CGRect) async throws {
        try await run {
            guard VirtualDisplayWindowPolicy.valid(bounds) else { throw VirtualDisplayWindowError.invalidBounds }
            guard !self.loadFailed, var journal = self.journal, !journal.records.isEmpty, !journal.isPrepared else { throw VirtualDisplayWindowError.unsupported }
            let snapshot = self.access.snapshot(frontmostOnly: false, identities: journal.records.map(\.identity), budget: HostAXBudget(total: 1.5))
            guard snapshot.complete, !snapshot.stageManagerEnabled else { throw VirtualDisplayWindowError.unsupported }
            for index in journal.records.indices {
                let record = journal.records[index]
                let matches = snapshot.windows.filter { $0.identity == record.identity }
                guard matches.count == 1, VirtualDisplayWindowPolicy.shouldRestore(record, current: matches[0].frame) else {
                    throw VirtualDisplayWindowError.unmovable
                }
                journal.records[index].requested = VirtualDisplayWindowPolicy.destination(for: matches[0].frame, in: bounds, index: index)
                if !journal.records[index].virtualBounds.contains(bounds) { journal.records[index].virtualBounds.append(bounds)
                    journal.records[index].virtualBounds = Array(journal.records[index].virtualBounds.suffix(8))
                }
            }
            guard VirtualDisplayWindowPolicy.distinctFrames(journal.records.map(\.requested)) else { throw VirtualDisplayWindowError.unsupported }
            try self.store.save(journal)
            self.journal = journal
            try self.apply(bounds: bounds)
        }
    }

    func restore() async -> Bool { (try? await run { self.restoreOnQueue() }) ?? false }
    func recover() async -> Bool { await restore() }

    private func apply(bounds: CGRect, moving: Set<VirtualDisplayWindowIdentity>? = nil) throws {
        guard let journal else { return }
        let budget = HostAXBudget(total: 2)
        var succeeded = true
        for record in journal.records where moving?.contains(record.identity) ?? true {
            if !access.setFrame(record.requested, identity: record.identity, budget: budget) { succeeded = false; break }
        }
        let settled = access.snapshot(frontmostOnly: false, identities: journal.records.map(\.identity), budget: HostAXBudget(total: 1.5))
        var updated = journal
        var actualFrames = settled.windows.filter { window in
            journal.records.contains(where: { $0.identity == window.identity }) && !(moving?.contains(window.identity) ?? true)
        }.map(\.frame)
        for index in updated.records.indices where moving?.contains(updated.records[index].identity) ?? true {
            let matches = settled.windows.filter { $0.identity == updated.records[index].identity }
            if matches.count == 1 {
                updated.records[index].applied = matches[0].frame
                if !VirtualDisplayWindowPolicy.fits(matches[0].frame, in: bounds) { succeeded = false }
                if actualFrames.contains(where: { VirtualDisplayWindowPolicy.sameOrigin($0, matches[0].frame) }) { succeeded = false }
                actualFrames.append(matches[0].frame)
            } else { succeeded = false }
        }
        if !settled.complete { succeeded = false }
        // Retain updated in-memory attribution even if this second disk write fails.
        self.journal = updated
        do { try store.save(updated) } catch { _ = restoreOnQueue(); throw error }
        if !succeeded { _ = restoreOnQueue(); throw VirtualDisplayWindowError.unmovable }
    }

    private func restoreOnQueue() -> Bool {
        guard !loadFailed else { return false }
        guard var journal else { return true }
        let snapshot = access.snapshot(frontmostOnly: false, identities: journal.records.map(\.identity), budget: HostAXBudget(total: 1.5))
        guard snapshot.complete, !snapshot.stageManagerEnabled else { return false }
        let budget = HostAXBudget(total: 2)
        var remaining: [VirtualDisplayWindowJournal.Record] = []
        var toVerify: [VirtualDisplayWindowJournal.Record] = []
        for record in journal.records {
            let matches = snapshot.windows.filter { $0.identity == record.identity }
            if matches.isEmpty && snapshot.closedIdentities.contains(record.identity) { continue }
            guard matches.count == 1 else { remaining.append(record); continue }
            let current = matches[0].frame
            guard VirtualDisplayWindowPolicy.shouldRestore(record, current: current) else { continue }
            if VirtualDisplayWindowPolicy.close(current, record.original) { continue }
            guard access.setFrame(record.original, identity: record.identity, budget: budget) else { remaining.append(record); continue }
            toVerify.append(record)
        }
        if !toVerify.isEmpty {
            let verified = access.snapshot(frontmostOnly: false, identities: journal.records.map(\.identity), budget: HostAXBudget(total: 1.5))
            for record in toVerify {
                let result = verified.windows.filter { $0.identity == record.identity }
                if !verified.complete || result.count != 1 || !VirtualDisplayWindowPolicy.close(result[0].frame, record.original) { remaining.append(record) }
            }
        }
        journal.records = remaining
        do {
            if remaining.isEmpty { try store.remove(); self.journal = nil }
            else { try store.save(journal); self.journal = journal }
        } catch { markPending(); return false }
        markPending()
        return remaining.isEmpty
    }

    private func markPending() { lock.withLock { pending = loadFailed || !(journal?.records.isEmpty ?? true) } }
    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        let result: Result<T, Error> = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Result { try work() }) }
        }
        return try result.get()
    }
}

private final class FileVirtualDisplayWindowJournalStore: VirtualDisplayWindowJournalStore, @unchecked Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> VirtualDisplayWindowJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(VirtualDisplayWindowJournal.self, from: Data(contentsOf: url))
    }
    func save(_ journal: VirtualDisplayWindowJournal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
    }
    func remove() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}

/// No title/content/private AX window-ID lookup. AX↔CG matching requires a unique same-PID frame.
/// Apps with coincident windows or unavailable launchDate fail closed instead of guessing.
private final class LiveVirtualDisplayWindowAccess: VirtualDisplayWindowAccess, @unchecked Sendable {
    private var elements: [VirtualDisplayWindowIdentity: AXUIElement] = [:]
    // This survives snapshots only within this keeper instance, never a crash/relaunch. Each use
    // proves same-process launch, CFEqual AX membership, AX identifier and public CG ID existence.
    private var provenBindings: [VirtualDisplayWindowIdentity: AXUIElement] = [:]
    private var requireFrontmost = false

    func snapshot(frontmostOnly: Bool, identities: [VirtualDisplayWindowIdentity], budget: HostAXBudget) -> VirtualDisplayWindowSnapshot {
        elements = [:]
        requireFrontmost = frontmostOnly
        let stageManager = UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
        guard !stageManager, let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return .init(windows: [], complete: false, stageManagerEnabled: stageManager)
        }
        // The on-screen list omits other Spaces and minimized windows. Only the public all-window
        // list can establish closure; AX failure or absence from the visible list cannot do so.
        var allInfo = identities.isEmpty ? nil : CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        if allInfo?.isEmpty == true, identities.contains(where: { identity in
            NSRunningApplication(processIdentifier: identity.pid)?.launchDate?.timeIntervalSince1970 == identity.launchTime
        }) { allInfo = nil } // An unavailable GUI inventory cannot establish closure.
        let closedIdentities = Set(identities.filter { identity in
            let app = NSRunningApplication(processIdentifier: identity.pid)
            let ids: Set<UInt32>? = allInfo.map { rows in
                Set(rows.compactMap { row in
                    guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == identity.pid else { return nil }
                    return (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                })
            }
            return VirtualDisplayWindowPolicy.isDefinitivelyClosed(identity, processExists: app != nil,
                currentLaunchTime: app?.launchDate?.timeIntervalSince1970, allWindowIDs: ids)
        })
        for identity in closedIdentities { provenBindings[identity] = nil }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let visible = info.filter { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
            && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0 }
        let pids = Set(visible.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value })
            .filter { $0 != ProcessInfo.processInfo.processIdentifier && (frontmostOnly ? $0 == frontmostPID : identities.map(\.pid).contains($0)) }
        var windows: [VirtualDisplayWindow] = []
        var complete = true
        for pid in pids.sorted() {
            guard !budget.isExhausted else { complete = false; break }
            guard let application = NSRunningApplication(processIdentifier: pid), let launch = application.launchDate else { continue }
            let app = AXUIElementCreateApplication(pid)
            guard budget.arm(app) else { complete = false; break }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let axWindows = value as? [AXUIElement] else {
                // Unrelated inaccessible apps must not prevent restoring an accessible recorded app.
                if frontmostOnly { complete = false }
                continue
            }
            if axWindows.count > 32 { complete = false; continue }
            for element in axWindows {
                guard !budget.isExhausted else { complete = false; break }
                guard string(element, kAXSubroleAttribute, budget: budget) == kAXStandardWindowSubrole as String,
                      bool(element, kAXMinimizedAttribute, budget: budget) == false,
                      bool(element, "AXFullScreen", budget: budget) == false,
                      let frame = frame(element, budget: budget), VirtualDisplayWindowPolicy.valid(frame) else { continue }
                let identifier = string(element, kAXIdentifierAttribute, budget: budget).flatMap { $0.isEmpty ? nil : $0 }
                let proven = provenBindings.filter { identity, bound in
                    identity.pid == pid && identity.launchTime == launch.timeIntervalSince1970
                        && identity.axIdentifier == identifier && CFEqual(bound, element)
                        && visible.contains(where: { row in
                            (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                                && (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == identity.windowID
                        })
                }
                if proven.count == 1, let identity = proven.keys.first {
                    guard elements[identity] == nil else { complete = false; continue }
                    elements[identity] = element
                    windows.append(.init(identity: identity, frame: frame))
                    continue
                }
                if !proven.isEmpty { complete = false; continue }
                let matches = visible.filter { row in
                    guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                          let dictionary = row[kCGWindowBounds as String] as? [String: Any],
                          let cgFrame = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
                    return VirtualDisplayWindowPolicy.close(frame, cgFrame)
                }
                guard matches.count == 1, let number = matches[0][kCGWindowNumber as String] as? NSNumber else { continue }
                let identity = VirtualDisplayWindowIdentity(pid: pid, launchTime: launch.timeIntervalSince1970, windowID: number.uint32Value, axIdentifier: identifier)
                if elements[identity] != nil { complete = false; continue }
                elements[identity] = element
                provenBindings[identity] = element
                windows.append(.init(identity: identity, frame: frame))
            }
        }
        return .init(windows: windows, complete: complete && !budget.isExhausted, stageManagerEnabled: stageManager,
                     closedIdentities: closedIdentities)
    }

    func setFrame(_ frame: CGRect, identity: VirtualDisplayWindowIdentity, budget: HostAXBudget) -> Bool {
        guard !(UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false),
              !requireFrontmost || NSWorkspace.shared.frontmostApplication?.processIdentifier == identity.pid,
              let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              visible.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == identity.windowID
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == identity.pid }),
              let element = elements[identity], let app = NSRunningApplication(processIdentifier: identity.pid),
              app.launchDate?.timeIntervalSince1970 == identity.launchTime,
              bool(element, kAXMinimizedAttribute, budget: budget) == false,
              bool(element, "AXFullScreen", budget: budget) == false else { return false }
        var size = frame.size, point = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let pointValue = AXValueCreate(.cgPoint, &point), budget.arm(element) else { return false }
        let sized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        guard budget.arm(element) else { return false }
        let positioned = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pointValue)
        return sized == .success && positioned == .success
    }

    private func attribute(_ element: AXUIElement, _ key: String, budget: HostAXBudget) -> CFTypeRef? {
        guard budget.arm(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    private func string(_ element: AXUIElement, _ key: String, budget: HostAXBudget) -> String? { attribute(element, key, budget: budget) as? String }
    private func bool(_ element: AXUIElement, _ key: String, budget: HostAXBudget) -> Bool? { (attribute(element, key, budget: budget) as? NSNumber)?.boolValue }
    private func frame(_ element: AXUIElement, budget: HostAXBudget) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute, budget: budget), let size = attribute(element, kAXSizeAttribute, budget: budget),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
