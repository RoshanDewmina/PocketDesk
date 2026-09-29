#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// One finger's path in screen points, with offsets in seconds from the gesture start.
@interface E2ETouchPath : NSObject
- (instancetype)initWithPoint:(CGPoint)point atOffset:(NSTimeInterval)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(NSTimeInterval)offset;
- (void)liftAtOffset:(NSTimeInterval)offset;
@end

/// Multi-finger touch synthesis for the E2E UI tests. XCUIElement has no public two- or
/// three-finger drag, so this drives XCTest's own event record classes, looked up at runtime.
/// `isAvailable` is false if a future Xcode removes them; callers then skip with a clear reason.
@interface E2ETouchSynthesizer : NSObject
+ (BOOL)isAvailable;
+ (BOOL)performPaths:(NSArray<E2ETouchPath *> *)paths name:(NSString *)name error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
