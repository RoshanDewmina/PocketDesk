import Foundation

enum HostAwayCopy {
    static let lockScreenSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!

    static func statusLine(_ readout: HostAwayReadout, now: Date) -> String? { nil }
    static func warningLine(_ readout: HostAwayReadout, now: Date) -> String? { nil }
    static func lockWarningText(_ warning: HostLockWarning, awayAvailable: Bool) -> String { "" }
    static func countdown(_ interval: TimeInterval) -> String { "" }
}
