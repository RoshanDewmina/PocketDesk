import XCTest

final class AwayPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func readout(_ phase: HostAwayReadout.Phase = .off,
                         change: (inout HostAwayReadout) -> Void = { _ in }) -> HostAwayReadout {
        var readout = HostAwayReadout()
        readout.available = true
        readout.enabled = true
        readout.phase = phase
        change(&readout)
        return readout
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: Fixed copy

    func testSettingAndButtonCopy() {
        XCTAssertEqual(HostAwayCopy.settingTitle, "Away mode")
        XCTAssertEqual(HostAwayCopy.settingSubtitle,
                       "Keep this Mac unlocked for your iPhone while you’re away. The screen is covered and the Mac locks if anyone touches it.")
        XCTAssertEqual(HostAwayCopy.introTitle, "Turn on Away mode?")
        XCTAssertEqual(HostAwayCopy.introConfirm, "Turn On Away Mode")
        XCTAssertEqual(HostAwayCopy.introCancel, "Cancel")
        XCTAssertEqual(HostAwayCopy.coverNowTitle, "Cover now")
        XCTAssertEqual(HostAwayCopy.turnOffTitle, "Turn off")
        XCTAssertEqual(HostAwayCopy.lockScreenSettingsTitle, "Lock Screen Settings…")
        XCTAssertEqual(HostAwayCopy.dismissTitle, "Dismiss")
        XCTAssertEqual(HostAwayCopy.keepAwakeSubtitle,
                       "While sharing is on. Your iPhone can reach this Mac only while it’s awake and unlocked.")
    }

    func testIntroBodyIsTheSpecsThreeParagraphs() {
        XCTAssertEqual(HostAwayCopy.introBody, [
            "While Away mode and sharing are both on, Farside keeps this Mac awake and unlocked so you can reach it from your iPhone. After 2 minutes with nobody using it, Farside covers the screen. If anyone touches the keyboard, mouse or trackpad, the Mac locks straight away, and you unlock it with your password as usual.",
            "What it can’t do: keep a MacBook awake with the lid closed (unless it’s on power with an external display, keyboard and mouse); survive a power cut, restart or macOS update (after a restart, someone has to sign in at the Mac); unlock a Mac that’s already locked; or hide notification sounds. It never changes your security settings, and Farside never sees your password.",
            "Away mode needs power. On battery it ends after 5 minutes and the Mac locks. It also ends, and locks the Mac, after 24 hours without a phone connection."
        ])
    }

    func testLockScreenLinkIsTheLockScreenPane() {
        XCTAssertEqual(HostAwayCopy.lockScreenSettingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")
    }

    // MARK: Status line

    func testArmedStatusCountsDownToTheCover() {
        let armed = readout(.armed) { $0.coversAt = self.now.addingTimeInterval(100) }
        XCTAssertEqual(HostAwayCopy.statusLine(armed, now: now), "Away mode · covers in 1:40")
    }

    func testArmedCountdownNeverGoesNegative() {
        let late = readout(.armed) { $0.coversAt = self.now.addingTimeInterval(-5) }
        XCTAssertEqual(HostAwayCopy.statusLine(late, now: now), "Away mode · covers in 0:00")
    }

    func testCoveredStatus() {
        XCTAssertEqual(HostAwayCopy.statusLine(readout(.covered), now: now), "Away · covered, locks if touched")
    }

    func testLockingStatus() {
        XCTAssertEqual(HostAwayCopy.statusLine(readout(.locking), now: now), "Away · locking this Mac…")
    }

    func testLockFailedStatus() {
        XCTAssertEqual(HostAwayCopy.statusLine(readout(.lockFailed), now: now),
                       "Away · couldn’t lock this Mac. It locks when the display sleeps.")
    }

    func testNoStatusWhenOffOrUnavailable() {
        XCTAssertNil(HostAwayCopy.statusLine(readout(.off), now: now))
        XCTAssertNil(HostAwayCopy.statusLine(readout(.off) { $0.unavailable = .sharingOff }, now: now))
        XCTAssertNil(HostAwayCopy.statusLine(readout(.off) { $0.enabled = false }, now: now))
        XCTAssertNil(HostAwayCopy.statusLine(readout(.armed) {
            $0.available = false
            $0.coversAt = self.now.addingTimeInterval(100)
        }, now: now))
    }

    // MARK: Warning line

    func testBatteryWarningCountsDownToTheEnd() {
        let onBattery = readout(.armed) {
            $0.coversAt = self.now.addingTimeInterval(100)
            $0.batteryEndsAt = self.now.addingTimeInterval(252)
        }
        XCTAssertEqual(HostAwayCopy.warningLine(onBattery, now: now), "On battery — Away mode ends in 4:12")
    }

    func testManagedWarning() {
        XCTAssertEqual(HostAwayCopy.warningLine(readout { $0.unavailable = .managed }, now: now),
                       "Your organisation manages this Mac’s lock settings — Away mode unavailable")
    }

    func testNeedsAccessibilityWarning() {
        XCTAssertEqual(HostAwayCopy.warningLine(readout { $0.unavailable = .needsAccessibility }, now: now),
                       "Needs Accessibility")
    }

    func testOnBatteryWarning() {
        XCTAssertEqual(HostAwayCopy.warningLine(readout { $0.unavailable = .onBattery }, now: now),
                       "Connect power to use Away mode")
    }

    func testSharingOffWarning() {
        XCTAssertEqual(HostAwayCopy.warningLine(readout { $0.unavailable = .sharingOff }, now: now),
                       "Starts when sharing is on")
    }

    func testSafeModeWarning() {
        XCTAssertEqual(HostAwayCopy.warningLine(readout { $0.unavailable = .safeMode }, now: now),
                       "Paused after repeated crashes")
    }

    func testMacLockedHasNoWarning() {
        XCTAssertNil(HostAwayCopy.warningLine(readout { $0.unavailable = .macLocked }, now: now))
        XCTAssertNil(HostAwayCopy.warningLine(readout {
            $0.unavailable = .macLocked
            $0.lowPowerMode = true
        }, now: now))
    }

    func testLowPowerModeIsTheLowestPriorityWarning() {
        XCTAssertEqual(HostAwayCopy.warningLine(readout(.armed) { $0.lowPowerMode = true }, now: now),
                       "Low Power Mode is on")
        XCTAssertEqual(HostAwayCopy.warningLine(readout(.armed) {
            $0.lowPowerMode = true
            $0.batteryEndsAt = self.now.addingTimeInterval(252)
        }, now: now), "On battery — Away mode ends in 4:12")
        XCTAssertEqual(HostAwayCopy.warningLine(readout {
            $0.lowPowerMode = true
            $0.unavailable = .onBattery
        }, now: now), "Connect power to use Away mode")
        XCTAssertNil(HostAwayCopy.warningLine(readout(.armed), now: now))
    }

    func testNoWarningWhileAwayModeIsOff() {
        XCTAssertNil(HostAwayCopy.warningLine(readout {
            $0.enabled = false
            $0.lowPowerMode = true
        }, now: now))
    }

    func testNothingShowsWhenTheGateIsOff() {
        for phase: HostAwayReadout.Phase in [.off, .armed, .covered, .locking, .lockFailed] {
            let gated = readout(phase) {
                $0.available = false
                $0.coversAt = self.now.addingTimeInterval(100)
                $0.batteryEndsAt = self.now.addingTimeInterval(252)
                $0.lowPowerMode = true
            }
            XCTAssertNil(HostAwayCopy.statusLine(gated, now: now), "\(phase)")
            XCTAssertNil(HostAwayCopy.warningLine(gated, now: now), "\(phase)")
        }
        for reason in AwayUnavailableReason.allCases {
            XCTAssertNil(HostAwayCopy.warningLine(readout {
                $0.available = false
                $0.unavailable = reason
            }, now: now), "\(reason)")
        }
    }

    func testCopyNeverClaimsLockedOrSecureWhileArmed() {
        let lines = [
            HostAwayCopy.statusLine(readout(.armed) { $0.coversAt = self.now.addingTimeInterval(100) }, now: now),
            HostAwayCopy.statusLine(readout(.covered), now: now)
        ]
        for line in lines {
            guard let lowered = line?.lowercased() else { return XCTFail("Armed and covered always show a status") }
            XCTAssertFalse(lowered.contains("locked"), lowered)
            XCTAssertFalse(lowered.contains("secure"), lowered)
        }
    }

    // MARK: Countdown

    func testCountdownFormatting() {
        XCTAssertEqual(HostAwayCopy.countdown(0), "0:00")
        XCTAssertEqual(HostAwayCopy.countdown(100), "1:40")
        XCTAssertEqual(HostAwayCopy.countdown(252), "4:12")
        XCTAssertEqual(HostAwayCopy.countdown(3600), "60:00")
        XCTAssertEqual(HostAwayCopy.countdown(-5), "0:00")
    }

    // MARK: Lock warning

    func testLockedWhileSharingPointsToAwayModeOnlyWhenAvailable() {
        let at = now
        let base = "Your Mac locked at \(time(at)) while sharing, so your iPhone couldn’t reach it. Farside can’t unlock it. To stay reachable, keep this Mac awake and unlocked"
        XCTAssertEqual(HostAwayCopy.lockWarningText(.lockedWhileSharing(at: at), awayAvailable: true),
                       base + ", or turn on Away mode.")
        XCTAssertEqual(HostAwayCopy.lockWarningText(.lockedWhileSharing(at: at), awayAvailable: false),
                       base + ".")
    }

    func testScreenSaverLockSaysWhetherAwayModeWasOn() {
        let at = now
        let tail = ". To stay reachable, change when the screen saver starts or when a password is required in Lock Screen settings."
        XCTAssertEqual(HostAwayCopy.lockWarningText(.screenSaverLocked(at: at, awayArmed: false), awayAvailable: true),
                       "Your Mac’s screen saver locked it at \(time(at))" + tail)
        XCTAssertEqual(HostAwayCopy.lockWarningText(.screenSaverLocked(at: at, awayArmed: true), awayAvailable: true),
                       "Your Mac’s screen saver locked it at \(time(at)) while Away mode was on" + tail)
    }

    func testLockWarningsNeverSuggestRemovingThePassword() {
        let warnings: [HostLockWarning] = [
            .lockedWhileSharing(at: now),
            .screenSaverLocked(at: now, awayArmed: false),
            .screenSaverLocked(at: now, awayArmed: true)
        ]
        for warning in warnings {
            for available in [true, false] {
                let text = HostAwayCopy.lockWarningText(warning, awayAvailable: available).lowercased()
                XCTAssertFalse(text.contains("disable"), text)
                XCTAssertFalse(text.contains("turn off"), text)
                XCTAssertFalse(text.contains("remove"), text)
            }
        }
    }
}
