import AppKit
import ScreenCaptureKit
import VideoToolbox
import Network

final class HostStream: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "PocketDesktop.capture", qos: .userInteractive)
    var report: ((String) -> Void)?
    var metrics: ((String) -> Void)?
    var pairing: ((String) -> Void)?
    var input: ((RemoteInput) -> Void)?
    var disconnected: (() -> Void)?
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var listener: NWListener?
    private var peer: WireConnection?
    private var info: StreamInfo?
    private var busy = false
    private var frameID: UInt64 = 0
    private var pendingID: UInt64 = 0
    private var generation = UUID()
    private var peerEpoch = UUID()
    private var captured = 0
    private var sent = 0
    private var skipped = 0
    private var lastMetric = CACurrentMediaTime()
    private var controlAllowed = false

    func start(filter: SCContentFilter, lan: Bool, address: String) {
        queue.async {
            self.stopOnQueue()
            let run = self.generation
            do {
                let key = try StreamWire.randomKey()
                let rect = filter.contentRect
                guard rect.width > 0, rect.height > 0 else { throw WireError.invalid }
                let factor = min(Double(filter.pointPixelScale), 1920 / Double(rect.width), 2160 / Double(rect.height))
                let width = max(2, Int(Double(rect.width) * factor) / 2 * 2)
                let height = max(2, Int(Double(rect.height) * factor) / 2 * 2)
                self.info = StreamInfo(width: width, height: height, logicalWidth: rect.width,
                    logicalHeight: rect.height, name: filter.style == .display ? "Mac display" : "Mac window", controlAllowed: false)
                try self.makeEncoder(width: width, height: height)
                let config = SCStreamConfiguration()
                config.width = width; config.height = height
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.queueDepth = 3
                config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                config.colorSpaceName = CGColorSpace.sRGB
                config.showsCursor = true
                config.capturesAudio = false
                config.ignoreShadowsSingleWindow = true
                config.scalesToFit = true
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                self.stream = stream
                let parameters = StreamWire.parameters(key: key)
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(lan ? address : "127.0.0.1"), port: .any)
                let listener = try NWListener(using: parameters, on: .any)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, self.generation == run else { return }
                    switch state {
                    case .ready:
                        let hex = key.map { String(format: "%02x", $0) }.joined()
                        self.pairing?("pd1|\(lan ? address : "127.0.0.1")|\(listener?.port?.rawValue ?? 0)|\(hex)")
                    case .failed: self.report?("Could not open the local connection"); self.stopOnQueue()
                    default: break
                    }
                }
                listener.start(queue: self.queue)
                stream.startCapture { [weak self] error in
                    guard let self else { return }
                    self.queue.async {
                        guard self.generation == run else { return }
                        if let error { self.report?("Capture failed: \(error.localizedDescription)"); self.stopOnQueue() }
                        else { self.report?("Sharing selected content · waiting for your device") }
                    }
                }
            } catch { self.report?("Could not start: \(error.localizedDescription)"); self.stopOnQueue() }
        }
    }
    func stop() { queue.async { self.stopOnQueue(); self.report?("Sharing stopped") } }
    private func stopOnQueue() {
        generation = UUID()
        peer?.close(); peer = nil
        listener?.cancel(); listener = nil
        stream?.stopCapture(completionHandler: { _ in }); stream = nil
        if let encoder { VTCompressionSessionInvalidate(encoder) }; encoder = nil
        info = nil; busy = false; controlAllowed = false
        captured = 0; sent = 0; skipped = 0; lastMetric = CACurrentMediaTime()
        pairing?(""); disconnected?()
    }
    func setControl(_ allowed: Bool) {
        queue.async {
            self.controlAllowed = allowed
            self.info?.controlAllowed = allowed
            if let info = self.info { self.peer?.send(StreamWire.json(1, info)) }
            if !allowed { self.disconnected?() }
        }
    }
    private func accept(_ connection: NWConnection) {
        // One session owns input; an unauthenticated attempt cannot evict its peer.
        guard peer == nil else { connection.cancel(); return }
        let candidate = WireConnection(connection, queue: queue)
        peer = candidate
        let run = generation
        candidate.onReady = { [weak self, weak candidate] in
            guard let self, let candidate, let info = self.info, self.generation == run else { return }
            candidate.send(StreamWire.json(1, info))
            self.report?("Paired device connected · live video")
            self.busy = false; self.sent = 0; self.peerEpoch = UUID()
        }
        candidate.onPacket = { [weak self, weak candidate] kind, data in
            guard let self, self.generation == run, self.peer === candidate else { return }
            if kind == 3 {
                var reader = WireReader(data: data)
                if let id = try? reader.integer(UInt64.self), data.count == 8, id == self.pendingID { self.busy = false }
            } else if kind == 4 {
                guard data.count <= 16384, let event = try? JSONDecoder().decode(RemoteInput.self, from: data) else {
                    candidate?.close("Invalid input"); return
                }
                if self.controlAllowed || event.action == "release" { self.input?(event) }
            } else { candidate?.close("Unsupported message") }
        }
        candidate.onClose = { [weak self, weak candidate] reason in
            guard let self, self.generation == run, self.peer === candidate else { return }
            self.peer = nil; self.busy = false; self.disconnected?()
            self.report?("\(reason) · ready to reconnect")
        }
        candidate.start()
    }
    func makeEncoder(width: Int, height: Int) throws {
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
        guard status == noErr, let encoder else { throw NSError(domain: "HardwareEncoder", code: Int(status)) }
        for (key, value) in [
            (kVTCompressionPropertyKey_RealTime, true as CFTypeRef),
            (kVTCompressionPropertyKey_AllowFrameReordering, false as CFTypeRef),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel),
            (kVTCompressionPropertyKey_AverageBitRate, 15_000_000 as CFTypeRef),
            (kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFTypeRef),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, 60 as CFTypeRef)
        ] {
            let result = VTSessionSetProperty(encoder, key: key, value: value)
            guard result == noErr else { throw NSError(domain: "EncoderConfiguration", code: Int(result)) }
        }
        guard VTCompressionSessionPrepareToEncodeFrames(encoder) == noErr else { throw WireError.invalid }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard stream === self.stream, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let encoder else { return }
        captured += 1
        guard !busy else { skipped += 1; return }
        busy = true; frameID += 1
        let id = frameID, run = generation, epoch = peerEpoch, start = CACurrentMediaTime()
        let captureTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let needsKey = peer?.connection.state != .ready || sent == 0
        let properties = needsKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let result = VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixelBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, encoded in
                guard let self else { return }
                self.queue.async {
                    guard self.generation == run else { return }
                    guard self.peerEpoch == epoch else { return }
                    guard status == noErr, let encoded, let frame = self.serialize(encoded, id: id, captureTime: captureTime, ms: (CACurrentMediaTime() - start) * 1000) else {
                        self.busy = false; self.report?("Encoder dropped a frame"); return
                    }
                    if let peer = self.peer, peer.connection.state == .ready {
                        self.pendingID = id
                        peer.send(StreamWire.packet(2, frame.payload)); self.sent += 1
                        self.queue.asyncAfter(deadline: .now() + 2) { [weak self, weak peer] in
                            guard let self, self.generation == run, self.busy, self.pendingID == id else { return }
                            peer?.close("Video response timed out"); self.busy = false
                        }
                    } else { self.busy = false; self.sent = 0 }
                    if CACurrentMediaTime() - self.lastMetric >= 1 {
                        self.metrics?("\(self.info?.width ?? 0) × \(self.info?.height ?? 0) · H.264 hardware · encode \(String(format: "%.1f", frame.encodeMS)) ms · sent \(self.sent) · skipped \(self.skipped)")
                        self.lastMetric = CACurrentMediaTime()
                    }
                }
            }
        if result != noErr { busy = false; report?("Encode submission failed: \(result)") }
    }
    func serialize(_ sample: CMSampleBuffer, id: UInt64, captureTime: Double, ms: Double) -> VideoFrame? {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var sps: UnsafePointer<UInt8>?, pps: UnsafePointer<UInt8>?
        var spsSize = 0, ppsSize = 0, count = 0, header: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &sps,
                parameterSetSizeOut: &spsSize, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &header) == noErr,
              CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1, parameterSetPointerOut: &pps,
                parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
              let sps, let pps, header == 4, spsSize <= 65535, ppsSize <= 65535 else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length < StreamWire.maximumPacket - 131100 else { return nil }
        var bytes = Data(count: length)
        let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard status == noErr else { return nil }
        return VideoFrame(id: id, captureTime: captureTime, encodeMS: ms, sps: Data(bytes: sps, count: spsSize), pps: Data(bytes: pps, count: ppsSize), bytes: bytes)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard stream === self.stream else { return }
            self.report?("Sharing ended: \(error.localizedDescription)"); self.stopOnQueue()
        }
    }
}
