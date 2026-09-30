import Foundation

enum MacCPU {
    static func othersFraction(previous: CPUTicks, current: CPUTicks, ownCPUSeconds: Double,
                               wallSeconds: TimeInterval, processors: Int) -> Double? {
        let busy = Double(current.user &- previous.user) + Double(current.system &- previous.system)
            + Double(current.nice &- previous.nice)
        let total = busy + Double(current.idle &- previous.idle)
        guard total > 0, wallSeconds > 0, processors > 0, ownCPUSeconds.isFinite else { return nil }
        // Ticks give the whole Mac's share; Farside's share comes from wall time so the tick unit never matters.
        let own = ownCPUSeconds / (wallSeconds * Double(processors))
        return min(1, max(0, busy / total - own))
    }
}

struct MacLoadPolicy {
    static let window: TimeInterval = 10
    static let busyAt = 0.85
    static let clearBelow = 0.70
    private static let jitter: TimeInterval = 0.5

    private var samples: [(duration: TimeInterval, fraction: Double)] = []
    private var processorBusy = false
    private var memoryCritical = false

    init() {}

    var level: MacVitals.Load { processorBusy || memoryCritical ? .busy : .ok }
    var cause: MacVitals.LoadCause? { memoryCritical ? .memory : processorBusy ? .processor : nil }

    mutating func observe(processorFraction: Double, over duration: TimeInterval) {
        guard processorFraction.isFinite, duration.isFinite, duration > 0 else { return }
        samples.append((duration, min(1, max(0, processorFraction))))
        while samples.count > 1, covered - samples[0].duration >= Self.window { samples.removeFirst() }
        guard covered >= Self.window - Self.jitter else { return }
        let mean = samples.reduce(0) { $0 + $1.duration * $1.fraction } / covered
        if !processorBusy, mean >= Self.busyAt { processorBusy = true }
        if processorBusy, mean < Self.clearBelow { processorBusy = false }
    }

    mutating func observe(memoryPressure: MacMemoryPressure) {
        switch memoryPressure {
        case .critical: memoryCritical = true
        case .normal: memoryCritical = false
        case .warning: break
        }
    }

    private var covered: TimeInterval { samples.reduce(0) { $0 + $1.duration } }
}

@MainActor
final class MacVitalsMonitor {
    static let processorInterval: TimeInterval = 2
    static let powerInterval: TimeInterval = 1

    private let sources: MacVitalsSources
    private(set) var isRunning = false
    private var policy = MacLoadPolicy()
    private var lastTicks: CPUTicks?
    private var lastOwn = 0.0
    private var lastSampleAt: TimeInterval = 0
    private var power: MacPowerReading?
    private var powerReadAt: TimeInterval = 0
    private var powerGenerationRead = 0

    init(sources: MacVitalsSources) { self.sources = sources }

    func start(now: TimeInterval) {
        guard !isRunning else { return }
        isRunning = true
        sources.start()
        lastTicks = sources.cpuTicks()
        lastOwn = sources.ownCPUSeconds()
        lastSampleAt = now
        readPower(now: now)
    }

    func stop() {
        guard isRunning else { return }
        sources.stop()
        isRunning = false
        policy = MacLoadPolicy()
        lastTicks = nil
        lastOwn = 0
        lastSampleAt = 0
        power = nil
        powerReadAt = 0
        powerGenerationRead = 0
    }

    func current(now: TimeInterval) -> MacVitals? {
        guard isRunning else { return nil }
        if now - lastSampleAt >= Self.processorInterval { sampleProcessor(now: now) }
        policy.observe(memoryPressure: sources.memoryPressure)
        if sources.powerGeneration != powerGenerationRead, now - powerReadAt >= Self.powerInterval {
            readPower(now: now)
        }
        let hasBattery = power?.batteryPercent != nil
        return MacVitals(power: power?.power,
                         batteryPercent: power?.batteryPercent,
                         charging: power?.charging,
                         batteryWarning: hasBattery ? sources.batteryWarningLevel() : nil,
                         thermal: sources.thermalState(),
                         lowPowerMode: sources.lowPowerMode(),
                         load: policy.level.rawValue,
                         loadCause: policy.cause?.rawValue).clamped()
    }

    private func sampleProcessor(now: TimeInterval) {
        let ticks = sources.cpuTicks()
        let own = sources.ownCPUSeconds()
        let elapsed = now - lastSampleAt
        if let previous = lastTicks, let ticks,
           let fraction = MacCPU.othersFraction(previous: previous, current: ticks, ownCPUSeconds: own - lastOwn,
                                                wallSeconds: elapsed, processors: sources.processorCount()) {
            policy.observe(processorFraction: fraction, over: elapsed)
        }
        lastTicks = ticks
        lastOwn = own
        lastSampleAt = now
    }

    private func readPower(now: TimeInterval) {
        powerGenerationRead = sources.powerGeneration
        power = sources.readPower()
        powerReadAt = now
    }
}
