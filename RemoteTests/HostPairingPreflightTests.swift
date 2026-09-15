import XCTest
import CoreGraphics

final class HostPairingPreflightTests: XCTestCase {
    func testInvitationCreationRequiresTheSelectedLoadedDisplay() {
        var creationCount = 0
        let create = {
            creationCount += 1
            return "invitation"
        }

        let withoutDisplays = HostPairingPreflight.createInvitation(
            selectedDisplayID: 0,
            availableDisplayIDs: [],
            create: create
        )
        XCTAssertNil(withoutDisplays)
        XCTAssertEqual(creationCount, 0, "Missing display state must not rotate or save pairing credentials")

        let staleSelection = HostPairingPreflight.createInvitation(
            selectedDisplayID: 7,
            availableDisplayIDs: [8],
            create: create
        )
        XCTAssertNil(staleSelection)
        XCTAssertEqual(creationCount, 0, "A display ID lost after restart must fail before invitation creation")

        let eligible = HostPairingPreflight.createInvitation(
            selectedDisplayID: 7,
            availableDisplayIDs: [7, 8],
            create: create
        )
        XCTAssertEqual(eligible, "invitation")
        XCTAssertEqual(creationCount, 1)
    }
}
