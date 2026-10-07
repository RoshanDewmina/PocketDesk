import UIKit
import QuartzCore

@MainActor
protocol PhoneDisplayTickLink: AnyObject {
    func invalidate()
}

/// Packet batching follows the display clock; ordered relative paths remain intact inside a tick.
/// A semantic event is a flush barrier. Cleanup may cancel pending motion synchronously.
@MainActor
final class PhoneDisplayTickInputPump: NSObject {
    static let optimizationDefaultsKey = "phoneDisplayTickInputPump.optimizedCadenceEnabled"
    static let leadingMotionDefaultsKey = "phoneDisplayTickInputPump.leadingMotionEnabled"
    static let couchMaximumCadenceDisabledKey = "couchInputMaximumCadenceDisabled"
    /// Picture mode drains moves at the panel's maximum too (`defaults write <phone bundle id>
    /// PocketDeskInputPump120 -bool YES`, then relaunch the app): up to 8 ms less wait on ProMotion, for
    /// twice the move packets. Off: Picture keeps the 60 Hz hint.
    static let maximumCadenceDefaultsKey = "PocketDeskInputPump120"
    static let retainedLinkIdleDuration: TimeInterval = 0.15

    struct Configuration {
        var now: () -> TimeInterval = { CACurrentMediaTime() }
        var maximumFramesPerSecond: () -> Int = {
            let activeWindowScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive && $0.keyWindow != nil }
            return activeWindowScene?.screen.maximumFramesPerSecond ?? 60
        }
        var idleRetentionDuration = PhoneDisplayTickInputPump.retainedLinkIdleDuration
        var userDefaults: UserDefaults = .standard
        var displayLinkFactory: ((CAFrameRateRange?, @escaping () -> Void) -> PhoneDisplayTickLink)?

