import Foundation

enum HostAwayCopy {
    static let lockScreenSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!

    static let settingTitle = "Away mode"
    static let settingSubtitle = "Keep this Mac unlocked for your iPhone while you’re away. The screen is covered and the Mac locks if anyone touches it."
    static let introTitle = "Turn on Away mode?"
    static let introBody = [
        "While Away mode and sharing are both on, Farside keeps this Mac awake and unlocked so you can reach it from your iPhone. After 2 minutes with nobody using it, Farside covers the screen. If anyone touches the keyboard, mouse or trackpad, the Mac locks straight away, and you unlock it with your password as usual.",
        "What it can’t do: keep a MacBook awake with the lid closed (unless it’s on power with an external display, keyboard and mouse); survive a power cut, restart or macOS update (after a restart, someone has to sign in at the Mac); unlock a Mac that’s already locked; or hide notification sounds. It never changes your security settings, and Farside never sees your password.",
        "Away mode needs power. On battery it ends after 5 minutes and the Mac locks. It also ends, and locks the Mac, after 24 hours without a phone connection."
    ]
    static let introConfirm = "Turn On Away Mode"
    static let introCancel = "Cancel"
    static let coverNowTitle = "Cover now"
    static let turnOffTitle = "Turn off"
    static let lockScreenSettingsTitle = "Lock Screen Settings…"
    static let dismissTitle = "Dismiss"
    static let keepAwakeSubtitle = "While sharing is on. Your iPhone can reach this Mac only while it’s awake and unlocked."

    static func statusLine(_ readout: HostAwayReadout, now: Date) -> String? {
        guard readout.available else { return nil }
        switch readout.phase {
        case .off:
            return nil
        case .armed:
            let remaining = readout.coversAt.map { $0.timeIntervalSince(now) } ?? 0
            return "Away mode · covers in \(countdown(remaining))"
        case .covered:
            return "Away · covered, locks if touched"
        case .locking:
            return "Away · locking this Mac…"
        case .lockFailed:
            return "Away · covered. Unlock at the Mac to continue."
        }
    }

    static func warningLine(_ readout: HostAwayReadout, now: Date) -> String? {
        guard readout.available, readout.enabled else { return nil }
        if let batteryEndsAt = readout.batteryEndsAt {
            return "On battery — Away mode ends in \(countdown(batteryEndsAt.timeIntervalSince(now)))"
        }
        switch readout.unavailable {
        case .managed: return "Your organisation manages this Mac’s lock settings — Away mode unavailable"
        case .needsAccessibility: return "Needs Accessibility"
        case .onBattery: return "Connect power to use Away mode"
        case .sharingOff: return "Starts when sharing is on"
        case .safeMode: return "Paused after repeated crashes"
        case .needsRecovery: return "Turn on automatic recovery to use Away mode"
        case .needsInputMonitoring: return "Couldn’t watch local input — Away mode unavailable"
        // Nobody at a locked Mac can read a warning, and the Mac is already in the safe state.
        case .macLocked: return nil
        case nil: break
        }
        return readout.lowPowerMode ? "Low Power Mode is on" : nil
    }

    static func lockWarningText(_ warning: HostLockWarning, awayAvailable: Bool) -> String {
        switch warning {
        case .lockedWhileSharing(let at):
            return "Your Mac locked at \(time(at)) while sharing, so your iPhone couldn’t reach it. Farside can’t unlock it. To stay reachable, keep this Mac awake and unlocked"
                + (awayAvailable ? ", or turn on Away mode." : ".")
        case .screenSaverLocked(let at, let awayArmed):
            return "Your Mac’s screen saver locked it at \(time(at))"
                + (awayArmed ? " while Away mode was on" : "")
                + ". To stay reachable, change when the screen saver starts or when a password is required in Lock Screen settings."
        }
    }

    /// Minutes and seconds left, rounded up so the countdown reads 0:00 only once the time has come.
    static func countdown(_ interval: TimeInterval) -> String {
        let seconds = interval.isFinite ? max(0, Int(interval.rounded(.up))) : 0
        let minutes = seconds / 60
        let rest = seconds % 60
        return "\(minutes):\(rest < 10 ? "0" : "")\(rest)"
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
