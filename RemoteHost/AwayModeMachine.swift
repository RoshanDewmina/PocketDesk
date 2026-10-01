import Foundation

enum AwayModeLimits {
    static let idleBeforeCover: TimeInterval = 120
    static let batteryGraceWithoutPhone: TimeInterval = 5 * 60
    static let batteryFloorWithPhone = 20
    static let expiryWithoutPhone: TimeInterval = 24 * 60 * 60
    static let lockConfirmTimeout: TimeInterval = 2
}

/// Why Away mode cannot arm right now, in the order the Mac explains them.
enum AwayUnavailableReason: String, Equatable, CaseIterable {
    case sharingOff, macLocked, needsAccessibility, managed, onBattery, safeMode, needsRecovery, needsRecoveryRecord, needsInputMonitoring
}

enum AwayEndReason: String, Equatable, CaseIterable {
    case touched, screensChanged, phoneRequest, stopSharing, quit, expiry, battery, lostRequirement, relaunchedAfterExit
}

struct AwayConditions: Equatable {
    var enabled = false
    /// The person wants sharing on. Internal stop/restart cycles keep this true.
    var sharingWanted = false
    /// Sharing is running now. Needed to arm, not to stay armed.
    var sharingActive = false
    var accessibility = false
    var onACPower = true
    var batteryPercent: Int?
    var managed = false
    var screenLocked = false
    var phoneConnected = false
    var safeMode = false
    var recoveryRunning = false
    var recoveryRecordReady = true
    var inputMonitoring = false
}

enum AwayPhase: Equatable {
    case off
    case armedPresent
    case armedCovered
    case locking(AwayEndReason)
    case lockFailed(AwayEndReason)
}

enum AwayEffect: Equatable {
    case lock(AwayEndReason)
}

struct AwayModeMachine: Equatable {
    private(set) var phase: AwayPhase = .off
    private(set) var conditions = AwayConditions()
    private(set) var lastLocalInputAt: TimeInterval = 0
    private(set) var lastPhoneAt: TimeInterval = 0
    private(set) var onBatterySince: TimeInterval?
    private(set) var lockRequestedAt: TimeInterval?
    /// Whether the cover stays up while locking and after a failed lock.
    private(set) var lockCovers = false

    init() {}

    static func unavailableReason(_ conditions: AwayConditions) -> AwayUnavailableReason? {
        if !conditions.sharingWanted || !conditions.sharingActive { return .sharingOff }
        if conditions.screenLocked { return .macLocked }
        if !conditions.accessibility { return .needsAccessibility }
        if conditions.managed { return .managed }
        if !conditions.onACPower { return .onBattery }
        if conditions.safeMode { return .safeMode }
        if !conditions.recoveryRunning { return .needsRecovery }
        if !conditions.recoveryRecordReady { return .needsRecoveryRecord }
        if !conditions.inputMonitoring { return .needsInputMonitoring }
        return nil
    }

    var isArmed: Bool { phase == .armedPresent || phase == .armedCovered }

    var wantsCover: Bool {
        switch phase {
        case .off, .armedPresent: false
        case .armedCovered: true
        case .locking, .lockFailed: lockCovers
        }
    }

    var holdsDisplayAwake: Bool {
        switch phase {
        case .armedPresent, .armedCovered, .locking: true
        case .off, .lockFailed: false
        }
    }

    var protocolState: AwayModeState {
        switch phase {
        case .off: .off
        case .armedPresent: .armed
        case .armedCovered: .covered
        case .locking, .lockFailed: lockCovers ? .covered : .armed
        }
    }

    func coversIn(now: TimeInterval) -> TimeInterval? {
        guard phase == .armedPresent else { return nil }
        return max(0, AwayModeLimits.idleBeforeCover - (now - lastLocalInputAt))
    }

    func batteryEndsIn(now: TimeInterval) -> TimeInterval? {
        guard isArmed, let onBatterySince, !conditions.phoneConnected else { return nil }
        return max(0, AwayModeLimits.batteryGraceWithoutPhone - (now - onBatterySince))
    }

    @discardableResult mutating func update(_ conditions: AwayConditions, now: TimeInterval) -> AwayEffect? {
        guard now.isFinite, now >= 0 else { return nil }
        // A phone that just left still counts as seen now, so the expiry clock starts at the disconnect.
        if conditions.phoneConnected || self.conditions.phoneConnected { lastPhoneAt = now }
        self.conditions = conditions
        onBatterySince = conditions.onACPower ? nil : (onBatterySince ?? now)

        switch phase {
        case .off:
            if conditions.enabled && Self.unavailableReason(conditions) == nil {
                phase = .armedPresent
                lastLocalInputAt = now
                lastPhoneAt = now
            }
            return nil
        case .armedPresent, .armedCovered:
            if conditions.screenLocked {
                release()
                return nil
            }
            if !conditions.enabled { return turnOffAtMac(now: now) }
            if !conditions.sharingWanted { return end(.stopSharing, now: now) }
            if !conditions.accessibility || conditions.managed || conditions.safeMode
                || !conditions.recoveryRunning || !conditions.recoveryRecordReady || !conditions.inputMonitoring {
                return end(.lostRequirement, now: now)
            }
            if batteryRuleFires(now: now) { return end(.battery, now: now) }
            return nil
        case .locking, .lockFailed:
            if conditions.screenLocked { release() }
            return nil
        }
    }

