import Foundation
import Network

/// What this device's own network path says about the link, for Connection Health. A hint only:
/// Apple leaves the link-quality levels coarse and undocumented, so nothing here may grant or deny
/// free access or pick a route. The constrained flag is a negotiated media preference. It may be named beside measured picture trouble as an observed fact.
/// Nothing here proves what caused that trouble.  `route.1` and the local link proof stay the only authorities.
struct NetworkLinkReading: Equatable {
    enum Quality: Equatable { case unknown, minimal, moderate, good }

    var quality: Quality
    var constrained: Bool
    var ultraConstrained: Bool
    var expensive: Bool
    var wifi: Bool
    var cellular: Bool

    init(quality: Quality = .unknown, constrained: Bool = false, ultraConstrained: Bool = false, expensive: Bool = false,
         wifi: Bool = false, cellular: Bool = false) {
        self.quality = quality
        self.constrained = constrained
        self.ultraConstrained = ultraConstrained
        self.expensive = expensive
        self.wifi = wifi
        self.cellular = cellular
    }

    init(_ path: NWPath) {
        let quality: Quality
        switch path.linkQuality {
        case .minimal: quality = .minimal
        case .moderate: quality = .moderate
        case .good: quality = .good
        default: quality = .unknown
        }
        self.init(quality: quality, constrained: path.isConstrained, ultraConstrained: path.isUltraConstrained, expensive: path.isExpensive,
                  wifi: path.usesInterfaceType(.wifi), cellular: path.usesInterfaceType(.cellular))
    }
}

/// One line of Connection Health copy, in the same shape: a title, what was seen, one next step.
struct NetworkLinkHint: Equatable {
    enum Kind: String, Equatable { case weakWiFi, cellularOrExpensive, veryConstrained, lowData }

    let kind: Kind
    let title: String
    let detail: String
    let nextStep: String
    var constrained = false
    var cellular = false
    var metered = false

    /// The most useful hint for a reading, or nil when the link looks fine or says nothing.
    static func from(_ reading: NetworkLinkReading) -> NetworkLinkHint? {
        var hint = existingHint(reading)
        if LowDataPolicy.isEnabled() && reading.constrained {
            if hint == nil {
                hint = NetworkLinkHint(kind: .lowData, title: "Low Data Mode",
                    detail: "This iPhone reports Low Data Mode for this network.", nextStep: "Turn it off in iPhone Settings for a sharper picture.")
            }
            hint?.constrained = true
        }
        return hint
    }

    private static func existingHint(_ reading: NetworkLinkReading) -> NetworkLinkHint? {
        if reading.ultraConstrained {
            return NetworkLinkHint(kind: .veryConstrained, title: "Very constrained link — picture limited",
                                   detail: "This iPhone reports a very constrained network, such as a satellite link.",
                                   nextStep: "Expect a slower, softer picture. Wi-Fi or a stronger signal helps.", cellular: reading.cellular, metered: reading.cellular || reading.expensive)
        }
        if reading.wifi && reading.quality == .minimal {
            return NetworkLinkHint(kind: .weakWiFi, title: "Weak Wi-Fi",
                                   detail: "This iPhone reports a weak Wi-Fi link.",
                                   nextStep: "Move closer to the router, or switch to a stronger network.", cellular: reading.cellular, metered: reading.expensive)
        }
        if reading.cellular || reading.expensive {
            return NetworkLinkHint(kind: .cellularOrExpensive, title: "Cellular / expensive",
                                   detail: reading.cellular ? "This iPhone is on cellular data."
                                       : "This iPhone reports a metered network, such as a Personal Hotspot.",
                                   nextStep: "The picture uses data. Join Wi-Fi to avoid charges.", cellular: reading.cellular, metered: true)
        }
        return nil
    }
}


/// Media preference only, never route or input authority. Absent means ON in the combined .7 test.
enum LowDataPolicy {
    static let defaultsKey = "FarsideLowDataPolicy"
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil || defaults.bool(forKey: defaultsKey)
    }
    /// Reuse the existing relay start tier as a ceiling; preserve a tighter internal override.
    static func ceiling(_ normal: Int, active: Bool) -> Int {
        active ? min(normal, StreamQuality.balanced.startBitrateBps(for: .relay)) : normal
    }
}

/// Phone owns path hysteresis: one second to enter, five stable seconds to restore normal media.
/// Partial feedback/probe heartbeats do not withdraw the host preference.
struct LowDataPolicyState {
    private(set) var active = false
    private var pending: (value: Bool, since: TimeInterval)?
    mutating func observe(constrained: Bool, supported: Bool, enabled: Bool, at now: TimeInterval) -> Bool? {
        guard supported, enabled else { self = Self(); return nil }
        guard now.isFinite else { return active }
        if constrained == active { pending = nil; return active }
        if pending?.value != constrained || now < (pending?.since ?? now) { pending = (constrained, now) }
        if let pending, now - pending.since >= (constrained ? 1 : 5) {
            active = constrained; self.pending = nil
        }
        return active
    }
}
