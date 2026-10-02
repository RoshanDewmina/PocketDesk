import XCTest
import SwiftUI
import AppKit

/// Renders the Farside host's popover, menu-bar mark, setup window and Settings offscreen in the
/// app's dark appearance. Set POCKETDESK_SNAPSHOT_DIR to write farside-mac-<view>.png files.
@MainActor
final class HostUISnapshotTests: XCTestCase {
    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["POCKETDESK_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private static let expires = Date().addingTimeInterval(104)
    private static let code = "pocketdesk:" + String(repeating: "c29tZS1wcml2YXRlLXBhaXJpbmctY29kZQ", count: 8)
    private static let measured = HostSessionReadout(route: .direct, roundTripMs: 14, framesPerSecond: 60)

    private func ready(_ status: HostStatus, change: (inout HostViewState) -> Void = { _ in }) -> HostViewState {
        var state = HostViewState()
        state.macName = "Roshan’s MacBook Air"
        state.appListName = "PocketDesk Host"
        state.screenRecording = .granted
        state.accessibility = .granted
        state.hasPairedPhone = true
        state.setupStep = .done
        state.status = status
        state.openAtLogin = true
        state.displays = [HostDisplayOption(id: 1, name: "Built-in Retina Display")]
        state.selectedDisplayID = 1
        change(&state)
        return state
    }

    func testMenuStates() throws {
        let now = Date()
        let states: [(String, HostViewState)] = [
            ("popover-live", ready(.controlling) { $0.session = Self.measured }),
            ("popover-view-only", ready(.viewing) {
                $0.accessibility = .denied
                $0.session = HostSessionReadout(route: .relayed, roundTripMs: 48, framesPerSecond: 30)
            }),
            ("popover-ready", ready(.ready)),
            ("popover-starting", ready(.starting)),
            ("popover-reconnecting", ready(.reconnecting)),
            ("popover-needs-phone", ready(.needsPhone) { $0.hasPairedPhone = false }),
            ("popover-approval", ready(.approvalRequested) { $0.hasPairedPhone = false }),
            ("popover-paused", ready(.paused) { $0.pausedUntil = now.addingTimeInterval(540) }),
            ("popover-off", ready(.paused)),
            ("popover-locked", ready(.unavailable) { $0.availability = .locked }),
            ("popover-unavailable", ready(.unavailable) {
                $0.detail = "Couldn’t reach the connection. Check this Mac’s internet, then try again."
            }),
            ("popover-needs-setup", ready(.needsScreenRecording) { $0.screenRecording = .denied }),
            ("popover-capture-approval", ready(.captureNeedsApproval)),
            ("popover-crash-loop", ready(.unavailable) {
                $0.crashLoopStopped = true
                $0.detail = "Farside stopped after repeated crashes. Sharing is paused until you resume it."
            }),
            ("popover-live-named", ready(.controlling) {
                $0.session = Self.measured
                $0.sessionStartedAt = now.addingTimeInterval(-724)
                $0.phoneName = "Roshan’s iPhone"
            }),
            ("popover-live-measuring", ready(.controlling) { $0.sessionStartedAt = now.addingTimeInterval(-3) }),
            ("popover-pairing-code", ready(.pairing) { $0.pairing = .showingCode(Self.code, expires: Self.expires) }),
            ("popover-pairing-expired", ready(.pairing) { $0.pairing = .expired }),
            ("popover-couch", ready(.controlling) { $0.couchMode = true }),
            ("popover-big-text", ready(.controlling) {
                $0.session = Self.measured
                $0.bigTextStatus = "Big Text on · looks like 1280 × 832"
            }),
            ("popover-big-text-restoring", ready(.unavailable) {
                $0.availability = .locked
                $0.bigTextStatus = "Restoring normal size…"
            }),
            ("popover-away-armed", ready(.controlling) {
                $0.awayMode = true
                $0.away = HostAwayReadout(available: true, enabled: true, phase: .armed,
                                        coversAt: now.addingTimeInterval(90))
            }),
            ("popover-away-lock-unconfirmed", ready(.unavailable) {
                $0.awayMode = true
                $0.away = HostAwayReadout(available: true, enabled: true, phase: .lockFailed)
            }),
            ("popover-screensaver-lock-warning", ready(.ready) {
                $0.lockWarning = .screenSaverLocked(at: now.addingTimeInterval(-600), awayArmed: false)
            }),
            ("popover-curtain-up", ready(.controlling) {
                $0.session = Self.measured
                $0.privacyCurtain = true
                $0.curtainStatus = "Covering your display. Your phone still sees the desktop."
                $0.loginItem = .needsApproval
            })
        ]
        for (name, state) in states {
            let presentation = HostPopoverPresentation.make(for: state, now: now)
            XCTAssertLessThanOrEqual(presentation.headline.count, 34, name)
            XCTAssertEqual(presentation.mood == .live, state.status.isSessionLive, name)
            try render(name, HostPopoverReviewScene(state: state, now: now,
                                                   activity: name == "popover-live-named" ? Self.liveFeed(now: now) : nil))
        }
        try render("popover-stop-confirm", HostPopoverReviewScene(state: ready(.controlling) {
            $0.session = Self.measured
            $0.sessionStartedAt = now.addingTimeInterval(-300)
        }, now: now, confirmingStop: true))
    }

    /// Measured round trips and a tap from just now, so the sparkline and the Taps light show.
    private static func liveFeed(now: Date) -> HostActivityFeed {
        let feed = HostActivityFeed()
        for value in [13, 14, 14, 16, 13, 12, 15, 31, 18, 14, 13, 14, 15, 14] { feed.record(roundTripMs: value) }
        return feed
    }

    func testStandaloneLiveStrip() throws {
        let now = Date()
        for (name, status, session, control) in [
            ("live-strip-direct", HostStatus.controlling, Self.measured as HostSessionReadout?, true),
            ("live-strip-measuring", .controlling, nil, true),
            ("live-strip-view-only", .viewing,
             HostSessionReadout(route: .relayed, roundTripMs: 48, framesPerSecond: 30), false)
        ] {
            let state = ready(status) { $0.session = session; $0.allowControl = control }
            let feed = Self.liveFeed(now: now)
            try render(name, VStack(spacing: 16) {
                HostPopoverStrip(presentation: HostPopoverPresentation.make(for: state, now: now), activity: feed)
                HostLiveReadout(session: session, allowControl: control, activity: feed).padding(.horizontal, 16)
            }
            .padding(.bottom, 16)
            .frame(width: 360)
            .background(HostTheme.popoverBackground))
        }
    }

    func testLiveMarkFramesAnimateOnlyTheLiveMark() {
        let frames = [HostMarkFrame(halo: 0.18), HostMarkFrame(wave: 0.5), HostMarkFrame(flash: 0.5)]
        for frame in frames {
            for state in HostMarkState.allCases {
                let image = HostMenuBarIcon.image(for: state, accessibilityDescription: "Farside", frame: frame)
                XCTAssertEqual(image.isTemplate, state != .live, "A frame never changes what tints the mark")
            }
        }
        let live = Date(timeIntervalSinceReferenceDate: 50)
        XCTAssertNotNil(HostMarkFrame.at(live.addingTimeInterval(0.2), liveSince: live, flashAt: nil).wave)
        XCTAssertNil(HostMarkFrame.at(live.addingTimeInterval(0.6), liveSince: live, flashAt: nil).wave, "The arrival wave plays once")
        XCTAssertNotNil(HostMarkFrame.at(live.addingTimeInterval(0.1), liveSince: nil, flashAt: live).flash)
        XCTAssertNil(HostMarkFrame.at(live.addingTimeInterval(0.4), liveSince: nil, flashAt: live).flash)
        let halos = stride(from: 0.0, to: 2.8, by: 0.1).map { HostMarkFrame.at(live.addingTimeInterval($0), liveSince: nil, flashAt: nil).halo }
        XCTAssertGreaterThan(halos.max()!, halos.min()!, "The halo breathes")
        XCTAssertTrue(halos.allSatisfy { $0 >= 0.15 && $0 <= 0.5 })
    }

    func testMenuBarMark() throws {
        for state in HostMarkState.allCases {
            let image = HostMenuBarIcon.image(for: state, accessibilityDescription: "Farside, \(state)")
            XCTAssertEqual(image.isTemplate, state != .live, "Only the live mark carries its own colors")
            XCTAssertEqual(image.accessibilityDescription, "Farside, \(state)")
            XCTAssertLessThanOrEqual(image.size.height, 22, "Fits the menu bar")
        }

        let strip = HostMenuBarReviewStrip()
        let bitmap = try render("menubar", strip, fixedSize: strip.size)
        let scale = CGFloat(bitmap.pixelsWide) / strip.size.width
        for (row, dark) in [(0, false), (1, true)] {
            for (index, state) in HostMarkState.allCases.enumerated() {
                let frame = strip.imageFrame(row: row, column: index)
                let ember = count(in: bitmap, frame: frame, scale: scale) { isEmber($0) }
                XCTAssertEqual(ember > 0, state == .live, "Ember tip only while live (\(state), dark: \(dark))")
                if state == .live {
                    let body = luminance(bitmap, point: CGPoint(x: frame.minX + 2, y: frame.minY + 6), scale: scale)
                    if dark {
                        XCTAssertGreaterThan(body, 0.6, "Live mark body follows a dark menu bar")
                    } else {
                        XCTAssertLessThan(body, 0.4, "Live mark body follows a light menu bar")
                    }
                }
            }
        }
    }

    func testArtStillFrameKeepsTheCaptionCornerClearAndEmberForContact() throws {
        let strip = CGSize(width: 360, height: 96)
        for mood in [HostPopoverPresentation.Mood.live, .calm, .paused, .attention] {
            let art = HostArt(.popoverStrip(mood)).frame(width: strip.width, height: strip.height)
                .background(Farside.Palette.void)
            let bitmap = try render("art-strip-\(mood)", art, fixedSize: strip, write: false)
            let scale = CGFloat(bitmap.pixelsWide) / strip.width
            let whole = CGRect(origin: .zero, size: strip)
            XCTAssertGreaterThan(count(in: bitmap, frame: whole, scale: scale, step: 1) { isDot($0) }, 100, "The strip has art: \(mood)")
            XCTAssertEqual(count(in: bitmap, frame: whole, scale: scale, step: 1) { isEmber($0) } > 0, mood == .live,
                           "Ember only while live: \(mood)")
            XCTAssertEqual(count(in: bitmap, frame: HostArtScenes.captionPlate(in: strip), scale: scale, step: 1) { isDot($0) }, 0,
                           "No dots where the caption plate sits: \(mood)")
        }

        let rail = CGSize(width: 280, height: 520)
        for (reach, contact) in [(0, false), (3, false), (3, true)] {
            let art = HostArt(.setupRail(reach: reach, contact: contact)).frame(width: rail.width, height: rail.height)
                .background(Color.black)
            let bitmap = try render("art-rail", art, fixedSize: rail, write: false)
            let scale = CGFloat(bitmap.pixelsWide) / rail.width
            let ember = count(in: bitmap, frame: CGRect(origin: .zero, size: rail), scale: scale, step: 1) { isEmber($0) }
            XCTAssertEqual(ember > 0, contact, "Rail ember only at contact (reach \(reach))")
        }
    }

    func testSetupSteps() throws {
        var fresh = HostViewState()
        fresh.appListName = "PocketDesk Host"
        fresh.macOSMajor = 26
        fresh.screenRecording = .denied
        fresh.accessibility = .denied
        fresh.setupStep = .screenRecording
        XCTAssertEqual(HostSetupFlow.initialPage(for: fresh), .hello)
        try render("setup-1-hello", HostSetupView(state: fresh, actions: .preview))
        try render("setup-2-permissions", HostSetupView(state: fresh, actions: .preview, page: .permissions))

        var waiting = fresh
        waiting.screenRecording = .granted
        waiting.setupStep = .accessibility
        waiting.accessibilitySettingsOpened = true
        try render("setup-2b-permissions-waiting", HostSetupView(state: waiting, actions: .preview, page: .permissions))
        var waitingOn27 = waiting
        waitingOn27.macOSMajor = 27
        try render("setup-2b-permissions-waiting-macos27", HostSetupView(state: waitingOn27, actions: .preview,
                                                                         page: .permissions))
        var waitingForScreen = fresh
        waitingForScreen.screenRecordingSettingsOpened = true
        try render("setup-2e-permissions-waiting-screen", HostSetupView(state: waitingForScreen, actions: .preview,
                                                                        page: .permissions))
        var afterUpdate = fresh
        afterUpdate.hasPairedPhone = true
        afterUpdate.macOSMajor = 27
        afterUpdate.permissionsTurnedOffByUpdate = [.screenRecording, .accessibility]
        try render("setup-2f-permissions-after-macos-update", HostSetupView(state: afterUpdate, actions: .preview,
                                                                           page: .permissions))

        var granted = waiting
        granted.accessibility = .granted
        granted.setupStep = .pairPhone
        try render("setup-2c-permissions-granted", HostSetupView(state: granted, actions: .preview, page: .permissions))

        var pair = granted
        pair.pairing = .showingCode(Self.code, expires: Self.expires)
        XCTAssertEqual(HostSetupFlow.initialPage(for: pair), .pair)
        try render("setup-3-pair", HostSetupView(state: pair, actions: .preview))
        pair.pairing = .awaitingApproval
        try render("setup-3b-approve", HostSetupView(state: pair, actions: .preview))
        pair.pairing = .expired
        try render("setup-3c-expired", HostSetupView(state: pair, actions: .preview))
        let replace = ready(.ready) {
            $0.pairingRequested = true
            $0.setupStep = .pairPhone
            $0.pairing = .confirmReplace
        }
        try render("setup-3d-replace", HostSetupView(state: replace, actions: .preview))

        var skipped = granted
        skipped.pairingDeferred = true
        skipped.status = .needsPhone
        XCTAssertEqual(HostSetupFlow.initialPage(for: skipped), .ready, "Skip for now lands on the ready check")
        try render("setup-3e-pair-skipped-ready", HostSetupView(state: skipped, actions: .preview))

        try render("setup-4-ready-check", HostSetupView(state: ready(.ready) { $0.openAtLogin = false }, actions: .preview))
        try render("setup-4b-ready-live", HostSetupView(state: ready(.controlling) { $0.session = Self.measured },
                                                         actions: .preview))
        try render("setup-4c-ready-issues", HostSetupView(state: ready(.unavailable) {
            $0.detail = "Couldn’t reach the connection."
            $0.accessibility = .denied
        }, actions: .preview))
        try render("setup-4d-ready-choices-pending", HostSetupView(state: ready(.ready) {
            $0.consentPending = true
            $0.openAtLogin = false
        }, actions: .preview))
    }

    func testConsentChoices() throws {
        let fresh = ready(.ready) {
            $0.consentPending = true
            $0.openAtLogin = false
            $0.keepAwake = false
        }
        let sheetLimit = HostTheme.setupSize.height
        for (name, state, cancel) in [
            ("setup-5-consent-new", fresh, false),
            ("setup-5b-consent-prior-choices", ready(.ready) {
                $0.consentPending = true
                $0.openAtLogin = true
                $0.keepAwake = true
            }, false),
            ("setup-5c-consent-change", ready(.ready), true)
        ] {
            let bitmap = try render(name, HostConsentView(state: state, confirm: { _ in }, cancel: cancel ? {} : nil))
            let height = CGFloat(bitmap.pixelsHigh) / (CGFloat(bitmap.pixelsWide) / 640)
            XCTAssertLessThanOrEqual(height, sheetLimit - 40, "\(name) fits over the \(sheetLimit) pt setup window")
        }
        try render("settings-keep-awake-on-battery", HostSettingsView(state: ready(.ready) {
            $0.keepAwake = true
            $0.keepAwakePausedOnBattery = true
            $0.loginItem = .needsApproval
        }, actions: .preview))
    }

    func testSettings() throws {
        try render("settings-removal-retry", HostSettingsView(state: ready(.paused) {
            $0.localPairRemovalMessage = "Couldn’t confirm removal. Phone sharing is off. Unlock this Mac and retry Remove."
        }, actions: .preview))
        try render("settings", HostSettingsView(state: ready(.ready), actions: .preview))
        try render("settings-live-two-displays", HostSettingsView(state: ready(.controlling) {
            $0.displays = [HostDisplayOption(id: 1, name: "Built-in Retina Display"),
                           HostDisplayOption(id: 2, name: "Studio Display")]
            $0.session = Self.measured
        }, actions: .preview))
        try render("settings-needs-attention", HostSettingsView(state: ready(.needsPhone) {
            $0.hasPairedPhone = false
            $0.accessibility = .denied
            $0.openAtLogin = false
        }, actions: .preview))
        try render("settings-reliability-privacy", HostSettingsView(state: ready(.controlling) {
            $0.session = Self.measured
            $0.openAtLogin = true
            $0.loginItem = .on
            $0.automaticRecovery = .needsApproval
            $0.privacyCurtain = true
            $0.curtainStatus = "Covering 2 displays. Your phone still sees the desktop."
        }, actions: .preview))
        try render("settings-crash-loop", HostSettingsView(state: ready(.unavailable) {
            $0.crashLoopStopped = true
            $0.automaticRecovery = .on
        }, actions: .preview))
        try render("settings-agent-alerts", HostSettingsView(state: ready(.controlling) {
            $0.session = Self.measured
            $0.agentAlerts = true
            $0.agentAlertsStatus = "Claude Code asked 2 min ago · told your iPhone"
        }, actions: .preview))
        try render("settings-capture-approval-icon-hidden", HostSettingsView(state: ready(.captureNeedsApproval) {
            $0.menuBarIconShown = false
        }, actions: .preview))
    }

    /// Capture the actual scrollable Settings content, including the sections below the fold.
    func testSettingsScrolledSections() throws {
        let fixtures: [(String, HostViewState)] = [
            ("settings", ready(.ready)),
            ("settings-agent-alerts", ready(.controlling) {
                $0.session = Self.measured
                $0.agentAlerts = true
                $0.agentAlertsStatus = "Claude Code asked 2 min ago · told your iPhone"
            }),
            ("settings-wake-and-server-retry", ready(.ready) {
                $0.wakeHelperHostID = String(repeating: "a", count: 64)
                $0.wakeOwnerPairID = String(repeating: "b", count: 64)
                $0.serverRemovalPending = true
                $0.serverRemovalMessage = "Couldn’t confirm server removal. Sharing is off. Retry when this Mac is online."
            }),
            ("settings-scoped-view-only", ready(.viewing) {
                $0.captureScopes = [.init(id: "display", name: "Entire display"),
                                    .init(id: "window:fixture", name: "Fixture editor window")]
                $0.selectedCaptureScopeID = "window:fixture"
                $0.captureScopeViewOnly = true
                $0.allowControl = false
            }),
            ("settings-away-preview", ready(.controlling) {
                $0.awayMode = true
                $0.away = HostAwayReadout(available: true, enabled: true, phase: .covered,
                                        batteryEndsAt: Date().addingTimeInterval(240))
                $0.lockWarning = .lockedWhileSharing(at: Date().addingTimeInterval(-600))
            })
        ]
        for (name, state) in fixtures {
            for (suffix, fraction) in [("top", 0.0), ("middle", 0.5), ("bottom", 1.0)] {
                try render("\(name)-\(suffix)", HostSettingsView(state: state, actions: .preview),
                           scrollFraction: fraction)
            }
        }
    }

    func testGuestViewing() throws {
        let fingerprint = stride(from: 0, to: 64, by: 8).map { _ in "0123abcd" }.joined(separator: " ")
        let fixtures: [(String, HostViewState)] = [
            ("guest-unavailable", ready(.ready)),
            ("guest-available", ready(.controlling) { $0.guestViewingAvailable = true }),
            ("guest-link-ready", ready(.controlling) {
                $0.guestViewingAvailable = true
                $0.guestRows = [.init(id: "fixture-link", fingerprint: fingerprint,
                                      status: "Link ready · waiting for a recipient", pending: false, linkReady: true)]
            }),
            ("guest-approval-pending", ready(.controlling) {
                $0.guestViewingAvailable = true
                $0.guestRows = [.init(id: "fixture-pending", fingerprint: fingerprint,
                                      status: "Recipient is waiting for approval", pending: true, linkReady: false)]
            }),
            ("guest-two-active", ready(.controlling) {
                $0.guestViewingAvailable = true
                $0.guestRows = [
                    .init(id: "fixture-1", fingerprint: fingerprint, status: "Viewing · 8 minutes left", pending: false, linkReady: false),
                    .init(id: "fixture-2", fingerprint: fingerprint, status: "Viewing · 6 minutes left", pending: false, linkReady: false)
                ]
            }),
            ("guest-error", ready(.controlling) {
                $0.guestMessage = "Couldn’t create a guest link. Try again while your remote session is live."
            })
        ]
        for (name, state) in fixtures {
            try render(name, HostGuestSettingsView(state: state, actions: .preview)
                .padding(24).frame(width: 620).background(HostTheme.windowBackground))
        }
    }

    func testWakeRegistration() throws {
        let suite = "FarsideHostSnapshotWake-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HostWakeTargetStore(defaults: defaults)
        let helper = String(repeating: "a", count: 64)
        let owner = String(repeating: "b", count: 64)
        try render("wake-registration-empty", WakeTargetRegistrationView(helperHostID: helper,
                                                                          ownerPairID: owner, store: store))
        try store.register(HostWakeTarget(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
                                         targetHostID: String(repeating: "c", count: 64), helperHostID: helper,
                                         ownerPairID: owner, hardwareAddress: WakeHardwareAddress("02:00:00:00:00:01"),
                                         interfaceName: "en0"), helperHostID: helper, ownerPairID: owner)
        try render("wake-registration-existing", WakeTargetRegistrationView(helperHostID: helper,
                                                                             ownerPairID: owner, store: store))
        defaults.set("fixture unreadable data", forKey: "ownerRegisteredWakeTargetsV1")
        try render("wake-registration-unreadable", WakeTargetRegistrationView(helperHostID: helper,
                                                                               ownerPairID: owner, store: store))
    }

    func testLegalNotices() throws {
        // A hostless XCTest runner's Bundle.main is xctest, not the shipping host. Read the same
        // bundled resource from this test bundle; the copied View body remains unchanged.
        try render("legal-notices-component", HostLegalSnapshotView())
    }

    func testLegalNoticesScrolledSections() throws {
        for (name, fraction) in [("middle", 0.5), ("bottom", 1.0)] {
            try render("legal-notices-component-\(name)", HostLegalSnapshotView(), scrollFraction: fraction)
        }
    }

    func testAdditionalSetupStates() throws {
        let service = ready(.needsPhone) {
            $0.hasPairedPhone = false
            $0.setupStep = .pairPhone
            $0.pairing = .needsService
        }
        try render("setup-3f-service-address", HostSetupView(state: service, actions: .preview, page: .pair))
        try render("setup-3g-already-paired", HostSetupView(state: ready(.ready), actions: .preview, page: .pair))
        let loading = ready(.pairing) {
            $0.hasPairedPhone = false
            $0.setupStep = .pairPhone
            $0.pairing = .idle
        }
        try render("setup-3h-code-loading", HostSetupView(state: loading, actions: .preview, page: .pair))
        try render("popover-pairing-loading", HostPopoverReviewScene(state: loading, now: Date()))
        let skipped = ready(.needsPhone) {
            $0.hasPairedPhone = false
            $0.accessibility = .denied
            $0.accessibilitySkipped = true
            $0.setupStep = .pairPhone
        }
        try render("setup-2g-accessibility-skipped", HostSetupView(state: skipped, actions: .preview,
                                                                  page: .permissions))
    }

    func testPermissionRecoveryComponents() throws {
        for macOSMajor in [26, 27] {
            for (name, title, reason, symbol, pane) in [
                ("screen-recording", "Screen Recording", "So your iPhone can see the screen.", "display",
                 HostSystemSettingsPane.screenRecording),
                ("accessibility", "Accessibility", "So taps become clicks and typing becomes typing.",
                 "hand.point.up.left", .accessibility)
            ] {
                let recovery = HostPermissionCopy.recovery(pane, listName: "PocketDesk Host", macOSMajor: macOSMajor)
                // Existing row hook exposes the delayed button without waiting or opening native UI.
                try render("permission-recovery-row-\(name)-macos\(macOSMajor)", HostPermissionRow(
                    title: title, reason: reason, symbol: symbol, status: .denied, waiting: true,
                    instruction: HostPermissionCopy.switchOn(pane, listName: "PocketDesk Host", macOSMajor: macOSMajor),
                    showsRecoveryLink: true, recovery: recovery, open: {},
                    relaunch: pane == .screenRecording ? {} : nil)
                    .padding(24).frame(width: 640).background(HostTheme.windowBackground))
                // Copy the production popover content only; no native popover/window is presented.
                try render("permission-recovery-body-\(name)-macos\(macOSMajor)",
                           HostPermissionRecoverySnapshotBody(recovery: recovery)
                    .background(HostTheme.popoverBackground))
            }
        }
    }

    func testCouchHUD() throws {
        // Snapshot-only exact View fixture; the production controller never orders a panel front.
        try render("couch-hud", CouchHUDView())
    }

    func testPrivacyCurtainComponents() throws {
        let displaySize = CGSize(width: 1440, height: 900)
        for (name, style) in [("sharing", PrivacyCurtainStyle.sharing),
                              ("away", .away), ("away-lock-failed", .awayLockFailed)] {
            // The source-copy View body fills an invented display; no shielding window is created.
            try render("privacy-curtain-\(name)", PrivacyCurtainView(style: style)
                .frame(width: displaySize.width, height: displaySize.height), fixedSize: displaySize)
        }
    }

    func testReceivedLinkOfferComponent() throws {
        let fixtureURL = try XCTUnwrap(URL(string: "https://example.invalid/fixture-link"))
        // Test-only source-copy View body. Neither action opens a URL or changes the clipboard.
        try render("received-link-offer", HostLinkOfferView(url: fixtureURL, open: {}, dismiss: {})
            .background(HostTheme.windowBackground))
    }

    func testCrashLoopAndCurtainAreExplained() {
        let stopped = HostPopoverPresentation.make(for: ready(.unavailable) { $0.crashLoopStopped = true })
        XCTAssertEqual(stopped.headline, "Stopped after repeated crashes")
        XCTAssertEqual(stopped.actions, [.tryAgain], "Try Again resumes sharing and clears the crash-loop stop")
        XCTAssertEqual(HostBackgroundItemCopy.loginSubtitle(wanted: true, state: .needsApproval),
                       "On · needs approval in System Settings")
        XCTAssertEqual(HostCurtainCopy.subtitle(for: ready(.controlling) {
            $0.privacyCurtain = true
            $0.focusAccessibility = .denied
        }), "Needs Accessibility, so Esc can always lift it")
    }

    // MARK: Rendering

    @discardableResult
    private func render<V: View>(_ name: String, _ view: V, fixedSize: CGSize? = nil,
                                 write: Bool = true, scrollFraction: Double? = nil) throws -> NSBitmapImageRep {
        guard let appearance = NSAppearance(named: .darkAqua) else { throw XCTSkip("No dark appearance") }
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = appearance
        let size = fixedSize ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        if let scrollFraction {
            let scroll = try XCTUnwrap(scrollViews(in: host).first, "No native scroll view for \(name)")
            let document = try XCTUnwrap(scroll.documentView, "No scroll document for \(name)")
            let distance = max(0, document.bounds.height - scroll.contentView.bounds.height)
            XCTAssertGreaterThan(distance, 0, "\(name) should include content below the fold")
            let offset = distance * CGFloat(scrollFraction)
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX,
                                                  y: document.isFlipped ? offset : distance - offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), "No bitmap for \(name)")
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 100, name)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 40, name)
        if write, let outputDirectory, let png = bitmap.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try png.write(to: outputDirectory.appendingPathComponent("farside-mac-\(name).png"))
        }
        window.contentView = nil
        return bitmap
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func pixel(_ bitmap: NSBitmapImageRep, _ point: CGPoint, scale: CGFloat) -> NSColor? {
        let x = Int((point.x * scale).rounded(.down)), y = Int((point.y * scale).rounded(.down))
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else { return nil }
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    private func count(in bitmap: NSBitmapImageRep, frame: CGRect, scale: CGFloat, step: CGFloat = 0.5,
                       where test: (NSColor) -> Bool) -> Int {
        var total = 0
        var y = frame.minY
        while y < frame.maxY {
            var x = frame.minX
            while x < frame.maxX {
                if let color = pixel(bitmap, CGPoint(x: x, y: y), scale: scale), test(color) { total += 1 }
                x += step
            }
            y += step
        }
        return total
    }

    private func isEmber(_ color: NSColor) -> Bool {
        color.redComponent > 0.85 && color.greenComponent > 0.2 && color.greenComponent < 0.5 && color.blueComponent < 0.3
    }

    /// A lit dot on the void: anything clearly brighter than the ground.
    private func isDot(_ color: NSColor) -> Bool {
        0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent > 0.2
    }

    private func luminance(_ bitmap: NSBitmapImageRep, point: CGPoint, scale: CGFloat) -> CGFloat {
        guard let color = pixel(bitmap, point, scale: scale) else { return -1 }
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }
}

