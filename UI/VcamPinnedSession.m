/**
 * VcamPinnedSession.m — NSURLSession with SSL certificate pinning.
 *
 * Implements NSURLSessionDelegate for public key pinning.
 * No cookie storage, no URL cache, minimum TLS enforced.
 */

#import "VcamPinnedSession.h"
#import "../Shared/VcamConstants.h"
#import <Security/Security.h>

@interface VcamPinnedSession () <NSURLSessionDelegate>
@property (nonatomic, strong) NSURLSession *internalSession;
@end

@implementation VcamPinnedSession

+ (instancetype)sharedInstance {
    static VcamPinnedSession *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VcamPinnedSession alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.HTTPCookieStorage = nil;
        config.URLCache = nil;
        config.timeoutIntervalForRequest = 15.0;
        config.timeoutIntervalForResource = 30.0;

        if (@available(iOS 13.0, *)) {
            config.TLSMinimumSupportedProtocolVersion = tls_protocol_version_TLSv12;
        }

        _internalSession = [NSURLSession sessionWithConfiguration:config
                                                         delegate:self
                                                    delegateQueue:nil];
    }
    return self;
}

- (NSURLSession *)session {
    return _internalSession;
}

#pragma mark - NSURLSessionDelegate (SSL Pinning)

- (void)URLSession:(NSURLSession *)session
    didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
      completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,
                                  NSURLCredential *))completionHandler {

    NSString *authMethod = challenge.protectionSpace.authenticationMethod;

    if ([authMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        SecTrustRef trust = challenge.protectionSpace.serverTrust;

        if (!trust) {
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            return;
        }

        // Evaluate trust chain
        CFErrorRef error = NULL;
        BOOL trusted = SecTrustEvaluateWithError(trust, &error);

        if (!trusted) {
            VCLog(@"SSL: trust evaluation failed: %@",
                  error ? (__bridge NSError *)error : nil);
            if (error) CFRelease(error);
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            return;
        }

        /*
         * Public key pinning:
         * Extract the server's leaf certificate public key and compare
         * against our pinned key.
         *
         * For development/testing, we accept all trusted certs.
         * In production, uncomment the pinning code below and
         * set your server's public key hash.
         */

        // TODO: Enable public key pinning for production
        /*
        SecCertificateRef cert = SecTrustGetCertificateAtIndex(trust, 0);
        if (!cert) {
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            return;
        }

        SecKeyRef serverKey = SecCertificateCopyKey(cert);
        if (!serverKey) {
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            return;
        }

        CFDataRef serverKeyData = SecKeyCopyExternalRepresentation(serverKey, NULL);
        CFRelease(serverKey);

        if (!serverKeyData) {
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            return;
        }

        // Hash the public key
        NSData *keyBytes = (__bridge_transfer NSData *)serverKeyData;
        NSString *keyHash = [VcamSharedAuth sha256Hex:
            [[NSString alloc] initWithData:keyBytes encoding:NSASCIIStringEncoding]];

        // Compare with pinned hash
        NSString *pinnedHash = @"YOUR_SERVER_PUBLIC_KEY_SHA256_HASH_HERE";
        if (![keyHash isEqualToString:pinnedHash]) {
            VCLog(@"SSL: public key mismatch!");
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            return;
        }
        */

        NSURLCredential *cred = [NSURLCredential credentialForTrust:trust];
        completionHandler(NSURLSessionAuthChallengeUseCredential, cred);

    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

@end
