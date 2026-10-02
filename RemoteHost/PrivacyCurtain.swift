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
    /// How long the phone has been backgrounded; a raised curtain stays for a short app switch.
    var pausedFor: TimeInterval = 0
    /// Seconds since the phone's last heartbeat, 0 when none has been seen this session.
    var phoneSilentFor: TimeInterval = 0
    /// The session just ended and Big Text is still restoring the Mac's own size under the curtain.
    var restoreHold = false
    var screenLocked = false
    /// The local Escape shortcut needs Accessibility, so the curtain does too.
    var accessibilityGranted = false
    var locallyDismissed = false
    var raiseFailed = false
    var safeMode = false
    /// Big Text is changing the display mode; capture blips during it must not uncover the Mac.
    var displayReconfiguring = false
    /// Away mode wants the Mac covered, with or without a phone.
    var awayCovered = false
}

enum PrivacyCurtainPolicy {
    /// Short capture hiccups do not flicker the curtain.
    static let unhealthyGrace: TimeInterval = 5
    /// A backgrounded phone keeps the Mac covered this long (BackgroundContinuity.maximumHold);
    /// after that nobody is coming back soon and a covered Mac with no phone is the worse failure.
    static let pausedHold: TimeInterval = BackgroundContinuity.maximumHold
    /// The phone heartbeats every 0.25 s in picture mode; this much silence means it is gone even
    /// if the media link has not noticed yet.
    static let phoneSilenceLimit: TimeInterval = 10
    /// After a session ends, Big Text's restore may finish under the curtain for at most this long.
    static let restoreHoldLimit: TimeInterval = 3
    /// The first Big Text change of a session waits this long for the curtain to go up first.
    static let scaleHoldLimit: TimeInterval = 1
    /// A restore that has not begun this long after the session ended is a reconnect grace, not a
    /// restore: the hold ends and the Mac uncovers. Must exceed the host's deliberate-End restore delay.
    static let restoreHoldDetect: TimeInterval = 1.5

    enum Desired: Equatable { case up, down }

    /// The post-session hold ends once an observed restore has finished and nothing is still
    /// refreshing: Big Text clears its phase before it moves windows back, so `needsRefresh`
    /// (the host flag set while a change is in flight) is what proves the windows are done.
    static func restoreHoldShouldEnd(observed: Bool, engaged: Bool, changing: Bool, needsRefresh: Bool) -> Bool {
        observed && !engaged && !changing && !needsRefresh
    }

    /// Whether the session's first Big Text change should wait for the curtain: only while the
    /// curtain is expected to go up and nothing has already decided otherwise.
    static func scaleShouldWait(curtainUp: Bool, expected: Bool, raiseFailed: Bool, liftedLocally: Bool,
                                paused: Bool, bigTextEngaged: Bool) -> Bool {
        !curtainUp && expected && !raiseFailed && !liftedLocally && !paused && !bigTextEngaged
    }

    static func heldScaleMayApply(connected: Bool, sharing: Bool, picture: Bool, viewOnly: Bool,
                                  paused: Bool, refused: Bool, ending: Bool, sameEpoch: Bool) -> Bool {
        connected && sharing && picture && !viewOnly && !paused && !refused && !ending && sameEpoch
    }

