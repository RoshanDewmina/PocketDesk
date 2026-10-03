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
        let converter = SystemAudioPCMConverter(sourceAgeEnabled: false)
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
        let converter = SystemAudioPCMConverter(sourceAgeEnabled: false)
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
        let converter = SystemAudioPCMConverter(sourceAgeEnabled: false)
        _ = converter.packets(from: try sample(rate: 48_000, frames: 240, pts: 0, value: 0.8))
        let packets = converter.packets(from: try sample(rate: 44_100, frames: 882, pts: 5, value: 0.2))
        XCTAssertFalse(packets.isEmpty)
        for packet in packets { XCTAssertLessThan(packet.pcm.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }, 10_000) }
        converter.reset()
        XCTAssertTrue(converter.packets(from: try sample(rate: 48_000, frames: 48_000, pts: 10)).isEmpty)
    }

    func testSourceAgeDefaultsOnAndExplicitOffAreSnapshottedAtStartup() throws {
        let suite = "SystemAudioPCMTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = try sample(rate: 48_000, frames: 480, pts: 10)
        let bounded = SystemAudioPCMConverter(defaults: defaults, hostClockNow: { CMTime(seconds: 11, preferredTimescale: 1_000_000) })
        defaults.set(false, forKey: "PocketDeskAudioSourceAge")
        XCTAssertTrue(bounded.packets(from: old).isEmpty, "Absent switch defaults ON and later changes cannot disable an existing converter")
        let legacy = SystemAudioPCMConverter(defaults: defaults, hostClockNow: { CMTime(seconds: 11, preferredTimescale: 1_000_000) })
        defaults.set(true, forKey: "PocketDeskAudioSourceAge")
        XCTAssertEqual(legacy.packets(from: old).count, 1, "Explicit NO retains legacy conversion of synthetic/old PTS")
        defaults.set("NO", forKey: "PocketDeskAudioSourceAge")
        let commandLineRollback = SystemAudioPCMConverter(defaults: defaults, hostClockNow: { .invalid })
        XCTAssertEqual(commandLineRollback.packets(from: old).count, 1, "NSUserDefaults command-line NO strings must restore legacy behavior too")
    }

    func testSourceAgeBoundaryKeepsOriginalPacketHostTime() throws {
        let converter = SystemAudioPCMConverter(sourceAgeEnabled: true, hostClockNow: { CMTime(seconds: 100, preferredTimescale: 1_000_000) })
        let freshPTS = 99.88
        let packets = converter.packets(from: try sample(rate: 48_000, frames: 480, pts: freshPTS))
        XCTAssertEqual(packets.count, 1, "Exactly 120 ms remains eligible")
        let packet = try XCTUnwrap(packets.first)
        XCTAssertEqual(CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(packet.hostTime)), freshPTS, accuracy: 0.000001)
        converter.reset()
        XCTAssertTrue(converter.packets(from: try sample(rate: 48_000, frames: 480, pts: 99.879)).isEmpty)
    }

    func testStaleSourceResetsPartialPCMBeforeFreshCaptureResumes() throws {
        var now = 100.0
        let converter = SystemAudioPCMConverter(sourceAgeEnabled: true, hostClockNow: { CMTime(seconds: now, preferredTimescale: 1_000_000) })
        XCTAssertTrue(converter.packets(from: try sample(rate: 48_000, frames: 240, pts: 99.9, value: 0.8)).isEmpty)
        now = 100.2
        XCTAssertTrue(converter.packets(from: try sample(rate: 48_000, frames: 240, pts: 99.905, value: 0.8)).isEmpty, "Continuous but stale PCM must be dropped before joining the remainder")
        XCTAssertEqual(converter.staleDrops, 1, "Each refused source buffer is counted for stream stats")
        now = 100.205
        XCTAssertTrue(converter.packets(from: try sample(rate: 48_000, frames: 240, pts: 100.2, value: 0.2)).isEmpty)
        let fresh = converter.packets(from: try sample(rate: 48_000, frames: 240, pts: 100.205, value: 0.2))
        XCTAssertEqual(fresh.count, 1)
        for packet in fresh { XCTAssertLessThan(packet.pcm.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }, 10_000) }

        converter.reset()
        now = 200
        XCTAssertTrue(converter.packets(from: try sample(rate: 48_000, frames: 240, pts: 199.99, value: 0.8)).isEmpty)
        XCTAssertTrue(converter.packets(from: try sample(rate: 48_000, frames: 240, pts: 199.8, value: 0.8)).isEmpty)
        XCTAssertTrue(converter.packets(from: try sample(rate: 48_000, frames: 240, pts: 199.995, value: 0.2)).isEmpty,
                      "Even an older stale sample must retire the prior partial packet before a continuous fresh sample")
        XCTAssertEqual(converter.staleDrops, 2, "The counter survives reset so every refused buffer reaches the stats line")
    }

    func testDiscontinuityAndResetFencePCMInBothSourceAgeStates() throws {
        for enabled in [true, false] {
            var now = 10.01
            let converter = SystemAudioPCMConverter(sourceAgeEnabled: enabled, hostClockNow: { CMTime(seconds: now, preferredTimescale: 1_000_000) })
            _ = converter.packets(from: try sample(rate: 48_000, frames: 240, pts: 10, value: 0.8))
            now = 15.01
            let packets = converter.packets(from: try sample(rate: 48_000, frames: 480, pts: 15, value: 0.2))
            XCTAssertEqual(packets.count, 1)
            for packet in packets { XCTAssertLessThan(packet.pcm.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }, 10_000) }
            _ = converter.packets(from: try sample(rate: 48_000, frames: 240, pts: 15.01, value: 0.8))
            converter.reset()
            now = 15.02
            XCTAssertTrue(converter.packets(from: try sample(rate: 48_000, frames: 240, pts: 15.015, value: 0.2)).isEmpty)
        }
    }
}
