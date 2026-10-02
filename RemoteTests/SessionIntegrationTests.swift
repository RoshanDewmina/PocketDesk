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

private final class IntegrationPasteboard: HostPasteboardAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let result: HostPasteboardRead
    private var stored: [ClipboardPayload] = []
    init(_ result: HostPasteboardRead) { self.result = result }
    var changeCount: Int { 0 }
    var writes: [ClipboardPayload] { lock.lock(); defer { lock.unlock() }; return stored }
    func read(limit: Int) -> HostPasteboardRead { result }
    func write(_ payload: ClipboardPayload) -> Bool { lock.lock(); stored.append(payload); lock.unlock(); return true }
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

/// The private Bun service has a scalar clientHash. This bounded service fixture admits the
/// catalog's token list and one client slot, forwarding the actual sealed coordinator traffic.
/// WebRTC offer/answer, ICE and control channels remain the real native implementation.
@MainActor
private final class MultiDeviceIntegrationRig {
    let hostStore = MemoryTrust()
    let phoneStores = [MemoryTrust(), MemoryTrust()]
    let hostSignal = ScriptedSignaling()
    let phoneSignals = [ScriptedSignaling(), ScriptedSignaling()]
    let host: RemoteCoordinator
    let phones: [RemoteCoordinator]
    var beforeHostSignalForward: ((RelayMessage) -> Void)?
    private(set) var busyAttempts = 0
    private(set) var activeClient: Int?
    private var hostRegistration: ScriptedSignaling.Connect?
    private var hostGeneration = 0
    private var clientGeneration = 0
    private struct Delivery {
        let target: ScriptedSignaling
        let message: RelayMessage
        let hostGeneration: Int
        let clientGeneration: Int
    }
    private var deliveries: [Delivery] = []
    private var drainScheduled = false

    init() {
        host = RemoteCoordinator(isHost: true, store: hostStore, retryLimit: 3,
            retryBaseNanoseconds: 10_000_000, signaling: hostSignal)
        phones = zip(phoneStores, phoneSignals).map { store, signal in
            RemoteCoordinator(isHost: false, store: store, retryLimit: 0, signaling: signal)
        }
        host.allowLegacyPrivateRoute = true
        for (index, phone) in phones.enumerated() {
            phone.allowLegacyPrivateRoute = true
            phone.localDisplayName = index == 0 ? "Original iPhone" : "Second iPad"
        }
        hostSignal.onConnect = { [weak self] in self?.registerHost($0) }
        hostSignal.respond = { [weak self] message in
            guard let self, message.type == "signal", let activeClient else { return }
            beforeHostSignalForward?(message)
            enqueue(message, to: phoneSignals[activeClient])
        }
        for (index, signal) in phoneSignals.enumerated() {
            signal.onConnect = { [weak self] in self?.registerClient(index, connection: $0) }
            signal.respond = { [weak self] message in
                guard let self, message.type == "signal", activeClient == index else { return }
                enqueue(message, to: hostSignal)
            }
        }
    }

    private func registerHost(_ connection: ScriptedSignaling.Connect) {
        guard hostSignal.isOpen else { return }
        XCTAssertNil(activeClient, "A host registration cannot replace an occupied session")
        XCTAssertEqual(connection.invitation.room, connection.hostToken.map(SecureRandom.digest))
        XCTAssertTrue(connection.features.contains(SignalingFeature.devices))
        let hashes = hostSignal.clientTokenHashes ?? []
        XCTAssertTrue((1...5).contains(hashes.count), "Approved grants plus a pending invitation stay within the five-device cap")
        XCTAssertEqual(Set(hashes).count, hashes.count)
        hostRegistration = connection
        hostGeneration += 1
        hostSignal.deliver(RelayMessage(type: "registered", role: "host", features: [SignalingFeature.devices]))
        hostSignal.deliver(RelayMessage(type: "ice", servers: []))
    }

