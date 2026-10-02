import XCTest
import UIKit
@testable import PocketDeskRemote

final class FarsideDesignTests: XCTestCase {
    func testBundledFacesLoadUnderTheNamesTheThemeUses() {
        print("Doto faces:", UIFont.fontNames(forFamilyName: "Doto"), "Instrument Serif faces:",
              UIFont.fontNames(forFamilyName: "Instrument Serif"))
        XCTAssertNotNil(UIFont(name: Farside.Typeface.dotMatrix, size: 30), "Doto must be registered through UIAppFonts")
        XCTAssertNotNil(UIFont(name: Farside.Typeface.serifItalic, size: 30), "Instrument Serif Italic must be registered")
        let doto = UIFont(name: Farside.Typeface.dotMatrix, size: 30)
        XCTAssertEqual(doto?.fontName, Farside.Typeface.dotMatrix)
    }

    func testDisplayHeadingKeepsPunctuationOutOfDoto() {
        let runs = FarsideHeading.runs("Your Mac is far. Your reach isn’t.", accent: "isn’t")
        XCTAssertEqual(runs, [
            .init(kind: .dots, text: "Your Mac is far"),
            .init(kind: .mark, text: "."),
            .init(kind: .dots, text: " Your reach "),
            .init(kind: .accent, text: "isn’t"),
            .init(kind: .mark, text: ".")
        ])
        for run in runs where run.kind == .dots {
            XCTAssertTrue(run.text.allSatisfy(FarsideHeading.isDotSafe), "Doto only ever gets letters, digits and spaces")
        }
    }

    func testFriendlyErrorsExplainWhatTheConnectionReported() {
        XCTAssertEqual(FriendlyError.from(status: "Connection timed out. Check that the Mac is awake and the service is reachable.",
                                          previous: "Connecting securely…", macName: "Studio")?.kind, .unreachable)
        XCTAssertEqual(FriendlyError.from(status: "Connection timed out. Check that the Mac is awake and the service is reachable.",
                                          previous: "Approve this phone on your Mac", macName: "Studio")?.kind, .approvalTimedOut)
        XCTAssertEqual(FriendlyError.from(status: "Connection service: host_unavailable_or_unauthorized. Check the Mac and retry.",
                                          previous: nil, macName: "Studio")?.kind, .unreachable)
        XCTAssertEqual(FriendlyError.from(status: "Connection service: already_connected. Check the Mac and retry.",
                                          previous: nil, macName: "Studio")?.kind, .busy)
        XCTAssertEqual(FriendlyError.from(status: "Pairing was declined on the Mac", previous: nil, macName: "Studio")?.kind, .declined)
        XCTAssertEqual(FriendlyError.from(status: "Secure connection failed. Reconnect or pair again on your Mac.",
                                          previous: nil, macName: "Studio")?.kind, .verifyFailed)
        XCTAssertEqual(FriendlyError.from(status: "Invalid control message. Session ended safely.",
                                          previous: nil, macName: "Studio")?.kind, .sessionGlitch)
        XCTAssertEqual(FriendlyError.from(status: "Connection lost. Tap Connect to try again.",
                                          previous: nil, macName: "Studio")?.kind, .connectionLost)
        XCTAssertNil(FriendlyError.from(status: "Disconnected", previous: nil, macName: "Studio"), "A deliberate stop is not an error")
        XCTAssertNil(FriendlyError.from(status: "Ready to connect", previous: nil, macName: "Studio"))
        XCTAssertFalse(FriendlyError.unreachable("Studio").message.contains("host_unavailable"), "No server codes in copy")
    }

    func testOnlyAReportFromTheMacSaysItIsAsleep() {
        XCTAssertEqual(FriendlyError.from(presence: .sleeping, at: "11:48 PM")?.kind, .napping)
        XCTAssertEqual(FriendlyError.from(presence: .locked, at: nil)?.kind, .locked)
        XCTAssertNil(FriendlyError.from(presence: .displayAsleep, at: nil), "Display sleep keeps the session")
        XCTAssertNotEqual(FriendlyError.unreachable("Studio").kind, .napping, "A timeout never claims the Mac is asleep")
    }

