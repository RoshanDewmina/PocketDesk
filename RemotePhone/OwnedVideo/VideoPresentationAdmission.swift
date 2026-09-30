import Foundation

/// Non-secret presentation identity supplied by the authenticated model, never derived from a room.
struct VideoPresentationIdentity: Equatable, Hashable, Sendable {
    let hostRecordID: String
    let ownerPairID: String
    let sessionID: UUID
    let trackID: UUID
    let contentEpoch: UInt64
    let geometryEpoch: UInt64
}

struct VideoPresentationAdmission: Equatable, Sendable {
    let identity: VideoPresentationIdentity
    /// Monotonic deadline. The model renews this only after current route/content authorization.
    let validUntil: TimeInterval
    func permits(at now: TimeInterval) -> Bool {
        now.isFinite && validUntil.isFinite && now < validUntil &&
        !identity.hostRecordID.isEmpty && !identity.ownerPairID.isEmpty
    }
}

/// Serialize invalidation with submissions/callbacks; callers must invalidate BEFORE flushing.
final class VideoPresentationFence: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var admission: VideoPresentationAdmission?
    private var closed = false
    init(_ admission: VideoPresentationAdmission) { self.admission = admission }
    func renew(_ next: VideoPresentationAdmission) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, next.identity == admission?.identity else { return false }
        admission = next
        return true
    }
    @discardableResult
    func withAdmission<T>(_ identity: VideoPresentationIdentity, at now: TimeInterval,
                          _ action: () -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, let admission, admission.identity == identity, admission.permits(at: now) else { return nil }
        return action()
    }
    func invalidate() {
        lock.lock(); closed = true; admission = nil; lock.unlock()
    }
}

/// Motion methods can synchronously deliver while holding their own presenter lock. NEVER
/// enter this gate or call motion/presenter methods while holding VideoPresentationFence.
/// Close the presentation fence first, then close/drain this gate before stopping motion.
final class VideoMotionGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var closed = false
    @discardableResult
    func perform(_ action: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        action(); return true
    }
    func close(_ teardown: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }; closed = true
        teardown()
    }
}

/// One pending, one last submitted for redraw, and at most two flights. No queue per decode.
final class NewestFrameMailbox<Frame>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Frame?
    private var shown: Frame?
    private var flights: Set<UInt64> = []
    private var sequence: UInt64 = 0
    private var closed = false
    @discardableResult
    func offer(_ frame: Frame, onReplacement: ((Frame) -> Void)? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        let replaced = pending != nil
        if let pending { onReplacement?(pending) }
        pending = frame
        return replaced
    }
    func take(redraw: Bool = false) -> (id: UInt64, frame: Frame, isNew: Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, flights.count < 2, let frame = pending ?? (redraw ? shown : nil) else { return nil }
        let isNew = pending != nil
        pending = nil; shown = frame
        sequence &+= 1; flights.insert(sequence)
        return (sequence, frame, isNew)
    }
    func completed(_ id: UInt64) {
        lock.lock(); flights.remove(id); lock.unlock()
    }
    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
    var retainedSlots: Int {
        lock.lock(); defer { lock.unlock() }
        return (pending == nil ? 0 : 1) + (shown == nil ? 0 : 1) + flights.count
    }
    func invalidate() {
        lock.lock(); closed = true; pending = nil; shown = nil; lock.unlock()
    }
}

enum VideoColorMatrix: Sendable { case bt601, bt709 }
enum VideoColorTransfer: Sendable {
    case srgb, bt709
    /// The owned drawable has one fixed BT.709 color space, including for sRGB capture.
    func encoded709(_ value: Float) -> Float {
        guard self == .srgb else { return value }
        let v = max(0, value)
        let linear = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        return linear < 0.018 ? 4.5 * linear : 1.099 * pow(linear, 0.45) - 0.099
    }
}
struct VideoColorConversion: Equatable, Sendable {
    let kr: Float
    let kb: Float
    let yOffset: Float
    let yScale: Float
    let uvScale: Float
    init(matrix: VideoColorMatrix, fullRange: Bool) {
        kr = matrix == .bt709 ? 0.2126 : 0.299
        kb = matrix == .bt709 ? 0.0722 : 0.114
        yOffset = fullRange ? 0 : 16 / 255
        yScale = fullRange ? 1 : 255 / 219
        uvScale = fullRange ? 1 : 255 / 224
    }
    func rgb(y: Float, cb: Float, cr: Float) -> (Float, Float, Float) {
        let l = (y - yOffset) * yScale, u = (cb - 128 / 255) * uvScale, v = (cr - 128 / 255) * uvScale
        return (l + 2 * (1 - kr) * v,
                l - 2 * kb * (1 - kb) / (1 - kr - kb) * u - 2 * kr * (1 - kr) / (1 - kr - kb) * v,
                l + 2 * (1 - kb) * u)
    }
}
