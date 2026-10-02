import Foundation
import XCTest

final class VirtualDisplayWindowTests: XCTestCase {
    private let original = CGRect(x: 40, y: 50, width: 900, height: 700)
    private let target = CGRect(x: 1800, y: 0, width: 603, height: 1311)

    private func fixture() -> (VirtualDisplayWindowKeeper, FakeVirtualWindowAccess, FakeVirtualJournalStore) {
        let access = FakeVirtualWindowAccess()
        access.windows = [VirtualDisplayWindow(identity: .init(pid: 10, launchTime: 123, windowID: 45, axIdentifier: nil), frame: original)]
        let store = FakeVirtualJournalStore()
        return (VirtualDisplayWindowKeeper(access: access, store: store), access, store)
    }

    func testJournalIsPersistedBeforeFirstMutation() async throws {
        let (keeper, access, store) = fixture()
        access.beforeSet = { XCTAssertFalse(store.journal?.records.isEmpty ?? true) }
        try await keeper.moveFrontmostWindows(to: target)
        XCTAssertTrue(keeper.hasPendingRestore)
        XCTAssertEqual(store.journal?.records.first?.original, original)
    }

    func testPreparationPersistsOriginalsBeforeDisplayCreationWithoutMoving() async throws {
        let (keeper, access, store) = fixture()
        try await keeper.prepareFrontmostWindows()
        XCTAssertEqual(access.setCount, 0)
        XCTAssertTrue(store.journal?.isPrepared == true)
        XCTAssertEqual(store.journal?.records.first?.original, original)
        access.windows[0].frame = CGRect(x: 0, y: 0, width: 700, height: 500) // WindowServer creation reflow.
        try await keeper.moveFrontmostWindows(to: target)
        XCTAssertEqual(store.journal?.records.first?.original, original)
        let restored = await keeper.restore()
        XCTAssertTrue(restored)
        XCTAssertEqual(access.windows[0].frame, original)
    }

    func testPreparedCrashJournalRecoversCreationReflowWithoutAnAppliedTarget() async throws {
        let (keeper, access, store) = fixture()
        try await keeper.prepareFrontmostWindows()
        access.windows[0].frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let recovery = VirtualDisplayWindowKeeper(access: access, store: store)
        let restored = await recovery.recover()
        XCTAssertTrue(restored)
        XCTAssertEqual(access.windows[0].frame, original)
        XCTAssertNil(store.journal)
    }

    func testPreparationPersistenceFailureLeavesNoWindowMutation() async {
        let (keeper, access, store) = fixture()
        store.failWrites = true
        do { try await keeper.prepareFrontmostWindows(); XCTFail("persist must precede display creation") } catch {}
        XCTAssertEqual(access.setCount, 0)
        XCTAssertFalse(keeper.hasPendingRestore)
        XCTAssertEqual(access.windows[0].frame, original)
    }

    func testPersistenceFailureNeverMovesWindow() async {
        let (keeper, access, store) = fixture()
        store.failWrites = true
        do { try await keeper.moveFrontmostWindows(to: target); XCTFail("must fail") } catch {}
        XCTAssertEqual(access.setCount, 0)
        XCTAssertEqual(access.windows.first?.frame, original)
    }

    func testPartialMutationIsRolledBack() async {
        let (keeper, access, _) = fixture()
        access.refuseNext = true
        do { try await keeper.moveFrontmostWindows(to: target); XCTFail("must fail") } catch {}
        XCTAssertEqual(access.windows.first?.frame, original)
        XCTAssertFalse(keeper.hasPendingRestore)
    }