    private func registerClient(_ index: Int, connection: ScriptedSignaling.Connect) {
        let signal = phoneSignals[index]
        guard signal.isOpen else { return }
        guard hostSignal.isOpen, let registered = hostRegistration,
              registered.invitation.room == connection.invitation.room,
              hostSignal.clientTokenHashes?.contains(SecureRandom.digest(connection.invitation.token)) == true else {
            signal.deliver(RelayMessage(type: "error", code: "host_unavailable_or_unauthorized"))
            return
        }
        guard activeClient == nil else {
            busyAttempts += 1
            signal.deliver(RelayMessage(type: "error", code: "already_connected"))
            return
        }
        activeClient = index
        clientGeneration += 1
        signal.deliver(RelayMessage(type: "registered", role: "client"))
        signal.deliver(RelayMessage(type: "ice", servers: []))
        hostSignal.deliver(RelayMessage(type: "peer", online: true))
        signal.deliver(RelayMessage(type: "peer", online: true))
    }

    private func enqueue(_ message: RelayMessage, to target: ScriptedSignaling) {
        guard deliveries.count < 256 else { XCTFail("Multi-device signaling exceeded its bounded queue"); return }
        deliveries.append(Delivery(target: target, message: message,
            hostGeneration: hostGeneration, clientGeneration: clientGeneration))
        guard !drainScheduled else { return }
        drainScheduled = true
        // Defer delivery until the sender returns and installs its newly derived cipher.
        Task { @MainActor [weak self] in self?.drain() }
    }

    private func drain() {
        for _ in 0..<256 {
            guard !deliveries.isEmpty else { drainScheduled = false; return }
            let delivery = deliveries.removeFirst()
            guard delivery.hostGeneration == hostGeneration,
                  delivery.clientGeneration == clientGeneration, delivery.target.isOpen else { continue }
            delivery.target.deliver(delivery.message)
        }
        drainScheduled = false
        XCTFail("Multi-device signaling did not settle within its bounded drain")
        deliveries.removeAll()
    }

    func disconnect(_ index: Int) {
        phones[index].stop()
        guard activeClient == index else { return }
        activeClient = nil
        clientGeneration += 1
        hostSignal.deliver(RelayMessage(type: "peer", online: false))
        if !hostSignal.isOpen { hostRegistration = nil }
    }

