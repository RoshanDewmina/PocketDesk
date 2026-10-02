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

    var isPrepared: Bool {
        !records.isEmpty && records.allSatisfy { $0.virtualBounds.isEmpty && $0.applied == nil && $0.requested == $0.original }
    }
}

enum VirtualDisplayWindowPolicy {
    static let tolerance: CGFloat = 2
    static let maximumWindows = 8

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
        let offset = min(CGFloat(max(0, index)) * 16, min(bounds.width, bounds.height) * 0.25)
        return CGRect(x: bounds.minX + offset, y: bounds.minY + offset,
                      width: min(frame.width, bounds.width - offset), height: min(frame.height, bounds.height - offset))
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