    @discardableResult mutating func tick(now: TimeInterval) -> AwayEffect? {
        guard now.isFinite, now >= 0 else { return nil }
        switch phase {
        case .locking(let reason):
            if let lockRequestedAt, elapsed(since: lockRequestedAt, now: now) >= AwayModeLimits.lockConfirmTimeout {
                if lockCovers { phase = .lockFailed(reason) } else { release() }
            }
            return nil
        case .armedPresent, .armedCovered:
            if conditions.phoneConnected { lastPhoneAt = now }
            if !conditions.phoneConnected && elapsed(since: lastPhoneAt, now: now) >= AwayModeLimits.expiryWithoutPhone {
                return end(.expiry, now: now)
            }
            if batteryRuleFires(now: now) { return end(.battery, now: now) }
            if phase == .armedPresent && elapsed(since: lastLocalInputAt, now: now) >= AwayModeLimits.idleBeforeCover {
                phase = .armedCovered
            }
            return nil
        case .off, .lockFailed:
            return nil
        }
    }

    @discardableResult mutating func localInput(now: TimeInterval) -> AwayEffect? {
        switch phase {
        case .armedPresent:
            lastLocalInputAt = now
            return nil
        case .armedCovered:
            return end(.touched, now: now)
        case .lockFailed(let reason):
            return beginLock(reason, now: now, covers: lockCovers)
        case .off, .locking:
            return nil
        }
    }

    mutating func coverNow(now: TimeInterval) {
        guard now.isFinite, now >= 0 else { return }
        if phase == .armedPresent { phase = .armedCovered }
    }

    @discardableResult mutating func end(_ reason: AwayEndReason, now: TimeInterval) -> AwayEffect? {
        switch phase {
        case .armedPresent, .armedCovered:
            return beginLock(reason, now: now, covers: phase == .armedCovered)
        case .off:
            switch reason {
            case .phoneRequest: return beginLock(reason, now: now, covers: false)
            // The previous run may have died with the cover up; stay covered until the lock lands.
            case .relaunchedAfterExit: return beginLock(reason, now: now, covers: true)
            default: return nil
            }
        case .lockFailed:
            return beginLock(reason, now: now, covers: lockCovers)
        case .locking:
            return nil
        }
    }

    @discardableResult mutating func turnOffAtMac(now: TimeInterval) -> AwayEffect? {
        switch phase {
        case .armedPresent: release(); return nil
        case .armedCovered: return end(.touched, now: now)
        case .off, .locking, .lockFailed: return nil
        }
    }

    mutating func lockConfirmed() {
        switch phase {
        case .locking, .lockFailed: release()
        case .off, .armedPresent, .armedCovered: break
        }
    }

    private mutating func beginLock(_ reason: AwayEndReason, now: TimeInterval, covers: Bool) -> AwayEffect {
        lockCovers = covers
        phase = .locking(reason)
        lockRequestedAt = now
        return .lock(reason)
    }

    private mutating func release() {
        phase = .off
        lockCovers = false
    }

    private func batteryRuleFires(now: TimeInterval) -> Bool {
        guard let onBatterySince else { return false }
        if conditions.phoneConnected {
            return (conditions.batteryPercent ?? 100) <= AwayModeLimits.batteryFloorWithPhone
        }
        return elapsed(since: onBatterySince, now: now) >= AwayModeLimits.batteryGraceWithoutPhone
    }

    // A clock that went backwards reads as no time passed, so nothing covers or locks early.
    private func elapsed(since start: TimeInterval, now: TimeInterval) -> TimeInterval {
        now >= start ? now - start : 0
    }
}

/// What the Mac's settings and popover show about Away mode.
struct HostAwayReadout: Equatable {
    enum Phase: Equatable { case off, armed, covered, locking, lockFailed }

    /// The release gate allows Away mode on this build or Mac.
    var available = false
    var enabled = false
    var phase: Phase = .off
    var unavailable: AwayUnavailableReason?
    var coversAt: Date?
    var batteryEndsAt: Date?
    var lowPowerMode = false
}

/// A successful capture filter applies to these exact cover windows and this stream attempt.
/// Replacing topology or restarting capture retires it without trusting asynchronous old work.
struct AwayExclusionReceipt: Equatable {
    let windowIDs: Set<UInt32>
    let captureAttempt: UInt64
    func matches(windowIDs: Set<UInt32>, captureAttempt: UInt64) -> Bool {
        !windowIDs.isEmpty && captureAttempt > 0 && self.windowIDs == windowIDs && self.captureAttempt == captureAttempt
    }
}