    func testLaterWindowFailureRollsBackEveryEarlierMutation() async {
        let (keeper, access, _) = fixture()
        var second = access.windows[0]
        second.identity.windowID = 46
        second.frame = CGRect(x: 100, y: 80, width: 900, height: 700)
        access.windows.append(second)
        access.refuseWindowIDOnce = 46
        access.beforeSet = { XCTAssertEqual(access.windows.count, 2); XCTAssertEqual(keeper.hasPendingRestore, true) }
        do { try await keeper.moveFrontmostWindows(to: target); XCTFail("must fail") } catch {}
        XCTAssertEqual(access.windows[0].frame, original)
        XCTAssertEqual(access.windows[1].frame, second.frame)
        XCTAssertFalse(keeper.hasPendingRestore)
    }

    func testPostMovePersistenceFailureRollsBackAndDeleteFailureRetainsReceipt() async throws {
        let (keeper, access, store) = fixture()
        store.failWriteNumber = 2
        do { try await keeper.moveFrontmostWindows(to: target); XCTFail("must fail") } catch {}
        XCTAssertEqual(access.windows[0].frame, original)
        store.failWriteNumber = nil
        try await keeper.moveFrontmostWindows(to: target)
        store.failRemoval = true
        let failed = await keeper.restore()
        XCTAssertFalse(failed)
        XCTAssertTrue(keeper.hasPendingRestore)
        XCTAssertEqual(access.windows[0].frame, original)
        store.failRemoval = false
        let retried = await keeper.restore()
        XCTAssertTrue(retried)
    }

    func testSameSizeWindowsGetDistinctFramesAndPreserveBothOriginals() async throws {
        let (keeper, access, store) = fixture()
        var second = access.windows[0]
        second.identity.windowID += 1
        second.frame.origin = CGPoint(x: 120, y: 100)
        access.windows.append(second)
        try await keeper.moveFrontmostWindows(to: target)
        XCTAssertFalse(VirtualDisplayWindowPolicy.close(access.windows[0].frame, access.windows[1].frame))
        XCTAssertEqual(store.journal?.records.map(\.original), [original, second.frame])
        let restored = await keeper.restore()
        XCTAssertTrue(restored)
        XCTAssertEqual(access.windows.map(\.frame), [original, second.frame])
    }

    func testAppForcedCoincidentFramesRollBackUsingKnownBindings() async {
        let (keeper, access, _) = fixture()
        let firstSettled = CGRect(x: target.minX, y: target.minY, width: 603, height: 700)
        let secondSettled = CGRect(x: target.minX, y: target.minY, width: 587, height: 700)
        XCTAssertTrue(VirtualDisplayWindowPolicy.sameOrigin(firstSettled, secondSettled))
        XCTAssertFalse(VirtualDisplayWindowPolicy.distinctFrames([firstSettled, secondSettled]))
        var second = access.windows[0]
        second.identity.windowID += 1
        second.frame.origin = CGPoint(x: 120, y: 100)
        access.windows.append(second)
        access.forcedVirtualFrame = CGRect(x: target.minX, y: target.minY, width: target.width, height: 700)
        do { try await keeper.moveFrontmostWindows(to: target); XCTFail("coincident result must fall back") } catch {}
        XCTAssertEqual(access.windows.map(\.frame), [original, second.frame])
        XCTAssertFalse(keeper.hasPendingRestore)
    }

    func testIncludeFrontmostWindowsPersistsAdditionsAndDoesNotRemigrateExistingWindows() async throws {
        let (keeper, access, store) = fixture()
        try await keeper.moveFrontmostWindows(to: target)
        access.windows[0].frame.origin.y += 30 // A person can reposition an existing virtual window.
        let retainedFrame = access.windows[0].frame
        var added = access.windows[0]
        added.identity.pid = 11
        added.identity.windowID = 90
        added.frame = CGRect(x: 50, y: 60, width: 800, height: 600)
        access.windows.append(added)
        access.beforeSet = { XCTAssertEqual(store.journal?.records.count, 2) }
        let previousMoves = access.setCount
        try await keeper.includeFrontmostWindows(to: target)
        XCTAssertEqual(access.setCount, previousMoves + 1)
        XCTAssertEqual(access.windows[0].frame, retainedFrame)
        XCTAssertEqual(store.journal?.records.map(\.original), [original, added.frame])
        access.beforeSet = nil
        let restored = await keeper.restore()
        XCTAssertTrue(restored)
        XCTAssertEqual(access.windows.map(\.frame), [original, added.frame])
    }

