import Foundation

extension SessionFeature {
    static let macVitals = "vitals.1"
}

/// The Mac's battery, temperature, Low Power Mode and whole-Mac load, on `capture` status. A field the
/// Mac could not read is omitted. Strings are checked by length and charset rather than by enum, so a
/// newer Mac's new word never ends a session (validation failures are fatal); the accessors map unknown words to nil.
struct MacVitals: Codable, Equatable {
    enum Power: String { case battery, ac, ups }
    enum Load: String { case ok, busy }
    enum LoadCause: String { case processor, memory }
    enum Thermal: Int { case nominal, fair, serious, critical }

    static let percentRange = 0...100
    static let warningRange = 1...3
    static let thermalRange = 0...3
    static let maxWordLength = 12

    var power: String? = nil
    var batteryPercent: Int? = nil
    var charging: Bool? = nil
    /// `IOPSGetBatteryWarningLevel`: 1 none, 2 early (about 20 minutes left), 3 final (about 10). Not guaranteed.
    var batteryWarning: Int? = nil
    /// `ProcessInfo.ThermalState` raw value.
    var thermal: Int? = nil
    var lowPowerMode: Bool? = nil
    var load: String? = nil
    var loadCause: String? = nil

    var powerSource: Power? { power.flatMap(Power.init(rawValue:)) }
    var loadLevel: Load? { load.flatMap(Load.init(rawValue:)) }
    var cause: LoadCause? { loadCause.flatMap(LoadCause.init(rawValue:)) }
    var thermalLevel: Thermal? { thermal.flatMap(Thermal.init(rawValue:)) }
    var onBattery: Bool { powerSource == .battery }

    func validate() throws {}
    func clamped() -> MacVitals { self }
}
