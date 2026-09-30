import XCTest
@testable import PocketDeskRemote

final class WatchGlanceSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_100)
    private let started = Date(timeIntervalSince1970: 1_790_000_000)
    private let grace = Date(timeIntervalSince1970: 1_790_000_142)

    private func attributes(label: String = "Your Mac", preview: Bool? = nil) -> FarsideSessionAttributes {
        FarsideSessionAttributes(macId: "m_x", macLabel: label, sessionId: "s", startedAtUnix: 1_790_000_000, preview: preview)
    }

    private func glance(_ state: SessionState, label: String = "Your Mac", preview: Bool? = nil, stale: Bool = false) -> WatchGlance {
        SessionGlance.glance(attributes: attributes(label: label, preview: preview), state: state, isStale: stale, now: now)
    }

    private var everyState: [SessionState] {
        [.live(), .live(route: .relay), .paused(graceEnds: grace), .paused(graceEnds: now.addingTimeInterval(-5)),
         SessionState(phase: .paused, graceEndsAtUnix: nil, route: nil, endedReason: nil),
         .reconnecting(), .ended(.user), SessionState(phase: .ended, graceEndsAtUnix: nil, route: nil, endedReason: nil),
         .ended(.timeout), .ended(.macStopped), .ended(.error)]
    }

    private func words(_ glance: WatchGlance) -> [String] {
        var words = [glance.displayTitle]
        if let note = glance.note { words.append(note) }
        switch glance.detail {
        case .text(let text): words.append(text)
        case .clock(let prefix, _, _): if let prefix { words.append(prefix) }
        }
        return words
    }

    func testLiveShowsTheLabelAnElapsedClockAndWhereToEndIt() {
        let g = glance(.live(route: .direct))
        XCTAssertEqual(g.mark, .plain)
        XCTAssertEqual(g.title, "Live")
        XCTAssertEqual(g.sensitiveTitleSuffix, "Your Mac")
        XCTAssertEqual(g.displayTitle, "Live · Your Mac")
        XCTAssertEqual(g.detail, .clock(prefix: nil, interval: started...started.addingTimeInterval(8 * 3600), countsDown: false))
        XCTAssertEqual(g.note, "End it on your iPhone.")
    }

    func testPausedCountsDownToTheGraceDeadline() {
        let g = glance(.paused(graceEnds: grace))
        XCTAssertEqual(g.mark, .plain)
        XCTAssertEqual(g.title, "Paused")
        XCTAssertEqual(g.detail, .clock(prefix: "Lets go in", interval: now...grace, countsDown: true))
        XCTAssertNil(g.note)
    }

    func testPausedWithNoOrPastGraceSaysSoonWithoutAClock() {
        for state in [SessionState(phase: .paused, graceEndsAtUnix: nil, route: nil, endedReason: nil),
                      .paused(graceEnds: now.addingTimeInterval(-5)), .paused(graceEnds: now)] {
            let g = glance(state)
            XCTAssertEqual(g.title, "Paused")
            XCTAssertEqual(g.detail, .text("Lets go soon."), "\(state)")
            XCTAssertNil(g.note)
        }
    }

    func testReconnecting() {
        let g = glance(.reconnecting(route: .relay))
        XCTAssertEqual(g.mark, .plain)
        XCTAssertEqual(g.title, "Reconnecting")
        XCTAssertEqual(g.detail, .text("Hold on."))
        XCTAssertNil(g.note)
    }

    func testEndedByThePersonOrWithNoReason() {
        for state in [SessionState.ended(.user), SessionState(phase: .ended, graceEndsAtUnix: nil, route: nil, endedReason: nil)] {
            let g = glance(state)
            XCTAssertEqual(g.title, "Session ended")
            XCTAssertEqual(g.detail, .text("Mac handed back."))
            XCTAssertNil(g.note)
        }
    }

    func testEndedByTimeout() {
        let g = glance(.ended(.timeout))
        XCTAssertEqual(g.title, "Farside let go")
        XCTAssertEqual(g.detail, .text("You were away."))
        XCTAssertNil(g.note)
    }

    func testEndedAtTheMac() {
        let g = glance(.ended(.macStopped))
        XCTAssertEqual(g.title, "Sharing stopped")
        XCTAssertEqual(g.detail, .text("Stopped at the Mac."))
        XCTAssertNil(g.note)
    }

    func testEndedByAnError() {
        let g = glance(.ended(.error))
        XCTAssertEqual(g.title, "Session ended")
        XCTAssertEqual(g.detail, .text("Nothing left open."))
        XCTAssertNil(g.note)
    }

    func testStaleSessionNeverLooksLive() {
        for state in everyState {
            let g = glance(state, stale: true)
            XCTAssertEqual(g.mark, .plain)
            XCTAssertEqual(g.title, "Session ended?", "\(state)")
            XCTAssertEqual(g.detail, .text("Check your iPhone."), "A stale glance has no running clock: \(state)")
            XCTAssertNil(g.note, "\(state)")
        }
    }

    func testNoSessionGlanceHasAMacLineOrAButtonWord() {
        for state in everyState {
            for stale in [false, true] {
                for preview: Bool? in [nil, true] {
                    for text in words(glance(state, preview: preview, stale: stale)) {
                        for banned in ["seen", "%", "Tap", "End session"] {
                            XCTAssertFalse(text.contains(banned), "\(text) contains \(banned)")
                        }
                    }
                }
            }
        }
    }

    func testTheMacNameOnlyAppearsThroughTheLabel() {
        XCTAssertEqual(glance(.live(), label: "Your Mac").displayTitle, "Live · Your Mac")
        XCTAssertEqual(glance(.live(), label: "Roshan's Mac").displayTitle, "Live · Roshan's Mac")
        for state in everyState {
            for stale in [false, true] {
                let g = glance(state, label: "Roshan's Mac", stale: stale)
                XCTAssertFalse(g.accessibilityLabel.contains("Roshan"))
                XCTAssertFalse(g.title.contains("Roshan"), "The name is only ever in the redactable suffix")
                XCTAssertFalse(g.note?.contains("Roshan") ?? false)
                let named = words(g).filter { $0.contains("Roshan") }
                if state.phase == .live, !stale {
                    XCTAssertEqual(named, ["Live · Roshan's Mac"])
                } else {
                    XCTAssertEqual(named, [], "\(state) stale: \(stale)")
                }
            }
        }
    }

    func testPreviewIsLabelled() {
        XCTAssertEqual(glance(.live(), preview: true).note, "Sample · preview", "Replaces the live note")
        XCTAssertEqual(glance(.live(), preview: true).displayTitle, "Live · Your Mac")
        XCTAssertEqual(glance(.paused(graceEnds: grace), preview: true).note, "Sample · preview")
        XCTAssertEqual(glance(.ended(.timeout), preview: true).note, "Sample · preview")
        XCTAssertEqual(glance(.live(), preview: true, stale: true).note, "Sample · preview")
        XCTAssertEqual(glance(.live(), preview: true).accessibilityLabel, "Sample. Farside. Connected to your Mac.")
        XCTAssertEqual(glance(.live(), preview: false).note, "End it on your iPhone.")
    }

    func testAccessibilityReusesTheLockScreenSummary() {
        for state in everyState {
            for stale in [false, true] {
                XCTAssertEqual(glance(state, stale: stale).accessibilityLabel,
                               SessionActivityCopy.accessibilitySummary(for: state, stale: stale))
            }
        }
        XCTAssertEqual(glance(.live()).accessibilityLabel, "Farside. Connected to your Mac.")
    }
}
