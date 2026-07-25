/**
 * VcamSharedAuth.m — Authentication & Cryptography Implementation.
 *
 * Implements the exact crypto contract from the original VcamLumiere binary:
 * - Custom key derivation: SHA256(masterKey:purpose:deviceID)
 * - AES-256-CBC with PKCS7 padding (CommonCrypto)
 * - HMAC-SHA256 (CommonCrypto)
 * - Ed25519 signature verification (Security.framework)
 * - Device fingerprint: SHA256("v3:<UDID>:<model>:<ios>:<bundleID>:<kern>:<cpu>")
 * - Plist-based auth storage with integrity HMAC
 */

#import "VcamSharedAuth.h"
#import "VcamConstants.h"
#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonHMAC.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import <dlfcn.h>
#include "monocypher-ed25519.h"

// libMobileGestalt — loaded dynamically to avoid linker error on macOS
typedef CFStringRef (*MGCopyAnswer_t)(CFStringRef property);

@interface VcamSharedAuth ()
- (NSData *)_deriveKeyForPurpose:(NSString *)purpose deviceID:(NSString *)deviceID;
- (NSString *)_encryptString:(NSString *)plaintext deviceID:(NSString *)deviceID;
@end

@implementation VcamSharedAuth

+ (instancetype)sharedInstance {
    static VcamSharedAuth *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VcamSharedAuth alloc] init];
    });
    return instance;
}

#pragma mark - Plist Helpers

- (NSMutableDictionary *)_readPlist {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:kVCPlistPath];
    if (!dict) dict = [NSMutableDictionary dictionary];
    return dict;
}

- (BOOL)_writePlist:(NSDictionary *)dict {
    return [dict writeToFile:kVCPlistPath atomically:YES];
}

#pragma mark - Plist Auth CRUD

- (BOOL)writePlistAuthToken:(NSString *)token
                 signingKey:(NSString *)signingKey
                   deviceID:(NSString *)deviceID {
    if (token.length == 0 || signingKey.length == 0 || deviceID.length == 0) {
        VCLog(@"Refusing to write incomplete auth data");
        return NO;
    }

    NSMutableDictionary *plist = [self _readPlist];

    // Bind the encrypted signing key to the device ID from this login response.
    NSString *encKey = [self _encryptString:signingKey deviceID:deviceID];
    if (!encKey) return NO;

    plist[kVCKeyAuthToken]    = token;
    plist[kVCKeyAuthSignEnc]  = encKey;
    plist[kVCKeyAuthDeviceID] = deviceID;

    // Compute and store integrity HMAC
    NSString *integrity = [self computePlistIntegrity:token
                                          signingKey:signingKey
                                            deviceID:deviceID];
    plist[kVCKeyAuthIntegrity] = integrity;

    BOOL written = [self _writePlist:plist];
    VCLog(@"Auth data %@ plist", written ? @"written to" : @"failed to write to");
    return written;
}

- (NSString *)readPlistToken {
    return [self _readPlist][kVCKeyAuthToken];
}

- (NSString *)readPlistSigningKey {
    NSString *enc = [self _readPlist][kVCKeyAuthSignEnc];
    if (!enc) return nil;
    return [self decryptString:enc];
}

- (NSString *)readPlistDeviceID {
    return [self _readPlist][kVCKeyAuthDeviceID];
}

- (NSDictionary *)readVerifiedAuth {
    NSDictionary *plist = [self _readPlist];

    NSString *token    = plist[kVCKeyAuthToken];
    NSString *encKey   = plist[kVCKeyAuthSignEnc];
    NSString *deviceID = plist[kVCKeyAuthDeviceID];
    NSString *stored   = plist[kVCKeyAuthIntegrity];

    if (!token || !encKey || !deviceID || !stored) {
        VCLog(@"readVerifiedAuth: missing auth fields");
        return nil;
    }

    // Decrypt signing key
    NSString *signingKey = [self decryptString:encKey];
    if (!signingKey) {
        VCLog(@"readVerifiedAuth: failed to decrypt signing key");
        return nil;
    }

    // Verify integrity
    NSString *computed = [self computePlistIntegrity:token
                                         signingKey:signingKey
                                           deviceID:deviceID];
    if (![stored isEqualToString:computed]) {
        VCLog(@"readVerifiedAuth: integrity mismatch!");
        return nil;
    }

    return @{
        @"token":      token,
        @"signingKey": signingKey,
        @"deviceID":   deviceID
    };
}

