/**
 * VcamPinnedSession.m — NSURLSession with SSL certificate pinning.
 *
 * Implements NSURLSessionDelegate for public key pinning.
 * No cookie storage, no URL cache, minimum TLS enforced.
 */

#import "VcamPinnedSession.h"
#import "../Shared/VcamConstants.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *certificateSHA256(NSData *certificateData) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(certificateData.bytes, (CC_LONG)certificateData.length, digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

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
        NSString *expectedHost = [NSURL URLWithString:kVCServerBaseURL].host;

        if (!trust ||
            [challenge.protectionSpace.host caseInsensitiveCompare:expectedHost] != NSOrderedSame) {
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            return;
        }

        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(trust, 0);
        if (!certificate) {
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            return;
        }

        NSData *certificateData = CFBridgingRelease(SecCertificateCopyData(certificate));
        NSString *actualHash = certificateSHA256(certificateData);
        if ([actualHash caseInsensitiveCompare:kVCTLSCertificateSHA256Hex] != NSOrderedSame) {
            VCLog(@"SSL: certificate pin mismatch for %@", challenge.protectionSpace.host);
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            return;
        }

        // Evaluate normally first. This private certificate has an internal SAN,
        // so the fallback binds the expected request host to the exact pinned leaf
        // above, then evaluates its X.509 validity with that leaf as the anchor.
        CFErrorRef error = NULL;
        BOOL trusted = SecTrustEvaluateWithError(trust, &error);
        if (!trusted) {
            if (error) CFRelease(error);
            error = NULL;

            NSArray *anchors = @[(__bridge id)certificate];
            SecPolicyRef basicPolicy = SecPolicyCreateBasicX509();
            if (!basicPolicy) {
                completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
                return;
            }
            OSStatus anchorStatus = SecTrustSetAnchorCertificates(
                trust, (__bridge CFArrayRef)anchors);
            OSStatus policyStatus = SecTrustSetPolicies(trust, basicPolicy);
            CFRelease(basicPolicy);
            if (anchorStatus == errSecSuccess && policyStatus == errSecSuccess) {
                SecTrustSetAnchorCertificatesOnly(trust, true);
                trusted = SecTrustEvaluateWithError(trust, &error);
            }
        }

        if (!trusted) {
            VCLog(@"SSL: trust evaluation failed: %@",
                  error ? (__bridge NSError *)error : nil);
            if (error) CFRelease(error);
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            return;
        }

        if (error) CFRelease(error);

        NSURLCredential *cred = [NSURLCredential credentialForTrust:trust];
        completionHandler(NSURLSessionAuthChallengeUseCredential, cred);

    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

@end
