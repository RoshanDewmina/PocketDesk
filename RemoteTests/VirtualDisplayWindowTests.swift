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

    private func prepareWorkspaceFixture(_ keeper: VirtualDisplayWindowKeeper, _ access: FakeVirtualWindowAccess,
                                         whileCurrent: @escaping @Sendable () -> Bool = { true }) async throws {
        try await keeper.prepareWorkspaceWindows(whileCurrent: whileCurrent)
        try await keeper.bindOwnedDisplay(access.ownedIdentity, whileCurrent: whileCurrent)
    }

    private func restoreLiveFixture(_ keeper: VirtualDisplayWindowKeeper, _ access: FakeVirtualWindowAccess,
                                    _ store: FakeVirtualJournalStore) async -> Bool {
        guard let physical = access.topology?.first?.bounds else { return false }
        try? await keeper.sealWorkspaceForRetirement(to: target, physicalFallbackBounds: physical)
        guard await keeper.restore(after: .present, physicalTopologyUnchanged: true) else { return false }
        if store.journal?.version == 2 {
            guard (try? await keeper.verifyWorkspaceRemoval(to: target, physicalFallbackBounds: physical)) == true else { return false }
            return await keeper.restore(after: .confirmedRemoved, physicalTopologyUnchanged: true)
        }
        return true
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
        try await keeper.bindOwnedDisplay(access.ownedIdentity)
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
        try await keeper.bindOwnedDisplay(access.ownedIdentity)
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
        let restored = await restoreLiveFixture(keeper, access, store)
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

    func testWorkspacePreparationJournalsEveryReachableAppBeforeCreation() async throws {
        let (keeper, access, store) = fixture()
        var other = access.windows[0]
        other.identity.pid = 11; other.identity.windowID = 70
        other.frame = CGRect(x: 100, y: 80, width: 500, height: 400)
        access.windows.append(other)
        try await prepareWorkspaceFixture(keeper, access)
        XCTAssertEqual(access.workspaceSnapshotCount, 1)
        XCTAssertEqual(access.setCount, 0)
        XCTAssertEqual(store.journal?.version, 2)
        XCTAssertEqual(store.journal?.protectedDisplays, access.topology)
        XCTAssertEqual(store.journal?.records.map(\.original), [original, other.frame])
        access.windows[0].frame = CGRect(x: 200, y: 100, width: 700, height: 600)
        try await keeper.moveWorkspaceWindows(to: target)
        XCTAssertEqual(store.journal?.records.map(\.original), [original, other.frame])
        let restored = await restoreLiveFixture(keeper, access, store)
        XCTAssertTrue(restored)
        XCTAssertEqual(access.windows.map(\.frame), [original, other.frame])
    }

    func testWorkspaceSupportsMoreThanEightDistinctWindowsAndRefusesOverflow() async throws {
        let (keeper, access, store) = fixture()
        let first = access.windows[0]
        access.windows = (0..<VirtualDisplayWindowPolicy.maximumWindows).map { index in
            var window = first
            window.identity.windowID += UInt32(index)
            window.frame.origin.x += CGFloat(index * 20)
            return window
        }
        try await prepareWorkspaceFixture(keeper, access)
        try await keeper.moveWorkspaceWindows(to: target)
        XCTAssertEqual(store.journal?.records.count, 32)
        XCTAssertTrue(VirtualDisplayWindowPolicy.distinctFrames(access.windows.map(\.frame)))
        let count = access.setCount
        var overflow = first; overflow.identity.windowID = 200
        access.windows.append(overflow)
        do { try await keeper.refreshWorkspace(to: target, physicalFallbackBounds: access.topology![0].bounds); XCTFail("bounded enrollment") } catch {}
        XCTAssertEqual(access.setCount, count)
        XCTAssertEqual(store.journal?.records.count, 32)
    }

    func testNewWindowBornOnVirtualGetsPersistedChosenPhysicalReturn() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access)
        try await keeper.moveWorkspaceWindows(to: target)
        let firstFrame = access.windows[0].frame
        var born = access.windows[0]
        born.identity.pid = 12; born.identity.windowID = 80
        born.frame = CGRect(x: 1830, y: 60, width: 400, height: 300)
        access.windows.append(born)
        let physical = access.topology![0].bounds
        let returnFrame = VirtualDisplayWindowPolicy.enrollmentReturnFrame(born.frame, virtualBounds: target, physicalBounds: physical, index: 1)
        access.beforeSet = { XCTAssertEqual(store.journal?.records.last?.original, returnFrame) }
        try await keeper.refreshWorkspace(to: target, physicalFallbackBounds: physical)
        XCTAssertEqual(access.windows[0].frame, firstFrame)
        XCTAssertTrue(physical.contains(returnFrame))
        access.beforeSet = nil
        let restored = await keeper.restore(after: .confirmedRemoved, physicalTopologyUnchanged: true)
        XCTAssertTrue(restored)
        XCTAssertEqual(access.windows.map(\.frame), [original, returnFrame])
    }

    func testBornVirtualWindowWithoutPhysicalAnchorCannotEnroll() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access)
        try await keeper.moveWorkspaceWindows(to: target)
        var born = access.windows[0]; born.identity.windowID += 1
        access.windows.append(born)
        let writes = access.setCount
        do { try await keeper.refreshWorkspace(to: target, physicalFallbackBounds: nil); XCTFail("return anchor is required") } catch {}
        XCTAssertEqual(access.setCount, writes)
        XCTAssertEqual(store.journal?.records.count, 1)
    }

    func testColdKeeperCannotActivatePreparedJournalOrEnrollNewWindows() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access)
        let cold = VirtualDisplayWindowKeeper(access: access, store: store)
        do { try await cold.moveWorkspaceWindows(to: target); XCTFail("prepared session authority was not restored") } catch {}
        do { try await cold.refreshWorkspace(to: target, physicalFallbackBounds: access.topology![0].bounds); XCTFail("recovery only") } catch {}
        XCTAssertEqual(access.setCount, 0)
        XCTAssertTrue(cold.hasPendingRestore)
    }

    func testRevokedAuthorityPreventsSnapshotAndJournalCreation() async {
        let (keeper, access, store) = fixture()
        let authority = VirtualDisplayWindowOperationAuthority(); authority.revoke()
        do { try await keeper.prepareWorkspaceWindows(whileCurrent: { authority.isCurrent }); XCTFail("stale authority") } catch {}
        XCTAssertEqual(access.snapshotCount, 0)
        XCTAssertEqual(access.workspaceSnapshotCount, 0)
        XCTAssertEqual(access.setCount, 0)
        XCTAssertNil(store.journal)
    }

    func testRevocationAfterFirstMutationRetainsJournalAndFencesLaterWrites() async throws {
        let (keeper, access, store) = fixture()
        var other = access.windows[0]; other.identity.windowID += 1
        other.frame.origin.x += 100; access.windows.append(other)
        let authority = VirtualDisplayWindowOperationAuthority()
        try await prepareWorkspaceFixture(keeper, access, whileCurrent: { authority.isCurrent })
        access.beforeSet = { authority.revoke() }
        do { try await keeper.moveWorkspaceWindows(to: target, whileCurrent: { authority.isCurrent }); XCTFail("stale mutation") } catch {}
        XCTAssertEqual(access.setCount, 1) // Fake revokes during the first primitive write.
        XCTAssertEqual(store.journal?.records.map(\.original), [original, other.frame])
        XCTAssertTrue(keeper.hasPendingRestore)
        let count = access.setCount
        do { try await keeper.refreshWorkspace(to: target, physicalFallbackBounds: access.topology![0].bounds); XCTFail("retired authority cannot reactivate") } catch {}
        XCTAssertEqual(access.setCount, count)
        access.beforeSet = nil
        let restored = await restoreLiveFixture(keeper, access, store)
        XCTAssertTrue(restored)
        XCTAssertEqual(access.windows.map(\.frame), [original, other.frame])
    }

    func testRevocationAfterEnrollmentSaveLeavesNewWindowUnmovedAndReceiptIntact() async throws {
        let (keeper, access, store) = fixture()
        let authority = VirtualDisplayWindowOperationAuthority()
        try await prepareWorkspaceFixture(keeper, access, whileCurrent: { authority.isCurrent })
        try await keeper.moveWorkspaceWindows(to: target, whileCurrent: { authority.isCurrent })
        var added = access.windows[0]; added.identity.windowID += 1; added.frame = original
        access.windows.append(added)
        let writes = access.setCount
        store.afterSave = { authority.revoke() }
        do { try await keeper.refreshWorkspace(to: target, physicalFallbackBounds: access.topology![0].bounds, whileCurrent: { authority.isCurrent }); XCTFail("retired after persist") } catch {}
        XCTAssertEqual(access.setCount, writes)
        XCTAssertEqual(access.windows[1].frame, original)
        XCTAssertEqual(store.journal?.records.count, 2)
        XCTAssertTrue(keeper.hasPendingRestore)
    }

    func testRefreshRetiresOnlyConfirmedClosedAndRetainsOffSpaceOriginals() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access)
        try await keeper.moveWorkspaceWindows(to: target)
        let missing = access.windows.removeFirst()
        var added = missing; added.identity.windowID += 1; added.frame = original
        access.windows = [added]
        try await keeper.refreshWorkspace(to: target, physicalFallbackBounds: access.topology![0].bounds)
        XCTAssertEqual(store.journal?.records.map(\.identity), [missing.identity, added.identity])
        access.closedIdentities = [missing.identity]
        try await keeper.refreshWorkspace(to: target, physicalFallbackBounds: access.topology![0].bounds)
        XCTAssertEqual(store.journal?.records.map(\.identity), [added.identity])
        XCTAssertEqual(store.journal?.records.first?.original, original)
    }

    func testResizeRetiresClosedButRefusesMissingSurvivorWithoutMutation() async throws {
        let (keeper, access, store) = fixture()
        var other = access.windows[0]; other.identity.windowID += 1
        other.frame.origin.x += 100; access.windows.append(other)
        try await prepareWorkspaceFixture(keeper, access)
        try await keeper.moveWorkspaceWindows(to: target)
        let removed = access.windows.removeLast()
        let count = access.setCount
        let landscape = CGRect(x: 1800, y: 0, width: 1311, height: 603)
        try await keeper.sealWorkspaceForResize(to: target, physicalFallbackBounds: access.topology![0].bounds)
        do { try await keeper.resize(to: landscape); XCTFail("off-Space survivor is pending") } catch {}
        XCTAssertEqual(access.setCount, count)
        XCTAssertEqual(store.journal?.records.count, 2)
        access.closedIdentities = [removed.identity]
        try await keeper.sealWorkspaceForResize(to: target, physicalFallbackBounds: access.topology![0].bounds)
        try await keeper.resize(to: landscape)
        XCTAssertEqual(store.journal?.records.count, 1)
        XCTAssertEqual(store.journal?.records.first?.original, original)
    }

    func testV2ColdRecoveryRequiresExactProtectedTopologyBeforeAnyAX() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access)
        try await keeper.moveWorkspaceWindows(to: target)
        let saved = access.topology!
        let cold = VirtualDisplayWindowKeeper(access: access, store: store)
        for change in 0..<7 {
            access.topology = saved
            switch change {
            case 0: access.topology = nil
            case 1: access.topology = []
            case 2: access.topology![0].uuid = UUID()
            case 3: access.topology![0].bounds.origin.x += 1
            case 4: access.topology![0].pixelWidth += 1
            case 5: access.topology![0].modeID += 1
            default: access.topology![0].rotation = 90
            }
            let snapshots = access.snapshotCount, moves = access.setCount
            let restored = await cold.recover()
            XCTAssertFalse(restored)
            XCTAssertEqual(access.snapshotCount, snapshots)
            XCTAssertEqual(access.setCount, moves)
            XCTAssertNotNil(store.journal)
        }
        access.topology = saved
        let restored = await cold.recover()
        XCTAssertTrue(restored)
        XCTAssertEqual(access.windows[0].frame, original)
        XCTAssertNil(store.journal)
    }

    func testV2MissingOrMalformedTopologyNeverConsumesJournal() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access)
        let saved = store.journal!
        let cases: [[VirtualDisplayProtectedDisplay]?] = [nil, [], [access.topology![0], access.topology![0]]]
        for topology in cases {
            store.journal = saved; store.journal!.protectedDisplays = topology
            let cold = VirtualDisplayWindowKeeper(access: access, store: store)
            let count = access.snapshotCount
            let restored = await cold.recover()
            XCTAssertFalse(restored)
            XCTAssertTrue(cold.hasPendingRestore)
            XCTAssertNotNil(store.journal)
            XCTAssertEqual(access.snapshotCount, count)
        }
    }

    func testWorkspacePreparationRejectsUnknownTopologyBeforeAnyMutation() async {
        let (keeper, access, store) = fixture()
        access.topology = nil
        do { try await keeper.prepareWorkspaceWindows(); XCTFail("protected topology required") } catch {}
        XCTAssertNil(store.journal)
        XCTAssertEqual(access.setCount, 0)
    }

    func testExactOriginalRestoreDoesNotConsumeOnePointRefusal() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access)
        try await keeper.moveWorkspaceWindows(to: target)
        var almost = original; almost.origin.x += 1
        access.windows[0].frame = almost
        access.forcedNextAppliedFrame = almost
        let refused = await restoreLiveFixture(keeper, access, store)
        XCTAssertFalse(refused)
        XCTAssertNotNil(store.journal)
        XCTAssertTrue(keeper.hasPendingRestore)
        let restored = await restoreLiveFixture(keeper, access, store)
        XCTAssertTrue(restored)
        XCTAssertEqual(access.windows[0].frame, original)
    }

    func testFailedRestoreRetiresEnrollmentEvenWhenReceiptRemainsPending() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access)
        try await keeper.moveWorkspaceWindows(to: target)
        access.alwaysRefuse = true
        let restored = await restoreLiveFixture(keeper, access, store)
        XCTAssertFalse(restored)
        let count = access.setCount
        do { try await keeper.refreshWorkspace(to: target, physicalFallbackBounds: access.topology![0].bounds); XCTFail("cleanup must finish") } catch {}
        XCTAssertEqual(access.setCount, count)
        XCTAssertNotNil(store.journal)
    }

    func testProtectedTopologyAllowsOnlyExactOwnedWorkspaceAddition() {
        let saved = FakeVirtualWindowAccess().topology!
        var extra = saved[0]
        extra.uuid = UUID(); extra.main = false; extra.bounds = target
        let valid = saved + [extra]
        XCTAssertTrue(VirtualDisplayWindowPolicy.workspaceTopologyMatches(saved, current: valid, virtualBounds: target, ownedDisplayUUID: extra.uuid))
        XCTAssertFalse(VirtualDisplayWindowPolicy.workspaceTopologyMatches(saved, current: saved, virtualBounds: target, ownedDisplayUUID: extra.uuid))
        XCTAssertFalse(VirtualDisplayWindowPolicy.workspaceTopologyMatches(saved, current: valid, virtualBounds: original, ownedDisplayUUID: extra.uuid))
        var changed = valid; changed[0].modeID += 1
        XCTAssertFalse(VirtualDisplayWindowPolicy.workspaceTopologyMatches(saved, current: changed, virtualBounds: target, ownedDisplayUUID: extra.uuid))
        changed = valid; changed[1].mirrored = true
        XCTAssertFalse(VirtualDisplayWindowPolicy.workspaceTopologyMatches(saved, current: changed, virtualBounds: target, ownedDisplayUUID: extra.uuid))
        changed = valid; changed[1].uuid = saved[0].uuid
        XCTAssertFalse(VirtualDisplayWindowPolicy.workspaceTopologyMatches(saved, current: changed, virtualBounds: target, ownedDisplayUUID: extra.uuid))
    }

    func testPhysicalChangeBetweenPreparationAndMoveRetainsPreparedOriginalsWithoutAX() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access)
        access.topology![0].bounds.origin.x += 100
        let snapshots = access.snapshotCount
        do { try await keeper.moveWorkspaceWindows(to: target); XCTFail("adapter baseline cannot replace original topology") } catch {}
        XCTAssertEqual(access.setCount, 0)
        XCTAssertEqual(access.snapshotCount, snapshots)
        XCTAssertEqual(store.journal?.records.first?.original, original)
        XCTAssertTrue(store.journal?.isPrepared == true)
        let restored = await keeper.restore(after: .neverCreated, physicalTopologyUnchanged: true)
        XCTAssertFalse(restored)
        XCTAssertEqual(access.setCount, 0)
        XCTAssertNotNil(store.journal)
    }

    func testTopologyChangeDuringMutationStopsLaterWritesAndPreservesWholeReceipt() async throws {
        let (keeper, access, store) = fixture()
        var second = access.windows[0]; second.identity.windowID += 1; second.frame.origin.x += 100
        access.windows.append(second)
        try await prepareWorkspaceFixture(keeper, access)
        access.beforeSet = { access.topology![0].modeID += 1 }
        do { try await keeper.moveWorkspaceWindows(to: target); XCTFail("physical mode changed during AX") } catch {}
        XCTAssertEqual(access.setCount, 1)
        XCTAssertEqual(store.journal?.records.map(\.original), [original, second.frame])
        XCTAssertTrue(keeper.hasPendingRestore)
        access.beforeSet = nil
        let restored = await restoreLiveFixture(keeper, access, store)
        XCTAssertFalse(restored) // Independently checks the older keeper topology, even if caller says true.
        XCTAssertEqual(access.setCount, 1)
    }
    func testRetirementSealPersistsLateWindowWithoutMovingThenKeepsReceiptUntilFinalInventory() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access); try await keeper.moveWorkspaceWindows(to: target)
        var late = access.windows[0]; late.identity.windowID += 1
        late.frame = CGRect(x: 1830, y: 100, width: 400, height: 300)
        access.windows.append(late)
        let count = access.setCount, physical = access.topology![0].bounds
        try await keeper.sealWorkspaceForRetirement(to: target, physicalFallbackBounds: physical)
        XCTAssertEqual(access.setCount, count)
        XCTAssertEqual(store.journal?.records.count, 2)
        let chosen = store.journal!.records[1].original
        XCTAssertTrue(physical.contains(chosen))
        let restored = await keeper.restore(after: .present, physicalTopologyUnchanged: true)
        XCTAssertTrue(restored); XCTAssertNotNil(store.journal); XCTAssertTrue(keeper.hasPendingRestore)
        XCTAssertEqual(access.windows.map(\.frame), [original, chosen])
        let ready = try await keeper.verifyWorkspaceRemoval(to: target, physicalFallbackBounds: physical)
        XCTAssertTrue(ready); XCTAssertNotNil(store.journal); XCTAssertTrue(keeper.hasPendingRestore)
        let removed = await keeper.restore(after: .confirmedRemoved, physicalTopologyUnchanged: true)
        XCTAssertTrue(removed); XCTAssertNil(store.journal); XCTAssertFalse(keeper.hasPendingRestore)
    }

    func testResizeSealJournalsLateWindowBeforeAnyResizeMutation() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access); try await keeper.moveWorkspaceWindows(to: target)
        var late = access.windows[0]; late.identity.windowID += 1
        late.frame = CGRect(x: 1840, y: 100, width: 400, height: 300); access.windows.append(late)
        let count = access.setCount, physical = access.topology![0].bounds
        try await keeper.sealWorkspaceForResize(to: target, physicalFallbackBounds: physical)
        XCTAssertEqual(access.setCount, count)
        XCTAssertEqual(store.journal?.records.count, 2)
        let chosen = store.journal!.records[1].original
        try await keeper.resize(to: CGRect(x: 1800, y: 0, width: 1311, height: 603))
        XCTAssertEqual(store.journal?.records[1].original, chosen)
        XCTAssertEqual(access.setCount, count + 2)
    }

    func testRetirementOverflowBlocksRestorationAndKeepsJournal() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access); try await keeper.moveWorkspaceWindows(to: target)
        let first = access.windows[0]
        for index in 1...32 {
            var late = first; late.identity.windowID += UInt32(index)
            late.frame.origin.x += CGFloat(index * 5); access.windows.append(late)
        }
        let count = access.setCount
        do { try await keeper.sealWorkspaceForRetirement(to: target, physicalFallbackBounds: access.topology![0].bounds); XCTFail("overflow retains display") } catch {}
        let restored = await keeper.restore(after: .present, physicalTopologyUnchanged: true)
        XCTAssertFalse(restored); XCTAssertEqual(access.setCount, count)
        XCTAssertEqual(store.journal?.records.count, 1); XCTAssertTrue(keeper.hasPendingRestore)
    }

    func testIncompleteStageManagerAndChangedTopologyCannotSealOrRestore() async throws {
        for failure in 0..<3 {
            let (keeper, access, store) = fixture()
            try await prepareWorkspaceFixture(keeper, access); try await keeper.moveWorkspaceWindows(to: target)
            let count = access.setCount
            if failure == 0 { access.complete = false }
            if failure == 1 { access.stageManager = true }
            if failure == 2 { access.topology![0].modeID += 1 }
            do { try await keeper.sealWorkspaceForRetirement(to: target, physicalFallbackBounds: access.topology![0].bounds); XCTFail("unproved inventory") } catch {}
            let restored = await keeper.restore(after: .present, physicalTopologyUnchanged: true)
            XCTAssertFalse(restored); XCTAssertEqual(access.setCount, count)
            XCTAssertNotNil(store.journal); XCTAssertTrue(keeper.hasPendingRestore)
        }
    }

    func testPostRestorationInventoryJournalsWindowBornDuringAXAndRequiresAnotherPass() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access); try await keeper.moveWorkspaceWindows(to: target)
        let physical = access.topology![0].bounds
        try await keeper.sealWorkspaceForRetirement(to: target, physicalFallbackBounds: physical)
        access.beforeSet = {
            var late = access.windows[0]; late.identity.windowID += 1
            late.frame = CGRect(x: 1850, y: 100, width: 400, height: 300)
            access.windows.append(late); access.beforeSet = nil
        }
        let first = await keeper.restore(after: .present, physicalTopologyUnchanged: true)
        XCTAssertFalse(first); XCTAssertEqual(store.journal?.records.count, 2)
        let chosen = store.journal!.records[1].original
        XCTAssertTrue(physical.contains(chosen)); XCTAssertTrue(keeper.hasPendingRestore)
        let second = await keeper.restore(after: .present, physicalTopologyUnchanged: true)
        XCTAssertTrue(second); XCTAssertEqual(access.windows[1].frame, chosen)
        let ready = try await keeper.verifyWorkspaceRemoval(to: target, physicalFallbackBounds: physical)
        XCTAssertTrue(ready); XCTAssertNotNil(store.journal)
        let removed = await keeper.restore(after: .confirmedRemoved, physicalTopologyUnchanged: true)
        XCTAssertTrue(removed); XCTAssertNil(store.journal)
    }

    func testFinalRemovalInventoryPersistsNewOwnedWindowAndBlocksRemoval() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access); try await keeper.moveWorkspaceWindows(to: target)
        let physical = access.topology![0].bounds
        try await keeper.sealWorkspaceForRetirement(to: target, physicalFallbackBounds: physical)
        let restored = await keeper.restore(after: .present, physicalTopologyUnchanged: true)
        XCTAssertTrue(restored)
        var late = access.windows[0]; late.identity.windowID += 1
        late.frame = CGRect(x: 1850, y: 100, width: 400, height: 300); access.windows.append(late)
        let count = access.setCount
        let ready = try await keeper.verifyWorkspaceRemoval(to: target, physicalFallbackBounds: physical)
        XCTAssertFalse(ready); XCTAssertEqual(access.setCount, count)
        XCTAssertEqual(store.journal?.records.count, 2); XCTAssertTrue(keeper.hasPendingRestore)
        let retried = await keeper.restore(after: .present, physicalTopologyUnchanged: true)
        XCTAssertTrue(retried)
        let final = try await keeper.verifyWorkspaceRemoval(to: target, physicalFallbackBounds: physical)
        XCTAssertTrue(final); XCTAssertNotNil(store.journal)
        let removed = await keeper.restore(after: .confirmedRemoved, physicalTopologyUnchanged: true)
        XCTAssertTrue(removed); XCTAssertNil(store.journal)
    }

    func testV2PresentRestorationWithoutFreshSealCannotMutateOrConsumeJournal() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access); try await keeper.moveWorkspaceWindows(to: target)
        let count = access.setCount
        let restored = await keeper.restore(after: .present, physicalTopologyUnchanged: true)
        XCTAssertFalse(restored); XCTAssertEqual(access.setCount, count)
        XCTAssertNotNil(store.journal)
    }

    func testProductionMatcherRejectsCoincidentWindowsEvenWithOneUniquelyAttributedWindow() {
        let unique = CGRect(x: 240, y: 180, width: 500, height: 400)
        let publicWindows: [VirtualDisplayWorkspaceInventoryPolicy.PublicWindow] = [
            .init(windowID: 45, frame: original), .init(windowID: 46, frame: original), .init(windowID: 47, frame: unique)
        ]
        let decisions = [original, original, unique].map {
            VirtualDisplayWorkspaceInventoryPolicy.attribute(frame: $0, onScreen: publicWindows, allSpaces: publicWindows)
        }
        XCTAssertEqual(decisions, [.unresolved, .unresolved, .matched(47)])
        let snapshot = VirtualDisplayWindowSnapshot(windows: [
            .init(identity: .init(pid: 10, launchTime: 123, windowID: 47, axIdentifier: nil), frame: unique)
        ], complete: !decisions.contains(.unresolved), stageManagerEnabled: false)
        XCTAssertFalse(snapshot.complete)
        XCTAssertFalse(VirtualDisplayWindowPolicy.validEnrollment(snapshot))
        // Previously established unique AX membership can still identify coincident live frames.
        XCTAssertEqual(VirtualDisplayWorkspaceInventoryPolicy.attribute(frame: original, onScreen: publicWindows,
            allSpaces: publicWindows, provenID: 45), .matched(45))
    }

    func testProductionMatcherRequiresPositiveUniqueAllSpaceProofBeforeExclusion() {
        let offSpace: [VirtualDisplayWorkspaceInventoryPolicy.PublicWindow] = [.init(windowID: 45, frame: original)]
        XCTAssertEqual(VirtualDisplayWorkspaceInventoryPolicy.attribute(frame: original, onScreen: [], allSpaces: offSpace), .outOfScope)
        XCTAssertEqual(VirtualDisplayWorkspaceInventoryPolicy.attribute(frame: original, onScreen: [], allSpaces: nil), .unresolved)
        XCTAssertEqual(VirtualDisplayWorkspaceInventoryPolicy.attribute(frame: original, onScreen: [], allSpaces: []), .unresolved)
        XCTAssertEqual(VirtualDisplayWorkspaceInventoryPolicy.attribute(frame: original, onScreen: [],
            allSpaces: offSpace + [.init(windowID: 46, frame: original)]), .unresolved)
        let staleVisible: [VirtualDisplayWorkspaceInventoryPolicy.PublicWindow] = [.init(windowID: 45, frame: target)]
        XCTAssertEqual(VirtualDisplayWorkspaceInventoryPolicy.attribute(frame: original, onScreen: staleVisible, allSpaces: offSpace), .unresolved)
        XCTAssertEqual(VirtualDisplayWorkspaceInventoryPolicy.attribute(frame: original, onScreen: [], allSpaces: offSpace, provenID: 45), .outOfScope)
        XCTAssertEqual(VirtualDisplayWorkspaceInventoryPolicy.attribute(frame: original, onScreen: [], allSpaces: [], provenID: 45), .unresolved)
        XCTAssertEqual(VirtualDisplayWorkspaceInventoryPolicy.attribute(frame: original, onScreen: offSpace,
            allSpaces: offSpace + [.init(windowID: 46, frame: original)]), .unresolved) // Visible/off-Space twins.
        XCTAssertEqual(VirtualDisplayWorkspaceInventoryPolicy.attribute(frame: original, onScreen: offSpace, allSpaces: nil), .unresolved)
    }

    func testProductionEligibilitySeparatesPositiveExclusionFromMissingOrRefusedMetadata() {
        typealias Policy = VirtualDisplayWorkspaceInventoryPolicy
        func classify(standard: Bool? = true, minimized: Bool? = false, fullscreen: Bool? = false,
                      frame: CGRect? = nil, size: Bool? = true, position: Bool? = true) -> Policy.Eligibility {
            Policy.eligibility(standard: standard, minimized: minimized, fullscreen: fullscreen,
                               frame: frame, sizeSettable: size, positionSettable: position)
        }
        XCTAssertEqual(classify(frame: original), .eligible)
        XCTAssertEqual(classify(standard: false), .outOfScope)
        XCTAssertEqual(classify(standard: nil, minimized: true), .outOfScope)
        XCTAssertEqual(classify(standard: nil, fullscreen: true), .outOfScope)
        XCTAssertEqual(classify(standard: nil, frame: original), .unresolved)
        XCTAssertEqual(classify(minimized: nil, frame: original), .unresolved)
        XCTAssertEqual(classify(fullscreen: nil, frame: original), .unresolved)
        XCTAssertEqual(classify(), .unresolved)
        XCTAssertEqual(classify(frame: .zero), .unresolved)
        XCTAssertEqual(classify(frame: original, size: nil), .unresolved) // AX API error.
        XCTAssertEqual(classify(frame: original, size: false), .unresolved) // Known refusal cannot be abandoned on owned display.
        XCTAssertEqual(classify(frame: original, position: nil), .unresolved)
        XCTAssertEqual(classify(frame: original, position: false), .unresolved)
    }

    func testProductionClosureInventoryNeverTurnsMalformedRowsIntoClosedWindowProof() {
        typealias Row = VirtualDisplayWorkspaceInventoryPolicy.PublicIdentityRow
        let valid = [Row(pid: 10, windowID: 45), Row(pid: 10, windowID: 46), Row(pid: 11, windowID: 70)]
        XCTAssertEqual(VirtualDisplayWorkspaceInventoryPolicy.closureIDs(valid, pid: 10), [45, 46])
        XCTAssertNil(VirtualDisplayWorkspaceInventoryPolicy.closureIDs(valid + [Row(pid: nil, windowID: 80)], pid: 10))
        XCTAssertNil(VirtualDisplayWorkspaceInventoryPolicy.closureIDs(valid + [Row(pid: 10, windowID: nil)], pid: 10))
        XCTAssertNil(VirtualDisplayWorkspaceInventoryPolicy.closureIDs(valid + [Row(pid: 10, windowID: 0)], pid: 10))
        XCTAssertNil(VirtualDisplayWorkspaceInventoryPolicy.closureIDs(valid + [Row(pid: 10, windowID: 45)], pid: 10))
        XCTAssertEqual(VirtualDisplayWorkspaceInventoryPolicy.closureIDs(valid + [Row(pid: 11, windowID: nil)], pid: 10), [45, 46])
        let identity = VirtualDisplayWindowIdentity(pid: 10, launchTime: 123, windowID: 45, axIdentifier: nil)
        let malformed = VirtualDisplayWorkspaceInventoryPolicy.closureIDs([Row(pid: 10, windowID: nil)], pid: 10)
        XCTAssertFalse(VirtualDisplayWindowPolicy.isDefinitivelyClosed(identity, processExists: true, currentLaunchTime: 123, allWindowIDs: malformed))
    }

    func testProductionInventoryCannotCertifyAVisibleWindowOmittedFromAXList() {
        let visible: [VirtualDisplayWorkspaceInventoryPolicy.PublicWindow] = [
            .init(windowID: 45, frame: original), .init(windowID: 46, frame: target)
        ]
        XCTAssertFalse(VirtualDisplayWorkspaceInventoryPolicy.allVisibleAccounted(visible, accountedIDs: []))
        XCTAssertFalse(VirtualDisplayWorkspaceInventoryPolicy.allVisibleAccounted(visible, accountedIDs: [45]))
        XCTAssertTrue(VirtualDisplayWorkspaceInventoryPolicy.allVisibleAccounted(visible, accountedIDs: [45, 46]))
    }

    func testPublicOwnedIdentityMatcherRejectsEveryChangedIdentityAndUnsafeDisplayState() {
        let proof = FakeVirtualWindowAccess().ownedIdentity
        func matches(_ observed: VirtualDisplayWindowOwnedDisplayIdentity, online: Bool = true,
                     main: Bool = false, mirrored: Bool = false, bounds: CGRect? = nil) -> Bool {
            VirtualDisplayWindowPolicy.ownedDisplayMatches(proof, displayID: observed.displayID,
                uuid: observed.uuid, vendor: observed.vendor, product: observed.product, serial: observed.serial,
                online: online, main: main, mirrored: mirrored, bounds: bounds ?? target, expectedBounds: target)
        }
        XCTAssertTrue(matches(proof))
        for field in 0..<5 {
            var foreign = proof
            switch field {
            case 0: foreign.displayID += 1
            case 1: foreign.uuid = UUID()
            case 2: foreign.vendor += 1
            case 3: foreign.product += 1
            default: foreign.serial += 1
            }
            XCTAssertFalse(matches(foreign))
        }
        XCTAssertFalse(matches(proof, online: false))
        XCTAssertFalse(matches(proof, main: true))
        XCTAssertFalse(matches(proof, mirrored: true))
        var changedBounds = target; changedBounds.origin.x += 1
        XCTAssertFalse(matches(proof, bounds: changedBounds))
        let saved = FakeVirtualWindowAccess().topology!
        var foreign = saved[0]; foreign.uuid = UUID(); foreign.bounds = target; foreign.main = false
        XCTAssertFalse(VirtualDisplayWindowPolicy.workspaceTopologyMatches(saved, current: saved + [foreign],
            virtualBounds: target, ownedDisplayUUID: proof.uuid))
    }

    func testLocalCleanupBindingSurvivesEnrollmentRetirementButCannotRenewOrAdoptLoadedReceipt() async throws {
        let (keeper, access, store) = fixture()
        try await keeper.prepareWorkspaceWindows() // Adapter creation may precede first binding.
        let proof = access.ownedIdentity
        do { try await keeper.moveWorkspaceWindows(to: target); XCTFail("unbound movement") } catch {}
        XCTAssertEqual(access.setCount, 0)
        let cold = VirtualDisplayWindowKeeper(access: access, store: store)
        do { try await cold.bindOwnedDisplay(proof); XCTFail("loaded journal cannot adopt a lease") } catch {}
        // The failed migration retired enrollment, but this keeper still owns the prepared receipt.
        try await keeper.bindOwnedDisplay(proof)
        try await keeper.sealWorkspaceForRetirement(to: target, physicalFallbackBounds: access.topology![0].bounds)
        try await keeper.bindOwnedDisplay(proof)
        var renewed = proof; renewed.leaseGeneration = UUID()
        do { try await keeper.bindOwnedDisplay(renewed); XCTFail("same public display cannot renew its lease generation") } catch {}
        let restored = await keeper.restore(after: .present, physicalTopologyUnchanged: true)
        XCTAssertTrue(restored)
        XCTAssertEqual(access.setCount, 0)
        XCTAssertEqual(store.journal?.records.first?.original, original)
        XCTAssertTrue(keeper.hasPendingRestore)
    }

    private func assertSameBoundsForeignReplacementBlocks(_ operation: Int) async throws {
        for replaceUUID in [true, false] {
            let (keeper, access, store) = fixture()
            try await prepareWorkspaceFixture(keeper, access)
            if operation != 0 { try await keeper.moveWorkspaceWindows(to: target) }
            let physical = access.topology![0].bounds
            if operation == 1 { try await keeper.sealWorkspaceForResize(to: target, physicalFallbackBounds: physical) }
            if operation >= 2 { try await keeper.sealWorkspaceForRetirement(to: target, physicalFallbackBounds: physical) }
            if operation == 3 {
                let restored = await keeper.restore(after: .present, physicalTopologyUnchanged: true)
                XCTAssertTrue(restored)
            }
            let writes = access.setCount, snapshots = access.snapshotCount
            let frames = access.windows.map(\.frame)
            if replaceUUID { access.ownedIdentity.uuid = UUID() } else { access.ownedIdentity.serial += 1 }
            switch operation {
            case 0:
                do { try await keeper.moveWorkspaceWindows(to: target); XCTFail("foreign migration") } catch {}
            case 1:
                var resized = target; resized.size.width += 10
                do { try await keeper.resize(to: resized); XCTFail("foreign resize") } catch {}
            case 2:
                let restored = await keeper.restore(after: .present, physicalTopologyUnchanged: true)
                XCTAssertFalse(restored)
            default:
                do {
                    let verified = try await keeper.verifyWorkspaceRemoval(to: target, physicalFallbackBounds: physical)
                    XCTAssertFalse(verified)
                } catch {}
            }
            XCTAssertEqual(access.setCount, writes)
            XCTAssertEqual(access.snapshotCount, snapshots)
            XCTAssertEqual(access.windows.map(\.frame), frames)
            XCTAssertEqual(store.journal?.records.first?.original, original)
            XCTAssertTrue(keeper.hasPendingRestore)
        }
    }

    func testSameBoundsForeignUUIDOrSerialBlocksMigrationWithoutAX() async throws {
        try await assertSameBoundsForeignReplacementBlocks(0)
    }
    func testSameBoundsForeignUUIDOrSerialBlocksResizeAfterSuccessfulSealWithoutAX() async throws {
        try await assertSameBoundsForeignReplacementBlocks(1)
    }
    func testSameBoundsForeignUUIDOrSerialBlocksRestorationAfterSuccessfulSealWithoutAX() async throws {
        try await assertSameBoundsForeignReplacementBlocks(2)
    }
    func testSameBoundsForeignUUIDOrSerialBlocksFinalVerificationAndRetainsReceipt() async throws {
        try await assertSameBoundsForeignReplacementBlocks(3)
    }

    func testVerifiedRemovalKeepsReceiptAcrossStopFailureAndAllowsCleanupRetry() async throws {
        let (keeper, access, store) = fixture()
        try await prepareWorkspaceFixture(keeper, access); try await keeper.moveWorkspaceWindows(to: target)
        let physical = access.topology![0].bounds
        try await keeper.sealWorkspaceForRetirement(to: target, physicalFallbackBounds: physical)
        let restored = await keeper.restore(after: .present, physicalTopologyUnchanged: true)
        XCTAssertTrue(restored)
        let ready = try await keeper.verifyWorkspaceRemoval(to: target, physicalFallbackBounds: physical)
        XCTAssertTrue(ready); XCTAssertNotNil(store.journal); XCTAssertTrue(keeper.hasPendingRestore)
        let session = store.journal!.session, count = access.setCount
        // The adapter failed to remove its owned display: another seal/restore remains possible.
        try await keeper.sealWorkspaceForRetirement(to: target, physicalFallbackBounds: physical)
        let retried = await keeper.restore(after: .present, physicalTopologyUnchanged: true)
        XCTAssertTrue(retried); XCTAssertEqual(store.journal?.session, session)
        XCTAssertEqual(store.journal?.records.first?.original, original)
        XCTAssertEqual(access.setCount, count)
        let removed = await keeper.restore(after: .confirmedRemoved, physicalTopologyUnchanged: true)
        XCTAssertTrue(removed); XCTAssertNil(store.journal)
    }
}

