import XCTest
import AppKit
import ApplicationServices

final class HostTextFocusTests: XCTestCase {
    func testEditableClassificationUsesRolesOrEditableAttributes() {
        XCTAssertTrue(HostTextFocusPolicy.isEditable(
            role: kAXTextFieldRole as String, enabled: true, editable: true, valueSettable: nil))
        XCTAssertTrue(HostTextFocusPolicy.isEditable(
            role: kAXTextAreaRole as String, enabled: true, editable: nil, valueSettable: true))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(
            role: kAXTextFieldRole as String, enabled: false, editable: true, valueSettable: true))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(
            role: kAXTextFieldRole as String, enabled: true, editable: false, valueSettable: true))
        XCTAssertTrue(HostTextFocusPolicy.isEditable(
            role: kAXTextFieldRole as String, enabled: true, editable: nil, valueSettable: nil))
        XCTAssertTrue(HostTextFocusPolicy.isEditable(
            role: kAXGroupRole as String, enabled: true, editable: true, valueSettable: true))
        XCTAssertTrue(HostTextFocusPolicy.isEditable(
            role: nil, enabled: true, editable: true, valueSettable: true))
    }

    func testAllTextRolesAndSelectionMetadataAreAcceptedWithoutReadingValues() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertTrue(HostTextFocusPolicy.isEditable(role: role, enabled: nil, editable: nil, valueSettable: nil))
        }
        XCTAssertTrue(HostTextFocusPolicy.isEditable(role: "AXGroup", enabled: true, editable: nil,
                                                    valueSettable: nil, selectionPresent: true))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(role: "AXButton", enabled: true, editable: nil,
                                                     valueSettable: false))
        XCTAssertFalse(HostTextFocusPolicy.isEditable(role: "AXTextArea", enabled: true, editable: false,
                                                     valueSettable: true, selectionPresent: true))
    }

    func testTapFocusChangeOpensHiddenEditorAnywhereInAppWithinWindow() {
        let focused = HostTextFocusResult(editable: true, axEditable: true,
                                          tapHitsFocused: false, focusChangedAt: 100.3)
        XCTAssertTrue(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.35,
                                                       ax: { focused }, cursor: { .arrow }))
        XCTAssertTrue(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.4,
                                                       ax: { focused }, cursor: { nil }))
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.401,
                                                        ax: { focused }, cursor: { .iBeam }))
    }

    func testAlreadyFocusedFieldNeedsMatchingTapAndNonTextTapDoesNotOpen() {
        var focused = HostTextFocusResult(editable: true, axEditable: true, tapHitsFocused: true)
        XCTAssertTrue(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                       ax: { focused }, cursor: { nil }))
        focused.tapHitsFocused = false
        focused.tapTargetEditable = false
        focused.focusChangedAt = 99.9
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                        ax: { focused }, cursor: { .iBeam }))
        focused.focusChangedAt = 100.2
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                        ax: { focused }, cursor: { .iBeam }))
    }

    func testRealIBeamFallbackOnlyWhenAXHasNoAnswer() {
        for shape in [PointerShape.iBeam, .iBeamVertical] {
            XCTAssertTrue(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                           ax: { .unfocused }, cursor: { shape }))
        }
        let button = HostTextFocusResult(editable: false, axEditable: false, focusChangedAt: 100.05)
        var cursorRead = false
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
            ax: { button }, cursor: { cursorRead = true; return .iBeam }))
        XCTAssertFalse(cursorRead, "An AX non-text answer must veto selectable-text I-beams")
        for shape: PointerShape? in [.arrow, .unknown, nil] {
            XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                            ax: { .unfocused }, cursor: { shape }))
        }
    }

    func testRetappingAlreadyFocusedHiddenEditorUsesRealIBeamOnlyForOpaqueHit() {
        var hidden = HostTextFocusResult(editable: true, axEditable: true,
                                         tapHitsFocused: false, focusChangedAt: 99)
        XCTAssertTrue(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                       ax: { hidden }, cursor: { .iBeam }))
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                        ax: { hidden }, cursor: { .arrow }))
        hidden.tapTargetEditable = false // A selectable label/button is a concrete AX answer.
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 100, now: 100.1,
                                                        ax: { hidden }, cursor: { .iBeam }))
    }

    func testNoTapFocusChangeIsIgnoredWithoutConsultingProviders() {
        var reads = 0
        let ax = { reads += 1; return HostTextFocusResult(editable: true, axEditable: true, focusChangedAt: 100.1) }
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: nil, now: 100.2,
                                                        ax: ax, cursor: { reads += 1; return .iBeam }))
        XCTAssertFalse(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: 101, now: 100.2,
                                                        ax: ax, cursor: { reads += 1; return .iBeam }))
        XCTAssertEqual(reads, 0)
    }

    func testPollingDetectsDelayedFocusButDoesNotInventAChangeOnFirstSample() {
        let changes = HostTextFocusChanges()
        let budget = HostAXBudget(total: 0.2)
        // A harmless nonexistent pid avoids subscribing to a real application in this fixture.
        changes.setSessionActive(true)
        changes.watch(pid: 999999, budget: budget)
        let first = AXUIElementCreateApplication(999999)
        let next = AXUIElementCreateApplication(999998)
        XCTAssertNil(changes.sample(first, pid: 999999, tapIssuedAt: 100, now: 100.05))
        XCTAssertEqual(changes.sample(next, pid: 999999, tapIssuedAt: 100, now: 100.2), 100.2)
        changes.stop()
        XCTAssertNil(changes.sample(next, pid: 999999, tapIssuedAt: 100, now: 100.3))
    }

    func testNonTextControlsWithSettableValuesNeverCountAsEditors() {
        for role in ["AXSlider", "AXCheckBox", "AXRadioButton", "AXButton", "AXStaticText"] {
            XCTAssertFalse(HostTextFocusPolicy.isEditable(role: role, enabled: true, editable: nil,
                valueSettable: true, selectionPresent: true), role)
        }
    }

    func testAXTargetProviderDistinguishesOpaqueCanvasFromConcreteNonTextAnswer() {
        for role in ["AXGroup", "AXWebArea", "AXWindow", "AXUnknown"] {
            XCTAssertNil(HostTextFocusPolicy.editableAnswer(role: role, enabled: nil, editable: nil,
                                                           valueSettable: false), role)
        }
        XCTAssertEqual(HostTextFocusPolicy.editableAnswer(role: "AXStaticText", enabled: true,
            editable: nil, valueSettable: false, selectionPresent: true), false)
        XCTAssertEqual(HostTextFocusPolicy.editableAnswer(role: "AXGroup", enabled: true,
            editable: false, valueSettable: false), false)
        XCTAssertEqual(HostTextFocusPolicy.editableAnswer(role: "AXGroup", enabled: true,
            editable: nil, valueSettable: true), true)
    }

    func testPostingTimestampKeepsFocusEventBeforeReceiptInsideTapWindow() {
        let posted = HostTextFocusTicket.postedAt(receivedAt: 100.12, postingStartedMs: 100000, clockNowMs: 100120)
        XCTAssertEqual(posted, 100, accuracy: 0.0001)
        let focus = HostTextFocusResult(editable: true, axEditable: true, focusChangedAt: 100.04)
        XCTAssertTrue(HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: posted, now: 100.2,
                                                       ax: { focus }, cursor: { nil }))
    }

    func testTicketExpiresOnNewInputEpochAndLostControl() {
        let ticket = HostTextFocusTicket(epoch: 7, revision: 13, issuedAt: 100)
        func current(epoch: UInt64 = 7, revision: UInt64 = 13, now: TimeInterval = 100.2,
                     active: Bool = true, connected: Bool = true,
                     control: Bool = true, healthy: Bool = true) -> Bool {
            ticket.isCurrent(epoch: epoch, revision: revision, now: now, active: active,
                             connected: connected, controlEnabled: control, captureHealthy: healthy)
        }
        XCTAssertTrue(current())
        XCTAssertFalse(current(revision: 14), "A newer input invalidates the click")
        XCTAssertFalse(current(epoch: 8), "A new capture/session cannot reuse focus")
        XCTAssertFalse(current(now: 101), "Late AX results must not pop the keyboard")
        XCTAssertFalse(current(now: 99.9))
        XCTAssertFalse(current(active: false))
        XCTAssertFalse(current(connected: false))
        XCTAssertFalse(current(control: false))
        XCTAssertFalse(current(healthy: false))
    }

    func testOnlyCanonicalClickProbeIDIsAccepted() {
        XCTAssertTrue(HostTextFocusProbe.isValidID(String(repeating: "a", count: 32)))
        XCTAssertFalse(HostTextFocusProbe.isValidID(nil))
        XCTAssertFalse(HostTextFocusProbe.isValidID(String(repeating: "a", count: 31)))
        XCTAssertFalse(HostTextFocusProbe.isValidID(String(repeating: "A", count: 32)))
        XCTAssertFalse(HostTextFocusProbe.isValidID(String(repeating: "g", count: 32)))
    }

    func testAcceptedClickKeepsExactPointAndFailedClickHasNoPoint() {
        var point = CGPoint(x: 130, y: 145)
        var accept = true
        let sink = RemoteInputEventSink(
            pointerLocation: { point },
            mouseSequence: { _ in accept },
            scroll: { _, _, _ in true },
            text: { _ in true },
            key: { _, _ in true }
        )
        let driver = RemoteInputDriver(eventSink: sink, isTrusted: { true })
        driver.enabled = true
        driver.configure(bounds: CGRect(x: 0, y: 0, width: 500, height: 400))
        let click = RemoteAction(action: "click", interaction: NativeInteraction(clickCount: 1))
        let first = driver.handle(click, upgraded: true)
        point = CGPoint(x: 300, y: 300)
        XCTAssertTrue(first.accepted)
        XCTAssertEqual(first.clickPoint, CGPoint(x: 130, y: 145))

        accept = false
        let failed = driver.handle(click, upgraded: true)
        XCTAssertFalse(failed.accepted)
        XCTAssertNil(failed.clickPoint)
    }

    func testInvalidClickCoordinatesFailClosedWithoutAXAccess() async {
        let editable = await HostTextFocusProbe.editableAtClick(CGPoint(x: CGFloat.nan, y: 1))
        XCTAssertFalse(editable)
    }

    #if DEBUG
    @MainActor
    func testAsyncAndDirectSecureInputQueriesFailClosedOnContention() async {
        await observeSerializedSecureInput(cancelWaitingTask: false)
    }

    @MainActor
    func testCancellationKeepsEnteredSecureInputQueryOwnedUntilReturn() async {
        await observeSerializedSecureInput(cancelWaitingTask: true)
    }

    @MainActor
    private func observeSerializedSecureInput(cancelWaitingTask: Bool,
                                             file: StaticString = #filePath, line: UInt = #line) async {
        let entered = expectation(description: "Existing secure-focus queue entered native boundary")
        let boundary = SerializedSecureInputObservation(entered: entered)
        let query: @Sendable () -> Bool = { boundary.read() }
        let pending = Task { @MainActor in
            let value = await HostSecureFocus.isSecureNow(query: query)
            return (value: value, cancelled: Task.isCancelled)
        }
        defer { boundary.releaseFirst(); pending.cancel() }

        let readiness = await XCTWaiter.fulfillment(of: [entered], timeout: 3)
        guard readiness == .completed else {
            attachSerializedSecureInputObservation(boundary.snapshot(), stage: "entry failure",
                                                   cancelled: cancelWaitingTask, answer: nil)
            XCTFail("The async production path did not enter the injected native boundary", file: file, line: line)
            boundary.releaseFirst()
            _ = await pending.value
            return
        }
        if cancelWaitingTask { pending.cancel() }
        let held = boundary.snapshot()
        XCTAssertEqual(held.calls, 1, file: file, line: line)
        XCTAssertEqual(held.active, 1, "Cancelling a caller is not a native completion", file: file, line: line)
        XCTAssertEqual(held.completed, 0, file: file, line: line)

        // The first native body remains held throughout this actual synchronous MainActor call.
        // Busy must return secure without entering a second body or waiting for the first to end.
        // A lock-removed fault enters body #2, returns false, and remains safe to clean up below.
        let busy = HostSecureFocus.secureEventInputEnabled(query: query)
        let whileHeld = boundary.snapshot()
        attachSerializedSecureInputObservation(whileHeld, stage: "busy return before release",
                                               cancelled: cancelWaitingTask, answer: busy)
        XCTAssertTrue(busy, "A busy native query must fail closed for this operation", file: file, line: line)
        XCTAssertEqual(whileHeld.calls, 1, "No second native invocation before actual completion", file: file, line: line)
        XCTAssertEqual(whileHeld.active, 1, file: file, line: line)
        XCTAssertEqual(whileHeld.completed, 0, file: file, line: line)
        XCTAssertEqual(whileHeld.completedOrdinals, [], file: file, line: line)
        XCTAssertEqual(whileHeld.maximumActive, 1, file: file, line: line)
        XCTAssertEqual(whileHeld.mainThreadEntries, [false], file: file, line: line)
        XCTAssertFalse(whileHeld.releaseIssued, file: file, line: line)
        XCTAssertFalse(whileHeld.queryTimedOut, "A watchdog cannot establish nonblocking admission", file: file, line: line)

        // Explicit test control, independent of a second native entry; never an elapsed-time release.
        boundary.releaseFirst()
        let asynchronous = await pending.value
        XCTAssertTrue(asynchronous.value, "The first true answer short-circuits real AX inspection", file: file, line: line)
        XCTAssertEqual(asynchronous.cancelled, cancelWaitingTask, file: file, line: line)
        let later = HostSecureFocus.secureEventInputEnabled(query: query)
        let observed = boundary.snapshot()
        attachSerializedSecureInputObservation(observed, stage: "fresh query after completion",
                                               cancelled: cancelWaitingTask, answer: later)
        XCTAssertFalse(later, "After completion, execute a fresh false query; never cache the busy/first true answer", file: file, line: line)
        XCTAssertEqual(observed.calls, 2, file: file, line: line)
        XCTAssertEqual(observed.completed, 2, file: file, line: line)
        XCTAssertEqual(observed.completedOrdinals, [1, 2], file: file, line: line)
        XCTAssertEqual(observed.active, 0, file: file, line: line)
        XCTAssertEqual(observed.maximumActive, 1, "Actual native bodies remain serialized", file: file, line: line)
        XCTAssertEqual(observed.mainThreadEntries, [false, true],
                       "Preserve async queue and direct MainActor contexts; this is not an affinity rule", file: file, line: line)
        XCTAssertTrue(observed.releaseIssued, file: file, line: line)
        XCTAssertFalse(observed.queryTimedOut, "A watchdog is cleanup, never native completion evidence", file: file, line: line)
    }

    private func attachSerializedSecureInputObservation(_ value: SerializedSecureInputObservation.Snapshot,
                                                        stage: String, cancelled: Bool, answer: Bool?) {
        let attachment = XCTAttachment(string: "stage=\(stage) cancelled=\(cancelled) answer=\(String(describing: answer)) calls=\(value.calls) completed=\(value.completed) completedOrdinals=\(value.completedOrdinals) active=\(value.active) maximumActive=\(value.maximumActive) mainThreadEntries=\(value.mainThreadEntries) releaseIssued=\(value.releaseIssued) queryTimedOut=\(value.queryTimedOut)")
        attachment.name = "secure-input-query-serialized-\(cancelled ? "cancelled" : "ordinary")-\(stage)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    #endif
}

