import CoreVideo
import Foundation

/// The size and format of a pixel buffer. Every buffer handed to one interpolation session must
/// match its input geometry exactly: VideoToolbox's low-latency interpolator crashes inside
/// `process(parameters:)` on inconsistent buffer geometry (Apple forums 817573).
struct FrameGeometry: Hashable, CustomStringConvertible {
    let width: Int
    let height: Int
    let pixelFormat: OSType

    init(width: Int, height: Int, pixelFormat: OSType) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }

    init(_ buffer: CVPixelBuffer) {
        self.init(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                  pixelFormat: CVPixelBufferGetPixelFormatType(buffer))
    }

    func matches(_ buffer: CVPixelBuffer) -> Bool { FrameGeometry(buffer) == self }

    static func fourCC(_ format: OSType) -> String {
        String([24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((format >> $0) & 0xff))) })
    }

    var description: String { "\(width)×\(height) \(Self.fourCC(pixelFormat))" }
}

/// One engine session: the input geometry and the spatial scale (1 = interpolation only; 2 =
/// interpolation plus 2× upscale in the same pass, iOS 27, hidden diagnostic A/B).
struct InterpolationSetup: Hashable, CustomStringConvertible {
    let input: FrameGeometry
    var scale: Int = 1

    var output: FrameGeometry {
        FrameGeometry(width: input.width * scale, height: input.height * scale, pixelFormat: input.pixelFormat)
    }

    var description: String { scale == 1 ? input.description : "\(input) ×\(scale)" }
}

/// The midpoint and, with spatial scaling, the processor's upscaled copy of the source frame
/// (it upscales the source but not the previous reference, so the source must be shown from here).
struct InterpolatedFrames {
    let middle: CVPixelBuffer
    let upscaledSource: CVPixelBuffer?
}

/// A pair must describe the same supported SDR domain; other tags are not guessed.
/// Snapshot before processing, and apply only after the engine returns buffer ownership.
struct InterpolationColorTags: Equatable {
    let primaries: String
    let transfer: String
    let matrix: String

    static let keys = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                       kCVImageBufferYCbCrMatrixKey]

    init?(_ buffer: CVPixelBuffer) {
        guard let primaries = CVBufferCopyAttachment(buffer, Self.keys[0], nil) as? String,
              primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
              let transfer = CVBufferCopyAttachment(buffer, Self.keys[1], nil) as? String,
              [kCVImageBufferTransferFunction_ITU_R_709_2 as String,
               kCVImageBufferTransferFunction_sRGB as String].contains(transfer),
              let matrix = CVBufferCopyAttachment(buffer, Self.keys[2], nil) as? String,
              [kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String,
               kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String].contains(matrix) else { return nil }
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
    }

    /// Pool buffers can retain attachments from their last use. Call before giving them to VT.
    static func clear(_ buffer: CVPixelBuffer) {
        for key in keys { CVBufferRemoveAttachment(buffer, key) }
    }

    func apply(to buffer: CVPixelBuffer) {
        Self.clear(buffer)
        for (key, value) in zip(Self.keys, [primaries, transfer, matrix]) {
            CVBufferSetAttachment(buffer, key, value as CFString, .shouldPropagate)
        }
    }
}

enum InterpolationColorTagsSwitch {
    static let defaultsKey = "PocketDeskInterpolationColorTags"
    /// Process-start A/B. NO restores the old untagged output and unchecked color pairing.
    static let isOn = read(defaults: .standard)

    static func read(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) == nil ? false : defaults.bool(forKey: defaultsKey)
    }
}

/// Largest source the interpolator accepts. iOS 27 reports it per scale factor; the iOS/macOS 27
/// release notes document "arbitrary source dimensions up to 1080p", used when nothing is reported.
struct InterpolationLimits: Equatable {
    let maxDimension: Int
    let maxPixels: Int

    static let documented = InterpolationLimits(maxDimension: 1920, maxPixels: 1920 * 1080)

    func fits(width: Int, height: Int) -> Bool {
        max(width, height) <= maxDimension && width * height <= maxPixels
    }

    /// The largest even size with the same aspect that fits, never larger than the input.
    func fitted(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        let edge = Double(maxDimension) / Double(max(width, height))
        let area = (Double(maxPixels) / Double(width * height)).squareRoot()
        let scale = min(1, edge, area)
        return (max(2, Int(Double(width) * scale) & ~1), max(2, Int(Double(height) * scale) & ~1))
    }
}

