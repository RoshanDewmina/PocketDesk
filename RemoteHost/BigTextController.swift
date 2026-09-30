import CoreGraphics
import Foundation

struct BigTextOffer: Equatable {
    let baseline: DisplayModeInfo
    let steps: [DisplayModeInfo]
    let current: DisplayModeInfo
}

/// A completed change receipt distinguishes duplicate AppKit notifications from a new display change.
struct BigTextScreenSnapshot {
    let frames: [CGDirectDisplayID: CGRect]
    let modeIDs: [CGDirectDisplayID: Int32]

    func matches(online: Set<CGDirectDisplayID>, frames liveFrames: [CGDirectDisplayID: CGRect],
                 modeIDs liveModes: [CGDirectDisplayID: Int32]) -> Bool {
        guard online == Set(frames.keys), Set(liveFrames.keys) == online, Set(modeIDs.keys) == online,
              liveModes == modeIDs else { return false }
        return frames.allSatisfy { id, frame in
            liveFrames[id].map { BigTextRefresh.matches(frame: frame, coreGraphicsBounds: $0) } ?? false
        }
    }

    /// CG may move a neighbour attached beyond the resized display's far edge. Other
    /// sizes, origins and mode IDs must stay at the starting configuration.
    func matchesChange(display: CGDirectDisplayID, target: DisplayModeInfo, online: Set<CGDirectDisplayID>,
                       frames live: [CGDirectDisplayID: CGRect], modeIDs modes: [CGDirectDisplayID: Int32]) -> Bool {
        guard online == Set(frames.keys), Set(live.keys) == online, Set(modes.keys) == online,
              let original = frames[display], let changed = live[display], modes[display] == target.ioModeID,
              abs(changed.minX - original.minX) < 1, abs(changed.minY - original.minY) < 1,
              abs(changed.width - CGFloat(target.width)) < 1, abs(changed.height - CGFloat(target.height)) < 1
        else { return false }
        let dx = changed.width - original.width, dy = changed.height - original.height
        return frames.allSatisfy { id, frame in
            guard id != display else { return true }
            guard modes[id] == modeIDs[id], let current = live[id],
                  abs(current.width - frame.width) < 1, abs(current.height - frame.height) < 1 else { return false }
            let xShift = frame.minX >= original.maxX - 1 ? dx : 0
            let yShift = frame.minY >= original.maxY - 1 ? dy : 0
            let xMatches = abs(current.minX - frame.minX) < 1 || abs(current.minX - frame.minX - xShift) < 1
            let yMatches = abs(current.minY - frame.minY) < 1 || abs(current.minY - frame.minY - yShift) < 1
            return xMatches && yMatches
        }
    }

}

enum BigTextRefresh {
    static let attempts = 6
    static let retryDelay: Duration = .milliseconds(200)
    static func matches(frame: CGRect, coreGraphicsBounds: CGRect) -> Bool {
        abs(frame.width - coreGraphicsBounds.width) < 1 && abs(frame.height - coreGraphicsBounds.height) < 1 &&
            abs(frame.minX - coreGraphicsBounds.minX) < 1 && abs(frame.minY - coreGraphicsBounds.minY) < 1
    }
}

@MainActor
protocol BigTextHost: AnyObject {
    func bigTextQuiesce()
    func bigTextResume(display: CGDirectDisplayID) async -> Bool
    func bigTextReply(display: CGDirectDisplayID, error: BigTextError?, requestID: String?)
    func bigTextForeignChange()
    func bigTextStateChanged()
    func bigTextDisplayBounds(_ display: CGDirectDisplayID) -> CGRect
    func bigTextRunningAppPIDs() -> [pid_t]
}

@MainActor
final class BigTextController {
    enum Phase: Equatable { case idle, changing, applied, restoring }
    enum RestoreReason: String { case sessionEnded, displaySwitched, sessionOff, restoreButton }

    static let settle: TimeInterval = 0.3
    static let poll: TimeInterval = 0.1
    static let disconnectGrace: TimeInterval = 20

    private enum Request: Equatable {
        case apply(CGDirectDisplayID, Double, String?)
        case restore(RestoreReason, reply: CGDirectDisplayID?, requestID: String?)
    }
    private enum Outcome { case ours, foreign, failed, cancelled }

    private(set) var phase: Phase = .idle
    private(set) var display: CGDirectDisplayID?
    private(set) var baseline: DisplayModeInfo?
    private(set) var current: DisplayModeInfo?
    private(set) var restorePending = false
    private(set) var changeTarget: (display: CGDirectDisplayID, mode: DisplayModeInfo)?
    weak var host: BigTextHost?

    var isEngaged: Bool { phase != .idle || current != nil || restorePending }
    var isChanging: Bool { phase == .changing || phase == .restoring }

