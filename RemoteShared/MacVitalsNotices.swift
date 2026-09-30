import Foundation

enum MacVitalsNotice {
    static let busy = "Your Mac is busy with other apps, so it may respond slowly."

    static func unplugged(_ percent: Int?) -> String {
        guard let percent else { return "Your Mac is now on battery." }
        return "Your Mac is now on battery · \(percent)%."
    }

    static func low(_ percent: Int) -> String {
        "Your Mac is on battery · \(percent)%. Plug it in to keep going."
    }

    static func critical(_ percent: Int?) -> String {
        guard let percent else {
            return "Your Mac’s battery is almost empty and it may sleep soon. Plug it in or save your work."
        }
        return "Your Mac is at \(percent)% and may sleep soon. Plug it in or save your work."
    }
}

struct MacVitalsNoticePolicy {
    static let lowPercent = 20
    static let criticalPercent = 10
    static let rearmRise = 5
    static let spacing: TimeInterval = 6
    static let unplugWindow: TimeInterval = 10
    static let finalWarning = 3

    private var wasExternal = false
    private var lowArmed = true
    private var criticalArmed = true
    private var unplugSeenAt: TimeInterval?
    private var busyShown = false
    private var lastShownAt: TimeInterval?

    init() {}

    mutating func observe(_ vitals: MacVitals?, pill: BusyState?, now: TimeInterval) -> String? {
        guard let vitals else { return nil }
        let source = vitals.powerSource
        let external = source == .ac || source == .ups || vitals.charging == true
        let onBattery = source == .battery && !external
        let percent = vitals.batteryPercent
        let finalWarning = vitals.batteryWarning == Self.finalWarning

        if external {
            lowArmed = true
            criticalArmed = true
            unplugSeenAt = nil
        } else if onBattery {
            if let percent, percent >= Self.lowPercent + Self.rearmRise { lowArmed = true }
            if let percent, percent >= Self.criticalPercent + Self.rearmRise, !finalWarning { criticalArmed = true }
            if wasExternal { unplugSeenAt = now }
        }
        // An unknown power word leaves the last known source in place, so it cannot fake or hide an unplug.
        if external || onBattery { wasExternal = external }
        if let seen = unplugSeenAt, now - seen > Self.unplugWindow { unplugSeenAt = nil }

        if let lastShownAt, now - lastShownAt < Self.spacing { return nil }
        let held = pill.map(Self.holds) ?? false

        if onBattery, criticalArmed, finalWarning || percent.map({ $0 <= Self.criticalPercent }) == true {
            criticalArmed = false
            lowArmed = false
            unplugSeenAt = nil
            return show(MacVitalsNotice.critical(percent), at: now)
        }
        guard !held else { return nil }
        if onBattery, lowArmed, let percent, percent <= Self.lowPercent {
            lowArmed = false
            unplugSeenAt = nil
            return show(MacVitalsNotice.low(percent), at: now)
        }
        if onBattery, unplugSeenAt != nil {
            unplugSeenAt = nil
            return show(MacVitalsNotice.unplugged(percent), at: now)
        }
        if vitals.loadLevel == .busy, !busyShown {
            busyShown = true
            return show(MacVitalsNotice.busy, at: now)
        }
        return nil
    }

    private static func holds(_ pill: BusyState) -> Bool {
        guard pill.isVisible, let reason = LadderReason(rawValue: pill.reason) else { return false }
        return reason == .thermal || reason == .power
    }

    private mutating func show(_ notice: String, at now: TimeInterval) -> String {
        lastShownAt = now
        return notice
    }
}
