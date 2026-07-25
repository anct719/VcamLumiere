/**
 * VcamLoginHelper.m — Login flow implementation.
 *
 * Handles POST /login and POST /logout with full crypto contract:
 * - HMAC-SHA256 request signing
 * - Ed25519 + HMAC response verification
 * - Nonce echo validation
 * - Timestamp freshness check
 * - Auth data storage to plist
 */

#import "VcamLoginHelper.h"
#import "VcamPinnedSession.h"
#import "../Shared/VcamSharedAuth.h"
#import "../Shared/VcamConstants.h"

@implementation VcamLoginHelper

#pragma mark - Login

- (void)_notifyFailure:(NSString *)message {
    if ([self.delegate respondsToSelector:@selector(loginDidFailWithError:)]) {
        [self.delegate loginDidFailWithError:message];
    }
}

- (void)doLoginWithUsername:(NSString *)username
                   password:(NSString *)password {

    if (username.length == 0 || password.length == 0) {
        [self _notifyFailure:@"Username and password required"];
        return;
    }

#if VCAM_LOCAL_AUTH
    if (![username isEqualToString:kVCLocalAuthUsername] ||
        ![password isEqualToString:kVCLocalAuthPassword]) {
        [self _notifyFailure:@"Invalid username or password"];
        return;
    }

    VcamSharedAuth *localAuth = [VcamSharedAuth sharedInstance];
    NSString *localDeviceID = [localAuth deviceFingerprint];
    NSString *localToken = [NSString stringWithFormat:@"local-%@", [localAuth randomNonce]];
    if (![localAuth writePlistAuthToken:localToken
                             signingKey:kVCLocalAuthSigningKey
                               deviceID:localDeviceID]) {
        [self _notifyFailure:@"Unable to save authentication data"];
        return;
    }

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(kVCNotifyConfig),
        NULL, NULL, true
    );
    VCLog(@"Local login success");
    if ([self.delegate respondsToSelector:@selector(loginDidSucceed)]) {
        [self.delegate loginDidSucceed];
    }
    return;
#else

    VcamSharedAuth *auth = [VcamSharedAuth sharedInstance];

    // Build request body
    NSString *fingerprint = [auth deviceFingerprint];
    NSString *deviceID = fingerprint;  // Use fingerprint as device ID
    NSString *model = [auth deviceModel];
    NSString *iosVer = [[UIDevice currentDevice] systemVersion];

    NSDictionary *bodyDict = @{
        @"username":           username,
        @"password":           password,
        @"device_fingerprint": fingerprint,
        @"device_id":          deviceID,
        @"ios_version":        iosVer,
        @"model":              model
    };

    NSError *jsonErr = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:bodyDict
                                                      options:0
                                                        error:&jsonErr];
    if (jsonErr) {
        [self _notifyFailure:@"Internal error (JSON)"];
        return;
    }

    // Build request
    NSString *urlStr = [NSString stringWithFormat:@"%@%@", kVCServerBaseURL, kVCLoginPath];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:bodyData];

    // Sign request
    [auth signRequestHeaders:request
                        path:kVCLoginPath
                        body:bodyData
                      secret:kVCHMACSecretHex];

    NSString *sentNonce = [request valueForHTTPHeaderField:@"X-Nonce"];

    // Send request
    NSURLSession *session = [[VcamPinnedSession sharedInstance] session];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                VCLog(@"Login network error: %@", error.localizedDescription);
                [self _notifyFailure:[NSString stringWithFormat:@"Network error: %@",
                                     error.localizedDescription]];
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            VCLog(@"Login response: %ld", (long)httpResponse.statusCode);

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                options:0
                                                                  error:nil];
            if (!json) {
                [self _notifyFailure:@"Invalid server response"];
                return;
            }

            // Check for error
            NSString *errMsg = json[@"error"];
            if (errMsg) {
                [self _notifyFailure:errMsg];
                return;
            }

            // Verify nonce echo
            NSString *nonceEcho = json[@"nonce_echo"];
            if (!nonceEcho || ![nonceEcho isEqualToString:sentNonce]) {
                VCLog(@"Login: nonce echo mismatch!");
                [self _notifyFailure:@"Security error (nonce)"];
                return;
            }

            // Verify server timestamp freshness
            NSNumber *serverTs = json[@"server_ts"];
            if (![auth isFreshServerTs:serverTs maxSkew:kVCMaxTimestampSkew]) {
                VCLog(@"Login: stale server timestamp");
                [self _notifyFailure:@"Security error (timestamp)"];
                return;
            }

            // Verify response signatures (HMAC + Ed25519)
            BOOL sigValid = [auth verifyResponseSig:json
                                             secret:kVCHMACSecretHex
                                             fields:nil];
            if (!sigValid) {
                VCLog(@"Login: response signature invalid!");
                [self _notifyFailure:@"Security error (signature)"];
                return;
            }

            // Extract token and signing key
            NSString *token = json[@"token"];
            NSString *signingKey = json[@"signing_key"];

            if (!token || !signingKey) {
                [self _notifyFailure:@"Invalid server response (missing fields)"];
                return;
            }

            // Store auth data
            if (![auth writePlistAuthToken:token
                                signingKey:signingKey
                                  deviceID:deviceID]) {
                [self _notifyFailure:@"Unable to save authentication data"];
                return;
            }

            VCLog(@"Login success! Token stored.");

            // Notify config changed (so Daemon picks up new auth)
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR(kVCNotifyConfig),
                NULL, NULL, true
            );

            if ([self.delegate respondsToSelector:@selector(loginDidSucceed)]) {
                [self.delegate loginDidSucceed];
            }
        });
    }];

    [task resume];
#endif
}

#pragma mark - Logout

- (void)doLogout {
    VcamSharedAuth *auth = [VcamSharedAuth sharedInstance];

#if VCAM_LOCAL_AUTH
    [auth clearPlistAuth];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(kVCNotifyRevoked),
        NULL, NULL, true
    );
    VCLog(@"Local logout complete");
    return;
#else

    NSString *token = [auth readPlistToken];
    NSString *deviceID = [auth readPlistDeviceID];

    if (!token) {
        [auth clearPlistAuth];
        return;
    }

    // Build logout request
    NSDictionary *bodyDict = @{
        @"token": token,
        @"device_id": deviceID ?: @""
    };

    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];

    NSString *urlStr = [NSString stringWithFormat:@"%@%@", kVCServerBaseURL, kVCLogoutPath];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:bodyData];

    [auth signRequestHeaders:request
                        path:kVCLogoutPath
                        body:bodyData
                      secret:kVCHMACSecretHex];

    NSURLSession *session = [[VcamPinnedSession sharedInstance] session];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            VCLog(@"Logout network error: %@", error.localizedDescription);
        } else {
            VCLog(@"Logout request sent");
        }
    }];
    [task resume];

    // Clear local auth immediately
    [auth clearPlistAuth];

    // Notify daemon to stop
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(kVCNotifyRevoked),
        NULL, NULL, true
    );

    VCLog(@"Logout complete");
#endif
}

@end
