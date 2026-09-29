import XCTest
import AppKit
import CoreText

/// The two accent faces, Doto and Instrument Serif Italic, must resolve on macOS by the names the
/// shared theme uses. Without them the display type quietly falls back to the system font.
@MainActor
final class HostFontTests: XCTestCase {
    private func faceNames(in url: URL) -> [String] {
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        return descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
    }

    func testBundledFilesCarryTheFaceNamesTheThemeUses() {
        let urls = HostFonts.bundledURLs()
        XCTAssertEqual(urls.map(\.lastPathComponent), HostFonts.bundledFiles, "A font file is missing from the bundle's Resources")
        let names = urls.flatMap(faceNames)
        XCTAssertTrue(names.contains(Farside.Typeface.dotMatrix), "Doto ExtraBold is registered as \(Farside.Typeface.dotMatrix): \(names)")
        XCTAssertTrue(names.contains(Farside.Typeface.serifItalic), "Instrument Serif Italic: \(names)")
    }

    func testAccentFacesResolveOnMacOS() throws {
        XCTAssertTrue(HostFonts.registerBundledFonts(), "Registering the bundled fonts reported an error")
        XCTAssertTrue(HostFonts.registerBundledFonts(), "Registering twice is harmless")

        let doto = try XCTUnwrap(NSFont(name: Farside.Typeface.dotMatrix, size: 30), "\(Farside.Typeface.dotMatrix) did not resolve")
        let serif = try XCTUnwrap(NSFont(name: Farside.Typeface.serifItalic, size: 30), "\(Farside.Typeface.serifItalic) did not resolve")
        XCTAssertEqual(doto.familyName, "Doto")
        XCTAssertEqual(serif.familyName, "Instrument Serif")
        XCTAssertNotNil(NSFont(name: Farside.Typeface.dotMatrix, size: 13), "Doto resolves at any size")
    }

    func testOFLTextsShipWithTheFonts() throws {
        let bundles = [Bundle.main, Bundle(for: Self.self)]
        for (file, holder) in [("OFL-Doto", "Doto Project Authors"), ("OFL-InstrumentSerif", "Instrument Serif Project Authors")] {
            let url = try XCTUnwrap(bundles.lazy.compactMap { $0.url(forResource: file, withExtension: "txt") }.first,
                                    "\(file).txt is not in the bundle's Resources")
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("SIL OPEN FONT LICENSE Version 1.1"), file)
            XCTAssertTrue(text.contains(holder), "\(file) names its copyright holder")
        }
    }
}
