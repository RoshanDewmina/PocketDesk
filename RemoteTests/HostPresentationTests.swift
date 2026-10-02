import XCTest

final class HostPresentationTests: XCTestCase {
    private func state(_ status: HostStatus, change: (inout HostViewState) -> Void = { _ in }) -> HostViewState {
        var state = HostViewState()
        state.screenRecording = .granted
        state.accessibility = .granted
        state.hasPairedPhone = true
        state.setupStep = .done
        state.status = status
        state.displays = [HostDisplayOption(id: 1, name: "Built-in Retina Display")]
        state.selectedDisplayID = 1
        change(&state)
        return state
    }

    private let allStatuses: [HostStatus] = [
        .needsScreenRecording, .needsPhone, .pairing, .approvalRequested, .starting,
        .reconnecting, .ready, .paused, .unavailable, .viewing, .controlling
    ]

    // MARK: Mark and ember

    func testMarkTipIsLiveOnlyWhileAPhoneIsConnected() {
        for status in allStatuses {
            XCTAssertEqual(HostMarkState(status: status) == .live, status.isSessionLive, "\(status)")
        }
        XCTAssertEqual(HostMarkState(status: .paused), .paused)
        XCTAssertEqual(HostMarkState(status: .approvalRequested), .attention)
        XCTAssertEqual(HostMarkState(status: .ready), .idle)
    }

    func testEmberIsReservedForContact() {
        for status in allStatuses {
            let presentation = HostPopoverPresentation.make(for: state(status))
            XCTAssertEqual(presentation.mood == .live, status.isSessionLive, "\(status)")
            for action in presentation.actions where presentation.emphasis(of: action) == .ember {
                XCTAssertEqual(action, .stopSharing, "Only Stop Sharing may be ember")
                XCTAssertTrue(status.isSessionLive, "Stop Sharing is ember only while live")
            }
        }
        let ready = HostPopoverPresentation.make(for: state(.ready))
        XCTAssertEqual(ready.emphasis(of: .stopSharing), .plate)
        XCTAssertEqual(ready.emphasis(of: .pause), .plate)
    }

    // MARK: Session readout

    func testSessionReadoutParsesTheSendersDiagnostics() throws {
        let readout = try XCTUnwrap(HostSessionReadout.parse(
            "Direct · video/H264 · 59.6 fps · 14 ms network RTT · VideoToolbox"))
        XCTAssertEqual(readout.route, .direct)
        XCTAssertEqual(readout.framesPerSecond, 60)
        XCTAssertEqual(readout.roundTripMs, 14)
        XCTAssertEqual(readout.caption, "Direct · 14 ms · 60 fps")
        XCTAssertEqual(readout.spokenCaption, "Direct connection, 14 milliseconds, 60 frames per second")

        let relayed = try XCTUnwrap(HostSessionReadout.parse(
            "Relay · codec pending · fps pending · RTT pending · codec implementation unreported"))
        XCTAssertEqual(relayed, HostSessionReadout(route: .relayed))
        XCTAssertEqual(relayed.caption, "Relayed")

        XCTAssertEqual(HostSessionReadout.parse("Direct · video/H264 · 10 fps · 0 ms network RTT · VideoToolbox")?.caption,
                       "Direct · <1 ms · 10 fps")
        XCTAssertNil(HostSessionReadout.parse("Route not measured"))
        XCTAssertNil(HostSessionReadout.parse("Route pending · codec pending · fps pending · RTT pending · x"))
    }

    func testLivePopoverShowsTheReadoutOrSaysItIsMeasuring() {
        var live = state(.controlling)
        XCTAssertEqual(HostPopoverPresentation.make(for: live).caption, "Measuring the connection")
        live.session = HostSessionReadout(route: .direct, roundTripMs: 14, framesPerSecond: 60)
        let presentation = HostPopoverPresentation.make(for: live)
        XCTAssertEqual(presentation.headline, "Connected · sharing this Mac")
        XCTAssertEqual(presentation.title, "Your iPhone is steering")
        XCTAssertEqual(presentation.caption, "Direct · 14 ms · 60 fps")
        XCTAssertEqual(presentation.actions, [.pause, .stopSharing])
        XCTAssertTrue(presentation.showsSessionToggles)

        let watching = HostPopoverPresentation.make(for: state(.viewing))
        XCTAssertEqual(watching.title, "Your iPhone is watching")
        XCTAssertEqual(watching.headline, "Connected · view only")
    }

    // MARK: Popover states

