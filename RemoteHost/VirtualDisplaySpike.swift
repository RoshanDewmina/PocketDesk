#if DEBUG
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ObjectiveC
import QuartzCore
import ScreenCaptureKit

/// Debug-only one-day spike (Docs/perf/VIRTUAL-DISPLAY-SPIKE.md): does a 2560×1440 @ 120 Hz
/// `CGVirtualDisplay` make ScreenCaptureKit deliver ≥ 110 distinct frames a second? Runs only when the
/// host is launched with `--virtual-display-spike`, before any host state exists; it never creates the
/// host model, pairing or network, and removes its window and virtual display before returning.
@MainActor
enum VirtualDisplaySpike {
    nonisolated static let launchArgument = "--virtual-display-spike"
    nonisolated static let scenariosArgument = "--virtual-display-spike-scenarios"
    nonisolated static let goMeanFPS = 110.0
    nonisolated static let goP90GapMs = 12.0
    nonisolated static let movingSeconds = 10
    nonisolated static let idleSeconds = 5
    nonisolated static let timeoutSeconds = 240

    private static var active: SpikeResources?
    private static var signalSources: [DispatchSourceSignal] = []

    /// Returns once every scenario has run and been torn down; the caller exits.
    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        // No delegate, so none of the host's launch callbacks can run in this process.
        app.delegate = nil
        app.setActivationPolicy(.accessory)
        installSignalHandlers()
        armTimeout()
        Task { @MainActor in
            await runScenarios(selectedScenarios(arguments: CommandLine.arguments))
            app.stop(nil)
            let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
            if let wake { app.postEvent(wake, atStart: false) }
        }
        app.run()
    }

    static func selectedScenarios(arguments: [String]) -> [VirtualDisplaySpikeScenario] {
        guard let index = arguments.firstIndex(of: scenariosArgument), arguments.indices.contains(index + 1) else {
            return VirtualDisplaySpikeScenario.all
        }
        let names = Set(arguments[index + 1].split(separator: ",").map(String.init))
        let chosen = VirtualDisplaySpikeScenario.all.filter { names.contains($0.name) }
        return chosen.isEmpty ? VirtualDisplaySpikeScenario.all : chosen
    }

    // MARK: Scenarios

    private static func runScenarios(_ scenarios: [VirtualDisplaySpikeScenario]) async {
        printHeader(scenarios)
        guard let primary = scenarios.first else { return }
        var results: [SpikeScenarioResult] = []
        for scenario in scenarios {
            results.append(await measure(scenario))
            try? await hold(1)
        }
        print("")
        for result in results { print(result.verdictLine(prefix: "VIRTUAL-DISPLAY-SPIKE-SCENARIO:")) }
        let verdict = results.first { $0.scenario.name == primary.name } ?? results[0]
        print(verdict.verdictLine(prefix: "VIRTUAL-DISPLAY-SPIKE:"))
    }

    private static func measure(_ scenario: VirtualDisplaySpikeScenario) async -> SpikeScenarioResult {
        let resources = SpikeResources()
        active = resources
        var result = SpikeScenarioResult(scenario: scenario)
        do {
            try await measure(scenario, using: resources, into: &result)
        } catch {
            result.error = String(describing: error)
            print("\(scenario.tag) ERROR \(error)")
        }
        await release(resources, tag: scenario.tag)
        active = nil
        return result
    }

    private static func measure(_ scenario: VirtualDisplaySpikeScenario, using resources: SpikeResources,
                                into result: inout SpikeScenarioResult) async throws {
        let tag = scenario.tag
        print("\n\(tag) creating \(scenario.summary)")
        let createdMs = MachClock.nowMs()
        let display = try PrivateVirtualDisplay.make(scenario) {
            print("\(tag) the system terminated the virtual display (terminationHandler)")
        }
        resources.display = display
        let id = PrivateVirtualDisplay.displayID(of: display)
        guard id != 0 else { throw SpikeFailure("the virtual display reports display ID 0") }
        resources.displayID = id
        guard await waitUntil(seconds: 5, { onlineDisplayIDs().contains(id) }) else {
            throw SpikeFailure("display \(id) never appeared in CGGetOnlineDisplayList")
        }
        print("\(tag) display \(id) online after \(format(MachClock.nowMs() - createdMs, 0)) ms")
        guard await waitUntil(seconds: 5, { screen(for: id) != nil }) else {
            throw SpikeFailure("no NSScreen for display \(id)")
        }
        if scenario.hiDPI {
            selectHiDPIMode(id, scenario: scenario, tag: tag)
            try await hold(1)
        }
        guard let virtualScreen = screen(for: id) else {
            throw SpikeFailure("the NSScreen for display \(id) went away")
        }
        result.reportedHz = reportDisplay(id, screen: virtualScreen, tag: tag)

        let view = SpikeMotionView(frame: NSRect(origin: .zero, size: virtualScreen.frame.size),
                                   scale: virtualScreen.backingScaleFactor)
        let window = makeWindow(on: virtualScreen, content: view)
        resources.window = window
        resources.view = view
        window.orderFrontRegardless()
        view.startTicking(preferredHz: Float(scenario.refreshHz))
        try await hold(1.5)
        print("\(tag) motion window \(window.frame) on screen \"\(window.screen?.localizedName ?? "?")\"")

        let scDisplay = try await shareableDisplay(id)
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let configuration = captureConfiguration(for: filter)
        let counter = SpikeFrameCounter()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: counter)
        resources.counter = counter
        resources.stream = stream
        try stream.addStreamOutput(counter, type: .screen, sampleHandlerQueue: counter.queue)
        try await stream.startCapture()
        print("\(tag) SCStream \(configuration.width)x\(configuration.height) minimumFrameInterval=.zero "
              + "queueDepth=\(configuration.queueDepth) pixelFormat=420v showsCursor=false")
        try await hold(1)

        let moving = try await record(counter: counter, view: view, seconds: movingSeconds)
        result.moving = moving.capture
        result.linkMoving = moving.link
        printPhase("moving \(movingSeconds) s", moving, tag: tag)

        view.stopTicking()
        try await hold(0.3)
        let idle = try await record(counter: counter, view: nil, seconds: idleSeconds)
        result.idle = idle.capture
        printPhase("idle \(idleSeconds) s (display link stopped)", idle, tag: tag)
        if let stopError = idle.sample.stopError ?? moving.sample.stopError {
            throw SpikeFailure("the stream stopped: \(stopError)")
        }
        let verdict = result.passes ? "GO" : "NO-GO"
        print("\(tag) verdict \(verdict): mean \(format(moving.capture.meanFPS, 1)) fps "
              + "(needs ≥ \(format(goMeanFPS, 0))), p90 gap \(format(moving.capture.p90GapMs, 2)) ms "
              + "(needs ≤ \(format(goP90GapMs, 0)))")
    }

    private static func record(counter: SpikeFrameCounter, view: SpikeMotionView?,
                               seconds: Int) async throws -> SpikePhase {
        let startMs = MachClock.nowMs()
        counter.begin()
        view?.beginRecording()
        // Frames displayed just before the window closes arrive a few ms later.
        try await hold(Double(seconds) + 0.15)
        let sample = counter.end()
        let ticks = view?.endRecording()
        return SpikePhase(
            sample: sample,
            capture: VirtualDisplaySpikeStats(timesMs: sample.displayTimesMs, startMs: startMs, seconds: seconds),
            link: ticks.map { VirtualDisplaySpikeStats(timesMs: $0.timesMs, startMs: startMs, seconds: seconds) },
            linkIntervalMs: ticks.flatMap { VirtualDisplaySpikeStats.percentile($0.intervalsMs.sorted(), 0.5) })
    }

    private static func release(_ resources: SpikeResources, tag: String) async {
        if let stream = resources.stream { try? await stream.stopCapture() }
        resources.stream = nil
        resources.counter = nil
        let id = resources.displayID
        resources.teardownNow()
        guard id != 0 else { return }
        let gone = await waitUntil(seconds: 5, { !onlineDisplayIDs().contains(id) })
        print(gone ? "\(tag) window closed, display \(id) removed"
                   : "\(tag) WARNING display \(id) still online 5 s after release")
    }

    // MARK: Display

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    private static func allModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }

    private static func describe(_ mode: CGDisplayMode) -> String {
        "\(mode.width)x\(mode.height) pt / \(mode.pixelWidth)x\(mode.pixelHeight) px "
            + "@ \(format(mode.refreshRate, 2)) Hz"
    }

    private static func describe(_ id: CGDirectDisplayID) -> String {
        let mode = CGDisplayCopyDisplayMode(id).map(describe) ?? "no mode"
        let refresh = DisplayRefresh.rateHz(for: id).map { format($0, 0) + " Hz" } ?? "unknown"
        return "\(mode), host reads \(refresh)\(CGDisplayIsMain(id) != 0 ? ", main" : "")"
    }

    /// HiDPI modes are listed in points; the 2× backing mode is not always the one macOS picks first.
    private static func selectHiDPIMode(_ id: CGDirectDisplayID, scenario: VirtualDisplaySpikeScenario, tag: String) {
        let width = Int(scenario.modeWidth)
        let pixelWidth = Int(scenario.pixelWidth)
        if let current = CGDisplayCopyDisplayMode(id), current.width == width, current.pixelWidth == pixelWidth {
            print("\(tag) HiDPI mode already current: \(describe(current))")
            return
        }
        guard let target = allModes(id).first(where: { $0.width == width && $0.pixelWidth == pixelWidth }) else {
            print("\(tag) no \(width) pt / \(pixelWidth) px mode offered; measuring the current mode")
            return
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            print("\(tag) CGBeginDisplayConfiguration failed; measuring the current mode")
            return
        }
        let configured = CGConfigureDisplayWithDisplayMode(config, id, target, nil)
        guard configured == .success else {
            CGCancelDisplayConfiguration(config)
            print("\(tag) CGConfigureDisplayWithDisplayMode failed (\(configured.rawValue)); "
                  + "measuring the current mode")
            return
        }
        // .forAppOnly: macOS restores the previous mode when this process exits.
        let completed = CGCompleteDisplayConfiguration(config, .forAppOnly)
        print("\(tag) switched to \(describe(target)) for this process (result \(completed.rawValue))")
    }

    private static func reportDisplay(_ id: CGDirectDisplayID, screen: NSScreen, tag: String) -> Double? {
        let mode = CGDisplayCopyDisplayMode(id)
        print("\(tag) CGDisplayCopyDisplayMode: \(mode.map(describe) ?? "nil"), "
              + "raw refreshRate \(mode.map { format($0.refreshRate, 3) } ?? "nil")")
        let bounds = CGDisplayBounds(id)
        print("\(tag) CGDisplayBounds: origin (\(format(Double(bounds.minX), 0)), \(format(Double(bounds.minY), 0))) "
              + "size \(format(Double(bounds.width), 0))x\(format(Double(bounds.height), 0)) pt; "
              + "CGDisplayPixelsWide/High \(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))")
        print("\(tag) NSScreen \"\(screen.localizedName)\": frame \(screen.frame), "
              + "backingScaleFactor \(format(Double(screen.backingScaleFactor), 1)), "
              + "maximumFramesPerSecond \(screen.maximumFramesPerSecond), "
              + "minimumRefreshInterval \(format(screen.minimumRefreshInterval * 1000, 3)) ms, "
              + "maximumRefreshInterval \(format(screen.maximumRefreshInterval * 1000, 3)) ms, "
              + "displayUpdateGranularity \(format(screen.displayUpdateGranularity * 1000, 3)) ms")
        print("\(tag) modes offered: \(allModes(id).map(describe).joined(separator: "; "))")
        let rate = DisplayRefresh.rateHz(for: id)
        let target = CaptureRatePolicy.targetFPS(displayRefreshHz: rate, tuning: .tuned)
        print("\(tag) host view: DisplayRefresh.rateHz \(rate.map { format($0, 2) } ?? "nil") -> "
              + "CaptureRatePolicy target \(target) fps")
        return rate
    }

    private static func makeWindow(on screen: NSScreen, content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.title = "Farside Virtual Display Spike"
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = content
        return window
    }

    // MARK: Capture

    private static func shareableDisplay(_ id: CGDirectDisplayID) async throws -> SCDisplay {
        let deadline = MachClock.nowMs() + 3000
        while true {
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                throw SpikeFailure("SCShareableContent failed: \(error) "
                                   + "(CGPreflightScreenCaptureAccess \(CGPreflightScreenCaptureAccess()))")
            }
            if let display = content.displays.first(where: { $0.displayID == id }) { return display }
            guard MachClock.nowMs() < deadline else {
                throw SpikeFailure("ScreenCaptureKit does not list display \(id)")
            }
            try await hold(0.2)
        }
    }

    private static func captureConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let scale = Double(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((Double(filter.contentRect.width) * scale).rounded()) & ~1
        configuration.height = Int((Double(filter.contentRect.height) * scale).rounded()) & ~1
        configuration.minimumFrameInterval = .zero
        configuration.queueDepth = CaptureRatePolicy.queueDepth(for: CaptureRatePolicy.highFPS)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return configuration
    }

    // MARK: Output

    private static func printHeader(_ scenarios: [VirtualDisplaySpikeScenario]) {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "not arm64 (unsupported)"
        #endif
        print("VIRTUAL-DISPLAY-SPIKE start: macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
              + "model \(hardwareModel()), \(arch), pid \(getpid())")
        print("CGPreflightScreenCaptureAccess \(CGPreflightScreenCaptureAccess())")
        for id in onlineDisplayIDs() { print("existing display \(id): \(describe(id))") }
        print("scenarios: \(scenarios.map(\.name).joined(separator: ", ")); "
              + "verdict from \(scenarios.first?.name ?? "-")")
        print("rule: GO when the \(movingSeconds)-s moving mean is ≥ \(format(goMeanFPS, 0)) distinct fps "
              + "and the p90 inter-frame gap is ≤ \(format(goP90GapMs, 0)) ms")
    }

    private static func printPhase(_ name: String, _ phase: SpikePhase, tag: String) {
        let capture = phase.capture
        let perSecond = capture.perSecond.map(String.init).joined(separator: " ")
        print("\(tag) \(name): distinct SCK frames per second \(perSecond)")
        print("\(tag) \(name): mean \(format(capture.meanFPS, 1)) fps, "
              + "gap median \(format(capture.medianGapMs, 2)) ms, p90 \(format(capture.p90GapMs, 2)) ms, "
              + "max \(format(capture.maxGapMs, 2)) ms, distinct \(capture.count)")
        let statuses = phase.sample.statuses.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\(statusName($0.key))=\($0.value)" }.joined(separator: " ")
        print("\(tag) \(name): statuses \(statuses.isEmpty ? "none" : statuses); "
              + "repeated displayTime \(phase.sample.repeatedDisplayTime), "
              + "missing displayTime \(phase.sample.missingDisplayTime)")
        if let link = phase.link {
            print("\(tag) \(name): display link \(format(link.meanFPS, 1)) ticks/s, tick gap median "
                  + "\(format(link.medianGapMs, 2)) ms, link interval median \(format(phase.linkIntervalMs, 2)) ms")
        }
    }

    private static func statusName(_ status: SCFrameStatus) -> String {
        switch status {
        case .complete: return "complete"
        case .idle: return "idle"
        case .blank: return "blank"
        case .suspended: return "suspended"
        case .started: return "started"
        case .stopped: return "stopped"
        @unknown default: return "status\(status.rawValue)"
        }
    }

    // MARK: Process

    private static func installSignalHandlers() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            _ = signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    active?.teardownNow()
                    active = nil
                    print("VIRTUAL-DISPLAY-SPIKE: ERROR reason=signal-\(number) (window and virtual display removed)")
                    exit(130)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private static func armTimeout() {
        let seconds = timeoutSeconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(seconds)) {
            print("VIRTUAL-DISPLAY-SPIKE: ERROR reason=timeout-\(seconds)s")
            // Exiting closes the window server connection, which removes the virtual display and the window.
            exit(3)
        }
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = MachClock.nowMs() + seconds * 1000
        while !condition() {
            guard MachClock.nowMs() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    private static func hold(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "?" }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    nonisolated static func format(_ value: Double?, _ decimals: Int) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.\(decimals)f", value)
    }
}