    func testIncludePersistenceFailureLeavesExistingJournalAndNewWindowUntouched() async throws {
        let (keeper, access, store) = fixture()
        try await keeper.moveFrontmostWindows(to: target)
        var added = access.windows[0]
        added.identity.windowID = 90
        added.frame = original
        access.windows.append(added)
        let frames = access.windows.map(\.frame)
        let count = access.setCount
        store.failWrites = true
        do { try await keeper.includeFrontmostWindows(to: target); XCTFail("persist must finish before enrollment") } catch {}
        XCTAssertEqual(access.setCount, count)
        XCTAssertEqual(access.windows.map(\.frame), frames)
        XCTAssertEqual(store.journal?.records.count, 1)
    }

    func testRefusedPortraitWidthRollsBack() async {
        let (keeper, access, _) = fixture()
        access.minimumWidth = 800
        do { try await keeper.moveFrontmostWindows(to: target); XCTFail("must fail") } catch {}
        XCTAssertEqual(access.windows.first?.frame, original)
    }

    func testResizePreservesOriginalAndRestoreIsIdempotent() async throws {
        let (keeper, access, store) = fixture()
        try await keeper.moveFrontmostWindows(to: target)
        try await keeper.resize(to: CGRect(x: 1800, y: 0, width: 1311, height: 603))
        XCTAssertEqual(store.journal?.records.first?.original, original)
        let result1 = await keeper.restore()
        XCTAssertTrue(result1)
        XCTAssertEqual(access.windows.first?.frame, original)
        let count = access.setCount
        let result2 = await keeper.restore()
        XCTAssertTrue(result2)
        XCTAssertEqual(access.setCount, count)
    }

    func testFailedRestoreRetainsJournalAndRetries() async throws {
        let (keeper, access, store) = fixture()
        try await keeper.moveFrontmostWindows(to: target)
        access.alwaysRefuse = true
        let result3 = await keeper.restore()
        XCTAssertFalse(result3)
        XCTAssertTrue(keeper.hasPendingRestore)
        XCTAssertNotNil(store.journal)
        access.alwaysRefuse = false
        let result4 = await keeper.restore()
        XCTAssertTrue(result4)
        XCTAssertNil(store.journal)
    }

    func testPIDReuseAndAmbiguousIdentityNeverRestore() async throws {
        let (keeper, access, store) = fixture()
        try await keeper.moveFrontmostWindows(to: target)
        access.windows[0].identity.launchTime = 124
        let recovery = VirtualDisplayWindowKeeper(access: access, store: store)
        let result5 = await recovery.recover()
        XCTAssertFalse(result5)
        XCTAssertTrue(recovery.hasPendingRestore)
        access.windows[0].identity.launchTime = 123
        access.windows.append(access.windows[0])
        let result6 = await recovery.recover()
        XCTAssertFalse(result6)
    }

    func testExitedAppAndClosedWindowRetireJournalWithoutAXMove() async throws {
        for appExited in [true, false] {
            let (keeper, access, store) = fixture()
            try await keeper.moveFrontmostWindows(to: target)
            let identity = access.windows[0].identity
            XCTAssertTrue(VirtualDisplayWindowPolicy.isDefinitivelyClosed(identity, processExists: !appExited,
                currentLaunchTime: appExited ? nil : identity.launchTime, allWindowIDs: appExited ? nil : []))
            access.windows = []
            access.closedIdentities = [identity]
            let count = access.setCount
            let restored = await keeper.restore()
            XCTAssertTrue(restored)
            XCTAssertFalse(keeper.hasPendingRestore)
            XCTAssertNil(store.journal)
            XCTAssertEqual(access.setCount, count)
        }
    }

