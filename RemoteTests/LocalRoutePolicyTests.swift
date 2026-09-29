import XCTest
import Foundation
import CryptoKit

final class LocalRoutePolicyTests: XCTestCase {
    private let room = String(repeating: "a", count: 64)
    private let epoch = String(repeating: "b", count: 32)
    private let session = String(repeating: "c", count: 64)
    private let nonce = String(repeating: "d", count: 64)
    private let endpoint = LocalProbeEndpoint(address: "192.168.1.20", port: 45000)
    private let key = SymmetricKey(data: Data(repeating: 7, count: 32))

    private func packet() throws -> Data {
        let body = "1|challenge|\(room)|\(epoch)|\(session)|\(nonce)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key)
        return try JSONEncoder().encode(ProbePacket(kind: "challenge", room: room, epoch: epoch,
                                                    session: session, nonce: nonce,
                                                    mac: Data(mac).base64EncodedString()))
    }

    func testLocalProofRequiresAuthenticatedOneHopOnTheSelectedPhysicalInterface() throws {
        let data = try packet()
        func verify(_ data: Data, ttl: Int32? = 1, index: UInt32? = 4,
                    address: String? = "192.168.1.20", port: UInt16? = 45000,
                    secret: SymmetricKey? = nil) -> ProbePacket? {
            LocalProbeVerifier.verify(data, ttl: ttl, interfaceIndex: index, sourceAddress: address,
                                      sourcePort: port, peer: endpoint, expectedInterface: 4,
                                      room: room, epoch: epoch, session: session, pairingKey: secret ?? key)
        }
        XCTAssertEqual(verify(data)?.nonce, nonce)
        XCTAssertNil(verify(data, ttl: nil))
        XCTAssertNil(verify(data, ttl: 2))
        XCTAssertNil(verify(data, index: nil))
        XCTAssertNil(verify(data, index: 9))
        XCTAssertNil(verify(data, address: "198.51.100.2"))
        XCTAssertNil(verify(data, port: 45001))
        XCTAssertNil(verify(data, secret: SymmetricKey(data: Data(repeating: 8, count: 32))))
        XCTAssertNil(verify(Data(repeating: 0, count: 513)))
    }

    func testSelectedICEPairMustMatchTheProvenHostAddresses() {
        let link = ProvenLocalLink(localAddress: "192.168.1.10", peerAddress: "192.168.1.20")
        XCTAssertTrue(LocalMediaRoute.matches(link, localType: "host", remoteType: "host",
                                             localAddress: "192.168.1.10", remoteAddress: "192.168.1.20", adapterType: "wifi"))
        XCTAssertFalse(LocalMediaRoute.matches(link, localType: "srflx", remoteType: "host",
                                              localAddress: "192.168.1.10", remoteAddress: "192.168.1.20", adapterType: "wifi"))
        XCTAssertFalse(LocalMediaRoute.matches(link, localType: "host", remoteType: "relay",
                                              localAddress: "192.168.1.10", remoteAddress: "192.168.1.20", adapterType: "wifi"))
        XCTAssertFalse(LocalMediaRoute.matches(link, localType: "host", remoteType: "host",
                                              localAddress: "10.8.0.2", remoteAddress: "192.168.1.20", adapterType: "wifi"))
        XCTAssertFalse(LocalMediaRoute.matches(link, localType: "host", remoteType: "host",
                                              localAddress: "192.168.1.10", remoteAddress: nil, adapterType: "wifi"))
        XCTAssertFalse(LocalMediaRoute.matches(link, localType: "host", remoteType: "host",
                                              localAddress: "192.168.1.10", remoteAddress: "192.168.1.20", adapterType: "vpn"))
        XCTAssertFalse(LocalMediaRoute.matches(link, localType: "host", remoteType: "host",
                                              localAddress: "192.168.1.10", remoteAddress: "192.168.1.20", adapterType: nil))
    }

    func testPolicyRejectsExpiredReplayAndEpochSwap() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func policy(_ epoch: String = String(repeating: "b", count: 32), revision: Int = 1,
                    deadline: Int64 = 1_800_000_030_000) throws -> RelayMessage {
            let json = """
            {"type":"route","version":1,"room":"\(room)","epoch":"\(epoch)","revision":\(revision),"access":"local","expiresAt":\(deadline)}
            """
            return try JSONDecoder().decode(RelayMessage.self, from: Data(json.utf8))
        }
        let first = try XCTUnwrap(ServerRoutePolicy.accept(policy(), room: room, previous: nil, now: now))
        XCTAssertNil(ServerRoutePolicy.accept(try policy(), room: room, previous: first, now: now))
        XCTAssertNil(ServerRoutePolicy.accept(try policy(String(repeating: "e", count: 32), revision: 2), room: room, previous: first, now: now))
        XCTAssertNil(ServerRoutePolicy.accept(try policy(revision: 2, deadline: 1_799_999_999_000), room: room, previous: first, now: now))
        XCTAssertNotNil(ServerRoutePolicy.accept(try policy(revision: 2), room: room, previous: first, now: now))
    }
}
