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
    static let retainedLinkIdleDuration: TimeInterval = 0.15

    struct Configuration {
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
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
    }

    private var pending: [RemoteAction] = []
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: InputTickTarget?
    private var injectedLink: PhoneDisplayTickLink?
    private let automaticTicks: Bool
    private let configuration: Configuration
    private let optimizedCadenceEnabled: Bool
    private var lastActivityTime: TimeInterval?
    var send: (([RemoteAction]) -> Bool)?
    var onFailure: (() -> Void)?

    init(automaticTicks: Bool = true) {
        let configuration = Configuration()
        self.automaticTicks = automaticTicks
        self.configuration = configuration
        self.optimizedCadenceEnabled = configuration.optimizationEnabled
        super.init()
    }

    init(configuration: Configuration) {
        self.automaticTicks = true
        self.configuration = configuration
        self.optimizedCadenceEnabled = configuration.optimizationEnabled
        super.init()
    }

    @discardableResult
    func offer(_ action: RemoteAction) -> Bool {
        guard ["move", "moveTo"].contains(action.action) else { return false }
        if pending.count == InputCausalEnvelope.maximumSegments, !flush() { return false }
        pending.append(action)
        lastActivityTime = configuration.now()
        if automaticTicks, displayLink == nil, injectedLink == nil {
            let range: CAFrameRateRange? = optimizedCadenceEnabled
                ? CAFrameRateRange(minimum: 60,
                                   maximum: Float(max(60, configuration.maximumFramesPerSecond())),
                                   preferred: 60)
                : nil
            let tick: () -> Void = { [weak self] in self?.tick() }
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
        return true
    }
    @discardableResult
    func flush() -> Bool {
        guard !pending.isEmpty else { return true }
        let actions = pending; pending.removeAll(keepingCapacity: true)
        let accepted = send?(actions) == true
        if !accepted { cancel(); onFailure?() }
        return accepted
    }
    func tick() {
        _ = flush()
        guard pending.isEmpty, displayLink != nil || injectedLink != nil else { return }
        let idleDuration = configuration.now() - (lastActivityTime ?? configuration.now())
        guard !optimizedCadenceEnabled || idleDuration >= configuration.idleRetentionDuration else { return }
        invalidateLink()
        lastActivityTime = nil
    }

    func cancel() {
        pending.removeAll(keepingCapacity: false)
        invalidateLink()
        lastActivityTime = nil
    }

    private func invalidateLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        injectedLink?.invalidate()
        injectedLink = nil
    }

    deinit { displayLink?.invalidate() }
}

private final class InputTickTarget: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func step() { action() }
}