struct VirtualDisplaySpikeScenario {
    let name: String
    /// Mode size as CGVirtualDisplayMode takes it: pixels at 1×, points when HiDPI.
    let modeWidth: UInt32
    let modeHeight: UInt32
    let refreshHz: Double
    let hiDPI: Bool
    let productID: UInt32
    let serial: UInt32

    static let all = [
        VirtualDisplaySpikeScenario(name: "1x-120", modeWidth: 2560, modeHeight: 1440, refreshHz: 120, hiDPI: false,
                                    productID: 0x0120, serial: 0x0120),
        VirtualDisplaySpikeScenario(name: "1x-144", modeWidth: 2560, modeHeight: 1440, refreshHz: 144, hiDPI: false,
                                    productID: 0x0144, serial: 0x0144),
        VirtualDisplaySpikeScenario(name: "hidpi-120", modeWidth: 1280, modeHeight: 720, refreshHz: 120, hiDPI: true,
                                    productID: 0x2120, serial: 0x2120)
    ]

    var pixelWidth: UInt32 { hiDPI ? modeWidth * 2 : modeWidth }
    var pixelHeight: UInt32 { hiDPI ? modeHeight * 2 : modeHeight }
    var tag: String { "[\(name)]" }
    var displayName: String { "Farside Spike \(name)" }

