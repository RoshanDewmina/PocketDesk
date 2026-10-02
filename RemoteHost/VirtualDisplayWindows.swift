import AppKit
import ApplicationServices
import ColorSync

protocol VirtualDisplayWindowAccess: AnyObject, Sendable {
    func snapshot(frontmostOnly: Bool, identities: [VirtualDisplayWindowIdentity], budget: HostAXBudget) -> VirtualDisplayWindowSnapshot
    func workspaceSnapshot(identities: [VirtualDisplayWindowIdentity], budget: HostAXBudget) -> VirtualDisplayWindowSnapshot
    func physicalTopology() -> [VirtualDisplayProtectedDisplay]?
    func matchesOwnedDisplay(_ identity: VirtualDisplayWindowOwnedDisplayIdentity, virtualBounds: CGRect?) -> Bool
    func workspaceTopologyMatches(_ protected: [VirtualDisplayProtectedDisplay], virtualBounds: CGRect,
                                  ownedDisplay: VirtualDisplayWindowOwnedDisplayIdentity) -> Bool
    func setFrame(_ frame: CGRect, identity: VirtualDisplayWindowIdentity, budget: HostAXBudget) -> Bool
    func setFrame(_ frame: CGRect, identity: VirtualDisplayWindowIdentity, budget: HostAXBudget,
                  whileCurrent: @escaping @Sendable () -> Bool) -> Bool
}

extension VirtualDisplayWindowAccess {
    func workspaceTopologyMatches(_ protected: [VirtualDisplayProtectedDisplay], virtualBounds: CGRect,
                                  ownedDisplay: VirtualDisplayWindowOwnedDisplayIdentity) -> Bool {
        guard matchesOwnedDisplay(ownedDisplay, virtualBounds: virtualBounds), let current = physicalTopology() else { return false }
        return VirtualDisplayWindowPolicy.workspaceTopologyMatches(protected, current: current, virtualBounds: virtualBounds,
            ownedDisplayUUID: ownedDisplay.uuid) && matchesOwnedDisplay(ownedDisplay, virtualBounds: virtualBounds)
    }

    func setFrame(_ frame: CGRect, identity: VirtualDisplayWindowIdentity, budget: HostAXBudget,
                  whileCurrent: @escaping @Sendable () -> Bool) -> Bool {
        whileCurrent() && setFrame(frame, identity: identity, budget: budget)
    }
}

/// Host boundaries revoke synchronously. This token cannot be renewed or reused for another session.
final class VirtualDisplayWindowOperationAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    var isCurrent: Bool { lock.withLock { current } }
    func revoke() { lock.withLock { current = false } }
}

protocol VirtualDisplayWindowJournalStore: AnyObject, Sendable {
    func load() throws -> VirtualDisplayWindowJournal?
    func save(_ journal: VirtualDisplayWindowJournal) throws
    func remove() throws
}

enum VirtualDisplayWindowError: Error {
    case unsupported, pendingRestore, unmovable, invalidBounds, staleOperation
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
    private var preparedSession: UUID?
    // Unlike enrollment authority, this local origin survives failure/cancellation for cleanup.
    // Loading a receipt never grants permission to bind a newly discovered display.
    private var locallyCreatedSession: UUID?
    private var ownedBinding: (session: UUID, identity: VirtualDisplayWindowOwnedDisplayIdentity)?
    private var activeSession: UUID?
    private var activeBounds: CGRect?
    private struct WorkspaceSeal {
        let session: UUID
        let bounds: CGRect
        let physicalBounds: CGRect
        let ownedDisplay: VirtualDisplayWindowOwnedDisplayIdentity
    }
    private var retirementSeal: WorkspaceSeal?
    private var resizeSeal: WorkspaceSeal?
    private var sealBlocked = false

    convenience init(journalURL: URL? = nil) {
        let url = journalURL ?? Self.defaultJournalURL
        self.init(access: LiveVirtualDisplayWindowAccess(), store: FileVirtualDisplayWindowJournalStore(url: url))
    }

