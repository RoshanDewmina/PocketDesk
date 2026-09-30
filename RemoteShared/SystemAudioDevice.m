#import "SystemAudioDevice.h"
#import <mach/mach_time.h>
#if TARGET_OS_OSX
/// Delegate dispatch uses the ADM's fixed owning thread. All submitted blocks are bounded before
/// dispatch; a synchronous epoch fence prevents a queued block from delivering after consent ends.
@implementation FPSystemAudioDevice {
    NSRecursiveLock *_lock;
    id<RTCAudioDeviceDelegate> _delegate;
    uint64_t _epoch;
    BOOL _consent, _capture, _recording, _playing, _initialized;
    NSUInteger _pending, _delivered;
    double _sampleTime;
}
- (instancetype)init { if ((self = [super init])) _lock = [NSRecursiveLock new]; return self; }
- (BOOL)consentEnabled { [_lock lock]; BOOL v = _consent; [_lock unlock]; return v; }
- (NSUInteger)pendingBytes { [_lock lock]; NSUInteger v = _pending; [_lock unlock]; return v; }
- (NSUInteger)deliveredFrames { [_lock lock]; NSUInteger v = _delivered; [_lock unlock]; return v; }
- (void)setConsent:(BOOL)enabled { [_lock lock]; _consent = enabled; if (!enabled) { _capture = NO; _epoch++; } [_lock unlock]; }
- (uint64_t)beginCapture { [_lock lock]; _epoch++; if (!_epoch) _epoch++; _capture = _consent; _sampleTime = 0; uint64_t v = _epoch; [_lock unlock]; return v; }
- (void)endCapture:(uint64_t)epoch { [_lock lock]; if (_epoch == epoch) { _capture = NO; _epoch++; } [_lock unlock]; }
- (BOOL)submitPCM:(NSData *)pcm captureEpoch:(uint64_t)epoch { return [self submitPCM:pcm captureEpoch:epoch hostTime:mach_absolute_time()]; }
- (BOOL)submitPCM:(NSData *)pcm captureEpoch:(uint64_t)epoch hostTime:(uint64_t)hostTime {
    // 120 ms maximum queued, 20 ms per packet; stereo signed 16-bit 48 kHz.
    if (!pcm.length || pcm.length % 4 || pcm.length > 3840) return NO;
    [_lock lock];
    if (!_capture || !_consent || !_recording || epoch != _epoch || !_delegate || _pending + pcm.length > 23040) { [_lock unlock]; return NO; }
    _pending += pcm.length;
    id<RTCAudioDeviceDelegate> delegate = _delegate;
    NSData *owned = [pcm copy];
    NSTimeInterval admittedAt = NSProcessInfo.processInfo.systemUptime;
    [_lock unlock];
    [delegate dispatchAsync:^{
        [self->_lock lock];
        self->_pending -= owned.length;
        if (self->_capture && self->_consent && self->_recording && self->_epoch == epoch && self->_delegate == delegate && NSProcessInfo.processInfo.systemUptime - admittedAt <= .12) {
            AudioUnitRenderActionFlags flags = 0;
            AudioTimeStamp stamp = {0}; stamp.mSampleTime = self->_sampleTime; stamp.mHostTime = hostTime; stamp.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
            UInt32 frames = (UInt32)owned.length / 4;
            // The pinned native direct-input-buffer path spans `frames` samples instead of
            // frames*channels. The public renderBlock path allocates the correct stereo size.
            OSStatus status = delegate.deliverRecordedData(&flags, &stamp, 0, frames, NULL, NULL,
                ^OSStatus(AudioUnitRenderActionFlags *f, const AudioTimeStamp *t, NSInteger bus, UInt32 n, AudioBufferList *list, void *context) {
                    if (list->mNumberBuffers != 1 || list->mBuffers[0].mNumberChannels != 2 || list->mBuffers[0].mDataByteSize != owned.length || !list->mBuffers[0].mData) return kAudio_ParamError;
                    memcpy(list->mBuffers[0].mData, owned.bytes, owned.length);
                    return noErr;
                });
            self->_sampleTime += frames;
            if (!status) self->_delivered += frames;
        }
        [self->_lock unlock];
    }];
    return YES;
}
- (double)deviceInputSampleRate { return 48000; }
- (double)deviceOutputSampleRate { return 48000; }
- (NSTimeInterval)inputIOBufferDuration { return .01; }
- (NSTimeInterval)outputIOBufferDuration { return .01; }
- (NSInteger)inputNumberOfChannels { return 2; }
- (NSInteger)outputNumberOfChannels { return 2; }
- (NSTimeInterval)inputLatency { return 0; }
- (NSTimeInterval)outputLatency { return 0; }
- (BOOL)isInitialized { return _initialized; }
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate { [_lock lock]; _delegate = delegate; _initialized = YES; [_lock unlock]; return YES; }
- (BOOL)terminateDevice { [_lock lock]; _capture = NO; _epoch++; _delegate = nil; _recording = NO; _initialized = NO; [_lock unlock]; return YES; }
- (BOOL)isPlayoutInitialized { return YES; }
- (BOOL)initializePlayout { return YES; }
- (BOOL)isPlaying { return _playing; }
- (BOOL)startPlayout { _playing = YES; return YES; }
- (BOOL)stopPlayout { _playing = NO; return YES; }
- (BOOL)isRecordingInitialized { return YES; }
- (BOOL)initializeRecording { return YES; }
- (BOOL)isRecording { [_lock lock]; BOOL v = _recording; [_lock unlock]; return v; }
- (BOOL)startRecording { [_lock lock]; _recording = YES; [_lock unlock]; return YES; }
- (BOOL)stopRecording { [_lock lock]; _recording = NO; _capture = NO; _epoch++; [_lock unlock]; return YES; }
@end
#endif
