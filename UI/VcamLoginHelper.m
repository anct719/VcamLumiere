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

- (void)doLogin:(UIViewController *)vc
       username:(NSString *)username
       password:(NSString *)password
          error:(UILabel *)errorLabel
        spinner:(UIActivityIndicatorView *)spinner {

    if (username.length == 0 || password.length == 0) {
        errorLabel.text = @"Username and password required";
        errorLabel.hidden = NO;
        return;
    }

    // Show spinner
    [spinner startAnimating];
    errorLabel.hidden = YES;

    VcamSharedAuth *auth = [VcamSharedAuth sharedInstance];

#if VCAM_LOCAL_AUTH
    if (![username isEqualToString:kVCLocalAuthUsername] ||
        ![password isEqualToString:kVCLocalAuthPassword]) {
        [spinner stopAnimating];
        errorLabel.text = @"Invalid username or password";
        errorLabel.hidden = NO;
        return;
    }

    NSString *deviceID = [auth deviceFingerprint];
    NSString *token = [NSString stringWithFormat:@"local-%@", [auth randomNonce]];
    if (![auth writePlistAuthToken:token
                        signingKey:kVCLocalAuthSigningKey
                          deviceID:deviceID]) {
        [spinner stopAnimating];
        errorLabel.text = @"Unable to save authentication data";
        errorLabel.hidden = NO;
        return;
    }

    [spinner stopAnimating];
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
        errorLabel.text = @"Internal error (JSON)";
        errorLabel.hidden = NO;
        [spinner stopAnimating];
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
            [spinner stopAnimating];

            if (error) {
                VCLog(@"Login network error: %@", error.localizedDescription);
                errorLabel.text = [NSString stringWithFormat:@"Network error: %@",
                                   error.localizedDescription];
                errorLabel.hidden = NO;
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            VCLog(@"Login response: %ld", (long)httpResponse.statusCode);

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                options:0
                                                                  error:nil];
            if (!json) {
                errorLabel.text = @"Invalid server response";
                errorLabel.hidden = NO;
                return;
            }

            // Check for error
            NSString *errMsg = json[@"error"];
            if (errMsg) {
                errorLabel.text = errMsg;
                errorLabel.hidden = NO;
                if ([self.delegate respondsToSelector:@selector(loginDidFailWithError:)]) {
                    [self.delegate loginDidFailWithError:errMsg];
                }
                return;
            }

            // Verify nonce echo
            NSString *nonceEcho = json[@"nonce_echo"];
            if (!nonceEcho || ![nonceEcho isEqualToString:sentNonce]) {
                VCLog(@"Login: nonce echo mismatch!");
                errorLabel.text = @"Security error (nonce)";
                errorLabel.hidden = NO;
                return;
            }

            // Verify server timestamp freshness
            NSNumber *serverTs = json[@"server_ts"];
            if (![auth isFreshServerTs:serverTs maxSkew:kVCMaxTimestampSkew]) {
                VCLog(@"Login: stale server timestamp");
                errorLabel.text = @"Security error (timestamp)";
                errorLabel.hidden = NO;
                return;
            }

            // Verify response signatures (HMAC + Ed25519)
            BOOL sigValid = [auth verifyResponseSig:json
                                             secret:kVCHMACSecretHex
                                             fields:nil];
            if (!sigValid) {
                VCLog(@"Login: response signature invalid!");
                errorLabel.text = @"Security error (signature)";
                errorLabel.hidden = NO;
                return;
            }

            // Extract token and signing key
            NSString *token = json[@"token"];
            NSString *signingKey = json[@"signing_key"];

            if (!token || !signingKey) {
                errorLabel.text = @"Invalid server response (missing fields)";
                errorLabel.hidden = NO;
                return;
            }

            // Store auth data
            [auth writePlistAuthToken:token
                           signingKey:signingKey
                             deviceID:deviceID];

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
