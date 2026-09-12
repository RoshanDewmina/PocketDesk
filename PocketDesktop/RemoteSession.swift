import SwiftUI
import AVFoundation
import Network

@Observable
final class RemoteSession {
    var status = "Not connected"
    var connecting = false
    var connected = false
    var info: StreamInfo?
    var frames = 0
    var fps = 0
    var encodeMS = 0.0
    var cursor = CGPoint(x: 0.5, y: 0.5)
    var dragging = false
    var command = false
    var shift = false
    var option = false
    var control = false
    var zoom = false
    var event = "Waiting for video"
    let display = AVSampleBufferDisplayLayer()
    @ObservationIgnored private var peer: WireConnection?
    @ObservationIgnored private var format: CMVideoFormatDescription?
    @ObservationIgnored private var lastSPS = Data()
    @ObservationIgnored private var lastPPS = Data()
    @ObservationIgnored private var lastFPS = CACurrentMediaTime()
    @ObservationIgnored private var intervalFrames = 0
    @ObservationIgnored private var attempt = UUID()
    var usable: Bool { connected && info?.controlAllowed == true }
    init() { display.videoGravity = .resizeAspect; display.backgroundColor = UIColor.black.cgColor }
    func connect(code: String) {
        disconnect()
        let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "pd1", !parts[1].isEmpty, parts[1].count < 256,
              let port = UInt16(parts[2]), port > 0, let key = StreamWire.parseKey(String(parts[3])) else {
            status = "Paste the complete connection code from your Mac."; return
        }
        let run = UUID(); attempt = run
        connecting = true; status = "Connecting to your Mac…"
        let connection = NWConnection(host: NWEndpoint.Host(String(parts[1])), port: NWEndpoint.Port(rawValue: port)!, using: StreamWire.parameters(key: key))
        let peer = WireConnection(connection, queue: .main)
        self.peer = peer
        peer.onReady = { [weak self] in
            guard let self, self.attempt == run else { return }
            self.status = "Paired · waiting for video"
        }
        peer.onPacket = { [weak self, weak peer] kind, bytes in
            guard let self, self.attempt == run else { return }
            do {
                switch kind {
                case 1:
                    guard bytes.count < 8192 else { throw WireError.invalid }
                    let value = try JSONDecoder().decode(StreamInfo.self, from: bytes)
                    guard value.version == 1, value.width > 0, value.width <= 4096, value.height > 0, value.height <= 4096,
                          value.logicalWidth.isFinite, value.logicalHeight.isFinite, value.logicalWidth > 0, value.logicalHeight > 0 else { throw WireError.invalid }
                    self.info = value; self.connected = true; self.connecting = false
                    if !value.controlAllowed { self.release() }
                    self.status = value.controlAllowed ? "Connected · control enabled" : "Connected · viewing only"
                case 2:
                    guard self.info != nil else { throw WireError.invalid }
                    let frame = try VideoFrame(payload: bytes)
                    try self.enqueue(frame)
                    var ack = Data(); ack.appendInteger(frame.id)
                    peer?.send(StreamWire.packet(3, ack))
                default: throw WireError.invalid
                }
            } catch { peer?.close("Video could not be decoded. Reconnect to try again.") }
        }
        peer.onClose = { [weak self] reason in
            guard let self, self.attempt == run else { return }
            self.connected = false; self.connecting = false; self.info = nil
            self.dragging = false; self.clearModifiers(); self.display.sampleBufferRenderer.flush(removingDisplayedImage: true)
            self.status = reason; self.peer = nil
        }
        peer.start()
    }
    func disconnect() {
        release(); attempt = UUID()
        peer?.close(); peer = nil
        connected = false; connecting = false; info = nil
        frames = 0; fps = 0; intervalFrames = 0; lastFPS = CACurrentMediaTime()
        display.sampleBufferRenderer.flush(removingDisplayedImage: true); format = nil; lastSPS = Data(); lastPPS = Data()
        status = "Not connected"
    }
    private func enqueue(_ frame: VideoFrame) throws {
        if frame.sps != lastSPS || frame.pps != lastPPS || format == nil {
            let status = frame.sps.withUnsafeBytes { sps in
                frame.pps.withUnsafeBytes { pps in
                    let pointers = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
                    let sizes = [frame.sps.count, frame.pps.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                        parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                }
            }
            guard status == noErr else { throw WireError.invalid }
            guard let format else { throw WireError.invalid }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            guard dimensions.width > 0, dimensions.height > 0, dimensions.width <= 4096, dimensions.height <= 4096 else { throw WireError.invalid }
            lastSPS = frame.sps; lastPPS = frame.pps
        }
        var nalReader = WireReader(data: frame.bytes)
        var nalCount = 0
        while nalReader.remaining > 0 {
            let length = Int(try nalReader.integer(UInt32.self))
            guard length > 0, nalCount < 4096 else { throw WireError.invalid }
            _ = try nalReader.take(length); nalCount += 1
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frame.bytes.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: frame.bytes.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { throw WireError.invalid }
        let copied = frame.bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: frame.bytes.count) }
        guard copied == noErr else { throw WireError.invalid }
        var sample: CMSampleBuffer?
        var size = frame.bytes.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(frame.id), timescale: 60), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { throw WireError.invalid }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        guard display.sampleBufferRenderer.status != .failed else { throw WireError.invalid }
        // Never discard a dependent compressed frame; close/restart if the decoder cannot keep up.
        guard display.sampleBufferRenderer.isReadyForMoreMediaData else { throw WireError.invalid }
        display.sampleBufferRenderer.enqueue(sample)
        intervalFrames += 1
        let now = CACurrentMediaTime()
        if now - lastFPS >= 1 { frames += intervalFrames; fps = Int(Double(intervalFrames) / (now - lastFPS)); encodeMS = frame.encodeMS; intervalFrames = 0; lastFPS = now }
    }
    private func send(_ input: RemoteInput) {
        guard usable || input.action == "release" else { event = "Enable control on your Mac"; return }
        peer?.send(StreamWire.json(4, input)); event = input.action.capitalized
    }
    func move(_ delta: CGSize, viewport: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite, usable else { return }
        cursor.x = min(1, max(0, cursor.x + delta.width / max(1, viewport.width)))
        cursor.y = min(1, max(0, cursor.y + delta.height / max(1, viewport.height)))
        send(RemoteInput(action: "move", x: cursor.x, y: cursor.y))
    }
    func click(_ action: String = "click") { send(RemoteInput(action: action, x: cursor.x, y: cursor.y)) }
    func toggleDrag() { guard usable else { return }; dragging.toggle(); click("drag") }
    func scroll(_ delta: CGSize) { send(RemoteInput(action: "scroll", x: delta.width, y: delta.height)) }
    func text(_ value: String) {
        guard !value.isEmpty else { return }
        for chunk in value.chunksOfUTF16(maximum: 512) { send(RemoteInput(action: "text", text: chunk)) }
        shift = false
    }
    func key(_ name: String) {
        let modifiers = [("command", command),("shift", shift),("option", option),("control", control)].filter(\.1).map(\.0)
        send(RemoteInput(action: "key", key: name, modifiers: modifiers)); clearModifiers()
    }
    func release() {
        peer?.send(StreamWire.json(4, RemoteInput(action: "release")))
        dragging = false; clearModifiers()
    }
    func clearModifiers() { command = false; shift = false; option = false; control = false }
}

private extension String {
    func chunksOfUTF16(maximum: Int) -> [String] {
        var output: [String] = [], chunk = ""
        for character in self {
            if chunk.utf16.count + String(character).utf16.count > maximum { if !chunk.isEmpty { output.append(chunk) }; chunk = "" }
            if String(character).utf16.count <= maximum { chunk.append(character) }
        }
        if !chunk.isEmpty { output.append(chunk) }; return output
    }
}

struct LiveVideoView: UIViewRepresentable {
    let session: RemoteSession
    func makeUIView(context: Context) -> VideoContainer { VideoContainer(display: session.display) }
    func updateUIView(_ view: VideoContainer, context: Context) { view.display.videoGravity = session.zoom ? .resizeAspectFill : .resizeAspect }
}
final class VideoContainer: UIView {
    let display: AVSampleBufferDisplayLayer
    init(display: AVSampleBufferDisplayLayer) { self.display = display; super.init(frame: .zero); backgroundColor = .black; clipsToBounds = true; layer.addSublayer(display) }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); CATransaction.begin(); CATransaction.setDisableActions(true); display.frame = bounds; CATransaction.commit() }
}
