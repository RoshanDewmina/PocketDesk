import Foundation
#if os(macOS)
import AVFoundation
import CoreMedia

/// Confined to the capture output queue. Converts real SCK PCM; no microphone or synthetic audio.
/// Source discontinuities discard converter state, rather than replaying stale audio to catch up.
struct SystemAudioPacket {
    let pcm: Data
    let hostTime: UInt64
}

final class SystemAudioPCMConverter {
    static let outputRate = 48_000.0
    static let packetFrames = 480
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?
    private var nextPTS: Double?
    private var lastPTS: Double?
    private var remainder = Data()
    private var packetPTS: Double?
    private let sourceAgeEnabled: Bool
    private let hostClockNow: () -> CMTime
    /// Source buffers the 120 ms age fence refused (cumulative; a slow screen frame ahead of audio
    /// on the shared capture queue shows up here rather than as silent audio loss).
    private(set) var staleDrops = 0
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: outputRate,
                                      channels: 2, interleaved: true)!

    // Snapshot once per capture converter. Explicit NO keeps the legacy continuity-only path.
    init(sourceAgeEnabled: Bool? = nil, defaults: UserDefaults = .standard,
         hostClockNow: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }) {
        self.sourceAgeEnabled = sourceAgeEnabled ?? (defaults.object(forKey: "PocketDeskAudioSourceAge") == nil
            || defaults.bool(forKey: "PocketDeskAudioSourceAge"))
        self.hostClockNow = hostClockNow
    }

    func reset() { converter = nil; format = nil; nextPTS = nil; lastPTS = nil; packetPTS = nil; remainder.removeAll(keepingCapacity: false) }

    func packets(from sample: CMSampleBuffer) -> [SystemAudioPacket] {
        guard sample.isValid, let description = CMSampleBufferGetFormatDescription(sample) else { reset(); return [] }
        let source = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sample)
        let pts = CMTimeGetSeconds(sourcePTS)
        guard source.sampleRate.isFinite, (8_000...192_000).contains(source.sampleRate),
              (1...2).contains(source.channelCount), frames > 0,
              frames <= Int(source.sampleRate / 10), pts.isFinite, pts >= 0 else { reset(); return [] }
        if sourceAgeEnabled {
            // Preserve the producer's existing PTS→host timeline contract; do not re-age old PCM.
            // Retire the remainder and resampler too, so stale partial PCM cannot join fresh sound.
            let age = CMTimeSubtract(hostClockNow(), sourcePTS)
            guard age.isNumeric, CMTimeCompare(age, CMTime(value: 120, timescale: 1_000)) <= 0 else {
                staleDrops += 1; reset(); return []
            }
        }
        // Never encode a duplicate/reversed source sample. Re-anchor when the cumulative source
        // clock differs from the produced PCM clock by 50 ms, so long sessions cannot build drift.
        if let lastPTS, pts <= lastPTS { return [] }
        if let nextPTS, abs(pts - nextPTS) > 0.05 { reset() }
        if let packetPTS, abs(pts - (packetPTS + Double(remainder.count / 4) / Self.outputRate)) > 0.05 { reset() }
        lastPTS = pts
        if source != format {
            converter = AVAudioConverter(from: source, to: output)
            format = source
            remainder.removeAll(keepingCapacity: false)
            packetPTS = pts
        }
        nextPTS = pts + Double(frames) / source.sampleRate
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames)),
              let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 5_280) else { return [] }
        input.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                         into: input.mutableAudioBufferList) == noErr else { reset(); return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard error == nil, status != .error else { reset(); return [] }
        let buffer = converted.audioBufferList.pointee.mBuffers
        guard converted.frameLength > 0, let bytes = buffer.mData else { return [] }
        remainder.append(Data(bytes: bytes, count: Int(converted.frameLength) * 4))
        // At most 100 ms of converted PCM; caller's ADM adds its independent 120 ms admission cap.
        guard remainder.count <= 21_120 else { reset(); return [] }
        var packets: [SystemAudioPacket] = []
        while remainder.count >= Self.packetFrames * 4 {
            let time = packetPTS ?? pts
            packets.append(SystemAudioPacket(pcm: Data(remainder.prefix(Self.packetFrames * 4)),
                                             hostTime: CMClockConvertHostTimeToSystemUnits(CMTime(seconds: time, preferredTimescale: 1_000_000_000))))
            packetPTS = time + Double(Self.packetFrames) / Self.outputRate
            remainder.removeFirst(Self.packetFrames * 4)
        }
        return packets
    }
}
#endif