/// The popover under a stand-in menu bar, for design review. The live app shows the same view in
/// a MenuBarExtra window.
private struct HostPopoverReviewScene: View {
    let state: HostViewState
    let now: Date
    var confirmingStop = false
    var activity: HostActivityFeed?

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 16) {
                Spacer()
                Image(nsImage: HostMenuBarIcon.image(for: HostMarkState(status: state.status),
                                                     accessibilityDescription: "Farside"))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(verbatim: "Wi-Fi")
                Text(verbatim: "Tue 9:41")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            HostPopoverView(state: state, actions: .preview, now: now, activity: activity, confirmingStop: confirmingStop)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Farside.Palette.line2, lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 24, y: 14)
        }
        .padding(24)
        .frame(width: 432)
        .background(Color(red: 0.035, green: 0.035, blue: 0.035))
    }
}

/// The four mark states on a light and a dark menu bar, drawn by AppKit image views the way a
/// status item draws them.
private struct HostMenuBarReviewStrip: NSViewRepresentable {
    let cellWidth: CGFloat = 64
    let rowHeight: CGFloat = 30
    var size: CGSize { CGSize(width: cellWidth * CGFloat(HostMarkState.allCases.count), height: rowHeight * 2) }

    func imageFrame(row: Int, column: Int) -> CGRect {
        let image = HostMenuBarIcon.size
        return CGRect(x: CGFloat(column) * cellWidth + (cellWidth - image.width) / 2,
                      y: CGFloat(row) * rowHeight + (rowHeight - image.height) / 2,
                      width: image.width, height: image.height)
    }