    func stop() {
        beforeHostSignalForward = nil
        host.stop()
        phones.forEach { $0.stop() }
        deliveries.removeAll()
        activeClient = nil
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
    func testTwoV2DevicesPersistBeforeAcceptanceAndReconnectWithoutTakeover() async throws {
        let rig = MultiDeviceIntegrationRig()
        defer { rig.stop() }
        let host = rig.host, first = rig.phones[0], second = rig.phones[1]
        let originalQR = try host.createPair(server: "wss://offline.invalid/signal", name: "Multi-device Mac")
        let room = originalQR.room, hostProof = try XCTUnwrap(host.hostPair?.hostToken)
        XCTAssertEqual(originalQR.version, PairEnrollment.version)
        host.start()
        try await waitFor("initial host registration") { host.hostRegistered }
        try first.enroll(originalQR.code())
        try await waitFor("first v2 comparison on both screens") {
            host.awaitingApproval && first.pairingComparisonCode != nil
        }
        let firstCode = try XCTUnwrap(host.pairingComparisonCode)
        XCTAssertEqual(firstCode, first.pairingComparisonCode)
        XCTAssertEqual(firstCode.filter(\.isNumber).count, 6)
        XCTAssertTrue(host.pairedDevices.isEmpty)
        XCTAssertNil(rig.phoneStores[0].data)
        XCTAssertFalse(host.connected); XCTAssertFalse(first.connected)

        var publications = 0
        rig.beforeHostSignalForward = { message in
            rig.beforeHostSignalForward = nil
            publications += 1
            do {
                let durable = try XCTUnwrap(rig.hostStore.read(HostPair.self))
                XCTAssertEqual(durable.approvedDevices.count, 1, "Persist the entire catalog before publishing accepted")
                XCTAssertNil(durable.pendingInvitation)
                XCTAssertEqual(durable.invitation, durable.approvedDevices[0].invitation)
                XCTAssertNil(rig.phoneStores[0].data, "Publication is observed before delivery to the phone")
                XCTAssertThrowsError(try SignalCipher(key: originalQR.key, room: room)
                    .open(XCTUnwrap(message.payload), sender: "host"), "The photographed QR cannot open accepted")
            } catch { XCTFail("First accepted was published without durable catalog: \(error)") }
        }
        host.approve()
        try await waitFor("first device's real WebRTC connection", seconds: 25) { host.connected && first.connected }
        XCTAssertEqual(publications, 1)
        let firstGrant = try XCTUnwrap(rig.phoneStores[0].read(PairInvitation.self))
        XCTAssertEqual(firstGrant.version, 1)
        XCTAssertEqual(firstGrant.room, room)
        XCTAssertNotEqual(firstGrant.key, originalQR.key)
        XCTAssertNotEqual(firstGrant.token, originalQR.token)
        XCTAssertEqual(host.invitation, firstGrant)
        XCTAssertNil(first.pairingComparisonCode)

        rig.disconnect(0)
        try await waitFor("host refreshes original saved-token admission") { host.hostRegistered && !host.connected }
        let secondQR = try host.createPair(server: originalQR.server, name: "Multi-device Mac")
        XCTAssertEqual(secondQR.version, PairEnrollment.version)
        XCTAssertEqual(secondQR.room, room)
        XCTAssertEqual(host.hostPair?.hostToken, hostProof)
        XCTAssertEqual(host.pairedDevices.map(\.invitation), [firstGrant])
        host.start()
        try await waitFor("host registers original and additional QR") { host.hostRegistered }
        XCTAssertEqual(Set(rig.hostSignal.clientTokenHashes ?? []),
                       Set([firstGrant.token, secondQR.token].map(SecureRandom.digest)))
        try second.enroll(secondQR.code())
        try await waitFor("second v2 comparison on both screens") {
            host.awaitingApproval && second.pairingComparisonCode != nil
        }
        let secondCode = try XCTUnwrap(host.pairingComparisonCode)
        XCTAssertEqual(secondCode, second.pairingComparisonCode)
        XCTAssertEqual(secondCode.filter(\.isNumber).count, 6)
        XCTAssertEqual(try rig.hostStore.read(HostPair.self)?.approvedDevices.map(\.invitation), [firstGrant])
        XCTAssertNil(rig.phoneStores[1].data)
        XCTAssertFalse(host.connected); XCTAssertFalse(second.connected)
        rig.beforeHostSignalForward = { message in
            rig.beforeHostSignalForward = nil
            publications += 1
            do {
                let durable = try XCTUnwrap(rig.hostStore.read(HostPair.self))
                XCTAssertEqual(durable.approvedDevices.count, 2, "Both grants must be durable before the second accepted")
                XCTAssertEqual(durable.approvedDevices[0].invitation, firstGrant)
                XCTAssertEqual(durable.invitation, durable.approvedDevices[1].invitation)
                XCTAssertEqual(durable.invitation.room, room)
                XCTAssertEqual(durable.hostToken, hostProof)
                XCTAssertNil(durable.pendingInvitation)
                XCTAssertNil(rig.phoneStores[1].data)
                XCTAssertThrowsError(try SignalCipher(key: secondQR.key, room: room)
                    .open(XCTUnwrap(message.payload), sender: "host"))
            } catch { XCTFail("Second accepted was published without both durable grants: \(error)") }
        }
        host.approve()
        try await waitFor("second device's real WebRTC connection", seconds: 25) { host.connected && second.connected }
        XCTAssertEqual(publications, 2)
        let secondGrant = try XCTUnwrap(rig.phoneStores[1].read(PairInvitation.self))
        XCTAssertEqual(secondGrant.version, 1)
        XCTAssertEqual(secondGrant.room, room)
        XCTAssertNotEqual(secondGrant.key, secondQR.key)
        XCTAssertNotEqual(secondGrant.token, secondQR.token)
        XCTAssertNotEqual(firstGrant.key, secondGrant.key)
        XCTAssertNotEqual(firstGrant.token, secondGrant.token)
        XCTAssertNil(host.pendingPairInvitation)
        XCTAssertEqual(host.pairedDevices.map(\.invitation), [firstGrant, secondGrant])

        let activeMedia = host.media, activePresentation = host.presentationSessionID
        first.start()
        try await waitFor("original device is refused while the second holds the slot") { rig.busyAttempts == 1 && !first.isRunning }
        XCTAssertTrue(first.status.contains("another device"))
        XCTAssertFalse(first.connected)
        XCTAssertTrue(host.connected); XCTAssertTrue(second.connected)
        XCTAssertTrue(host.media === activeMedia)
        XCTAssertEqual(host.presentationSessionID, activePresentation)
        XCTAssertEqual(host.invitation, secondGrant)
        XCTAssertFalse(host.awaitingApproval)
        // Also bypass fixture admission with the other valid key: the coordinator itself must
        // ignore it while an existing session owns the cipher, consent and presentation.
        let ignored = host.staleMessagesIgnored, sent = rig.hostSignal.sent.count
        let competing = ProtectedMessage(kind: "request", request: try SecureRandom.token(), session: "", sequence: 0)
        rig.hostSignal.deliver(RelayMessage(type: "signal", payload: try SignalCipher(key: firstGrant.key, room: room)
            .seal(competing, sender: "client")))
        XCTAssertEqual(host.staleMessagesIgnored, ignored + 1)
        XCTAssertEqual(rig.hostSignal.sent.count, sent)
        XCTAssertTrue(host.connected); XCTAssertTrue(second.connected)
        XCTAssertTrue(host.media === activeMedia)
        XCTAssertEqual(host.presentationSessionID, activePresentation)

        var received: RemoteAction?
        host.onControl = { received = try? JSONDecoder().decode(RemoteAction.self, from: $0) }
        XCTAssertTrue(second.sendControl(RemoteAction(action: "text", text: "Second still controls", key: "second-active", epoch: 42)))
        try await waitFor("refused contender leaves the second device's real control channel working") { received?.text == "Second still controls" }

        rig.disconnect(1)
        try await waitFor("both durable tokens are registered after second disconnect") { host.hostRegistered && !host.connected }
        XCTAssertEqual(Set(rig.hostSignal.clientTokenHashes ?? []),
                       Set([firstGrant.token, secondGrant.token].map(SecureRandom.digest)))
        for (index, grant) in [firstGrant, secondGrant].enumerated() {
            let phone = rig.phones[index]
            phone.restore(); phone.start()
            try await waitFor("saved device \(index + 1) reconnects with real WebRTC", seconds: 25) { host.connected && phone.connected }
            XCTAssertFalse(host.awaitingApproval)
            XCTAssertNil(host.pairingComparisonCode); XCTAssertNil(phone.pairingComparisonCode)
            XCTAssertFalse(phone.enrollmentPending)
            XCTAssertEqual(phone.invitation, grant)
            XCTAssertEqual(host.invitation, grant)
            XCTAssertEqual(host.hostPair?.hostToken, hostProof)
            XCTAssertEqual(host.invitation?.room, room)
            XCTAssertEqual(try rig.hostStore.read(HostPair.self)?.approvedDevices.map(\.invitation), [firstGrant, secondGrant])
            received = nil
            let text = "Saved device \(index + 1)"
            XCTAssertTrue(phone.sendControl(RemoteAction(action: "text", text: text, key: "reconnect-\(index)", epoch: 42)))
            try await waitFor("reconnected device \(index + 1) controls through its own channel") { received?.text == text }
            rig.disconnect(index)
            try await waitFor("host ready after device \(index + 1)") { host.hostRegistered && !host.connected }
        }
        XCTAssertEqual(try rig.phoneStores[0].read(PairInvitation.self), firstGrant)
        XCTAssertEqual(try rig.phoneStores[1].read(PairInvitation.self), secondGrant)
    }

    @MainActor
    func testRealEnrollmentControlReconnectAndRevocation() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let hostStore = MemoryTrust(), phoneStore = MemoryTrust()
        let host = RemoteCoordinator(isHost: true, store: hostStore)
        host.allowLegacyPrivateRoute = true
        let phone = RemoteCoordinator(isHost: false, store: phoneStore)
        phone.allowLegacyPrivateRoute = true
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
    func testHostKeepsRegisteredRoomWhenPhoneLeavesOrMediaDrops() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let host = RemoteCoordinator(isHost: true, store: MemoryTrust())
        host.allowLegacyPrivateRoute = true
        let phone = RemoteCoordinator(isHost: false, store: MemoryTrust())
        phone.allowLegacyPrivateRoute = true
        var hostStatuses: [String] = []
        let observer = host.$status.sink { hostStatuses.append($0) }
        defer {
            print("HOST LISTENER RECEIPT: host=\(host.status), phone=\(phone.status), transitions=\(hostStatuses)")
            withExtendedLifetime(observer) {}; host.stop(); phone.stop()
        }

        let invitation = try host.createPair(server: url, name: "Persistent Host")
        host.start()
        try await waitFor("host registered") { host.hostRegistered }
        try phone.enroll(invitation.code())
        try await waitFor("approval pending") { host.awaitingApproval }
        host.approve()
        try await waitFor("paired session connected", seconds: 25) { host.connected && phone.connected }

        let departureStart = hostStatuses.count
        phone.stop()
        try await waitFor("host stayed registered after phone left") {
            !host.connected && host.hostRegistered && host.status == "Ready for your paired phone"
        }
        XCTAssertTrue(hostStatuses.dropFirst(departureStart).contains { $0.contains("retrying") },
                      "The first departure must re-register with rotated trust")

        phone.start()
        try await waitFor("phone rejoined without host restart", seconds: 25) { host.connected && phone.connected }
        let sendFailureStart = hostStatuses.count
        host.media?.close()
        XCTAssertFalse(host.sendControl(RemoteAction(action: "heartbeat")),
                       "A closed media channel must reject host control sends")
        XCTAssertTrue(host.hostRegistered)
        XCTAssertEqual(host.status, "Ready for your paired phone")
        phone.stop()
        XCTAssertFalse(hostStatuses.dropFirst(sendFailureStart).contains { $0.contains("retrying") })

        phone.start()
        try await waitFor("phone rejoined after host send failure", seconds: 25) { host.connected && phone.connected }
        let mediaDropStart = hostStatuses.count
        host.media?.onState?("disconnected")
        try await waitFor("host retained listener after media dropped") {
            !host.connected && host.hostRegistered && host.status == "Ready for your paired phone"
        }
        phone.stop()
        XCTAssertFalse(hostStatuses.dropFirst(mediaDropStart).contains { $0.contains("retrying") },
                       "A media/offline callback race must not close the registered host room")
    }