    func testOffSpaceAndUnavailableInventoryRetainJournal() async throws {
        let (keeper, access, store) = fixture()
        try await keeper.moveFrontmostWindows(to: target)
        let identity = access.windows[0].identity
        XCTAssertFalse(VirtualDisplayWindowPolicy.isDefinitivelyClosed(identity, processExists: true,
            currentLaunchTime: identity.launchTime, allWindowIDs: [identity.windowID]))
        XCTAssertFalse(VirtualDisplayWindowPolicy.isDefinitivelyClosed(identity, processExists: true,
            currentLaunchTime: identity.launchTime, allWindowIDs: nil))
        XCTAssertFalse(VirtualDisplayWindowPolicy.isDefinitivelyClosed(identity, processExists: true,
            currentLaunchTime: nil, allWindowIDs: []))
        access.windows = [] // AX/on-screen enumeration cannot see a window on another Space.
        let restored = await keeper.restore()
        XCTAssertFalse(restored)
        XCTAssertTrue(keeper.hasPendingRestore)
        XCTAssertNotNil(store.journal)
    }

    func testPIDReuseRetiresExitedOriginalWithoutMovingReplacementProcess() async throws {
        let (keeper, access, store) = fixture()
        try await keeper.moveFrontmostWindows(to: target)
        let originalIdentity = access.windows[0].identity
        access.windows[0].identity.launchTime += 1
        XCTAssertTrue(VirtualDisplayWindowPolicy.isDefinitivelyClosed(originalIdentity, processExists: true,
            currentLaunchTime: access.windows[0].identity.launchTime, allWindowIDs: [originalIdentity.windowID]))
        access.closedIdentities = [originalIdentity]
        let count = access.setCount
        let replacementFrame = access.windows[0].frame
        let restored = await keeper.restore()
        XCTAssertTrue(restored)
        XCTAssertNil(store.journal)
        XCTAssertEqual(access.setCount, count)
        XCTAssertEqual(access.windows[0].frame, replacementFrame)
    }

    func testUserMovedWindowOnVirtualRestoresButPhysicalMoveIsPreserved() async throws {
        let (keeper, access, _) = fixture()
        try await keeper.moveFrontmostWindows(to: target)
        access.windows[0].frame = CGRect(x: 1830, y: 80, width: 300, height: 400)
        let result7 = await keeper.restore()
        XCTAssertTrue(result7)
        XCTAssertEqual(access.windows[0].frame, original)
        try await keeper.moveFrontmostWindows(to: target)
        let userFrame = CGRect(x: 200, y: 250, width: 400, height: 300)
        access.windows[0].frame = userFrame
        let result8 = await keeper.restore()
        XCTAssertTrue(result8)
        XCTAssertEqual(access.windows[0].frame, userFrame)
    }

    func testCrashBeforeAppliedFrameWriteAndOSRelocationCanRecover() async throws {
        let (keeper, access, store) = fixture()
        try await keeper.moveFrontmostWindows(to: target)
        store.journal?.records[0].applied = nil
        let recovery = VirtualDisplayWindowKeeper(access: access, store: store)
        let result9 = await recovery.recover()
        XCTAssertTrue(result9)
        let next = VirtualDisplayWindowKeeper(access: access, store: store)
        try await next.moveFrontmostWindows(to: target)
        access.windows[0].frame.origin = original.origin
        let result10 = await next.recover()
        XCTAssertTrue(result10)
        XCTAssertEqual(access.windows[0].frame, original)
    }