    func makeNSView(context: Context) -> NSView {
        let container = FlippedView(frame: NSRect(origin: .zero, size: size))
        for (row, appearanceName) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let bar = FlippedView(frame: NSRect(x: 0, y: CGFloat(row) * rowHeight, width: size.width, height: rowHeight))
            bar.appearance = NSAppearance(named: appearanceName)
            bar.wantsLayer = true
            bar.layer?.backgroundColor = (row == 0 ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.13, alpha: 1)).cgColor
            container.addSubview(bar)
            for (column, state) in HostMarkState.allCases.enumerated() {
                let frame = imageFrame(row: 0, column: column)
                let view = NSImageView(frame: frame)
                view.image = HostMenuBarIcon.image(for: state, accessibilityDescription: "Farside")
                view.imageScaling = .scaleNone
                bar.addSubview(view)
            }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

// Test-only resource-container adaptation of RemoteShared/LegalNoticesView.swift.
// Production SHA256: 6ad6c8fceeaa4fd56a91716bf8c2b45aaf2d662f30f48ef52ceeb9fa4894fccd

private struct HostLegalSnapshotView: View {
    @Environment(\.dismiss) private var dismiss
    private var notices: String {
        guard let url = Bundle(for: HostUISnapshotTests.self).url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Third-party notices are unavailable in this build."
        }
        return text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(notices)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .navigationTitle("Third-Party Notices")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(width: 640, height: 520)
        #endif
    }
}
