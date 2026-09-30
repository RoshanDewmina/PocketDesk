import Foundation

/// How long a return to the session took, from the moment the phone started coming back to the
/// moment a new renderer callback reached an active scene. One measurement at a time; the result is reported once.
struct ResumeTiming {
    enum Kind: String, Equatable {
        /// The session was held in the background and asked to resume.
        case held
        /// The hold had ended, so the phone reconnected by itself.
        case reconnect
        /// The person tapped Reconnect.
        case manual
    }

    enum CancelReason: String, Equatable {
        case userEnded, leftAgain, timedOut
    }

    struct Measurement: Equatable {
        var kind: Kind
        /// A held session that stopped answering and had to reconnect.
        var fellBack: Bool
        /// From the start of the return to a new frame on an active screen.
        var totalMs: Int
        /// The part of that wait left after iOS finished bringing the app forward.
        var afterActiveMs: Int
        /// When the previous view or display was restored, if the path needed that.
        var settledMs: Int?

        var summary: String {
            let seconds = String(format: "%.1f s", Double(totalMs) / 1000)
            let how = fellBack ? "reconnected after the held session stopped answering"
                : kind == .held ? "session was held" : "reconnected"
            return "\(seconds) · \(how)"
        }
    }

    static let ceiling: TimeInterval = 60

    private(set) var kind: Kind?
    private var began: TimeInterval = 0
    private var activeAt: TimeInterval?
    private var frameAt: TimeInterval?
    private var settledAt: TimeInterval?
    private var fellBack = false

    var isOpen: Bool { kind != nil }

    mutating func begin(_ kind: Kind, at now: TimeInterval, sceneActive: Bool) {
        self.kind = kind
        began = now
        activeAt = sceneActive ? now : nil
        frameAt = nil
        settledAt = nil
        fellBack = false
    }

    mutating func sceneActive(at now: TimeInterval) -> Measurement? {
        guard isOpen, now >= began, now - began <= Self.ceiling, activeAt == nil else { return nil }
        activeAt = max(now, began)
        return completed()
    }

    mutating func fellBack(at now: TimeInterval) {
        guard kind == .held else { return }
        fellBack = true
        frameAt = nil
        settledAt = nil
    }

    /// Ignore callbacks timestamped before this return; this is renderer arrival, not glass timing.
    mutating func frame(at now: TimeInterval) -> Measurement? {
        guard isOpen, frameAt == nil, now >= began, now - began <= Self.ceiling else { return nil }
        frameAt = now
        return completed()
    }

    mutating func settled(at now: TimeInterval) -> Measurement? {
        guard isOpen, now >= began, now - began <= Self.ceiling, settledAt == nil else { return nil }
        settledAt = max(now, began)
        return completed()
    }

    mutating func expire(at now: TimeInterval) -> Bool {
        guard isOpen, now - began > Self.ceiling else { return false }
        cancel(.timedOut)
        return true
    }

    mutating func cancel(_ reason: CancelReason) {
        kind = nil
    }

    private var needsSettle: Bool { kind != .held || fellBack }

    private mutating func completed() -> Measurement? {
        guard let kind, let activeAt, let frameAt, !needsSettle || settledAt != nil else { return nil }
        let visible = max(activeAt, frameAt)
        let result = Measurement(kind: kind, fellBack: fellBack,
                                 totalMs: Self.ms(visible - began),
                                 afterActiveMs: Self.ms(max(0, frameAt - activeAt)),
                                 settledMs: settledAt.map { Self.ms($0 - began) })
        self.kind = nil
        return result
    }

    private static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }
}
