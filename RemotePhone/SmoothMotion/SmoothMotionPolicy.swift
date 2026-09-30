import Foundation

/// Settings → Picture → Smooth motion (D40). Auto is the prototype default.
enum SmoothMotionMode: String, CaseIterable, Identifiable {
    case auto, always, off

    static let key = "smoothMotion.mode"
    static let defaultMode: SmoothMotionMode = .auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .always: "Always"
        case .off: "Off"
        }
    }

    var footnote: String {
        switch self {
        case .auto: "Doubles the frame rate during scrolling, dragging and video. Adds about one frame of delay while active, never while typing or tapping."
        case .always: "Doubles the frame rate whenever the picture changes. Adds about one frame of delay."
        case .off: "Shows each Mac frame as it arrives, with no added delay."
        }
    }

    static func stored(_ defaults: UserDefaults = .standard) -> SmoothMotionMode {
        defaults.string(forKey: key).flatMap(SmoothMotionMode.init(rawValue:)) ?? defaultMode
    }
}

/// Something the phone knows about the next frames before they arrive.
enum SmoothMotionHint: Equatable {
    case scroll, windowDrag, autoPan, typing, preciseTap

    /// The outgoing control actions that predict large motion, typing or a precise tap.
    static func classify(action: String, dragging: Bool) -> SmoothMotionHint? {
        switch action {
        case "scroll": .scroll
        case "move", "moveTo": dragging ? .windowDrag : nil
        case "key", "text": .typing
        case "click", "right", "double", "middle": .preciseTap
        default: nil
        }
    }
}

/// Why interpolation cannot run at all right now, whatever the mode and motion.
enum SmoothMotionBlock: String, Equatable {
    case unsupported = "not supported"
    case display = "display under 120 Hz"
    case thermal = "thermal"
    case behind = "falling behind"
    case failed = "errors"
    case format = "picture format"
    case size = "picture too large"
}

/// When to interpolate. Auto engages only for large motion (a scroll, a window drag, an auto-pan,
/// or sustained whole-picture change such as video) and yields at once to typing and precise taps,
/// where the added frame of delay matters more than smoothness. Static pictures never engage, so
/// the view's own idle refresh (efficiency P2) is left alone. Not thread-safe; the controller locks.
struct SmoothMotionPolicy: Equatable {
    static let motionHold: TimeInterval = 0.3
    static let typingQuiet: TimeInterval = 0.8
    static let tapQuiet: TimeInterval = 0.4
    static let staticAfter: TimeInterval = 0.25
    /// Share of sampled luma points that must change for a frame to count as large motion.
    static let largeChange = 0.12
    /// Consecutive large-change frames before content motion alone engages Auto, so one
    /// window opening or a page switch does not.
    static let sustainedFrames = 3

    enum State: Equatable {
        case engaged(String)
        case idle(String)

        var engaged: Bool { if case .engaged = self { true } else { false } }
        var reason: String {
            switch self {
            case .engaged(let reason), .idle(let reason): reason
            }
        }
    }

    var mode: SmoothMotionMode
    var block: SmoothMotionBlock?
    private(set) var state: State = .idle("starting")
    private var lastMotion = -TimeInterval.infinity
    private var motionKind = "motion"
    private var lastTyping = -TimeInterval.infinity
    private var lastTap = -TimeInterval.infinity
    private var lastFrame = -TimeInterval.infinity
    private var frameBefore = -TimeInterval.infinity
    private var largeRun = 0

    init(mode: SmoothMotionMode) {
        self.mode = mode
    }

    var engaged: Bool { state.engaged }

    mutating func note(_ hint: SmoothMotionHint, at now: TimeInterval) {
        switch hint {
        case .scroll: motion("scroll", at: now)
        case .windowDrag: motion("drag", at: now)
        case .autoPan: motion("auto-pan", at: now)
        case .typing: lastTyping = now
        case .preciseTap: lastTap = now
        }
    }

    /// A decoded frame. `change` is the share of sampled points that moved, nil when not measured.
    mutating func frameArrived(change: Double?, at now: TimeInterval) {
        frameBefore = lastFrame
        lastFrame = now
        guard let change else { return }
        if change >= Self.largeChange {
            largeRun += 1
            if largeRun >= Self.sustainedFrames { motion("content", at: now) }
        } else {
            largeRun = 0
        }
    }

    @discardableResult
    mutating func evaluate(at now: TimeInterval) -> Bool {
        state = decide(at: now)
        return state.engaged
    }

    private func decide(at now: TimeInterval) -> State {
        if mode == .off { return .idle("off") }
        if let block { return .idle(block.rawValue) }
        // The first frame after a still period is shown as it is: the one before it is stale.
        if now - lastFrame > Self.staticAfter || lastFrame - frameBefore > Self.staticAfter { return .idle("static") }
        if mode == .always { return .engaged("always") }
        if now - lastTyping < Self.typingQuiet { return .idle("typing") }
        if now - lastTap < Self.tapQuiet { return .idle("tap") }
        if now - lastMotion <= Self.motionHold { return .engaged(motionKind) }
        return .idle("still")
    }

    private mutating func motion(_ kind: String, at now: TimeInterval) {
        lastMotion = now
        motionKind = kind
    }
}

/// Auto's content-motion signal: the share of a sparse luma grid that changed since the last
/// frame. About 1,300 byte reads per frame, far below the cost of a strip marker read.
struct FrameChangeSampler {
    static let columns = 48
    static let rows = 27
    static let threshold = 12

    private var previous: [UInt8] = []

    mutating func reset() { previous.removeAll(keepingCapacity: true) }

    /// Nil for the first frame after a reset or a size change.
    mutating func change(luma: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> Double? {
        guard width >= Self.columns, height >= Self.rows else { return nil }
        var samples = [UInt8](repeating: 0, count: Self.columns * Self.rows)
        for row in 0..<Self.rows {
            let y = (row * 2 + 1) * height / (Self.rows * 2)
            let line = luma.advanced(by: y * bytesPerRow)
            for column in 0..<Self.columns {
                samples[row * Self.columns + column] = line[(column * 2 + 1) * width / (Self.columns * 2)]
            }
        }
        defer { previous = samples }
        guard previous.count == samples.count else { return nil }
        return Self.changedShare(previous, samples)
    }

    static func changedShare(_ before: [UInt8], _ after: [UInt8]) -> Double {
        guard before.count == after.count, !after.isEmpty else { return 0 }
        var changed = 0
        for index in after.indices where abs(Int(after[index]) - Int(before[index])) > threshold { changed += 1 }
        return Double(changed) / Double(after.count)
    }
}
