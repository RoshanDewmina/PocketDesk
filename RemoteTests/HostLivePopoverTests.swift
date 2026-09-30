import XCTest

/// D39: the popover's activity feed, the phone's name and a Return key that never lets a phone in.
@MainActor
final class HostLivePopoverTests: XCTestCase {
    private func state(_ status: HostStatus, change: (inout HostViewState) -> Void = { _ in }) -> HostViewState {
        var state = HostViewState()
        state.screenRecording = .granted
        state.accessibility = .granted
        state.hasPairedPhone = true
        state.setupStep = .done
        state.status = status
        change(&state)
        return state
    }

    func testReturnDeclinesAnUnknownPhone() {
        let approval = HostPopoverPresentation.make(for: state(.approvalRequested))
        XCTAssertEqual(approval.actions, [.declinePhone, .allowPhone])
        XCTAssertEqual(approval.defaultAction, .declinePhone)
        XCTAssertEqual(approval.emphasis(of: .allowPhone), .primary, "Allow still reads as the main action")
    }

    func testReturnPressesOnlyASafeMainAction() {
        XCTAssertNil(HostPopoverPresentation.make(for: state(.controlling)).defaultAction, "Return never stops a live session")
        XCTAssertNil(HostPopoverPresentation.make(for: state(.ready)).defaultAction)
        XCTAssertEqual(HostPopoverPresentation.make(for: state(.paused)).defaultAction, .resumeSharing)
        XCTAssertEqual(HostPopoverPresentation.make(for: state(.needsPhone)).defaultAction, .pairPhone)
    }

    func testTheLivePopoverNamesThePhone() {
        XCTAssertEqual(HostPopoverPresentation.make(for: state(.controlling)).title, "Your iPhone is steering")
        let named = HostPopoverPresentation.make(for: state(.viewing) { $0.phoneName = "Roshan’s iPhone" })
        XCTAssertEqual(named.title, "Roshan’s iPhone is watching")
    }

    func testActivityCountsAcceptedTapsKeysAndScrollsButNotPointerMoves() {
        let feed = HostActivityFeed()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        feed.record(action: "move", at: start)
        feed.record(action: "moveTo", at: start)
        XCTAssertTrue(feed.pulses.isEmpty)
        feed.record(action: "click", at: start)
        feed.record(action: "key", at: start)
        feed.record(action: "scroll", at: start)
        XCTAssertEqual(Set(feed.pulses.keys), [.tap, .keys, .scroll])
        XCTAssertEqual(feed.tapSerial, 1)
        XCTAssertEqual(feed.recentTaps, [start])
    }

    func testActivityIsThrottledSoInputCannotFloodThePopover() {
        let feed = HostActivityFeed()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        for step in 0..<20 { feed.record(action: "click", at: start.addingTimeInterval(Double(step) * 0.01)) }
        XCTAssertEqual(feed.pulses[.tap]?.serial, 2, "One at 0 s and one once 100 ms passed")
        for step in 0..<20 { feed.record(action: "double", at: start.addingTimeInterval(1 + Double(step) * 0.2)) }
        XCTAssertEqual(feed.recentTaps.count, HostActivityFeed.tapLimit)
    }

    func testTheSparklineKeepsOnlyMeasuredRoundTrips() {
        let feed = HostActivityFeed()
        feed.record(roundTripMs: nil)
        XCTAssertTrue(feed.roundTrips.isEmpty, "Nothing is drawn until something is measured")
        for value in 0..<50 { feed.record(roundTripMs: value) }
        XCTAssertEqual(feed.roundTrips.count, HostActivityFeed.roundTripLimit)
        XCTAssertEqual(feed.roundTrips.last, 49)
        feed.reset()
        XCTAssertTrue(feed.roundTrips.isEmpty && feed.recentTaps.isEmpty && feed.pulses.isEmpty)
    }
}