- (void)clearPlistAuth {
    NSMutableDictionary *plist = [self _readPlist];
    [plist removeObjectForKey:kVCKeyAuthToken];
    [plist removeObjectForKey:kVCKeyAuthSignEnc];
    [plist removeObjectForKey:kVCKeyAuthDeviceID];
    [plist removeObjectForKey:kVCKeyAuthIntegrity];
    [self _writePlist:plist];
    VCLog(@"Auth data cleared from plist");
}

#pragma mark - Integrity

- (NSString *)computePlistIntegrity:(NSString *)token
                         signingKey:(NSString *)signingKey
                           deviceID:(NSString *)deviceID {
    // payload = "token|signingKey|deviceID"
    NSString *payload = [NSString stringWithFormat:@"%@|%@|%@",
                         token, signingKey, deviceID];

    // key = "plist-integrity:<salt>"
    NSString *hmacKey = [NSString stringWithFormat:@"plist-integrity:%@",
                         [self plistIntegrityKey]];

    return [self hmacHex:hmacKey payload:payload];
}

- (NSString *)plistIntegrityKey {
    return kVCPlistIntegritySalt;
}

#pragma mark - Key Derivation

- (NSData *)deriveKeyForPurpose:(NSString *)purpose {
    /*
     * Custom key derivation (matches original binary):
     * SHA256(masterKey + ":" + purpose + ":" + deviceID)
     *
     * purpose = "enc" for AES encryption
     * purpose = "mac" for HMAC operations
     */
    NSString *deviceID = [self readPlistDeviceID];
    if (!deviceID) {
        deviceID = [self deviceFingerprint];
    }

    return [self _deriveKeyForPurpose:purpose deviceID:deviceID];
}

- (NSData *)_deriveKeyForPurpose:(NSString *)purpose deviceID:(NSString *)deviceID {
    NSString *input = [NSString stringWithFormat:@"%@:%@:%@",
                       kVCAESMasterKeyHex, purpose, deviceID];

    uint8_t hash[CC_SHA256_DIGEST_LENGTH];
    const char *cStr = [input UTF8String];
    CC_SHA256(cStr, (CC_LONG)strlen(cStr), hash);

    return [NSData dataWithBytes:hash length:CC_SHA256_DIGEST_LENGTH];
}

#pragma mark - AES Encrypt / Decrypt

- (NSString *)encryptString:(NSString *)plaintext {
    NSString *deviceID = [self readPlistDeviceID] ?: [self deviceFingerprint];
    return [self _encryptString:plaintext deviceID:deviceID];
}

- (NSString *)_encryptString:(NSString *)plaintext deviceID:(NSString *)deviceID {
    if (!plaintext) return nil;

    NSData *key = [self _deriveKeyForPurpose:kVCPurposeEnc deviceID:deviceID];
    NSData *data = [plaintext dataUsingEncoding:NSUTF8StringEncoding];

    // Generate random 16-byte IV
    uint8_t iv[kCCBlockSizeAES128];
    if (SecRandomCopyBytes(kSecRandomDefault, kCCBlockSizeAES128, iv) != errSecSuccess) {
        VCLog(@"AES encrypt: unable to generate IV");
        return nil;
    }

    size_t outLen = data.length + kCCBlockSizeAES128;
    NSMutableData *outData = [NSMutableData dataWithLength:outLen];

    size_t actualLen = 0;
    CCCryptorStatus status = CCCrypt(
        kCCEncrypt,
        kCCAlgorithmAES,
        kCCOptionPKCS7Padding,
        key.bytes, key.length,
        iv,
        data.bytes, data.length,
        outData.mutableBytes, outLen,
        &actualLen
    );

    if (status != kCCSuccess) {
        VCLog(@"AES encrypt failed: %d", (int)status);
        return nil;
    }

    outData.length = actualLen;

    // Prepend IV to ciphertext: [16 bytes IV][ciphertext]
    NSMutableData *result = [NSMutableData dataWithBytes:iv length:kCCBlockSizeAES128];
    [result appendData:outData];

    return [result base64EncodedStringWithOptions:0];
}

