import CoreGraphics
import Foundation

enum DisplayModeApplyResult: Equatable { case applied, failed(Int32) }

@MainActor
protocol DisplayModeSwitching: AnyObject {
    func currentMode(of display: CGDirectDisplayID) -> DisplayModeInfo?
    func modes(of display: CGDirectDisplayID) -> [DisplayModeInfo]
    func apply(_ mode: DisplayModeInfo, to display: CGDirectDisplayID) -> DisplayModeApplyResult
    func onlineDisplays() -> Set<CGDirectDisplayID>
}

struct DisplayReconfigurationEvent: Equatable {
    let display: CGDirectDisplayID
    let flags: CGDisplayChangeSummaryFlags
}

struct OwnChangeRecognizer {
    enum Verdict: Equatable { case pending, ours, foreign }
    static let timeout: TimeInterval = 10

    let display: CGDirectDisplayID
    let target: DisplayModeInfo
    let onlineBefore: Set<CGDirectDisplayID>
    let startedAt: TimeInterval

    mutating func observe(_ event: DisplayReconfigurationEvent) {}
    func verdict(now: TimeInterval, online: Set<CGDirectDisplayID>, current: DisplayModeInfo?) -> Verdict { .pending }
}
