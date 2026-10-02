#import <XCTest/XCTest.h>
#import <WebRTC/WebRTC.h>
#import "../RemoteShared/SystemAudioDevice.h"
#import "RemoteCoreTests-Swift.h"
#import <mach/mach_time.h>

/// In-process, loopback-only WebRTC. Both devices are custom, so no speaker or microphone opens.
@interface LoopbackAudioPeer : NSObject <RTCPeerConnectionDelegate>
@property(nonatomic) RTCPeerConnection *connection;
@property(nonatomic, weak) LoopbackAudioPeer *other;
@property(nonatomic) NSMutableArray<RTCIceCandidate *> *candidates;
@property(nonatomic) BOOL ready;
@property(nonatomic, copy) void (^connected)(void);
@end
@implementation LoopbackAudioPeer
- (instancetype)init { if ((self = [super init])) _candidates = [NSMutableArray new]; return self; }
- (void)accept:(RTCIceCandidate *)candidate {
    if (_ready) [_connection addIceCandidate:candidate completionHandler:^(NSError *e) {}];
    else [_candidates addObject:candidate];
}
- (void)remoteReady {
    _ready = YES;
    for (RTCIceCandidate *candidate in _candidates) [_connection addIceCandidate:candidate completionHandler:^(NSError *e) {}];
    [_candidates removeAllObjects];
}
- (void)peerConnection:(RTCPeerConnection *)p didChangeSignalingState:(RTCSignalingState)s {}
- (void)peerConnection:(RTCPeerConnection *)p didAddStream:(RTCMediaStream *)s {}
- (void)peerConnection:(RTCPeerConnection *)p didRemoveStream:(RTCMediaStream *)s {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)p {}
- (void)peerConnection:(RTCPeerConnection *)p didChangeIceConnectionState:(RTCIceConnectionState)s {
    if (s == RTCIceConnectionStateConnected || s == RTCIceConnectionStateCompleted) dispatch_async(dispatch_get_main_queue(), ^{ if (self.connected) self.connected(); });
}
- (void)peerConnection:(RTCPeerConnection *)p didChangeIceGatheringState:(RTCIceGatheringState)s {}
- (void)peerConnection:(RTCPeerConnection *)p didGenerateIceCandidate:(RTCIceCandidate *)c {
    NSArray *fields = [c.sdp componentsSeparatedByString:@" "];
    if (fields.count < 5 || !([fields[4] isEqualToString:@"127.0.0.1"] || [fields[4] isEqualToString:@"::1"])) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [self.other accept:c]; });
}
- (void)peerConnection:(RTCPeerConnection *)p didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)c {}
- (void)peerConnection:(RTCPeerConnection *)p didOpenDataChannel:(RTCDataChannel *)c {}
@end

/// Pull decoded stereo on the native ADM owner thread, never a real speaker.
@interface MeasuringAudioDevice : FPSystemAudioDevice
@property(nonatomic) id<RTCAudioDeviceDelegate> fixtureDelegate;
@property(nonatomic) double leftPhaseLeft, leftPhaseRight, rightPhaseLeft, rightPhaseRight;
@end
@implementation MeasuringAudioDevice
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    self.fixtureDelegate = delegate;
    return [super initializeWithDelegate:delegate];
}
- (BOOL)terminateDevice {
    BOOL result = [super terminateDevice];
    self.fixtureDelegate = nil;
    return result;
}
- (void)measurePhase:(NSUInteger)phase {
    [self.fixtureDelegate dispatchAsync:^{
        int16_t samples[960] = {0};
        AudioBufferList list = { .mNumberBuffers = 1, .mBuffers = {{2, sizeof(samples), samples}} };
        AudioTimeStamp stamp = {0}; stamp.mHostTime = mach_absolute_time(); stamp.mFlags = kAudioTimeStampHostTimeValid;
        AudioUnitRenderActionFlags flags = 0;
        OSStatus result = self.fixtureDelegate.getPlayoutData(&flags, &stamp, 0, 480, &list);
        if (result != noErr) return;
        for (NSUInteger i = 0; i < 480; i++) {
            double left = samples[i * 2], right = samples[i * 2 + 1];
            if (phase == 1) { self.leftPhaseLeft += left * left; self.leftPhaseRight += right * right; }
            if (phase == 2) { self.rightPhaseLeft += left * left; self.rightPhaseRight += right * right; }
        }
    }];
}
@end

