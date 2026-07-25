/**
 * VcamHelper.m — Main UI coordinator for VcamLumiere.
 *
 * Manages:
 * - Floating "LIVE" button with drag gesture
 * - Settings panel (RTMP URL, toggles, sliders)
 * - Login alert controller
 * - Plist config read/write
 * - Darwin notification handling
 * - VcamLiveVerifier integration
 * - VcamVolumeObserver integration
 */

#import "VcamHelper.h"
#import "VcamPassthroughWindow.h"
#import "VcamLoginHelper.h"
#import "VcamLiveVerifier.h"
#import "VcamVolumeObserver.h"
#import "../Shared/VcamSharedAuth.h"
#import "../Shared/VcamAntiHook.h"
#import "../Shared/VcamConstants.h"
#import <AudioToolbox/AudioToolbox.h>

@interface VcamHelper () <VcamLoginDelegate, VcamLiveVerifierDelegate, VcamVolumeObserverDelegate>

@property (nonatomic, strong) VcamPassthroughWindow *window;
@property (nonatomic, strong) UIButton *floatButton;
@property (nonatomic, strong) UIView *settingsPanel;
@property (nonatomic, assign) BOOL panelVisible;

@property (nonatomic, strong) UITextField *rtmpField;
@property (nonatomic, strong) UISwitch *liveSwitch;
@property (nonatomic, strong) UISwitch *flashSwitch;
@property (nonatomic, strong) UISlider *speedSlider;
@property (nonatomic, strong) UISlider *brightnessSlider;
@property (nonatomic, strong) UISlider *areaSlider;
@property (nonatomic, strong) UISlider *hueSlider;

@property (nonatomic, strong) VcamLoginHelper *loginHelper;
@property (nonatomic, strong) VcamLiveVerifier *liveVerifier;
@property (nonatomic, strong) VcamVolumeObserver *volumeObserver;
@property (nonatomic, strong) UIAlertController *loginProgressAlert;
@property (nonatomic, copy) NSString *pendingLoginUsername;

@end

@implementation VcamHelper

+ (instancetype)sharedInstance {
    static VcamHelper *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VcamHelper alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _loginHelper = [[VcamLoginHelper alloc] init];
        _loginHelper.delegate = self;

        _liveVerifier = [[VcamLiveVerifier alloc] init];
        _liveVerifier.delegate = self;

        _volumeObserver = [[VcamVolumeObserver alloc] init];
        _volumeObserver.delegate = self;

        _panelVisible = NO;

        [self _registerNotifications];
    }
    return self;
}

#pragma mark - Window Setup

- (void)showFloatingButton {
    if (self.window) {
        if (self.liveSwitch.isOn) {
            [self.liveVerifier startPeriodicVerification];
        }
        return;
    }

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    self.window = [[VcamPassthroughWindow alloc] initWithFrame:screenBounds];

    // Create floating button
    CGFloat btnSize = 50;
    self.floatButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatButton.frame = CGRectMake(screenBounds.size.width - btnSize - 16,
                                         screenBounds.size.height / 2 - btnSize / 2,
                                         btnSize, btnSize);
    self.floatButton.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.3 alpha:0.9];
    self.floatButton.layer.cornerRadius = btnSize / 2;
    self.floatButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.floatButton.layer.shadowOffset = CGSizeMake(0, 2);
    self.floatButton.layer.shadowOpacity = 0.5;
    self.floatButton.layer.shadowRadius = 4;
    self.floatButton.clipsToBounds = NO;

    [self.floatButton setTitle:@"LIVE" forState:UIControlStateNormal];
    [self.floatButton.titleLabel setFont:[UIFont boldSystemFontOfSize:12]];
    [self.floatButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    [self.floatButton addTarget:self action:@selector(_floatButtonTapped)
               forControlEvents:UIControlEventTouchUpInside];

    // Add drag gesture
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                    initWithTarget:self action:@selector(_handleDrag:)];
    [self.floatButton addGestureRecognizer:pan];

    [self.window addSubview:self.floatButton];

    // Create settings panel (hidden initially)
    [self _createSettingsPanel];

    self.window.hidden = NO;

    // Start volume observer
    [self.volumeObserver startObserving];
    if (self.liveSwitch.isOn) {
        [self.liveVerifier startPeriodicVerification];
    }

    // Start shake animation
    [self _addShakeAnimation];

    VCLog(@"Floating button shown");
}

