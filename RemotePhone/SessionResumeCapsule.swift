import CoreGraphics
import Foundation

/// Where the person was looking: Fit or Fill, zoom, the display point at the centre of the safe
/// area (as a fraction of the display) and whether touches steer the Mac or only move the view.
struct ResumeViewport: Equatable {
    var mode: ViewportMode
    var zoom: CGFloat
    var focus: CGPoint
    var atBaseline: Bool
    var viewOnly: Bool

    /// Nothing to restore beyond the defaults a new session starts with.
    var isDefaultView: Bool { atBaseline && !viewOnly }

    /// The same view to within rounding, so a session that kept its screen is not "restored" again.
    func matches(_ other: ResumeViewport) -> Bool {
        mode == other.mode && viewOnly == other.viewOnly && atBaseline == other.atBaseline
            && abs(zoom - other.zoom) < 0.001 && abs(focus.x - other.focus.x) < 0.001 && abs(focus.y - other.focus.y) < 0.001
    }
}

extension ViewportTransform {
    func resumeViewport(viewOnly: Bool) -> ResumeViewport? {
        guard sourceSize.width > 0, sourceSize.height > 0, scale > 0 else { return nil }
        let safe = safeRect
        guard let point = sourcePoint(fromView: CGPoint(x: safe.midX, y: safe.midY)) else { return nil }
        return ResumeViewport(mode: mode, zoom: zoom,
                              focus: CGPoint(x: point.x / sourceSize.width, y: point.y / sourceSize.height),
                              atBaseline: isAtBaseline, viewOnly: viewOnly)
    }

    mutating func restore(_ resume: ResumeViewport) {
        setMode(resume.mode)
        guard !resume.atBaseline else { return }
        let safe = safeRect
        setZoom(resume.zoom, anchoredAt: CGPoint(x: safe.midX, y: safe.midY))
        center(onSourcePoint: CGPoint(x: resume.focus.x * sourceSize.width, y: resume.focus.y * sourceSize.height))
    }
}

/// A small note of the view to put back when a session that ended by itself is reconnected.
///
/// It holds only viewport numbers and the display they belong to: no input, no screen content, and
/// nothing is ever replayed. A deliberate End discards it, it expires with the automatic-resume
/// window, and a display whose geometry changed voids it.
struct SessionResumeCapsule: Codable, Equatable {
    static let lifetime: TimeInterval = BackgroundContinuity.automaticResumeWindow
    /// How long a new session may wait for the remembered display to come back before giving up.
    static let displayWait: TimeInterval = 10

    enum Decision: Equatable {
        case restore(ResumeViewport)
        /// The session is still switching to the capsule's display.
        case wait
        case discard
    }

    var macKey: String
    var displayID: UInt32?
    var displayWidth: Double
    var displayHeight: Double
    var mode: String
    var zoom: Double
    var focusX: Double
    var focusY: Double
    var atBaseline: Bool
    var viewOnly: Bool
    var savedAt: Date

    init(macKey: String, displayID: UInt32?, displaySize: CGSize, viewport: ResumeViewport, savedAt: Date) {
        self.macKey = macKey
        self.displayID = displayID
        displayWidth = Double(displaySize.width)
        displayHeight = Double(displaySize.height)
        mode = viewport.mode.rawValue
        zoom = Double(viewport.zoom)
        focusX = Double(viewport.focus.x)
        focusY = Double(viewport.focus.y)
        atBaseline = viewport.atBaseline
        viewOnly = viewport.viewOnly
        self.savedAt = savedAt
    }

    /// Nil when a stored value is out of range, so a damaged record is never applied.
    var viewport: ResumeViewport? {
        guard let mode = ViewportMode(rawValue: mode), zoom.isFinite, (0.05...20).contains(zoom),
              focusX.isFinite, focusY.isFinite, (0...1).contains(focusX), (0...1).contains(focusY) else { return nil }
        return ResumeViewport(mode: mode, zoom: CGFloat(zoom), focus: CGPoint(x: focusX, y: focusY),
                              atBaseline: atBaseline, viewOnly: viewOnly)
    }

    /// - Parameter mayStillSwitchDisplay: the new session may yet move to the remembered display.
    func decision(macKey: String, displayID current: UInt32?, displaySize: CGSize, now: Date,
                  mayStillSwitchDisplay: Bool) -> Decision {
        guard macKey == self.macKey, now >= savedAt, now.timeIntervalSince(savedAt) <= Self.lifetime,
              let viewport else { return .discard }
        if let displayID, let current, displayID != current {
            return mayStillSwitchDisplay ? .wait : .discard
        }
        guard abs(displayWidth - Double(displaySize.width)) < 0.5,
              abs(displayHeight - Double(displaySize.height)) < 0.5 else { return .discard }
        return .restore(viewport)
    }
}

/// One capsule for the paired Mac, kept across a relaunch so a return after iOS ended the app still
/// resumes. Viewport numbers only; the unsent text draft stays in memory and is never written here.
struct SessionResumeStore {
    static let defaultsKey = "sessionResumeCapsule"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> SessionResumeCapsule? {
        defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(SessionResumeCapsule.self, from: $0) }
    }

    func save(_ capsule: SessionResumeCapsule?) {
        guard let capsule, let data = try? JSONEncoder().encode(capsule) else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
