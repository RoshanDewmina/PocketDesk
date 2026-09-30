import XCTest

final class LANWakeTests: XCTestCase {
    private let helper = String(repeating: "a", count: 64), grant = String(repeating: "b", count: 64), targetHost = String(repeating: "c", count: 64), targetID = UUID()
    private func target() throws -> HostWakeTarget {
        try HostWakeTarget(id: targetID, targetHostID: targetHost, helperHostID: helper, ownerPairID: grant,
                          hardwareAddress: WakeHardwareAddress("02:01:02:03:04:05"), interfaceName: "en0")
    }
    private func authority(_ deadline: Double = 1000, epoch: UInt64 = 1) -> HostWakeAuthority {
        HostWakeAuthority(helperHostID: helper, ownerPairID: grant, sessionID: "authenticated", epoch: epoch, validUntil: deadline)
    }
    private func request(_ number: Int = 1) -> WakeRequest { WakeRequest(targetID: targetID, requestID: String(format: "%032x", number)) }
    private func admitted(_ authority: HostWakeAuthority, _ operation: () -> WakeReply.Status) -> WakeReply.Status { operation() }
    func testStrictAddressAndExactPacket() throws {
        for text in ["", "2:01:02:03:04:05", "+2:01:02:03:04:05", "02:01:02:03:04:0g", "01:01:02:03:04:05", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"] {
            XCTAssertThrowsError(try WakeHardwareAddress(text))
        }
        let address = try WakeHardwareAddress("02:01:02:03:04:05")
        XCTAssertEqual(address.magicPacket.count, 102)
        XCTAssertEqual(Array(address.magicPacket.prefix(6)), Array(repeating: 255, count: 6))
        XCTAssertEqual(Array(address.magicPacket.dropFirst(6)), Array(repeating: address.bytes, count: 16).flatMap { $0 })
    }
    func testPrivateDirectedBroadcastOnlyAndInjectedSender() throws {
        let good = WakeLANInterface(name: "en0", index: 2, address: 0xc0a8010a, netmask: 0xffffff00, broadcast: 0xc0a801ff)
        XCTAssertTrue(good.valid())
        for bad in [WakeLANInterface(name: "en0", index: 2, address: 0x0a00000a, netmask: 0x80000000, broadcast: 0x7fffffff),
                    WakeLANInterface(name: "en0", index: 2, address: 0x08080808, netmask: 0xffffff00, broadcast: 0x080808ff),
                    WakeLANInterface(name: "en0", index: 2, address: good.address, netmask: 0xffffff00, broadcast: 0xffffffff),
                    WakeLANInterface(name: "en0", index: 2, address: good.address, netmask: 0xff00ff00, broadcast: good.broadcast)] {
            XCTAssertFalse(bad.valid())
        }
        var packets = 0
        let sender = LANMagicPacketSender(interface: { _ in good }, write: { observed, bytes in
            XCTAssertEqual(observed, good); XCTAssertEqual(bytes.count, 102); packets += 1; return true
        })
        XCTAssertEqual(sender.send(try target()), .sent); XCTAssertEqual(packets, 1)
        XCTAssertEqual(LANMagicPacketSender(interface: { _ in nil }, write: { _, _ in XCTFail(); return true }).send(try target()), .unsupported)
    }
    func testReplayAgeEpochCooldownAndFinalRevocation() throws {
        var now = 100.0, sends = 0
        var configured: HostWakeTarget? = try target()
        let service = HostLANWakeService(resolve: { _ in configured }, send: { _ in sends += 1; return .sent }, clock: { now })
        XCTAssertEqual(service.request(request(), receivedAt: now, authority: authority(), sendUnderAuthority: admitted).status, .sent)
        now = 161
        XCTAssertEqual(service.request(request(), receivedAt: now, authority: authority(), sendUnderAuthority: admitted).status, .denied, "Same session nonce survives time/cooldown")
        XCTAssertEqual(service.request(request(2), receivedAt: now - 31, authority: authority(), sendUnderAuthority: admitted).status, .denied)
        XCTAssertEqual(service.request(request(2), receivedAt: now + 1, authority: authority(), sendUnderAuthority: admitted).status, .denied)
        XCTAssertEqual(service.request(request(2), receivedAt: now, authority: authority(now), sendUnderAuthority: admitted).status, .denied)
        XCTAssertEqual(service.request(request(2), receivedAt: now, authority: authority(), sendUnderAuthority: { _, _ in .denied }).status, .denied)
        XCTAssertEqual(service.request(request(2), receivedAt: now, authority: authority(), sendUnderAuthority: admitted).status, .sent, "Rejected authority did not consume nonce")
        now = 162
        XCTAssertEqual(service.request(request(3), receivedAt: now, authority: authority(), sendUnderAuthority: admitted).status, .denied)
        now = 222
        XCTAssertEqual(service.request(request(4), receivedAt: now, authority: authority(), sendUnderAuthority: { _, operation in configured = nil; return operation() }).status, .denied)
        XCTAssertEqual(sends, 2)
    }
    func testWrongOwnerAndBoundedSessionNonceLedger() throws {
        let registered = try target()
        let service = HostLANWakeService(resolve: { _ in registered }, send: { _ in XCTFail(); return .sent }, clock: { 100 })
        let foreignLookup = HostLANWakeService(resolve: { _ in registered }, send: { _ in XCTFail(); return .sent }, clock: { 100 })
        XCTAssertEqual(foreignLookup.request(WakeRequest(targetID: UUID(), requestID: request().requestID), receivedAt: 100, authority: authority(), sendUnderAuthority: admitted).status, .denied)
        let wrong = HostWakeAuthority(helperHostID: helper, ownerPairID: String(repeating: "d", count: 64), sessionID: "authenticated", epoch: 1, validUntil: 1000)
        XCTAssertEqual(service.request(request(), receivedAt: 100, authority: wrong, sendUnderAuthority: admitted).status, .denied)
        let ledger = HostLANWakeService(resolve: { _ in nil }, send: { _ in XCTFail(); return .sent }, clock: { 100 })
        for n in 2...130 { _ = ledger.request(request(n), receivedAt: 100, authority: authority(), sendUnderAuthority: admitted) }
        XCTAssertEqual(ledger.request(request(1000), receivedAt: 100, authority: authority(), sendUnderAuthority: admitted).status, .denied)
    }
    func testExpiryAndRemovalAreRecheckedBeforeDatagram() throws {
        let target = try target()
        var clockReads = 0, sends = 0
        let expired = HostLANWakeService(resolve: { _ in target }, send: { _ in sends += 1; return .sent }, clock: {
            clockReads += 1; return clockReads == 1 ? 100 : 102
        })
        XCTAssertEqual(expired.request(request(), receivedAt: 100, authority: authority(101), sendUnderAuthority: admitted).status, .denied)
        var resolutions = 0
        let removed = HostLANWakeService(resolve: { _ in resolutions += 1; return resolutions == 1 ? target : nil },
            send: { _ in sends += 1; return .sent }, clock: { 100 })
        XCTAssertEqual(removed.request(request(), receivedAt: 100, authority: authority(), sendUnderAuthority: admitted).status, .denied)
        XCTAssertEqual(sends, 0)
    }