- (void)hideFloatingButton {
    [self.volumeObserver stopObserving];
    [self.liveVerifier stopPeriodicVerification];

    self.window.hidden = YES;
    self.window = nil;
    self.floatButton = nil;
    self.settingsPanel = nil;
    self.panelVisible = NO;

    VCLog(@"Floating button hidden");
}

#pragma mark - Settings Panel

- (void)_createSettingsPanel {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat panelW = 280;
    CGFloat panelH = 440;
    CGFloat panelX = (screenBounds.size.width - panelW) / 2;
    CGFloat panelY = (screenBounds.size.height - panelH) / 2;

    self.settingsPanel = [[UIView alloc] initWithFrame:CGRectMake(panelX, panelY, panelW, panelH)];
    self.settingsPanel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.95];
    self.settingsPanel.layer.cornerRadius = 16;
    self.settingsPanel.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1].CGColor;
    self.settingsPanel.layer.borderWidth = 0.5;
    self.settingsPanel.hidden = YES;
    self.settingsPanel.clipsToBounds = YES;

    CGFloat y = 16;
    CGFloat margin = 16;
    CGFloat labelW = panelW - margin * 2;

    // Title
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, labelW, 24)];
    title.text = [NSString stringWithFormat:@"VcamLumiere %@", VCAM_VERSION];
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    title.textAlignment = NSTextAlignmentCenter;
    [self.settingsPanel addSubview:title];
    y += 32;

    // RTMP URL field
    UILabel *rtmpLabel = [self _createLabel:@"RTMP Link:" frame:CGRectMake(margin, y, labelW, 18)];
    [self.settingsPanel addSubview:rtmpLabel];
    y += 20;

    self.rtmpField = [[UITextField alloc] initWithFrame:CGRectMake(margin, y, labelW, 34)];
    self.rtmpField.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    self.rtmpField.textColor = [UIColor whiteColor];
    self.rtmpField.font = [UIFont systemFontOfSize:13];
    self.rtmpField.placeholder = @"rtmp://host/live";
    self.rtmpField.layer.cornerRadius = 6;
    self.rtmpField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 34)];
    self.rtmpField.leftViewMode = UITextFieldViewModeAlways;
    self.rtmpField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.rtmpField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.rtmpField.returnKeyType = UIReturnKeyDone;
    [self.rtmpField addTarget:self action:@selector(_rtmpFieldChanged)
             forControlEvents:UIControlEventEditingDidEnd];
    [self.settingsPanel addSubview:self.rtmpField];
    y += 42;

    // LIVE toggle
    y = [self _addToggleRow:@"LIVE" y:y target:@selector(_liveSwitchChanged:) switchRef:&_liveSwitch];

    // FLASH toggle
    y = [self _addToggleRow:@"FLASH" y:y target:@selector(_flashSwitchChanged:) switchRef:&_flashSwitch];

    // Sliders
    y = [self _addSliderRow:@"Speed"      y:y min:0.1 max:5.0 val:1.0 ref:&_speedSlider];
    y = [self _addSliderRow:@"Brightness" y:y min:0.0 max:1.0 val:0.5 ref:&_brightnessSlider];
    y = [self _addSliderRow:@"Area"       y:y min:0.1 max:1.0 val:0.5 ref:&_areaSlider];
    y = [self _addSliderRow:@"Hue"        y:y min:0.0 max:1.0 val:0.0 ref:&_hueSlider];

    for (UISlider *s in @[_speedSlider, _brightnessSlider, _areaSlider, _hueSlider]) {
        [s addTarget:self action:@selector(_sliderChanged:) forControlEvents:UIControlEventValueChanged];
    }

    // Buttons row
    y += 8;
    CGFloat btnW = (labelW - 8) / 2;

    UIButton *logoutBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    logoutBtn.frame = CGRectMake(margin, y, btnW, 36);
    [logoutBtn setTitle:@"Logout" forState:UIControlStateNormal];
    [logoutBtn setTitleColor:[UIColor colorWithRed:1 green:0.4 blue:0.4 alpha:1]
                    forState:UIControlStateNormal];
    logoutBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    logoutBtn.layer.cornerRadius = 8;
    [logoutBtn addTarget:self action:@selector(_logoutTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.settingsPanel addSubview:logoutBtn];

    UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    hideBtn.frame = CGRectMake(margin + btnW + 8, y, btnW, 36);
    [hideBtn setTitle:@"Hide" forState:UIControlStateNormal];
    [hideBtn setTitleColor:[UIColor colorWithRed:0.4 green:0.8 blue:1 alpha:1]
                  forState:UIControlStateNormal];
    hideBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    hideBtn.layer.cornerRadius = 8;
    [hideBtn addTarget:self action:@selector(_hideTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.settingsPanel addSubview:hideBtn];

    y += 44;

    // Footer
    UILabel *footer = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, labelW, 16)];
    footer.text = @"@lumierephan";
    footer.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    footer.font = [UIFont systemFontOfSize:11];
    footer.textAlignment = NSTextAlignmentCenter;
    [self.settingsPanel addSubview:footer];

    // Adjust panel height
    CGRect frame = self.settingsPanel.frame;
    frame.size.height = y + 24;
    frame.origin.y = (screenBounds.size.height - frame.size.height) / 2;
    self.settingsPanel.frame = frame;

    [self.window addSubview:self.settingsPanel];

    // Load saved config
    [self _loadConfig];
}

