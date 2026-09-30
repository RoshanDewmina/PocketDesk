import AppKit
import CoreVideo
import SwiftUI

/// Three separate Escape presses at the Mac, close together, lift the curtain. Key repeats and
/// keys the phone injected never count.
struct EscapeTripleTap: Equatable {
    static let presses = 3
    static let window: TimeInterval = 2

    private(set) var recent: [TimeInterval] = []

    mutating func register(at time: TimeInterval, isRepeat: Bool, injected: Bool) -> Bool {
        guard !isRepeat, !injected else { return false }
        recent = recent.filter { time >= $0 && time - $0 <= Self.window }
        recent.append(time)
        guard recent.count >= Self.presses else { return false }
        recent.removeAll()
        return true
    }

    mutating func reset() {
        recent.removeAll()
    }
}

struct PrivacyCurtainInputs: Equatable {
    var preference = false
    /// A phone is connected to an active share and the host is not quitting.
    var sessionLive = false
    var captureHealthy = false
    /// How long capture has been continuously unhealthy.
    var unhealthyFor: TimeInterval = 0
    var displayAsleep = false
    var phonePaused = false
    var screenLocked = false
    /// The local Escape shortcut needs Accessibility, so the curtain does too.
    var accessibilityGranted = false
    var locallyDismissed = false
    var raiseFailed = false
    var safeMode = false
    /// Away mode wants the Mac covered, with or without a phone.
    var awayCovered = false
}

enum PrivacyCurtainPolicy {
    /// Short capture hiccups do not flicker the curtain.
    static let unhealthyGrace: TimeInterval = 5

    enum Desired: Equatable { case up, down }

    static func desired(_ inputs: PrivacyCurtainInputs, currentlyUp: Bool) -> Desired {
        if inputs.awayCovered { return inputs.screenLocked ? .down : .up }
        guard inputs.preference, inputs.sessionLive, !inputs.phonePaused, !inputs.screenLocked,
              !inputs.safeMode, !inputs.locallyDismissed, !inputs.raiseFailed,
              inputs.accessibilityGranted else { return .down }
        if currentlyUp {
            let lostPicture = !inputs.captureHealthy && !inputs.displayAsleep && inputs.unhealthyFor > unhealthyGrace
            return lostPicture ? .down : .up
        }
        // Raise only against a live picture, so the stream can be checked afterwards.
        return inputs.captureHealthy ? .up : .down
    }

    static func protocolState(_ inputs: PrivacyCurtainInputs, up: Bool) -> PrivacyCurtainState {
        guard inputs.preference else { return .off }
        if inputs.locallyDismissed { return .liftedLocally }
        if inputs.raiseFailed { return .failed }
        if !inputs.accessibilityGranted { return .unavailable }
        return up ? .up : .pending
    }
}

/// Resolves the curtain's windows among ScreenCaptureKit's shareable windows. Every curtain window
/// must be found; excluding only some of them would leave part of the curtain in the stream.
enum CaptureWindowExclusion {
    static func windows<Window>(for ids: Set<CGWindowID>, in available: [Window],
                                id: (Window) -> CGWindowID) -> [Window]? {
        guard !ids.isEmpty else { return nil }
        let matches = available.filter { ids.contains(id($0)) }
        guard Set(matches.map(id)) == ids else { return nil }
        return matches
    }
}

/// A coarse 8 × 8 grid of luma samples from a captured frame; it cannot reproduce the picture.
struct CaptureLumaSignature: Equatable {
    static let side = 8
    let samples: [UInt8]

    init?(samples: [UInt8]) {
        guard samples.count == Self.side * Self.side else { return nil }
        self.samples = samples
    }

    init?(pixelBuffer: CVPixelBuffer) {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let side = Self.side
        var values: [UInt8] = []
        values.reserveCapacity(side * side)
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            guard width > 0, height > 0 else { return nil }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<side {
                for column in 0..<side {
                    let y = min(height - 1, (2 * row + 1) * height / (2 * side))
                    let x = min(width - 1, (2 * column + 1) * width / (2 * side))
                    values.append(bytes[y * stride + x])
                }
            }
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard width > 0, height > 0 else { return nil }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<side {
                for column in 0..<side {
                    let y = min(height - 1, (2 * row + 1) * height / (2 * side))
                    let x = min(width - 1, (2 * column + 1) * width / (2 * side))
                    let pixel = y * stride + x * 4
                    let luma = (29 * Int(bytes[pixel]) + 150 * Int(bytes[pixel + 1]) + 77 * Int(bytes[pixel + 2])) >> 8
                    values.append(UInt8(min(255, luma)))
                }
            }
        default:
            return nil
        }
        self.samples = values
    }
}

