import CoreMedia
import CoreVideo
import Foundation
import os
import VideoToolbox

/// What the installed OS reports for VideoToolbox low-latency frame interpolation, logged once
/// per session and shown in Diagnostics. The API is iOS 26+ and absent from the simulator SDK.
enum InterpolationAvailability {
    static let logger = Logger(subsystem: "com.roshan.PocketDesk", category: "smooth-motion")

    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return VTLowLatencyFrameInterpolationConfiguration.isSupported
        #endif
    }

    /// Interpolation-only limit: the OS's own report on iOS 27, else the documented 1080p.
    static let limits: InterpolationLimits = reportedLimits(scale: 1) ?? .documented

    /// 2× spatial scaling limit. Only iOS 27 can report it; nil means the A/B toggle cannot run.
    static let upscaleLimits: InterpolationLimits? = reportedLimits(scale: 2)

    /// e.g. "VT LLFI supported · ≤1920 px edge · 2.1 MP · 2× ≤960 px".
    static let summary: String = {
        guard isSupported else {
            #if targetEnvironment(simulator)
            return "VT interpolation unavailable in the simulator"
            #else
            return "VT interpolation not supported on this device"
            #endif
        }
        var parts = ["VT LLFI supported",
                     "≤\(limits.maxDimension) px edge",
                     String(format: "%.1f MP", Double(limits.maxPixels) / 1_000_000)]
        if reportedLimits(scale: 1) == nil { parts.append("(documented)") }
        if let upscaleLimits { parts.append("2× ≤\(upscaleLimits.maxDimension) px") }
        return parts.joined(separator: " · ")
    }()

    private static func reportedLimits(scale: Int) -> InterpolationLimits? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else { return nil }
        if #available(iOS 27.0, *) {
            guard let dimension = VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: scale),
                  dimension > 0 else { return nil }
            let pixels = VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: scale)
            return InterpolationLimits(maxDimension: dimension, maxPixels: pixels.flatMap { $0 > 0 ? $0 : nil } ?? dimension * dimension)
        }
        return nil
        #endif
    }

    static func makeEngine() -> FrameInterpolationEngine? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else { return nil }
        return VideoToolboxInterpolationEngine()
        #endif
    }
}

#if !targetEnvironment(simulator)
/// VTFrameProcessor with a `VTLowLatencyFrameInterpolationConfiguration` for one midpoint
/// (phase 0.5), optionally with 2× spatial scaling. Destination buffers come from a pool built
/// from the configuration's own destination attributes and the started output geometry, so the
/// previous, source and destination buffers always agree; each call re-checks that before
/// reaching VideoToolbox, which crashes rather than failing on a mismatch.
final class VideoToolboxInterpolationEngine: FrameInterpolationEngine {
    private var processor: VTFrameProcessor?
    private var pool: CVPixelBufferPool?
    private var setup: InterpolationSetup?

