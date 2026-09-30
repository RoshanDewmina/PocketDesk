import UIKit

/// Packet batching follows the display clock; ordered relative paths remain intact inside a tick.
/// A semantic event is a flush barrier. Cleanup may cancel pending motion synchronously.
@MainActor
final class PhoneDisplayTickInputPump: NSObject {
    private var pending: [RemoteAction] = []
    private var link: CADisplayLink?
    private let automaticTicks: Bool
    var send: (([RemoteAction]) -> Bool)?
    var onFailure: (() -> Void)?
    init(automaticTicks: Bool = true) { self.automaticTicks = automaticTicks; super.init() }
    @discardableResult
    func offer(_ action: RemoteAction) -> Bool {
        guard ["move", "moveTo"].contains(action.action) else { return false }
        if pending.count == InputCausalEnvelope.maximumSegments, !flush() { return false }
        pending.append(action)
        if automaticTicks, link == nil {
            let target = InputTickTarget { [weak self] in self?.tick() }
            let link = CADisplayLink(target: target, selector: #selector(InputTickTarget.step))
            link.add(to: .main, forMode: .common)
            self.link = link
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
    func tick() { _ = flush(); if pending.isEmpty { link?.invalidate(); link = nil } }
    func cancel() { pending.removeAll(keepingCapacity: false); link?.invalidate(); link = nil }
    deinit { link?.invalidate() }
}
private final class InputTickTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func step() { action() }
}