    var summary: String {
        let size = hiDPI ? "\(modeWidth)x\(modeHeight) pt HiDPI (\(pixelWidth)x\(pixelHeight) px)"
                         : "\(modeWidth)x\(modeHeight) px 1x"
        return "\"\(displayName)\": \(size) @ \(VirtualDisplaySpike.format(refreshHz, 0)) Hz"
    }
}

/// Distinct-frame statistics over one measurement window, from display timestamps in mach milliseconds.
struct VirtualDisplaySpikeStats {
    let seconds: Int
    let perSecond: [Int]
    let count: Int
    let meanFPS: Double
    let medianGapMs: Double?
    let p90GapMs: Double?
    let maxGapMs: Double?

    init(timesMs: [Double], startMs: Double, seconds: Int) {
        let endMs = startMs + Double(seconds) * 1000
        let inside = timesMs.filter { $0 >= startMs && $0 < endMs }.sorted()
        var buckets = [Int](repeating: 0, count: max(seconds, 1))
        for time in inside { buckets[min(buckets.count - 1, Int((time - startMs) / 1000))] += 1 }
        let gaps = zip(inside.dropFirst(), inside).map { $0 - $1 }.sorted()
        self.seconds = seconds
        perSecond = buckets
        count = inside.count
        meanFPS = seconds > 0 ? Double(inside.count) / Double(seconds) : 0
        medianGapMs = Self.percentile(gaps, 0.5)
        p90GapMs = Self.percentile(gaps, 0.9)
        maxGapMs = gaps.last
    }

