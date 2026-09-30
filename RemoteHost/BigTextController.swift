import CoreGraphics
import Foundation

struct BigTextOffer: Equatable {
    let baseline: DisplayModeInfo
    let steps: [DisplayModeInfo]
    let current: DisplayModeInfo
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

    private(set) var phase: Phase = .idle
    private(set) var display: CGDirectDisplayID?
    private(set) var baseline: DisplayModeInfo?
    private(set) var current: DisplayModeInfo?
    private(set) var restorePending = false
    weak var host: BigTextHost?

    var isEngaged: Bool { phase != .idle || current != nil || restorePending }
    var isChanging: Bool { phase == .changing || phase == .restoring }

    init(switcher: DisplayModeSwitching, windows: BigTextWindowKeeping,
         now: @escaping () -> TimeInterval, sleep: @escaping (TimeInterval) async -> Void) {}

    func offer(for display: CGDirectDisplayID) -> BigTextOffer? { nil }
    func request(display: CGDirectDisplayID, looksLikeWidth: Double, allowed: Bool, accessibilityGranted: Bool) {}
    func observe(_ event: DisplayReconfigurationEvent) {}
    func sessionEnded(_ reason: RestoreReason) {}
    func connectionLost() {}
    func sessionResumed() {}
    func retryPendingRestore() {}
    func restoreForTermination() {}
    func drain() async {}

    static func describe(_ descriptor: DisplayDescriptor, offer: BigTextOffer?) -> DisplayDescriptor { descriptor }
}