    private let switcher: DisplayModeSwitching
    private let windows: BigTextWindowKeeping
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async -> Void
    private var recognizer: OwnChangeRecognizer?
    private var completedSnapshot: BigTextScreenSnapshot?
    private var activeRequestID: String?
    private var pending: Request?
    private var worker: Task<Void, Never>?
    private var grace: Task<Void, Never>?

    init(switcher: DisplayModeSwitching, windows: BigTextWindowKeeping,
         now: @escaping () -> TimeInterval, sleep: @escaping (TimeInterval) async -> Void) {
        self.switcher = switcher
        self.windows = windows
        self.now = now
        self.sleep = sleep
    }

    func offer(for display: CGDirectDisplayID) -> BigTextOffer? {
        guard let live = switcher.currentMode(of: display) else { return nil }
        let base = (self.display == display ? baseline : nil) ?? live
        return BigTextOffer(baseline: base, steps: BigTextSteps.steps(baseline: base, modes: switcher.modes(of: display)), current: live)
    }

    static func describe(_ descriptor: DisplayDescriptor, offer: BigTextOffer?) -> DisplayDescriptor {
        guard let offer else { return descriptor }
        var described = descriptor
        described.scaleSteps = offer.steps.map(\.step)
        described.scaleBaselineWidth = Double(offer.baseline.width)
        described.scaleCurrentWidth = Double(offer.current.width)
        return described
    }

    func request(display: CGDirectDisplayID, looksLikeWidth: Double, allowed: Bool, accessibilityGranted: Bool, requestID: String? = nil) {
        guard allowed else { return host?.bigTextReply(display: display, error: .disabled, requestID: requestID) ?? () }
        guard accessibilityGranted else { return host?.bigTextReply(display: display, error: .noAccessibility, requestID: requestID) ?? () }
        enqueue(looksLikeWidth == 0 ? .restore(.sessionOff, reply: display, requestID: requestID) : .apply(display, looksLikeWidth, requestID))
    }

    func observe(_ event: DisplayReconfigurationEvent) {
        guard recognizer == nil else {
            // A completed callback can be delivered while the next AX preparation awaits.
            // Ignore it only when the whole live configuration still equals that preparation's start.
            if recognizer?.applicationStarted == false,
               event.flags.isDisjoint(with: [.addFlag, .removeFlag, .enabledFlag, .disabledFlag, .mirrorFlag, .unMirrorFlag]),
               configurationIsOurs(applied: false) { return }
            recognizer?.observe(event)
            return
        }
        guard !isChanging, !event.flags.contains(.beginConfigurationFlag) else { return }
        if forgetIfChangedElsewhere() { host?.bigTextStateChanged() }
    }

    func sessionEnded(_ reason: RestoreReason) {
        grace?.cancel()
        grace = nil
        guard isEngaged || worker != nil else { return }
        enqueue(.restore(reason, reply: reason == .restoreButton ? display : nil, requestID: nil))
    }

    func connectionLost() {
        grace?.cancel()
        grace = nil
        guard isEngaged || worker != nil else { return }
        grace = Task { [weak self] in
            guard let self else { return }
            await self.sleep(Self.disconnectGrace)
            guard !Task.isCancelled else { return }
            self.grace = nil
            self.sessionEnded(.sessionEnded)
        }
    }

    func sessionResumed() {
        grace?.cancel()
        grace = nil
    }

    func retryPendingRestore() {
        guard restorePending else { return }
        enqueue(.restore(.sessionEnded, reply: nil, requestID: nil))
    }

    func restoreForTermination() {
        worker?.cancel()
        grace?.cancel()
        grace = nil
        pending = nil
        let inFlight = recognizer.flatMap { $0.applicationStarted ? $0.target : nil }
        recognizer = nil
        guard let display, let baseline else { return }
        let live = switcher.currentMode(of: display)?.ioModeID
        // The worker may be suspended mid-change, with the mode already switched to a target it has not recognised yet.
        let stillOurs = live.map { live in [current, inFlight].contains { $0?.ioModeID == live } } ?? false
        if stillOurs, live != baseline.ioModeID {
            changeTarget = (display, baseline)
            phase = .restoring
            host?.bigTextStateChanged()
            _ = switcher.apply(baseline, to: display)
        }
        forget()
    }

    func drain() async {
        while grace != nil || worker != nil {
            if let grace { await grace.value }
            if let worker { await worker.value }
        }
    }

    private func enqueue(_ request: Request) {
        guard worker != nil else { return start(request) }
        switch pending {
        case .apply(let superseded, _, let id)?: host?.bigTextReply(display: superseded, error: .busy, requestID: id)
        case .restore(_, let superseded?, let id)?: host?.bigTextReply(display: superseded, error: .busy, requestID: id)
        default: break
        }
        pending = request
    }

