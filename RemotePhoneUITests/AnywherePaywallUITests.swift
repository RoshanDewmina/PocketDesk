import XCTest

/// Farside Anywhere in the running app: reachable without a Mac (Guideline 2.1(b)), price, period,
/// trial and renewal terms on screen before the buy button (3.1.2(c)), Restore, Terms and Privacy,
/// and an honest way out. Products come from the scheme's StoreKit configuration file. Purchases
/// themselves are covered by the SKTestSession unit tests, which do not need the system sheet.
final class AnywherePaywallUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testPaywallFromHomeWithoutAMacShowsTermsBeforeBuying() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-anywhere"]
        app.launch()

        let row = app.buttons["home.anywhere"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Home offers Farside Anywhere with no Mac paired")
        XCTAssertTrue(row.label.contains("Farside Anywhere"), row.label)
        XCTAssertTrue(row.label.contains("Verified local access free"), row.label)
        row.tap()

        let yearly = app.buttons["anywhere.plan.yearly"]
        XCTAssertTrue(yearly.waitForExistence(timeout: 15), "Plans load from the StoreKit configuration")
        let monthly = app.buttons["anywhere.plan.monthly"]
        XCTAssertTrue(yearly.label.contains("59.99"), yearly.label)
        XCTAssertTrue(monthly.label.contains("7.99"), monthly.label)
        XCTAssertTrue(yearly.isSelected, "Yearly is the default choice")
        attach(app, "paywall")

        let summary = app.staticTexts["anywhere.summary"]
        let subscribe = app.buttons["anywhere.subscribe"]
        XCTAssertTrue(summary.exists && subscribe.exists)
        XCTAssertTrue(summary.label.contains("7-day free trial, then"), summary.label)
        XCTAssertTrue(summary.label.contains("59.99 a year"), summary.label)
        XCTAssertTrue(summary.label.contains("Renews automatically"), summary.label)
        XCTAssertEqual(subscribe.label, "Start 7-day free trial")
        XCTAssertTrue(summary.isHittable && subscribe.isHittable, "Terms and the button are both on screen")
        XCTAssertLessThan(summary.frame.maxY, subscribe.frame.minY, "The terms sit above the button")
        XCTAssertFalse(subscribe.isEnabled, "The fixture has no verification service, so a charge cannot start")
        XCTAssertTrue(app.descendants(matching: .any)["anywhere.purchaseUnavailable"].exists)

        // On a phone-height sheet the second plan starts below the fixed purchase bar. XCTest can
        // resolve the offscreen button but tap the bar's coordinate instead, opening StoreKit.
        let plansScroll = app.scrollViews.firstMatch
        for _ in 0..<5 where monthly.frame.maxY >= summary.frame.minY - 8 || !monthly.isHittable {
            plansScroll.swipeUp()
        }
        XCTAssertTrue(monthly.isHittable)
        XCTAssertLessThan(monthly.frame.maxY, summary.frame.minY - 8, "The plan must be above the purchase bar before tapping")
        monthly.tap()
        let monthlySummary = NSPredicate(format: "label CONTAINS %@", "7.99 a month")
        expectation(for: monthlySummary, evaluatedWith: summary)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(monthly.isSelected)
        XCTAssertTrue(summary.label.contains("7.99 a month"), summary.label)

        let disclosure = app.staticTexts["anywhere.disclosure"]
        XCTAssertTrue(disclosure.exists)
        for part in ["renews automatically until you cancel", "24 hours before", "Settings › Apple Account › Subscriptions"] {
            XCTAssertTrue(disclosure.label.contains(part), "Missing “\(part)”: \(disclosure.label)")
        }
        let restore = app.buttons["anywhere.restore"]
        let terms = app.buttons["anywhere.terms"]
        let privacy = app.buttons["anywhere.privacy"]
        for _ in 0..<3 where !privacy.isHittable { app.swipeUp() }
        XCTAssertTrue(restore.isHittable, "Restore Purchases is visible")
        XCTAssertTrue(terms.isHittable, "Terms of Use link is visible")
        XCTAssertTrue(privacy.isHittable, "Privacy Policy link is visible")
        XCTAssertTrue(app.buttons["anywhere.redeem"].exists, "Offer codes remain discoverable")
        attach(app, "paywall-terms")

        app.buttons["anywhere.notNow"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(subscribe.exists, "Not now closes the sheet")
    }

    @MainActor
    func testHelpMenuOpensAnywhereAndCloseReturnsHome() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-anywhere"]
        app.launch()
        let help = app.buttons["Help and more"]
        XCTAssertTrue(help.waitForExistence(timeout: 10))
        help.tap()
        app.buttons["Farside Anywhere"].tap()
        let close = app.buttons["anywhere.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["anywhere.restore"].exists)
        close.tap()
        XCTAssertTrue(app.buttons["home.anywhere"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testServiceAskingForAnywhereExplainsAndOffersIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-demo-mac", "--ui-error=needsPlan"]
        app.launch()
        let primary = app.buttons["error.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["error.secondary"].exists, "Trying again on the Mac's Wi-Fi stays available")
        XCTAssertTrue(primary.label == "See Farside Anywhere" || primary.label.hasSuffix("free trial"), primary.label)
        attach(app, "needs-plan")
        primary.tap()
        XCTAssertTrue(app.buttons["anywhere.notNow"].waitForExistence(timeout: 10), "The plan sheet opens")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
