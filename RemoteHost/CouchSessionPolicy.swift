import Foundation
import CoreGraphics

enum HostSessionState: Equatable {
    case picture, couch
    case refused(SessionModeRefusal)

    var wireMode: String {
        switch self {
        case .picture: SessionMode.picture.rawValue
        case .couch: SessionMode.couch.rawValue
        case .refused: SessionModeStatus.refused
        }
    }

    var wireReason: String? {
        if case .refused(let reason) = self { return reason.rawValue }
        return nil
    }

    /// Picture keeps issuing on every status as before; Couch only while healthy; a refused session never.
    func issuesTokens(healthy: Bool) -> Bool {
        switch self {
        case .picture: true
        case .couch: healthy
        case .refused: false
        }
    }
}

struct CouchAdmissionInputs: Equatable {
    var routeLocal = false
    var provenLinkActive = false
    var allowControl = false
    var accessibility: HostPermissionStatus = .unchecked
}

enum CouchAdmission {
    /// The network reason wins over control: turning control on would not make a remote link usable.
    static func decide(_ inputs: CouchAdmissionInputs) -> SessionModeRefusal? {
        guard inputs.routeLocal, inputs.provenLinkActive else { return .notLocal }
        guard inputs.allowControl, inputs.accessibility.isGranted else { return .controlOff }
        return nil
    }
}

struct CouchHealthInputs: Equatable {
    var routeLocal = false
    var provenLinkActive = false
    var heartbeatAge: TimeInterval?
    var screenLocked = false
    var consoleUserActive = true
    var allowControl = false
    var accessibility: HostPermissionStatus = .unchecked
    var phonePaused = false
}

enum CouchHealth {
    static let heartbeatLimit: TimeInterval = 0.75

    static func isHealthy(_ i: CouchHealthInputs) -> Bool {
        guard let age = i.heartbeatAge, (0..<heartbeatLimit).contains(age) else { return false }
        return i.routeLocal && i.provenLinkActive && !i.screenLocked && i.consoleUserActive
            && i.allowControl && i.accessibility.isGranted && !i.phonePaused
    }
}

/// Lock and console status must come from the same window-server query.
struct CouchSessionSnapshot: Equatable {
    var screenLocked: Bool
    var consoleUserActive: Bool

    static let unavailable = Self(screenLocked: true, consoleUserActive: false)

    init(screenLocked: Bool, consoleUserActive: Bool) {
        self.screenLocked = screenLocked
        self.consoleUserActive = consoleUserActive
    }

    init(session: [String: Any]?) {
        guard let session, let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool else {
            self = .unavailable; return
        }
        // Preserve the existing absent lock-flag interpretation; malformed present values deny control.
        screenLocked = session["CGSSessionScreenIsLocked"].map { ($0 as? Bool) ?? true } ?? false
        consoleUserActive = onConsole
    }
}

/// Owned by the main-actor host. Notifications revoke admission independently of cached OS state.
struct CouchSessionSnapshotCache {
    static let maximumAge: TimeInterval = 0.1
    static let disabledDefaultsKey = "couchSessionSnapshotCacheDisabled"
    private var cached: CouchSessionSnapshot?
    private var queriedAt: TimeInterval?
    private var locked = false
    private var resigned = false
    private var sleeping = false

    mutating func observeAvailability(_ event: HostSleepPolicy.Event) {
        invalidate()
        switch event {
        case .screenLocked: locked = true
        case .screenUnlocked: locked = false
        case .sessionResigned: resigned = true
        case .sessionActivated: resigned = false
        case .systemWillSleep: sleeping = true
        case .systemDidWake: sleeping = false
        case .displaySlept, .displayWoke: break
        }
    }

    private mutating func invalidate() { cached = nil; queriedAt = nil }

    mutating func snapshot(at now: TimeInterval, cacheEnabled: Bool = true,
                           query: () -> [String: Any]?) -> CouchSessionSnapshot {
        guard now.isFinite else { invalidate(); return .unavailable }
        guard !locked, !resigned, !sleeping else { return .unavailable }
        if cacheEnabled, let cached, let queriedAt, (0..<Self.maximumAge).contains(now - queriedAt) {
            return cached
        }
        invalidate()
        let current = CouchSessionSnapshot(session: query())
        if cacheEnabled { cached = current; queriedAt = now }
        return current
    }
}

extension HostControlPolicy {
    static func isEnabled(userConsent: Bool, accessibilityPermission: HostPermissionStatus,
                          session: HostSessionState, captureHealthy: Bool, couchHealthy: Bool) -> Bool {
        switch session {
        case .picture:
            isEnabled(userConsent: userConsent, accessibilityPermission: accessibilityPermission, captureHealthy: captureHealthy)
        case .couch:
            userConsent && accessibilityPermission.isGranted && couchHealthy
        case .refused:
            false
        }
    }
}

extension RemoteInputLease {
    static let pictureDuration: TimeInterval = 2
    static let couchDuration: TimeInterval = 1
}

enum HostCouchDisplays {
    struct Display: Equatable {
        var id: UInt32
        var bounds: CGRect
        var mirrorsAnother: Bool
    }

    static func rects(_ displays: [Display], main: UInt32) -> [CGRect] {
        let usable = displays.filter { d in
            !d.mirrorsAnother && d.bounds.width > 0 && d.bounds.height > 0 &&
                [d.bounds.origin.x, d.bounds.origin.y, d.bounds.width, d.bounds.height].allSatisfy(\.isFinite)
        }
        var result: [CGRect] = []
        for display in usable.filter({ $0.id == main }) + usable.filter({ $0.id != main })
        where !result.contains(display.bounds) {
            result.append(display.bounds)
        }
        return result
    }

    /// Needs no Screen Recording: CoreGraphics display geometry only.
    static func current() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let displays = ids.prefix(Int(count)).map {
            Display(id: $0, bounds: CGDisplayBounds($0), mirrorsAnother: CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay)
        }
        return rects(Array(displays), main: CGMainDisplayID())
    }
}

enum CouchCatalogRefresh {
    static func allowed(active: Bool, session: HostSessionState, browserRunning: Bool) -> Bool {
        !browserRunning && (!active || session == .couch)
    }
}

struct CouchPictureRefreshTicket: Equatable {
    static let maximumWait: TimeInterval = 4
    let id = UUID()
    let epoch: UInt64
    let issuedAt: TimeInterval

    func isCurrent(epoch: UInt64, now: TimeInterval, samePeer: Bool, session: HostSessionState,
                   connected: Bool, active: Bool, paused: Bool) -> Bool {
        matchesSession(epoch: epoch, samePeer: samePeer, session: session,
                       connected: connected, active: active, paused: paused)
            && (0..<Self.maximumWait).contains(now - issuedAt)
    }

    func matchesSession(epoch: UInt64, samePeer: Bool, session: HostSessionState,
                        connected: Bool, active: Bool, paused: Bool) -> Bool {
        samePeer && self.epoch == epoch && session == .couch && connected && active && !paused
    }
}
