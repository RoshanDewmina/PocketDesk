import XCTest

final class HostReadinessTests: XCTestCase {
    func testSetupStepsFollowPermissionAndPairingState() {
        func step(_ screen: HostPermissionStatus, _ ax: HostPermissionStatus, skipped: Bool = false,
                  paired: Bool = false, requested: Bool = false) -> HostSetupStep {
            .current(screenRecording: screen, accessibility: ax, accessibilitySkipped: skipped,
                     hasPairedPhone: paired, pairingRequested: requested)
        }
        XCTAssertEqual(step(.unchecked, .unchecked), .screenRecording)
        XCTAssertEqual(step(.denied, .granted, paired: true), .screenRecording,
                       "A lost Screen Recording grant always returns to the first step")
        XCTAssertEqual(step(.granted, .denied), .accessibility)
        XCTAssertEqual(step(.granted, .denied, skipped: true), .pairPhone, "View-only setup can skip Accessibility")
        XCTAssertEqual(step(.granted, .granted), .pairPhone)
        XCTAssertEqual(step(.granted, .granted, paired: true), .done)
        XCTAssertEqual(step(.granted, .granted, paired: true, requested: true), .pairPhone)
    }

    func testStatusPrioritisesLiveSessionAndApproval() {
        var inputs = HostStatus.Inputs(screenRecording: .granted, hasPairedPhone: true,
                                       sharingActive: true, hostRegistered: true)
        XCTAssertEqual(HostStatus.resolve(inputs), .ready)

        inputs.connected = true
        XCTAssertEqual(HostStatus.resolve(inputs), .viewing)
        inputs.controlEffective = true
        XCTAssertEqual(HostStatus.resolve(inputs), .controlling)

        inputs.screenRecording = .denied
        XCTAssertEqual(HostStatus.resolve(inputs), .controlling,
                       "A live session must stay visible even while permissions change underneath it")

        inputs.connected = false
        inputs.awaitingApproval = true
        XCTAssertEqual(HostStatus.resolve(inputs), .approvalRequested)
    }

    func testStatusExplainsWhyTheMacIsNotReady() {
        XCTAssertEqual(HostStatus.resolve(.init(screenRecording: .denied, hasPairedPhone: true)), .needsScreenRecording)
        XCTAssertEqual(HostStatus.resolve(.init(screenRecording: .granted)), .needsPhone)
        XCTAssertEqual(HostStatus.resolve(.init(screenRecording: .granted, pairingInProgress: true)), .pairing)
        XCTAssertEqual(HostStatus.resolve(.init(screenRecording: .granted, hasPairedPhone: true, wantsSharing: false)), .paused)
        XCTAssertEqual(HostStatus.resolve(.init(screenRecording: .granted, hasPairedPhone: true, unavailable: true)), .unavailable)
        XCTAssertEqual(HostStatus.resolve(.init(screenRecording: .granted, hasPairedPhone: true, sharingActive: true)), .starting)
        XCTAssertTrue(HostStatus.needsScreenRecording.needsAttention)
        XCTAssertFalse(HostStatus.ready.needsAttention)
    }

    func testALostServiceRegistrationIsNeverReady() {
        var inputs = HostStatus.Inputs(screenRecording: .granted, hasPairedPhone: true,
                                       sharingActive: true, hostRegistered: false, reconnecting: true)
        XCTAssertEqual(HostStatus.resolve(inputs), .reconnecting)
        XCTAssertEqual(HostStatus.reconnecting.title, "Reconnecting to Farside service…")
        XCTAssertFalse(HostStatus.reconnecting.isSessionLive)
        inputs.hostRegistered = true
        inputs.reconnecting = false
        XCTAssertEqual(HostStatus.resolve(inputs), .ready)
        inputs.hostRegistered = false
        XCTAssertEqual(HostStatus.resolve(inputs), .starting, "Ready requires a live registration")
        inputs.wantsSharing = false
        inputs.reconnecting = true
        XCTAssertEqual(HostStatus.resolve(inputs), .paused)
    }

    func testEveryStatusHasADistinctSessionIndicator() {
        XCTAssertNotEqual(HostStatus.viewing.menuBarSymbol, HostStatus.ready.menuBarSymbol)
        XCTAssertNotEqual(HostStatus.controlling.menuBarSymbol, HostStatus.ready.menuBarSymbol)
        XCTAssertNotEqual(HostStatus.controlling.menuBarSymbol, HostStatus.viewing.menuBarSymbol)
    }

    func testAutoStartRequiresEverythingAndStopsAfterUnexpectedFailure() {
        var gate = HostAutoStartGate()
        func allowed(wants: Bool = true, active: Bool = false, browser: Bool = false, screen: Bool = true,
                     display: Bool = true, paired: Bool = true, service: Bool = true) -> Bool {
            gate.shouldStart(wantsSharing: wants, sharingActive: active, otherAccessRunning: browser,
                             screenRecordingGranted: screen, displayReady: display,
                             hasPairedPhone: paired, serviceConfigured: service)
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(wants: false), "Stop Sharing must hold until the user resumes")
        XCTAssertFalse(allowed(active: true))
        XCTAssertFalse(allowed(browser: true))
        XCTAssertFalse(allowed(screen: false))
        XCTAssertFalse(allowed(display: false))
        XCTAssertFalse(allowed(paired: false), "An unpaired Mac never listens on its own")
        XCTAssertFalse(allowed(service: false))

        gate.suspend()
        XCTAssertFalse(allowed(), "A failed service start must not retry in a tight loop")
        gate.clear()
        XCTAssertTrue(allowed())
    }

