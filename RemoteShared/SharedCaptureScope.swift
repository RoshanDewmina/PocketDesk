import Foundation

/// Status only. Target handles and document/window titles stay on the owning Mac.
struct CaptureScopeFrame: Codable, Equatable {
    enum Kind: String, Codable { case display, application, window }
    var version = 1
    let epoch: UInt64
    let kind: Kind
    let label: String
    let viewOnly: Bool

    func validate() throws {
        guard version == 1, epoch > 0, !label.isEmpty, label.utf8.count <= 128,
              !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              viewOnly == (kind != .display) else { throw RemoteError.invalidMessage }
    }
}

enum SharedCaptureScopePolicy {
    /// Evidence must come from a fresh owner-local inventory and retained process identity.
    /// A display's presence never substitutes for a missing narrower target.
    static func targetIsAvailable(kind: CaptureScopeFrame.Kind, displayPresent: Bool,
                                  exactProcessInstance: Bool, selectedWindowPresent: Bool) -> Bool {
        switch kind {
        case .display: return displayPresent
        case .application, .window: return displayPresent && exactProcessInstance && selectedWindowPresent
        }
    }

    static func permits(_ action: String, kind: CaptureScopeFrame.Kind) -> Bool {
        kind == .display || ["release", "heartbeat", "pause", "resume", "viewOnly"].contains(action)
    }

    static func features(_ features: [String], kind: CaptureScopeFrame.Kind) -> [String] {
        guard kind != .display else { return features }
        let allowed = Set([SessionFeature.captureScope, SessionFeature.backgroundPause, SessionFeature.liveViewOnly,
                           SessionFeature.ladder, SessionFeature.macVitals, SessionFeature.videoLTR, SessionFeature.videoRefinement, SessionFeature.exactVideoTiming])
        return features.filter { allowed.contains($0) }
    }
}

/// A terminal per-stream fence. Invalidation waits for an in-progress delivery; after it returns,
/// even a queued frame or a cached idle frame cannot reach the old peer. Never revive a closed lease.
/// Narrow streams also need a continuously renewed inventory lease; a stalled inventory fails closed.
final class CaptureScopeLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var validUntil: TimeInterval
    private let clock: () -> TimeInterval

    init(validUntil: TimeInterval = .infinity, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.validUntil = validUntil; self.clock = clock
    }

    func renew(until deadline: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if active { validUntil = deadline }
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        active = false
    }

    @discardableResult
    func performIfValid(_ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Sample after acquiring the delivery lock: queued work cannot reuse a pre-wait timestamp.
        let now = clock()
        guard active, now.isFinite, now <= validUntil else { return false }
        body()
        return true
    }
}
