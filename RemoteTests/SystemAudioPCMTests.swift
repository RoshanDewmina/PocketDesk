import XCTest
import AVFoundation
import CoreMedia

final class SystemAudioPCMTests: XCTestCase {
    private func sample(rate: Double, frames: Int, pts: Double, value: Float = 0.25) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let memory = try XCTUnwrap(pcm.audioBufferList.pointee.mBuffers.mData).assumingMemoryBound(to: Float.self)
        for i in 0..<(frames * 2) { memory[i] = value }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                       presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: nil, dataBuffer: nil, formatDescription: format.formatDescription,
                                               sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result), noErr)
        let sample = try XCTUnwrap(result)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil,
                                                                   blockBufferMemoryAllocator: nil, flags: 0,
                                                                   bufferList: pcm.audioBufferList), noErr)
        return sample
    }
    func testResamples44100ToBoundedStereoPacketsWithoutDurationDrift() throws {
        let converter = SystemAudioPCMConverter()
        var frames = 0
        for i in 0..<200 {
            let packets = converter.packets(from: try sample(rate: 44_100, frames: 441, pts: Double(i) / 100))
            XCTAssertLessThanOrEqual(packets.count, 10)
            for packet in packets {
                XCTAssertEqual(packet.pcm.count, 1920)
                frames += packet.pcm.count / 4
                let value = packet.pcm.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
                XCTAssertGreaterThan(value, 0)
            }
        }
        XCTAssertLessThan(abs(frames - 96_000), 960, "Resampler must not accumulate duration drift")
    }
    func testDuplicateSamplesAndCumulativeClockDriftAreBounded() throws {
        let converter = SystemAudioPCMConverter()
        let first = try sample(rate: 48_000, frames: 480, pts: 10)
        XCTAssertEqual(converter.packets(from: first).count, 1)
        XCTAssertTrue(converter.packets(from: first).isEmpty)
        XCTAssertTrue(converter.packets(from: try sample(rate: 48_000, frames: 480, pts: 9)).isEmpty)
        for i in 1..<500 {
            let pts = 10 + Double(i) * 0.0103 // Deliberately drift the source clock relative to PCM.
            let packets = converter.packets(from: try sample(rate: 48_000, frames: 480, pts: pts))
            for packet in packets {
                let capturedAt = CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(packet.hostTime))
                XCTAssertLessThan(abs(capturedAt - pts), 0.051)
            }
        }
    }
    func testDiscontinuityAndFormatChangeCannotReplayPreviousPCM() throws {
        let converter = SystemAudioPCMConverter()
        _ = converter.packets(from: try sample(rate: 48_000, frames: 240, pts: 0, value: 0.8))
        let packets = converter.packets(from: try sample(rate: 44_100, frames: 882, pts: 5, value: 0.2))
        XCTAssertFalse(packets.isEmpty)
        for packet in packets { XCTAssertLessThan(packet.pcm.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }, 10_000) }
        converter.reset()
        XCTAssertTrue(converter.packets(from: try sample(rate: 48_000, frames: 48_000, pts: 10)).isEmpty)
    }
}