private final class FakeVirtualJournalStore: VirtualDisplayWindowJournalStore, @unchecked Sendable {
    var journal: VirtualDisplayWindowJournal?
    var failWrites = false
    var failWriteNumber: Int?
    var writes = 0
    var failRemoval = false
    var afterSave: (() -> Void)?
    func load() throws -> VirtualDisplayWindowJournal? { journal }
    func save(_ journal: VirtualDisplayWindowJournal) throws {
        writes += 1
        if failWrites || failWriteNumber == writes { throw CocoaError(.fileWriteUnknown) }
        self.journal = journal
        afterSave?()
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
    var workspaceSnapshotCount = 0
    var topology: [VirtualDisplayProtectedDisplay]? = [
        .init(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
              bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), width: 1512, height: 982,
              pixelWidth: 3024, pixelHeight: 1964, modeID: 10, modeFlags: 0, refresh: 60,
              rotation: 0, main: true, mirrored: false, mirrorTarget: nil)
    ]
    var ownedIdentity = VirtualDisplayWindowOwnedDisplayIdentity(displayID: 99,
        uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, vendor: 0xFA51,
        product: 0xB801, serial: 77, leaseGeneration: UUID())
    var ownedOnline = true
    var ownedMain = false
    var ownedMirrored = false
    var forcedNextAppliedFrame: CGRect?
    var reflowAfterNextSnapshot: CGRect?
    var refuseNext = false
    var refuseWindowIDOnce: UInt32?
    var alwaysRefuse = false
    var minimumWidth: CGFloat = 0
    var forcedVirtualFrame: CGRect?
    var beforeSet: (() -> Void)?
    func physicalTopology() -> [VirtualDisplayProtectedDisplay]? { topology }
    func matchesOwnedDisplay(_ identity: VirtualDisplayWindowOwnedDisplayIdentity, virtualBounds: CGRect?) -> Bool {
        VirtualDisplayWindowPolicy.ownedDisplayMatches(identity, displayID: ownedIdentity.displayID,
            uuid: ownedIdentity.uuid, vendor: ownedIdentity.vendor, product: ownedIdentity.product,
            serial: ownedIdentity.serial, online: ownedOnline, main: ownedMain, mirrored: ownedMirrored,
            bounds: virtualBounds ?? CGRect(x: 1800, y: 0, width: 603, height: 1311), expectedBounds: virtualBounds)
    }
    func workspaceTopologyMatches(_ protected: [VirtualDisplayProtectedDisplay], virtualBounds: CGRect,
                                  ownedDisplay: VirtualDisplayWindowOwnedDisplayIdentity) -> Bool {
        guard matchesOwnedDisplay(ownedDisplay, virtualBounds: virtualBounds), let topology, let first = topology.first else { return false }
        // The fake's extra display can independently be replaced while physical monitors stay put.
        var owned = first
        owned.uuid = ownedIdentity.uuid
        owned.bounds = virtualBounds; owned.main = ownedMain; owned.mirrored = ownedMirrored; owned.mirrorTarget = nil
        return VirtualDisplayWindowPolicy.workspaceTopologyMatches(protected, current: topology + [owned], virtualBounds: virtualBounds,
            ownedDisplayUUID: ownedDisplay.uuid) && matchesOwnedDisplay(ownedDisplay, virtualBounds: virtualBounds)
    }
    func workspaceSnapshot(identities: [VirtualDisplayWindowIdentity], budget: HostAXBudget) -> VirtualDisplayWindowSnapshot {
        workspaceSnapshotCount += 1
        return snapshot(frontmostOnly: false, identities: identities, budget: budget)
    }
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
