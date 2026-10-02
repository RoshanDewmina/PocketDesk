import Foundation

/// Remembers whether the desktop fills the screen or fits inside the safe area.
enum ViewportPreference {
    static let key = "viewportMode"

    static func stored(in defaults: UserDefaults = .standard) -> ViewportMode {
        defaults.string(forKey: key).flatMap(ViewportMode.init(rawValue:)) ?? .fill
    }

    /// The first window chooses one shared value. Resizing or a later regular window never
    /// replaces the person's selection (or a compact first launch's Fill).
    @discardableResult
    static func initialize(regularWidth: Bool, in defaults: UserDefaults = .standard) -> ViewportMode {
        if defaults.object(forKey: key) == nil {
            store(regularWidth ? .fit : .fill, in: defaults)
        }
        return stored(in: defaults)
    }

    static func store(_ mode: ViewportMode, in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }
}

/// G4: when the phone tells the Mac which part of the desktop it shows. Each change sent takes the next
/// epoch, and every regular heartbeat repeats the newest one sent, so a restarted Mac re-applies it.
///
/// Every crop change costs the picture a few mis-scaled frames: the phone places frames by the region the
/// Mac echoes on `capture` status, and that status travels apart from the video (MS21; recording
/// 15:26:33 on 1 Oct, where the picture's scale jumped back and forth while the zoom readout fell
/// steadily from 4.8x to 3.1x). So while a gesture runs, a change the stream still covers waits until the
/// gesture settles or rests for `quietInterval`; a change it no longer covers leaves at most every
/// `minimumInterval`. While a pinch out keeps going and the view no longer fits in the crop at all, it
/// asks for twice the visible area, so the crop changes about once per halving, not every 100 ms.
struct ViewportReporter {
    static let minimumInterval: TimeInterval = 0.1
    static let quietInterval: TimeInterval = 0.3

    enum Send: Equatable {
        case none
        case now
        case at(TimeInterval)
    }

    private(set) var request: ViewportCaptureRequest?
    private(set) var epoch: UInt64 = 0
    private var sent: ViewportCaptureRequest?
    private var lastSentAt = -TimeInterval.infinity
    private var changedAt = -TimeInterval.infinity
    private var previousChangeAt = -TimeInterval.infinity

    var hasUnsentChange: Bool { request != nil && request != sent }

    mutating func update(_ request: ViewportCaptureRequest?, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if request != self.request { previousChangeAt = changedAt; changedAt = now }
        self.request = request
    }

    /// When the newest request should leave on its own heartbeat. `coverage` is the desktop rect the
    /// stream shows now (the echoed crop, or the whole display); nil leaves every change as it comes.
    func nextSend(settled: Bool, coverage: CGRect? = nil, at now: TimeInterval) -> Send {
        guard hasUnsentChange, let request else { return .none }
        if settled || sent?.displaySize != request.displaySize { return .now }
        // A region sent but not yet echoed also counts: the Mac is about to stream it.
        if let coverage, let sent, Self.covers(coverage, request.rect)
            || sent.displaySize == request.displaySize && Self.covers(sent.rect, request.rect) {
            let quiet = changedAt + Self.quietInterval
            return now >= quiet ? .now : .at(quiet)
        }
        let due = lastSentAt + Self.minimumInterval
        return now >= due ? .now : .at(due)
    }

    /// Makes what leaves now the request heartbeats repeat; false when nothing changes or the request
    /// belongs to another display.
    mutating func commit(settled: Bool, coverage: CGRect? = nil, forDisplay displaySize: CGSize,
                         at now: TimeInterval) -> Bool {
        guard let request, request.displaySize == displaySize,
              let next = outgoing(settled: settled, coverage: coverage, at: now), next != sent else { return false }
        epoch += 1
        sent = next
        lastSentAt = now
        return true
    }

    /// The region every heartbeat carries: the newest one sent; nil while there is no request or it
    /// belongs to another display.
    func region(forDisplay displaySize: CGSize) -> ViewportRegion? {
        guard request != nil, let sent, sent.displaySize == displaySize else { return nil }
        return sent.region(epoch: epoch)
    }

    /// A new session has been sent nothing, so its first send carries the request under a new epoch.
    mutating func sessionEnded() {
        sent = nil
        lastSentAt = -.infinity
    }

    private func outgoing(settled: Bool, coverage: CGRect?, at now: TimeInterval) -> ViewportCaptureRequest? {
        guard let request else { return nil }
        // Only a continuing pinch out: a pan or a one-off layout change gets exactly what it shows.
        guard !settled, sent != nil, now < changedAt + Self.quietInterval,
              changedAt - previousChangeAt < Self.quietInterval, let coverage,
              request.rect.width > coverage.width + 0.5 || request.rect.height > coverage.height + 0.5
        else { return request }
        return request.widened(by: 2)
    }

    private static func covers(_ coverage: CGRect, _ rect: CGRect) -> Bool {
        coverage.insetBy(dx: -0.5, dy: -0.5).contains(rect)
    }
}
