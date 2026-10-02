import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreMedia
import CoreImage
import UniformTypeIdentifiers
import ImageIO
import UnlockCore

final class Frame: NSObject, SCStreamOutput {
    let lock = NSLock()
    var result: Data?
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixel = CMSampleBufferGetImageBuffer(buffer),
              let image = CIContext().createCGImage(CIImage(cvPixelBuffer: pixel), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))) else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        lock.lock(); if result == nil { result = data as Data }; lock.unlock()
    }
    func take() -> Data? { lock.lock(); defer { lock.unlock() }; let value = result; result = nil; return value }
}
final class Agent: NSObject, NSXPCListenerDelegate, AgentAPI {
    let queue = DispatchQueue(label: "unlock.prototype.input")
    let lifecycle = DispatchQueue(label: "unlock.prototype.lifecycle")
    var busy = false
    // An unresponsive framework await cannot retain capture indefinitely: exit only this standalone agent.
    // No KeepAlive is configured. A human must uninstall/reinstall after this bounded failure.
    func begin(seconds: Double) -> DispatchWorkItem? {
        lifecycle.sync {
            guard !busy else { return nil }; busy = true
            let timeout = DispatchWorkItem { _exit(70) }
            lifecycle.asyncAfter(deadline: .now() + seconds, execute: timeout)
            return timeout
        }
    }
    func end(_ timeout: DispatchWorkItem) { lifecycle.sync { timeout.cancel(); busy = false } }
    // Physical keycodes, no modifiers: intentional restriction to ABC/U.S. lowercase+digits.
    let keys: [UInt8: CGKeyCode] = Dictionary(uniqueKeysWithValues: zip(Array("abcdefghijklmnopqrstuvwxyz0123456789".utf8), [0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6,29,18,19,20,21,23,22,26,28,25].map(CGKeyCode.init)))
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == 0 else { return false }
        connection.setCodeSigningRequirement(Prototype.requirement(["daemon"]))
        connection.exportedInterface = NSXPCInterface(with: AgentAPI.self)
        connection.exportedObject = self; connection.resume(); return true
    }
    func capture(_ deadline: Double, reply: @escaping (Data?, String) -> Void) {
        guard Prototype.canCapture(), deadline > Date().timeIntervalSince1970, deadline - Date().timeIntervalSince1970 <= 30 else { reply(nil, "DENIED"); return }
        guard let timeout = begin(seconds: 16) else { reply(nil, "BUSY"); return }
        Task {
            defer { self.end(timeout) }
            var stream: SCStream?
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard Date().timeIntervalSince1970 < deadline, Prototype.canCapture(), let display = content.displays.first else { reply(nil, "NO_DISPLAY_OR_DENIED"); return }
                let config = SCStreamConfiguration()
                config.width = min(display.width, 1920)
                config.height = max(1, display.height * config.width / max(1, display.width))
                config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
                config.queueDepth = 3; config.showsCursor = false; config.capturesAudio = false
                let frame = Frame()
                let capture = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []), configuration: config, delegate: nil)
                stream = capture
                guard Date().timeIntervalSince1970 < deadline, Prototype.canCapture() else { reply(nil, "EXPIRED_OR_DENIED"); return }
                try capture.addStreamOutput(frame, type: .screen, sampleHandlerQueue: DispatchQueue(label: "unlock.prototype.frame"))
                try await capture.startCapture()
                var result: Data?
                while Date().timeIntervalSince1970 < deadline && Prototype.canCapture() {
                    if let data = frame.take() { result = data; break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try await capture.stopCapture()
                guard Date().timeIntervalSince1970 < deadline, Prototype.canCapture(), let data = result else { reply(nil, "NO_FRAME_OR_SESSION_CHANGED"); return }
                reply(data, "FRAME")
            } catch {
                if let stream { try? await stream.stopCapture() }
                reply(nil, "CAPTURE_FAILED") // No OS descriptions, window names or contents in logs.
            }
        }
    }
    func typePassword(_ bytes: Data, deadline: Double, reply: @escaping (String) -> Void) {
        guard let timeout = begin(seconds: 11) else { reply("BUSY"); return }
        queue.async {
            defer { self.end(timeout) }
            var secret = bytes
            defer { secret.resetBytes(in: secret.startIndex..<secret.endIndex) }
            guard getuid() != 0, Policy.validPassword(secret), AXIsProcessTrusted(), Prototype.canType(deadline: deadline),
                  let source = CGEventSource(stateID: .privateState) else { reply("DENIED"); return }
            // A fresh guard for every character and Return. Never read AX field values, pasteboard or event taps.
            for byte in secret {
                guard Prototype.canType(deadline: deadline), let key = self.keys[byte], self.post(key, source: source) else { reply("SESSION_CHANGED_OR_INPUT_FAILED"); return }
                usleep(30_000)
            }
            guard Prototype.canType(deadline: deadline), self.post(36, source: source) else { reply("SESSION_CHANGED_OR_INPUT_FAILED"); return }
            reply("POSTED_NOT_VERIFIED")
        }
    }
    func post(_ key: CGKeyCode, source: CGEventSource) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = []; up.flags = []
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }
}
if CommandLine.arguments == [CommandLine.arguments[0], "--consent"] {
    guard getuid() != 0 else { exit(1) }
    _ = NSApplication.shared
    _ = CGRequestScreenCaptureAccess()
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    exit(0)
}
guard CommandLine.arguments.count == 1, let config = Prototype.configuration(), config.enabled,
      getuid() == 0 || getuid() == config.uid else { exit(1) }
_ = NSApplication.shared
let agent = Agent()
let listener = NSXPCListener.anonymous()
listener.delegate = agent; listener.resume()
// Daemon restart/reload must not leave a dangling endpoint. Re-register periodically.
var daemon: NSXPCConnection?
func connect() {
    guard daemon == nil else { return }
    let connection = NSXPCConnection(machServiceName: Prototype.service, options: .privileged)
    connection.setCodeSigningRequirement(Prototype.requirement(["daemon"]))
    connection.remoteObjectInterface = NSXPCInterface(with: DaemonAPI.self)
    connection.invalidationHandler = { DispatchQueue.main.async { daemon = nil } }
    connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
    daemon = connection; connection.resume()
    let broker = connection.remoteObjectProxyWithErrorHandler { _ in } as! DaemonAPI
    broker.registerAgent(listener.endpoint) { _ in }
}
connect()
let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in connect() }
RunLoop.current.run()