    private func start(_ first: Request) {
        worker = Task { [weak self] in
            var next: Request? = first
            while let request = next, let self, !Task.isCancelled {
                await self.perform(request)
                next = self.pending
                self.pending = nil
            }
            self?.worker = nil
        }
    }

    private func perform(_ request: Request) async {
        switch request {
        case .apply(let target, let width, let id):
            activeRequestID = id
            await apply(width, on: target)
        case .restore(let reason, let replyTo, let id):
            activeRequestID = id
            await restore(reason, replyTo: replyTo)
        }
    }

    private func apply(_ width: Double, on target: CGDirectDisplayID) async {
        if forgetIfChangedElsewhere() { host?.bigTextStateChanged() }
        if let display, display != target {
            await restore(.displaySwitched, replyTo: nil)
            guard self.display == nil else { return reply(target, .failed) }
        }
        guard let offer = offer(for: target) else { return reply(target, .failed) }
        guard let mode = BigTextSteps.nearest(to: width, in: offer.steps) else {
            return reply(target, width >= Double(offer.baseline.width) ? nil : .unsupported)
        }
        guard mode.ioModeID != offer.current.ioModeID else { return reply(target, nil) }

        let first = current == nil
        beginChange(to: mode, on: target)
        defer { recognizer = nil }
        changeTarget = (target, mode)
        phase = .changing
        host?.bigTextStateChanged()
        host?.bigTextQuiesce()
        if first {
            display = target
            baseline = offer.baseline
            await windows.snapshot(within: host?.bigTextDisplayBounds(target) ?? .null, pids: host?.bigTextRunningAppPIDs() ?? [])
        } else {
            await windows.prepareStep()
        }
        switch await change(to: mode, on: target) {
        case .ours:
            await windows.recordSettled()
            guard !Task.isCancelled else { return }
            guard configurationIsOurs(applied: true) else {
                handleForeignApply(mode: mode, target: target)
                return
            }
            current = mode
            restorePending = false
            phase = .applied
            // A refreshed display list that cannot be verified is handled by the host as a foreign change.
            let resumed = await host?.bigTextResume(display: target) ?? false
            guard configurationIsOurs(applied: true) else {
                handleForeignApply(mode: mode, target: target)
                return
            }
            completedSnapshot = screenSnapshot()
            reply(target, resumed ? nil : .failed)
        case .failed:
            if first { forget() } else { phase = .applied }
            _ = await host?.bigTextResume(display: target)
            if configurationIsOurs(applied: false) { completedSnapshot = screenSnapshot() }
            reply(target, .failed)
        case .foreign:
            handleForeignApply(mode: mode, target: target)
            return
        case .cancelled:
            return
        }
        host?.bigTextStateChanged()
    }

    private func restore(_ reason: RestoreReason, replyTo: CGDirectDisplayID?) async {
        if forgetIfChangedElsewhere() { host?.bigTextStateChanged() }
        guard let target = display, let baseline, current != nil || restorePending else {
            if let replyTo { reply(replyTo, nil) }
            return
        }
        let sessionContinues = reason == .sessionOff || reason == .restoreButton
        beginChange(to: baseline, on: target)
        defer { recognizer = nil }
        changeTarget = (target, baseline)
        phase = .restoring
        host?.bigTextStateChanged()
        if sessionContinues { host?.bigTextQuiesce() }
        var failed = false
        switch await change(to: baseline, on: target) {
        case .ours:
            current = nil
            self.baseline = nil
            display = nil
            restorePending = false
            phase = .idle
            await windows.restore()
            if !configurationIsOurs(applied: true) { failed = true; windows.discard(); host?.bigTextForeignChange() }
        case .failed:
            failed = true
            // A live session keeps Big Text and restores when it ends; only an ended one needs the retry flag.
            restorePending = restorePending || !sessionContinues
            phase = restorePending ? .idle : .applied
        case .foreign:
            // A monitor plugged in mid-restore can leave our mode in place; keep the baseline so the
            // session-end retry, wake or unlock restores it. Any other mode was restored or chosen.
            let live = switcher.currentMode(of: target)?.ioModeID
            if let current, live == nil || live == current.ioModeID {
                // Sleep/lock may make the mode unreadable. That is not evidence the person chose
                // another mode; keep the baseline until a live query can establish ownership.
                restorePending = true
                phase = .idle
            } else {
                forget()
            }
            if sessionContinues {
                if let replyTo { reply(replyTo, .failed) }
                host?.bigTextForeignChange()
                host?.bigTextStateChanged()
                return
            }
        case .cancelled:
            return
        }
        if sessionContinues, await host?.bigTextResume(display: target) != true { failed = true }
        if configurationIsOurs(applied: !failed) { completedSnapshot = screenSnapshot() }
        if let replyTo { reply(replyTo, failed ? .failed : nil) }
        host?.bigTextStateChanged()
    }