    func testColdRecoveryRestoresArbitraryPhysicalReflowAndRetainsFailedOriginals() async throws {
        let (keeper, access, store) = fixture()
        try await keeper.moveFrontmostWindows(to: target)
        let reflow = CGRect(x: 270, y: 90, width: 580, height: 860)
        access.windows[0].frame = reflow // Display destruction may choose another physical anchor/size.
        let recovery = VirtualDisplayWindowKeeper(access: access, store: store)
        access.alwaysRefuse = true
        let refused = await recovery.recover()
        XCTAssertFalse(refused)
        XCTAssertTrue(recovery.hasPendingRestore)
        XCTAssertNotNil(store.journal)
        access.alwaysRefuse = false
        let restored = await recovery.recover()
        XCTAssertTrue(restored)
        XCTAssertEqual(access.windows[0].frame, original)
        XCTAssertNil(store.journal)
    }

    func testDisplayPresenceRequiresExactPositiveOrThreeInventoryAbsenceEvidence() {
        func classify(constructed: Bool = true, known: Bool = true, online: Bool? = true,
                      matches: Bool = true, main: Bool = false, mirrored: Bool = false,
                      absent: Bool = false, current: Bool = true) -> SessionVirtualDisplayPresence {
            SessionVirtualDisplayPresencePolicy.classify(constructed: constructed, knownIdentity: known,
                online: online, identityMatches: matches, isMain: main, isMirrored: mirrored,
                absenceConfirmed: absent, operationCurrent: current)
        }
        XCTAssertEqual(classify(), .present)
        XCTAssertEqual(classify(online: false, absent: true), .confirmedRemoved)
        XCTAssertEqual(classify(constructed: false, known: false, online: nil), .neverCreated)
        for result in [classify(known: false), classify(online: nil, absent: true), classify(matches: false),
                       classify(main: true), classify(mirrored: true), classify(online: false),
                       classify(online: false, absent: true, current: false), classify(constructed: false, current: false)] {
            XCTAssertEqual(result, .unknown)
        }
        // Clearing the public ID cannot discard retained identity; reuse cannot adopt a foreign display.
        XCTAssertEqual(classify(online: false, absent: true), .confirmedRemoved)
        XCTAssertEqual(classify(online: true, matches: false, absent: true), .unknown)
    }

    func testRestorationPolicyRequiresKnownTopologyOrNeverCreatedPreparation() {
        for presence in [SessionVirtualDisplayPresence.present, .confirmedRemoved] {
            XCTAssertEqual(VirtualDisplayRestorationPolicy.action(presence: presence,
                physicalTopologyUnchanged: true, journalIsPrepared: false), .restoreOriginals)
            XCTAssertEqual(VirtualDisplayRestorationPolicy.action(presence: presence,
                physicalTopologyUnchanged: false, journalIsPrepared: true), .retainJournal)
        }
        XCTAssertEqual(VirtualDisplayRestorationPolicy.action(presence: .neverCreated,
            physicalTopologyUnchanged: false, journalIsPrepared: true), .restoreOriginals)
        XCTAssertEqual(VirtualDisplayRestorationPolicy.action(presence: .neverCreated,
            physicalTopologyUnchanged: true, journalIsPrepared: false), .retainJournal)
        XCTAssertEqual(VirtualDisplayRestorationPolicy.action(presence: .unknown,
            physicalTopologyUnchanged: true, journalIsPrepared: true), .retainJournal)
    }

    func testSameInstanceConfirmedRemovalRestoresArbitraryReflowAndRetriesRefusal() async throws {
        let (keeper, access, store) = fixture()
        try await keeper.moveFrontmostWindows(to: target)
        access.windows[0].frame = CGRect(x: 270, y: 90, width: 580, height: 860)
        access.alwaysRefuse = true
        let refused = await keeper.restore(after: .confirmedRemoved, physicalTopologyUnchanged: true)
        XCTAssertFalse(refused); XCTAssertTrue(keeper.hasPendingRestore); XCTAssertNotNil(store.journal)
        access.alwaysRefuse = false
        let restored = await keeper.restore(after: .confirmedRemoved, physicalTopologyUnchanged: true)
        XCTAssertTrue(restored); XCTAssertEqual(access.windows[0].frame, original); XCTAssertNil(store.journal)
    }

