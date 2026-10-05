import XCTest

final class WindowWorkspaceTests: XCTestCase {
    func testLifetimeRetiresForSessionEpochDisplayRevokeAndTimeout() {
        let session = UUID(), lease = WindowWorkspaceLifetime(session: UUID(), epoch: 7, display: 2, generation: 4, issuedAt: 100)
        XCTAssertFalse(lease.permits(session: session, epoch: 7, display: 2, generation: 4, now: 101, allowed: true))
        XCTAssertTrue(lease.permits(session: lease.session, epoch: 7, display: 2, generation: 4, now: 101, allowed: true))
        XCTAssertFalse(lease.permits(session: lease.session, epoch: 8, display: 2, generation: 4, now: 101, allowed: true))
        XCTAssertFalse(lease.permits(session: lease.session, epoch: 7, display: 3, generation: 4, now: 101, allowed: true))
        XCTAssertFalse(lease.permits(session: lease.session, epoch: 7, display: 2, generation: 5, now: 101, allowed: true))
        XCTAssertFalse(lease.permits(session: lease.session, epoch: 7, display: 2, generation: 4, now: 101, allowed: false))
        XCTAssertFalse(lease.permits(session: lease.session, epoch: 7, display: 2, generation: 4, now: 131, allowed: true))
    }
    func testPIDReuseAndMissingLaunchFailClosed() {
        let launch = Date()
        XCTAssertTrue(WindowWorkspaceLifetime.sameProcess(pid: 1, launch: launch, currentPID: 1, currentLaunch: launch, terminated: false))
        XCTAssertFalse(WindowWorkspaceLifetime.sameProcess(pid: 1, launch: launch, currentPID: 1, currentLaunch: launch.addingTimeInterval(1), terminated: false))
        XCTAssertFalse(WindowWorkspaceLifetime.sameProcess(pid: 1, launch: launch, currentPID: 2, currentLaunch: launch, terminated: false))
        XCTAssertFalse(WindowWorkspaceLifetime.sameProcess(pid: 1, launch: launch, currentPID: 1, currentLaunch: launch, terminated: true))
        XCTAssertFalse(WindowWorkspaceLifetime.sameProcess(pid: 1, launch: nil, currentPID: 1, currentLaunch: nil, terminated: false))
    }
    func testClosedMinimizedAndMovedWindowCannotRemainCurrent() {
        let display = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: -1400, y: 100, width: 700, height: 600)
        XCTAssertTrue(WindowWorkspaceLifetime.currentWindow(retainedMember: true, minimized: false, frame: frame, displayFrame: display))
        XCTAssertFalse(WindowWorkspaceLifetime.currentWindow(retainedMember: false, minimized: false, frame: frame, displayFrame: display))
        XCTAssertFalse(WindowWorkspaceLifetime.currentWindow(retainedMember: true, minimized: false, frame: nil, displayFrame: display))
        XCTAssertFalse(WindowWorkspaceLifetime.currentWindow(retainedMember: true, minimized: true, frame: frame, displayFrame: display))
        XCTAssertFalse(WindowWorkspaceLifetime.currentWindow(retainedMember: true, minimized: false, frame: frame.offsetBy(dx: 3000, dy: 0), displayFrame: display))
    }
    func testActivationRequiresOpaqueRevisionAndHandle() {
        XCTAssertThrowsError(try WindowWorkspaceRequest(operation: .activate).validate())
        XCTAssertThrowsError(try WindowWorkspaceRequest(operation: .activate, revision: "title", handle: "Safari").validate())
        XCTAssertNoThrow(try WindowWorkspaceRequest(operation: .activate, revision: InputCausalEnvelope.identity(), handle: InputCausalEnvelope.identity()).validate())
        XCTAssertThrowsError(try WindowWorkspaceRequest(operation: .list, handle: InputCausalEnvelope.identity()).validate())
    }
    func testActualEncodedCatalogFitsBudgetDespiteEscapedLabels() throws {
        let entries = (0..<24).map { _ in WindowWorkspaceEntry(id: InputCausalEnvelope.identity(), app: String(repeating: "\"", count: 128), title: String(repeating: "\\", count: 128), exactWindow: true) }
        let reply = try XCTUnwrap(WindowWorkspaceReply.boundedCatalog(revision: InputCausalEnvelope.identity(), entries: entries))
        XCTAssertLessThan(reply.entries.count, entries.count)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(reply).count, 8192)
        XCTAssertNoThrow(try reply.validate())
    }
    func testBoundedLabelsAndDuplicateHandles() {
        XCTAssertEqual(WindowWorkspaceReply.label("a\nb\u{0}"), "ab")
        XCTAssertEqual(WindowWorkspaceReply.label(String(repeating: "x", count: 200)).count, 128)
        let row = WindowWorkspaceEntry(id: InputCausalEnvelope.identity(), app: "App", title: "Window", exactWindow: true)
        XCTAssertThrowsError(try WindowWorkspaceReply(operation: .list, outcome: .confirmed, revision: InputCausalEnvelope.identity(), entries: [row,row]).validate())
    }
    func testNegativeOriginRetinaClipAndViewportPointerAlignment() throws {
        let display = CGRect(x: -1440, y: -900, width: 1440, height: 900)
        let geometry = try XCTUnwrap(FocusGeometry.make(field: CGRect(x: -1400, y: -850, width: 700, height: 600), anchor: nil, displayFrame: display, geometrySize: display.size))
        let viewport = ViewportTransform(sourceSize: display.size, canvasSize: CGSize(width: 393, height: 852), mode: .fill, safeInsets: .init(top: 60, left: 0, bottom: 300, right: 0))
        let fitted = try XCTUnwrap(WindowWorkspaceViewport.fit(geometry, viewport: viewport))
        let source = CGPoint(x: geometry.rect.midX, y: geometry.rect.midY)
        let mapped = try XCTUnwrap(fitted.sourcePoint(fromView: fitted.viewPoint(fromSource: source)))
        XCTAssertEqual(source.x, mapped.x, accuracy: 0.001); XCTAssertEqual(source.y, mapped.y, accuracy: 0.001)
        XCTAssertTrue(fitted.safeRect.contains(fitted.viewPoint(fromSource: source)))
        let wrong = ViewportTransform(sourceSize: CGSize(width: 900, height: 1440), canvasSize: viewport.canvasSize)
        XCTAssertNil(WindowWorkspaceViewport.fit(geometry, viewport: wrong))
    }
    func testWindowEntirelyElsewhereAndInvalidGeometryRejected() {
        XCTAssertNil(FocusGeometry.make(field: CGRect(x: 2000, y: 100, width: 100, height: 100), anchor: nil, displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), geometrySize: CGSize(width: 1440,height: 900)))
        XCTAssertThrowsError(try WindowWorkspaceReply(operation: .activate, outcome: .requested, geometry: .init(displayWidth: 1440, displayHeight: 900, x: 1, y: 1, width: 100, height: 100), display: 1).validate())
    }
}
