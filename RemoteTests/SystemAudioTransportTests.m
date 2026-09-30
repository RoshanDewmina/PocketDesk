#import <XCTest/XCTest.h>
#import <WebRTC/WebRTC.h>
#import "../RemoteShared/SystemAudioDevice.h"

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
    FPSystemAudioDevice *output = [FPSystemAudioDevice new], *receiver = [FPSystemAudioDevice new];
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
        [tx.connection setLocalDescription:offer completionHandler:^(NSError *e) {
            XCTAssertNil(e);
            [rx.connection setRemoteDescription:offer completionHandler:^(NSError *e) {
                XCTAssertNil(e); dispatch_async(dispatch_get_main_queue(), ^{ [rx remoteReady]; });
                [rx.connection answerForConstraints:constraints completionHandler:^(RTCSessionDescription *answer, NSError *e) {
                    XCTAssertNil(e);
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
    for (int i = 0; i < 960; i++) samples[i] = (int16_t)(6000 * sin((i / 2) * 2 * M_PI * 440 / 48000));
    XCTestExpectation *sent = [self expectationWithDescription:@"Two seconds of synthetic PCM fixture"];
    __block NSUInteger ticks = 0;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:.01 repeats:YES block:^(NSTimer *t) {
        [output submitPCM:pcm captureEpoch:epoch];
        if (++ticks == 200) { [t invalidate]; [sent fulfill]; }
    }];
    [self waitForExpectations:@[sent] timeout:5]; [timer invalidate];
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
