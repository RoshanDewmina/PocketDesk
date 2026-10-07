import XCTest

/// Base class for every physical test that clicks, types, pastes or switches apps on the Mac.
/// Only `script/physical/run.sh --mac-input` runs these: one test per run, after the Mac has been unlocked
/// and untouched for 120 s, stopped the moment someone uses the Mac. The gate is final so a subclass cannot
/// skip it; put per-test setup in `setUpMacInput()`.
class PhysicalMacInputTestCase: XCTestCase {
    final override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FARSIDE_PHYSICAL_LIFECYCLE_SMOKE"] == "1", environment["FARSIDE_PHYSICAL_MAC_INPUT"] == "1" else {
            throw XCTSkip("Sends input to the Mac: run only through script/physical/run.sh --mac-input")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("A simulator is not physical Mac-input acceptance")
        #else
        try super.setUpWithError()
        continueAfterFailure = false
        try setUpMacInput()
        #endif
    }

    func setUpMacInput() throws {}
}
