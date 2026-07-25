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
@property (nonatomic, strong) NSLock *pixelBufferLock;
@property (nonatomic, assign) CVPixelBufferRef currentPixelBuffer;

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
        _pixelBufferLock = [[NSLock alloc] init];

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
        [self stop];
        return;
    }

    // License check
    NSDictionary *auth = [[VcamSharedAuth sharedInstance] readVerifiedAuth];
    if (!auth) {
        VCLog(@"license check FAILED reason=missing_auth, refusing to start");
        [self stop];
        return;
    }

    VCLog(@"license check OK, starting stream");

    self.rtmpURL = url;

    if (self.rtmpClient) {
        [self stop];
    }

    RTMPClient *client = [[RTMPClient alloc] init];
    self.rtmpClient = client;
    client.delegate = self;

    // Set up decoder callback
    __weak typeof(self) weakSelf = self;
    __weak RTMPClient *weakClient = client;
    client.decoder.onFrame = ^(CVPixelBufferRef pixelBuffer, CMTime pts) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.rtmpClient != weakClient) return;

        CVPixelBufferRetain(pixelBuffer);
        [strongSelf.pixelBufferLock lock];
        if (!strongSelf->_isLive) {
            [strongSelf.pixelBufferLock unlock];
            CVPixelBufferRelease(pixelBuffer);
            return;
        }
        CVPixelBufferRef old = strongSelf->_currentPixelBuffer;
        strongSelf->_currentPixelBuffer = pixelBuffer;
        BOOL isFirstFrame = !strongSelf->_hasFirstFrame;
        strongSelf->_hasFirstFrame = YES;
        [strongSelf.pixelBufferLock unlock];
        if (old) CVPixelBufferRelease(old);

        if (isFirstFrame) {
            VCLog(@"[VCamManager] First valid frame -> notify firstframe");
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR(kVCNotifyFirstFrame),
                NULL, NULL, true
            );
        }
    };

    [self.pixelBufferLock lock];
    _isLive = YES;
    [self.pixelBufferLock unlock];
    [client startWithRTMPURL:url];
}

- (void)stop {
    [self.pixelBufferLock lock];
    _isLive = NO;
    _hasFirstFrame = NO;
    CVPixelBufferRef old = _currentPixelBuffer;
    _currentPixelBuffer = NULL;
    [self.pixelBufferLock unlock];
    if (old) CVPixelBufferRelease(old);

    if (self.rtmpClient) {
        [self.rtmpClient stop];
        self.rtmpClient = nil;
    }

    VCLog(@"VCamManager: stopped");
}

- (CVPixelBufferRef)copyCurrentPixelBuffer {
    [self.pixelBufferLock lock];
    CVPixelBufferRef pixelBuffer = _isLive ? _currentPixelBuffer : NULL;
    if (pixelBuffer) CVPixelBufferRetain(pixelBuffer);
    [self.pixelBufferLock unlock];
    return pixelBuffer;
}

#pragma mark - RTMPClientDelegate

- (void)rtmpClientDidConnect:(id)client {
    if (client != self.rtmpClient) return;
    VCLog(@"VCamManager: RTMP connected");
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(kVCNotifyRTMPNetwork),
        NULL, NULL, true
    );
}

- (void)rtmpClientDidDisconnect:(id)client reason:(NSString *)reason {
    if (client != self.rtmpClient) return;
    VCLog(@"VCamManager: RTMP disconnected: %@", reason);
    [self.pixelBufferLock lock];
    _hasFirstFrame = NO;
    [self.pixelBufferLock unlock];
}

- (void)rtmpClient:(id)client didReceiveVideoFrame:(CVPixelBufferRef)pixelBuffer {
    // Handled via decoder.onFrame callback
}

- (void)rtmpClient:(id)client didFailWithError:(NSString *)error {
    if (client != self.rtmpClient) return;
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
