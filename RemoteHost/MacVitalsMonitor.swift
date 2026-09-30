import Foundation

enum MacCPU {
    static func othersFraction(previous: CPUTicks, current: CPUTicks, ownCPUSeconds: Double,
                               wallSeconds: TimeInterval, processors: Int) -> Double? { nil }
}

struct MacLoadPolicy {
    static let window: TimeInterval = 10
    static let busyAt = 0.85
    static let clearBelow = 0.70

    init() {}

    var level: MacVitals.Load { .ok }
    var cause: MacVitals.LoadCause? { nil }
    mutating func observe(processorFraction: Double, over duration: TimeInterval) {}
    mutating func observe(memoryPressure: MacMemoryPressure) {}
}

@MainActor
final class MacVitalsMonitor {
    static let processorInterval: TimeInterval = 2
    static let powerInterval: TimeInterval = 1

    private let sources: MacVitalsSources
    private(set) var isRunning = false

    init(sources: MacVitalsSources) { self.sources = sources }

    func start(now: TimeInterval) {}
    func stop() {}
    func current(now: TimeInterval) -> MacVitals? { nil }
}
