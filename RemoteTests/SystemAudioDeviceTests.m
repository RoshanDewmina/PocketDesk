#import <XCTest/XCTest.h>
#import <WebRTC/WebRTC.h>
#import "../RemoteShared/SystemAudioDevice.h"
@interface TestAudioDelegate : NSObject <RTCAudioDeviceDelegate>
@property(nonatomic) NSMutableArray<dispatch_block_t> *pending;
@property(nonatomic) NSUInteger frames;
@property(nonatomic) BOOL nonzero;
@end
@implementation TestAudioDelegate
- (instancetype)init { if ((self = [super init])) _pending = [NSMutableArray new]; return self; }
- (RTCAudioDeviceDeliverRecordedDataBlock)deliverRecordedData {
    return ^OSStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *stamp, NSInteger bus,
                     UInt32 frames, const AudioBufferList *list, void *context, RTCAudioDeviceRenderRecordedDataBlock render) {
        NSMutableData *data = [NSMutableData dataWithLength:frames * 4];
        AudioBufferList rendered = { .mNumberBuffers = 1, .mBuffers = { { 2, (UInt32)data.length, data.mutableBytes } } };
        if (!list && render) { render(flags, stamp, bus, frames, &rendered, context); list = &rendered; }
        self.frames += frames;
        if (list && list->mBuffers[0].mData && ((int16_t *)list->mBuffers[0].mData)[0] != 0) self.nonzero = YES;
        return noErr;
    };
}
- (RTCAudioDeviceGetPlayoutDataBlock)getPlayoutData { return ^OSStatus(AudioUnitRenderActionFlags *f, const AudioTimeStamp *t, NSInteger b, UInt32 n, AudioBufferList *d) { return noErr; }; }
- (double)preferredInputSampleRate { return 48000; }
- (double)preferredOutputSampleRate { return 48000; }
- (NSTimeInterval)preferredInputIOBufferDuration { return .01; }
- (NSTimeInterval)preferredOutputIOBufferDuration { return .01; }
- (void)notifyAudioInputParametersChange {}
- (void)notifyAudioOutputParametersChange {}
- (void)notifyAudioInputInterrupted {}
- (void)notifyAudioOutputInterrupted {}
- (void)dispatchAsync:(dispatch_block_t)block { [_pending addObject:[block copy]]; }
- (void)dispatchSync:(dispatch_block_t)block { block(); }
- (void)drain { NSArray *copy = [_pending copy]; [_pending removeAllObjects]; for (dispatch_block_t block in copy) block(); }
@end
@interface SystemAudioDeviceTests : XCTestCase
@end
@implementation SystemAudioDeviceTests
- (NSData *)packet { NSMutableData *pcm = [NSMutableData dataWithLength:1920]; ((int16_t *)pcm.mutableBytes)[0] = 42; return pcm; }
- (void)testConsentRecordingEpochAndRealPCMDelivery {
    FPSystemAudioDevice *device = [FPSystemAudioDevice new]; TestAudioDelegate *delegate = [TestAudioDelegate new];
    [device initializeWithDelegate:delegate]; [device startRecording];
    uint64_t refused = [device beginCapture];
    XCTAssertFalse([device submitPCM:[self packet] captureEpoch:refused]);
    [device setConsent:YES]; uint64_t epoch = [device beginCapture];
    XCTAssertTrue([device submitPCM:[self packet] captureEpoch:epoch]); [delegate drain];
    XCTAssertEqual(delegate.frames, 480u); XCTAssertTrue(delegate.nonzero);
    XCTAssertEqual(device.deliveredFrames, 480u); XCTAssertEqual(device.pendingBytes, 0u);
}
- (void)testMuteAndReplacementFenceAlreadyQueuedBlocks {
    FPSystemAudioDevice *device = [FPSystemAudioDevice new]; TestAudioDelegate *delegate = [TestAudioDelegate new];
    [device initializeWithDelegate:delegate]; [device startRecording]; [device setConsent:YES]; uint64_t old = [device beginCapture];
    XCTAssertTrue([device submitPCM:[self packet] captureEpoch:old]); [device setConsent:NO]; [delegate drain];
    XCTAssertEqual(delegate.frames, 0u);
    [device setConsent:YES]; uint64_t next = [device beginCapture];
    XCTAssertFalse([device submitPCM:[self packet] captureEpoch:old]);
    [device endCapture:old]; XCTAssertTrue([device submitPCM:[self packet] captureEpoch:next]);
    [device endCapture:next]; [delegate drain]; XCTAssertEqual(delegate.frames, 0u);
}
- (void)testBoundedAdmissionAndTerminateDiscard {
    FPSystemAudioDevice *device = [FPSystemAudioDevice new]; TestAudioDelegate *delegate = [TestAudioDelegate new];
    [device initializeWithDelegate:delegate]; [device startRecording]; [device setConsent:YES]; uint64_t epoch = [device beginCapture];
    for (int i = 0; i < 12; i++) XCTAssertTrue([device submitPCM:[self packet] captureEpoch:epoch]);
    XCTAssertEqual(device.pendingBytes, 23040u); XCTAssertFalse([device submitPCM:[self packet] captureEpoch:epoch]);
    XCTAssertFalse([device submitPCM:[NSMutableData dataWithLength:3844] captureEpoch:epoch]);
    XCTAssertFalse([device submitPCM:[NSMutableData dataWithLength:1919] captureEpoch:epoch]);
    [device terminateDevice]; [delegate drain]; XCTAssertEqual(delegate.frames, 0u); XCTAssertEqual(device.pendingBytes, 0u);
}
- (void)testExpiredQueueDoesNotReplayStaleAudio {
    FPSystemAudioDevice *device = [FPSystemAudioDevice new]; TestAudioDelegate *delegate = [TestAudioDelegate new];
    [device initializeWithDelegate:delegate]; [device startRecording]; [device setConsent:YES]; uint64_t epoch = [device beginCapture];
    XCTAssertTrue([device submitPCM:[self packet] captureEpoch:epoch]);
    [NSThread sleepForTimeInterval:.15]; [delegate drain];
    XCTAssertEqual(delegate.frames, 0u); XCTAssertEqual(device.pendingBytes, 0u);
    XCTAssertTrue([device submitPCM:[self packet] captureEpoch:epoch]); [delegate drain]; XCTAssertEqual(delegate.frames, 480u);
}
- (void)testPinnedMacFactoryActuallyInitializesInjectedDevice {
    RTCInitializeSSL(); FPSystemAudioDevice *device = [FPSystemAudioDevice new];
    RTCPeerConnectionFactory *factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:nil decoderFactory:nil audioDevice:device];
    RTCConfiguration *config = [RTCConfiguration new]; config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    RTCPeerConnection *peer = [factory peerConnectionWithConfiguration:config constraints:[[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil] delegate:nil];
    XCTAssertNotNil(peer); XCTAssertTrue(device.isInitialized);
    RTCAudioTrack *track = [factory audioTrackWithTrackId:@"system-output-test"];
    XCTAssertNotNil([peer addTrack:track streamIds:@[@"test"]]);
    [peer close];
}
@end
