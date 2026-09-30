import XCTest
import Foundation
import CryptoKit
import Darwin
import Network

final class LocalLinkProofDiagnosticsTests: XCTestCase {
    /// Captured from recvmsg on macOS 27 for a TTL-1 datagram received on en0 (index 11).
    private let capturedEn0Control: [UInt8] = [
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00,
        0x14, 0x12, 0x0b, 0x00, 0x06, 0x03, 0x06, 0x00, 0x65, 0x6e, 0x30, 0xf8,
        0x73, 0xdf, 0x14, 0xfe, 0x56, 0x00, 0x00, 0x00,
        0x0d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
    ]

    func testControlParserReadsDarwinSingleByteTTLAndInterfaceIndex() {
        let parsed = capturedEn0Control.withUnsafeBytes { LocalProbeControl.parse($0, length: 48) }
        XCTAssertEqual(parsed.ttl, 1)
        XCTAssertEqual(parsed.index, 11)
    }

    func testControlParserAcceptsIntSizedTTLPayload() {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 16
        bytes[8] = UInt8(IP_RECVTTL)
        bytes[12] = 1
        let parsed = bytes.withUnsafeBytes { LocalProbeControl.parse($0, length: 16) }
        XCTAssertEqual(parsed.ttl, 1)
        XCTAssertNil(parsed.index)
    }

    func testControlParserStopsOnTruncatedMessage() {
        let parsed = capturedEn0Control.withUnsafeBytes { LocalProbeControl.parse($0, length: 40) }
        XCTAssertEqual(parsed.index, 11)
        XCTAssertNil(parsed.ttl)
    }