    var passes: Bool {
        guard let p90GapMs else { return false }
        return meanFPS >= VirtualDisplaySpike.goMeanFPS && p90GapMs <= VirtualDisplaySpike.goP90GapMs
    }

    /// Nearest rank on an ascending sample.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

private struct SpikeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct SpikePhase {
    let sample: SpikeCaptureSample
    let capture: VirtualDisplaySpikeStats
    let link: VirtualDisplaySpikeStats?
    let linkIntervalMs: Double?
}

private struct SpikeScenarioResult {
    let scenario: VirtualDisplaySpikeScenario
    var reportedHz: Double?
    var moving: VirtualDisplaySpikeStats?
    var linkMoving: VirtualDisplaySpikeStats?
    var idle: VirtualDisplaySpikeStats?
    var error: String?

    init(scenario: VirtualDisplaySpikeScenario) { self.scenario = scenario }

    var passes: Bool { error == nil && moving?.passes == true }

    func verdictLine(prefix: String) -> String {
        func format(_ value: Double?, _ decimals: Int) -> String { VirtualDisplaySpike.format(value, decimals) }
        guard error == nil, let moving else {
            let reason = (error ?? "no measurement").replacingOccurrences(of: "\"", with: "'")
            return "\(prefix) ERROR reason=\"\(reason)\" scenario=\(scenario.name)"
        }
        return [prefix, passes ? "GO" : "NO-GO", "fps=\(format(moving.meanFPS, 1))",
                "p90gap=\(format(moving.p90GapMs, 2))ms", "median=\(format(moving.medianGapMs, 2))ms",
                "distinct=\(moving.count)", "reported=\(format(reportedHz, 0))Hz",
                "link=\(format(linkMoving?.meanFPS, 1))", "idle=\(format(idle?.meanFPS, 1))",
                "scenario=\(scenario.name)"].joined(separator: " ")
    }
}

@MainActor
private final class SpikeResources {
    var display: NSObject?
    var displayID: CGDirectDisplayID = 0
    var window: NSWindow?
    var view: SpikeMotionView?
    var stream: SCStream?
    var counter: SpikeFrameCounter?

