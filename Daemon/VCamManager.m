/**
 * VCamManager.m — Stream orchestrator.
 *
 * Coordinates:
 * - RTMPClient for pulling RTMP stream
 * - H264Decoder for decoding video frames
 * - Frame storage for hook injection
 * - Config reload from plist
 * - Darwin notification handling
 */

#import "VCamManager.h"
#import "RTMPClient.h"
#import "H264Decoder.h"
#import "../Shared/VcamConstants.h"
#import "../Shared/VcamSharedAuth.h"
#import "../Shared/VcamAntiHook.h"

@interface VCamManager () <RTMPClientDelegate>

@property (nonatomic, strong) RTMPClient *rtmpClient;
@property (nonatomic, copy) NSString *rtmpURL;
@property (nonatomic, assign) BOOL enabled;

@end

@implementation VCamManager

+ (instancetype)sharedInstance {
    static VCamManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isLive = NO;
        _hasFirstFrame = NO;
        _currentPixelBuffer = NULL;

        [self _registerNotifications];
        [self reloadConfig];
    }
    return self;
}

#pragma mark - Config

- (void)reloadConfig {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kVCPlistPath];
    if (!plist) {
        VCLog(@"VCamManager: no config plist found");
        return;
    }

    NSString *newURL = plist[kVCKeyRtmpURL];
    BOOL newEnabled = [plist[kVCKeyEnabled] boolValue];

    VCLog(@"VCamManager: config reload - enabled=%d url=%@", newEnabled, newURL);

    if (newEnabled && newURL.length > 0) {
        if (!self.isLive || ![newURL isEqualToString:self.rtmpURL]) {
            self.rtmpURL = newURL;
            self.enabled = YES;
            [self startWithURL:newURL];
        }
    } else if (!newEnabled && self.isLive) {
        [self stop];
    }
}

#pragma mark - Start / Stop

- (void)startWithURL:(NSString *)url {
    // Anti-hook check
    if ([[VcamAntiHook sharedInstance] isCompromised]) {
        VCLog(@"[vc-antihook] compromised -> killing stream");
        return;
    }

    // License check
    NSDictionary *auth = [[VcamSharedAuth sharedInstance] readVerifiedAuth];
    if (!auth) {
        VCLog(@"license check FAILED reason=missing_auth, refusing to start");
        return;
    }

    VCLog(@"license check OK, starting stream");

    self.rtmpURL = url;

    if (self.rtmpClient) {
        [self.rtmpClient stop];
    }

    self.rtmpClient = [[RTMPClient alloc] init];
    self.rtmpClient.delegate = self;

    // Set up decoder callback
    __weak typeof(self) weakSelf = self;
    self.rtmpClient.decoder.onFrame = ^(CVPixelBufferRef pixelBuffer, CMTime pts) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        CVPixelBufferRetain(pixelBuffer);
        CVPixelBufferRef old = strongSelf.currentPixelBuffer;
        strongSelf.currentPixelBuffer = pixelBuffer;
        if (old) CVPixelBufferRelease(old);

        if (!strongSelf.hasFirstFrame) {
            strongSelf->_hasFirstFrame = YES;
            VCLog(@"[VCamManager] First valid frame -> notify firstframe");
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR(kVCNotifyFirstFrame),
                NULL, NULL, true
            );
        }
    };

    _isLive = YES;
    [self.rtmpClient startWithRTMPURL:url];
}

- (void)stop {
    _isLive = NO;
    _hasFirstFrame = NO;

    if (self.rtmpClient) {
        [self.rtmpClient stop];
        self.rtmpClient = nil;
    }

    CVPixelBufferRef old = self.currentPixelBuffer;
    self.currentPixelBuffer = NULL;
    if (old) CVPixelBufferRelease(old);

    VCLog(@"VCamManager: stopped");
}

#pragma mark - RTMPClientDelegate

- (void)rtmpClientDidConnect:(id)client {
    VCLog(@"VCamManager: RTMP connected");
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(kVCNotifyRTMPNetwork),
        NULL, NULL, true
    );
}

- (void)rtmpClientDidDisconnect:(id)client reason:(NSString *)reason {
    VCLog(@"VCamManager: RTMP disconnected: %@", reason);
    _hasFirstFrame = NO;
}

- (void)rtmpClient:(id)client didReceiveVideoFrame:(CVPixelBufferRef)pixelBuffer {
    // Handled via decoder.onFrame callback
}

- (void)rtmpClient:(id)client didFailWithError:(NSString *)error {
    VCLog(@"VCamManager: RTMP error: %@", error);
}

#pragma mark - Darwin Notifications

- (void)_registerNotifications {
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();

    // Config changed notification (from UI)
    CFNotificationCenterAddObserver(
        center, (__bridge const void *)self,
        configChangedCallback,
        CFSTR(kVCNotifyConfig),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // Revoked notification (from UI)
    CFNotificationCenterAddObserver(
        center, (__bridge const void *)self,
        revokedCallback,
        CFSTR(kVCNotifyRevoked),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}

static void configChangedCallback(CFNotificationCenterRef center,
                                    void *observer,
                                    CFNotificationName name,
                                    const void *object,
                                    CFDictionaryRef userInfo) {
    VCLog(@"VCamManager: config changed notification received");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[VCamManager sharedInstance] reloadConfig];
    });
}

static void revokedCallback(CFNotificationCenterRef center,
                              void *observer,
                              CFNotificationName name,
                              const void *object,
                              CFDictionaryRef userInfo) {
    VCLog(@"VCamManager: license revoked notification received");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[VCamManager sharedInstance] stop];
    });
}

@end