    func testEveryStateNamesItselfWithOneMainAction() {
        for status in allStatuses {
            let presentation = HostPopoverPresentation.make(for: state(status))
            XCTAssertFalse(presentation.headline.isEmpty, "\(status)")
            XCTAssertLessThanOrEqual(presentation.headline.count, 34, "Strip caption must fit: \(status)")
            XCTAssertFalse(presentation.title.isEmpty, "\(status)")
            XCTAssertFalse(presentation.actions.isEmpty, "\(status)")
            XCTAssertLessThanOrEqual(presentation.actions.count, 2, "\(status)")
            for action in presentation.actions {
                XCTAssertLessThanOrEqual(action.title.count, 16, "Button titles stay short: \(action)")
            }
        }
    }

    func testPausedStateSaysWhenSharingComesBack() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let paused = state(.paused) { $0.pausedUntil = now.addingTimeInterval(600) }
        let presentation = HostPopoverPresentation.make(for: paused, now: now, timeText: { _ in "10:52" })
        XCTAssertEqual(presentation.headline, "Paused · back at 10:52")
        XCTAssertEqual(presentation.actions, [.resumeNow])
        XCTAssertEqual(presentation.emphasis(of: .resumeNow), .primary)

        let expired = HostPopoverPresentation.make(for: paused, now: now.addingTimeInterval(601))
        XCTAssertEqual(expired.headline, "Sharing is off")
        XCTAssertEqual(HostPopoverPresentation.make(for: state(.paused)).actions, [.resumeSharing])
    }

    func testUnavailableStatesExplainTheMacItself() {
        let locked = HostPopoverPresentation.make(for: state(.unavailable) { $0.availability = .locked })
        XCTAssertEqual(locked.title, "This Mac is locked")
        XCTAssertEqual(locked.caption, "Sharing resumes when it’s unlocked")
        XCTAssertEqual(HostPopoverPresentation.make(for: state(.unavailable) { $0.availability = .asleep }).title,
                       "This Mac went to sleep")
        XCTAssertEqual(HostPopoverPresentation.make(for: state(.unavailable) { $0.availability = .switchedUser }).title,
                       "Someone else is using this Mac")

        let service = HostPopoverPresentation.make(for: state(.unavailable) { $0.detail = "Couldn’t reach the relay." })
        XCTAssertEqual(service.message, "Couldn’t reach the relay.")
        XCTAssertEqual(service.actions, [.tryAgain])

        let asleep = HostPopoverPresentation.make(for: state(.controlling) { $0.availability = .displayAsleep })
        XCTAssertEqual(asleep.message, "The display is asleep. Your iPhone can wake it.")
    }

    func testApprovalAndSetupStatesPointAtTheFix() {
        let approval = HostPopoverPresentation.make(for: state(.approvalRequested))
        XCTAssertEqual(approval.actions, [.declinePhone, .allowPhone])
        XCTAssertEqual(approval.emphasis(of: .allowPhone), .primary)
        XCTAssertEqual(approval.emphasis(of: .declinePhone), .plate)
        XCTAssertTrue(approval.message?.contains("mouse and keyboard") == true)
        XCTAssertFalse(HostPopoverPresentation.make(for: state(.approvalRequested) { $0.allowControl = false })
            .message?.contains("mouse and keyboard") == true)

        XCTAssertEqual(HostPopoverPresentation.make(for: state(.needsScreenRecording)).actions, [.finishSetup])
        XCTAssertEqual(HostPopoverPresentation.make(for: state(.needsPhone)).actions, [.pairPhone])
        XCTAssertTrue(HostPopoverAction.pairPhone.leavesPopover)
        XCTAssertFalse(HostPopoverAction.stopSharing.leavesPopover)
    }

    // MARK: Timed pause

    func testTimedPauseOnlyResumesItsOwnSchedule() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var pause = HostTimedPause()
        XCTAssertFalse(pause.isActive(at: now))
        let first = pause.begin(at: now)
        XCTAssertEqual(first, now.addingTimeInterval(HostTimedPause.standard))
        XCTAssertTrue(pause.isActive(at: now.addingTimeInterval(599)))
        XCTAssertFalse(pause.isActive(at: now.addingTimeInterval(600)))
        XCTAssertTrue(pause.isCurrent(first))

        let second = pause.begin(at: now.addingTimeInterval(30))
        XCTAssertFalse(pause.isCurrent(first), "A replaced pause must not resume sharing")
        XCTAssertTrue(pause.isCurrent(second))

        pause.cancel()
        XCTAssertFalse(pause.isCurrent(second), "Resume or Stop cancels the pending resume")
        XCTAssertNil(pause.resumesAt)
    }

    // MARK: Setup flow

    func testSetupStartsWithHelloOnlyOnAFreshMac() {
        var fresh = HostViewState()
        fresh.screenRecording = .denied
        fresh.accessibility = .denied
        XCTAssertEqual(HostSetupFlow.initialPage(for: fresh), .hello)

        var halfway = fresh
        halfway.screenRecording = .granted
        halfway.setupStep = .accessibility
        XCTAssertEqual(HostSetupFlow.initialPage(for: halfway), .permissions)

        var revoked = state(.needsScreenRecording) { $0.screenRecording = .denied; $0.setupStep = .screenRecording }
        XCTAssertEqual(HostSetupFlow.initialPage(for: revoked), .permissions,
                       "A lost permission goes straight to the permission page")
        revoked.setupStep = .pairPhone
        XCTAssertEqual(HostSetupFlow.initialPage(for: revoked), .pair)
        XCTAssertEqual(HostSetupFlow.initialPage(for: state(.ready)), .ready)
    }

    func testContinueNeedsTheRealStateBehindEachPage() {
        var setup = HostViewState()
        XCTAssertTrue(HostSetupFlow.canContinue(from: .hello, state: setup))
        setup.setupStep = .accessibility
        XCTAssertFalse(HostSetupFlow.canContinue(from: .permissions, state: setup))
        setup.setupStep = .pairPhone
        XCTAssertTrue(HostSetupFlow.canContinue(from: .permissions, state: setup))
        XCTAssertFalse(HostSetupFlow.canContinue(from: .pair, state: setup))
        setup.setupStep = .done
        XCTAssertTrue(HostSetupFlow.canContinue(from: .pair, state: setup))
        XCTAssertFalse(HostSetupFlow.canContinue(from: .ready, state: setup))
    }

    func testStepChangesMoveThePageOnlyWhenTheyMust() {
        XCTAssertEqual(HostSetupFlow.page(afterStepChangeFrom: .done, to: .screenRecording, current: .ready), .permissions)
        XCTAssertEqual(HostSetupFlow.page(afterStepChangeFrom: .done, to: .pairPhone, current: .ready), .pair,
                       "Pair a phone… from the menu opens the pairing page")
        XCTAssertEqual(HostSetupFlow.page(afterStepChangeFrom: .pairPhone, to: .done, current: .pair), .ready,
                       "Approving the phone moves on to the ready check")
        XCTAssertEqual(HostSetupFlow.page(afterStepChangeFrom: .accessibility, to: .pairPhone, current: .permissions),
                       .permissions, "Granting permissions enables Continue without jumping")
        XCTAssertEqual(HostSetupFlow.page(afterStepChangeFrom: .screenRecording, to: .accessibility, current: .hello), .hello)
    }

    func testProgressCaptionsCountRealProgress() {
        var setup = HostViewState()
        setup.screenRecording = .granted
        setup.accessibility = .denied
        setup.setupStep = .accessibility
        XCTAssertEqual(HostSetupFlow.progressCaption(page: .permissions, state: setup), "1 of 2 granted")
        setup.accessibilitySkipped = true
        setup.setupStep = .pairPhone
        XCTAssertEqual(HostSetupFlow.progressCaption(page: .permissions, state: setup), "View only for now")
        setup.accessibility = .granted
        XCTAssertEqual(HostSetupFlow.progressCaption(page: .permissions, state: setup), "Both granted")
        XCTAssertEqual(HostSetupFlow.progressDots(page: .permissions, state: setup), 7)
        XCTAssertEqual(HostSetupFlow.progressDots(page: .hello, state: setup), 0)
        XCTAssertLessThanOrEqual(HostSetupFlow.progressDots(page: .ready, state: state(.ready)), 15)
    }

    // MARK: Ready check

    func testReadyCheckPassesOnlyWhatIsTrueNow() {
        var ready = state(.ready) {
            $0.openAtLogin = true
            $0.loginItem = .on
        }
        var checks = HostReadyCheck.checks(for: ready)
        XCTAssertEqual(checks.map(\.id), HostReadyCheck.ID.allCases)
        XCTAssertTrue(checks.allSatisfy { $0.result == .pass }, "\(checks)")
        XCTAssertTrue(HostReadyCheck.isReady(checks))
        XCTAssertEqual(checks.first { $0.id == .display }?.detail, "Sharing Built-in Retina Display")

        XCTAssertEqual(checks.map(\.id).last, .backgroundChoices)

        ready.openAtLogin = false
        ready.loginItem = .off
        checks = HostReadyCheck.checks(for: ready)
        XCTAssertEqual(checks.first { $0.id == .backgroundChoices }?.result, .pass)
        XCTAssertEqual(checks.first { $0.id == .backgroundChoices }?.detail, "Opens when you open it · sleeps as usual")
        XCTAssertEqual(checks.first { $0.id == .backgroundChoices }?.fix, .reviewChoices)
        XCTAssertTrue(HostReadyCheck.isReady(checks), "Choosing off is a valid choice")

        let starting = HostReadyCheck.checks(for: state(.starting))
        XCTAssertEqual(starting.first { $0.id == .connection }?.result, .waiting)
        XCTAssertFalse(HostReadyCheck.isReady(starting), "Not ready until the Mac is actually listening")

        let reconnecting = HostReadyCheck.checks(for: state(.reconnecting))
        XCTAssertEqual(reconnecting.first { $0.id == .connection }?.result, .waiting)
        XCTAssertEqual(reconnecting.first { $0.id == .connection }?.detail, "Reconnecting to Farside service")
        XCTAssertFalse(HostReadyCheck.isReady(reconnecting), "A Mac the service can’t reach is not ready")
        XCTAssertEqual(HostPopoverPresentation.make(for: state(.reconnecting)).title, "Reconnecting to Farside service…")

        let paused = HostReadyCheck.checks(for: state(.paused))
        XCTAssertEqual(paused.first { $0.id == .connection }?.fix, .resumeSharing)

        let unavailable = HostReadyCheck.checks(for: state(.unavailable) { $0.detail = "The relay didn’t answer." })
        XCTAssertEqual(unavailable.first { $0.id == .connection }?.detail, "The relay didn’t answer.")
        XCTAssertEqual(unavailable.first { $0.id == .connection }?.fix, .tryAgain)
    }

    func testReadyCheckAsksForLoginAndKeepAwakeChoicesUntilConfirmed() {
        let pending = HostReadyCheck.checks(for: state(.ready) { $0.consentPending = true })
        let row = pending.first { $0.id == .backgroundChoices }
        XCTAssertEqual(row?.result, .fail)
        XCTAssertEqual(row?.fix, .reviewChoices)
        XCTAssertFalse(HostReadyCheck.isReady(pending), "Setup is not finished until both are chosen")
        XCTAssertLessThanOrEqual(HostSetupFlow.progressDots(page: .ready, state: state(.ready) { $0.consentPending = true }),
                                 HostSetupFlow.progressDots(page: .ready, state: state(.ready)))

        let chosen = HostReadyCheck.checks(for: state(.ready) {
            $0.openAtLogin = true
            $0.keepAwake = true
            $0.loginItem = .on
        }).first { $0.id == .backgroundChoices }
        XCTAssertEqual(chosen?.result, .pass)
        XCTAssertEqual(chosen?.detail, "Opens at login · stays awake while sharing")

        let unapproved = HostReadyCheck.checks(for: state(.ready) {
            $0.openAtLogin = true
            $0.loginItem = .needsApproval
        }).first { $0.id == .backgroundChoices }
        XCTAssertEqual(unapproved?.result, .optional)
        XCTAssertEqual(unapproved?.detail, "Open at login needs approval in System Settings")
        XCTAssertEqual(unapproved?.fix, .openLoginItems, "Approval happens in System Settings, not in the sheet")

        for system in [HostBackgroundItemState.off, .unavailable] {
            let unregistered = HostReadyCheck.checks(for: state(.ready) {
                $0.openAtLogin = true
                $0.keepAwake = true
                $0.loginItem = system
            }).first { $0.id == .backgroundChoices }
            XCTAssertEqual(unregistered?.result, .optional, "\(system)")
            XCTAssertEqual(unregistered?.detail, "Open at login isn’t registered", "A wish is never shown as fact")
        }

        let pausedOnBattery = HostReadyCheck.checks(for: state(.ready) {
            $0.keepAwake = true
            $0.keepAwakePausedOnBattery = true
        }).first { $0.id == .backgroundChoices }
        XCTAssertEqual(pausedOnBattery?.detail, "Opens when you open it · keep-awake paused on battery")
    }

    func testConsentSheetStartsFromTheCurrentChoices() {
        XCTAssertEqual(HostConsentChoices(state(.ready)), HostConsentChoices(openAtLogin: false, keepAwake: false),
                       "A new install starts with both off")
        XCTAssertEqual(HostConsentChoices(state(.ready) {
            $0.openAtLogin = true
            $0.keepAwake = true
            $0.loginItem = .needsApproval
        }), HostConsentChoices(openAtLogin: true, keepAwake: true), "Prior choices are filled in")
    }

    func testLoginAndKeepAwakeSettingsShowTheChoiceAndWhatMacOSDid() {
        typealias C = HostBackgroundItemCopy
        XCTAssertEqual(C.loginSubtitle(wanted: true, state: .on), "On · registered")
        XCTAssertEqual(C.loginSubtitle(wanted: true, state: .needsApproval), "On · needs approval in System Settings")
        XCTAssertEqual(C.loginSubtitle(wanted: false, state: .off), "Off")
        XCTAssertEqual(C.loginSubtitle(wanted: false, state: .on), "Off · still listed in System Settings")
        XCTAssertTrue(C.loginSubtitle(wanted: true, state: .off).hasPrefix("On · not registered"))

        let normal = HostKeepAwakeCopy.subtitle(pausedOnBattery: false)
        XCTAssertTrue(normal.contains("While your iPhone is connected and not paused, the screen always stays on"),
                      "States the automatic display hold")
        XCTAssertTrue(normal.contains("Pauses on battery"))
        XCTAssertTrue(HostKeepAwakeCopy.subtitle(pausedOnBattery: true).hasPrefix("Paused on battery"))

        XCTAssertTrue(HostConsentCopy.intro.contains("Nothing changes until Continue"))
        XCTAssertTrue(HostConsentCopy.loginBody.contains("notification that a login item was added"))
        XCTAssertTrue(HostConsentCopy.loginBody.contains("System Settings"))
        XCTAssertTrue(HostConsentCopy.keepAwakeBody.contains("no phone is connected"))
        XCTAssertTrue(HostConsentCopy.keepAwakeBody.contains("battery"))
        XCTAssertTrue(HostConsentCopy.alwaysTrue.contains("connected and not paused, Farside keeps the screen on"))
        XCTAssertTrue(HostConsentCopy.alwaysTrue.contains("never unlocks"))
    }

    func testReadyCheckTreatsViewOnlyAsAChoice() {
        let noAccessibility = HostReadyCheck.checks(for: state(.ready) { $0.accessibility = .denied })
        let control = noAccessibility.first { $0.id == .control }
        XCTAssertEqual(control?.result, .optional)
        XCTAssertEqual(control?.fix, .openSettings(.accessibility))

        let controlOff = HostReadyCheck.checks(for: state(.ready) { $0.allowControl = false }).first { $0.id == .control }
        XCTAssertEqual(controlOff?.fix, .allowControl)

        let noScreen = HostReadyCheck.checks(for: state(.needsScreenRecording) {
            $0.screenRecording = .denied
            $0.displays = []
        })
        XCTAssertEqual(noScreen.first { $0.id == .screenRecording }?.fix, .openSettings(.screenRecording))
        XCTAssertEqual(noScreen.first { $0.id == .display }?.result, .waiting)
        XCTAssertFalse(HostReadyCheck.isReady(noScreen))

        let unpaired = HostReadyCheck.checks(for: state(.needsPhone) { $0.hasPairedPhone = false })
        XCTAssertEqual(unpaired.first { $0.id == .phone }?.fix, .pairPhone)
    }

    func testChimeIsOnByDefaultAndRemembered() throws {
        let suite = "HostPresentationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HostPreferences(defaults: defaults)
        XCTAssertTrue(preferences.chimeOnConnect)
        preferences.chimeOnConnect = false
        XCTAssertFalse(HostPreferences(defaults: defaults).chimeOnConnect)
    }

    func testPrivacyModeSettingSaysWhatTheDefaultDoesAndHowToLookAtTheMac() {
        var state = HostViewState()
        state.privacyCurtain = true
        state.focusAccessibility = .granted
        XCTAssertEqual(HostCurtainCopy.subtitle(for: state),
                       "On by default. Your phone still sees everything; press Esc three times at this Mac to show it")
        state.curtainStatus = "Covering your display. Your phone still sees the desktop."
        XCTAssertEqual(HostCurtainCopy.subtitle(for: state), state.curtainStatus, "A live status replaces the explanation")
        state.curtainStatus = nil
        state.privacyCurtain = false
        XCTAssertEqual(HostCurtainCopy.subtitle(for: state), "Off: anyone at the Mac can watch what the phone does")
        state.privacyCurtain = true
        state.focusAccessibility = .denied
        XCTAssertEqual(HostCurtainCopy.subtitle(for: state), "Needs Accessibility, so Esc can always lift it")
        state.captureScopeViewOnly = true
        XCTAssertEqual(HostCurtainCopy.subtitle(for: state), "Not used while sharing a single window or app",
                       "A greyed-out switch says why")
    }
}