        fileprivate var optimizationEnabled: Bool {
            userDefaults.object(forKey: PhoneDisplayTickInputPump.optimizationDefaultsKey) as? Bool != false
        }
        fileprivate var leadingMotionEnabled: Bool {
            userDefaults.object(forKey: PhoneDisplayTickInputPump.leadingMotionDefaultsKey) as? Bool != false
        }
        fileprivate var maximumCadenceEnabled: Bool {
            userDefaults.bool(forKey: PhoneDisplayTickInputPump.maximumCadenceDefaultsKey)
        }
    }

    private var pending: [RemoteAction] = []
    private var oldestPendingOfferMs: Double?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: InputTickTarget?
    private var injectedLink: PhoneDisplayTickLink?
    private let automaticTicks: Bool
    private let configuration: Configuration
    private let optimizedCadenceEnabled: Bool
    private let leadingMotionEnabled: Bool
    private let couchMaximumCadenceEnabled: Bool
    private let maximumCadenceEnabled: Bool
    private var lastActivityTime: TimeInterval?
    private var lastDisplayTickTime: TimeInterval?
    private var burstActive = false
    private var prefersDisplayMaximum = false
    private var linkGeneration = 0
    var send: (([RemoteAction]) -> Bool)?
    var onFailure: (() -> Void)?
    /// Actual callback-to-callback interval, in milliseconds; gaps between links are excluded.
    var onDisplayInterval: ((Double) -> Void)?
    /// Offer entry through successful synchronous leading send, in milliseconds.
    var onLeadingMotionLatency: ((Double) -> Void)?

    init(automaticTicks: Bool = true, configuration: Configuration = Configuration()) {
        self.automaticTicks = automaticTicks
        self.configuration = configuration
        self.optimizedCadenceEnabled = configuration.optimizationEnabled
        self.leadingMotionEnabled = configuration.leadingMotionEnabled
        self.couchMaximumCadenceEnabled = !configuration.userDefaults.bool(forKey: Self.couchMaximumCadenceDisabledKey)
        self.maximumCadenceEnabled = configuration.maximumCadenceEnabled
        super.init()
    }

    @discardableResult
    func offer(_ action: RemoteAction, preferDisplayMaximum: Bool = false) -> Bool {
        guard ["move", "moveTo"].contains(action.action) else { return false }
        if prefersDisplayMaximum != preferDisplayMaximum {
            // A mode transition must update the hint without discarding its ordered path.
            invalidateLink()
            prefersDisplayMaximum = preferDisplayMaximum
        }
        let offeredAt = configuration.now()
        if pending.count == InputCausalEnvelope.maximumSegments, !drain() { return false }
        let startsBurst = !burstActive || offeredAt - (lastActivityTime ?? offeredAt) >= configuration.idleRetentionDuration
        burstActive = true
        if pending.isEmpty, InputCadenceTrace.enabled { oldestPendingOfferMs = offeredAt * 1_000 }
        pending.append(action)
        lastActivityTime = offeredAt
        startLinkIfNeeded()
        if leadingMotionEnabled, startsBurst {
            guard drain() else { return false }
            let elapsed = (configuration.now() - offeredAt) * 1_000
            if elapsed.isFinite, elapsed >= 0 { onLeadingMotionLatency?(elapsed) }
        }
        return true
    }

    private func startLinkIfNeeded() {
        guard automaticTicks, displayLink == nil, injectedLink == nil else { return }
        let maximum = Float(max(60, configuration.maximumFramesPerSecond()))
        let atMaximum = maximumCadenceEnabled || prefersDisplayMaximum && couchMaximumCadenceEnabled
        let range: CAFrameRateRange? = optimizedCadenceEnabled
            ? CAFrameRateRange(minimum: 60, maximum: maximum, preferred: atMaximum ? maximum : 60) : nil
        linkGeneration += 1
        let generation = linkGeneration
        let tick: () -> Void = { [weak self] in
            guard let self, self.linkGeneration == generation else { return }
            self.tick()
        }
        if let factory = configuration.displayLinkFactory {
            injectedLink = factory(range, tick)
        } else {
            let target = InputTickTarget(action: tick)
            let displayLink = CADisplayLink(target: target, selector: #selector(InputTickTarget.step))
            if let range { displayLink.preferredFrameRateRange = range }
            displayLink.add(to: .main, forMode: .common)
            displayLinkTarget = target
            self.displayLink = displayLink
        }
    }

    @discardableResult
    func flush() -> Bool {
        // Called before a semantic action. The next motion starts a fresh ordered burst.
        burstActive = false
        return drain()
    }

    @discardableResult
    private func drain() -> Bool {
        guard !pending.isEmpty else { return true }
        let actions = pending; pending.removeAll(keepingCapacity: true)
        if let oldestPendingOfferMs {
            InputCadenceTrace.pump(offeredMs: oldestPendingOfferMs, sendMs: configuration.now() * 1_000, count: actions.count)
        }
        oldestPendingOfferMs = nil
        let accepted = send?(actions) == true
        if !accepted { cancel(); onFailure?() }
        return accepted
    }
    func tick() {
        let now = configuration.now()
        if displayLink != nil || injectedLink != nil {
            let previous = lastDisplayTickTime
            lastDisplayTickTime = now
            if let previous {
                let interval = (now - previous) * 1_000
                if interval.isFinite, interval > 0 { onDisplayInterval?(interval) }
            }
        }
        guard drain() else { return }
        let idleDuration = now - (lastActivityTime ?? now)
        if idleDuration >= configuration.idleRetentionDuration { burstActive = false }
        guard pending.isEmpty, displayLink != nil || injectedLink != nil else { return }
        guard !optimizedCadenceEnabled || idleDuration >= configuration.idleRetentionDuration else { return }
        invalidateLink()
        lastActivityTime = nil
    }

    func cancel() {
        pending.removeAll(keepingCapacity: false)
        oldestPendingOfferMs = nil
        invalidateLink()
        lastActivityTime = nil
        burstActive = false
    }

    private func invalidateLink() {
        linkGeneration += 1
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        injectedLink?.invalidate()
        injectedLink = nil
        lastDisplayTickTime = nil
    }

    deinit { displayLink?.invalidate() }
}
@MainActor
private final class InputTickTarget: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func step() { action() }
}
