import Foundation
import Network

/// What this device's own network path says about the link, for Connection Health. A hint only:
/// Apple leaves the link-quality levels coarse and undocumented, so nothing here may grant or deny
/// free access or pick a route. It may be named beside measured picture trouble as an observed fact.
/// Nothing here proves what caused that trouble.  `route.1` and the local link proof stay the only authorities.
struct NetworkLinkReading: Equatable {
    enum Quality: Equatable { case unknown, minimal, moderate, good }

    var quality: Quality
    var ultraConstrained: Bool
    var expensive: Bool
    var wifi: Bool
    var cellular: Bool

    init(quality: Quality = .unknown, ultraConstrained: Bool = false, expensive: Bool = false,
         wifi: Bool = false, cellular: Bool = false) {
        self.quality = quality
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
        self.init(quality: quality, ultraConstrained: path.isUltraConstrained, expensive: path.isExpensive,
                  wifi: path.usesInterfaceType(.wifi), cellular: path.usesInterfaceType(.cellular))
    }
}

/// One line of Connection Health copy, in the same shape: a title, what was seen, one next step.
struct NetworkLinkHint: Equatable {
    enum Kind: String, Equatable { case weakWiFi, cellularOrExpensive, veryConstrained }

    let kind: Kind
    let title: String
    let detail: String
    let nextStep: String
    var cellular = false
    var metered = false

    /// The most useful hint for a reading, or nil when the link looks fine or says nothing.
    static func from(_ reading: NetworkLinkReading) -> NetworkLinkHint? {
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