    init(access: VirtualDisplayWindowAccess, store: VirtualDisplayWindowJournalStore) {
        self.access = access
        self.store = store
        do {
            journal = try store.load()
            if let journal, ![1, 2].contains(journal.version)
                || (journal.version == 1 && journal.protectedDisplays != nil)
                || (journal.version == 2 && journal.protectedDisplays.map(VirtualDisplayWindowPolicy.validTopology) != true)
                || journal.records.count > VirtualDisplayWindowPolicy.maximumWindows
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
    func prepareFrontmostWindows() async throws { try await prepareWorkspaceWindows() }

    /// All uniquely attributable, movable standard windows in currently reachable Spaces, <=32.
    /// No activation, fullscreen exit, unminimizing or arbitrary Space transaction is attempted.
    func prepareWorkspaceWindows(whileCurrent: @escaping @Sendable () -> Bool = { true }) async throws {
        try await run {
            try self.requireCurrent(whileCurrent)
            guard !self.loadFailed, self.journal == nil else { throw VirtualDisplayWindowError.pendingRestore }
            guard let topology = self.access.physicalTopology(), VirtualDisplayWindowPolicy.validTopology(topology) else {
                throw VirtualDisplayWindowError.unsupported
            }
            let snapshot = self.access.workspaceSnapshot(identities: [], budget: HostAXBudget(total: 1.5))
            guard VirtualDisplayWindowPolicy.validEnrollment(snapshot),
                  let confirmed = self.access.physicalTopology(), VirtualDisplayWindowPolicy.sameTopology(topology, confirmed) else {
                throw VirtualDisplayWindowError.unsupported
            }
            let records = snapshot.windows.sorted(by: self.windowOrder).map { window in
                VirtualDisplayWindowJournal.Record(identity: window.identity, original: window.frame,
                    requested: window.frame, applied: nil, virtualBounds: [])
            }
            let journal = VirtualDisplayWindowJournal(version: 2, records: records, protectedDisplays: topology)
            try self.requireCurrent(whileCurrent)
            try self.store.save(journal)
            self.journal = journal
            self.locallyCreatedSession = journal.session
            self.markPending()
            try self.requireCurrent(whileCurrent)
            self.preparedSession = journal.session
        }
    }

    /// Bind after adapter creation and before migration/sealing. Only identical rebinding is legal.
    /// Cleanup may use its own operation predicate after enrollment has been revoked.
    func bindOwnedDisplay(_ identity: VirtualDisplayWindowOwnedDisplayIdentity,
                          whileCurrent: @escaping @Sendable () -> Bool = { true }) async throws {
        try await run {
            try self.requireCurrent(whileCurrent)
            guard !self.loadFailed, let journal = self.journal, journal.version == 2,
                  self.locallyCreatedSession == journal.session,
                  journal.protectedDisplays?.contains(where: { $0.uuid == identity.uuid }) == false else {
                throw VirtualDisplayWindowError.pendingRestore
            }
            if let bound = self.ownedBinding {
                guard bound.session == journal.session, bound.identity == identity else { throw VirtualDisplayWindowError.staleOperation }
            }
            guard self.access.matchesOwnedDisplay(identity, virtualBounds: nil) else { throw VirtualDisplayWindowError.staleOperation }
            try self.requireCurrent(whileCurrent)
            self.ownedBinding = (journal.session, identity)
        }
    }

    func moveFrontmostWindows(to bounds: CGRect) async throws { try await moveWindows(to: bounds, allowUnprepared: true, whileCurrent: { true }) }

    func moveWorkspaceWindows(to bounds: CGRect, whileCurrent: @escaping @Sendable () -> Bool = { true }) async throws {
        try await moveWindows(to: bounds, allowUnprepared: false, whileCurrent: whileCurrent)
    }

    private func moveWindows(to bounds: CGRect, allowUnprepared: Bool, whileCurrent: @escaping @Sendable () -> Bool) async throws {
        try await run {
            try self.requireCurrent(whileCurrent)
            guard !self.loadFailed, (allowUnprepared && self.journal == nil) || (self.journal?.isPrepared == true && self.preparedSession == self.journal?.session) else {
                throw VirtualDisplayWindowError.pendingRestore
            }
            guard VirtualDisplayWindowPolicy.valid(bounds) else { throw VirtualDisplayWindowError.invalidBounds }
            let admitted = self.workspacePredicate(journal: self.journal, bounds: bounds, whileCurrent: whileCurrent)
            try self.requireCurrent(admitted)
            let snapshot = self.journal == nil
                ? self.access.workspaceSnapshot(identities: [], budget: HostAXBudget(total: 1.5))
                : self.access.snapshot(frontmostOnly: false, identities: self.journal!.records.map(\.identity), budget: HostAXBudget(total: 1.5))
            guard VirtualDisplayWindowPolicy.validEnrollment(snapshot) else { throw VirtualDisplayWindowError.unsupported }
            var journal: VirtualDisplayWindowJournal
            if var prepared = self.journal {
                for index in prepared.records.indices {
                    guard snapshot.windows.filter({ $0.identity == prepared.records[index].identity }).count == 1 else { throw VirtualDisplayWindowError.unsupported }
                    prepared.records[index].requested = VirtualDisplayWindowPolicy.destination(for: prepared.records[index].original, in: bounds, index: index)
                    prepared.records[index].virtualBounds = [bounds]
                }
                journal = prepared
            } else {
                // Compatibility direct move has no precreation evidence; keep historical v1.
                // The host workspace path must call prepareWorkspaceWindows before creation.
                let records = snapshot.windows.sorted(by: self.windowOrder).enumerated().map { index, window in
                    VirtualDisplayWindowJournal.Record(identity: window.identity, original: window.frame,
                        requested: VirtualDisplayWindowPolicy.destination(for: window.frame, in: bounds, index: index), applied: nil, virtualBounds: [bounds])
                }
                journal = VirtualDisplayWindowJournal(records: records)
            }
            guard VirtualDisplayWindowPolicy.distinctFrames(journal.records.map(\.requested)) else { throw VirtualDisplayWindowError.unsupported }
            try self.requireCurrent(admitted)
            try self.store.save(journal)
            self.journal = journal
            self.markPending()
            try self.apply(bounds: bounds, whileCurrent: admitted)
            self.preparedSession = nil
            self.activeSession = journal.session
            self.activeBounds = bounds
        }
    }

    /// Compatibility seam. A new window already on the virtual display requires an explicit
    /// physical return anchor through refreshWorkspace and cannot enroll through this helper.
    func includeFrontmostWindows(to bounds: CGRect) async throws {
        try await refreshWorkspace(to: bounds, physicalFallbackBounds: nil)
    }

    /// Caller polls single-flight only while the authenticated owned workspace is active.
    /// Existing windows are never remigrated. A new window overlapping virtual bounds receives
    /// a chosen physical return frame, since no pre-session physical original can be known.
    func refreshWorkspace(to bounds: CGRect, physicalFallbackBounds: CGRect?,
                          whileCurrent: @escaping @Sendable () -> Bool = { true }) async throws {
        try await run {
            try self.requireCurrent(whileCurrent)
            guard !self.loadFailed else { throw VirtualDisplayWindowError.pendingRestore }
            guard VirtualDisplayWindowPolicy.valid(bounds) else { throw VirtualDisplayWindowError.invalidBounds }
            if let physicalFallbackBounds, !VirtualDisplayWindowPolicy.valid(physicalFallbackBounds) { throw VirtualDisplayWindowError.invalidBounds }
            guard var journal = self.journal, self.activeSession == journal.session, self.activeBounds == bounds,
                  !journal.isPrepared else { throw VirtualDisplayWindowError.pendingRestore }
            let admitted = self.workspacePredicate(journal: journal, bounds: bounds, whileCurrent: whileCurrent)
            try self.requireCurrent(admitted)
            let snapshot = self.access.workspaceSnapshot(identities: journal.records.map(\.identity), budget: HostAXBudget(total: 1.5))
            guard VirtualDisplayWindowPolicy.validEnrollment(snapshot, allowEmpty: true) else { throw VirtualDisplayWindowError.unsupported }
            let oldCount = journal.records.count
            journal.records.removeAll { record in
                snapshot.closedIdentities.contains(record.identity) && !snapshot.windows.contains(where: { $0.identity == record.identity })
            }
            let existing = Set(journal.records.map(\.identity))
            let additions = snapshot.windows.filter { !existing.contains($0.identity) }.sorted(by: self.windowOrder)
            guard !additions.isEmpty || oldCount != journal.records.count else { return }
            guard journal.records.count + additions.count <= VirtualDisplayWindowPolicy.maximumWindows else { throw VirtualDisplayWindowError.unsupported }
            var occupied = journal.records.map(\.requested) + snapshot.windows.filter { existing.contains($0.identity) }.map(\.frame)
            journal.records += try additions.map { window in
                if bounds.intersects(window.frame) && physicalFallbackBounds == nil { throw VirtualDisplayWindowError.unsupported }
                guard let index = (0..<VirtualDisplayWindowPolicy.maximumWindows).first(where: { index in
                    let candidate = VirtualDisplayWindowPolicy.destination(for: window.frame, in: bounds, index: index)
                    return occupied.allSatisfy { !VirtualDisplayWindowPolicy.sameOrigin(candidate, $0) }
                }) else { throw VirtualDisplayWindowError.unsupported }
                let requested = VirtualDisplayWindowPolicy.destination(for: window.frame, in: bounds, index: index)
                occupied.append(requested)
                let original = physicalFallbackBounds.map {
                    VirtualDisplayWindowPolicy.enrollmentReturnFrame(window.frame, virtualBounds: bounds, physicalBounds: $0, index: index)
                } ?? window.frame
                return VirtualDisplayWindowJournal.Record(identity: window.identity, original: original,
                    requested: requested,
                    applied: nil, virtualBounds: [bounds])
            }
            try self.requireCurrent(admitted)
            try self.store.save(journal)
            self.journal = journal
            self.markPending()
            try self.requireCurrent(admitted)
            if !additions.isEmpty { try self.apply(bounds: bounds, moving: Set(additions.map(\.identity)), whileCurrent: admitted) }
        }
    }

    func resize(to bounds: CGRect, whileCurrent: @escaping @Sendable () -> Bool = { true }) async throws {
        try await run {
            try self.requireCurrent(whileCurrent)
            guard VirtualDisplayWindowPolicy.valid(bounds) else { throw VirtualDisplayWindowError.invalidBounds }
            guard !self.loadFailed, var journal = self.journal, self.activeSession == journal.session, !journal.isPrepared else {
                throw VirtualDisplayWindowError.pendingRestore
            }
            if journal.version == 2 {
                guard let seal = self.resizeSeal, seal.session == journal.session,
                      seal.ownedDisplay == self.ownedBinding?.identity else { throw VirtualDisplayWindowError.pendingRestore }
                // Catch a window born after the pre-adapter seal, before the first AX resize.
                _ = try self.sealOnQueue(bounds: bounds, physicalBounds: seal.physicalBounds,
                                         retiring: false, whileCurrent: whileCurrent)
                journal = self.journal!
            }
            let admitted = self.workspacePredicate(journal: journal, bounds: bounds, whileCurrent: whileCurrent)
            try self.requireCurrent(admitted)
            let snapshot = self.access.snapshot(frontmostOnly: false, identities: journal.records.map(\.identity), budget: HostAXBudget(total: 1.5))
            guard snapshot.complete, !snapshot.stageManagerEnabled else { throw VirtualDisplayWindowError.unsupported }
            journal.records.removeAll { record in
                snapshot.closedIdentities.contains(record.identity) && !snapshot.windows.contains(where: { $0.identity == record.identity })
            }
            for index in journal.records.indices {
                let record = journal.records[index]
                let matches = snapshot.windows.filter { $0.identity == record.identity }
                guard matches.count == 1, VirtualDisplayWindowPolicy.valid(matches[0].frame) else {
                    throw VirtualDisplayWindowError.unmovable
                }
                journal.records[index].requested = VirtualDisplayWindowPolicy.destination(for: matches[0].frame, in: bounds, index: index)
                if !journal.records[index].virtualBounds.contains(bounds) { journal.records[index].virtualBounds.append(bounds)
                    journal.records[index].virtualBounds = Array(journal.records[index].virtualBounds.suffix(8))
                }
            }
            guard VirtualDisplayWindowPolicy.distinctFrames(journal.records.map(\.requested)) else { throw VirtualDisplayWindowError.unsupported }
            try self.requireCurrent(admitted)
            try self.store.save(journal)
            self.journal = journal
            self.markPending()
            if !journal.records.isEmpty { try self.apply(bounds: bounds, whileCurrent: admitted) }
            try self.requireCurrent(admitted)
            self.activeBounds = bounds
            self.resizeSeal = nil
        }
    }

    /// Await BEFORE the adapter changes its mode. Persists new return records without AX moves.
    func sealWorkspaceForResize(to bounds: CGRect, physicalFallbackBounds: CGRect,
                                whileCurrent: @escaping @Sendable () -> Bool = { true }) async throws {
        try await run {
            _ = try self.sealOnQueue(bounds: bounds, physicalBounds: physicalFallbackBounds,
                                     retiring: false, whileCurrent: whileCurrent)
        }
    }

    /// Cleanup uses its own current-operation proof; revoked enrollment never blocks safe cleanup.
    /// Incomplete/unsupported inventory or overflow blocks restoration/removal and retains receipts.
    func sealWorkspaceForRetirement(to bounds: CGRect, physicalFallbackBounds: CGRect,
                                    whileCurrent: @escaping @Sendable () -> Bool = { true }) async throws {
        try await run {
            self.retireEnrollment()
            _ = try self.sealOnQueue(bounds: bounds, physicalBounds: physicalFallbackBounds,
                                     retiring: true, whileCurrent: whileCurrent)
        }
    }

    /// Must follow successful restoration immediately before adapter removal. No AX writes.
    /// Public inventory and window creation are not atomic; this proves only the observed subset.
    func verifyWorkspaceRemoval(to bounds: CGRect, physicalFallbackBounds: CGRect,
                                whileCurrent: @escaping @Sendable () -> Bool = { true }) async throws -> Bool {
        try await run {
            guard let journal = self.journal, journal.version == 2,
                  let seal = self.retirementSeal, seal.session == journal.session, seal.bounds == bounds,
                  seal.physicalBounds == physicalFallbackBounds,
                  seal.ownedDisplay == self.ownedBinding?.identity else { throw VirtualDisplayWindowError.pendingRestore }
            let result = try self.sealOnQueue(bounds: bounds, physicalBounds: physicalFallbackBounds,
                                              retiring: true, whileCurrent: whileCurrent)
            guard !result.additions.contains(where: { identity in
                result.snapshot.windows.contains { $0.identity == identity && bounds.intersects($0.frame) }
            }), let current = self.journal else { return false }
            for record in current.records {
                let matches = result.snapshot.windows.filter { $0.identity == record.identity }
                if matches.isEmpty && result.snapshot.closedIdentities.contains(record.identity) { continue }
                guard matches.count == 1, matches[0].frame == record.original else { return false }
            }
            try self.requireCurrent(self.workspacePredicate(journal: current, bounds: bounds, whileCurrent: whileCurrent))
            // Keep the complete receipt across adapter.stop's suspension/failure. Only a later
            // confirmedRemoved restoration (or strict cold recovery) may retire it.
            return true
        }
    }

    private func sealOnQueue(bounds: CGRect, physicalBounds: CGRect, retiring: Bool,
                             whileCurrent: @escaping @Sendable () -> Bool) throws -> (snapshot: VirtualDisplayWindowSnapshot, additions: Set<VirtualDisplayWindowIdentity>) {
        guard !loadFailed, var journal else { throw VirtualDisplayWindowError.pendingRestore }
        guard journal.version == 2 else { return (.init(windows: [], complete: true, stageManagerEnabled: false), []) }
        sealBlocked = true; markPending()
        guard VirtualDisplayWindowPolicy.valid(bounds), VirtualDisplayWindowPolicy.valid(physicalBounds) else { throw VirtualDisplayWindowError.invalidBounds }
        if !retiring {
            guard activeSession == journal.session else { throw VirtualDisplayWindowError.pendingRestore }
        }
        let admitted = workspacePredicate(journal: journal, bounds: bounds, whileCurrent: whileCurrent)
        try requireCurrent(admitted)
        let snapshot = access.workspaceSnapshot(identities: journal.records.map(\.identity), budget: HostAXBudget(total: 1.5))
        guard VirtualDisplayWindowPolicy.validEnrollment(snapshot, allowEmpty: true) else { throw VirtualDisplayWindowError.unsupported }
        journal.records.removeAll { record in
            snapshot.closedIdentities.contains(record.identity) && !snapshot.windows.contains(where: { $0.identity == record.identity })
        }
        let recorded = Set(journal.records.map(\.identity))
        let additions = snapshot.windows.filter { !recorded.contains($0.identity) }.sorted(by: windowOrder)
        guard journal.records.count + additions.count <= VirtualDisplayWindowPolicy.maximumWindows else { throw VirtualDisplayWindowError.unsupported }
        let first = journal.records.count
        journal.records += additions.enumerated().map { index, window in
            .init(identity: window.identity,
                  original: VirtualDisplayWindowPolicy.enrollmentReturnFrame(window.frame, virtualBounds: bounds, physicalBounds: physicalBounds, index: first + index),
                  requested: window.frame, applied: nil, virtualBounds: [bounds])
        }
        // Creation itself can reflow prepared windows, even if the first migration never ran.
        for index in journal.records.indices where journal.records[index].virtualBounds.isEmpty {
            journal.records[index].virtualBounds = [bounds]
        }
        try requireCurrent(admitted)
        try store.save(journal)
        self.journal = journal; markPending()
        try requireCurrent(admitted)
        guard let ownedDisplay = ownedBinding?.identity else { throw VirtualDisplayWindowError.pendingRestore }
        let seal = WorkspaceSeal(session: journal.session, bounds: bounds, physicalBounds: physicalBounds, ownedDisplay: ownedDisplay)
        if retiring { retirementSeal = seal } else { resizeSeal = seal }
        sealBlocked = false; markPending()
        return (snapshot, Set(additions.map(\.identity)))
    }

    /// Without the host's explicit live-display proof, v2 restoration requires the exact
    /// precreation inventory (the cold/removed-display case). v1 keeps its historical helper.
    func restore() async -> Bool {
        (try? await run {
            if let journal = self.journal, journal.version == 2 {
                guard let protected = journal.protectedDisplays else { self.retireEnrollment(); return false }
                return self.restoreOnQueue(recoverOriginals: true, whileCurrent: {
                    guard let current = self.access.physicalTopology() else { return false }
                    return VirtualDisplayWindowPolicy.sameTopology(protected, current)
                })
            }
            return self.restoreOnQueue()
        }) ?? false
    }
    /// Host teardown always returns enrolled windows to saved originals, including manual drags.
    /// Unknown display/topology evidence leaves the journal untouched and performs no AX work.
    func restore(after evidence: SessionVirtualDisplayPresence, physicalTopologyUnchanged: Bool) async -> Bool {
        (try? await run {
            self.retireEnrollment()
            guard !self.loadFailed,
                  VirtualDisplayRestorationPolicy.action(presence: evidence,
                    physicalTopologyUnchanged: physicalTopologyUnchanged,
                    journalIsPrepared: self.journal?.isPrepared == true) == .restoreOriginals else { return false }
            if let journal = self.journal, journal.version == 2 {
                guard let protected = journal.protectedDisplays else { return false }
                if evidence == .present {
                    guard !self.sealBlocked, let seal = self.retirementSeal, seal.session == journal.session,
                          seal.ownedDisplay == self.ownedBinding?.identity else { return false }
                    return self.restoreOnQueue(recoverOriginals: true,
                        whileCurrent: self.workspacePredicate(journal: journal, bounds: seal.bounds, whileCurrent: { true }),
                        retainCompletedJournal: true, retirement: seal)
                }
                return self.restoreOnQueue(recoverOriginals: true, whileCurrent: {
                    guard let current = self.access.physicalTopology() else { return false }
                    return VirtualDisplayWindowPolicy.protectedTopologyMatches(protected, current: current, allowOwnedDisplay: evidence == .present)
                })
            }
            return self.restoreOnQueue(recoverOriginals: true)
        }) ?? false
    }
    /// A process-owned display disappearing can reflow surviving windows to any physical frame.
    /// Recovery uses the persisted original after exact launch/CG/AX attribution. The standalone
    /// ordinary restore helper retains its prior manual-drag behavior for its other callers.
    func recover() async -> Bool {
        (try? await run {
            self.retireEnrollment()
            guard !self.loadFailed else { return false }
            if let journal = self.journal, journal.version == 2 {
                guard let protected = journal.protectedDisplays, let current = self.access.physicalTopology(),
                      VirtualDisplayWindowPolicy.sameTopology(protected, current) else { return false }
                return self.restoreOnQueue(recoverOriginals: true, whileCurrent: {
                    guard let current = self.access.physicalTopology() else { return false }
                    return VirtualDisplayWindowPolicy.sameTopology(protected, current)
                })
            }
            // v1 compatibility has no persisted topology; it retains the historical B8 limitation.
            return self.restoreOnQueue(recoverOriginals: true)
        }) ?? false
    }

    private func apply(bounds: CGRect, moving: Set<VirtualDisplayWindowIdentity>? = nil,
                       whileCurrent: @escaping @Sendable () -> Bool) throws {
        guard let journal else { return }
        let budget = HostAXBudget(total: 2)
        var succeeded = true
        for record in journal.records where moving?.contains(record.identity) ?? true {
            try requireCurrent(whileCurrent)
            let applied = access.setFrame(record.requested, identity: record.identity, budget: budget, whileCurrent: whileCurrent)
            try requireCurrent(whileCurrent)
            if !applied { succeeded = false; break }
        }
        try requireCurrent(whileCurrent)
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
        do { try store.save(updated) } catch {
            _ = restoreOnQueue(recoverOriginals: true, whileCurrent: whileCurrent, retainCompletedJournal: updated.version == 2)
            throw error
        }
        try requireCurrent(whileCurrent)
        if !succeeded {
            _ = restoreOnQueue(recoverOriginals: true, whileCurrent: whileCurrent, retainCompletedJournal: updated.version == 2)
            throw VirtualDisplayWindowError.unmovable
        }
    }

    private func restoreOnQueue(recoverOriginals: Bool = false, whileCurrent: @escaping @Sendable () -> Bool = { true },
                                retainCompletedJournal: Bool = false, retirement: WorkspaceSeal? = nil) -> Bool {
        retireEnrollment()
        guard whileCurrent() else { return false }
        guard !loadFailed else { return false }
        guard var journal else { return true }
        let snapshot = access.snapshot(frontmostOnly: false, identities: journal.records.map(\.identity), budget: HostAXBudget(total: 1.5))
        guard snapshot.complete, !snapshot.stageManagerEnabled else { return false }
        let budget = HostAXBudget(total: 2)
        var remaining: [VirtualDisplayWindowJournal.Record] = []
        var toVerify: [VirtualDisplayWindowJournal.Record] = []
        for record in journal.records {
            guard whileCurrent() else { return false }
            let matches = snapshot.windows.filter { $0.identity == record.identity }
            if matches.isEmpty && snapshot.closedIdentities.contains(record.identity) { continue }
            guard matches.count == 1 else { remaining.append(record); continue }
            let current = matches[0].frame
            guard VirtualDisplayWindowPolicy.valid(current) else { remaining.append(record); continue }
            guard recoverOriginals || journal.version == 2 || VirtualDisplayWindowPolicy.shouldRestore(record, current: current) else { continue }
            if current == record.original { toVerify.append(record); continue }
            guard access.setFrame(record.original, identity: record.identity, budget: budget, whileCurrent: whileCurrent) else { remaining.append(record); continue }
            toVerify.append(record)
        }
        if !toVerify.isEmpty {
            let verified = access.snapshot(frontmostOnly: false, identities: journal.records.map(\.identity), budget: HostAXBudget(total: 1.5))
            for record in toVerify {
                let result = verified.windows.filter { $0.identity == record.identity }
                if !verified.complete || result.count != 1 || result[0].frame != record.original { remaining.append(record) }
            }
        }
        guard whileCurrent() else { return false }
        if let retirement {
            do {
                let observed = try sealOnQueue(bounds: retirement.bounds, physicalBounds: retirement.physicalBounds,
                                              retiring: true, whileCurrent: whileCurrent)
                // Newly observed windows must take another restoration pass before removal.
                if !observed.additions.isEmpty { return false }
            } catch { return false }
        }
        if retainCompletedJournal {
            // Keep all originals, including already restored records, until final removal inventory.
            markPending()
            return remaining.isEmpty
        }
        journal.records = remaining
        do {
            if remaining.isEmpty {
                try store.remove(); self.journal = nil; sealBlocked = false; retirementSeal = nil; resizeSeal = nil
                ownedBinding = nil; locallyCreatedSession = nil
            }
            else { try store.save(journal); self.journal = journal }
        } catch { markPending(); return false }
        markPending()
        return remaining.isEmpty
    }

    private func retireEnrollment() { preparedSession = nil; activeSession = nil; activeBounds = nil }
    private func workspacePredicate(journal: VirtualDisplayWindowJournal?, bounds: CGRect,
                                    whileCurrent: @escaping @Sendable () -> Bool) -> @Sendable () -> Bool {
        guard let journal, journal.version == 2 else { return whileCurrent }
        guard let binding = ownedBinding, binding.session == journal.session else { return { false } }
        return {
            guard whileCurrent(), let protected = journal.protectedDisplays else { return false }
            return self.access.workspaceTopologyMatches(protected, virtualBounds: bounds, ownedDisplay: binding.identity)
        }
    }
    private func requireCurrent(_ predicate: @Sendable () -> Bool) throws {
        guard predicate() else { retireEnrollment(); throw VirtualDisplayWindowError.staleOperation }
    }
    private func windowOrder(_ a: VirtualDisplayWindow, _ b: VirtualDisplayWindow) -> Bool {
        a.identity.pid == b.identity.pid ? a.identity.windowID < b.identity.windowID : a.identity.pid < b.identity.pid
    }

    private func markPending() { lock.withLock { pending = loadFailed || sealBlocked || !(journal?.records.isEmpty ?? true) } }
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
        snapshot(frontmostOnly: frontmostOnly, includeAll: false, identities: identities, budget: budget)
    }

    func workspaceSnapshot(identities: [VirtualDisplayWindowIdentity], budget: HostAXBudget) -> VirtualDisplayWindowSnapshot {
        snapshot(frontmostOnly: false, includeAll: true, identities: identities, budget: budget)
    }

    func matchesOwnedDisplay(_ identity: VirtualDisplayWindowOwnedDisplayIdentity, virtualBounds: CGRect?) -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0, count <= 32 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let expected = count
        guard CGGetOnlineDisplayList(expected, &ids, &count) == .success, count == expected,
              ids.contains(identity.displayID) else { return false }
        let id = identity.displayID
        guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return false }
        let uuid = UUID(uuidString: CFUUIDCreateString(nil, value) as String)
        return VirtualDisplayWindowPolicy.ownedDisplayMatches(identity, displayID: id, uuid: uuid,
            vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
            online: true, main: CGDisplayIsMain(id) != 0,
            mirrored: CGDisplayIsInMirrorSet(id) != 0 || CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay,
            bounds: CGDisplayBounds(id), expectedBounds: virtualBounds)
    }

    func physicalTopology() -> [VirtualDisplayProtectedDisplay]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0, count <= 32 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let expected = count
        guard CGGetOnlineDisplayList(expected, &ids, &count) == .success, count == expected else { return nil }
        func uuid(_ id: CGDirectDisplayID) -> UUID? {
            guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            return UUID(uuidString: CFUUIDCreateString(nil, value) as String)
        }
        var displays: [VirtualDisplayProtectedDisplay] = []
        for id in ids {
            guard let stable = uuid(id), let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            let mirror = CGDisplayMirrorsDisplay(id)
            let mirrorUUID = mirror == kCGNullDirectDisplay ? nil : uuid(mirror)
            guard mirror == kCGNullDirectDisplay || mirrorUUID != nil else { return nil }
            displays.append(.init(uuid: stable, bounds: CGDisplayBounds(id), width: mode.width, height: mode.height,
                pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, modeID: UInt32(bitPattern: mode.ioDisplayModeID),
                modeFlags: mode.ioFlags, refresh: mode.refreshRate, rotation: CGDisplayRotation(id),
                main: CGDisplayIsMain(id) != 0, mirrored: CGDisplayIsInMirrorSet(id) != 0, mirrorTarget: mirrorUUID))
        }
        var confirmed: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &confirmed) == .success, confirmed == expected,
              VirtualDisplayWindowPolicy.validTopology(displays) else { return nil }
        return displays
    }

    private func snapshot(frontmostOnly: Bool, includeAll: Bool, identities: [VirtualDisplayWindowIdentity], budget: HostAXBudget) -> VirtualDisplayWindowSnapshot {
        elements = [:]
        requireFrontmost = frontmostOnly
        let stageManager = UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
        guard !stageManager, let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return .init(windows: [], complete: false, stageManagerEnabled: stageManager)
        }
        // The on-screen list omits other Spaces and minimized windows. Only the public all-window
        // list can establish closure; AX failure or absence from the visible list cannot do so.
        var allInfo = includeAll || !identities.isEmpty
            ? CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] : nil
        if allInfo?.isEmpty == true, identities.contains(where: { identity in
            NSRunningApplication(processIdentifier: identity.pid)?.launchDate?.timeIntervalSince1970 == identity.launchTime
        }) { allInfo = nil } // An unavailable GUI inventory cannot establish closure.
        let closedIdentities = Set(identities.filter { identity in
            let app = NSRunningApplication(processIdentifier: identity.pid)
            let ids: Set<UInt32>? = allInfo.flatMap { rows in
                VirtualDisplayWorkspaceInventoryPolicy.closureIDs(rows.map { row in
                    .init(pid: positiveID(row[kCGWindowOwnerPID as String], maximum: UInt32(Int32.max)).map(Int32.init),
                          windowID: positiveID(row[kCGWindowNumber as String]))
                }, pid: identity.pid)
            }
            return VirtualDisplayWindowPolicy.isDefinitivelyClosed(identity, processExists: app != nil,
                currentLaunchTime: app?.launchDate?.timeIntervalSince1970, allWindowIDs: ids)
        })
        for identity in closedIdentities { provenBindings[identity] = nil }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var complete = true
        let visible = info.filter { row in
            let layer = row[kCGWindowLayer as String] as? NSNumber
            let alpha = row[kCGWindowAlpha as String] as? NSNumber
            let validLayer = layer.map { $0.doubleValue.isFinite && $0.doubleValue.rounded(.towardZero) == $0.doubleValue
                && $0.doubleValue >= Double(Int32.min) && $0.doubleValue <= Double(Int32.max) } ?? false
            if validLayer, let layer, layer.intValue != 0 { return false }
            if let alpha, alpha.doubleValue.isFinite, alpha.doubleValue <= 0 { return false }
            guard validLayer, let layer, let alpha, alpha.doubleValue.isFinite else {
                if includeAll { complete = false }; return false
            }
            return layer.intValue == 0 && alpha.doubleValue > 0
        }
        let pids = Set(visible.compactMap { row -> Int32? in
            guard let id = positiveID(row[kCGWindowOwnerPID as String], maximum: UInt32(Int32.max)) else {
                if includeAll { complete = false }; return nil
            }
            return Int32(id)
        })
            .filter { pid in
                guard pid != ProcessInfo.processInfo.processIdentifier else { return false }
                guard includeAll else { return frontmostOnly ? pid == frontmostPID : identities.map(\.pid).contains(pid) }
                guard let application = NSRunningApplication(processIdentifier: pid) else { complete = false; return false }
                switch application.activationPolicy {
                case .regular: return true
                case .accessory, .prohibited: return false
                @unknown default: complete = false; return false
                }
            }
        var windows: [VirtualDisplayWindow] = []
        for pid in pids.sorted() {
            guard !budget.isExhausted else { complete = false; break }
            guard let application = NSRunningApplication(processIdentifier: pid), let launch = application.launchDate,
                  launch.timeIntervalSince1970.isFinite else { complete = false; continue }
            guard let publicVisible = publicWindows(visible, pid: pid) else { complete = false; continue }
            let publicAll = allInfo.flatMap { publicWindows($0, pid: pid) }
            let app = AXUIElementCreateApplication(pid)
            guard budget.arm(app) else { complete = false; break }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let axWindows = value as? [AXUIElement] else {
                if includeAll || frontmostOnly { complete = false }
                continue
            }
            if axWindows.count > 128 { complete = false; continue }
            var accountedIDs = Set<UInt32>()
            for element in axWindows {
                guard !budget.isExhausted else { complete = false; break }
                let standard = string(element, kAXSubroleAttribute, budget: budget).flatMap { $0.isEmpty ? nil : $0 == kAXStandardWindowSubrole as String }
                let minimized = standard == false ? nil : bool(element, kAXMinimizedAttribute, budget: budget)
                let fullscreen = standard == false ? nil : bool(element, "AXFullScreen", budget: budget)
                let candidateFrame = includeAll || !(standard == false || minimized == true || fullscreen == true) ? frame(element, budget: budget) : nil
                let needsMoveProof = includeAll && standard == true && minimized == false && fullscreen == false && candidateFrame != nil
                let sizeSettable = needsMoveProof ? settableState(element, kAXSizeAttribute, budget: budget) : nil
                let positionSettable = needsMoveProof ? settableState(element, kAXPositionAttribute, budget: budget) : nil
                switch VirtualDisplayWorkspaceInventoryPolicy.eligibility(standard: standard, minimized: minimized, fullscreen: fullscreen,
                    frame: candidateFrame, sizeSettable: sizeSettable, positionSettable: positionSettable, requireMovable: includeAll) {
                case .outOfScope:
                    if includeAll, let frame = candidateFrame {
                        let boundIDs = provenBindings.filter { identity, bound in
                            identity.pid == pid && identity.launchTime == launch.timeIntervalSince1970 && CFEqual(bound, element)
                        }.keys.map(\.windowID)
                        if boundIDs.count <= 1,
                           case let .matched(id) = VirtualDisplayWorkspaceInventoryPolicy.attribute(frame: frame, onScreen: publicVisible,
                                                                                                    allSpaces: publicAll, provenID: boundIDs.first) {
                            accountedIDs.insert(id)
                        }
                    }
                    continue
                case .unresolved: complete = false; continue
                case .eligible: break
                }
                guard let frame = candidateFrame else { complete = false; continue }
                let identifier = string(element, kAXIdentifierAttribute, budget: budget).flatMap { $0.isEmpty ? nil : $0 }
                let proven = provenBindings.filter { identity, bound in
                    identity.pid == pid && identity.launchTime == launch.timeIntervalSince1970
                        && identity.axIdentifier == identifier && CFEqual(bound, element)
                        && (publicVisible.contains(where: { $0.windowID == identity.windowID })
                            || publicAll?.contains(where: { $0.windowID == identity.windowID }) == true)
                }
                guard proven.count <= 1 else { complete = false; continue }
                let number: UInt32
                switch VirtualDisplayWorkspaceInventoryPolicy.attribute(frame: frame, onScreen: publicVisible, allSpaces: publicAll,
                                                                         provenID: proven.keys.first?.windowID) {
                case .outOfScope: continue
                case .unresolved: complete = false; continue
                case let .matched(id): number = id
                }
                accountedIDs.insert(number)
                let identity = proven.keys.first ?? VirtualDisplayWindowIdentity(pid: pid, launchTime: launch.timeIntervalSince1970, windowID: number, axIdentifier: identifier)
                if elements[identity] != nil { complete = false; continue }
                elements[identity] = element
                provenBindings[identity] = element
                windows.append(.init(identity: identity, frame: frame))
            }
            if includeAll && !VirtualDisplayWorkspaceInventoryPolicy.allVisibleAccounted(publicVisible, accountedIDs: accountedIDs) { complete = false }
        }
        return .init(windows: windows, complete: complete && !budget.isExhausted, stageManagerEnabled: stageManager,
                     closedIdentities: closedIdentities)
    }

    private func publicWindows(_ rows: [[String: Any]], pid: Int32) -> [VirtualDisplayWorkspaceInventoryPolicy.PublicWindow]? {
        var result: [VirtualDisplayWorkspaceInventoryPolicy.PublicWindow] = []
        for row in rows {
            guard let owner = positiveID(row[kCGWindowOwnerPID as String], maximum: UInt32(Int32.max)) else { return nil }
            guard Int32(owner) == pid else { continue }
            guard let layer = row[kCGWindowLayer as String] as? NSNumber, layer.doubleValue.isFinite,
                  layer.doubleValue.rounded(.towardZero) == layer.doubleValue else { return nil }
            guard layer.intValue == 0 else { continue }
            guard let number = positiveID(row[kCGWindowNumber as String]),
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), VirtualDisplayWindowPolicy.valid(frame) else { return nil }
            result.append(.init(windowID: number, frame: frame))
        }
        return Set(result.map(\.windowID)).count == result.count ? result : nil
    }

    private func positiveID(_ value: Any?, maximum: UInt32 = .max) -> UInt32? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite,
              number.doubleValue >= 1, number.doubleValue <= Double(maximum),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.uint32Value
    }

    func setFrame(_ frame: CGRect, identity: VirtualDisplayWindowIdentity, budget: HostAXBudget) -> Bool {
        setFrame(frame, identity: identity, budget: budget, whileCurrent: { true })
    }

    func setFrame(_ frame: CGRect, identity: VirtualDisplayWindowIdentity, budget: HostAXBudget,
                  whileCurrent: @escaping @Sendable () -> Bool) -> Bool {
        guard whileCurrent(), VirtualDisplayWindowPolicy.valid(frame) else { return false }
        guard !(UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false),
              !requireFrontmost || NSWorkspace.shared.frontmostApplication?.processIdentifier == identity.pid,
              let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              visible.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == identity.windowID
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == identity.pid }),
              let element = elements[identity], let app = NSRunningApplication(processIdentifier: identity.pid),
              app.launchDate?.timeIntervalSince1970 == identity.launchTime,
              let membership = attribute(AXUIElementCreateApplication(identity.pid), kAXWindowsAttribute, budget: budget) as? [AXUIElement],
              membership.filter({ CFEqual($0, element) }).count == 1,
              string(element, kAXSubroleAttribute, budget: budget) == kAXStandardWindowSubrole as String,
              string(element, kAXIdentifierAttribute, budget: budget).flatMap({ $0.isEmpty ? nil : $0 }) == identity.axIdentifier,
              bool(element, kAXMinimizedAttribute, budget: budget) == false,
              bool(element, "AXFullScreen", budget: budget) == false,
              settable(element, kAXSizeAttribute, budget: budget), settable(element, kAXPositionAttribute, budget: budget) else { return false }
        var size = frame.size, point = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let pointValue = AXValueCreate(.cgPoint, &point),
              budget.arm(element), whileCurrent() else { return false }
        let sized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        guard budget.arm(element), whileCurrent() else { return false }
        let positioned = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pointValue)
        return sized == .success && positioned == .success
    }

    private func settable(_ element: AXUIElement, _ key: String, budget: HostAXBudget) -> Bool {
        settableState(element, key, budget: budget) == true
    }

    private func settableState(_ element: AXUIElement, _ key: String, budget: HostAXBudget) -> Bool? {
        guard budget.arm(element) else { return nil }
        var value: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, key as CFString, &value) == .success else { return nil }
        return value.boolValue
    }

    private func attribute(_ element: AXUIElement, _ key: String, budget: HostAXBudget) -> CFTypeRef? {
        guard budget.arm(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    private func string(_ element: AXUIElement, _ key: String, budget: HostAXBudget) -> String? { attribute(element, key, budget: budget) as? String }
    private func bool(_ element: AXUIElement, _ key: String, budget: HostAXBudget) -> Bool? {
        guard let value = attribute(element, key, budget: budget) as? NSNumber,
              value.doubleValue == 0 || value.doubleValue == 1 else { return nil }
        return value.boolValue
    }
    private func frame(_ element: AXUIElement, budget: HostAXBudget) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute, budget: budget), let size = attribute(element, kAXSizeAttribute, budget: budget),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
