import XCTest
@testable import PocketDeskRemote

@MainActor
final class WorkspacePersonalizationTests: XCTestCase {
    private func host(_ id: String = "a", owner: String = "b") -> PhoneHostTrust {
        let invitation = PairInvitation(server: "wss://fixture.test/signal", room: String(repeating: "a", count: 64), token: String(repeating: "b", count: 64),
            key: Data(repeating: 7, count: 32), expires: Date().addingTimeInterval(60), name: "Test Mac", ownerPairID: String(repeating: owner, count: 64))
        return PhoneHostTrust(id: String(repeating: id, count: 64), durableHostID: nil, ownerPairID: invitation.ownerPairID, invitation: invitation, legacyAliases: [])
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "WorkspaceTests." + UUID().uuidString)! }
    func testPinsOrderHideResetAreLocalAndHostBound() {
        let defaults = defaults(), store = ShortcutWorkspaceStore(defaults: defaults), host = host(), bundle = "com.apple.Safari"
        let catalog = ShortcutCatalog.chips(for: bundle)
        var profile = store.profile(host: host, bundleID: bundle, catalog: catalog)
        profile.order.reverse(); profile.hidden.insert(ShortcutWorkspaceStore.catalogID(catalog[0]))
        store.save(profile, host: host, bundleID: bundle)
        XCTAssertEqual(store.visible(host: host, bundleID: bundle, catalog: catalog).first, catalog.last)
        XCTAssertFalse(store.visible(host: host, bundleID: bundle, catalog: catalog).contains(catalog[0]))
        XCTAssertEqual(store.visible(host: self.host(owner: "c"), bundleID: bundle, catalog: catalog), catalog)
        store.restoreDefaults(host: host, bundleID: bundle)
        XCTAssertEqual(store.visible(host: host, bundleID: bundle, catalog: catalog), catalog)
    }
    func testDuplicateLabelsHaveSeparateChordIDsAndCorruptStoreFallsBack() {
        let defaults = defaults(), store = ShortcutWorkspaceStore(defaults: defaults), host = host(), bundle = "com.apple.Safari"
        let one = PersonalShortcut(id: UUID(), label: "Action", bundleID: bundle, key: "s", modifiers: ["command"])
        let two = PersonalShortcut(id: UUID(), label: "Action", bundleID: bundle, key: "f", modifiers: ["command"])
        store.save(.init(order: [], hidden: [], custom: [one,two]), host: host, bundleID: bundle)
        XCTAssertEqual(store.profile(host: host, bundleID: bundle, catalog: []).custom.count, 2)
        XCTAssertNotEqual(one.id, two.id)
        defaults.set(Data("corrupt".utf8), forKey: ShortcutWorkspaceStore.defaultsKey)
        XCTAssertTrue(store.profile(host: host, bundleID: bundle, catalog: []).custom.isEmpty)
    }
    func testNamedViewsSurviveIndependentResumeDeletionAndForgetRemovesOnlyExactHost() throws {
        let defaults = defaults(), store = TaskViewWorkspaceStore(defaults: defaults), host = host()
        let display = DisplayDescriptor(id: 9, name: "Display", width: 1440, height: 900)
        let resume = ResumeViewport(mode: .fill, zoom: 2, focus: CGPoint(x: 0.7,y: 0.4), atBaseline: false, viewOnly: false)
        let view = try XCTUnwrap(SavedTaskView(label: "Editor", host: host, display: display, viewport: resume))
        store.save(view, host: host)
        SessionResumeStore(defaults: defaults).save(nil)
        XCTAssertEqual(store.all(host: host).count, 1)
        XCTAssertTrue(store.all(host: self.host(owner: "c")).isEmpty)
        store.rename(view.id, label: "Work", host: host)
        XCTAssertEqual(store.all(host: host).first?.label, "Work")
        store.forget(host: self.host(owner: "c")); XCTAssertEqual(store.all(host: host).count, 1)
        store.forget(host: host); XCTAssertTrue(store.all(host: host).isEmpty)
    }
    func testCorruptTaskViewsAndInvalidGeometryFailClosed() {
        let defaults = defaults(), store = TaskViewWorkspaceStore(defaults: defaults), host = host()
        defaults.set(Data("invalid".utf8), forKey: TaskViewWorkspaceStore.defaultsKey)
        XCTAssertTrue(store.all(host: host).isEmpty)
        let invalid = DisplayDescriptor(id: 1, name: "Display", width: -1, height: 900)
        let resume = ResumeViewport(mode: .fill, zoom: 2, focus: CGPoint(x: 0.5,y: 0.5), atBaseline: false, viewOnly: false)
        XCTAssertNil(SavedTaskView(label: "Work", host: host, display: invalid, viewport: resume))
        let longGrapheme = "a" + String(repeating: "\u{0301}", count: 200)
        XCTAssertEqual(longGrapheme.count, 1)
        let display = DisplayDescriptor(id: 1, name: "Display", width: 1440, height: 900)
        XCTAssertNil(SavedTaskView(label: longGrapheme, host: host, display: display, viewport: resume))
        XCTAssertFalse(PersonalShortcut(id: UUID(), label: longGrapheme, bundleID: "com.apple.Safari", key: "s", modifiers: ["command"]).valid)
    }
    func testRemapWaitsForFreshGeometryAndRejectsWrongSessionHostAndChangedGeometry() throws {
        let host = host(), session = UUID(), display = DisplayDescriptor(id: 2, name: "Display", width: 1440,height: 900)
        let resume = ResumeViewport(mode: .fit, zoom: 2, focus: CGPoint(x: 0.5,y: 0.5), atBaseline: false, viewOnly: true)
        let view = try XCTUnwrap(SavedTaskView(label: "Read", host: host, display: display, viewport: resume))
        let intent = TaskViewRestoreIntent(id: UUID(), view: view, hostKey: view.hostKey, session: session, display: 99, requestedEpoch: 8, startedAt: 100)
        func decision(hostKey: String? = view.hostKey, run: UUID = session, epoch: UInt64 = 8, displayID: UInt32? = 99,
                      size: CGSize = CGSize(width:1440,height:900), pending: Bool = false, settled: Bool = true, allowed: Bool = true, now: TimeInterval = 101) -> TaskViewRestoreIntent.Decision {
            intent.decision(hostKey: hostKey, session: run, epoch: epoch, display: displayID, size: size, pendingDisplay: pending,
                            geometrySettled: settled, allowed: allowed, now: now)
        }
        XCTAssertEqual(decision(pending: true), .wait); XCTAssertEqual(decision(settled: false), .wait)
        XCTAssertEqual(decision(epoch: 7), .wait); XCTAssertEqual(decision(displayID: 2), .wait)
        XCTAssertEqual(decision(run: UUID()), .cancel); XCTAssertEqual(decision(hostKey: "wrong"), .cancel)
        XCTAssertEqual(decision(allowed: false), .cancel); XCTAssertEqual(decision(now: 111), .cancel)
        XCTAssertEqual(decision(size: CGSize(width:900,height:1440)), .fit)
        XCTAssertEqual(decision(), .restore(resume))
    }
    func testCustomControllerFreshHandshakePostsOnceAndRejectsStaleOrWrongApp() throws {
        let controller = ShortcutWorkspaceController(), session = UUID()
        var frame: WorkspaceFrame?, sent: [ScopedChordRequest] = []
        controller.authority = { (session, 8) }
        controller.transport = { next, _ in frame = next; if let request = try? next.decode(ScopedChordRequest.self) { sent.append(request) }; return true }
        let chord = PersonalShortcut(id: UUID(), label: "Save", bundleID: "com.apple.Safari", key: "s", modifiers: ["command"])
        controller.run(chord)
        XCTAssertEqual(sent.count, 1); XCTAssertEqual(sent[0].operation, .context)
        controller.receive(try WorkspaceFrame(kind: .scopedChord, requestID: XCTUnwrap(frame).requestID,
            value: ScopedChordReply(outcome: .ready, context: InputCausalEnvelope.identity(), bundleID: "com.apple.Safari")), epoch: 8)
        XCTAssertEqual(sent.count, 2); XCTAssertEqual(sent[1].operation, .post)
        let post = try XCTUnwrap(frame)
        controller.receive(try WorkspaceFrame(kind: .scopedChord, requestID: post.requestID, value: ScopedChordReply(outcome: .posted)), epoch: 8)
        XCTAssertTrue(controller.message.hasPrefix("Chord posted"))
        controller.receive(try WorkspaceFrame(kind: .scopedChord, requestID: post.requestID, value: ScopedChordReply(outcome: .posted)), epoch: 8)
        XCTAssertEqual(sent.count, 2)
        controller.run(chord)
        controller.receive(try WorkspaceFrame(kind: .scopedChord, requestID: XCTUnwrap(frame).requestID,
            value: ScopedChordReply(outcome: .ready, context: InputCausalEnvelope.identity(), bundleID: "com.apple.finder")), epoch: 8)
        XCTAssertEqual(sent.count, 3); XCTAssertFalse(controller.busy)
        controller.run(chord); controller.retire()
        controller.receive(try WorkspaceFrame(kind: .scopedChord, requestID: XCTUnwrap(frame).requestID, value: ScopedChordReply(outcome: .posted)), epoch: 8)
        XCTAssertEqual(sent.count, 4)
    }
}
