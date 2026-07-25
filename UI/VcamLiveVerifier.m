/**
 * VcamLiveVerifier.m — Periodic license verification.
 *
 * Runs every 30 seconds while stream is active.
 * POST /verify with signed request.
 * On revocation: posts Darwin notification to kill stream.
 */

#import "VcamLiveVerifier.h"
#import "VcamPinnedSession.h"
#import "../Shared/VcamSharedAuth.h"
#import "../Shared/VcamConstants.h"

@interface VcamLiveVerifier ()
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation VcamLiveVerifier

- (void)startPeriodicVerification {
    [self stopPeriodicVerification];

#if VCAM_LOCAL_AUTH
    VCLog(@"LiveVerifier: local auth mode");
    [self verifyOnce];
    return;
#else

    VCLog(@"LiveVerifier: starting periodic verify (%.0fs interval)", kVCVerifyInterval);

    // Verify immediately
    [self verifyOnce];

    // Schedule periodic
    self.timer = [NSTimer scheduledTimerWithTimeInterval:kVCVerifyInterval
                                                 target:self
                                               selector:@selector(verifyOnce)
                                               userInfo:nil
                                                repeats:YES];
#endif
}

- (void)stopPeriodicVerification {
    if (self.timer) {
        [self.timer invalidate];
        self.timer = nil;
        VCLog(@"LiveVerifier: stopped");
    }
}

- (void)verifyOnce {
#if VCAM_LOCAL_AUTH
    NSDictionary *localAuth = [[VcamSharedAuth sharedInstance] readVerifiedAuth];
    if (!localAuth) {
        [self _handleRevocation:@"missing_local_auth"];
        return;
    }

    if ([self.delegate respondsToSelector:@selector(verifierDidConfirmValid)]) {
        [self.delegate verifierDidConfirmValid];
    }
    return;
#else
    VcamSharedAuth *auth = [VcamSharedAuth sharedInstance];

    NSString *token = [auth readPlistToken];
    NSString *deviceID = [auth readPlistDeviceID];

    if (!token || !deviceID) {
        VCLog(@"LiveVerifier: no auth data, skipping verify");
        [self _handleRevocation:@"missing_auth"];
        return;
    }

    // Build request
    NSDictionary *bodyDict = @{
        @"token":     token,
        @"device_id": deviceID
    };

    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];

    NSString *urlStr = [NSString stringWithFormat:@"%@%@", kVCServerBaseURL, kVCVerifyPath];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:bodyData];

    [auth signRequestHeaders:request
                        path:kVCVerifyPath
                        body:bodyData
                      secret:kVCHMACSecretHex];

    NSString *sentNonce = [request valueForHTTPHeaderField:@"X-Nonce"];

    NSURLSession *session = [[VcamPinnedSession sharedInstance] session];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        if (error) {
            VCLog(@"LiveVerifier: network error: %@", error.localizedDescription);
            // Don't revoke on network error — could be temporary
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) {
            VCLog(@"LiveVerifier: invalid response");
            return;
        }

        // Verify nonce echo
        NSString *nonceEcho = json[@"nonce_echo"];
        if (!nonceEcho || ![nonceEcho isEqualToString:sentNonce]) {
            VCLog(@"LiveVerifier: nonce mismatch");
            return;
        }

        // Verify response signature
        BOOL sigValid = [auth verifyResponseSig:json
                                         secret:kVCHMACSecretHex
                                         fields:nil];
        if (!sigValid) {
            VCLog(@"LiveVerifier: response signature invalid");
            return;
        }

        BOOL valid = [json[@"valid"] boolValue];

        if (valid) {
            VCLog(@"LiveVerifier: token valid");
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(verifierDidConfirmValid)]) {
                    [self.delegate verifierDidConfirmValid];
                }
            });
        } else {
            NSString *reason = json[@"reason"] ?: @"unknown";
            VCLog(@"LiveVerifier: token INVALID reason=%@", reason);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _handleRevocation:reason];
            });
        }
    }];
    [task resume];
#endif
}

- (void)_handleRevocation:(NSString *)reason {
    [self stopPeriodicVerification];

    // Post revocation notification
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(kVCNotifyRevoked),
        NULL, NULL, true
    );

    if ([self.delegate respondsToSelector:@selector(verifierDidDetectRevocation:)]) {
        [self.delegate verifierDidDetectRevocation:reason];
    }
}

@end
