import Foundation

/// Negative readiness is not proof that an owned display disappeared.
enum SessionVirtualDisplayPresence: Equatable, Sendable {
    case present, confirmedRemoved, unknown, neverCreated
}

/// Pure classification of bounded public-inventory evidence; no foreign display is adopted.
enum SessionVirtualDisplayPresencePolicy {
    static func classify(constructed: Bool, knownIdentity: Bool, online: Bool?, identityMatches: Bool,
                         isMain: Bool, isMirrored: Bool, absenceConfirmed: Bool,
                         operationCurrent: Bool) -> SessionVirtualDisplayPresence {
        guard operationCurrent else { return .unknown }
        guard constructed else { return .neverCreated }
        guard knownIdentity, let online else { return .unknown }
        if online { return identityMatches && !isMain && !isMirrored ? .present : .unknown }
        return absenceConfirmed ? .confirmedRemoved : .unknown
    }
}

enum VirtualDisplayRestorationAction: Equatable, Sendable { case restoreOriginals, retainJournal }
enum VirtualDisplayRestorationPolicy {
    static func action(presence: SessionVirtualDisplayPresence, physicalTopologyUnchanged: Bool,
                       journalIsPrepared: Bool) -> VirtualDisplayRestorationAction {
        switch presence {
        case .present, .confirmedRemoved:
            return physicalTopologyUnchanged ? .restoreOriginals : .retainJournal
        case .neverCreated:
            return journalIsPrepared ? .restoreOriginals : .retainJournal
        case .unknown:
            return .retainJournal
        }
    }
}

/// Public CG window ID is scoped to the process launch, never just its reusable PID.
struct VirtualDisplayWindowIdentity: Codable, Hashable, Sendable {
    var pid: Int32
    var launchTime: TimeInterval
    var windowID: UInt32
    var axIdentifier: String?
}

struct VirtualDisplayWindow: Sendable {
    var identity: VirtualDisplayWindowIdentity
    var frame: CGRect
}

struct VirtualDisplayWindowSnapshot: Sendable {
    var windows: [VirtualDisplayWindow]
    var complete: Bool
    var stageManagerEnabled: Bool
    /// Absent from a successful public all-Space inventory, or its exact process launch exited.
    /// Missing from the on-screen AX snapshot alone is never evidence that a window closed.
    var closedIdentities: Set<VirtualDisplayWindowIdentity> = []
}

/// Shared decisions used by the live AX inventory; unresolved candidates block the whole snapshot.
enum VirtualDisplayWorkspaceInventoryPolicy {
    enum Eligibility: Equatable, Sendable { case eligible, outOfScope, unresolved }
    enum Attribution: Equatable, Sendable { case matched(UInt32), outOfScope, unresolved }
    struct PublicWindow: Sendable {
        var windowID: UInt32
        var frame: CGRect
    }
    struct PublicIdentityRow: Sendable {
        var pid: Int32?
        var windowID: UInt32?
    }

    static func closureIDs(_ rows: [PublicIdentityRow], pid: Int32) -> Set<UInt32>? {
        var ids = Set<UInt32>()
        for row in rows {
            guard let owner = row.pid, owner > 0 else { return nil }
            guard owner == pid else { continue }
            guard let id = row.windowID, id != 0 else { return nil }
            guard ids.insert(id).inserted else { return nil }
        }
        return ids
    }

    static func eligibility(standard: Bool?, minimized: Bool?, fullscreen: Bool?, frame: CGRect?,
                            sizeSettable: Bool?, positionSettable: Bool?, requireMovable: Bool = true) -> Eligibility {
        if standard == false || minimized == true || fullscreen == true { return .outOfScope }
        guard standard == true, minimized == false, fullscreen == false,
              let frame, VirtualDisplayWindowPolicy.valid(frame) else { return .unresolved }
        // A standard window that cannot be moved cannot safely be abandoned on the owned display.
        if requireMovable && (sizeSettable != true || positionSettable != true) { return .unresolved }
        return .eligible
    }

    static func attribute(frame: CGRect, onScreen: [PublicWindow], allSpaces: [PublicWindow]?,
                          provenID: UInt32? = nil) -> Attribution {
        if let provenID {
            if onScreen.contains(where: { $0.windowID == provenID }) { return .matched(provenID) }
            if allSpaces?.contains(where: { $0.windowID == provenID }) == true { return .outOfScope }
            return .unresolved
        }
        let visibleMatches = onScreen.filter { VirtualDisplayWindowPolicy.close(frame, $0.frame) }
        guard let allSpaces else { return .unresolved }
        let allMatches = allSpaces.filter { VirtualDisplayWindowPolicy.close(frame, $0.frame) }
        if visibleMatches.count == 1, allMatches.count == 1, visibleMatches[0].windowID == allMatches[0].windowID {
            return .matched(visibleMatches[0].windowID)
        }
        // Absence from on-screen is exclusion only after unique public all-Space attribution.
        guard visibleMatches.isEmpty, allMatches.count == 1,
              !onScreen.contains(where: { $0.windowID == allMatches[0].windowID }) else { return .unresolved }
        return .outOfScope
    }