enum InterpolationError: Error, Equatable, CustomStringConvertible {
    case unsupportedDevice
    case unsupportedFormat(OSType)
    case tooLarge(width: Int, height: Int)
    case configurationRejected
    case sessionStartFailed(String)
    case geometryMismatch
    case bufferUnavailable
    case processingFailed(String)

    var description: String {
        switch self {
        case .unsupportedDevice: "not supported on this device"
        case .unsupportedFormat(let format): "format \(FrameGeometry.fourCC(format)) unsupported"
        case .tooLarge(let width, let height): "\(width)×\(height) above the interpolator's limit"
        case .configurationRejected: "configuration rejected"
        case .sessionStartFailed(let message): "session start failed: \(message)"
        case .geometryMismatch: "geometry mismatch"
        case .bufferUnavailable: "no destination buffer"
        case .processingFailed(let message): "processing failed: \(message)"
        }
    }
}

/// One frame-interpolation backend. `start` may load an ML model and take longer than a frame,
/// so it only runs on the interpolator's own queue.
protocol FrameInterpolationEngine: AnyObject {
    func start(_ setup: InterpolationSetup) throws
    /// Produces the frame halfway between `previous` and `current`. Both already match the
    /// started input geometry; the completion may run on any thread.
    func interpolate(previous: CVPixelBuffer, previousTime: TimeInterval,
                     current: CVPixelBuffer, currentTime: TimeInterval,
                     completion: @escaping (Result<InterpolatedFrames, InterpolationError>) -> Void)
    func stop()
}

/// Owns one engine session at a time, off the decode and main threads. The decode thread only
/// ever takes a lock here: it asks whether a frame can go now and hands it off, never waiting for
/// a session start, input preparation or a result. One frame is in flight at most; a frame that
/// arrives while it is busy is refused so the caller shows it directly rather than queueing work
/// that would add delay. The previous reference lives on the queue, so pairs are always the two
/// most recent frames handed in, and any frame shown without passing through here drops it.
final class FrameInterpolator: @unchecked Sendable {
    enum Phase: Equatable {
        case idle
        case starting(InterpolationSetup)
        case ready(InterpolationSetup)
        case rejected(InterpolationSetup, InterpolationError)
        case unavailable(InterpolationError)
    }

    enum Submission: Equatable {
        case accepted
        case busy
        case notReady
    }

    enum Outcome {
        /// `input` is the prepared source the pair was made from (fitted or converted if needed).
        case interpolated(InterpolatedFrames, input: CVPixelBuffer, processingMs: Double)
        /// No usable previous frame yet; this one becomes the reference.
        case primed(input: CVPixelBuffer)
        case failed(InterpolationError, input: CVPixelBuffer?, processingMs: Double)
    }

    let queue: DispatchQueue
    private let makeEngine: () -> FrameInterpolationEngine?
    private let colorTags: Bool
    private let lock = NSLock()
    private var engine: FrameInterpolationEngine?
    private var phase: Phase = .idle
    private var inFlight = false
    private var generation = 0
    private var startMs: Double?
    /// Tracks work handed to the engine, so a reconfigure or stop never ends a VideoToolbox
    /// session while it is still processing a pair.
    private let work = DispatchGroup()
    private static let drainTimeout: DispatchTimeInterval = .milliseconds(250)
    /// Queue-confined.
    private var reference: (buffer: CVPixelBuffer, time: TimeInterval, generation: Int)?

    init(queue: DispatchQueue = DispatchQueue(label: "Farside.smooth-motion", qos: .userInteractive),
         colorTags: Bool = InterpolationColorTagsSwitch.isOn,
         makeEngine: @escaping () -> FrameInterpolationEngine?) {
        self.queue = queue
        self.colorTags = colorTags
        self.makeEngine = makeEngine
    }

    var currentPhase: Phase {
        lock.lock(); defer { lock.unlock() }
        return phase
    }

    /// Session start time for the latest `ready`, logged because model loading can exceed a frame.
    var lastStartMs: Double? {
        lock.lock(); defer { lock.unlock() }
        return startMs
    }