    func testUnknownOrChangedPhysicalTopologyRetainsJournalWithoutAnyAXWork() async throws {
        for (presence, topology) in [(SessionVirtualDisplayPresence.unknown, true), (.present, false), (.confirmedRemoved, false)] {
            let (keeper, access, store) = fixture()
            try await keeper.moveFrontmostWindows(to: target)
            access.windows[0].frame = CGRect(x: 270, y: 90, width: 580, height: 860)
            let snapshots = access.snapshotCount, writes = access.setCount, persisted = store.writes
            let restored = await keeper.restore(after: presence, physicalTopologyUnchanged: topology)
            XCTAssertFalse(restored); XCTAssertTrue(keeper.hasPendingRestore); XCTAssertNotNil(store.journal)
            XCTAssertEqual(access.snapshotCount, snapshots); XCTAssertEqual(access.setCount, writes)
            XCTAssertEqual(store.writes, persisted)
        }
    }

    func testPresentOwnedDisplayTeardownReturnsEnrolledPhysicalDragToSavedOriginal() async throws {
        let (keeper, access, store) = fixture()
        try await keeper.moveFrontmostWindows(to: target)
        access.windows[0].frame = CGRect(x: 200, y: 250, width: 400, height: 300)
        let restored = await keeper.restore(after: .present, physicalTopologyUnchanged: true)
        XCTAssertTrue(restored); XCTAssertEqual(access.windows[0].frame, original); XCTAssertNil(store.journal)
    }

    func testNeverCreatedAdmitsPreparedOriginalsButCannotConsumeAlreadyMigratedJournal() async throws {
        let (prepared, preparedAccess, preparedStore) = fixture()
        try await prepared.prepareFrontmostWindows()
        preparedAccess.windows[0].frame = CGRect(x: 20, y: 40, width: 500, height: 600)
        let restored = await prepared.restore(after: .neverCreated, physicalTopologyUnchanged: false)
        XCTAssertTrue(restored); XCTAssertEqual(preparedAccess.windows[0].frame, original); XCTAssertNil(preparedStore.journal)
        let (migrated, access, store) = fixture()
        try await migrated.moveFrontmostWindows(to: target)
        let snapshots = access.snapshotCount, writes = access.setCount
        let rejected = await migrated.restore(after: .neverCreated, physicalTopologyUnchanged: true)
        XCTAssertFalse(rejected); XCTAssertTrue(migrated.hasPendingRestore); XCTAssertNotNil(store.journal)
        XCTAssertEqual(access.snapshotCount, snapshots); XCTAssertEqual(access.setCount, writes)
    }

    func testApplyFailureAndPostMoveSaveFailureRestoreOriginalAfterSuccessivePhysicalReflows() async {
        for failsSave in [false, true] {
            let (keeper, access, store) = fixture()
            if failsSave { store.failWriteNumber = 2 }
            access.beforeSet = {
                if access.setCount == 0 {
                    access.forcedNextAppliedFrame = CGRect(x: 270, y: 90, width: 580, height: 860)
                    access.reflowAfterNextSnapshot = CGRect(x: 370, y: 190, width: 490, height: 690)
                }
            }
            do { try await keeper.moveFrontmostWindows(to: target); XCTFail("outside-virtual settled frame must fail") } catch {}
            XCTAssertEqual(access.windows[0].frame, original)
            XCTAssertFalse(keeper.hasPendingRestore); XCTAssertNil(store.journal)
        }
    }

    func testRollbackRefusalAfterArbitraryPhysicalReflowsRetainsOriginalForEvidenceRetry() async {
        let (keeper, access, store) = fixture()
        access.beforeSet = {
            if access.setCount == 0 {
                access.forcedNextAppliedFrame = CGRect(x: 270, y: 90, width: 580, height: 860)
                access.reflowAfterNextSnapshot = CGRect(x: 370, y: 190, width: 490, height: 690)
            } else { access.alwaysRefuse = true }
        }
        do { try await keeper.moveFrontmostWindows(to: target); XCTFail("outside-virtual settled frame must fail") } catch {}
        XCTAssertTrue(keeper.hasPendingRestore); XCTAssertEqual(store.journal?.records.first?.original, original)
        access.beforeSet = nil; access.alwaysRefuse = false
        let restored = await keeper.restore(after: .confirmedRemoved, physicalTopologyUnchanged: true)
        XCTAssertTrue(restored); XCTAssertEqual(access.windows[0].frame, original); XCTAssertNil(store.journal)
    }

