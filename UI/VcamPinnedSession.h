/**
 * VcamPinnedSession.h — NSURLSession with SSL certificate pinning.
 */

#import <Foundation/Foundation.h>

@interface VcamPinnedSession : NSObject

+ (instancetype)sharedInstance;
- (NSURLSession *)session;

@end
