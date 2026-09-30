import CoreGraphics
import Foundation

struct BigTextOffer: Equatable {
    let baseline: DisplayModeInfo
    let steps: [DisplayModeInfo]
    let current: DisplayModeInfo
}

enum BigTextRefresh {
    static func matches(frame: CGRect, coreGraphicsBounds: CGRect) -> Bool {
        abs(frame.width - coreGraphicsBounds.width) < 1 && abs(frame.height - coreGraphicsBounds.height) < 1 &&
            abs(frame.minX - coreGraphicsBounds.minX) < 1 && abs(frame.minY - coreGraphicsBounds.minY) < 1
    }
}

@MainActor
protocol BigTextHost: AnyObject {
    func bigTextQuiesce()
    func bigTextResume(display: CGDirectDisplayID) async -> Bool
    func bigTextReply(display: CGDirectDisplayID, error: BigTextError?)
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
        case apply(CGDirectDisplayID, Double)
        case restore(RestoreReason, reply: CGDirectDisplayID?)
    }
    private enum Outcome { case ours, foreign, failed, cancelled }

    private(set) var phase: Phase = .idle
    private(set) var display: CGDirectDisplayID?
    private(set) var baseline: DisplayModeInfo?
    private(set) var current: DisplayModeInfo?
    private(set) var restorePending = false
    weak var host: BigTextHost?

    var isEngaged: Bool { phase != .idle || current != nil || restorePending }
    var isChanging: Bool { phase == .changing || phase == .restoring }

    private let switcher: DisplayModeSwitching
    private let windows: BigTextWindowKeeping
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async -> Void
    private var recognizer: OwnChangeRecognizer?
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

    func request(display: CGDirectDisplayID, looksLikeWidth: Double, allowed: Bool, accessibilityGranted: Bool) {
        guard allowed else { return reply(display, .disabled) }
        guard accessibilityGranted else { return reply(display, .noAccessibility) }
        enqueue(looksLikeWidth == 0 ? .restore(.sessionOff, reply: display) : .apply(display, looksLikeWidth))
    }

    func observe(_ event: DisplayReconfigurationEvent) {
        guard recognizer == nil else {
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
        enqueue(.restore(reason, reply: reason == .restoreButton ? display : nil))
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
        enqueue(.restore(.sessionEnded, reply: nil))
    }

    func restoreForTermination() {
        worker?.cancel()
        grace?.cancel()
        grace = nil
        pending = nil
        recognizer = nil
        guard let display, let baseline else { return }
        let live = switcher.currentMode(of: display)?.ioModeID
        let stillOurs = current.map { live == $0.ioModeID } ?? true
        forget()
        if stillOurs, live != baseline.ioModeID { _ = switcher.apply(baseline, to: display) }
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
        case .apply(let superseded, _)?: reply(superseded, .busy)
        case .restore(_, let superseded?)?: reply(superseded, .busy)
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
        case .apply(let target, let width): await apply(width, on: target)
        case .restore(let reason, let replyTo): await restore(reason, replyTo: replyTo)
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
        phase = .changing
        host?.bigTextStateChanged()
        host?.bigTextQuiesce()
        if first {
            display = target
            baseline = offer.baseline
            await windows.snapshot(within: host?.bigTextDisplayBounds(target) ?? .null, pids: host?.bigTextRunningAppPIDs() ?? [])
        }
        switch await change(to: mode, on: target) {
        case .ours:
            if first { await windows.recordSettled() }
            guard !Task.isCancelled else { return }
            current = mode
            restorePending = false
            phase = .applied
            _ = await host?.bigTextResume(display: target)
            reply(target, nil)
        case .failed:
            if first { forget() } else { phase = .applied }
            _ = await host?.bigTextResume(display: target)
            reply(target, .failed)
        case .foreign:
            // Something else changed too (say, a monitor was plugged in). If the display still took our
            // mode, keep the baseline so the session end restores it; otherwise the new mode is not ours to undo.
            if switcher.currentMode(of: target)?.ioModeID == mode.ioModeID {
                current = mode
                phase = .applied
            } else {
                forget()
            }
            host?.bigTextForeignChange()
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
        case .failed:
            failed = true
            // A live session keeps Big Text and restores when it ends; only an ended one needs the retry flag.
            restorePending = restorePending || !sessionContinues
            phase = restorePending ? .idle : .applied
        case .foreign:
            forget()
            if sessionContinues {
                host?.bigTextForeignChange()
                host?.bigTextStateChanged()
                return
            }
        case .cancelled:
            return
        }
        if sessionContinues { _ = await host?.bigTextResume(display: target) }
        if let replyTo { reply(replyTo, failed ? .failed : nil) }
        host?.bigTextStateChanged()
    }

    private func change(to mode: DisplayModeInfo, on target: CGDirectDisplayID) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        if switcher.currentMode(of: target)?.ioModeID == mode.ioModeID { return .ours }
        recognizer = OwnChangeRecognizer(display: target, target: mode, onlineBefore: switcher.onlineDisplays(), startedAt: now())
        defer { recognizer = nil }
        guard switcher.apply(mode, to: target) == .applied else { return .failed }
        while let recognizer, !Task.isCancelled {
            switch recognizer.verdict(now: now(), online: switcher.onlineDisplays(), current: switcher.currentMode(of: target)) {
            case .ours:
                await self.sleep(Self.settle)
                return Task.isCancelled ? .cancelled : .ours
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
        current = nil
        baseline = nil
        display = nil
        restorePending = false
        phase = .idle
    }

    private func reply(_ display: CGDirectDisplayID, _ error: BigTextError?) {
        host?.bigTextReply(display: display, error: error)
    }
}
