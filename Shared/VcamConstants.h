/**
 * VcamConstants.h — All shared constants for VcamLumiere.
 *
 * Notification names, plist keys, crypto keys, and configuration defaults.
 * This file is included by both Daemon and UI targets.
 */

#ifndef VCAM_CONSTANTS_H
#define VCAM_CONSTANTS_H

#import <Foundation/Foundation.h>

#pragma mark - Version

#define VCAM_VERSION        @"2.0.3"
#define VCAM_BUILD          @"203"
#define VCAM_DISPLAY_NAME   @"VcamLumiere"

#pragma mark - Plist Paths

#define kVCPlistPath        @"/var/mobile/vc.plist"
#define kVCDebugLogPath     @"/var/mobile/vcam_debug.log"

#pragma mark - Plist Keys (Runtime Config)

#define kVCKeyRtmpURL       @"rtmpURL"
#define kVCKeyEnabled       @"enabled"
#define kVCKeyFlashEnabled  @"flashEnabled"
#define kVCKeyFlashSpeed    @"flashSpeed"
#define kVCKeyFlashBright   @"flashBrightness"
#define kVCKeyFlashArea     @"flashArea"
#define kVCKeyFlashHue      @"flashHue"
#define kVCKeyFlashOffsetX  @"flashOffsetX"
#define kVCKeyFlashOffsetY  @"flashOffsetY"
#define kVCKeyFlashMirrorX  @"flashMirrorX"

#pragma mark - Plist Keys (Auth Data)

#define kVCKeyAuthToken     @"auth_token"
#define kVCKeyAuthSignEnc   @"auth_signing_key_enc"
#define kVCKeyAuthDeviceID  @"auth_device_id"
#define kVCKeyAuthIntegrity @"auth_integrity"

#pragma mark - Darwin Notification Names

#define kVCNotifyConfig      "com.vcam.config"
#define kVCNotifyFirstFrame  "com.lumiere.vcam.firstframe"
#define kVCNotifyRevoked     "com.lumiere.vcam.revoked"
#define kVCNotifyRTMPNetwork "com.lumiere.vcam.rtmp.network"
#define kVCNotifyLiveVerify  "com.vcam.liveverify"

#pragma mark - Crypto Keys (CHANGE THESE FOR PRODUCTION)

// Ed25519 public key (hex) — used to verify server responses
// Private key is on the server only
#define kVCEd25519PubKeyHex @"6eafce5ecdf005cae58a4acbc9e670a08cd8054993e45334b34fe615c231f876"

// HMAC shared secret (hex) — must match server .env
#define kVCHMACSecretHex    @"3636b322bc8c67fc9fd3899240c9865627b7a981d626efb9f154026baab8682e"

// AES master key (hex) — used for local encryption of signing_key in plist
#define kVCAESMasterKeyHex  @"66619bc9c5623128f8d7582b7b379392bf66f662a74a91b7b985cbe194e3691b"

// Plist integrity salt
#define kVCPlistIntegritySalt @"vcam-lumiere-integrity-2024"

#pragma mark - Server Configuration

#define kVCServerBaseURL    @"https://thitconmeo.bond"
#define kVCTLSCertificateSHA256Hex @"a669438409f6984a95296cf123c6a71d790cfc99218892bf6d9ed1b5551d9b28"
#define kVCLoginPath        @"/login"
#define kVCVerifyPath       @"/verify"
#define kVCLogoutPath       @"/logout"

#pragma mark - Timing Constants

#define kVCMaxTimestampSkew   300     // seconds
#define kVCReconnectDelay1    3.0     // after connect fail
#define kVCReconnectDelay2    2.0     // after disconnect
#define kVCVerifyInterval     30.0    // periodic verify interval
#define kVCTokenExpiry        2592000 // 30 days in seconds

#pragma mark - Key Derivation Purposes

#define kVCPurposeEnc  @"enc"
#define kVCPurposeMac  @"mac"

#pragma mark - Logging

#define VCLog(fmt, ...) NSLog(@"[vc] " fmt, ##__VA_ARGS__)

#endif /* VCAM_CONSTANTS_H */