    /// Starts or reconfigures a session for `setup` unless one is ready or starting for it.
    /// A setup the engine rejected stays rejected until the geometry or scale changes.
    func prepare(for setup: InterpolationSetup, onReady: ((Result<Double, InterpolationError>) -> Void)? = nil) {
        lock.lock()
        switch phase {
        case .starting(let current), .ready(let current), .rejected(let current, _):
            if current == setup { lock.unlock(); return }
        case .unavailable:
            lock.unlock(); return
        case .idle:
            break
        }
        phase = .starting(setup)
        generation += 1
        let startGeneration = generation
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let existing = engine
            let current = generation == startGeneration
            lock.unlock()
            guard current else { return }
            reference = nil
            _ = work.wait(timeout: .now() + Self.drainTimeout)
            existing?.stop()
            let started = MachClock.nowMs()
            let created = existing ?? makeEngine()
            var result: Result<Double, InterpolationError> = .failure(.unsupportedDevice)
            if let created {
                do {
                    try created.start(setup)
                    result = .success(MachClock.nowMs() - started)
                } catch let error as InterpolationError {
                    result = .failure(error)
                } catch {
                    result = .failure(.sessionStartFailed(String(describing: error)))
                }
            }
            lock.lock()
            engine = created
            if generation == startGeneration {
                switch result {
                case .success(let ms):
                    phase = .ready(setup)
                    startMs = ms
                case .failure(.unsupportedDevice):
                    phase = .unavailable(.unsupportedDevice)
                case .failure(let error):
                    phase = .rejected(setup, error)
                }
            }
            lock.unlock()
            onReady?(result)
        }
    }

    func isReady(for setup: InterpolationSetup) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return phase == .ready(setup)
    }

    /// The error the engine gave for exactly this setup, or for every setup on this device.
    func rejection(for setup: InterpolationSetup) -> InterpolationError? {
        lock.lock(); defer { lock.unlock() }
        switch phase {
        case .rejected(let rejected, let error) where rejected == setup: return error
        case .unavailable(let error): return error
        default: return nil
        }
    }

    /// Hands one frame over. `prepare` runs on the queue and returns the buffer to interpolate
    /// (the source itself, or a fitted or converted copy); it must match `setup.input` exactly or
    /// the pair is refused before VideoToolbox sees it.
    func submit(time: TimeInterval, setup: InterpolationSetup,
                prepare: @escaping () -> CVPixelBuffer?,
                completion: @escaping (Outcome) -> Void) -> Submission {
        lock.lock()
        guard phase == .ready(setup), let engine else { lock.unlock(); return .notReady }
        guard !inFlight else { lock.unlock(); return .busy }
        inFlight = true
        work.enter()
        let submitGeneration = generation
        lock.unlock()
        queue.async { [self] in
            let started = MachClock.nowMs()
            guard let input = prepare(), setup.input.matches(input) else {
                reference = nil
                return finish(.failed(.geometryMismatch, input: nil, processingMs: MachClock.nowMs() - started), completion)
            }
            lock.lock()
            let current = generation == submitGeneration
            lock.unlock()
            let previous = reference
            reference = current ? (input, time, submitGeneration) : nil
            guard current, let previous, previous.generation == submitGeneration,
                  setup.input.matches(previous.buffer) else {
                return finish(.primed(input: input), completion)
            }
            let tags = InterpolationColorTags(input)
            if colorTags, tags == nil || tags != InterpolationColorTags(previous.buffer) {
                // A color-domain transition primes a new reference rather than counting as a
                // processor failure. The source still goes directly to its normal renderer.
                return finish(.primed(input: input), completion)
            }
            engine.interpolate(previous: previous.buffer, previousTime: previous.time,
                               current: input, currentTime: time) { [self] result in
                let ms = MachClock.nowMs() - started
                switch result {
                case .success(let frames):
                    if colorTags, let tags {
                        tags.apply(to: frames.middle)
                        if let upscaled = frames.upscaledSource { tags.apply(to: upscaled) }
                    }
                    finish(.interpolated(frames, input: input, processingMs: ms), completion)
                case .failure(let error): finish(.failed(error, input: input, processingMs: ms), completion)
                }
            }
        }
        return .accepted
    }

    /// A frame was shown without passing through here, so the held reference is no longer the
    /// frame before the next one.
    func dropReference() {
        queue.async { [self] in reference = nil }
    }

    /// Ends the session, for teardown or a thermal fallback. The next `prepare` starts afresh.
    func stop() {
        lock.lock()
        generation += 1
        if case .unavailable = phase {} else { phase = .idle }
        let engine = engine
        self.engine = nil
        lock.unlock()
        queue.async { [self] in
            reference = nil
            _ = work.wait(timeout: .now() + Self.drainTimeout)
            engine?.stop()
        }
    }

    func waitUntilIdle() {
        queue.sync {}
    }

    private func finish(_ outcome: Outcome, _ completion: (Outcome) -> Void) {
        lock.lock(); inFlight = false; lock.unlock()
        work.leave()
        completion(outcome)
    }
}