    private func screenSnapshot() -> BigTextScreenSnapshot {
        let online = switcher.onlineDisplays()
        let frames = Dictionary(uniqueKeysWithValues: online.map { ($0, switcher.bounds(of: $0)) })
        let modes = Dictionary(uniqueKeysWithValues: online.compactMap { id in
            switcher.currentMode(of: id).map { (id, $0.ioModeID) }
        })
        return BigTextScreenSnapshot(frames: frames, modeIDs: modes)
    }

    private func beginChange(to mode: DisplayModeInfo, on target: CGDirectDisplayID) {
        let before = screenSnapshot()
        completedSnapshot = nil
        recognizer = OwnChangeRecognizer(display: target, target: mode, onlineBefore: Set(before.frames.keys),
                                        startedAt: now(), before: before, preparing: true)
    }

    private func configurationIsOurs(applied: Bool) -> Bool {
        guard let recognizer else { return false }
        let live = screenSnapshot()
        return recognizer.configurationMatches(online: Set(live.frames.keys), frames: live.frames,
                                               modeIDs: live.modeIDs, applied: applied)
    }

    /// Host observers and asynchronous display refreshes must verify the same ownership
    /// evidence as the worker, rather than treating every change during an await as ours.
    var ownsLiveConfiguration: Bool {
        if let recognizer {
            return configurationIsOurs(applied: switcher.currentMode(of: recognizer.display)?.ioModeID == recognizer.target.ioModeID)
        }
        guard let completedSnapshot else { return false }
        let live = screenSnapshot()
        return completedSnapshot.matches(online: Set(live.frames.keys), frames: live.frames, modeIDs: live.modeIDs)
    }

    /// Pending owns only observer deferral; resume and completed receipts still require
    /// strict full-mode evidence through ownsLiveConfiguration.
    var screenChangeVerdict: OwnChangeRecognizer.Verdict {
        guard let recognizer else { return ownsLiveConfiguration ? .ours : .foreign }
        let live = screenSnapshot()
        return recognizer.screenChangeVerdict(now: now(), online: Set(live.frames.keys),
                                               frames: live.frames, modeIDs: live.modeIDs)
    }

    func handleScreenChangeNotification(refit: () -> Void, foreign: () -> Void) {
        switch screenChangeVerdict {
        case .ours, .pending: refit()
        case .foreign: foreign()
        }
    }

    private func handleForeignApply(mode: DisplayModeInfo, target: CGDirectDisplayID) {
        // Retain only display-mode ownership, never a window plan from a foreign configuration.
        windows.discard()
        let live = switcher.currentMode(of: target)?.ioModeID
        if recognizer?.applicationStarted == true, live == nil || live == mode.ioModeID {
            current = mode
            phase = .applied
        } else if let current, live == current.ioModeID {
            phase = .applied
        } else {
            forget()
        }
        reply(target, .failed)
        host?.bigTextForeignChange()
        host?.bigTextStateChanged()
    }

    private func change(to mode: DisplayModeInfo, on target: CGDirectDisplayID) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        guard configurationIsOurs(applied: false) else { return .foreign }
        if switcher.currentMode(of: target)?.ioModeID == mode.ioModeID {
            recognizer?.beginApplying(at: now())
            return .ours
        }
        recognizer?.beginApplying(at: now())
        guard switcher.apply(mode, to: target) == .applied else { return .failed }
        while let recognizer, !Task.isCancelled {
            let live = screenSnapshot()
            if recognizer.screenChangeVerdict(now: now(), online: Set(live.frames.keys),
                                                frames: live.frames, modeIDs: live.modeIDs) == .foreign {
                return .foreign
            }
            switch recognizer.verdict(now: now(), online: switcher.onlineDisplays(), current: switcher.currentMode(of: target)) {
            case .ours:
                await self.sleep(Self.settle)
                guard !Task.isCancelled else { return .cancelled }
                return configurationIsOurs(applied: true) ? .ours : .foreign
            case .foreign:
                return .foreign
            case .pending:
                await self.sleep(Self.poll)
            }
        }
        return .cancelled
    }

    // The person may pick a resolution in System Settings while Big Text is applied; their choice
    // wins, so the baseline is dropped instead of being restored over it.
    @discardableResult
    private func forgetIfChangedElsewhere() -> Bool {
        guard let display, let current, let live = switcher.currentMode(of: display),
              live.ioModeID != current.ioModeID else { return false }
        forget()
        return true
    }

    private func forget() {
        windows.discard()
        completedSnapshot = nil
        current = nil
        baseline = nil
        display = nil
        restorePending = false
        changeTarget = nil
        phase = .idle
    }

    private func reply(_ display: CGDirectDisplayID, _ error: BigTextError?) {
        host?.bigTextReply(display: display, error: error, requestID: activeRequestID)
    }
}