#pragma mark - UI Helpers

- (UILabel *)_createLabel:(NSString *)text frame:(CGRect)frame {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.text = text;
    label.textColor = [UIColor colorWithWhite:0.7 alpha:1];
    label.font = [UIFont systemFontOfSize:12];
    return label;
}

- (CGFloat)_addToggleRow:(NSString *)title y:(CGFloat)y
                  target:(SEL)action switchRef:(UISwitch *__strong *)outSwitch {
    CGFloat margin = 16;
    CGFloat w = self.settingsPanel.frame.size.width - margin * 2;

    UILabel *label = [self _createLabel:title frame:CGRectMake(margin, y + 4, w - 60, 20)];
    [self.settingsPanel addSubview:label];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(margin + w - 51, y, 51, 31)];
    sw.onTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1];
    sw.transform = CGAffineTransformMakeScale(0.75, 0.75);
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [self.settingsPanel addSubview:sw];
    *outSwitch = sw;

    return y + 36;
}

- (CGFloat)_addSliderRow:(NSString *)title y:(CGFloat)y
                     min:(float)min max:(float)max val:(float)val
                     ref:(UISlider *__strong *)outSlider {
    CGFloat margin = 16;
    CGFloat w = self.settingsPanel.frame.size.width - margin * 2;

    UILabel *label = [self _createLabel:title frame:CGRectMake(margin, y, w, 16)];
    [self.settingsPanel addSubview:label];
    y += 16;

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(margin, y, w, 24)];
    slider.minimumValue = min;
    slider.maximumValue = max;
    slider.value = val;
    slider.minimumTrackTintColor = [UIColor colorWithRed:0.2 green:0.6 blue:1 alpha:1];
    [self.settingsPanel addSubview:slider];
    *outSlider = slider;

    return y + 28;
}

#pragma mark - Button Actions

- (void)_floatButtonTapped {
    AudioServicesPlaySystemSound(1519);  // haptic
    [self togglePanel];
}

- (void)togglePanel {
    self.panelVisible = !self.panelVisible;
    self.settingsPanel.hidden = !self.panelVisible;

    if (self.panelVisible) {
        self.settingsPanel.alpha = 0;
        [UIView animateWithDuration:0.25 animations:^{
            self.settingsPanel.alpha = 1;
        }];
    }
}

- (void)_hideTapped {
    self.panelVisible = NO;
    self.settingsPanel.hidden = YES;
}

- (void)_logoutTapped {
    [self.loginHelper doLogout];
    [self.liveVerifier stopPeriodicVerification];
    self.panelVisible = NO;
    self.settingsPanel.hidden = YES;

    // Show login again after a short delay
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self showLoginAlert];
    });
}