    /// Releasing the CGVirtualDisplay object is what removes the display.
    func teardownNow() {
        view?.stopTicking()
        view = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        display = nil
    }
}

// MARK: - Private CoreGraphics classes

/// CoreGraphics' virtual-display classes are SPI with no public header. They are looked up at run time
/// (NSClassFromString, class_getInstanceMethod) so nothing links a private symbol; selectors and type
/// encodings were read from the macOS 27.0 (26A428) runtime. Scalar and struct properties go through
/// KVC, which unboxes NSNumber and NSValue into the setter's argument.
private enum PrivateVirtualDisplay {
    private typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    // initWithWidth:height:refreshRate: is "@32@0:8I16I20d24": unsigned int, unsigned int, double.
    private typealias ModeInit = @convention(c) (Unmanaged<AnyObject>, Selector, UInt32, UInt32, Double)
        -> Unmanaged<AnyObject>?
    private typealias DisplayInit = @convention(c) (Unmanaged<AnyObject>, Selector, AnyObject) -> Unmanaged<AnyObject>?
    private typealias ApplySettings = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

    private static let vendorID: UInt32 = 0xFA51
    // The ASUS VG32VQ1B's panel, so macOS sizes the virtual display like the real 144 Hz source.
    private static let sizeInMillimeters = NSSize(width: 697, height: 392)

