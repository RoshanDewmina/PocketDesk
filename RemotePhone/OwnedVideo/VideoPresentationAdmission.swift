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

/// Shared model-issued authority. Retirement is permanent and serializes with the final effect,
/// including effects from a new coordinator that still holds a cached admission value.
final class VideoPresentationLifetime: @unchecked Sendable, Equatable {
    private let lock = NSRecursiveLock()
    private var retired = false
    static func == (lhs: VideoPresentationLifetime, rhs: VideoPresentationLifetime) -> Bool { lhs === rhs }
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return !retired }
    func retire() { lock.lock(); retired = true; lock.unlock() }
    func withActive<T>(_ action: () -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard !retired else { return nil }
        return action()
    }
}

struct VideoPresentationAdmission: Equatable, Sendable {
    let identity: VideoPresentationIdentity
    /// Monotonic deadline. The model renews this only after current route/content authorization.
    let validUntil: TimeInterval
    let lifetime: VideoPresentationLifetime
    init(identity: VideoPresentationIdentity, validUntil: TimeInterval,
         lifetime: VideoPresentationLifetime = VideoPresentationLifetime()) {
        self.identity = identity; self.validUntil = validUntil; self.lifetime = lifetime
    }
    func permits(at now: TimeInterval) -> Bool {
        lifetime.isActive && now.isFinite && validUntil.isFinite && now < validUntil &&
        !identity.hostRecordID.isEmpty && !identity.ownerPairID.isEmpty
    }
    /// Only the authenticated model calls this after recomputing current route/content facts.
    static func renewed(_ proposal: VideoPresentationAdmission?, from previous: VideoPresentationAdmission?) -> VideoPresentationAdmission? {
        guard let proposal else { previous?.lifetime.retire(); return nil }
        if let previous, previous.identity == proposal.identity, previous.lifetime.isActive {
            return VideoPresentationAdmission(identity: proposal.identity, validUntil: proposal.validUntil, lifetime: previous.lifetime)
        }
        previous?.lifetime.retire()
        return proposal
    }
}

