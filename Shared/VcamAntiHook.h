/**
 * VcamAntiHook.h — Anti-tampering detection.
 */

#import <Foundation/Foundation.h>

@interface VcamAntiHook : NSObject

+ (instancetype)sharedInstance;

- (BOOL)isCompromised;
- (void)scatterTrip;
- (BOOL)scatterTripped;

@end
