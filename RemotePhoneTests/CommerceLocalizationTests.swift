import XCTest
@testable import PocketDeskRemote

final class CommerceLocalizationTests: XCTestCase {
    func testFrenchFormatsCompletePriceAndRenewalTermsWithoutEnglishPeriodAssembly() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "fr", ofType: "lproj"))
        let french = try XCTUnwrap(Bundle(path: path))
        let price = CommerceLocalization.text("PRICE_YEAR", "%@ a year", "59,99 $", bundle: french, locale: Locale(identifier: "fr_CA"))
        XCTAssertEqual(price, "59,99 $ par an")
        let disclosure = CommerceLocalization.text("DISCLOSURE_TRIAL_YEAR", "fallback", "7 jours", "59,99 $", bundle: french, locale: Locale(identifier: "fr_CA"))
        for part in ["7 jours", "59,99 $ par an", "24 heures", "Compte Apple", "cinq", "réseau local vérifié"] {
            XCTAssertTrue(disclosure.contains(part), part)
        }
        XCTAssertFalse(disclosure.contains("a year")); XCTAssertFalse(disclosure.contains("%@"))
        XCTAssertEqual(CommerceLocalization.text("YEAR_SAVING", "Save %ld%%", 37, bundle: french, locale: Locale(identifier: "fr_CA")), "Économisez 37%")
    }
    func testMissingTranslationUsesCompleteFallbackAndDoesNotChangeStorefrontPrice() {
        XCTAssertEqual(CommerceLocalization.text("MISSING_FIXTURE_KEY", "%@ a month", "€8,49", bundle: .main, locale: Locale(identifier: "fr_CA")), "€8,49 a month")
    }
}