    /// End-to-end against the kernel: a TTL-1 datagram over loopback must parse as TTL 1 on lo0.
    func testKernelAncillaryDataParsesAsOneHop() throws {
        func open() throws -> (Int32, UInt16) {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { throw XCTSkip("socket unavailable") }
            var one: Int32 = 1
            XCTAssertEqual(setsockopt(fd, IPPROTO_IP, IP_TTL, &one, 4), 0)
            XCTAssertEqual(setsockopt(fd, IPPROTO_IP, IP_RECVIF, &one, 4), 0)
            XCTAssertEqual(setsockopt(fd, IPPROTO_IP, IP_RECVTTL, &one, 4), 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            XCTAssertEqual(bound, 0)
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &size) }
            }
            return (fd, UInt16(bigEndian: address.sin_port))
        }
        let (sender, _) = try open()
        let (receiver, port) = try open()
        defer { Darwin.close(sender); Darwin.close(receiver) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &target.sin_addr)
        let payload = Array("probe".utf8)
        let sent = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.sendto(sender, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(sent, payload.count)
        var body = [UInt8](repeating: 0, count: 64)
        var control = [UInt8](repeating: 0, count: 256)
        let parsed: (ttl: Int32?, index: UInt32?) = body.withUnsafeMutableBytes { bodyBytes in
            control.withUnsafeMutableBytes { controlBytes in
                var vector = iovec(iov_base: bodyBytes.baseAddress, iov_len: bodyBytes.count)
                return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    var header = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1,
                                        msg_control: controlBytes.baseAddress,
                                        msg_controllen: socklen_t(controlBytes.count), msg_flags: 0)
                    guard Darwin.recvmsg(receiver, &header, 0) > 0 else { return (nil, nil) }
                    return LocalProbeControl.parse(UnsafeRawBufferPointer(controlBytes), length: Int(header.msg_controllen))
                }
            }
        }
        XCTAssertEqual(parsed.ttl, 1)
        XCTAssertEqual(parsed.index, if_nametoindex("lo0"))
    }

    // MARK: Path classification

    private let en0 = LocalPathInterface(name: "en0", index: 11, type: .wifi)
    private let utun2 = LocalPathInterface(name: "utun2", index: 24, type: .other)

    private func classify(_ available: [LocalPathInterface], using: Set<String>,
                          expected: (String, UInt32)? = ("en0", 11), ipv4: String? = "10.0.0.114") -> LocalPathVerdict {
        LocalPathClassifier.classify(satisfied: true, available: available,
                                     uses: { type in available.contains { $0.type == type && using.contains($0.name) } },
                                     expected: expected, currentIPv4: ipv4, expectedIPv4: "10.0.0.114")
    }

    func testInstalledVPNAlongsideDirectWiFiRoutePasses() {
        XCTAssertEqual(classify([en0, en0, utun2], using: ["en0"]), .safe)
    }

    func testPathRoutedOverVPNFails() {
        XCTAssertEqual(classify([en0, utun2], using: ["utun2"]), .usesOther)
        XCTAssertEqual(classify([en0, utun2], using: ["en0", "utun2"]), .usesOther)
    }

    func testCellularAmbiguityAndInterfaceChangesFail() {
        let cell = LocalPathInterface(name: "pdp_ip0", index: 3, type: .cellular)
        let wired = LocalPathInterface(name: "en5", index: 7, type: .wiredEthernet)
        XCTAssertEqual(classify([en0, cell], using: ["pdp_ip0"]), .usesCellular)
        XCTAssertEqual(classify([en0, cell], using: ["en0"]), .safe)
        XCTAssertEqual(classify([en0, wired], using: ["en0"]), .multiplePhysical)
        XCTAssertEqual(classify([utun2], using: []), .noPhysical)
        XCTAssertEqual(classify([en0], using: ["en0"], expected: ("en0", 12)), .interfaceMismatch)
        XCTAssertEqual(classify([en0], using: []), .notUsingPhysical)
        XCTAssertEqual(classify([en0], using: ["en0"], ipv4: "10.0.0.115"), .addressChanged)
        XCTAssertEqual(LocalPathClassifier.classify(satisfied: false, available: [en0], uses: { _ in true },
                                                    expected: nil, currentIPv4: nil, expectedIPv4: nil), .unsatisfied)
    }

    // MARK: Rejection reasons

    func testVerifierReportsTheFirstFailedCheck() throws {
        let room = String(repeating: "a", count: 64), epoch = String(repeating: "b", count: 32)
        let session = String(repeating: "c", count: 64), nonce = String(repeating: "d", count: 64)
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let peer = LocalProbeEndpoint(address: "10.0.0.40", port: 45000)
        let body = "1|challenge|\(room)|\(epoch)|\(session)|\(nonce)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key)
        let data = try JSONEncoder().encode(ProbePacket(kind: "challenge", room: room, epoch: epoch, session: session,
                                                        nonce: nonce, mac: Data(mac).base64EncodedString()))
        func reason(ttl: Int32? = 1, index: UInt32? = 11, address: String = "10.0.0.40", port: UInt16 = 45000,
                    secret: SymmetricKey? = nil) -> LocalProbeRejection? {
            let result = LocalProbeVerifier.check(data, ttl: ttl, interfaceIndex: index, sourceAddress: address,
                                                  sourcePort: port, peer: peer, expectedInterface: 11, room: room,
                                                  epoch: epoch, session: session, pairingKey: secret ?? key)
            if case .failure(let error) = result { return error.reason }
            return nil
        }
        XCTAssertNil(reason())
        XCTAssertEqual(reason(ttl: nil), .ttl)
        XCTAssertEqual(reason(ttl: 64), .ttl)
        XCTAssertEqual(reason(index: 24), .interface)
        XCTAssertEqual(reason(address: "10.0.0.41"), .sourceAddress)
        XCTAssertEqual(reason(port: 1), .sourcePort)
        XCTAssertEqual(reason(secret: SymmetricKey(data: Data(repeating: 8, count: 32))), .hmac)
    }

    /// macOS WebRTC labels en0 "unknown" (observed: networkType=unknown, networkAdapterType=unknown for
    /// 10.0.0.114) while Tailscale's utun candidates are networkType=vpn, vpn=1.
    func testMacUnknownAdapterOnProvenAddressesIsTheLocalLinkButVPNIsNot() {
        let link = ProvenLocalLink(localAddress: "10.0.0.114", peerAddress: "10.0.0.40")
        func matches(_ local: String = "10.0.0.114", adapter: String? = "unknown", network: String? = "unknown",
                     vpn: Bool? = false, localType: String = "host") -> Bool {
            LocalMediaRoute.matches(link, localType: localType, remoteType: "host", localAddress: local,
                                    remoteAddress: "10.0.0.40", adapterType: adapter, networkType: network, vpn: vpn)
        }
        XCTAssertTrue(matches())
        XCTAssertTrue(matches(adapter: "wifi", network: "wifi"))
        XCTAssertTrue(matches(adapter: nil, network: "ethernet", vpn: nil))
        XCTAssertFalse(matches("100.107.213.92", adapter: "unknown", network: "vpn", vpn: true))
        XCTAssertFalse(matches(network: "vpn"))
        XCTAssertFalse(matches(vpn: true))
        XCTAssertFalse(matches(adapter: "cellular", network: "cellular"))
        XCTAssertFalse(matches(adapter: nil, network: nil))
        XCTAssertFalse(matches(localType: "srflx"))
        XCTAssertFalse(matches("10.0.0.115"))
    }

    /// Observed 30 Sep: after the IPv4 proof, WebRTC nominated a same-LAN IPv6 host pair and the host
    /// ended every session. Only the proven host address may be trickled in either direction.
    func testLocalModeTricklesOnlyTheProvenHostAddress() {
        func allows(_ sdp: String) -> Bool { LocalMediaRoute.allows(candidate: sdp, address: "10.0.0.114") }
        XCTAssertTrue(allows("candidate:842163049 1 udp 2122260223 10.0.0.114 56143 typ host generation 0"))
        XCTAssertFalse(allows("candidate:1 1 udp 2122262783 2607:fea8:fe00:853d:b109:b0d1:4b55:227a 50000 typ host"))
        XCTAssertFalse(allows("candidate:2 1 udp 2122197247 100.107.213.92 50001 typ host"))
        XCTAssertFalse(allows("candidate:3 1 udp 1686052607 10.0.0.114 50002 typ srflx raddr 10.0.0.114 rport 50002"))
        XCTAssertFalse(allows("candidate:4 1 udp 41885439 10.0.0.114 3478 typ relay"))
        XCTAssertFalse(allows("candidate:5 1 tcp 1518280447 10.0.0.1140 9 typ host tcptype active"))
        XCTAssertFalse(allows("garbage"))
    }

    func testStageSummaryCarriesNoAddresses() {
        var stage = LocalProofStage()
        stage.monitorReady = true; stage.peerSet = true; stage.challengesSent = 32; stage.packetsReceived = 32
        stage.rejections[.ttl] = 32
        let summary = stage.summary
        XCTAssertTrue(summary.contains("ttl=32"))
        XCTAssertFalse(summary.contains("10.0.0."))
    }
}