#if DEBUG
/// Only bookkeeping is locked here; it does not serialize the injected native bodies.
/// Body #1 is held by explicit test control and later bodies return a different value immediately.
private final class SerializedSecureInputObservation: @unchecked Sendable {
    struct Snapshot {
        var calls = 0
        var completed = 0
        var completedOrdinals: [Int] = []
        var active = 0
        var maximumActive = 0
        var mainThreadEntries: [Bool] = []
        var releaseIssued = false
        var queryTimedOut = false
    }

    private let lock = NSLock()
    private let firstEntered: XCTestExpectation
    private let release = DispatchSemaphore(value: 0)
    private var state = Snapshot()

    init(entered: XCTestExpectation) { firstEntered = entered }

    func read() -> Bool {
        lock.lock()
        state.calls += 1
        let ordinal = state.calls
        state.active += 1
        state.maximumActive = max(state.maximumActive, state.active)
        state.mainThreadEntries.append(Thread.isMainThread)
        lock.unlock()

        var timedOut = false
        if ordinal == 1 {
            firstEntered.fulfill()
            timedOut = release.wait(timeout: .now() + 5) == .timedOut
        }

        lock.lock()
        state.active -= 1
        state.completed += 1
        state.completedOrdinals.append(ordinal)
        state.queryTimedOut = state.queryTimedOut || timedOut
        lock.unlock()
        return ordinal == 1
    }

    func releaseFirst() {
        lock.lock()
        state.releaseIssued = true
        lock.unlock()
        release.signal()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }
}
#endif