/// After the curtain goes up, the stream should look the same as before. If it suddenly turns
/// almost uniformly curtain-dark, the exclusion did not take effect.
enum CurtainCanary {
    /// Video-range luma for the curtain's #050505 is about 20; full range about 5.
    static let darkLuma: UInt8 = 40
    static let darkShare = 0.9

    static func looksLikeCurtain(_ signature: CaptureLumaSignature) -> Bool {
        let dark = signature.samples.filter { $0 <= darkLuma }.count
        return Double(dark) >= darkShare * Double(signature.samples.count)
    }

    /// Nil signatures, or a desktop that was already dark, cannot prove a failure.
    static func exclusionFailed(before: CaptureLumaSignature?, after: CaptureLumaSignature?) -> Bool {
        guard let before, let after else { return false }
        return !looksLikeCurtain(before) && looksLikeCurtain(after)
    }
}

/// Opaque windows covering every display while a phone is connected. They belong to this process,
/// so they vanish if the host crashes or is ended by its hang watchdog, and they are excluded from
/// the host's own ScreenCaptureKit filter so the phone keeps seeing the real desktop.
@MainActor
final class PrivacyCurtainController {
    enum Phase: Equatable { case down, raising, up }

    enum RaiseResult: Equatable {
        case raised, cancelled, noScreens, exclusionFailed, verificationFailed
    }

    struct CaptureHooks {
        /// Returns true once the live capture filter excludes every given window.
        var exclude: (Set<CGWindowID>) async -> Bool
        var signature: () async -> CaptureLumaSignature?
    }

    private(set) var phase: Phase = .down
    /// Called before the curtain lifts after three local Escape presses.
    var onLocalLift: (() -> Void)?
    var onPhaseChange: ((Phase) -> Void)?
    private(set) var style: PrivacyCurtainStyle = .sharing
    /// Away mode turns this off: its cover ends only by locking the Mac.
    var escapeLiftEnabled = true
    /// When false, a display change is reported through `onScreensChanged` instead of lifting.
    var liftsOnScreenChange = true
    var onScreensChanged: (() -> Void)?
    /// One window per display. Tests substitute tiny off-screen windows so nothing is ever shown.
    private let makeWindows: (() -> [NSWindow])?

    init(makeWindows: (() -> [NSWindow])? = nil) {
        self.makeWindows = makeWindows
    }

    private var windows: [NSWindow] = []
    private var monitors: [Any] = []
    private var escape = EscapeTripleTap()
    private var generation: UInt64 = 0
    private var screenObserver: NSObjectProtocol?

    var windowIDs: Set<CGWindowID> { Set(windows.map { CGWindowID($0.windowNumber) }) }

    func raise(hooks: CaptureHooks,
               settle: Duration = .milliseconds(150),
               verifyAfter: Duration = .milliseconds(500)) async -> RaiseResult {
        guard phase == .down else { return phase == .up ? .raised : .cancelled }
        generation &+= 1
        let current = generation
        phase = .raising
        // Transparent until the stream is known to exclude them.
        windows = makeWindows?() ?? NSScreen.screens.map { Self.makeWindow(for: $0, style: style) }
        guard !windows.isEmpty else { phase = .down; return .noScreens }
        windows.forEach { $0.orderFrontRegardless() }
        observeScreenChanges()
        let excluded = await hooks.exclude(windowIDs)
        guard isCurrent(current, .raising) else { return .cancelled }
        guard excluded else { tearDown(); return .exclusionFailed }

        try? await Task.sleep(for: settle)
        guard isCurrent(current, .raising) else { return .cancelled }
        let before = await hooks.signature()
        guard isCurrent(current, .raising) else { return .cancelled }

        windows.forEach { $0.alphaValue = 1 }
        phase = .up
        installKeyMonitors()
        onPhaseChange?(.up)

        try? await Task.sleep(for: verifyAfter)
        guard isCurrent(current, .up) else { return .cancelled }
        let after = await hooks.signature()
        guard isCurrent(current, .up) else { return .cancelled }
        if CurtainCanary.exclusionFailed(before: before, after: after) {
            lift()
            return .verificationFailed
        }
        return .raised
    }