#pragma mark - Config Changes

- (void)_rtmpFieldChanged {
    [self _saveConfig];
}

- (void)_liveSwitchChanged:(UISwitch *)sender {
    [self _saveConfig];

    if (sender.isOn) {
        [self.liveVerifier startPeriodicVerification];
    } else {
        [self.liveVerifier stopPeriodicVerification];
    }
}

- (void)_flashSwitchChanged:(UISwitch *)sender {
    [self _saveConfig];
}

- (void)_sliderChanged:(UISlider *)sender {
    [self _saveConfig];
}

#pragma mark - Config Load / Save

- (void)_loadConfig {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kVCPlistPath];
    if (!plist) return;

    self.rtmpField.text = plist[kVCKeyRtmpURL];
    self.liveSwitch.on = [plist[kVCKeyEnabled] boolValue];
    self.flashSwitch.on = [plist[kVCKeyFlashEnabled] boolValue];

    if (plist[kVCKeyFlashSpeed])  self.speedSlider.value = [plist[kVCKeyFlashSpeed] floatValue];
    if (plist[kVCKeyFlashBright]) self.brightnessSlider.value = [plist[kVCKeyFlashBright] floatValue];
    if (plist[kVCKeyFlashArea])   self.areaSlider.value = [plist[kVCKeyFlashArea] floatValue];
    if (plist[kVCKeyFlashHue])    self.hueSlider.value = [plist[kVCKeyFlashHue] floatValue];
}

- (void)_saveConfig {
    NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:kVCPlistPath];
    if (!plist) plist = [NSMutableDictionary dictionary];

    plist[kVCKeyRtmpURL]      = self.rtmpField.text ?: @"";
    plist[kVCKeyEnabled]      = @(self.liveSwitch.isOn);
    plist[kVCKeyFlashEnabled] = @(self.flashSwitch.isOn);
    plist[kVCKeyFlashSpeed]   = @(self.speedSlider.value);
    plist[kVCKeyFlashBright]  = @(self.brightnessSlider.value);
    plist[kVCKeyFlashArea]    = @(self.areaSlider.value);
    plist[kVCKeyFlashHue]     = @(self.hueSlider.value);

    [plist writeToFile:kVCPlistPath atomically:YES];

    // Notify daemon that config changed
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(kVCNotifyConfig),
        NULL, NULL, true
    );
}

#pragma mark - Login

- (void)showLoginAlert {
    // Check if already authenticated
    NSDictionary *auth = [[VcamSharedAuth sharedInstance] readVerifiedAuth];
    if (auth) {
        VCLog(@"Already authenticated, showing UI");
        [self showFloatingButton];
        return;
    }

    [self _showLoginAlertWithError:nil];
}

- (UIViewController *)_topViewController {
    UIWindow *keyWindow = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow && window.rootViewController) {
            keyWindow = window;
            break;
        }
    }
    if (!keyWindow) {
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (window.rootViewController) {
                keyWindow = window;
                break;
            }
        }
    }

    UIViewController *controller = keyWindow.rootViewController;
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    return controller;
}

- (void)_showLoginAlertWithError:(NSString *)error {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Login @lumierephan"
                         message:error
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Username";
        tf.text = self.pendingLoginUsername;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Password";
        tf.secureTextEntry = YES;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Confirm"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSString *username = alert.textFields[0].text;
        NSString *password = alert.textFields[1].text;
        self.pendingLoginUsername = username;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _showLoginProgressWithCompletion:^{
                [self.loginHelper doLoginWithUsername:username password:password];
            }];
        });
    }]];

    [[self _topViewController] presentViewController:alert animated:YES completion:nil];
}

- (void)_showLoginProgressWithCompletion:(void (^)(void))completion {
    UIAlertController *progress = [UIAlertController
        alertControllerWithTitle:@"Signing In"
                         message:@"\n\n"
                  preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [progress.view addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:progress.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:progress.view.bottomAnchor constant:-20.0]
    ]];
    [spinner startAnimating];
    self.loginProgressAlert = progress;
    [[self _topViewController] presentViewController:progress
                                           animated:YES
                                         completion:completion];
}

#pragma mark - VcamLoginDelegate