    static func make(_ scenario: VirtualDisplaySpikeScenario, onTermination: @escaping () -> Void) throws -> NSObject {
        let descriptor = try plainInstance("CGVirtualDisplayDescriptor")
        try set(descriptor, "queue", DispatchQueue.main)
        try set(descriptor, "name", scenario.displayName)
        try set(descriptor, "maxPixelsWide", NSNumber(value: scenario.pixelWidth))
        try set(descriptor, "maxPixelsHigh", NSNumber(value: scenario.pixelHeight))
        try set(descriptor, "sizeInMillimeters", NSValue(size: sizeInMillimeters))
        try set(descriptor, "vendorID", NSNumber(value: vendorID))
        try set(descriptor, "productID", NSNumber(value: scenario.productID))
        try set(descriptor, "serialNum", NSNumber(value: scenario.serial))
        let handler: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in onTermination() }
        try set(descriptor, "terminationHandler", unsafeBitCast(handler, to: AnyObject.self))

        let display = try construct("CGVirtualDisplay", "initWithDescriptor:", as: DisplayInit.self) {
            function, allocated, selector in
            function(allocated, selector, descriptor)
        }
        let mode = try construct("CGVirtualDisplayMode", "initWithWidth:height:refreshRate:", as: ModeInit.self) {
            function, allocated, selector in
            function(allocated, selector, scenario.modeWidth, scenario.modeHeight, scenario.refreshHz)
        }
        let settings = try plainInstance("CGVirtualDisplaySettings")
        try set(settings, "hiDPI", NSNumber(value: UInt32(scenario.hiDPI ? 1 : 0)))
        try set(settings, "modes", [mode] as NSArray)
        let (apply, selector) = try instanceMethod(type(of: display), "applySettings:", as: ApplySettings.self)
        guard apply(display, selector, settings) else {
            throw SpikeFailure("-[CGVirtualDisplay applySettings:] returned NO")
        }
        return display
    }