    func start(_ setup: InterpolationSetup) throws {
        stop()
        let input = setup.input
        let limits = setup.scale == 1 ? InterpolationAvailability.limits : InterpolationAvailability.upscaleLimits
        guard let limits, limits.fits(width: input.width, height: input.height) else {
            throw InterpolationError.tooLarge(width: input.width, height: input.height)
        }
        let made: VTLowLatencyFrameInterpolationConfiguration? = setup.scale == 1
            ? VTLowLatencyFrameInterpolationConfiguration(frameWidth: input.width, frameHeight: input.height,
                                                          numberOfInterpolatedFrames: 1)
            : VTLowLatencyFrameInterpolationConfiguration(frameWidth: input.width, frameHeight: input.height,
                                                          spatialScaleFactor: setup.scale)
        guard let configuration = made else { throw InterpolationError.configurationRejected }
        guard configuration.supportedPixelFormats.contains(input.pixelFormat) else {
            throw InterpolationError.unsupportedFormat(input.pixelFormat)
        }
        guard let pool = Self.makePool(setup.output, required: configuration.destinationPixelBufferAttributes) else {
            throw InterpolationError.bufferUnavailable
        }
        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: configuration)
        } catch {
            throw InterpolationError.sessionStartFailed(String(describing: error))
        }
        self.processor = processor
        self.pool = pool
        self.setup = setup
    }

    func interpolate(previous: CVPixelBuffer, previousTime: TimeInterval,
                     current: CVPixelBuffer, currentTime: TimeInterval,
                     completion: @escaping (Result<InterpolatedFrames, InterpolationError>) -> Void) {
        guard let processor, let pool, let setup else { return completion(.failure(.configurationRejected)) }
        guard setup.input.matches(previous), setup.input.matches(current),
              CVPixelBufferGetIOSurface(previous) != nil, CVPixelBufferGetIOSurface(current) != nil else {
            return completion(.failure(.geometryMismatch))
        }
        guard let middle = Self.buffer(from: pool, matching: setup.output) else {
            return completion(.failure(.bufferUnavailable))
        }
        let upscaled = setup.scale == 1 ? nil : Self.buffer(from: pool, matching: setup.output)
        if setup.scale != 1 && upscaled == nil { return completion(.failure(.bufferUnavailable)) }
        let previousStamp = CMTime(seconds: previousTime, preferredTimescale: 1_000_000)
        let currentStamp = CMTime(seconds: max(currentTime, previousTime + 0.000_001), preferredTimescale: 1_000_000)
        let middleStamp = CMTime(seconds: (previousStamp.seconds + currentStamp.seconds) / 2, preferredTimescale: 1_000_000)
        var destinations: [VTFrameProcessorFrame] = []
        if let frame = VTFrameProcessorFrame(buffer: middle, presentationTimeStamp: middleStamp) { destinations.append(frame) }
        if let upscaled, let frame = VTFrameProcessorFrame(buffer: upscaled, presentationTimeStamp: currentStamp) {
            destinations.append(frame)
        }
        guard destinations.count == setup.scale,
              let previousFrame = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: previousStamp),
              let sourceFrame = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: currentStamp),
              let parameters = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: sourceFrame, previousFrame: previousFrame,
                interpolationPhase: [0.5], destinationFrames: destinations) else {
            return completion(.failure(.configurationRejected))
        }
        processor.process(parameters: parameters) { _, error in
            if let error {
                completion(.failure(.processingFailed(String(describing: error))))
            } else {
                completion(.success(InterpolatedFrames(middle: middle, upscaledSource: upscaled)))
            }
        }
    }

    func stop() {
        processor?.endSession()
        processor = nil
        pool = nil
        setup = nil
    }

    private static func buffer(from pool: CVPixelBufferPool, matching geometry: FrameGeometry) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created) == kCVReturnSuccess,
              let buffer = created, geometry.matches(buffer) else { return nil }
        return buffer
    }

    private static func makePool(_ geometry: FrameGeometry, required: [String: Any]) -> CVPixelBufferPool? {
        let ours: [String: Any] = [
            kCVPixelBufferWidthKey as String: geometry.width,
            kCVPixelBufferHeightKey as String: geometry.height,
            kCVPixelBufferPixelFormatTypeKey as String: geometry.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var resolved: CFDictionary?
        let inputs = [required as CFDictionary, ours as CFDictionary] as CFArray
        guard CVPixelBufferCreateResolvedAttributesDictionary(kCFAllocatorDefault, inputs, &resolved) == kCVReturnSuccess,
              var attributes = resolved as? [String: Any] else { return nil }
        attributes[kCVPixelBufferWidthKey as String] = geometry.width
        attributes[kCVPixelBufferHeightKey as String] = geometry.height
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = geometry.pixelFormat
        var pool: CVPixelBufferPool?
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
            return nil
        }
        return pool
    }
}
#endif