@interface SystemAudioTransportTests : XCTestCase
@end
@implementation SystemAudioTransportTests
- (RTCPeerConnectionFactory *)factory:(FPSystemAudioDevice *)device {
    RTCPeerConnectionFactory *f = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:nil decoderFactory:nil audioDevice:device];
    RTCPeerConnectionFactoryOptions *options = [RTCPeerConnectionFactoryOptions new];
    options.ignoreLoopbackNetworkAdapter = NO; options.ignoreWiFiNetworkAdapter = YES;
    options.ignoreEthernetNetworkAdapter = YES; options.ignoreVPNNetworkAdapter = YES; options.ignoreCellularNetworkAdapter = YES;
    [f setOptions:options]; return f;
}
- (void)testSyntheticPCMCrossesRealLoopbackOpusRTPWithoutMicrophone {
    RTCInitializeSSL();
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    BOOL txStereo = ![environment[@"FARSIDE_TEST_TX_STEREO"] isEqualToString:@"NO"];
    BOOL rxStereo = ![environment[@"FARSIDE_TEST_RX_STEREO"] isEqualToString:@"NO"];
    FPSystemAudioDevice *output = [FPSystemAudioDevice new];
    MeasuringAudioDevice *receiver = [MeasuringAudioDevice new];
    RTCPeerConnectionFactory *txFactory = [self factory:output], *rxFactory = [self factory:receiver];
    RTCConfiguration *config = [RTCConfiguration new]; config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
    LoopbackAudioPeer *tx = [LoopbackAudioPeer new], *rx = [LoopbackAudioPeer new]; tx.other = rx; rx.other = tx;
    tx.connection = [txFactory peerConnectionWithConfiguration:config constraints:constraints delegate:tx];
    rx.connection = [rxFactory peerConnectionWithConfiguration:config constraints:constraints delegate:rx];
    RTCAudioSource *source = [txFactory audioSourceWithConstraints:[[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{@"googEchoCancellation":@"false", @"googAutoGainControl":@"false", @"googNoiseSuppression":@"false"} optionalConstraints:nil]];
    RTCAudioTrack *track = [txFactory audioTrackWithSource:source trackId:@"system-fixture"];
    RTCRtpTransceiverInit *init = [RTCRtpTransceiverInit new]; init.direction = RTCRtpTransceiverDirectionSendOnly;
    [tx.connection addTransceiverWithTrack:track init:init];
    XCTestExpectation *connected = [self expectationWithDescription:@"Loopback connected"];
    __block BOOL fulfilled = NO;
    tx.connected = ^{ if (!fulfilled) { fulfilled = YES; [connected fulfill]; } };
    [tx.connection offerForConstraints:constraints completionHandler:^(RTCSessionDescription *offer, NSError *error) {
        XCTAssertNil(error);
        offer = [[RTCSessionDescription alloc] initWithType:offer.type sdp:[PeerMedia opusSDP:offer.sdp sender:YES enabled:txStereo]];
        XCTAssertEqual([offer.sdp containsString:@"sprop-stereo=1"], txStereo);
        [tx.connection setLocalDescription:offer completionHandler:^(NSError *e) {
            XCTAssertNil(e);
            [rx.connection setRemoteDescription:offer completionHandler:^(NSError *e) {
                XCTAssertNil(e); dispatch_async(dispatch_get_main_queue(), ^{ [rx remoteReady]; });
                [rx.connection answerForConstraints:constraints completionHandler:^(RTCSessionDescription *answer, NSError *e) {
                    XCTAssertNil(e);
                    answer = [[RTCSessionDescription alloc] initWithType:answer.type sdp:[PeerMedia opusSDP:answer.sdp sender:NO enabled:rxStereo]];
                    XCTAssertEqual([answer.sdp containsString:@"stereo=1"], rxStereo);
                    [rx.connection setLocalDescription:answer completionHandler:^(NSError *e) {
                        XCTAssertNil(e);
                        [tx.connection setRemoteDescription:answer completionHandler:^(NSError *e) { XCTAssertNil(e); dispatch_async(dispatch_get_main_queue(), ^{ [tx remoteReady]; }); }];
                    }];
                }];
            }];
        }];
    }];
    [self waitForExpectations:@[connected] timeout:8];
    XCTestExpectation *recording = [self expectationWithDescription:@"Native ADM recording started"];
    NSTimer *recordingTimer = [NSTimer scheduledTimerWithTimeInterval:.01 repeats:YES block:^(NSTimer *t) {
        if (output.isRecording) { [t invalidate]; [recording fulfill]; }
    }];
    [self waitForExpectations:@[recording] timeout:3]; [recordingTimer invalidate];
    XCTAssertTrue(output.isRecording);
    XCTAssertFalse(receiver.isRecording, @"Receiver has no local sending track or microphone");
    [output setConsent:YES]; uint64_t epoch = [output beginCapture];
    NSMutableData *pcm = [NSMutableData dataWithLength:1920]; int16_t *samples = pcm.mutableBytes;

    XCTestExpectation *sent = [self expectationWithDescription:@"Two seconds of synthetic PCM fixture"];
    __block NSUInteger ticks = 0;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:.01 repeats:YES block:^(NSTimer *t) {
        for (NSUInteger frame = 0; frame < 480; frame++) {
            int16_t tone = (int16_t)(6000 * sin((ticks * 480 + frame) * 2 * M_PI * 440 / 48000));
            samples[frame * 2] = ticks < 100 ? tone : 0;
            samples[frame * 2 + 1] = ticks < 100 ? 0 : tone;
        }
        [output submitPCM:pcm captureEpoch:epoch];
        [receiver measurePhase:(ticks >= 40 && ticks < 80) ? 1 : ((ticks >= 140 && ticks < 180) ? 2 : 0)];
        if (++ticks == 200) { [t invalidate]; [sent fulfill]; }
    }];
    [self waitForExpectations:@[sent] timeout:5]; [timer invalidate];
    [receiver.fixtureDelegate dispatchSync:^{}];
    printf("SYSTEM_AUDIO_STEREO leftRatio=%.6f rightRatio=%.6f\n", receiver.leftPhaseRight / fmax(receiver.leftPhaseLeft, 1), receiver.rightPhaseLeft / fmax(receiver.rightPhaseRight, 1));
    XCTAssertGreaterThan(receiver.leftPhaseLeft, 1e6);
    XCTAssertGreaterThan(receiver.rightPhaseRight, 1e6);
    if (rxStereo) {
        XCTAssertLessThan(receiver.leftPhaseRight / fmax(receiver.leftPhaseLeft, 1), .05);
        XCTAssertLessThan(receiver.rightPhaseLeft / fmax(receiver.rightPhaseRight, 1), .05);
    } else {
        XCTAssertEqualWithAccuracy(receiver.leftPhaseRight / fmax(receiver.leftPhaseLeft, 1), 1, .01);
        XCTAssertEqualWithAccuracy(receiver.rightPhaseLeft / fmax(receiver.rightPhaseRight, 1), 1, .01);
    }
    XCTestExpectation *stats = [self expectationWithDescription:@"Actual Opus RTP receipt"];
    [rx.connection statisticsWithCompletionHandler:^(RTCStatisticsReport *report) {
        NSUInteger packets = 0;
        for (RTCStatistics *stat in report.statistics.allValues) {
            if ([stat.type isEqualToString:@"inbound-rtp"] && [stat.values[@"kind"] isEqual:@"audio"]) packets += [(NSNumber *)stat.values[@"packetsReceived"] unsignedIntegerValue];
        }
        printf("SYSTEM_AUDIO_LOOPBACK packets=%lu frames=%lu noReceiverRecording=%d\n", (unsigned long)packets, (unsigned long)output.deliveredFrames, !receiver.isRecording);
        XCTAssertGreaterThanOrEqual(packets, 85u, @"Two seconds must transport stereo duration, not half-speed truncated input"); XCTAssertGreaterThan(output.deliveredFrames, 48000u);
        [stats fulfill];
    }];
    [self waitForExpectations:@[stats] timeout:3];
    [output setConsent:NO]; NSUInteger fenced = output.deliveredFrames;
    XCTAssertFalse([output submitPCM:pcm captureEpoch:epoch]); XCTAssertEqual(output.deliveredFrames, fenced);
    tx.connected = nil; [tx.connection close]; [rx.connection close]; tx.connection = nil; rx.connection = nil;
}
@end