    static func displayID(of display: NSObject) -> CGDirectDisplayID {
        guard display.responds(to: NSSelectorFromString("displayID")) else { return 0 }
        return (display.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
    }

    private static func privateClass(_ name: String) throws -> AnyClass {
        guard let cls = NSClassFromString(name) else { throw SpikeFailure("class \(name) is missing") }
        return cls
    }

    private static func plainInstance(_ name: String) throws -> NSObject {
        guard let objectType = try privateClass(name) as? NSObject.Type else {
            throw SpikeFailure("\(name) is not an NSObject")
        }
        return objectType.init()
    }

    private static func instanceMethod<T>(_ cls: AnyClass, _ selectorName: String,
                                          as type: T.Type) throws -> (T, Selector) {
        let selector = NSSelectorFromString(selectorName)
        guard let found = class_getInstanceMethod(cls, selector) else {
            throw SpikeFailure("-[\(NSStringFromClass(cls)) \(selectorName)] is missing")
        }
        return (unsafeBitCast(method_getImplementation(found), to: type), selector)
    }

    /// +alloc then the given initializer; the initializer consumes the allocation and returns +1.
    private static func construct<T>(
        _ className: String, _ initializer: String, as type: T.Type,
        call: (T, Unmanaged<AnyObject>, Selector) -> Unmanaged<AnyObject>?
    ) throws -> NSObject {
        let cls = try privateClass(className)
        let (function, selector) = try instanceMethod(cls, initializer, as: type)
        let allocSelector = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(cls, allocSelector) else {
            throw SpikeFailure("+[\(className) alloc] is missing")
        }
        let alloc = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)
        guard let allocated = alloc(cls, allocSelector) else { throw SpikeFailure("+[\(className) alloc] failed") }
        guard let object = call(function, allocated, selector)?.takeRetainedValue() as? NSObject else {
            throw SpikeFailure("-[\(className) \(initializer)] returned nil")
        }
        return object
    }

    private static func set(_ object: NSObject, _ key: String, _ value: Any) throws {
        let setter = "set\(key.prefix(1).uppercased())\(key.dropFirst()):"
        guard object.responds(to: NSSelectorFromString(setter)) else {
            throw SpikeFailure("-[\(NSStringFromClass(type(of: object))) \(setter)] is missing")
        }
        object.setValue(value, forKey: key)
    }
}