- (void)loginDidSucceed {
    VCLog(@"Login succeeded, showing floating button");
    void (^completion)(void) = ^{
        self.loginProgressAlert = nil;
        self.pendingLoginUsername = nil;
        [self showFloatingButton];
    };
    if (self.loginProgressAlert.presentingViewController) {
        [self.loginProgressAlert dismissViewControllerAnimated:YES completion:completion];
    } else {
        completion();
    }
}

- (void)loginDidFailWithError:(NSString *)error {
    VCLog(@"Login failed: %@", error);
    void (^completion)(void) = ^{
        self.loginProgressAlert = nil;
        [self _showLoginAlertWithError:error];
    };
    if (self.loginProgressAlert.presentingViewController) {
        [self.loginProgressAlert dismissViewControllerAnimated:YES completion:completion];
    } else {
        completion();
    }
}

#pragma mark - VcamLiveVerifierDelegate

- (void)verifierDidConfirmValid {
    // License still valid — nothing to do
}

- (void)verifierDidDetectRevocation:(NSString *)reason {
    VCLog(@"License revoked: %@", reason);

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"License Revoked"
                         message:[NSString stringWithFormat:@"Reason: %@", reason]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self hideFloatingButton];
        [self showLoginAlert];
    }]];

    [[self _topViewController] presentViewController:alert animated:YES completion:nil];
}

#pragma mark - VcamVolumeObserverDelegate

- (void)volumeToggleTriggered {
    VCLog(@"Volume toggle triggered");

    if (self.window.hidden) {
        self.window.hidden = NO;
    } else {
        self.panelVisible = NO;
        self.settingsPanel.hidden = YES;
        self.window.hidden = YES;
    }
}

#pragma mark - Animations

- (void)_addShakeAnimation {
    CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
    anim.values = @[@(-0.04), @(0.04), @(-0.04)];
    anim.duration = 0.3;
    anim.repeatCount = HUGE_VALF;
    anim.autoreverses = YES;
    [self.floatButton.layer addAnimation:anim forKey:@"shake"];
}

#pragma mark - Drag Gesture

- (void)_handleDrag:(UIPanGestureRecognizer *)gesture {
    UIView *button = gesture.view;
    CGPoint translation = [gesture translationInView:self.window];

    button.center = CGPointMake(button.center.x + translation.x,
                                 button.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:self.window];

    if (gesture.state == UIGestureRecognizerStateEnded) {
        // Snap to edge
        CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
        CGFloat btnW = button.frame.size.width;
        CGFloat targetX;

        if (button.center.x < screenW / 2) {
            targetX = btnW / 2 + 8;
        } else {
            targetX = screenW - btnW / 2 - 8;
        }

        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.6
              initialSpringVelocity:0.5
                            options:0
                         animations:^{
            button.center = CGPointMake(targetX, button.center.y);
        } completion:nil];
    }
}

#pragma mark - Darwin Notifications

- (void)_registerNotifications {
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();

    CFNotificationCenterAddObserver(
        center, (__bridge const void *)self,
        firstFrameCallback,
        CFSTR(kVCNotifyFirstFrame),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    CFNotificationCenterAddObserver(
        center, (__bridge const void *)self,
        revokedCallback,
        CFSTR(kVCNotifyRevoked),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}

static void firstFrameCallback(CFNotificationCenterRef center,
                                 void *observer, CFNotificationName name,
                                 const void *object, CFDictionaryRef userInfo) {
    VCLog(@"First frame received from daemon");
    dispatch_async(dispatch_get_main_queue(), ^{
        VcamHelper *helper = (__bridge VcamHelper *)observer;
        // Update button color to green = streaming
        helper.floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.3 alpha:0.9];
    });
}

static void revokedCallback(CFNotificationCenterRef center,
                              void *observer, CFNotificationName name,
                              const void *object, CFDictionaryRef userInfo) {
    VCLog(@"Revocation notification received in UI");
    dispatch_async(dispatch_get_main_queue(), ^{
        VcamHelper *helper = (__bridge VcamHelper *)observer;
        [helper.liveVerifier stopPeriodicVerification];
        helper.floatButton.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.3 alpha:0.9];
    });
}

@end
