import AppKit
import XCTest

final class FakeWindowAccess: WindowAccess, @unchecked Sendable {
    var windows: [WindowRef] = []
    var frames: [WindowRef: CGRect] = [:]
    var set: [(WindowRef, CGRect)] = []
    var refuse: Set<WindowRef> = []
    var stageManagerEnabled = false

    func standardWindows(within bounds: CGRect, pids: [pid_t]) -> [WindowRef] { windows.filter { pids.contains($0.pid) } }
    func frame(of window: WindowRef) -> CGRect? { frames[window] }
    func setFrame(_ frame: CGRect, of window: WindowRef) -> Bool {
        guard !refuse.contains(window) else { return false }
        set.append((window, frame))
        frames[window] = frame
        return true
    }
}

final class BigTextWindowTests: XCTestCase {
    private func window(_ pid: pid_t = 10) -> WindowRef { WindowRef(pid: pid, element: NSObject()) }

    func testOnlyWindowsStillWhereMacOSLeftThemAreRestoredLargestFirst() {
        let small = window(), big = window(), moved = window(), closed = window()
        let before = [small: CGRect(x: 0, y: 0, width: 400, height: 300), big: CGRect(x: 0, y: 0, width: 1400, height: 900),
                      moved: CGRect(x: 0, y: 0, width: 1400, height: 900), closed: CGRect(x: 0, y: 0, width: 1400, height: 900)]
        let after = [small: before[small]!, big: CGRect(x: 0, y: 0, width: 1280, height: 800),
                     moved: CGRect(x: 0, y: 0, width: 1280, height: 800), closed: CGRect(x: 0, y: 0, width: 1280, height: 800)]
        let now = [small: before[small]!, big: after[big]!, moved: CGRect(x: 50, y: 50, width: 900, height: 600)]
        let plan = WindowRestorePlan.moves(before: before, after: after, now: now)
        XCTAssertEqual(plan.map(\.0), [big], "unchanged windows, windows the person moved and closed windows are left alone")
        XCTAssertEqual(plan.first?.1, before[big])
    }

    func testKeeperSnapshotsSettlesAndRestores() async {
        let access = FakeWindowAccess()
        let a = window(), b = window(99)
        access.windows = [a, b]
        access.frames = [a: CGRect(x: 0, y: 0, width: 1400, height: 900), b: CGRect(x: 0, y: 0, width: 800, height: 600)]
        let keeper = BigTextWindowKeeper(access: access)
        await keeper.snapshot(within: CGRect(x: 0, y: 0, width: 1470, height: 956), pids: [10])
        XCTAssertTrue(keeper.hasSnapshot)
        access.frames[a] = CGRect(x: 0, y: 0, width: 1280, height: 800)
        await keeper.recordSettled()
        let restored = await keeper.restore()
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(access.frames[a], CGRect(x: 0, y: 0, width: 1400, height: 900))
        XCTAssertTrue(access.set.allSatisfy { $0.0 !== b }, "windows of apps not listed are never touched")
        XCTAssertFalse(keeper.hasSnapshot, "a restore consumes the snapshot")
    }

    func testStageManagerSkipsRestoreAndRefusalsAreIgnored() async {
        let access = FakeWindowAccess()
        let a = window()
        access.windows = [a]
        access.frames = [a: CGRect(x: 0, y: 0, width: 1400, height: 900)]
        let keeper = BigTextWindowKeeper(access: access)
        await keeper.snapshot(within: .infinite, pids: [10])
        access.frames[a] = CGRect(x: 0, y: 0, width: 1280, height: 800)
        await keeper.recordSettled()
        access.refuse = [a]
        let refusedCount = await keeper.restore()
        XCTAssertEqual(refusedCount, 0)

        await keeper.snapshot(within: .infinite, pids: [10])
        await keeper.recordSettled()
        access.stageManagerEnabled = true
        access.refuse = []
        let stageCount = await keeper.restore()
        XCTAssertEqual(stageCount, 0)
        XCTAssertTrue(access.set.isEmpty)
    }

    func testDiscardForgetsWithoutMoving() async {
        let access = FakeWindowAccess()
        let a = window()
        access.windows = [a]
        access.frames = [a: CGRect(x: 0, y: 0, width: 1400, height: 900)]
        let keeper = BigTextWindowKeeper(access: access)
        await keeper.snapshot(within: .infinite, pids: [10])
        keeper.discard()
        XCTAssertFalse(keeper.hasSnapshot)
        let count = await keeper.restore()
        XCTAssertEqual(count, 0)
    }
}
