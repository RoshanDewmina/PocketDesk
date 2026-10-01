import XCTest
@testable import PocketDeskRemote

@MainActor
final class DataUseNoticeTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "farside.tests.dataWarning." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var cellular: NetworkLinkHint { NetworkLinkHint.from(.init(cellular: true))! }

    func testGateOffersOnceThenPersistsAcrossInstancesWithInjectedDefaults() {
        let gate = DataWarningGate(defaults: defaults)
        XCTAssertFalse(gate.shouldOffer(metered: false))
        XCTAssertTrue(gate.shouldOffer(metered: true))
        gate.markSeen()
        XCTAssertFalse(gate.shouldOffer(metered: true))
        XCTAssertFalse(DataWarningGate(defaults: defaults).shouldOffer(metered: true))
    }

    func testMeteredRouteShowsNonBlockingNoticeOnceAndUseLessDataLowersThePreset() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(), dataWarningDefaults: defaults)
        model.prepareConnection(mode: .picture)
        model.connection.connected = true
        model.streamQuality = .sharp
        model.observeLinkHint(nil)
        XCTAssertNil(model.dataWarning)
        model.observeLinkHint(cellular)
        let warning = try XCTUnwrap(model.dataWarning)
        XCTAssertEqual(warning.lessData, .balanced)
        XCTAssertTrue(warning.message.contains("Sharper"), warning.message)
        XCTAssertTrue(model.connection.connected, "The notice never stops the session")
        model.useLessData()
        XCTAssertEqual(model.streamQuality, .balanced)
        XCTAssertNil(model.dataWarning)
        XCTAssertTrue(DataWarningGate(defaults: defaults).seen)
        model.observeLinkHint(nil); model.observeLinkHint(cellular)
        XCTAssertNil(model.dataWarning, "Dismissed once, never again")
        let relaunched = PhoneRemoteModel(background: FakeBackgroundExecution(), dataWarningDefaults: defaults)
        relaunched.observeLinkHint(cellular)
        XCTAssertNil(relaunched.dataWarning)
    }

    func testKeepLeavesThePresetAndLowestPresetOffersNoDowngrade() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(), dataWarningDefaults: defaults)
        model.streamQuality = .balanced
        model.observeLinkHint(cellular)
        XCTAssertNil(try XCTUnwrap(model.dataWarning).lessData)
        model.keepDataQuality()
        XCTAssertEqual(model.streamQuality, .balanced)
        XCTAssertTrue(DataWarningGate(defaults: defaults).seen)
    }

    func testEveryPresetHasLocalizedEstimateCopyAndSpokenLabel() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "fr", ofType: "lproj"))
        let french = try XCTUnwrap(Bundle(path: path))
        let english = Locale(identifier: "en_US"), canadian = Locale(identifier: "fr_CA")
        let expected: [StreamQuality: (String, String)] = [.balanced: ("Responsive: about 0.1–5.4 GB per hour", "Responsive : environ 0,1 à 5,4 Go par heure"),
                                                           .sharp: ("Sharper: about 0.2–11 GB per hour", "Sharper : environ 0,2 à 11 Go par heure")]
        for quality in StreamQuality.allCases {
            let estimate = DataUseEstimate(quality, audio: false, packetRepair: false)
            XCTAssertEqual(DataUseCopy.presetLine(quality, estimate, locale: english), expected[quality]?.0)
            XCTAssertEqual(DataUseCopy.presetLine(quality, estimate, bundle: french, locale: canadian), expected[quality]?.1)
            XCTAssertTrue(DataUseCopy.presetSpoken(quality, estimate, locale: english).contains("gigabytes per hour"))
            XCTAssertFalse(DataUseCopy.presetSpoken(quality, estimate, locale: english).contains("–"))
        }
        XCTAssertTrue(DataUseCopy.note(locale: english).contains("Files and guest viewers are counted separately"))
        XCTAssertTrue(DataUseCopy.note(locale: english).contains("20%"))
        XCTAssertTrue(DataUseCopy.note(bundle: french, locale: canadian).contains("20 %"))
    }
}
