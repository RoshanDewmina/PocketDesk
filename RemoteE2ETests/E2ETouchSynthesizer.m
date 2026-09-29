#import "E2ETouchSynthesizer.h"

// Selectors implemented by XCTest's XCPointerEventPath and XCSynthesizedEventRecord.
@interface NSObject (E2EXCTestEventSynthesis)
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
- (instancetype)initWithName:(NSString *)name interfaceOrientation:(long long)orientation;
- (void)addPointerEventPath:(id)path;
- (BOOL)synthesizeWithError:(NSError **)error;
@end

typedef NS_ENUM(NSInteger, E2ETouchStep) { E2ETouchStepDown, E2ETouchStepMove, E2ETouchStepUp };

@implementation E2ETouchPath {
    NSMutableArray<NSArray *> *_steps;
}

- (instancetype)initWithPoint:(CGPoint)point atOffset:(NSTimeInterval)offset {
    if ((self = [super init])) {
        _steps = [NSMutableArray array];
        [_steps addObject:@[@(E2ETouchStepDown), [NSValue valueWithBytes:&point objCType:@encode(CGPoint)], @(offset)]];
    }
    return self;
}

- (void)moveToPoint:(CGPoint)point atOffset:(NSTimeInterval)offset {
    [_steps addObject:@[@(E2ETouchStepMove), [NSValue valueWithBytes:&point objCType:@encode(CGPoint)], @(offset)]];
}

- (void)liftAtOffset:(NSTimeInterval)offset {
    CGPoint zero = CGPointZero;
    [_steps addObject:@[@(E2ETouchStepUp), [NSValue valueWithBytes:&zero objCType:@encode(CGPoint)], @(offset)]];
}

- (nullable id)makeXCTestPath {
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    if (pathClass == nil || _steps.count == 0) { return nil; }
    id path = nil;
    for (NSArray *step in _steps) {
        E2ETouchStep kind = (E2ETouchStep)[step[0] integerValue];
        CGPoint point = CGPointZero;
        [step[1] getValue:&point];
        double offset = [step[2] doubleValue];
        switch (kind) {
            case E2ETouchStepDown: path = [[pathClass alloc] initForTouchAtPoint:point offset:offset]; break;
            case E2ETouchStepMove: [path moveToPoint:point atOffset:offset]; break;
            case E2ETouchStepUp: [path liftUpAtOffset:offset]; break;
        }
    }
    return path;
}
@end

@implementation E2ETouchSynthesizer

+ (BOOL)isAvailable {
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    return pathClass != nil && recordClass != nil
        && [pathClass instancesRespondToSelector:@selector(initForTouchAtPoint:offset:)]
        && [pathClass instancesRespondToSelector:@selector(moveToPoint:atOffset:)]
        && [pathClass instancesRespondToSelector:@selector(liftUpAtOffset:)]
        && [recordClass instancesRespondToSelector:@selector(initWithName:interfaceOrientation:)]
        && [recordClass instancesRespondToSelector:@selector(addPointerEventPath:)]
        && [recordClass instancesRespondToSelector:@selector(synthesizeWithError:)];
}

+ (BOOL)performPaths:(NSArray<E2ETouchPath *> *)paths name:(NSString *)name error:(NSError **)error {
    if (![self isAvailable]) {
        if (error) {
            *error = [NSError errorWithDomain:@"E2ETouchSynthesizer" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"XCTest event synthesis classes are unavailable"}];
        }
        return NO;
    }
    // UIInterfaceOrientationPortrait == 1. The E2E suite runs in portrait.
    id record = [[NSClassFromString(@"XCSynthesizedEventRecord") alloc] initWithName:name interfaceOrientation:1];
    for (E2ETouchPath *path in paths) {
        id xcPath = [path makeXCTestPath];
        if (xcPath == nil) {
            if (error) {
                *error = [NSError errorWithDomain:@"E2ETouchSynthesizer" code:2
                                         userInfo:@{NSLocalizedDescriptionKey: @"empty touch path"}];
            }
            return NO;
        }
        [record addPointerEventPath:xcPath];
    }
    return [record synthesizeWithError:error];
}
@end