    func lift() {
        generation &+= 1
        let wasShowing = phase != .down
        tearDown()
        if wasShowing { onPhaseChange?(.down) }
    }

    func setStyle(_ style: PrivacyCurtainStyle) {
        self.style = style
        for window in windows {
            (window.contentView as? NSHostingView<PrivacyCurtainView>)?.rootView = PrivacyCurtainView(style: style)
        }
    }

    func handleScreenParametersChanged() {
        if liftsOnScreenChange { lift() } else { onScreensChanged?() }
    }

    /// Feeds a key-down seen by the local or global monitor. Exposed for tests.
    @discardableResult
    func handleKeyDown(keyCode: UInt16, timestamp: TimeInterval, isRepeat: Bool, injected: Bool) -> Bool {
        guard phase == .up, escapeLiftEnabled, keyCode == Self.escapeKeyCode,
              escape.register(at: timestamp, isRepeat: isRepeat, injected: injected) else { return false }
        onLocalLift?()
        lift()
        return true
    }

    static let escapeKeyCode: UInt16 = 53

    private func isCurrent(_ token: UInt64, _ expected: Phase) -> Bool {
        token == generation && phase == expected
    }

    private func tearDown() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        escape.reset()
        phase = .down
    }

    private func installKeyMonitors() {
        guard monitors.isEmpty else { return }
        // Keys aimed at other apps. Needs Accessibility; the curtain is only offered with it.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let key = Self.keyFacts(event)
            Task { @MainActor in
                self?.handleKeyDown(keyCode: key.code, timestamp: key.time, isRepeat: key.isRepeat, injected: key.injected)
            }
        }) {
            monitors.append(global)
        }
        // Keys aimed at Farside's own windows, if one was focused when the curtain went up.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let key = Self.keyFacts(event)
            Task { @MainActor in
                self?.handleKeyDown(keyCode: key.code, timestamp: key.time, isRepeat: key.isRepeat, injected: key.injected)
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    private nonisolated static func keyFacts(_ event: NSEvent) -> (code: UInt16, time: TimeInterval, isRepeat: Bool, injected: Bool) {
        (event.keyCode, event.timestamp, event.isARepeat, RemoteInputTag.isInjected(event.cgEvent))
    }

    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        // A display added or removed would be left uncovered or half-covered: lift everything.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenParametersChanged() }
        }
    }

    static func makeWindow(for screen: NSScreen, style: PrivacyCurtainStyle = .sharing) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Injected clicks must reach the apps underneath.
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = NSColor(srgbRed: 5 / 255, green: 5 / 255, blue: 5 / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.title = "Farside privacy curtain"
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: PrivacyCurtainView(style: style))
        return window
    }
}

enum PrivacyCurtainStyle: Equatable {
    case sharing, away, awayLockFailed
}

struct PrivacyCurtainView: View {
    var style: PrivacyCurtainStyle = .sharing

    private var title: LocalizedStringKey {
        switch style {
        case .sharing: "This Mac is being used remotely"
        case .away, .awayLockFailed: "Away mode is on"
        }
    }

    private var line: LocalizedStringKey {
        switch style {
        case .sharing: "Press Esc three times to lift"
        case .away: "Touching the keyboard, mouse or trackpad locks this Mac"
        case .awayLockFailed: "Farside couldn’t lock this Mac. It locks when the display sleeps"
        }
    }

    var body: some View {
        ZStack {
            Farside.Palette.void.ignoresSafeArea()
            VStack(spacing: Farside.Space.s) {
                HStack(spacing: Farside.Space.s) {
                    Circle()
                        .fill(Farside.Palette.ember)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Farside.Palette.bone)
                }
                Text(line)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Farside.Palette.ash)
            }
            .multilineTextAlignment(.center)
            .padding(Farside.Space.xl)
        }
    }
}