    func testHomeStatusIsHonestAboutContact() {
        XCTAssertEqual(MacStatus("Ready to connect").dot, .idle)
        XCTAssertEqual(MacStatus("Connecting securely…").dot, .busy, "Reaching the service is not contact with the Mac")
        XCTAssertEqual(MacStatus("Authenticating your Mac…").dot, .live, "The Mac answered")
        XCTAssertTrue(MacStatus("Approve this phone on your Mac").needsApproval)
        XCTAssertEqual(MacStatus("Connection service: relay_unavailable. Check the Mac and retry.").tone, .caution)
        XCTAssertFalse(MacStatus("Connection service: relay_unavailable. Check the Mac and retry.").text.contains("relay_unavailable"))
    }

    func testScannerFeedbackNamesTheProblemWithoutAdmittingTheCode() throws {
        XCTAssertEqual(PairingCodeProblem(code: "https://example.com"), .notFarside)
        XCTAssertEqual(PairingCodeProblem(code: "pocketdesk:not-base64!"), .damaged)
        let expired = PairInvitation(server: "wss://relay.example/signal", room: String(repeating: "a", count: 64),
                                     token: String(repeating: "b", count: 64), key: Data(repeating: 1, count: 32),
                                     expires: Date(timeIntervalSinceNow: -60), name: "Studio")
        let code = try expired.code()
        XCTAssertThrowsError(try PairInvitation.parse(code), "Expired codes stay rejected by pairing itself")
        XCTAssertEqual(PairingCodeProblem(code: code), .expired)
    }

    @MainActor
    func testPrimingIsExplainedOnceAndNeverDuringUITests() {
        let defaults = UserDefaults(suiteName: "FarsideDesignTests")!
        defaults.removePersistentDomain(forName: "FarsideDesignTests")
        XCTAssertTrue(PermissionPrimer.needsPriming(.localNetwork, in: defaults))
        PermissionPrimer.markPrimed(.localNetwork, in: defaults)
        XCTAssertFalse(PermissionPrimer.needsPriming(.localNetwork, in: defaults))
        defaults.removePersistentDomain(forName: "FarsideDesignTests")
    }

