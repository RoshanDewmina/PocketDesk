import Foundation

struct MacVitalsPresentation: Equatable {
    struct Row: Equatable {
        var title: String
        var value: String
    }

    static let tooOld = "Your Mac’s Farside is too old to report battery and load. Update it on your Mac."
    static let waiting = "Waiting for your Mac to report."
    private static let notReported = "Not reported"

    let caption: String
    /// Most complete first; the Controls header shows the first that fits on one line.
    let captions: [String]
    let spoken: String
    let isWarning: Bool
    let rows: [Row]

    init(_ vitals: MacVitals) {
        let percent = vitals.batteryPercent
        let spokenPercent = percent.map { "\($0) percent" }
        // Missing power/load/thermal evidence stays unknown, including future enum words.
        let reportsNormalHealth = vitals.powerSource != nil &&
            (vitals.thermalLevel == .nominal || vitals.thermalLevel == .fair) &&
            vitals.lowPowerMode == false && vitals.loadLevel == .ok
        let base: (caption: String?, spoken: [String]) = switch vitals.powerSource {
        case .battery:
            (Self.join("on battery", percent), ["on battery", spokenPercent].compactMap { $0 })
        case .ac where vitals.charging == true:
            (Self.join("charging", percent), ["charging", spokenPercent].compactMap { $0 })
        case .ac where percent != nil:
            ("plugged in", ["plugged in"])
        case .ups:
            (Self.join("on UPS", percent), ["on UPS power", spokenPercent].compactMap { $0 })
        case .ac:
            reportsNormalHealth ? (nil, []) : ("plugged in", ["plugged in"])
        case nil:
            (nil, [])
        }

        var suffixes: [String] = []
        switch vitals.thermalLevel {
        case .critical: suffixes.append("hot")
        case .serious: suffixes.append("warm")
        case .nominal, .fair, nil: break
        }
        if vitals.lowPowerMode == true { suffixes.append("Low Power Mode") }
        if vitals.loadLevel == .busy { suffixes.append("busy") }

        let normal = base.caption == nil && suffixes.isEmpty
            ? [reportsNormalHealth ? "running normally" : "status not reported"] : []
        caption = "Mac · " + ([base.caption].compactMap { $0 } + normal + suffixes).joined(separator: " · ")
        var captions = [caption]
        if normal.isEmpty {
            let withoutLowPower = suffixes.filter { $0 != "Low Power Mode" }
            let withoutWarm = withoutLowPower.filter { $0 != "warm" }
            for kept in [withoutLowPower, withoutWarm] {
                let words = [base.caption].compactMap { $0 } + kept
                if !words.isEmpty { captions.append("Mac · " + words.joined(separator: " · ")) }
            }
            var shortest = [base.caption].compactMap { $0 } + withoutWarm
            // Something is being reported, so "running normally" would be untrue; keep its most important word.
            if shortest.isEmpty { shortest = Array((withoutLowPower + suffixes).prefix(1)) }
            captions.append(shortest.joined(separator: " · "))
        }
        self.captions = captions.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        spoken = "Your Mac: " + (base.spoken + normal + suffixes).joined(separator: ", ") + "."

        let lowOnBattery = vitals.onBattery && ((percent ?? 100) <= 20 || (vitals.batteryWarning ?? 1) >= 2)
        let hot = (vitals.thermalLevel?.rawValue ?? 0) >= MacVitals.Thermal.serious.rawValue
        isWarning = lowOnBattery || hot || vitals.loadLevel == .busy

        rows = [
            Row(title: "Power", value: Self.powerRow(vitals)),
            Row(title: "Temperature", value: Self.temperatureRow(vitals.thermalLevel)),
            Row(title: "Low Power Mode", value: vitals.lowPowerMode.map { $0 ? "On" : "Off" } ?? Self.notReported),
            Row(title: "Load", value: Self.loadRow(vitals)),
        ]
    }

    private static func join(_ words: String, _ percent: Int?) -> String {
        percent.map { "\(words) \($0)%" } ?? words
    }

    private static func powerRow(_ vitals: MacVitals) -> String {
        let source: String
        switch vitals.powerSource {
        case .battery: source = "Battery"
        case .ac: source = "Power adapter"
        case .ups: source = "UPS"
        case nil: return notReported
        }
        let charging = vitals.powerSource == .ac && vitals.charging == true ? "charging" : nil
        let warning: String? = switch vitals.batteryWarning {
        case 2: "macOS low-battery warning"
        case 3: "macOS final battery warning"
        default: nil
        }
        return [source, charging, vitals.batteryPercent.map { "\($0)%" }, warning]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private static func temperatureRow(_ thermal: MacVitals.Thermal?) -> String {
        switch thermal {
        case .nominal, .fair: "Normal"
        case .serious: "Warm"
        case .critical: "Hot"
        case nil: notReported
        }
    }

    private static func loadRow(_ vitals: MacVitals) -> String {
        switch vitals.loadLevel {
        case .ok: "Normal"
        case .busy: ["Busy", vitals.cause?.rawValue].compactMap { $0 }.joined(separator: " · ")
        case nil: notReported
        }
    }

    #if DEBUG
    static func preview(_ name: String) -> MacVitals? {
        switch name {
        case "battery12":
            MacVitals(power: "battery", batteryPercent: 12, charging: false, batteryWarning: 2,
                      thermal: 2, lowPowerMode: true, load: "busy", loadCause: "processor")
        case "battery64":
            MacVitals(power: "battery", batteryPercent: 64, charging: false, batteryWarning: 1,
                      thermal: 0, lowPowerMode: false, load: "ok")
        case "charging82":
            MacVitals(power: "ac", batteryPercent: 82, charging: true, thermal: 0, lowPowerMode: false, load: "ok")
        case "desktop":
            MacVitals(power: "ac", thermal: 0, lowPowerMode: false, load: "ok")
        default:
            nil
        }
    }
    #endif
}