    func testStorePreservesUnreadableDataAndRefusesForeignGrant() throws {
        let name = "WakeTests.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = HostWakeTargetStore(defaults: defaults)
        XCTAssertThrowsError(try store.register(target(), helperHostID: helper, ownerPairID: String(repeating: "d", count: 64)))
        try store.register(target(), helperHostID: helper, ownerPairID: grant)
        XCTAssertEqual(try store.read(), [try target()])
        defaults.set(Data("future-schema".utf8), forKey: "ownerRegisteredWakeTargetsV1")
        XCTAssertThrowsError(try store.register(target(), helperHostID: helper, ownerPairID: grant))
        XCTAssertEqual(defaults.data(forKey: "ownerRegisteredWakeTargetsV1"), Data("future-schema".utf8))
    }
    func testSchemaRejectsWrongActionAndMixedExtensions() throws {
        let wake = request()
        try RemoteAction(action: "wakeRequest", wakeRequest: wake).validate()
        try RemoteAction(action: "wakeReply", wakeReply: WakeReply(targetID: targetID, requestID: wake.requestID, status: .sent)).validate()
        XCTAssertThrowsError(try RemoteAction(action: "key", wakeRequest: wake).validate())
        XCTAssertThrowsError(try RemoteAction(action: "wakeRequest", text: "payload", wakeRequest: wake).validate())
        XCTAssertThrowsError(try RemoteAction(action: "wakeRequest", features: ["spoof"], wakeRequest: wake).validate())
        XCTAssertThrowsError(try RemoteAction(action: "wakeRequest", wakeRequest: WakeRequest(targetID: targetID, requestID: "BAD")).validate())
        XCTAssertThrowsError(try RemoteAction(action: "wakeRequest").validate())
    }
}
