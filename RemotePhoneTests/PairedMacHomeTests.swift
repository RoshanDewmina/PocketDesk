import XCTest
@testable import PocketDeskRemote

final class PairedMacHomeTests: XCTestCase {
    private func invitation() throws -> PairInvitation {
        try HostPair.create(server: "wss://fixture.invalid/signal", name: "Fixture").invitation
    }
    func testSavedMacWithoutSelectionOffersChoiceWithoutInferringDestination() throws {
        let a = try invitation(), b = try invitation()
        let saved = [PairedMac(id: "a", name: a.name, invitation: a), PairedMac(id: "b", name: b.name, invitation: b)]
        XCTAssertEqual(SavedMacHomeState(selected: b, saved: saved), .selected)
        XCTAssertEqual(SavedMacHomeState(selected: nil, saved: [saved[0]]), .choose)
        XCTAssertEqual(SavedMacHomeState(selected: nil, saved: []), .empty)
        XCTAssertEqual(saved[0].invitation, a, "Home presentation never changes saved credentials")
    }
    func testLegacyPairingRemainsReadableButLabelsMissingLocalAndShareIdentity() throws {
        let old = try invitation()
        XCTAssertNoThrow(try old.validate(enrollment: false))
        XCTAssertFalse(old.hasOwnerLocalIdentity)
        XCTAssertEqual(PairedMac(id: "old", name: old.name, invitation: old).pairingRefreshNote,
                       "Older pairing · re-pair for sharing and local access")
        XCTAssertTrue(RemoteError.localPairingRefreshRequired.localizedDescription.contains("fresh owner-approved QR"))
        XCTAssertFalse(RemoteError.localPairingRefreshRequired.localizedDescription.contains("expired"))
    }
    func testIdentifiedPairNeedsEveryLocalIdentityAndNeverObtainsItFromName() throws {
        var current = try invitation()
        current.durableHostID = try SecureRandom.token(); current.ownerPairID = try SecureRandom.token()
        current.localServiceName = "fixture"
        XCTAssertTrue(current.hasOwnerLocalIdentity)
        XCTAssertNil(PairedMac(id: "current", name: current.name, invitation: current).pairingRefreshNote)
        var incomplete = current; incomplete.localServiceName = nil
        XCTAssertFalse(incomplete.hasOwnerLocalIdentity)
        XCTAssertEqual(PairedMac(id: "incomplete", name: incomplete.name, invitation: incomplete).pairingRefreshNote,
                       "Older pairing · re-pair for local access")
        let legacy = try invitation()
        XCTAssertEqual(legacy.name, current.name)
        XCTAssertNil(legacy.durableHostID); XCTAssertNil(legacy.ownerPairID)
        XCTAssertFalse(legacy.hasOwnerLocalIdentity)
    }
}
