import CoreGraphics
import Foundation

enum DisplayModeApplyResult: Equatable { case applied, failed(Int32) }

@MainActor
protocol DisplayModeSwitching: AnyObject {
    func currentMode(of display: CGDirectDisplayID) -> DisplayModeInfo?
    func modes(of display: CGDirectDisplayID) -> [DisplayModeInfo]
    func apply(_ mode: DisplayModeInfo, to display: CGDirectDisplayID) -> DisplayModeApplyResult
    func onlineDisplays() -> Set<CGDirectDisplayID>
}

struct DisplayReconfigurationEvent: Equatable {
    let display: CGDirectDisplayID
    let flags: CGDisplayChangeSummaryFlags
}

struct OwnChangeRecognizer {
    enum Verdict: Equatable { case pending, ours, foreign }
    static let timeout: TimeInterval = 10
    private static let structural: CGDisplayChangeSummaryFlags =
        [.addFlag, .removeFlag, .enabledFlag, .disabledFlag, .mirrorFlag, .unMirrorFlag]

    let display: CGDirectDisplayID
    let target: DisplayModeInfo
    let onlineBefore: Set<CGDirectDisplayID>
    let startedAt: TimeInterval
    private(set) var sawSetMode = false
    private(set) var sawStructuralChange = false

    init(display: CGDirectDisplayID, target: DisplayModeInfo, onlineBefore: Set<CGDirectDisplayID>, startedAt: TimeInterval) {
        self.display = display
        self.target = target
        self.onlineBefore = onlineBefore
        self.startedAt = startedAt
    }

    mutating func observe(_ event: DisplayReconfigurationEvent) {
        guard !event.flags.contains(.beginConfigurationFlag) else { return }
        if !event.flags.isDisjoint(with: Self.structural) { sawStructuralChange = true }
        if event.display == display, event.flags.contains(.setModeFlag) { sawSetMode = true }
    }

    func verdict(now: TimeInterval, online: Set<CGDirectDisplayID>, current: DisplayModeInfo?) -> Verdict {
        if sawStructuralChange || online != onlineBefore { return .foreign }
        if sawSetMode, current?.ioModeID == target.ioModeID { return .ours }
        return now - startedAt > Self.timeout ? .foreign : .pending
    }
}

@MainActor
final class LiveDisplayModeSwitcher: DisplayModeSwitching {
    func currentMode(of display: CGDirectDisplayID) -> DisplayModeInfo? { CGDisplayCopyDisplayMode(display).map(Self.info) }

    func modes(of display: CGDirectDisplayID) -> [DisplayModeInfo] { raw(display).map(Self.info) }

    func apply(_ mode: DisplayModeInfo, to display: CGDirectDisplayID) -> DisplayModeApplyResult {
        guard let target = raw(display).first(where: { $0.ioDisplayModeID == mode.ioModeID }) else {
            return .failed(CGError.illegalArgument.rawValue)
        }
        var config: CGDisplayConfigRef?
        let begun = CGBeginDisplayConfiguration(&config)
        guard begun == .success, let config else { return .failed(begun.rawValue) }
        let configured = CGConfigureDisplayWithDisplayMode(config, display, target, nil)
        guard configured == .success else {
            CGCancelDisplayConfiguration(config)
            return .failed(configured.rawValue)
        }
        // App-only scope reverts on application termination. SIGKILL/watchdog behaviour still
        // needs the physical acceptance check; it is not proved by successful configuration.
        let completed = CGCompleteDisplayConfiguration(config, .forAppOnly)
        return completed == .success ? .applied : .failed(completed.rawValue)
    }

    func onlineDisplays() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Set(ids.prefix(Int(count)))
    }

    private func raw(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
    }

    nonisolated static func info(_ mode: CGDisplayMode) -> DisplayModeInfo {
        DisplayModeInfo(ioModeID: mode.ioDisplayModeID, width: mode.width, height: mode.height,
                        pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                        refreshRate: mode.refreshRate, usableForDesktopGUI: mode.isUsableForDesktopGUI())
    }
}

@MainActor
final class DisplayReconfigurationMonitor {
    private let handler: (DisplayReconfigurationEvent) -> Void
    private var registered = false

    init(handler: @escaping (DisplayReconfigurationEvent) -> Void) { self.handler = handler }

    func start() {
        guard !registered else { return }
        registered = CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque()) == .success
    }

    func stop() {
        guard registered else { return }
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        registered = false
    }

    fileprivate func deliver(_ event: DisplayReconfigurationEvent) { handler(event) }
}

// CoreGraphics calls this on whatever thread it likes, so it must not inherit the monitor's main-actor isolation.
private nonisolated func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
                                     _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let event = DisplayReconfigurationEvent(display: display, flags: flags)
    let monitor = Unmanaged<DisplayReconfigurationMonitor>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { MainActor.assumeIsolated { monitor.deliver(event) } }
}
