import Darwin
import Foundation
import IOKit.ps

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
    private static let providing = ["AC Power": "ac", "Battery Power": "battery", "UPS Power": "ups"]

    static func reading(descriptions: [[String: Any]], providingType: String?) -> MacPowerReading? {
        let present = descriptions.filter { ($0["Is Present"] as? Bool) ?? true }
        let battery = present.first { $0["Type"] as? String == "InternalBattery" }
        let ups = present.first { $0["Type"] as? String == "UPS" }
        let source = battery ?? ups
        let stated = (source?["Power Source State"] as? String).flatMap { $0 == "Off Line" ? nil : providing[$0] }
        let power = providingType.flatMap { providing[$0] } ?? stated
        let reading = MacPowerReading(power: power, batteryPercent: source.flatMap(percent),
                                      charging: battery?["Is Charging"] as? Bool)
        return reading == MacPowerReading() ? nil : reading
    }

    private static func percent(_ description: [String: Any]) -> Int? {
        guard let current = (description["Current Capacity"] as? NSNumber)?.doubleValue,
              let maximum = (description["Max Capacity"] as? NSNumber)?.doubleValue,
              maximum > 0, current >= 0 else { return nil }
        return Int(min(100, (current * 100 / maximum).rounded(.down)))
    }
}

@MainActor
final class LiveMacVitalsSources: MacVitalsSources {
    private(set) var powerGeneration = 0
    private(set) var memoryPressure: MacMemoryPressure = .normal
    private var powerSource: CFRunLoopSource?
    private var pressureSource: DispatchSourceMemoryPressure?
    // Retained while started so a missed stop() leaks instead of handing IOKit a freed context.
    private var retainedSelf: Unmanaged<LiveMacVitalsSources>?
    // mach_host_self() adds a send-right reference on every call, so take it once.
    private let host = mach_host_self()

    init() {}

    deinit { mach_port_deallocate(mach_task_self_, host) }

    func start() {
        guard retainedSelf == nil else { return }
        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained
        let context = retained.toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let sources = Unmanaged<LiveMacVitalsSources>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { sources.powerGeneration += 1 }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self, weak pressure] in
            guard let event = pressure?.data else { return }
            MainActor.assumeIsolated {
                self?.memoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            }
        }
        pressure.resume()
        pressureSource = pressure
        memoryPressure = Self.currentPressure()
    }

    func stop() {
        guard let retained = retainedSelf else { return }
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            self.powerSource = nil
        }
        pressureSource?.cancel()
        pressureSource = nil
        memoryPressure = .normal
        retainedSelf = nil
        retained.release()
    }

    // The dispatch source reports only changes, so a Mac already under pressure needs a seed.
    private static func currentPressure() -> MacMemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }

    func readPower() -> MacPowerReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
        }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        return MacPowerParser.reading(descriptions: descriptions, providingType: providing)
    }

    func batteryWarningLevel() -> Int { Int(IOPSGetBatteryWarningLevel().rawValue) }
    func thermalState() -> Int { ProcessInfo.processInfo.thermalState.rawValue }
    func lowPowerMode() -> Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    func processorCount() -> Int { ProcessInfo.processInfo.activeProcessorCount }

    func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return CPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }

    func ownCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }
}