    @MainActor
    func testDuplicateTransportLossKeepsPendingRetryAlive() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        // Retry belongs to saved trust. Fresh comparison enrollment intentionally retires its QR
        // on transport loss, so initialize an already paired v1 record rather than createPair.
        let hostStore = MemoryTrust()
        let saved = try HostPair.create(server: url, name: "Retry Host").rotated()
        try hostStore.save(saved)
        let host = RemoteCoordinator(isHost: true, store: hostStore,
                                     retryLimit: 2, retryBaseNanoseconds: 200_000_000,
                                     registrationStableNanoseconds: 100_000_000)
        host.allowLegacyPrivateRoute = true
        defer { host.stop() }
        host.restore()
        XCTAssertEqual(host.hostPair?.paired, true)
        XCTAssertEqual(host.invitation?.version, 1)
        host.start()
        try await waitFor("host registered") { host.hostRegistered }

        host.simulateTransportLossForTesting()
        XCTAssertTrue(host.status.contains("retrying"))
        host.simulateTransportLossForTesting()
        XCTAssertTrue(host.status.contains("retrying"), "Duplicate loss must not terminate a queued retry")
        try await waitFor("host re-registered after duplicate loss") { host.hostRegistered }
        try await Task.sleep(nanoseconds: 150_000_000)
        host.simulateTransportLossForTesting()
        XCTAssertTrue(host.status.contains("retrying"))
        try await waitFor("host re-registered after separate outage") { host.hostRegistered }
        try await Task.sleep(nanoseconds: 150_000_000)
        host.simulateTransportLossForTesting()
        XCTAssertTrue(host.status.contains("retrying"),
                      "Separate healthy host registrations must replenish the bounded retry budget")
        try await waitFor("host re-registered a third time") { host.hostRegistered }
        XCTAssertFalse(host.awaitingApproval, "Saved-trust retries never restart comparison enrollment")
        XCTAssertEqual(host.invitation, saved.invitation)
        XCTAssertEqual(try hostStore.read(HostPair.self)?.invitation, saved.invitation,
                       "Duplicate and separate outages preserve the existing saved grant")
    }

    @MainActor
    func testInterruptedEnrollmentBeforeHostRegistrationRequiresFreshScan() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let hostStore = MemoryTrust(), phoneStore = MemoryTrust()
        let host = RemoteCoordinator(isHost: true, store: hostStore)
        host.allowLegacyPrivateRoute = true
        let phone = RemoteCoordinator(isHost: false, store: phoneStore)
        phone.allowLegacyPrivateRoute = true
        defer { host.stop(); phone.stop() }

        let original = try host.createPair(server: url, name: "Late Host")
        try phone.enroll(original.code())
        try await waitFor("unapproved scan retires when its transport fails") {
            phone.status == "Pairing was interrupted. Scan a fresh QR to try again."
        }
        XCTAssertNil(phone.invitation); XCTAssertNil(phoneStore.data)
        XCTAssertFalse(phone.reconnecting, "An unapproved scan is not saved trust")
        XCTAssertFalse(host.hostRegistered)
        XCTAssertFalse(host.connected)
        XCTAssertFalse(phone.connected)

        host.start()
        try await waitFor("host registered after the retired scan") { host.hostRegistered }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(host.awaitingApproval); XCTAssertFalse(phone.connected)
        try phone.enroll(original.code()) // fresh, deliberate scan of the still-current QR
        try await waitFor("fresh enrollment still requires explicit host approval") { host.awaitingApproval }
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
        host.allowLegacyPrivateRoute = true
        let phone = RemoteCoordinator(isHost: false, store: phoneStore)
        phone.allowLegacyPrivateRoute = true
        defer { host.stop(); phone.stop() }
        let invitation = try host.createPair(server: url, name: "Test")
        host.start(); try await waitFor("host registered") { host.status == "Ready for your paired phone" }
        try phone.enroll(invitation.code()); try await waitFor("approval pending") { host.awaitingApproval }
        host.reject()
        XCTAssertFalse(host.hostRegistered, "A terminal failure must immediately hide the pairing code")
        XCTAssertFalse(host.connected); XCTAssertFalse(phone.connected); XCTAssertNil(phoneStore.data)
        phone.stop()
        // Declining retires only the unapproved QR grant. First pairing has no approved
        // device to resume, so a new attempt requires a fresh code in the same Mac room.
        host.start()
        XCTAssertFalse(host.hostRegistered)
        XCTAssertNil(host.pendingPairInvitation)
        let freshInvitation = try host.createPair(server: url, name: "Test")
        XCTAssertEqual(freshInvitation.room, invitation.room)
        XCTAssertNotEqual(freshInvitation.key, invitation.key)
        host.start(); try await waitFor("host re-registered") { host.status == "Ready for your paired phone" }
        try phone.enroll(freshInvitation.code()); try await waitFor("approval pending again") { host.awaitingApproval }
        hostStore.refuseSave = true; host.approve()
        XCTAssertFalse(host.connected); XCTAssertNil(phoneStore.data)
        XCTAssertNil(host.pendingPairInvitation, "Save failure retires the exposed grant")
        XCTAssertFalse(host.isRunning)
        host.start()
        XCTAssertFalse(host.hostRegistered, "Failed retirement cannot re-register the QR")
        hostStore.refuseSave = false
        host.restore(); host.start()
        XCTAssertNil(host.pendingPairInvitation, "Storage recovery alone cannot revive a photographed QR")
        XCTAssertFalse(host.isRunning)
        let recovered = try host.createPair(server: url, name: "Test")
        XCTAssertEqual(recovered.room, freshInvitation.room)
        XCTAssertNotEqual(recovered.key, freshInvitation.key)
        XCTAssertNotEqual(recovered.token, freshInvitation.token)
        phone.stop(); host.start()
        try await waitFor("fresh code registers after storage recovers") { host.hostRegistered }
        try phone.enroll(recovered.code())
        try await waitFor("fresh comparison after save failure") { host.awaitingApproval }
        XCTAssertEqual(host.pairingComparisonCode, phone.pairingComparisonCode)
        host.approve()
        try await waitFor("fresh approval connects after save failure", seconds: 25) { host.connected && phone.connected }
    }

    @MainActor
    func testPhoneSaveFailureKeepsRotatedHostTrustAndRetiresOldScan() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let hostStore = MemoryTrust(), phoneStore = MemoryTrust()
        phoneStore.refuseSave = true
        let host = RemoteCoordinator(isHost: true, store: hostStore)
        host.allowLegacyPrivateRoute = true
        let phone = RemoteCoordinator(
            isHost: false,
            store: phoneStore,
            retryLimit: 3,
            retryBaseNanoseconds: 25_000_000
        )
        phone.allowLegacyPrivateRoute = true
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
        try await waitFor("old scan retires after the service rejects its rotated key") {
            phone.status == "Pairing was interrupted. Scan a fresh QR to try again."
        }
        XCTAssertNil(phone.invitation); XCTAssertNil(phoneStore.data)
        let retained = try XCTUnwrap(hostStore.read(HostPair.self))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        XCTAssertTrue(try encoder.encode(retained) == encoder.encode(committed), "Failure cannot roll back any approved host trust field")
        XCTAssertFalse(host.awaitingApproval); XCTAssertFalse(host.connected)
        phone.start()
        XCTAssertEqual(phone.status, "Pair with your Mac first")
        XCTAssertFalse(phone.reconnecting, "Connect cannot resurrect an unapproved or failed-to-save scan")
        XCTAssertFalse(host.awaitingApproval); XCTAssertFalse(host.connected); XCTAssertFalse(phone.connected)
    }

    @MainActor
    private func connectedPair(_ url: String, name: String) async throws -> (RemoteCoordinator, RemoteCoordinator) {
        let host = RemoteCoordinator(isHost: true, store: MemoryTrust())
        host.allowLegacyPrivateRoute = true
        let phone = RemoteCoordinator(isHost: false, store: MemoryTrust())
        phone.allowLegacyPrivateRoute = true
        let invitation = try host.createPair(server: url, name: name)
        host.start()
        try await waitFor("host registered") { host.hostRegistered }
        try phone.enroll(invitation.code())
        try await waitFor("approval pending") { host.awaitingApproval }
        host.approve()
        try await waitFor("paired session connected", seconds: 25) { host.connected && phone.connected }
        return (host, phone)
    }

    @MainActor
    func testMaximumClipboardTransfersBothWaysOverTheRealControlChannel() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let (host, phone) = try await connectedPair(url, name: "Clipboard Host")
        defer { host.stop(); phone.stop() }
        let unit = "abcdé🙂\n"
        let text = String(repeating: unit, count: ClipboardLimits.maximumBytes / unit.utf8.count)
        let pasteboard = IntegrationPasteboard(.text(ClipboardPayload(text: text)))
        let clipboard = HostClipboardService(pasteboard: pasteboard)
        clipboard.transport = { frame in host.sendControl(RemoteAction(action: "clipboard", clipboard: frame)) }
        clipboard.bufferedAmount = { host.media?.controlBufferedAmount }
        host.onControl = { data in
            guard let frame = (try? JSONDecoder().decode(RemoteAction.self, from: data))?.clipboard else { return }
            clipboard.receive(frame, allowed: true)
        }

        var assembler = ClipboardAssembler()
        var received: ClipboardPayload?
        var frames = 0
        phone.onControl = { data in
            guard let frame = (try? JSONDecoder().decode(RemoteAction.self, from: data))?.clipboard else { return }
            frames += 1
            if case .complete(_, let payload) = assembler.accept(frame, at: 0) { received = payload }
        }
        let started = Date()
        var interleaved = 0
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "clipboard", clipboard: .pull(ClipboardTransferID.make()))))
        while received == nil, Date().timeIntervalSince(started) < 15 {
            if phone.sendControl(RemoteAction(action: "heartbeat")) { interleaved += 1 }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pullSeconds = Date().timeIntervalSince(started)
        XCTAssertEqual(received, ClipboardPayload(text: text))
        XCTAssertEqual(frames, ClipboardLimits.maximumChunks)
        XCTAssertTrue(host.connected && phone.connected, "Pacing must never trip the control channel's buffer guard")
        XCTAssertGreaterThan(interleaved, 0)

        var results: [String] = []
        phone.onControl = { data in
            guard let frame = (try? JSONDecoder().decode(RemoteAction.self, from: data))?.clipboard,
                  frame.op == "result", let status = frame.status else { return }
            results.append(status)
        }
        var outbox = ClipboardOutbox()
        outbox.load(try ClipboardChunker.frames(for: ClipboardPayload(text: text + "!"), operation: "push",
                                                transfer: ClipboardTransferID.make()))
        XCTAssertThrowsError(try ClipboardChunker.frames(for: ClipboardPayload(text: text + String(repeating: "!", count: 64)),
                                                         operation: "push", transfer: ClipboardTransferID.make()))
        let pushStarted = Date()
        while !outbox.isEmpty, Date().timeIntervalSince(pushStarted) < 15 {
            for frame in outbox.release(bufferedAmount: phone.media?.controlBufferedAmount) {
                XCTAssertTrue(phone.sendControl(RemoteAction(action: "clipboard", clipboard: frame)))
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await waitFor("Mac acknowledged the stored push", seconds: 10) { results == ["stored"] }
        XCTAssertEqual(pasteboard.writes, [ClipboardPayload(text: text + "!")])
        XCTAssertTrue(host.connected && phone.connected)
        print(String(format: "CLIPBOARD RECEIPT: %d bytes Mac→phone in %.2f s with %d interleaved heartbeats; phone→Mac in %.2f s",
                     text.utf8.count, pullSeconds, interleaved, Date().timeIntervalSince(pushStarted)))
    }

    @MainActor
    func testGraceExpiryEndsOnlyThePhoneSessionAndCachedTrustRejoins() async throws {
        let (service, url) = try service(); defer { service.terminate() }
        let (host, phone) = try await connectedPair(url, name: "Pause Host")
        defer { host.stop(); phone.stop() }
        var hostStatuses: [String] = []
        let observer = host.$status.sink { hostStatuses.append($0) }
        defer { withExtendedLifetime(observer) {} }

        // The first session after enrollment re-registers with rotated trust; later ones keep the room.
        for round in 0..<2 {
            XCTAssertTrue(phone.sendControl(RemoteAction(action: "pause", epoch: 1)))
            let mark = hostStatuses.count
            host.dropPeerSession()
            XCTAssertFalse(host.connected, "The paused phone's session ends at once")
            if round == 1 {
                XCTAssertTrue(host.hostRegistered, "Grace expiry keeps the host listening")
                XCTAssertEqual(host.status, "Ready for your paired phone")
            }
            try await waitFor("phone rejoined with cached credentials", seconds: 25) { host.connected && phone.connected }
            XCTAssertTrue(hostStatuses.dropFirst(mark).contains("Ready for your paired phone"))
            XCTAssertFalse(host.awaitingApproval, "Resuming never requires re-pairing")
            if round == 1 {
                XCTAssertFalse(hostStatuses.dropFirst(mark).contains { $0.contains("retrying") })
            }
        }
    }

    func testUTF16BoundAndHealthMessages() throws {
        XCTAssertThrowsError(try RemoteAction(action: "text", text: String(repeating: "a", count: 1025)).validate())
        XCTAssertNoThrow(try RemoteAction(action: "text", text: String(repeating: "👋", count: 512)).validate())
        XCTAssertThrowsError(try RemoteAction(action: "text", text: String(repeating: "👋", count: 513)).validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1).validate())
        XCTAssertNoThrow(try RemoteAction(action: "textResult", x: 1, key: "test").validate())
    }
}
