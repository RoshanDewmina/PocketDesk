import XCTest
import AppIntentsTesting

/// The intents run the way Siri, Shortcuts and Spotlight run them: through the system, against the
/// installed app, not by calling `perform()` in-process. The app is launched with a paired Mac that
/// lives only in memory, so the run needs no Keychain and pairs nothing for real.
@available(iOS 27.0, *)
final class IntentsSystemUITests: XCTestCase {
    private let bundleIdentifier = "com.roshan.PocketDesk.Remote"

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-seed-pairing=Studio Mac", "--ui-x"] + extra
        app.launch()
        return app
    }

    @MainActor
    func testTheMacParameterOffersTheOnePairedMacByName() async throws {
        launch()
        let definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)
        let macs = try await definitions.entities["MacEntity"].allEntities()
        XCTAssertEqual(macs.count, 1, "One Mac is paired")
        let name: String = try macs[0].name
        XCTAssertEqual(name, "Studio Mac")
    }

    @MainActor
    func testIsMyMacAwakeAnswersWithAStateAndNeverOpensASession() async throws {
        let app = launch(["--ui-mac-status=awake"])
        let definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)

        let named = try await definitions.intents["MacStatusIntent"].makeIntent(mac: try await definitions.entities["MacEntity"].allEntities()[0]).run()
        let namedState: String = try named.value
        XCTAssertEqual(namedState, "awake")

        let unnamed = try await definitions.intents["MacStatusIntent"].makeIntent().run()
        let unnamedState: String = try unnamed.value
        XCTAssertEqual(unnamedState, "awake", "With one Mac paired nothing is asked")
        XCTAssertNotEqual(app.state, .notRunning)
    }

    @MainActor
    func testEndSessionRunsWithNoSessionAndSaysSo() async throws {
        launch()
        let definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)
        try await definitions.intents["EndSessionIntent"].makeIntent().run()
    }
}
