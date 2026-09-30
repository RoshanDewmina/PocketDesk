import Foundation

enum MacVitalsNotice {
    static let busy = "Your Mac is busy with other apps, so it may respond slowly."
    static func unplugged(_ percent: Int?) -> String { "" }
    static func low(_ percent: Int) -> String { "" }
    static func critical(_ percent: Int?) -> String { "" }
}

struct MacVitalsNoticePolicy {
    static let lowPercent = 20
    static let criticalPercent = 10
    static let rearmRise = 5
    static let spacing: TimeInterval = 6
    static let unplugWindow: TimeInterval = 10

    init() {}

    mutating func observe(_ vitals: MacVitals?, pill: BusyState?, now: TimeInterval) -> String? { nil }
}
