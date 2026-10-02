import XCTest
import AVFoundation
import CoreMedia

final class SystemAudioPCMTests: XCTestCase {
    func testAudioQueueSplitAndRollbackSelectExpectedQueue() {
        let capture = DispatchQueue(label: "audio-test.capture-owner")
        let split = CaptureAudioQueue(captureQueue: capture, splitEnabled: true)
        let rollback = CaptureAudioQueue(captureQueue: capture, splitEnabled: false)
        XCTAssertFalse(split.queue === capture)
        XCTAssertTrue(rollback.queue === capture, "Rollback uses the original screen callback queue")
        for owner in [split, rollback] {
            owner.sync { owner.sync {} } // Fencing on the owner queue must not deadlock.
        }
    }

    func testSplitAudioWorkDoesNotWaitForCaptureQueue() {
        let capture = DispatchQueue(label: "audio-test.blocked-capture")
        let owner = CaptureAudioQueue(captureQueue: capture, splitEnabled: true)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        capture.async { entered.signal(); release.wait() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        defer { release.signal(); capture.sync {} }
        let audio = expectation(description: "Audio remains independent of picture work")
        owner.queue.async { audio.fulfill() }
        wait(for: [audio], timeout: 2)
    }

    func testAudioFenceRejectsLatePCMInBothQueueModes() {
        for splitEnabled in [true, false] {
            let owner = CaptureAudioQueue(captureQueue: DispatchQueue(label: "audio-test.fence"), splitEnabled: splitEnabled)
            var admission = CaptureAudioAdmission()
            var ended: [UInt64] = []
            owner.sync {
                admission.configure(capturesAudio: true, allowed: true, begin: { 7 }, end: { ended.append($0) })
                XCTAssertEqual(admission.admittedEpoch(consent: true), 7)
            }
            owner.sync { admission.retire(end: { ended.append($0) }) }
            owner.sync {
                XCTAssertNil(admission.admittedEpoch(consent: true), "Queued PCM cannot reuse the retired epoch")
                XCTAssertEqual(ended, [7])
                admission.configure(capturesAudio: true, allowed: false, begin: { XCTFail("Stale completion cannot arm after Listen-off"); return 8 }, end: { ended.append($0) })
                XCTAssertNil(admission.admittedEpoch(consent: false))
                admission.configure(capturesAudio: true, allowed: true, begin: { 9 }, end: { ended.append($0) })
                XCTAssertEqual(admission.admittedEpoch(consent: true), 9)
                XCTAssertNil(admission.admittedEpoch(consent: false), "Live peer consent is checked for every callback")
                admission.configure(capturesAudio: false, allowed: true, begin: { 10 }, end: { ended.append($0) })
                XCTAssertNil(admission.admittedEpoch(consent: true))
                XCTAssertEqual(ended, [7, 9])
                admission.retire(terminal: true, end: { ended.append($0) })
                admission.configure(capturesAudio: true, allowed: true, begin: { XCTFail("Stop/scope fence cannot be rearmed by a late completion"); return 11 }, end: { ended.append($0) })
                XCTAssertNil(admission.admittedEpoch(consent: true))
            }
        }
    }

    func testAudioFenceWaitsForAnInProgressCallbackInBothQueueModes() {
        for splitEnabled in [true, false] {
            let owner = CaptureAudioQueue(captureQueue: DispatchQueue(label: "audio-test.in-progress"), splitEnabled: splitEnabled)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let fenced = DispatchSemaphore(value: 0)
            owner.queue.async { entered.signal(); release.wait() }
            XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
            DispatchQueue.global().async { owner.sync {}; fenced.signal() }
            XCTAssertEqual(fenced.wait(timeout: .now()), .timedOut, "Fence cannot return while an audio callback is running")
            release.signal()
            XCTAssertEqual(fenced.wait(timeout: .now() + 2), .success)
        }
    }

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