    static func allVisibleAccounted(_ onScreen: [PublicWindow], accountedIDs: Set<UInt32>) -> Bool {
        onScreen.allSatisfy { accountedIDs.contains($0.windowID) }
    }
}

/// Every display online before workspace creation is protected, including foreign virtual ones.
/// UUIDs survive public display-ID reassignment; mode/position/mirroring changes still deny recovery.
struct VirtualDisplayProtectedDisplay: Codable, Equatable, Sendable {
    var uuid: UUID
    var bounds: CGRect
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var modeID: UInt32
    var modeFlags: UInt32
    var refresh: Double
    var rotation: Double
    var main: Bool
    var mirrored: Bool
    var mirrorTarget: UUID?
}

/// Adapter proof for one retained display lease. Mode changes preserve this generation.
/// This is deliberately not persisted: a cold keeper may recover originals, never adopt a lease.
struct VirtualDisplayWindowOwnedDisplayIdentity: Equatable, Sendable {
    var displayID: UInt32
    var uuid: UUID
    var vendor: UInt32
    var product: UInt32
    var serial: UInt32
    var leaseGeneration: UUID
}

struct VirtualDisplayWindowJournal: Codable, Sendable {
    struct Record: Codable, Sendable {
        var identity: VirtualDisplayWindowIdentity
        var original: CGRect
        var requested: CGRect
        var applied: CGRect?
        var virtualBounds: [CGRect]
    }
    var version = 1
    var session = UUID()
    var records: [Record]
    /// v1 is the historical B8 format. New workspace journals require v2 and this evidence.
    var protectedDisplays: [VirtualDisplayProtectedDisplay]? = nil

    var isPrepared: Bool {
        !records.isEmpty && records.allSatisfy { $0.virtualBounds.isEmpty && $0.applied == nil && $0.requested == $0.original }
    }
}

enum VirtualDisplayWindowPolicy {
    static let tolerance: CGFloat = 2
    static let maximumWindows = 32

    static func validTopology(_ displays: [VirtualDisplayProtectedDisplay]) -> Bool {
        !displays.isEmpty && displays.count <= 32 && Set(displays.map(\.uuid)).count == displays.count
            && displays.filter(\.main).count == 1 && displays.allSatisfy { entry in
                valid(entry.bounds) && entry.width > 0 && entry.height > 0 && entry.pixelWidth > 0 && entry.pixelHeight > 0
                    && entry.refresh.isFinite && entry.refresh >= 0 && entry.rotation.isFinite
                    && (entry.mirrorTarget == nil || (entry.mirrored && displays.contains(where: { $0.uuid == entry.mirrorTarget })))
            }
    }

    static func sameTopology(_ a: [VirtualDisplayProtectedDisplay], _ b: [VirtualDisplayProtectedDisplay]) -> Bool {
        validTopology(a) && validTopology(b)
            && a.sorted { $0.uuid.uuidString < $1.uuid.uuidString } == b.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
    }

    static func protectedTopologyMatches(_ protected: [VirtualDisplayProtectedDisplay], current: [VirtualDisplayProtectedDisplay], allowOwnedDisplay: Bool) -> Bool {
        guard validTopology(protected), validTopology(current) else { return false }
        let savedIDs = Set(protected.map(\.uuid))
        let retained = current.filter { savedIDs.contains($0.uuid) }
        let extra = current.filter { !savedIDs.contains($0.uuid) }
        return sameTopology(protected, retained) && (extra.isEmpty || (allowOwnedDisplay && extra.count == 1
            && !extra[0].main && !extra[0].mirrored && extra[0].mirrorTarget == nil))
    }

    static func workspaceTopologyMatches(_ protected: [VirtualDisplayProtectedDisplay], current: [VirtualDisplayProtectedDisplay], virtualBounds: CGRect,
                                         ownedDisplayUUID: UUID) -> Bool {
        let savedIDs = Set(protected.map(\.uuid))
        let extra = current.filter { !savedIDs.contains($0.uuid) }
        return protectedTopologyMatches(protected, current: current, allowOwnedDisplay: true)
            && extra.count == 1 && extra[0].uuid == ownedDisplayUUID && extra[0].bounds == virtualBounds
    }

