import Foundation
import CoreGraphics

/// Negotiated metadata on existing native actions; never an independent authority or channel.
struct PencilFrame: Codable, Equatable {
    enum Phase: String, Codable { case hover, began, moved, ended, cancelled }
    var version = 1
    let stream: String
    var phase: Phase
    var pressure: Double
    var tiltX: Double
    var tiltY: Double
    func validate(action: String, interaction: NativeInteraction?) throws {
        guard version == 1, stream.utf8.count == 32,
              stream.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              pressure.isFinite, (0...1).contains(pressure), tiltX.isFinite, tiltY.isFinite,
              abs(tiltX) <= 1, abs(tiltY) <= 1 else { throw RemoteError.invalidMessage }
        switch phase {
        case .hover: guard action == "moveTo", pressure == 0 else { throw RemoteError.invalidMessage }
        case .began: guard action == "dragDown", interaction?.hold == stream, interaction?.clickCount == 1 else { throw RemoteError.invalidMessage }
        case .moved: guard action == "moveTo", interaction?.hold == stream, interaction?.clickCount == 1 else { throw RemoteError.invalidMessage }
        case .ended, .cancelled: guard action == "dragUp", pressure == 0, interaction?.hold == stream, interaction?.clickCount == 1 else { throw RemoteError.invalidMessage }
        }
    }
    func zeroed(_ phase: Phase = .cancelled) -> PencilFrame {
        var value = self; value.phase = phase; value.pressure = 0; return value
    }
}

/// One accepted contact. Ignored palms are never replayed after the pencil lifts.
final class PencilContactRouter {
    var send: (CGPoint, PencilFrame) -> Bool = { _, _ in false }
    private(set) var active: String?
    private var lastPoint = CGPoint.zero
    private var lastFrame: PencilFrame?
    private var enabled = false
    private var revision: UInt64 = 0
    func configure(enabled: Bool, revision: UInt64) {
        if !enabled || self.revision != revision { cancel() }
        self.enabled = enabled; self.revision = revision
    }
    @discardableResult
    func begin(at point: CGPoint, pressure: Double, tiltX: Double, tiltY: Double) -> Bool {
        guard enabled, active == nil else { return false }
        let frame = PencilFrame(stream: InputCausalEnvelope.identity(), phase: .began, pressure: pressure, tiltX: tiltX, tiltY: tiltY)
        guard finite(point), samplesValid(frame), send(point, frame) else { return false }
        active = frame.stream; lastPoint = point; lastFrame = frame; return true
    }
    @discardableResult
    func move(to point: CGPoint, pressure: Double, tiltX: Double, tiltY: Double) -> Bool {
        guard enabled, let stream = active else { return false }
        let frame = PencilFrame(stream: stream, phase: .moved, pressure: pressure, tiltX: tiltX, tiltY: tiltY)
        guard finite(point), samplesValid(frame), send(point, frame) else { cancel(); return false }
        lastPoint = point; lastFrame = frame; return true
    }
    func updatePressure(pressure: Double, tiltX: Double, tiltY: Double) {
        _ = move(to: lastPoint, pressure: pressure, tiltX: tiltX, tiltY: tiltY)
    }
    func end(at point: CGPoint) {
        guard let lastFrame else { return }
        let target = finite(point) ? point : lastPoint
        if !send(target, lastFrame.zeroed(.ended)) { _ = send(lastPoint, lastFrame.zeroed()) }
        active = nil; self.lastFrame = nil
    }
    func hover(at point: CGPoint, tiltX: Double, tiltY: Double) {
        guard enabled, active == nil, finite(point) else { return }
        let frame = PencilFrame(stream: InputCausalEnvelope.identity(), phase: .hover, pressure: 0, tiltX: tiltX, tiltY: tiltY)
        if samplesValid(frame) { _ = send(point, frame) }
    }
    func cancel() {
        if let lastFrame { _ = send(lastPoint, lastFrame.zeroed()) }
        active = nil; lastFrame = nil
    }
    private func finite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }
    private func samplesValid(_ frame: PencilFrame) -> Bool {
        frame.pressure.isFinite && (0...1).contains(frame.pressure) && frame.tiltX.isFinite && frame.tiltY.isFinite && abs(frame.tiltX) <= 1 && abs(frame.tiltY) <= 1
    }
}

/// Actual scene lock is the gate; a requested preference alone cannot admit raw deltas.
final class LockedRelativeMouseRouter {
    var send: (NativeGestureCommand) -> Bool = { _ in false }
    private(set) var enabled = false
    private(set) var hold: String?
    func setEnabled(_ value: Bool) { if !value { cancel() }; enabled = value }
    func move(x: Double, y: Double, gain: Double) {
        guard enabled, x.isFinite, y.isFinite, gain.isFinite, gain > 0 else { return }
        let dx = x * gain, dy = -y * gain
        guard abs(dx) <= 20000, abs(dy) <= 20000 else { return }
        if !send(.move(CGSize(width: dx, height: dy))) { cancel() }
    }
    func primary(_ down: Bool) {
        guard enabled else { return }
        if down {
            guard hold == nil else { return }
            let id = InputCausalEnvelope.identity()
            if send(.dragBegan(id: id, count: 1)) { hold = id }
        } else { cancel() }
    }
    func cancel() {
        if let hold { _ = send(.dragEnded(id: hold)) }
        hold = nil
    }
}
