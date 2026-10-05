import XCTest

final class HostOnboardingTests: XCTestCase {
    func testFirst60ShowsActionableQRBeforeMissingPermissions() {
        var state = HostViewState()
        state.first60SetupPending = true
        state.screenRecording = .denied; state.accessibility = .denied
        state.setupStep = .pairPhone
        XCTAssertEqual(HostSetupFlow.initialPage(for: state), .pair)
        XCTAssertEqual(HostSetupFlow.visiblePages(first60: true), [.pair, .permissions, .ready])
        state.hasPairedPhone = true; state.setupStep = .screenRecording
        XCTAssertEqual(HostSetupFlow.first60Page(for: state), .permissions)
        state.screenRecording = .granted
        XCTAssertEqual(HostSetupFlow.first60Page(for: state), .permissions)
        state.accessibilitySkipped = true
        XCTAssertEqual(HostSetupFlow.first60Page(for: state), .ready)
    }

    func testFirst60DoesNotPresentAutomaticBackgroundConsent() {
        XCTAssertFalse(HostLaunchPolicy.presentsConsent(step: .done, consentPending: true, first60: true,
                                                        launchedAsLoginItem: false, loginItemRegistered: false))
        XCTAssertTrue(HostLaunchPolicy.presentsConsent(step: .done, consentPending: true, first60: false,
                                                       launchedAsLoginItem: false, loginItemRegistered: false))
    }

    // MARK: Permissions name what System Settings shows

    func testPaneTitlesFollowTheMacOSThatShowsThem() {
        XCTAssertEqual(HostSystemSettingsPane.screenRecording.title(macOSMajor: 26), "Screen & System Audio Recording")
        XCTAssertEqual(HostSystemSettingsPane.screenRecording.title(macOSMajor: 27), "Screen & System Audio Recording")
        XCTAssertEqual(HostSystemSettingsPane.accessibility.title(macOSMajor: 26), "Accessibility")
        XCTAssertEqual(HostSystemSettingsPane.accessibility.title(macOSMajor: 27), "Device Control and Data Access")
    }

    func testDeepLinksStillNameTheirPrivacyAnchors() {
        XCTAssertEqual(HostSystemSettingsPane.screenRecording.url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        XCTAssertEqual(HostSystemSettingsPane.accessibility.url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func testTheListNameIsTheInstalledBundlesFinderName() {
        XCTAssertEqual(HostPermissionCopy.listName(fromDisplayName: "PocketDesk Host.app"), "PocketDesk Host")
        XCTAssertEqual(HostPermissionCopy.listName(fromDisplayName: "Farside.app"), "Farside")
        XCTAssertEqual(HostPermissionCopy.listName(fromDisplayName: "Farside"), "Farside", "Extension already hidden")
    }

    func testInstructionsNameThePaneAndTheEntry() {
        XCTAssertEqual(HostPermissionCopy.switchOn(.screenRecording, listName: "PocketDesk Host", macOSMajor: 26),
                       "In Screen & System Audio Recording, switch on “PocketDesk Host”.")
        XCTAssertEqual(HostPermissionCopy.switchOn(.accessibility, listName: "Farside", macOSMajor: 27),
                       "In Device Control and Data Access, switch on “Farside”.")
        let recovery = HostPermissionCopy.recovery(.screenRecording, listName: "PocketDesk Host", macOSMajor: 26)
        XCTAssertTrue(recovery.contains("in Screen & System Audio Recording, select “PocketDesk Host”"), recovery)
        XCTAssertFalse(HostPermissionCopy.recovery(.accessibility, listName: "Farside", macOSMajor: 26).contains("reopen"))
    }

    // MARK: Pairing can wait

    private func pairStep(deferred: Bool) -> HostViewState {
        var state = HostViewState()
        state.screenRecording = .granted
        state.accessibility = .granted
        state.setupStep = .pairPhone
        state.pairingDeferred = deferred
        return state
    }

    func testSkippingPairingOpensTheReadyCheckAndNeverDeadEnds() {
        let waiting = pairStep(deferred: false)
        XCTAssertFalse(HostSetupFlow.canContinue(from: .pair, state: waiting), "Continue still needs a phone")
        XCTAssertEqual(HostSetupFlow.furthestPage(for: .pairPhone), .pair)
        XCTAssertEqual(HostSetupFlow.initialPage(for: waiting), .pair)

        let skipped = pairStep(deferred: true)
        XCTAssertTrue(HostSetupFlow.canContinue(from: .pair, state: skipped))
        XCTAssertEqual(HostSetupFlow.furthestPage(for: .pairPhone, pairingDeferred: true), .ready)
        XCTAssertEqual(HostSetupFlow.initialPage(for: skipped), .ready)

        var needsPermission = skipped
        needsPermission.screenRecording = .denied
        needsPermission.setupStep = .screenRecording
        XCTAssertFalse(HostSetupFlow.canContinue(from: .pair, state: needsPermission),
                       "Skipping pairing never skips a missing permission")
        XCTAssertEqual(HostSetupFlow.furthestPage(for: .screenRecording, pairingDeferred: true), .permissions)
    }

    func testTheReadyCheckTreatsASkippedPhoneAsOptionalWithAWayBack() {
        let skipped = HostReadyCheck.checks(for: pairStep(deferred: true)).first { $0.id == .phone }
        XCTAssertEqual(skipped?.result, .optional)
        XCTAssertEqual(skipped?.fix, .pairPhone)
        XCTAssertEqual(skipped?.detail, "Skipped for now · pair in Settings → Devices")

        let missing = HostReadyCheck.checks(for: pairStep(deferred: false)).first { $0.id == .phone }
        XCTAssertEqual(missing?.result, .fail)

        var paired = pairStep(deferred: true)
        paired.hasPairedPhone = true
        XCTAssertEqual(HostReadyCheck.checks(for: paired).first { $0.id == .phone }?.result, .pass)
    }

    func testTheSkipIsRememberedAcrossLaunches() throws {
        let suite = "farside.onboarding.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HostPreferences(defaults: defaults)
        XCTAssertFalse(preferences.pairingDeferred)
        preferences.pairingDeferred = true
        XCTAssertTrue(HostPreferences(defaults: defaults).pairingDeferred)
    }

    // MARK: Codes refresh instead of expiring on screen

    func testACodeThatRunsOutOnScreenIsReplaced() {
        let code = HostPairingState.showingCode("pocketdesk:abc", expires: Date())
        XCTAssertTrue(HostPairingRefresh.shouldRefresh(from: code, to: .expired))
    }

    func testOtherEndsAndFailedRefreshesStayExpired() {
        XCTAssertFalse(HostPairingRefresh.shouldRefresh(from: .awaitingApproval, to: .expired),
                       "A declined phone's code stays ended")
        XCTAssertFalse(HostPairingRefresh.shouldRefresh(from: .expired, to: .expired),
                       "A refresh that failed does not loop")
        XCTAssertFalse(HostPairingRefresh.shouldRefresh(from: .idle, to: .expired))
        let first = HostPairingState.showingCode("pocketdesk:abc", expires: Date())
        let second = HostPairingState.showingCode("pocketdesk:def", expires: Date().addingTimeInterval(120))
        XCTAssertFalse(HostPairingRefresh.shouldRefresh(from: first, to: second))
    }
}
