import XCTest

final class PhoneAwayTests: XCTestCase {
    private func host(_ record: String = "a", grant: String? = String(repeating: "b", count: 64)) -> PhoneHostTrust {
        let invite = PairInvitation(server: "wss://example.com/signal", room: String(repeating: "c", count: 64),
            token: String(repeating: "d", count: 64), key: Data(repeating: 1, count: 32), expires: Date(), name: "Mac",
            durableHostID: String(repeating: "e", count: 64), ownerPairID: grant)
        return PhoneHostTrust(id: String(repeating: record, count: 64), durableHostID: invite.durableHostID,
            ownerPairID: grant, invitation: invite, legacyAliases: [])
    }
    func testHistoricalAwayIsExactRecordGrantAndServerBoundAndCannotReadRoomAlias() {
        let suite = "away-memory-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = AwayMemory(defaults: defaults)
        var a = host(); let b = host("f")
        defaults.set([String(SecureRandom.digest("farside-away|" + a.invitation.room).prefix(24)): "covered"], forKey: "awayLastKnownByMac")
        XCTAssertFalse(memory.wasOn(host: a))
        memory.remember(.covered, host: a)
        XCTAssertTrue(memory.wasOn(host: a)); XCTAssertFalse(memory.wasOn(host: b))
        a.ownerPairID = String(repeating: "f", count: 64)
        XCTAssertFalse(memory.wasOn(host: a))
        a = host(); a.invitation.server = "wss://other.example/signal"
        XCTAssertFalse(memory.wasOn(host: a))
        let serialized = String(describing: defaults.dictionary(forKey: AwayMemory.defaultsKey))
        XCTAssertFalse(serialized.contains(host().invitation.token))
        XCTAssertFalse(serialized.contains(host().invitation.room))
    }
    func testLegacyMemoryTracksExactCredentialAndNeverPromotesRoomToIdentity() {
        let suite = "away-legacy-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = AwayMemory(defaults: defaults)
        var old = host(grant: nil)
        memory.remember(.armed, host: old)
        old.invitation.key = Data(repeating: 2, count: 32)
        XCTAssertFalse(memory.wasOn(host: old))
    }
    func testPendingLockRejectsWrongHostGrantSessionEpochAndExpiredOrNonfiniteTime() {
        let session = UUID(), key = AwayMemory.macKey(host: host())
        let request = PhoneAwayLockRequest(hostKey: key, session: session, epoch: 4, sentAt: 10)
        XCTAssertTrue(request.matches(hostKey: key, session: session, epoch: 4, at: 14.9))
        XCTAssertFalse(request.matches(hostKey: AwayMemory.macKey(host: host("f")), session: session, epoch: 4, at: 11))
        XCTAssertFalse(request.matches(hostKey: key, session: UUID(), epoch: 4, at: 11))
        XCTAssertFalse(request.matches(hostKey: key, session: session, epoch: 5, at: 11))
        for time in [9.0, 15.1, .nan, .infinity] {
            XCTAssertFalse(request.matches(hostKey: key, session: session, epoch: 4, at: time))
        }
    }
}
