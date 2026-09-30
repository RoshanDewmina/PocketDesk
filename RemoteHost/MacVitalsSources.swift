import Foundation

struct MacPowerReading: Equatable {
    var power: String? = nil
    var batteryPercent: Int? = nil
    var charging: Bool? = nil
}

enum MacMemoryPressure: Equatable { case normal, warning, critical }

struct CPUTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

@MainActor
protocol MacVitalsSources: AnyObject {
    var powerGeneration: Int { get }
    var memoryPressure: MacMemoryPressure { get }
    func start()
    func stop()
    func readPower() -> MacPowerReading?
    func batteryWarningLevel() -> Int
    func thermalState() -> Int
    func lowPowerMode() -> Bool
    func cpuTicks() -> CPUTicks?
    func ownCPUSeconds() -> Double
    func processorCount() -> Int
}

enum MacPowerParser {
    static func reading(descriptions: [[String: Any]], providingType: String?) -> MacPowerReading? { nil }
}

@MainActor
final class LiveMacVitalsSources: MacVitalsSources {
    private(set) var powerGeneration = 0
    private(set) var memoryPressure: MacMemoryPressure = .normal

    init() {}

    func start() {}
    func stop() {}
    func readPower() -> MacPowerReading? { nil }
    func batteryWarningLevel() -> Int { 1 }
    func thermalState() -> Int { 0 }
    func lowPowerMode() -> Bool { false }
    func cpuTicks() -> CPUTicks? { nil }
    func ownCPUSeconds() -> Double { 0 }
    func processorCount() -> Int { 1 }
}
