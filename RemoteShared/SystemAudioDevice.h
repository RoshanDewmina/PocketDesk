#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <Foundation/Foundation.h>
#import "SystemAudioCompatibility/RTCAudioDevice.h"
NS_ASSUME_NONNULL_BEGIN
/// System output only. Never opens a microphone or a hardware recording device.
@interface FPSystemAudioDevice : NSObject <RTCAudioDevice>
@property(nonatomic, readonly) BOOL consentEnabled;
@property(nonatomic, readonly) NSUInteger pendingBytes;
@property(nonatomic, readonly) NSUInteger deliveredFrames;
- (void)setConsent:(BOOL)enabled;
- (uint64_t)beginCapture;
- (void)endCapture:(uint64_t)epoch;
- (BOOL)submitPCM:(NSData *)pcm captureEpoch:(uint64_t)epoch;
- (BOOL)submitPCM:(NSData *)pcm captureEpoch:(uint64_t)epoch hostTime:(uint64_t)hostTime;
@end
NS_ASSUME_NONNULL_END
#endif