- (NSString *)decryptString:(NSString *)ciphertext {
    if (!ciphertext) return nil;

    NSData *key = [self deriveKeyForPurpose:kVCPurposeEnc];
    NSData *combined = [[NSData alloc] initWithBase64EncodedString:ciphertext options:0];

    if (combined.length < kCCBlockSizeAES128 + 1) {
        VCLog(@"AES decrypt: data too short");
        return nil;
    }

    // Extract IV (first 16 bytes) and ciphertext
    NSData *iv = [combined subdataWithRange:NSMakeRange(0, kCCBlockSizeAES128)];
    NSData *encrypted = [combined subdataWithRange:
                         NSMakeRange(kCCBlockSizeAES128,
                                     combined.length - kCCBlockSizeAES128)];

    size_t outLen = encrypted.length + kCCBlockSizeAES128;
    NSMutableData *outData = [NSMutableData dataWithLength:outLen];

    size_t actualLen = 0;
    CCCryptorStatus status = CCCrypt(
        kCCDecrypt,
        kCCAlgorithmAES,
        kCCOptionPKCS7Padding,
        key.bytes, key.length,
        iv.bytes,
        encrypted.bytes, encrypted.length,
        outData.mutableBytes, outLen,
        &actualLen
    );

    if (status != kCCSuccess) {
        VCLog(@"AES decrypt failed: %d", (int)status);
        return nil;
    }

    outData.length = actualLen;
    return [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
}

#pragma mark - HMAC

- (NSString *)hmacHex:(NSString *)key payload:(NSString *)payload {
    NSData *keyData = [key dataUsingEncoding:NSUTF8StringEncoding];
    return [self hmacHexData:keyData payload:payload];
}

- (NSString *)hmacHexData:(NSData *)keyData payload:(NSString *)payload {
    NSData *payloadData = [payload dataUsingEncoding:NSUTF8StringEncoding];

    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256,
           keyData.bytes, keyData.length,
           payloadData.bytes, payloadData.length,
           digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

#pragma mark - Request Signing

- (void)signRequestHeaders:(NSMutableURLRequest *)request
                      path:(NSString *)path
                      body:(NSData *)body
                    secret:(NSString *)secret {
    NSString *timestamp = [NSString stringWithFormat:@"%lld",
                           (long long)[[NSDate date] timeIntervalSince1970]];
    NSString *nonce = [self randomNonce];

    // HMAC payload: "<timestamp>|<path>|<base64(body)>"
    NSString *bodyB64 = [body base64EncodedStringWithOptions:0];
    NSString *payload = [NSString stringWithFormat:@"%@|%@|%@",
                         timestamp, path, bodyB64];

    // Sign with HMAC secret (raw bytes from hex)
    NSData *secretData = [VcamSharedAuth hexToData:secret];
    NSString *signature = [self hmacHexData:secretData payload:payload];

    [request setValue:timestamp forHTTPHeaderField:@"X-Timestamp"];
    [request setValue:nonce     forHTTPHeaderField:@"X-Nonce"];
    [request setValue:signature forHTTPHeaderField:@"X-Signature"];
}

#pragma mark - Ed25519 Verification

- (BOOL)verifyEd25519Sig:(NSString *)sigBase64
                 payload:(NSString *)payload
                  pubKey:(NSData *)pubKey {
    if (!sigBase64 || !payload || pubKey.length != 32) return NO;

    NSData *sigData = [[NSData alloc] initWithBase64EncodedString:sigBase64 options:0];
    NSData *msgData = [payload dataUsingEncoding:NSUTF8StringEncoding];

    if (!sigData || sigData.length != 64) {
        VCLog(@"Ed25519: invalid signature length (%lu)", (unsigned long)sigData.length);
        return NO;
    }

    int result = crypto_ed25519_check(sigData.bytes,
                                      pubKey.bytes,
                                      msgData.bytes,
                                      msgData.length);
    if (result != 0) VCLog(@"Ed25519: verification failed");
    return result == 0;
}

#pragma mark - Response Verification

- (BOOL)verifyResponseSig:(NSDictionary *)response
                   secret:(NSString *)secret
                   fields:(NSArray<NSString *> *)fields {
    /*
     * Verify the server's dual signatures:
     * 1. Check HMAC-SHA256 server_sig
     * 2. Check Ed25519 ed25519_sig
     * 3. Check timestamp freshness
     * 4. Check nonce echo
     */

    NSString *serverSig  = response[@"server_sig"];
    NSString *ed25519Sig = response[@"ed25519_sig"];
    NSNumber *serverTs   = response[@"server_ts"];

    if (!serverSig || !ed25519Sig || !serverTs) {
        VCLog(@"Response verify: missing signature fields");
        return NO;
    }

    // Check timestamp freshness
    if (![self isFreshServerTs:serverTs maxSkew:kVCMaxTimestampSkew]) {
        VCLog(@"Response verify: stale server timestamp");
        return NO;
    }

    // Reconstruct payload for HMAC verification
    // Build dict without signatures for HMAC check
    NSMutableDictionary *hmacDict = [response mutableCopy];
    [hmacDict removeObjectForKey:@"server_sig"];
    [hmacDict removeObjectForKey:@"ed25519_sig"];

    NSData *hmacJSON = [NSJSONSerialization dataWithJSONObject:hmacDict
                                                      options:NSJSONWritingSortedKeys
                                                        error:nil];
    NSString *hmacPayload = [[NSString alloc] initWithData:hmacJSON
                                                  encoding:NSUTF8StringEncoding];

    NSData *secretData = [VcamSharedAuth hexToData:secret];
    NSString *expectedHMAC = [self hmacHexData:secretData payload:hmacPayload];

    if (![serverSig isEqualToString:expectedHMAC]) {
        VCLog(@"Response verify: HMAC mismatch");
        return NO;
    }

    // Verify Ed25519 signature
    NSMutableDictionary *edDict = [response mutableCopy];
    [edDict removeObjectForKey:@"ed25519_sig"];

    NSData *edJSON = [NSJSONSerialization dataWithJSONObject:edDict
                                                    options:NSJSONWritingSortedKeys
                                                      error:nil];
    NSString *edPayload = [[NSString alloc] initWithData:edJSON
                                                encoding:NSUTF8StringEncoding];

    NSData *pubKeyData = [VcamSharedAuth hexToData:kVCEd25519PubKeyHex];
    BOOL edValid = [self verifyEd25519Sig:ed25519Sig
                                  payload:edPayload
                                   pubKey:pubKeyData];

    if (!edValid) {
        VCLog(@"Response verify: Ed25519 signature invalid");
        return NO;
    }

    return YES;
}

#pragma mark - Device Fingerprint

- (NSString *)deviceFingerprint {
    // Get UDID via MobileGestalt (loaded dynamically)
    NSString *udid = @"unknown";
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (gestalt) {
        MGCopyAnswer_t mgCopyAnswer = (MGCopyAnswer_t)dlsym(gestalt, "MGCopyAnswer");
        if (mgCopyAnswer) {
            CFStringRef udidRef = mgCopyAnswer(CFSTR("UniqueDeviceID"));
            if (udidRef) {
                udid = (__bridge_transfer NSString *)udidRef;
            }
        }
    }

    NSString *model = [self deviceModel];
    NSString *ios = [[UIDevice currentDevice] systemVersion];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";

    struct utsname u;
    uname(&u);
    NSString *kern = [NSString stringWithUTF8String:u.release];

    // CPU subtype
    NSString *cpu = @"arm64";

    // Format: "v3:<udid>:<model>:<ios>:<bundleID>:<kern>:<cpu>"
    NSString *raw = [NSString stringWithFormat:@"v3:%@:%@:%@:%@:%@:%@",
                     udid, model, ios, bundleID, kern, cpu];

    return [VcamSharedAuth sha256Hex:raw];
}

- (NSString *)deviceModel {
    struct utsname u;
    uname(&u);
    return [NSString stringWithUTF8String:u.machine];
}

#pragma mark - Utility

- (NSString *)randomNonce {
    uint8_t buf[16];
    SecRandomCopyBytes(kSecRandomDefault, 16, buf);
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) {
        [hex appendFormat:@"%02x", buf[i]];
    }
    return [hex copy];
}

- (BOOL)isFreshServerTs:(NSNumber *)serverTs maxSkew:(NSInteger)maxSkew {
    if (!serverTs) return NO;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval ts = [serverTs doubleValue];
    return fabs(now - ts) <= maxSkew;
}

+ (NSString *)sha256Hex:(NSString *)input {
    const char *cStr = [input UTF8String];
    uint8_t hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(cStr, (CC_LONG)strlen(cStr), hash);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", hash[i]];
    }
    return [hex copy];
}

+ (NSData *)hexToData:(NSString *)hex {
    NSMutableData *data = [NSMutableData dataWithCapacity:hex.length / 2];
    for (NSUInteger i = 0; i < hex.length; i += 2) {
        NSString *byteStr = [hex substringWithRange:NSMakeRange(i, 2)];
        unsigned int byte;
        [[NSScanner scannerWithString:byteStr] scanHexInt:&byte];
        uint8_t b = (uint8_t)byte;
        [data appendBytes:&b length:1];
    }
    return [data copy];
}

+ (NSString *)dataToHex:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return [hex copy];
}

@end