// MARK: - Capture counting

private struct SpikeCaptureSample {
    let displayTimesMs: [Double]
    let statuses: [SCFrameStatus: Int]
    let repeatedDisplayTime: Int
    let missingDisplayTime: Int
    let stopError: String?
}

/// Counts complete frames by distinct ScreenCaptureKit `displayTime`, only while recording.
private final class SpikeFrameCounter: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "Farside.VirtualDisplaySpike.capture", qos: .userInteractive)
    private var recording = false
    private var displayTimes: [UInt64] = []
    private var lastDisplayTime: UInt64 = 0
    private var statuses: [SCFrameStatus: Int] = [:]
    private var repeatedDisplayTime = 0
    private var missingDisplayTime = 0
    private var stopError: String?

    override init() {
        super.init()
        displayTimes.reserveCapacity(4096)
    }

    func begin() {
        queue.sync {
            displayTimes.removeAll(keepingCapacity: true)
            statuses = [:]
            repeatedDisplayTime = 0
            missingDisplayTime = 0
            recording = true
        }
    }

    func end() -> SpikeCaptureSample {
        queue.sync {
            recording = false
            return SpikeCaptureSample(displayTimesMs: displayTimes.map(MachClock.milliseconds(fromMachTicks:)),
                                      statuses: statuses, repeatedDisplayTime: repeatedDisplayTime,
                                      missingDisplayTime: missingDisplayTime, stopError: stopError)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, recording, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        statuses[status, default: 0] += 1
        guard status == .complete else { return }
        let displayTime = (info[.displayTime] as? NSNumber)?.uint64Value ?? 0
        if displayTime == 0 {
            missingDisplayTime += 1
        } else if displayTime == lastDisplayTime {
            repeatedDisplayTime += 1
        } else {
            lastDisplayTime = displayTime
            displayTimes.append(displayTime)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = String(describing: error)
        queue.async { self.stopError = message }
    }
}

// MARK: - Moving content

/// A full-screen black view whose white bar moves and whose counter advances on every display-link tick,
/// so every refresh of the virtual display changes pixels.
private final class SpikeMotionView: NSView {
    private let bar = CALayer()
    private let counter = CATextLayer()
    private var link: CADisplayLink?
    private var frameIndex = 0
    private var recording = false
    private var tickTimesMs: [Double] = []
    private var intervalsMs: [Double] = []

    init(frame: NSRect, scale: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        bar.backgroundColor = NSColor.white.cgColor
        bar.frame = CGRect(x: 0, y: 0, width: 96, height: frame.height)
        counter.foregroundColor = NSColor.systemGreen.cgColor
        counter.fontSize = 120
        counter.contentsScale = scale
        counter.frame = CGRect(x: 48, y: max(0, frame.height - 220), width: 1200, height: 160)
        layer?.addSublayer(bar)
        layer?.addSublayer(counter)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func startTicking(preferredHz: Float) {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: preferredHz, maximum: preferredHz,
                                                        preferred: preferredHz)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stopTicking() {
        link?.invalidate()
        link = nil
    }

    func beginRecording() {
        tickTimesMs.removeAll(keepingCapacity: true)
        intervalsMs.removeAll(keepingCapacity: true)
        recording = true
    }

    func endRecording() -> (timesMs: [Double], intervalsMs: [Double]) {
        recording = false
        return (tickTimesMs, intervalsMs)
    }

    @objc private func tick(_ link: CADisplayLink) {
        frameIndex += 1
        if recording {
            tickTimesMs.append(MachClock.milliseconds(fromMediaTime: link.timestamp))
            intervalsMs.append((link.targetTimestamp - link.timestamp) * 1000)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let travel = max(1, bounds.width - bar.frame.width)
        bar.frame.origin.x = CGFloat((frameIndex * 16) % Int(travel))
        counter.string = "\(frameIndex)"
        CATransaction.commit()
    }
}
#endif