    @MainActor
    func testMicrophoneDoesNotPrimeAgainWhilePermissionsAreStillUndetermined() {
        let suiteName = "FarsideDesignTests.microphone.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(PermissionPrimer.needsPriming(.microphone, in: defaults,
                                                    microphoneNeedsAuthorization: { true }))
        PermissionPrimer.markPrimed(.microphone, in: defaults)
        XCTAssertFalse(PermissionPrimer.needsPriming(.microphone, in: defaults,
                                                     microphoneNeedsAuthorization: { true }),
                       "Continue must reach the iOS prompts even while permissions are undetermined")
    }

    @MainActor
    func testMoveLessonCompletesEvenWhenThePadResizesMidAttempt() {
        let coach = GestureCoachModel()
        coach.layout(CGSize(width: 350, height: 392))
        coach.start()
        let start = coach.pointer

        steer(coach, to: coach.target)
        XCTAssertTrue(coach.targetDodged, "First arrival makes the pixel dodge once")
        XCTAssertFalse(coach.passed)
        let pointerAfterDodge = coach.pointer

        // The dodge note appears and the pad shrinks; the lesson must not restart.
        coach.layout(CGSize(width: 350, height: 372))
        XCTAssertTrue(coach.targetDodged, "A resize keeps the dodge")
        XCTAssertNotEqual(coach.pointer, start, "A resize doesn't send the pointer back to the start")
        XCTAssertEqual(coach.pointer.x, pointerAfterDodge.x, accuracy: 0.5)

        steer(coach, to: coach.target)
        XCTAssertTrue(coach.passed, "Second arrival on the pixel passes the lesson")
    }

    @MainActor
    func testEveryLessonCanBePassedThroughItsOwnGestures() {
        let coach = GestureCoachModel()
        coach.layout(CGSize(width: 350, height: 392))
        coach.start()
        steer(coach, to: coach.target)
        steer(coach, to: coach.target)
        XCTAssertTrue(coach.passed, "Move")
        coach.advance()

        XCTAssertTrue(coach.handle(.click(count: 1)))
        XCTAssertTrue(coach.passed, "Click")
        coach.advance()

        for _ in 0..<40 { _ = coach.handle(.scroll(delta: CGSize(width: 0, height: -20), phase: "changed", stream: "s")) }
        XCTAssertTrue(coach.passed, "Scroll")
        coach.advance()

        XCTAssertEqual(coach.lesson, .drag)
        _ = coach.handle(.dragBegan(id: "d", count: 1))
        steer(coach, to: CGPoint(x: coach.folderFrame.midX, y: coach.folderFrame.midY))
        _ = coach.handle(.dragEnded(id: "d"))
        XCTAssertTrue(coach.passed, "Drag")
        coach.advance()

        _ = coach.handle(.zoom(factor: 2.5, anchor: .zero))
        XCTAssertTrue(coach.passed, "Zoom")
        coach.advance()
        XCTAssertTrue(coach.finished)
    }

    /// Moves the coach pointer toward a point in small steps, like a finger would.
    @MainActor
    private func steer(_ coach: GestureCoachModel, to goal: CGPoint) {
        for _ in 0..<200 {
            if coach.passed { return }
            let dx = goal.x - coach.pointer.x, dy = goal.y - coach.pointer.y
            let distance = hypot(dx, dy)
            if distance < 2 { return }
            let step = min(6, distance)
            let before = coach.target
            _ = coach.handle(.move(CGSize(width: dx / distance * step, height: dy / distance * step)))
            if coach.target != before { return }
        }
    }

    @MainActor
    func testCoachZoomAcceptsTheRealFingerPinchCommand() {
        let key = "accessibility.adaptiveLayoutsEnabled"
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let coach = GestureCoachModel()
        coach.layout(CGSize(width: 350, height: 300))
        coach.start()
        for _ in 0..<4 { coach.advance() }
        let input = NativeGestureEngine(enabled: true, panMode: false, revision: 4, sensitivity: 1,
                                        pointerScale: 1, doubleClickInterval: 0.5, onCommand: coach.handle)
        func fingers(_ left: CGFloat, _ right: CGFloat) -> [NativeGestureEngine.Touch] {
            [.init(id: 1, point: CGPoint(x: left, y: 150)),
             .init(id: 2, point: CGPoint(x: right, y: 150))]
        }
        input.update(fingers(125, 225), at: 1)
        input.update(fingers(75, 275), at: 1.1)
        input.update(fingers(50, 300), at: 1.2)
        input.update([], at: 1.3)
        XCTAssertTrue(coach.passed, "Finger pinches must unlock Finish through the production engine")
        XCTAssertEqual(coach.zoom, 2.5, accuracy: 0.01)
    }

    @MainActor
    func testCoachLessonsRunOnALocalPadAndAdvanceInOrder() {
        let coach = GestureCoachModel()
        coach.layout(CGSize(width: 350, height: 392))
        coach.start()
        XCTAssertEqual(coach.lesson, .move)
        let start = coach.pointer
        XCTAssertTrue(coach.handle(.move(CGSize(width: 10, height: -4))))
        XCTAssertEqual(coach.pointer, CGPoint(x: start.x + 10, y: start.y - 4), "Moves stay on the practice pad")
        coach.advance()
        XCTAssertEqual(coach.lesson, .click)
        XCTAssertTrue(coach.handle(.click(count: 1)), "The pointer starts on Yes, so a tap anywhere clicks it")
        XCTAssertTrue(coach.passed)
        coach.advance()
        XCTAssertEqual(coach.lesson, .scroll)
        for _ in 0..<40 { _ = coach.handle(.scroll(delta: CGSize(width: 0, height: -20), phase: "changed", stream: "s")) }
        XCTAssertTrue(coach.passed)
        coach.advance(); coach.advance()
        XCTAssertEqual(coach.lesson, .zoom)
        _ = coach.handle(.zoom(factor: 2.5, anchor: .zero))
        XCTAssertTrue(coach.passed)
        coach.advance()
        XCTAssertTrue(coach.finished)
    }
}
