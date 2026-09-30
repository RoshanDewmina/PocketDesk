import XCTest
@testable import PocketDeskRemote

final class PhoneSystemAudioDeviceTests: XCTestCase {
    func testNativeRecordingRequestsAreRefusedAcrossLifecycle() {
        let device = PhoneSystemAudioDevice()
        XCTAssertFalse(device.isRecordingInitialized)
        XCTAssertFalse(device.initializeRecording())
        XCTAssertFalse(device.startRecording())
        XCTAssertFalse(device.isRecording)
        device.setConsent(true)
        XCTAssertFalse(device.initializeRecording())
        XCTAssertFalse(device.startRecording())
        XCTAssertFalse(device.isRecording)
        XCTAssertTrue(device.stopRecording())
        XCTAssertTrue(device.terminateDevice())
        XCTAssertFalse(device.isInitialized)
        XCTAssertFalse(device.startRecording())
        XCTAssertFalse(device.isRecording)
    }
}