    /// Called by the live CG reader and fixtures; the lease nonce is checked by keeper binding.
    static func ownedDisplayMatches(_ proof: VirtualDisplayWindowOwnedDisplayIdentity, displayID: UInt32,
                                    uuid: UUID?, vendor: UInt32, product: UInt32, serial: UInt32,
                                    online: Bool, main: Bool, mirrored: Bool, bounds: CGRect,
                                    expectedBounds: CGRect?) -> Bool {
        proof.displayID != 0 && proof.serial != 0 && online && !main && !mirrored
            && displayID == proof.displayID && uuid == proof.uuid && vendor == proof.vendor
            && product == proof.product && serial == proof.serial && valid(bounds)
            && (expectedBounds == nil || bounds == expectedBounds)
    }

    static func validEnrollment(_ snapshot: VirtualDisplayWindowSnapshot, allowEmpty: Bool = false) -> Bool {
        snapshot.complete && !snapshot.stageManagerEnabled && (allowEmpty || !snapshot.windows.isEmpty)
            && snapshot.windows.count <= maximumWindows
            && Set(snapshot.windows.map(\.identity)).count == snapshot.windows.count
            && snapshot.windows.allSatisfy {
                valid($0.frame) && $0.identity.pid > 0 && $0.identity.launchTime.isFinite && $0.identity.windowID != 0
            }
    }

    static func distinctFrames(_ frames: [CGRect]) -> Bool {
        frames.indices.allSatisfy { index in
            frames.indices.filter { $0 < index }.allSatisfy { !sameOrigin(frames[index], frames[$0]) }
        }
    }

    /// Width/height differences do not make windows stacked at the same corner useful placement.
    /// Keep full-frame comparison separate for identity attribution and restore verification.
    static func sameOrigin(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
    }

    static func isDefinitivelyClosed(_ identity: VirtualDisplayWindowIdentity, processExists: Bool,
                                    currentLaunchTime: TimeInterval?, allWindowIDs: Set<UInt32>?) -> Bool {
        guard processExists else { return true }
        guard let currentLaunchTime else { return false }
        if currentLaunchTime != identity.launchTime { return true }
        guard let allWindowIDs else { return false }
        return !allWindowIDs.contains(identity.windowID)
    }

    static func valid(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0 && frame.width <= 32768 && frame.height <= 32768
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    static func fits(_ frame: CGRect, in bounds: CGRect) -> Bool {
        valid(frame) && valid(bounds) && bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(frame)
    }

    static func destination(for frame: CGRect, in bounds: CGRect, index: Int = 0) -> CGRect {
        let step = min(CGFloat(16), min(bounds.width, bounds.height) * 0.25 / CGFloat(maximumWindows - 1))
        let offset = CGFloat(max(0, index)) * step
        return CGRect(x: bounds.minX + offset, y: bounds.minY + offset,
                      width: min(frame.width, bounds.width - offset), height: min(frame.height, bounds.height - offset))
    }

    /// Newly discovered windows overlapping the temporary display have no known physical original.
    /// Choose a bounded physical return frame; precreation/enrolled originals are never replaced.
    static func enrollmentReturnFrame(_ frame: CGRect, virtualBounds: CGRect, physicalBounds: CGRect, index: Int) -> CGRect {
        virtualBounds.intersects(frame) ? destination(for: frame, in: physicalBounds, index: index) : frame
    }

    /// Resize/move ownership follows exact public identity. A drag within the virtual workspace
    /// remains ours to restore; a distinct physical-screen drag is the person's new layout.
    static func shouldRestore(_ record: VirtualDisplayWindowJournal.Record, current: CGRect) -> Bool {
        guard valid(current) else { return false }
        // Prepared records predate display creation. Exact launch/CG/AX attribution permits
        // undoing WindowServer's creation-time reflow before a target frame was applied.
        if record.virtualBounds.isEmpty && record.applied == nil && record.requested == record.original { return true }
        if close(current, record.original) { return true }
        if close(current, record.requested) || record.applied.map({ close(current, $0) }) == true { return true }
        if record.virtualBounds.contains(where: { $0.contains(CGPoint(x: current.midX, y: current.midY)) }) { return true }
        // WindowServer can relocate to the old physical anchor after the virtual display disappears.
        let sameAnchor = abs(current.minX - record.original.minX) <= tolerance
            && abs(current.minY - record.original.minY) <= tolerance
        let knownSizes = [record.requested] + (record.applied.map { [$0] } ?? [])
        return sameAnchor && knownSizes.contains { abs(current.width - $0.width) <= tolerance && abs(current.height - $0.height) <= tolerance }
    }
}