/// Lock order: local fence then shared lifetime. Retirement releases the lifetime lock before
/// local teardown, so neither a model retirement nor a renderer teardown inverts that order.
final class VideoPresentationFence: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var admission: VideoPresentationAdmission?
    private var closed = false
    private let clock: () -> TimeInterval
    init(_ admission: VideoPresentationAdmission, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.admission = admission; self.clock = clock }
    func renew(_ next: VideoPresentationAdmission) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, next.identity == admission?.identity, next.lifetime === admission?.lifetime,
              next.permits(at: clock()) else { return false }
        admission = next
        return true
    }
    @discardableResult
    func withAdmission<T>(_ identity: VideoPresentationIdentity, at now: TimeInterval,
                          _ action: () -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, let admission, admission.identity == identity else { return nil }
        return admission.lifetime.withActive {
            guard admission.permits(at: max(now, clock())) else { return nil }
            return action()
        } ?? nil
    }
    /// Local view removal closes this renderer only. The model retires shared authority separately.
    func invalidate() { lock.lock(); closed = true; admission = nil; lock.unlock() }
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
    private var presentationFlights: Set<UInt64> = []
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
    func take(redraw: Bool = false, holdUntilPresented: Bool = false) -> (id: UInt64, frame: Frame, isNew: Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, flights.union(presentationFlights).count < 2, let frame = pending ?? (redraw ? shown : nil) else { return nil }
        let isNew = pending != nil
        pending = nil; shown = frame
        sequence &+= 1; flights.insert(sequence)
        if holdUntilPresented { presentationFlights.insert(sequence) }
        return (sequence, frame, isNew)
    }
    func completed(_ id: UInt64) {
        lock.lock(); flights.remove(id); presentationFlights.remove(id); lock.unlock()
    }
    /// GPU resources and drawable occupancy have independent completion edges.
    func gpuCompleted(_ id: UInt64) { lock.lock(); flights.remove(id); lock.unlock() }
    func presented(_ id: UInt64) { lock.lock(); presentationFlights.remove(id); lock.unlock() }
    /// A taken frame that could not be drawn (no drawable this tick) goes back as pending unless a
    /// newer frame arrived, so its receipt and newness survive the retry.
    func requeue(_ id: UInt64, frame: Frame, wasNew: Bool) {
        lock.lock(); defer { lock.unlock() }
        flights.remove(id); presentationFlights.remove(id)
        guard !closed, wasNew, pending == nil else { return }
        pending = frame
    }
    func hasPending(where predicate: (Frame) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }; return pending.map(predicate) ?? false
    }
    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
    var retainedSlots: Int {
        lock.lock(); defer { lock.unlock() }
        return (pending == nil ? 0 : 1) + (shown == nil ? 0 : 1) + flights.union(presentationFlights).count
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

/// Evidence supplied only by the original source's actual drawable-presented callback.
struct RotationPresentedSource: Equatable {
    let identity: VideoPresentationIdentity
    let tagGeometry: UInt64
    let tagScope: UInt64
    let pixelWidth: Int
    let pixelHeight: Int
    let presentedAt: TimeInterval
    let originalSource: Bool
}

/// A frozen picture has separate terminal authority; this never renews an old live admission.
struct VirtualDisplayRotationPolicy {
    private(set) var begin: VirtualDisplayResizeBegin?
    private(set) var oldIdentity: VideoPresentationIdentity?
    private(set) var targetEpoch: UInt64?
    private(set) var deadline: TimeInterval?
    private var beganAt: TimeInterval?
    private var retiredTokens: [String] = []
    var isHolding: Bool { begin != nil }
    mutating func start(_ request: VirtualDisplayResizeBegin, frame: RotationPresentedSource,
                        current: VideoPresentationIdentity, scope: UInt64, display: UInt32,
                        routeDeadline: TimeInterval, now: TimeInterval) -> Bool {
        guard !isHolding, !retiredTokens.contains(request.token), (try? request.validate()) != nil,
              current == frame.identity, current.geometryEpoch == request.fromEpoch,
              scope == request.scopeEpoch, display == request.display,
              frame.originalSource, frame.tagGeometry == request.fromEpoch, frame.tagScope == scope,
              now.isFinite, routeDeadline.isFinite, routeDeadline > now,
              frame.presentedAt.isFinite, frame.presentedAt > 0, frame.presentedAt <= now,
              now - frame.presentedAt < 2 else { return false }
        begin = request; oldIdentity = current; targetEpoch = nil; beganAt = now
        deadline = min(routeDeadline, now + 2)
        return true
    }
    mutating func bind(token: String?, epoch: UInt64, scope: UInt64, display: UInt32,
                       current: VideoPresentationIdentity, now: TimeInterval) -> Bool {
        guard active(at: now), let begin, let oldIdentity, token == begin.token,
              epoch > begin.fromEpoch, scope == begin.scopeEpoch, display == begin.display,
              current == oldIdentity, targetEpoch == nil else { clear(); return false }
        targetEpoch = epoch
        return true
    }
    func permitsPreflight(token: String?, epoch: UInt64, scope: UInt64, now: TimeInterval) -> Bool {
        active(at: now) && token == begin?.token && epoch == targetEpoch && scope == begin?.scopeEpoch
    }
    mutating func presented(_ frame: RotationPresentedSource, current: VideoPresentationIdentity,
                            scope: UInt64, display: UInt32, now: TimeInterval) -> Bool {
        guard active(at: now), let begin, let oldIdentity, let targetEpoch, let beganAt,
              frame.originalSource, frame.identity == current,
              current.hostRecordID == oldIdentity.hostRecordID, current.ownerPairID == oldIdentity.ownerPairID,
              current.sessionID == oldIdentity.sessionID, current.trackID == oldIdentity.trackID,
              current.contentEpoch == oldIdentity.contentEpoch &+ 1, current.geometryEpoch == targetEpoch,
              frame.tagGeometry == targetEpoch, frame.tagScope == begin.scopeEpoch,
              scope == begin.scopeEpoch, display == begin.display,
              frame.pixelWidth == begin.pixelWidth, frame.pixelHeight == begin.pixelHeight,
              frame.presentedAt.isFinite, frame.presentedAt >= beganAt, frame.presentedAt <= now else { return false }
        clear(); return true
    }
    func active(at now: TimeInterval) -> Bool {
        guard isHolding, let deadline else { return false }
        return now.isFinite && now < deadline
    }
    mutating func expire(at now: TimeInterval) -> Bool {
        guard isHolding, !active(at: now) else { return false }
        clear(); return true
    }
    mutating func clear() {
        if let token = begin?.token {
            retiredTokens.append(token)
            if retiredTokens.count > 32 { retiredTokens.removeFirst(retiredTokens.count - 32) }
        }
        begin = nil; oldIdentity = nil; targetEpoch = nil; deadline = nil; beganAt = nil
    }
}
