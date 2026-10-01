import CoreGraphics
import Foundation
import IOKit.ps

/// Away mode ships only once Roshan's S1 and S2 tests pass (Docs/plans/AWAY-MODE-FEASIBILITY-TESTS.md).
enum AwayModeGate {
    static let releaseDefault = false
    static let previewKey = "FarsideAwayModePreview"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        releaseDefault || defaults.bool(forKey: previewKey)
        #else
        releaseDefault
        #endif
    }
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
        HostPowerSnapshot(onACPower: providingType == kIOPMACPowerKey,
                          batteryPercent: batteryPercent(sources),
                          lowPowerMode: lowPowerMode)
    }

    private static func batteryPercent(_ sources: [[String: Any]]) -> Int? {
        guard let battery = sources.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }),
              let current = battery[kIOPSCurrentCapacityKey] as? Int,
              let maximum = battery[kIOPSMaxCapacityKey] as? Int,
              maximum > 0 else { return nil }
        let percent = Int((Double(current) / Double(maximum) * 100).rounded())
        return min(100, max(0, percent))
    }
}

struct SystemPowerSource: HostPowerSourceReading {
    func snapshot() -> HostPowerSnapshot {
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return HostPowerSourceParser.snapshot(providingType: nil, sources: [], lowPowerMode: lowPowerMode)
        }
        let providingType = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        let sources = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return HostPowerSourceParser.snapshot(providingType: providingType, sources: sources, lowPowerMode: lowPowerMode)
    }
}

enum ManagedLockPolicy {
    static let domain = "com.apple.screensaver"
    static let keys = ["idleTime", "askForPassword", "askForPasswordDelay"]

    static func isManaged(isForced: (_ key: String, _ domain: String) -> Bool = ManagedLockPolicy.systemIsForced) -> Bool {
        keys.contains { isForced($0, domain) }
    }

    static func systemIsForced(_ key: String, _ domain: String) -> Bool {
        CFPreferencesAppValueIsForced(key as CFString, domain as CFString)
    }
}

enum HostIdle {
    /// Seconds since any input event in this login session, local or injected.
    static func systemIdleSeconds() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~0)!
        return max(0, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput))
    }
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

    mutating func screenSaverStarted(uptime: TimeInterval) {
        screenSaverStartedAt = uptime
    }

    mutating func screenSaverStopped() {
        screenSaverStartedAt = nil
    }

    /// A warning only for a lock nobody at the Mac chose while sharing was wanted.
    mutating func screenLocked(at date: Date, uptime: TimeInterval, sharingWanted: Bool, awayArmed: Bool,
                               lockRequestedByFarside: Bool, idleSeconds: TimeInterval) -> HostLockWarning? {
        guard sharingWanted, !lockRequestedByFarside else { return nil }
        // Stopping the screen saver clears the start time, so a recorded start means it is still running.
        if screenSaverStartedAt != nil {
            return .screenSaverLocked(at: date, awayArmed: awayArmed)
        }
        if idleSeconds >= Self.idleForAutomaticLock {
            return .lockedWhileSharing(at: date)
        }
        return nil
    }
}