    static func desired(_ inputs: PrivacyCurtainInputs, currentlyUp: Bool) -> Desired {
        // Only the Away machine's positive verifier retires awayCovered; notifications cannot.
        if inputs.awayCovered { return .up }
        guard inputs.preference, !inputs.screenLocked, !inputs.safeMode, !inputs.locallyDismissed,
              !inputs.raiseFailed, inputs.accessibilityGranted else { return .down }
        if currentlyUp && inputs.restoreHold && !inputs.sessionLive { return .up }
        guard inputs.sessionLive else { return .down }
        if inputs.phonePaused { return currentlyUp && inputs.pausedFor <= pausedHold ? .up : .down }
        // Regardless of phase: Mac capture stays healthy when the phone vanishes, so a raise here
        // would flap against the lowering below until the media link notices.
        if inputs.phoneSilentFor > phoneSilenceLimit { return .down }
        if currentlyUp && inputs.displayReconfiguring { return .up }
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

/// Own mode changes preserve the screen arrangement. Cover the current desktop plus twice the
/// target/current size delta in each direction: neighbouring origins and AppKit's flipped Y
/// origin can both shift by that delta. Foreign topology changes still lift the curtain.
enum CurtainDisplayCoverage {
    static func envelope(frames: [CGRect], currentSize: CGSize, targetSize: CGSize) -> CGRect {
        let desktop = frames.reduce(CGRect.null) { $0.union($1) }
        guard !desktop.isNull else { return .null }
        let dx = 2 * abs(targetSize.width - currentSize.width) + 1
        let dy = 2 * abs(targetSize.height - currentSize.height) + 1
        return desktop.insetBy(dx: -dx, dy: -dy)
    }

    static func matchesAppKit(frame: CGRect, bounds: CGRect, mainHeight: CGFloat) -> Bool {
        BigTextRefresh.matches(frame: frame,
                              coreGraphicsBounds: CGRect(x: bounds.minX, y: mainHeight - bounds.maxY,
                                                        width: bounds.width, height: bounds.height))
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
    /// False while the host itself changes a display mode; it then calls `refitToScreens()`.
    var followsScreenChanges = true
    /// Both observers use the host's verified receipt, so a late duplicate never lifts the curtain.
    var ownsScreenChange: (() -> Bool)?
    private var changeCoverage: CGRect?
    private var finishingDisplayChange = false
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
        // Sharing waits for exclusion; Away protects the local screen before any async work.
        windows = makeWindows?() ?? NSScreen.screens.map { Self.makeWindow(for: $0, style: style) }
        guard !windows.isEmpty else { phase = .down; return .noScreens }
        if style != .sharing { windows.forEach { $0.alphaValue = 1 } }
        windows.forEach { $0.orderFrontRegardless() }
        observeScreenChanges()
        if style != .sharing {
            phase = .up
            installKeyMonitors()
            onPhaseChange?(.up)
            let ids = windowIDs
            Task { @MainActor in _ = await hooks.exclude(ids) }
            return .raised
        }
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

    /// Cancel an unfinished raise before its capture owner is invalidated. An already raised
    /// curtain keeps exactly the same window IDs and capture exclusions throughout the switch.
    func prepareForDisplayChange(coverage: CGRect) {
        if style != .sharing {
            changeCoverage = coverage
            refitAwayCover()
            return
        }
        if phase == .raising { lift(); return }
        guard phase == .up, !coverage.isNull, !coverage.isEmpty else { return }
        changeCoverage = coverage
        finishingDisplayChange = false
        for window in windows { window.setFrame(window.frame.union(coverage), display: true) }
    }

    /// Early callbacks must never shrink to lagging AppKit frames; union them with the guard
    /// envelope until ScreenCaptureKit and CoreGraphics agree at completion.
    func refitDuringDisplayChange() {
        if style != .sharing { refitAwayCover(); return }
        guard phase == .up, let coverage = changeCoverage else { return }
        if finishingDisplayChange { return refitToScreens() }
        let expanded = NSScreen.screens.reduce(coverage) { $0.union($1.frame) }
        changeCoverage = expanded
        for window in windows { window.setFrame(window.frame.union(expanded), display: true) }
    }

    /// Windows are made in `NSScreen.screens` order, so they pair with screens by position.
    func refitToScreens() {
        if style != .sharing {
            let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
            if changeCoverage != nil {
                guard NSScreen.screens.allSatisfy({ screen in
                    guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
                    return CurtainDisplayCoverage.matchesAppKit(frame: screen.frame, bounds: CGDisplayBounds(id), mainHeight: mainHeight)
                }) else { return }
            }
            changeCoverage = nil
            refitAwayCover()
            return
        }
        let screens = NSScreen.screens
        guard windows.count == screens.count else { return lift() }
        if changeCoverage != nil {
            finishingDisplayChange = true
            let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
            // AppKit can lag the verified capture geometry too. Keep the guard envelope until
            // every screen has caught up, then a late own notification can finish the exact refit.
            guard screens.allSatisfy({ screen in
                guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
                return CurtainDisplayCoverage.matchesAppKit(frame: screen.frame, bounds: CGDisplayBounds(id), mainHeight: mainHeight)
            }) else { return }
        }
        changeCoverage = nil
        finishingDisplayChange = false
        for (window, screen) in zip(windows, screens) { window.setFrame(screen.frame, display: true) }
    }

    func lift() {
        generation &+= 1
        let wasShowing = phase != .down
        tearDown()
        if wasShowing { onPhaseChange?(.down) }
    }

    /// Before a capture restart: a half-raised curtain would otherwise report `exclusionFailed`
    /// for the rest of the session, because the old stream can no longer exclude its windows.
    func cancelRaise() {
        if phase == .raising { lift() }
    }

    func setStyle(_ style: PrivacyCurtainStyle) {
        guard self.style != style else { return }
        // Retire any old sharing canary/exclusion completion before promoting to Away.
        generation &+= 1
        self.style = style
        for window in windows {
            (window.contentView as? NSHostingView<PrivacyCurtainView>)?.rootView = PrivacyCurtainView(style: style)
        }
        if style != .sharing && phase == .raising {
            windows.forEach { $0.alphaValue = 1 }
            phase = .up
            installKeyMonitors()
            onPhaseChange?(.up)
        }
    }

    func handleScreenParametersChanged() {
        guard phase != .down else { return }
        if !liftsOnScreenChange || style != .sharing {
            refitAwayCover()
            if followsScreenChanges && ownsScreenChange?() != true { onScreensChanged?() }
        } else if !followsScreenChanges || ownsScreenChange?() == true {
            refitDuringDisplayChange()
        } else { lift() }
    }

    /// Keep old windows opaque until replacements cover the new display geometry.
    func refitAwayCover() {
        guard phase != .down, style != .sharing else { return }
        let replacements = makeWindows?() ?? NSScreen.screens.map { Self.makeWindow(for: $0, style: style) }
        guard !replacements.isEmpty else { return }
        replacements.forEach {
            if let coverage = changeCoverage { $0.setFrame($0.frame.union(coverage), display: true) }
            $0.alphaValue = 1; $0.orderFrontRegardless()
        }
        let previous = windows
        windows = replacements
        generation &+= 1
        phase = .up
        for window in previous { window.orderOut(nil); window.close() }
        onPhaseChange?(.up)
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
        changeCoverage = nil
        finishingDisplayChange = false
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
        // Foreign screen changes lift the sharing curtain; Away replaces its cover first.
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
        case .sharing: "Press Esc three times to show this screen"
        case .away: "Touching the keyboard, mouse or trackpad locks this Mac"
        case .awayLockFailed: "This Mac stays covered. Unlock it at the Mac to continue"
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
