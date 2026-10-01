import Foundation
import VideoToolbox

/// Host-side still-picture signal for the owned encoder's bounded QP floor. Off unless the phone
/// asked for it; every frame ScreenCaptureKit reports as changed ends a still period.
final class TextClarityContext: @unchecked Sendable {
    static let stillAfter: TimeInterval = 0.5
    let enabled: Bool
    private let lock = NSLock()
    private let clock: () -> TimeInterval
    private var changedAt: TimeInterval?
    init(enabled: Bool, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.enabled = enabled; self.clock = clock
    }
    func contentChanged() {
        guard enabled else { return }
        let now = clock()
        lock.lock(); changedAt = now; lock.unlock()
    }
    var isStill: Bool {
        guard enabled else { return false }
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        guard let changedAt else { return false }
        return now - changedAt >= Self.stillAfter
    }
}

/// A tighter frame-QP ceiling while the picture is still. VideoToolbox drops frames rather than
/// exceed its data-rate limits, so the session's bitrate caps and the ladder still win under load.
enum TextClarityPolicy {
    static let stillHEVCQP = 24
    static let stillH264QP = 26
    static func stillFrameQP(hevc: Bool, sessionBound: Int) -> Int { min(sessionBound, hevc ? stillHEVCQP : stillH264QP) }
    static func supported(_ catalog: [String: Any]?) -> Bool { catalog?[kVTCompressionPropertyKey_MaxAllowedFrameQP as String] != nil }
}
