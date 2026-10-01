import XCTest
import ServiceManagement

private final class FakeBackgroundService: HostBackgroundService {
    var status: SMAppService.Status
    var registrations = 0
    var unregistrations = 0
    var registerError: Error?
    var onRegister: SMAppService.Status = .enabled

    init(_ status: SMAppService.Status = .notRegistered) { self.status = status }

    func register() throws {
        registrations += 1
        if let registerError { throw registerError }
        status = onRegister
    }

    func unregisterAndWait() async throws {
        unregistrations += 1
        status = .notRegistered
    }
}

@MainActor
final class HostBackgroundServicesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "HostBackgroundServicesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func services(login: FakeBackgroundService = FakeBackgroundService(),
                          agent: FakeBackgroundService = FakeBackgroundService(),
                          installed: Bool = true, fingerprint: String? = "100-1") -> HostBackgroundServices {
        HostBackgroundServices(loginItem: login, recoveryAgent: agent, defaults: defaults,
                               installed: installed, helperFingerprint: fingerprint)
    }

    func testNewSetupDoesNotEnableBackgroundItemsWithoutChoice() {
        let login = FakeBackgroundService()
        let subject = services(login: login)

        XCTAssertNil(subject.applyDefaults(setupComplete: false))
        XCTAssertEqual(login.registrations, 0, "Nothing registers before setup is complete")

        XCTAssertNil(subject.applyDefaults(setupComplete: true))
        XCTAssertEqual(login.registrations, 0)
        XCTAssertEqual(subject.loginState, .off)
        XCTAssertFalse(subject.recoveryWanted)
        subject.setLoginItem(true)
        subject.applyDefaults(setupComplete: true)
        XCTAssertEqual(login.registrations, 1, "Only the explicit choice registers")
        XCTAssertFalse(services(login: login).recoveryWanted, "Choosing login never silently chooses recovery")
    }

    func testTurningLaunchAtLoginOffSticksAcrossLaunches() async {
        let login = FakeBackgroundService()
        let subject = services(login: login)
        subject.setLoginItem(true)
        subject.setLoginItem(false)
        for _ in 0..<20 where login.status != .notRegistered { await Task.yield() }
        XCTAssertEqual(login.unregistrations, 1)

        let relaunched = services(login: login)
        relaunched.applyDefaults(setupComplete: true)
        XCTAssertEqual(login.registrations, 1, "A person's opt-out is never overridden by the default")
        XCTAssertEqual(relaunched.loginState, .off)
    }

    func testDevelopmentCopiesAreNeverRegisteredAutomatically() {
        let login = FakeBackgroundService(), agent = FakeBackgroundService()
        let subject = services(login: login, agent: agent, installed: false)
        subject.applyDefaults(setupComplete: true)
        XCTAssertEqual(login.registrations, 0)
        XCTAssertEqual(agent.registrations, 0)

        XCTAssertTrue(HostInstallLocation.isInstalled(bundlePath: "/Applications/PocketDesk Host.app", home: "/Users/me"))
        XCTAssertTrue(HostInstallLocation.isInstalled(bundlePath: "/Users/me/Applications/Farside.app", home: "/Users/me"))
        XCTAssertFalse(HostInstallLocation.isInstalled(
            bundlePath: "/Users/me/Library/Developer/Xcode/DerivedData/X/Build/Products/Debug/PocketDeskRemoteHost.app",
            home: "/Users/me"))
        XCTAssertFalse(HostInstallLocation.isInstalled(
            bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/PocketDesk Host.app", home: "/Users/me"))
    }

    func testStatusIsReportedHonestly() {
        XCTAssertEqual(HostBackgroundItemState(SMAppService.Status.enabled), .on)
        XCTAssertEqual(HostBackgroundItemState(SMAppService.Status.notRegistered), .off)
        XCTAssertEqual(HostBackgroundItemState(SMAppService.Status.requiresApproval), .needsApproval)
        XCTAssertEqual(HostBackgroundItemState(SMAppService.Status.notFound), .unavailable)
        XCTAssertTrue(HostBackgroundItemState.needsApproval.isRegistered)

        let login = FakeBackgroundService()
        login.onRegister = .requiresApproval
        let subject = services(login: login)
        subject.setLoginItem(true)
        XCTAssertEqual(subject.loginState, .needsApproval, "Registered but not approved is not shown as on")
    }

    func testRegistrationFailureIsExplainedAndAlreadyRegisteredIsSuccess() {
        let login = FakeBackgroundService()
        login.registerError = NSError(domain: "SMAppServiceErrorDomain", code: Int(kSMErrorLaunchDeniedByUser))
        let subject = services(login: login)
        let problem = subject.setLoginItem(true)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("open at login") == true)

        let already = FakeBackgroundService()
        already.registerError = NSError(domain: "SMAppServiceErrorDomain", code: Int(kSMErrorAlreadyRegistered))
        XCTAssertNil(services(login: already).setLoginItem(true))
    }

    func testExplicitRecoveryChoiceReregistersAnUpdatedHelper() async {
        let agent = FakeBackgroundService()
        let first = services(agent: agent, fingerprint: "100-1")
        XCTAssertFalse(first.recoveryWanted)
        first.setRecovery(true, setupComplete: true)
        XCTAssertEqual(agent.registrations, 1)
        XCTAssertEqual(first.recoveryState, .on)

        services(agent: agent, fingerprint: "100-1").applyDefaults(setupComplete: true)
        XCTAssertEqual(agent.registrations, 1, "An unchanged helper is not re-registered")

        let updated = services(agent: agent, fingerprint: "200-2")
        updated.applyDefaults(setupComplete: true)
        for _ in 0..<50 where agent.registrations < 2 { await Task.yield() }
        XCTAssertEqual(agent.unregistrations, 1, "ServiceManagement needs an updated agent unregistered first")
        XCTAssertEqual(agent.registrations, 2)
    }

    func testTurningRecoveryOffUnregistersTheHelper() async {
        let agent = FakeBackgroundService()
        let subject = services(agent: agent)
        subject.setRecovery(true, setupComplete: true)
        subject.setRecovery(false, setupComplete: true)
        for _ in 0..<50 where agent.unregistrations == 0 { await Task.yield() }
        XCTAssertEqual(agent.unregistrations, 1)
        XCTAssertFalse(subject.recoveryWanted)

        services(agent: agent).applyDefaults(setupComplete: true)
        XCTAssertEqual(agent.registrations, 1, "Recovery stays off after the person turns it off")
    }

    func testLegacyChoicesAndKeepAwakeArePreserved() {
        defaults.set(true, forKey: "launchAtLoginDefaultApplied")
        let subject = services(login: FakeBackgroundService(.enabled))
        XCTAssertTrue(subject.recoveryWanted, "Preserve previous completed setup's recovery default")
        XCTAssertTrue(HostPreferences(defaults: defaults).keepAwake)
        subject.setRecovery(false, setupComplete: true)
        XCTAssertFalse(services().recoveryWanted, "Explicit false survives migration/relaunch")
        defaults.set(false, forKey: "keepAwakeWhileSharing")
        XCTAssertFalse(HostPreferences(defaults: defaults).keepAwake)
    }

    func testRegisteredHelperRetainedAndNewKeepAwakeRequiresChoice() {
        XCTAssertFalse(HostPreferences(defaults: defaults).keepAwake)
        defaults.set(true, forKey: "launchAtLoginDefaultApplied")
        XCTAssertFalse(HostPreferences(defaults: defaults).keepAwake, "Later login choice does not enable idle assertions")
        let agent = FakeBackgroundService(.enabled)
        let subject = services(agent: agent)
        XCTAssertTrue(subject.recoveryWanted)
        subject.applyDefaults(setupComplete: true)
        XCTAssertEqual(agent.unregistrations, 0)
        defaults.set(true, forKey: "keepAwakeWhileSharing")
        XCTAssertTrue(HostPreferences(defaults: defaults).keepAwake)
    }

    func testLoginWishStartsFromWhatMacOSHasAndThenFollowsThePerson() {
        XCTAssertFalse(services().loginWanted, "A new install wants nothing until the person chooses")

        defaults.removeObject(forKey: "openAtLoginWanted")
        let login = FakeBackgroundService(.requiresApproval)
        let existing = services(login: login)
        XCTAssertTrue(existing.loginWanted, "An existing registration is kept as the prior choice")
        XCTAssertEqual(existing.loginState, .needsApproval, "The wish and the system status stay separate")
        XCTAssertEqual(login.registrations, 0)

        existing.setLoginItem(false)
        XCTAssertFalse(services(login: login).loginWanted, "An explicit off survives relaunch")
    }

    func testConfirmingNewConsentCopyNeverResetsPriorRecoveryOrKeepAwakeChoices() {
        defaults.set(true, forKey: "launchAtLoginDefaultApplied")
        let agent = FakeBackgroundService(.enabled)
        XCTAssertTrue(services(agent: agent).recoveryWanted)
        let preferences = HostPreferences(defaults: defaults)
        XCTAssertTrue(preferences.keepAwake)
        XCTAssertTrue(preferences.consentPending(), "New copy is still shown once to an existing install")

        preferences.acceptedConsentVersion = HostPreferences.consentVersion
        let relaunched = services(agent: agent)
        XCTAssertTrue(relaunched.recoveryWanted)
        XCTAssertEqual(agent.unregistrations, 0)
        XCTAssertTrue(HostPreferences(defaults: defaults).keepAwake)
        XCTAssertFalse(HostPreferences(defaults: defaults).consentPending())
    }

    func testConfirmingLoginChoiceMatrix() {
        typealias P = HostBackgroundPolicy
        XCTAssertFalse(P.shouldApplyLogin(wanted: true, saved: true, state: .needsApproval),
                       "No re-register while approval is pending")
        XCTAssertFalse(P.shouldApplyLogin(wanted: true, saved: true, state: .on))
        XCTAssertFalse(P.shouldApplyLogin(wanted: false, saved: false, state: .off))
        XCTAssertTrue(P.shouldApplyLogin(wanted: false, saved: true, state: .on), "Switching off unregisters")
        XCTAssertTrue(P.shouldApplyLogin(wanted: false, saved: false, state: .needsApproval),
                      "Off removes a leftover registration")
        XCTAssertTrue(P.shouldApplyLogin(wanted: true, saved: false, state: .off))
        XCTAssertTrue(P.shouldApplyLogin(wanted: true, saved: true, state: .off), "A failed registration is retried")
    }

    func testApplyingLoginChoiceTouchesOnlyTheLoginItem() async {
        defaults.set(true, forKey: "automaticRecoveryEnabled")
        defaults.set(true, forKey: "backgroundChoicePolicyV2")
        let login = FakeBackgroundService(.requiresApproval)
        let agent = FakeBackgroundService(.enabled)
        let subject = services(login: login, agent: agent)
        XCTAssertTrue(subject.loginWanted)

        XCTAssertNil(subject.applyLoginChoice(true))
        XCTAssertEqual(login.registrations, 0, "Pending approval is not registered again")

        subject.applyLoginChoice(false)
        for _ in 0..<50 where login.unregistrations == 0 { await Task.yield() }
        XCTAssertEqual(login.unregistrations, 1)
        XCTAssertFalse(subject.loginWanted)

        subject.applyLoginChoice(true)
        XCTAssertEqual(login.registrations, 1)
        XCTAssertEqual(agent.registrations, 0)
        XCTAssertEqual(agent.unregistrations, 0)
        XCTAssertTrue(subject.recoveryWanted, "Recovery is untouched by the login choice")
    }

    func testSavedWishFollowsLoginItemsChangedInSystemSettings() {
        let login = FakeBackgroundService(.enabled)
        let subject = services(login: login)
        XCTAssertTrue(subject.loginWanted)

        login.status = .requiresApproval
        subject.refresh()
        XCTAssertFalse(subject.loginWanted, "Switched off in System Settings")

        login.status = .enabled
        subject.refresh()
        XCTAssertTrue(subject.loginWanted, "Switched back on in System Settings")

        let own = FakeBackgroundService()
        own.onRegister = .requiresApproval
        let fresh = services(login: own)
        fresh.setLoginItem(true)
        XCTAssertTrue(fresh.loginWanted, "Farside's own registration waiting for approval keeps the wish")
    }

    func testRecoveryPolicy() {
        typealias P = HostBackgroundPolicy
        XCTAssertEqual(P.recoveryAction(wanted: true, setupComplete: false, installed: true, state: .off,
                                        registeredFingerprint: nil, currentFingerprint: "a"), .none)
        XCTAssertEqual(P.recoveryAction(wanted: true, setupComplete: true, installed: true, state: .off,
                                        registeredFingerprint: nil, currentFingerprint: "a"), .register)
        XCTAssertEqual(P.recoveryAction(wanted: true, setupComplete: true, installed: true, state: .on,
                                        registeredFingerprint: "a", currentFingerprint: "a"), .none)
        XCTAssertEqual(P.recoveryAction(wanted: true, setupComplete: true, installed: true, state: .needsApproval,
                                        registeredFingerprint: "a", currentFingerprint: "b"), .reregister)
        XCTAssertEqual(P.recoveryAction(wanted: false, setupComplete: true, installed: true, state: .on,
                                        registeredFingerprint: "a", currentFingerprint: "a"), .unregister)
        XCTAssertEqual(P.recoveryAction(wanted: true, setupComplete: true, installed: true, state: .off,
                                        registeredFingerprint: nil, currentFingerprint: nil), .none,
                       "A bundle without the helper never registers a broken agent")
    }
}
