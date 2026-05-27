/**
 * VcamSharedAuth.h — Authentication & Cryptography Manager.
 *
 * Shared between Daemon and UI dylibs.
 * Handles: HMAC-SHA256, AES-256 encrypt/decrypt, Ed25519 verify,
 * plist auth storage, device fingerprint, request signing.
 */

#import <Foundation/Foundation.h>

@interface VcamSharedAuth : NSObject

+ (instancetype)sharedInstance;

#pragma mark - Plist Auth CRUD

- (void)writePlistAuthToken:(NSString *)token
                 signingKey:(NSString *)signingKey
                   deviceID:(NSString *)deviceID;
- (NSString *)readPlistToken;
- (NSString *)readPlistSigningKey;
- (NSString *)readPlistDeviceID;
- (NSDictionary *)readVerifiedAuth;
- (void)clearPlistAuth;

#pragma mark - Integrity

- (NSString *)computePlistIntegrity:(NSString *)token
                         signingKey:(NSString *)signingKey
                           deviceID:(NSString *)deviceID;
- (NSString *)plistIntegrityKey;

#pragma mark - Key Derivation

- (NSData *)deriveKeyForPurpose:(NSString *)purpose;

#pragma mark - Encrypt / Decrypt

- (NSString *)encryptString:(NSString *)plaintext;
- (NSString *)decryptString:(NSString *)ciphertext;

#pragma mark - HMAC

- (NSString *)hmacHex:(NSString *)key payload:(NSString *)payload;
- (NSString *)hmacHexData:(NSData *)keyData payload:(NSString *)payload;

#pragma mark - Request Signing

- (void)signRequestHeaders:(NSMutableURLRequest *)request
                      path:(NSString *)path
                      body:(NSData *)body
                    secret:(NSString *)secret;

#pragma mark - Ed25519 Verification

- (BOOL)verifyEd25519Sig:(NSString *)sigBase64
                 payload:(NSString *)payload
                  pubKey:(NSData *)pubKey;

#pragma mark - Response Verification

- (BOOL)verifyResponseSig:(NSDictionary *)response
                   secret:(NSString *)secret
                   fields:(NSArray<NSString *> *)fields;

#pragma mark - Device

- (NSString *)deviceFingerprint;
- (NSString *)deviceModel;

#pragma mark - Utility

- (NSString *)randomNonce;
- (BOOL)isFreshServerTs:(NSNumber *)serverTs maxSkew:(NSInteger)maxSkew;
+ (NSString *)sha256Hex:(NSString *)input;
+ (NSData *)hexToData:(NSString *)hex;
+ (NSString *)dataToHex:(NSData *)data;

@end
