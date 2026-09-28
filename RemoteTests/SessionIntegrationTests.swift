import XCTest
import Foundation
import CoreVideo
import WebRTC
import Combine

private final class MemoryTrust: PairPersistence {
    var data: Data?
    var refuseSave = false
    func save<T: Encodable>(_ value: T) throws {
        if refuseSave { throw RemoteError.keychain(-1) }
        data = try JSONEncoder().encode(value)
    }
    func read<T: Decodable>(_ type: T.Type) throws -> T? { try data.map { try JSONDecoder().decode(type, from: $0) } }
    func delete() throws { data = nil }
}

private final class TestFrameReceiver: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var count = 0
    private var lastSize = CGSize.zero
    var received: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 }
    var frameSize: CGSize { lock.lock(); defer { lock.unlock() }; return lastSize }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        count += 1
        lastSize = CGSize(width: Int(frame.width), height: Int(frame.height))
        lock.unlock()
    }
}

final class SessionIntegrationTests: XCTestCase {
    @MainActor
    private func waitFor(_ description: String, seconds: Double = 8, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), description)
        if !predicate() { throw RemoteError.stale }
    }

    private func service() throws -> (Process, String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/bun")
        process.arguments = [root.appendingPathComponent("scripts/test-service.ts").path]
        process.currentDirectoryURL = root; process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.availableData
        guard let text = String(data: bytes, encoding: .utf8), let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate(); throw RemoteError.invalidMessage
        }
        return (process, "ws://127.0.0.1:\(port)/signal")
    }

    @MainActor
    func testRealEnrollmentControlReconnectAndRevocation() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let hostStore = MemoryTrust(), phoneStore = MemoryTrust()
        let host = RemoteCoordinator(isHost: true, store: hostStore)
        let phone = RemoteCoordinator(isHost: false, store: phoneStore)
        var transitions: [String] = []
        let hostObserver = host.$status.sink { transitions.append("host: \($0)") }
        let phoneObserver = phone.$status.sink { transitions.append("phone: \($0)") }
        defer {
            print("SESSION TRANSITIONS: \(transitions.joined(separator: " -> "))")
            withExtendedLifetime((hostObserver, phoneObserver)) {}
            host.stop(); phone.stop()
        }
        let original = try host.createPair(server: url, name: "Integration Mac")
        XCTAssertFalse(host.hostRegistered, "Creating an invitation must not make it ready for scanning")
        host.start()
        XCTAssertFalse(host.hostRegistered, "Opening the socket must wait for registration acknowledgement")
        try await waitFor("host registered") { host.hostRegistered }
        try phone.enroll(original.code())
        try await waitFor("explicit host approval required") { host.awaitingApproval }
        XCTAssertFalse(host.connected); XCTAssertFalse(phone.connected)
        host.approve()
        try await waitFor("both real WebRTC control channels connected: \(host.status), \(phone.status)", seconds: 25) { host.connected && phone.connected }
        XCTAssertEqual(host.invitation, phone.invitation)
        XCTAssertNotEqual(host.invitation?.key, original.key)
        XCTAssertEqual(try phoneStore.read(PairInvitation.self), host.invitation)
        try await waitFor("remote video track negotiated") { phone.remoteVideo != nil }
        let renderer = TestFrameReceiver()
        let video = try XCTUnwrap(phone.remoteVideo)
        video.add(renderer); defer { video.remove(renderer) }
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 127, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for _ in 0..<12 {
            host.media?.pushFrame(pixels, timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await waitFor("generated fixture encoded and decoded through native WebRTC") { renderer.received }
        try await waitFor("measured candidate route available") { host.diagnostics.hasPrefix("Direct") }
        print("LOCAL MEDIA RECEIPT: \(host.diagnostics)")
        // Exercise an in-session resolution increase and decrease through the
        // real encoder/decoder. This proves dimensions, not network performance.
        for size in [CGSize(width: 3840, height: 2160), CGSize(width: 1920, height: 1080)] {
            var sizedBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &sizedBuffer), kCVReturnSuccess)
            let sizedPixels = try XCTUnwrap(sizedBuffer)
            CVPixelBufferLockBaseAddress(sizedPixels, [])
            memset(CVPixelBufferGetBaseAddress(sizedPixels), 90, CVPixelBufferGetDataSize(sizedPixels))
            CVPixelBufferUnlockBaseAddress(sizedPixels, [])
            for _ in 0..<20 {
                host.media?.pushFrame(sizedPixels, timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
                try await Task.sleep(nanoseconds: 100_000_000)
                if renderer.frameSize == size { break }
            }
            try await waitFor("native stream decodes changed frame size \(size)") { renderer.frameSize == size }
            print("RESOLUTION RECEIPT: decoded \(Int(renderer.frameSize.width)) x \(Int(renderer.frameSize.height))")
        }
        var received: RemoteAction?
        host.onControl = { data in received = try? JSONDecoder().decode(RemoteAction.self, from: data) }
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "text", text: "Bonjour 👋 中文", key: "test-1", epoch: 42)))
        try await waitFor("text arrived over native ordered data channel") { received != nil }
        XCTAssertEqual(received?.text, "Bonjour 👋 中文"); XCTAssertEqual(received?.epoch, 42)
        let obsoleteStateCallback = host.media?.onState
        phone.stop()
        try await waitFor("host registered after disconnect", seconds: 8) { !host.connected && host.hostRegistered }
        // A queued callback can outlive its weak media reference. nil === nil must
        // never make a closed peer the owner of this new signaling attempt.
        obsoleteStateCallback?("closed")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(host.status, "Ready for your paired phone")
        phone.start()
        try await waitFor("saved trust reconnects without approval", seconds: 25) { host.connected && phone.connected }
        XCTAssertFalse(host.awaitingApproval)
        host.revoke()
        XCTAssertFalse(host.hostRegistered, "Revocation must immediately hide the pairing code")
        try await waitFor("phone loses revoked session") { !phone.connected }
        XCTAssertNil(hostStore.data)
        XCTAssertFalse(phone.sendControl(RemoteAction(action: "click")))
        XCTAssertFalse(host.connected)
    }

    @MainActor
    func testEnrollmentRecoversWhenPhoneRegistersBeforeHost() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let hostStore = MemoryTrust(), phoneStore = MemoryTrust()
        let host = RemoteCoordinator(isHost: true, store: hostStore)
        let phone = RemoteCoordinator(isHost: false, store: phoneStore)
        defer { host.stop(); phone.stop() }

        let original = try host.createPair(server: url, name: "Late Host")
        try phone.enroll(original.code())
        try await waitFor("phone entered bounded retry before the host room existed") {
            phone.status.contains("retrying")
        }
        XCTAssertFalse(host.hostRegistered)
        XCTAssertFalse(host.connected)
        XCTAssertFalse(phone.connected)

        host.start()
        try await waitFor("host registered during the phone retry window") { host.hostRegistered }
        try await waitFor("retried enrollment still requires explicit host approval") { host.awaitingApproval }
        XCTAssertFalse(host.connected)
        XCTAssertFalse(phone.connected)

        host.approve()
        try await waitFor("late host and early phone completed trusted WebRTC setup", seconds: 25) {
            host.connected && phone.connected
        }
        XCTAssertNotEqual(host.invitation?.key, original.key)
        XCTAssertEqual(host.invitation, phone.invitation)
        let currentInvitation = try XCTUnwrap(host.invitation)
        let savedHost = try XCTUnwrap(hostStore.read(HostPair.self))
        let savedPhone = try XCTUnwrap(phoneStore.read(PairInvitation.self))
        XCTAssertTrue(savedHost.paired)
        XCTAssertEqual(savedHost.invitation, currentInvitation)
        XCTAssertEqual(savedPhone, currentInvitation)
    }

    @MainActor
    func testRejectedApprovalAndSaveFailureNeverConnect() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let hostStore = MemoryTrust(), phoneStore = MemoryTrust()
        let host = RemoteCoordinator(isHost: true, store: hostStore)
        let phone = RemoteCoordinator(isHost: false, store: phoneStore)
        defer { host.stop(); phone.stop() }
        let invitation = try host.createPair(server: url, name: "Test")
        host.start(); try await waitFor("host registered") { host.status == "Ready for your paired phone" }
        try phone.enroll(invitation.code()); try await waitFor("approval pending") { host.awaitingApproval }
        host.reject()
        XCTAssertFalse(host.hostRegistered, "A terminal failure must immediately hide the pairing code")
        XCTAssertFalse(host.connected); XCTAssertFalse(phone.connected); XCTAssertNil(phoneStore.data)
        phone.stop()
        host.start(); try await waitFor("host re-registered") { host.status == "Ready for your paired phone" }
        try phone.enroll(invitation.code()); try await waitFor("approval pending again") { host.awaitingApproval }
        hostStore.refuseSave = true; host.approve()
        XCTAssertFalse(host.connected); XCTAssertNil(phoneStore.data)
        XCTAssertEqual(host.invitation, invitation)
    }

    @MainActor
    func testPhoneSaveFailureKeepsRotatedHostTrust() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let hostStore = MemoryTrust(), phoneStore = MemoryTrust()
        phoneStore.refuseSave = true
        let host = RemoteCoordinator(isHost: true, store: hostStore)
        let phone = RemoteCoordinator(
            isHost: false,
            store: phoneStore,
            retryLimit: 3,
            retryBaseNanoseconds: 25_000_000
        )
        defer { host.stop(); phone.stop() }
        let original = try host.createPair(server: url, name: "Test")
        host.start(); try await waitFor("host registered") { host.status == "Ready for your paired phone" }
        try phone.enroll(original.code()); try await waitFor("approval pending") { host.awaitingApproval }
        host.approve()
        try await waitFor("phone save failure ends enrollment") { phone.status.contains("Secure connection failed") }
        XCTAssertFalse(host.connected); XCTAssertFalse(phone.connected); XCTAssertNil(phoneStore.data)
        let committed = try XCTUnwrap(hostStore.read(HostPair.self))
        XCTAssertTrue(committed.paired); XCTAssertNotEqual(committed.invitation.key, original.key)
        phone.stop(); host.stop(); host.start()
        try await waitFor("rotated host re-registered") { host.status == "Ready for your paired phone" }
        try phone.enroll(original.code())
        try await waitFor("original invitation exhausts its bounded retry budget") {
            phone.status.contains("host_unavailable_or_unauthorized")
        }
        XCTAssertFalse(host.awaitingApproval); XCTAssertFalse(host.connected)
        phone.start()
        try await waitFor("explicit Connect starts a fresh bounded retry budget") {
            phone.status.contains("retrying")
        }
        XCTAssertFalse(host.awaitingApproval); XCTAssertFalse(host.connected); XCTAssertFalse(phone.connected)
    }

    func testUTF16BoundAndHealthMessages() throws {
        XCTAssertThrowsError(try RemoteAction(action: "text", text: String(repeating: "a", count: 1025)).validate())
        XCTAssertNoThrow(try RemoteAction(action: "text", text: String(repeating: "👋", count: 512)).validate())
        XCTAssertThrowsError(try RemoteAction(action: "text", text: String(repeating: "👋", count: 513)).validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1).validate())
        XCTAssertNoThrow(try RemoteAction(action: "textResult", x: 1, key: "test").validate())
    }
}
