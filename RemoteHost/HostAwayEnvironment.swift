import CoreGraphics
import Foundation
import IOKit.ps

/// Away mode ships only once Roshan's S1 and S2 tests pass (Docs/plans/AWAY-MODE-FEASIBILITY-TESTS.md).
enum AwayModeGate {
    static let releaseDefault = false
    static let previewKey = "FarsideAwayModePreview"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool { false }
}

struct HostPowerSnapshot: Equatable {
    var onACPower = true
    var batteryPercent: Int?
    var lowPowerMode = false
}

protocol HostPowerSourceReading {
    func snapshot() -> HostPowerSnapshot
}

enum HostPowerSourceParser {
    /// `providingType` is `IOPSGetProvidingPowerSourceType`'s value; `sources` are the power source descriptions.
    static func snapshot(providingType: String?, sources: [[String: Any]], lowPowerMode: Bool) -> HostPowerSnapshot {
        HostPowerSnapshot()
    }
}

struct SystemPowerSource: HostPowerSourceReading {
    func snapshot() -> HostPowerSnapshot { HostPowerSnapshot() }
}

enum ManagedLockPolicy {
    static let domain = "com.apple.screensaver"
    static let keys = ["idleTime", "askForPassword", "askForPasswordDelay"]

    static func isManaged(isForced: (_ key: String, _ domain: String) -> Bool = ManagedLockPolicy.systemIsForced) -> Bool {
        false
    }

    static func systemIsForced(_ key: String, _ domain: String) -> Bool { false }
}

enum HostIdle {
    /// Seconds since any input event in this login session, local or injected.
    static func systemIdleSeconds() -> TimeInterval { 0 }
}

enum HostLockWarning: Equatable {
    case lockedWhileSharing(at: Date)
    case screenSaverLocked(at: Date, awayArmed: Bool)
}

struct HostLockWarningTracker: Equatable {
    /// A screen saver that started this recently is taken as the cause of a lock.
    static let screenSaverWindow: TimeInterval = 10
    /// A lock after this much idle time is taken as automatic rather than chosen.
    static let idleForAutomaticLock: TimeInterval = 30

    private(set) var screenSaverStartedAt: TimeInterval?

    mutating func screenSaverStarted(uptime: TimeInterval) {}
    mutating func screenSaverStopped() {}

    /// A warning only for a lock nobody at the Mac chose while sharing was wanted.
    mutating func screenLocked(at date: Date, uptime: TimeInterval, sharingWanted: Bool, awayArmed: Bool,
                               lockRequestedByFarside: Bool, idleSeconds: TimeInterval) -> HostLockWarning? {
        nil
    }
}
