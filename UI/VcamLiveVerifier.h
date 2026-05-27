/**
 * VcamLiveVerifier.h — Periodic license verification.
 */

#import <Foundation/Foundation.h>

@protocol VcamLiveVerifierDelegate <NSObject>
- (void)verifierDidConfirmValid;
- (void)verifierDidDetectRevocation:(NSString *)reason;
@end

@interface VcamLiveVerifier : NSObject

@property (nonatomic, weak) id<VcamLiveVerifierDelegate> delegate;

- (void)startPeriodicVerification;
- (void)stopPeriodicVerification;
- (void)verifyOnce;

@end
