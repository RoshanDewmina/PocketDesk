#if DEBUG
import XCTest
#if os(macOS)
import Darwin
#endif

final class VirtualDisplayPrototypePolicyTests: XCTestCase {
    private final class LifetimeProbe { let onRelease: () -> Void; init(_ callback: @escaping () -> Void) { onRelease = callback }; deinit { onRelease() } }
    private func options(_ extra: [String] = []) throws -> PortraitPrototypeOptions {
        try .parse(["host", PortraitPrototypeOptions.argument] + extra)
    }
    func testGeometryRejectsLandscapeWrongScaleAndUnknownRefresh() throws {
        let two = try options(["--portrait-mode", "2x"])
        XCTAssertTrue(two.accepts(logicalWidth: 430, logicalHeight: 932, pixelsWide: 860, pixelsHigh: 1864, backingScale: 2, refresh: 60))
        XCTAssertFalse(two.accepts(logicalWidth: 932, logicalHeight: 430, pixelsWide: 1864, pixelsHigh: 860, backingScale: 2, refresh: 60))
        XCTAssertFalse(two.accepts(logicalWidth: 430, logicalHeight: 932, pixelsWide: 430, pixelsHigh: 932, backingScale: 1, refresh: 60))
        XCTAssertFalse(two.accepts(logicalWidth: 430, logicalHeight: 932, pixelsWide: 860, pixelsHigh: 1864, backingScale: 2, refresh: 0))
        XCTAssertFalse(two.accepts(logicalWidth: 430, logicalHeight: 932, pixelsWide: 860, pixelsHigh: 1864, backingScale: 2, refresh: .nan))
        XCTAssertEqual(try options().pixelWidth, 430)
    }
    func testExplicitScreenWindowInitializerUsesRelativeOriginOnEveryDesktopArrangement() {
        for origin in [CGPoint.zero, CGPoint(x: 1920, y: 0), CGPoint(x: -430, y: 0),
                       CGPoint(x: 0, y: 1243), CGPoint(x: 0, y: -932)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 430, height: 932))
            let content = PortraitWindowPlacement.screenRelativeContentRect(for: screen)
            XCTAssertEqual(content.origin, .zero)
            XCTAssertEqual(content.size, screen.size)
            // Apply the documented initializer translation exactly once to obtain the owned global frame.
            let global = content.offsetBy(dx: screen.origin.x, dy: screen.origin.y)
            XCTAssertEqual(global, screen)
        }
    }
    func testTransientScaledSnapshotAndWrongIdentitiesNeverPassPlacementGate() {
        let bounds = CGRect(x: -430, y: 0, width: 430, height: 932)
        func matches(_ frame: CGRect?, window: UInt32? = 820, owner: Int32? = 91, screen: UInt32? = 5, displayFound: Bool = true) -> Bool {
            PortraitWindowPlacement.matches(windowID: window, ownerPID: owner, screenID: screen, displayFound: displayFound,
                captureFrame: frame, expectedWindowID: 820, expectedOwnerPID: 91, expectedDisplayID: 5, displayBounds: bounds)
        }
        XCTAssertFalse(matches(CGRect(x: -426, y: 8, width: 422, height: 916)))
        XCTAssertFalse(matches(nil)); XCTAssertFalse(matches(bounds, window: 821)); XCTAssertFalse(matches(bounds, owner: 92))
        XCTAssertFalse(matches(bounds, screen: 1)); XCTAssertFalse(matches(bounds, displayFound: false))
        XCTAssertFalse(matches(bounds.offsetBy(dx: 0, dy: 311))) // AppKit and CG coordinates cannot be mixed.
        XCTAssertTrue(matches(bounds))
    }
    func testPlacementRediscoverySharesOneFiveSecondDeadline() {
        let deadline = PortraitPlacementDeadline(startMs: 100)
        XCTAssertEqual(deadline.remainingNanoseconds(nowMs: 100), 5_000_000_000)
        XCTAssertEqual(deadline.remainingNanoseconds(nowMs: 2500), 2_600_000_000)
        XCTAssertEqual(deadline.remainingNanoseconds(nowMs: 5099), 1_000_000)
        XCTAssertNil(deadline.remainingNanoseconds(nowMs: 5100)); XCTAssertNil(deadline.remainingNanoseconds(nowMs: 8000))
        XCTAssertNil(deadline.remainingNanoseconds(nowMs: .nan))
        XCTAssertNil(PortraitPlacementDeadline(startMs: .infinity).remainingNanoseconds(nowMs: 100))
    }
    func testCLIFailsClosedBeforeHostStartup() throws {
        for extra in [["--portrait-mode"], ["--portrait-mode", "landscape"], ["--portrait-action", "unknown"],
                      ["--portrait-mode", "1x", "--portrait-mode", "2x"], ["--virtual-display-spike"],
                      ["--portrait-action", "smoke", "--portrait-moving-seconds", "nan"],
                      ["--portrait-action", "smoke", "--portrait-moving-seconds", "0"],
                      ["--portrait-action", "smoke", "--portrait-idle-seconds", "6"],
                      ["--portrait-moving-seconds", "1"], [PortraitPrototypeOptions.argument], ["--unexpected"]] {
            XCTAssertThrowsError(try options(extra), "\(extra)")
        }
        XCTAssertThrowsError(try PortraitPrototypeOptions.parse(["host"]))
        XCTAssertThrowsError(try PortraitPrototypeOptions.parse(["host", "--portrait-mode", "2x"]))
        XCTAssertTrue(PortraitPrototypeOptions.requested(["host", "--portrait-mode", "2x"]))
        XCTAssertTrue(PortraitPrototypeOptions.requested(["host", "--portrait-action", "check"]))
        XCTAssertTrue(PortraitPrototypeOptions.requested(["host", "--virtual-display-portrait-typo"]))
        XCTAssertFalse(PortraitPrototypeOptions.requested(["host", "--virtual-display-spike"]))
        XCTAssertEqual(try options(["--portrait-action", "check"]).action, .check)
    }
    func testRepeatedMissingAndNonMonotonicTimestampsAreNotDistinct() {
        var metrics = PortraitFrameMetrics()
        metrics.record(status: "complete", timeMs: nil)
        metrics.record(status: "complete", timeMs: 0)
        metrics.record(status: "complete", timeMs: .nan)
        metrics.record(status: "idle", timeMs: 100)
        metrics.record(status: "complete", timeMs: 100)
        metrics.record(status: "complete", timeMs: 100)
        metrics.record(status: "complete", timeMs: 90)
        metrics.record(status: "complete", timeMs: 120)
        XCTAssertEqual(metrics.distinct, 2); XCTAssertEqual(metrics.missing, 3)
        XCTAssertEqual(metrics.repeated, 1); XCTAssertEqual(metrics.nonMonotonic, 1)
        XCTAssertEqual(metrics.report(seconds: 2)["fps"] as? Double, 1)
        XCTAssertEqual(metrics.report(seconds: 2)["p90GapMs"] as? Double, 20)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(metrics.report(seconds: .nan)))
    }
    func testMetricsStorageAndVocabularyAreBounded() {
        var metrics = PortraitFrameMetrics()
        for value in 1...5000 { metrics.record(status: "complete", timeMs: Double(value)); metrics.record(status: "untrusted-\(value)", timeMs: nil) }
        XCTAssertEqual(metrics.timesMs.count, 2048); XCTAssertEqual(metrics.distinct, 5000)
        XCTAssertEqual(metrics.dropped, 5000 - 2048); XCTAssertEqual(metrics.statuses.count, 2)
    }
    func testStaleCallbackCannotAdmitOrClearReplacement() {
        var admission = PortraitRunAdmission()
        let first = admission.start()!
        admission.cancel(); XCTAssertFalse(admission.accepts(first)); XCTAssertNil(admission.start())
        admission.cleaned(); let second = admission.start()!
        XCTAssertFalse(admission.accepts(first)); XCTAssertTrue(admission.accepts(second))
    }
    func testABIScalarStructAndBlockMismatchesFailClosed() {
        let expected = ["@", ":", "I", "I", "d"]
        XCTAssertTrue(PortraitABIEncoding.accepts(actualReturn: "@", actualArguments: expected, expectedReturn: "@", expectedArguments: expected))
        for argument in ["Q", "q", "i", "f", "@?"] {
            XCTAssertFalse(PortraitABIEncoding.accepts(actualReturn: "@", actualArguments: ["@", ":", argument, "I", "d"], expectedReturn: "@", expectedArguments: expected))
        }
        XCTAssertFalse(PortraitABIEncoding.accepts(actualReturn: "c", actualArguments: ["@", ":", "@"], expectedReturn: "B", expectedArguments: ["@", ":", "@"]))
        XCTAssertFalse(PortraitABIEncoding.accepts(actualReturn: "v", actualArguments: ["@", ":", "{CGSize=ff}"], expectedReturn: "v", expectedArguments: ["@", ":", "{CGSize=dd}"]))
    }
    func testDeniedPermissionCreatesNothingAndDoesNotInvokeAuditOrLease() {
        var calls: [String] = []
        XCTAssertThrowsError(try PortraitCreationPreflight.acquire(permission: { false }, audit: { calls.append("audit") },
            lease: { calls.append("lease"); return 1 }, existingIdentity: { calls.append("identity"); return false },
            create: { calls.append("create"); return 2 }))
        XCTAssertTrue(calls.isEmpty)
    }
    func testUnsupportedABILeaseFailureAndExistingIdentityCannotCreateDisplay() {
        for stage in ["abi", "lease", "identity"] {
            var creates = 0
            XCTAssertThrowsError(try PortraitCreationPreflight.acquire(permission: { true }, audit: {
                if stage == "abi" { throw PortraitPrototypeFailure.rejected("abi") }
            }, lease: { () throws -> Int in
                if stage == "lease" { throw PortraitPrototypeFailure.rejected("lease") }; return 1
            }, existingIdentity: { stage == "identity" }, create: { creates += 1; return 2 }))
            XCTAssertEqual(creates, 0)
        }
    }
    #if os(macOS)
    func testRuntimeLeaseRejectsOccupiedSymlinkAndInsecureFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("farside-portrait-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("lease").path
        var first: PortraitRuntimeLease? = try .acquire(path: path)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try PortraitRuntimeLease.acquire(path: path))
        first = nil
        let second = try PortraitRuntimeLease.acquire(path: path)
        try withExtendedLifetime(second) {
            let symlink = directory.appendingPathComponent("link").path
            XCTAssertEqual(Darwin.symlink(path, symlink), 0)
            XCTAssertThrowsError(try PortraitRuntimeLease.acquire(path: symlink))
        }
        let insecure = directory.appendingPathComponent("insecure").path
        XCTAssertTrue(FileManager.default.createFile(atPath: insecure, contents: Data()))
        XCTAssertEqual(chmod(insecure, 0o644), 0)
        XCTAssertThrowsError(try PortraitRuntimeLease.acquire(path: insecure))
    }
    #endif

    /// These invoke the SAME async callback resource owner used by the production SCStream adapter.
    /// The fabricated stream identity is captured in its own stop closure; no WindowServer is needed.
    @MainActor
    func testConfigurationFailureRetainsAcquiredDisplayAndLeaseUntilRemovalAcknowledged() throws {
        var displayReleases = 0; var leaseReleases = 0
        var lease: LifetimeProbe? = LifetimeProbe { leaseReleases += 1 }
        weak var weakDisplay: LifetimeProbe?
        let owner = PortraitDisplayCreationOwner<LifetimeProbe, LifetimeProbe>()
        XCTAssertThrowsError(try owner.create(lease: lease!, construct: {
            let display = LifetimeProbe { displayReleases += 1 }; weakDisplay = display; return display
        }, identify: { _ in 71 }, configure: { _ in throw PortraitPrototypeFailure.rejected("configuration rejected") }))
        lease = nil
        XCTAssertNotNil(weakDisplay); XCTAssertEqual(owner.displayID, 71)
        XCTAssertEqual(displayReleases, 0); XCTAssertEqual(leaseReleases, 0)
        owner.releaseDisplay()
        XCTAssertNil(weakDisplay); XCTAssertEqual(displayReleases, 1); XCTAssertEqual(leaseReleases, 0)
        // The controller calls this ONLY after observing removal; failed removal retains the lease.
        owner.acknowledgeRemoval(); XCTAssertEqual(leaseReleases, 1)
    }
    @MainActor
    func testUnknownAcquiredDisplayIdentityCannotConfigureOrReuseOwner() {
        let owner = PortraitDisplayCreationOwner<Int, Int>()
        var configured = false
        XCTAssertThrowsError(try owner.create(lease: 4, construct: { 9 }, identify: { _ in 0 }, configure: { _ in configured = true }))
        XCTAssertFalse(configured); XCTAssertTrue(owner.hadDisplay); XCTAssertEqual(owner.lease, 4)
        owner.releaseDisplay()
        XCTAssertThrowsError(try owner.create(lease: 5, construct: { 10 }, identify: { _ in 2 }, configure: { _ in }))
        XCTAssertEqual(owner.lease, 4)
    }
    @MainActor
    func testDelayedSuccessfulStartAfterStopStopsExactResourceBeforeRelease() {
        var completeStart: PortraitCaptureOwner.Completion?
        var completeStop: PortraitCaptureOwner.Completion?
        var stoppedIDs: [Int] = []; var released = 0
        let streamID = 47
        let owner = PortraitCaptureOwner(start: { completeStart = $0 }, stop: {
            stoppedIDs.append(streamID); completeStop = $0
        }, release: { released += 1 })
        owner.start(); owner.stop(); owner.stop()
        XCTAssertTrue(owner.startPending); XCTAssertEqual(released, 0); XCTAssertTrue(stoppedIDs.isEmpty)
        completeStart?(nil)
        XCTAssertEqual(stoppedIDs, [47]); XCTAssertEqual(owner.state, .stopping); XCTAssertEqual(released, 0)
        completeStop?(nil)
        XCTAssertEqual(owner.state, .stopped); XCTAssertEqual(released, 1)
        completeStart?(nil); completeStop?(nil); owner.stop()
        XCTAssertEqual(released, 1); XCTAssertEqual(stoppedIDs, [47])
    }
    @MainActor
    func testTimedOutStartRetainsResourceUntilLateSuccessAndStop() {
        var start: PortraitCaptureOwner.Completion?; var stop: PortraitCaptureOwner.Completion?; var releases = 0
        let owner = PortraitCaptureOwner(start: { start = $0 }, stop: { stop = $0 }, release: { releases += 1 })
        owner.start(); owner.deadline("start-timeout")
        XCTAssertEqual(owner.state, .unresolved); XCTAssertEqual(releases, 0)
        start?(nil); XCTAssertEqual(owner.state, .stopping); XCTAssertNotNil(stop)
        owner.deadline("stop-timeout"); XCTAssertEqual(releases, 0)
        stop?(nil); XCTAssertEqual(releases, 1); XCTAssertEqual(owner.state, .stopped)
        XCTAssertEqual(owner.failure, "start-timeout")
    }
    @MainActor
    func testFailedStopRetainsResourcesAndBlocksNextStart() {
        var stop: PortraitCaptureOwner.Completion?; var starts = 0; var releases = 0
        var admission = PortraitRunAdmission(); XCTAssertNotNil(admission.start())
        let owner = PortraitCaptureOwner(start: { completion in starts += 1; completion(nil) }, stop: { stop = $0 }, release: { releases += 1; admission.cleaned() })
        owner.start(); owner.stop(); stop?("failed-stop"); owner.start(); owner.stop()
        XCTAssertEqual(owner.state, .unresolved); XCTAssertEqual(releases, 0); XCTAssertEqual(starts, 1)
        XCTAssertNil(admission.start()); XCTAssertEqual(owner.failure, "failed-stop")
    }
    @MainActor
    func testLateOldCompletionCannotReleaseNewOwner() {
        var oldStop: PortraitCaptureOwner.Completion?; var oldReleases = 0; var newReleases = 0
        let old = PortraitCaptureOwner(start: { $0(nil) }, stop: { oldStop = $0 }, release: { oldReleases += 1 })
        old.start(); old.stop(); oldStop?(nil)
        let new = PortraitCaptureOwner(start: { $0(nil) }, stop: { $0(nil) }, release: { newReleases += 1 })
        new.start(); oldStop?(nil)
        XCTAssertEqual(oldReleases, 1); XCTAssertEqual(newReleases, 0); XCTAssertEqual(new.state, .running)
        new.stop(); XCTAssertEqual(newReleases, 1)
    }
    @MainActor
    func testFailedStartAndStopBeforeStartReleaseOnce() {
        var count = 0
        let failed = PortraitCaptureOwner(start: { $0("start-error") }, stop: { _ in XCTFail("failed start should not stop a never-started stream") }, release: { count += 1 })
        failed.start(); failed.stop(); XCTAssertEqual(count, 1); XCTAssertEqual(failed.failure, "start-error")
        let unused = PortraitCaptureOwner(start: { _ in XCTFail("start called") }, stop: { _ in XCTFail("stop called") }, release: { count += 1 })
        unused.stop(); unused.start(); unused.stop(); XCTAssertEqual(count, 2)
    }
}
#endif