    func testIncompleteEnumerationAndStageManagerDoNotConsumeJournal() async throws {
        let (keeper, access, _) = fixture()
        try await keeper.moveFrontmostWindows(to: target)
        access.complete = false
        let result11 = await keeper.restore()
        XCTAssertFalse(result11)
        XCTAssertTrue(keeper.hasPendingRestore)
        access.complete = true
        access.stageManager = true
        let result12 = await keeper.restore()
        XCTAssertFalse(result12)
        XCTAssertTrue(keeper.hasPendingRestore)
    }
}

private final class FakeVirtualJournalStore: VirtualDisplayWindowJournalStore, @unchecked Sendable {
    var journal: VirtualDisplayWindowJournal?
    var failWrites = false
    var failWriteNumber: Int?
    var writes = 0
    var failRemoval = false
    func load() throws -> VirtualDisplayWindowJournal? { journal }
    func save(_ journal: VirtualDisplayWindowJournal) throws {
        writes += 1
        if failWrites || failWriteNumber == writes { throw CocoaError(.fileWriteUnknown) }
        self.journal = journal
    }
    func remove() throws {
        if failRemoval { throw CocoaError(.fileWriteUnknown) }
        journal = nil
    }
}

private final class FakeVirtualWindowAccess: VirtualDisplayWindowAccess, @unchecked Sendable {
    var windows: [VirtualDisplayWindow] = []
    var complete = true
    var stageManager = false
    var closedIdentities: Set<VirtualDisplayWindowIdentity> = []
    var setCount = 0
    var snapshotCount = 0
    var forcedNextAppliedFrame: CGRect?
    var reflowAfterNextSnapshot: CGRect?
    var refuseNext = false
    var refuseWindowIDOnce: UInt32?
    var alwaysRefuse = false
    var minimumWidth: CGFloat = 0
    var forcedVirtualFrame: CGRect?
    var beforeSet: (() -> Void)?
    func snapshot(frontmostOnly: Bool, identities: [VirtualDisplayWindowIdentity], budget: HostAXBudget) -> VirtualDisplayWindowSnapshot {
        snapshotCount += 1
        let result = VirtualDisplayWindowSnapshot(windows: windows, complete: complete, stageManagerEnabled: stageManager, closedIdentities: closedIdentities)
        if let reflow = reflowAfterNextSnapshot, !windows.isEmpty {
            windows[0].frame = reflow; reflowAfterNextSnapshot = nil
        }
        return result
    }
    func setFrame(_ frame: CGRect, identity: VirtualDisplayWindowIdentity, budget: HostAXBudget) -> Bool {
        beforeSet?()
        setCount += 1
        guard let index = windows.firstIndex(where: { $0.identity == identity }) else { return false }
        if alwaysRefuse { return false }
        if refuseNext || refuseWindowIDOnce == identity.windowID {
            refuseNext = false
            refuseWindowIDOnce = nil
            windows[index].frame.size = frame.size // AXSize may succeed while AXPosition fails.
            return false
        }
        windows[index].frame = frame
        if let forcedVirtualFrame, frame.minX >= forcedVirtualFrame.minX { windows[index].frame = forcedVirtualFrame }
        windows[index].frame.size.width = max(frame.width, minimumWidth)
        if let forcedNextAppliedFrame {
            windows[index].frame = forcedNextAppliedFrame; self.forcedNextAppliedFrame = nil
        }
        return true
    }
}