    func testDisplayChoiceKeepsSelectionThenPrefersMainDisplay() {
        XCTAssertEqual(HostDisplayChoice.preferred(available: [3, 5], previous: 5, main: 3), 5)
        XCTAssertEqual(HostDisplayChoice.preferred(available: [3, 5], previous: 9, main: 3), 3)
        XCTAssertEqual(HostDisplayChoice.preferred(available: [4, 5], previous: 0, main: 3), 4)
        XCTAssertEqual(HostDisplayChoice.preferred(available: [], previous: 5, main: 3), 0)
    }

    func testSystemSettingsLinksTargetPrivacyPanes() {
        XCTAssertEqual(HostSystemSettingsPane.screenRecording.url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        XCTAssertEqual(HostSystemSettingsPane.accessibility.url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func testControlIsOnByDefaultAndRemembersTheUsersChoice() throws {
        let suite = "HostReadinessTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = HostPreferences(defaults: defaults)
        XCTAssertTrue(preferences.allowControl)
        XCTAssertFalse(preferences.keepAwake, "Idle keep-awake requires a deliberate new-install choice")
        XCTAssertTrue(preferences.sharingEnabled)
        XCTAssertTrue(HostControlConsentState().isAllowed)

        preferences.allowControl = false
        XCTAssertFalse(HostPreferences(defaults: defaults).allowControl)

        preferences.sharingEnabled = false
        XCTAssertFalse(HostPreferences(defaults: defaults).sharingEnabled,
                       "Stop Sharing must survive quitting and reopening the host")
    }

    func testShareMacAudioIsOffByDefaultAndSurvivesRelaunch() throws {
        let suite = "HostReadinessTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(HostPreferences(defaults: defaults).allowSystemAudio, "Sound sharing stays opt-in")
        HostPreferences(defaults: defaults).allowSystemAudio = true
        XCTAssertTrue(HostPreferences(defaults: defaults).allowSystemAudio, "The owner's choice survives a host relaunch")
        HostPreferences(defaults: defaults).allowSystemAudio = false
        XCTAssertFalse(HostPreferences(defaults: defaults).allowSystemAudio)
    }

    func testPrivacyModeIsOnByDefaultAndAnExplicitChoiceWins() throws {
        let suite = "HostReadinessTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(HostPreferences(defaults: defaults).privacyCurtain, "A connecting phone covers the Mac unless told otherwise")
        HostPreferences(defaults: defaults).privacyCurtain = false
        XCTAssertFalse(HostPreferences(defaults: defaults).privacyCurtain, "Off at the Mac or from the phone survives relaunch")
        HostPreferences(defaults: defaults).privacyCurtain = true
        XCTAssertTrue(HostPreferences(defaults: defaults).privacyCurtain)

        // A pre-privacy-mode install that explicitly chose off keeps it after the upgrade.
        defaults.set(false, forKey: "privacyCurtainWhileSharing")
        XCTAssertFalse(HostPreferences(defaults: defaults).privacyCurtain)
        // `defaults write … -int 1` and older builds' NSNumber values read as the choice they are.
        defaults.set(1, forKey: "privacyCurtainWhileSharing")
        XCTAssertTrue(HostPreferences(defaults: defaults).privacyCurtain)
        defaults.set(0, forKey: "privacyCurtainWhileSharing")
        XCTAssertFalse(HostPreferences(defaults: defaults).privacyCurtain)
    }

    func testPrivacyModeKillSwitchRestoresTheOldDefaultWithoutTouchingChoices() throws {
        let suite = "HostReadinessTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "privacyModeDefaultOff")
        XCTAssertFalse(HostPreferences(defaults: defaults).privacyCurtain, "Kill switch: off until the person turns it on")
        XCTAssertFalse(HostPreferences(defaults: defaults).privacyCurtainDefault)
        HostPreferences(defaults: defaults).privacyCurtain = true
        XCTAssertTrue(HostPreferences(defaults: defaults).privacyCurtain, "The kill switch never overrides an explicit on")
        defaults.removeObject(forKey: "privacyModeDefaultOff")
        XCTAssertTrue(HostPreferences(defaults: defaults).privacyCurtainDefault)
    }

    func testLocalNetworkOnlyIsOffByDefaultAndSurvivesRelaunch() throws {
        let suite = "HostReadinessTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(HostPreferences(defaults: defaults).localOnly)
        HostPreferences(defaults: defaults).localOnly = true
        XCTAssertTrue(HostPreferences(defaults: defaults).localOnly)
        XCTAssertTrue(HostPreferences(defaults: defaults).sharingEnabled, "The route choice never turns sharing off")
    }

    func testLoginAndKeepAwakeConsentIsAskedOnceAndAgainOnlyWhenItsVersionRises() throws {
        let suite = "HostReadinessTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = HostPreferences(defaults: defaults)
        XCTAssertTrue(fresh.consentPending(), "First launch asks")
        XCTAssertFalse(fresh.keepAwake, "Nothing is on before the person chooses")
        fresh.acceptedConsentVersion = HostPreferences.consentVersion
        XCTAssertFalse(HostPreferences(defaults: defaults).consentPending(), "Asked once")
        XCTAssertTrue(HostPreferences(defaults: defaults).consentPending(currentVersion: HostPreferences.consentVersion + 1),
                      "A new explanation asks again")
    }

    func testExistingKeepAwakeChoiceIsPreservedWhileConsentIsStillAsked() throws {
        let suite = "HostReadinessTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "keepAwakeWhileSharing")

        let existing = HostPreferences(defaults: defaults)
        XCTAssertTrue(existing.keepAwake, "Pre-filled from the prior choice")
        XCTAssertTrue(existing.consentPending())
    }

    func testConsentOpensAtLaunchOnlyWhenTheLaunchCannotBeALoginItemLaunch() {
        typealias P = HostLaunchPolicy
        XCTAssertTrue(P.presentsConsent(step: .done, consentPending: true, launchedAsLoginItem: false,
                                        loginItemRegistered: false))
        XCTAssertFalse(P.presentsConsent(step: .done, consentPending: true, launchedAsLoginItem: true,
                                         loginItemRegistered: false), "Never a modal at login")
        XCTAssertFalse(P.presentsConsent(step: .done, consentPending: true, launchedAsLoginItem: false,
                                         loginItemRegistered: true),
                       "A registered login item may have launched without the Apple event")
        XCTAssertFalse(P.presentsConsent(step: .done, consentPending: false, launchedAsLoginItem: false,
                                         loginItemRegistered: false))
        XCTAssertFalse(P.presentsConsent(step: .pairPhone, consentPending: true, launchedAsLoginItem: false,
                                         loginItemRegistered: false), "Unfinished setup asks on its own Ready page")

        XCTAssertTrue(P.presentsSetup(step: .screenRecording, pairingDeferred: false))
        XCTAssertFalse(P.presentsSetup(step: .pairPhone, pairingDeferred: true))
        XCTAssertFalse(P.presentsSetup(step: .done, pairingDeferred: false), "Pending consent alone doesn't open setup")
    }

    func testNewPairingUsesSelectedServiceWithoutChangingCurrentConnection() {
        let saved = "wss://saved.example/signal"
        let staging = "wss://signal-staging.getfarside.com/signal"
        XCTAssertEqual(HostPreferences.serviceEnvironment(for: staging), "staging")
        XCTAssertEqual(HostPreferences.serviceEnvironment(for: "wss://signal-staging.getfarside.com:8443/signal"), "private or custom")
        XCTAssertEqual(HostPreferences.serviceEnvironment(for: "wss://signal-staging.getfarside.com:443/signal"), "staging")
        XCTAssertEqual(HostPreferences.serviceEnvironment(for: saved), "private or custom")
        XCTAssertEqual(HostPreferences.serviceEnvironment(for: nil), "not configured")
        XCTAssertEqual(HostPreferences.resolveServiceAddress(saved: saved, preference: staging, bundled: nil), saved)
        XCTAssertEqual(HostPreferences.resolvePairingServiceAddress(saved: saved, preference: staging, bundled: nil), staging)
        XCTAssertEqual(HostPreferences.resolvePairingServiceAddress(saved: saved, preference: "http://invalid.example", bundled: nil), saved)
        XCTAssertEqual(HostPreferences.resolvePairingServiceAddress(saved: nil, preference: "http://invalid.example", bundled: staging), staging)
        XCTAssertNil(HostPreferences.resolvePairingServiceAddress(saved: nil, preference: "http://invalid.example", bundled: nil))
    }

    func testServiceAddressUsesFirstValidSource() {
        XCTAssertEqual(HostPreferences.resolveServiceAddress(
            saved: "wss://saved.example/signal", preference: "wss://pref.example/signal", bundled: nil),
            "wss://saved.example/signal")
        XCTAssertEqual(HostPreferences.resolveServiceAddress(
            saved: nil, preference: "http://bad.example", bundled: "wss://bundled.example/signal"),
            "wss://bundled.example/signal")
        XCTAssertNil(HostPreferences.resolveServiceAddress(saved: nil, preference: " ", bundled: nil))
    }
    func testFailedDisplayEnumerationOffersRecoveryButRespectsStop() {
        for state: HostDisplayRefreshStatus in [.failed, .unavailable] {
            var inputs = HostStatus.Inputs(screenRecording: .granted, hasPairedPhone: true, displayStatus: state)
            XCTAssertEqual(HostStatus.resolve(inputs), .unavailable)
            inputs.wantsSharing = false
            XCTAssertEqual(HostStatus.resolve(inputs), .paused)
        }
        XCTAssertEqual(HostStatus.resolve(.init(screenRecording: .granted, hasPairedPhone: true, displayStatus: .checking)), .starting)
    }
}
