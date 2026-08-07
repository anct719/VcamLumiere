// vcamui — New black floating ball + modern control panel (Patch module, v1.3)
// Independent UI patch for vcamplus. Does NOT modify any original source file.
// All actions call the ORIGINAL interfaces (config files + Darwin notifications
// + runtime ObjC classes MJRcv / UIHlp / FWCtrl). Fully removable.
// v1.1: + 视频投放 眼/嘴/头 (原数字键1-3 → enabled field[1] videoIndex)
//       + 颜色注入 彩/强度+/- (enabled field[7] colorInject, field[11] alpha)
// v1.2 (audit fixes):
//       + H1 补回 选择图片 / 开启-关闭虚拟相机 / 停止直播流 原菜单功能
//       + H2 面板改 UIScrollView + 高度自适应(小屏不再裁切)
//       + M1 vcuTopVC 改 scene 扫描, 排除自身悬浮窗
//       + M2 关闭时发 ctrl 通知触发原进程释放 reader
//       + M3 直播拉流用读改写, 不再用 "1" 覆盖控制字段
//       + M4 卸载后需重启进程才能还原原菜单(hook 内存残留)
// v1.3 (Final Audit VCU-1 fix):
//       + 颜色注入"彩"开关改驱动原 FWCtrl.toggleColorInject, 启动 1/30s 屏幕采样,
//         使 RGB 随屏幕颜色实时写入 enabled 文件(此前仅翻转 field[7] 会导致纯黑覆盖)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - Paths & constants (mirror of original project)

#define VCU_DIR        @"/var/jb/var/mobile/Library/vcamplus"
#define VCU_FLAG       VCU_DIR @"/enabled"
#define VCU_STREAM     VCU_DIR @"/stream.conf"
#define VCU_STREAM_FRAME VCU_DIR @"/stream.jpg"
#define VCU_AUDIO      VCU_DIR @"/audio.conf"
#define VCU_NOTIFY_AUD @"com.vcamplus.audio.changed"
#define VCU_NOTIFY_CTL @"com.vcamplus.ctrl"

static IMP gVCUOrigPresent = NULL;

#pragma mark - Controller interface (declared early so static helpers can use it)

@interface VCUICtrl : NSObject
+ (instancetype)shared;
- (void)showBall;
- (BOOL)streamActive;
- (void)setStreamActive:(BOOL)on;
- (void)updateStreamBtn;
- (void)updateCamBtn;
- (void)updateColorBtn;
@end

#pragma mark - Passthrough window

@interface VCUWindow : UIWindow
@end
@implementation VCUWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

#pragma mark - Helpers (top VC, config IO)

// Top VC via scene scan (keyWindow is deprecated on iOS 13+). Excludes our own
// overlay window so we never present from the ball window.
static UIViewController *vcuTopVC(void) {
    UIViewController *top = nil;
    @try {
        UIWindow *w = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in ((UIWindowScene *)s).windows) {
                if ([win isKindOfClass:[VCUWindow class]]) continue;
                if (win.isKeyWindow) { w = win; break; }
            }
            if (w) break;
        }
        if (!w) {
            for (UIWindow *win in [UIApplication sharedApplication].windows) {
                if (![win isKindOfClass:[VCUWindow class]]) { w = win; break; }
            }
        }
        top = w.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
    } @catch (NSException *e) {}
    return top;
}

static NSMutableArray *vcuAudioParts(void) {
    NSString *c = [NSString stringWithContentsOfFile:VCU_AUDIO encoding:NSUTF8StringEncoding error:nil];
    NSArray *arr = (c.length >= 3) ? [c componentsSeparatedByString:@","] : @[@"0", @"", @"1.0", @"1", @"0"];
    return [NSMutableArray arrayWithArray:arr];
}

static void vcuWriteAudio(NSArray *parts) {
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:VCU_DIR withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *line = [parts componentsJoinedByString:@","];
        [line writeToFile:VCU_AUDIO atomically:YES encoding:NSUTF8StringEncoding error:nil];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)VCU_NOTIFY_AUD, NULL, NULL, YES);
    } @catch (NSException *e) {}
}

// Read enabled file as 16 fields (same format as vcam_applyControls).
static NSMutableArray *vcuFlagParts(void) {
    NSString *c = [NSString stringWithContentsOfFile:VCU_FLAG encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *p = (c.length >= 3) ? [[c componentsSeparatedByString:@","] mutableCopy] : [@[@"1"] mutableCopy];
    while (p.count < 16) [p addObject:@"0"];
    return p;
}

static void vcuWriteFlagParts(NSArray *p) {
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:VCU_DIR withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *line = [p componentsJoinedByString:@","];
        [line writeToFile:VCU_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)VCU_NOTIFY_CTL, NULL, NULL, YES);
    } @catch (NSException *e) {}
}

// Set rotation directly to an absolute angle (0/90/180/270). The original FWCtrl
// only rotates +90 per tap (tag 101) and its global cannot be set absolutely from
// here, so we write the exact angle straight to the file (the render process reads
// it via applyControls). Rotation stays correct whenever color sampling is OFF;
// while sampling is ON the sampler's vcam_writeControls() may rewrite field[2]
// from SpringBoard's global — an original-architecture limitation shared with the
// stock FWCtrl panel, not introduced by this patch.
static void vcuSetRotation(int deg) {
    @try {
        NSMutableArray *p = vcuFlagParts();
        p[0] = @"1";
        p[2] = [NSString stringWithFormat:@"%d", deg];
        vcuWriteFlagParts(p);
    } @catch (NSException *e) {}
}

// Video slot switch (原数字键 1-3 → 眼/嘴/头). Field [1] = videoIndex.
// Read-modify-write of the enabled file: sets ONLY field[1], preserving rotation,
// color, and stream fields set elsewhere. (Driving FWCtrl.btnTap: would rewrite the
// whole file from SpringBoard's globals and clobber fields this patch sets directly.)
static void vcuSwitchVideo(int index) {
    @try {
        NSMutableArray *p = vcuFlagParts();
        p[0] = @"1";
        p[1] = [NSString stringWithFormat:@"%d", index];
        vcuWriteFlagParts(p);
    } @catch (NSException *e) {}
}

// Color injection toggle (原"彩"键). Field [7] = colorInject on/off.
// RGB sampling fix (VCU-1): sampled-color injection needs the ORIGINAL FWCtrl's
// toggleColorInject — it sets this process's gColorInject global, starts/stops the
// 1/30s screen sampler, and rewrites the enabled file with [7]=1 + live RGB. Calling
// only startColorSampling is NOT enough: the sampler's vcam_writeControls() would
// write field[7] back from SpringBoard's stale gColorInject (NO), cancelling our flag.
// toggleColorInject flips the GLOBAL, so after calling it we force field[7] to our
// intended value — this also covers the process-restart case where the global (NO)
// and the file may disagree. nil-safe; never calls doShow, so no second ball.
static void vcuColorToggle(void) {
    @try {
        Class fw = objc_getClass("FWCtrl");
        id inst = fw ? [fw performSelector:@selector(shared)] : nil;
        NSMutableArray *p = vcuFlagParts();
        BOOL wantOn = [p[7] intValue] == 0;
        if (inst && [inst respondsToSelector:@selector(toggleColorInject)]) {
            [inst performSelector:@selector(toggleColorInject)];
        }
        // Force the flag to the intended state (and keep it consistent even if the
        // global flip disagreed with the file after a process restart).
        NSMutableArray *p2 = vcuFlagParts();
        p2[0] = @"1";
        p2[7] = wantOn ? @"1" : @"0";
        vcuWriteFlagParts(p2);
    } @catch (NSException *e) {}
}

// Color injection intensity (原 +/- 键). Field [11] = alpha, clamp 0.05 ~ 1.0.
// Read-modify-write: sets ONLY field[11], preserving all other fields.
static void vcuColorIntensity(double delta) {
    @try {
        NSMutableArray *p = vcuFlagParts();
        double a = [p[11] doubleValue];
        a += delta;
        a = MAX(0.05, MIN(1.0, a));
        p[0] = @"1";
        p[11] = [NSString stringWithFormat:@"%.2f", a];
        vcuWriteFlagParts(p);
    } @catch (NSException *e) {}
}

// Close virtual camera: remove flag + stop stream + delete frame. The render loop
// in the original process (src:1680, case 25) detects the missing flag and stops
// replacing frames; stale AVAssetReader handles are dropped on the next
// vcam_switchVideo / UIHlp save (src:1517, 5282). We post the ctrl notification so
// the original vcam_applyControls runs and releases its readers on its own thread.
static void vcuCloseCamera(void) {
    @try {
        [[NSFileManager defaultManager] removeItemAtPath:VCU_FLAG error:nil];
        Class cls = objc_getClass("MJRcv");
        id rcv = cls ? [cls performSelector:@selector(shared)] : nil;
        if (rcv) [rcv performSelector:@selector(stop)];
        [[NSFileManager defaultManager] removeItemAtPath:VCU_STREAM_FRAME error:nil];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)VCU_NOTIFY_CTL, NULL, NULL, YES);
    } @catch (NSException *e) {}
}

// Toggle virtual camera on/off (matches original 开启/关闭虚拟相机 actions,
// src:5590-5602). Reads current flag presence.
static void vcuToggleCamera(void) {
    @try {
        BOOL en = [[NSFileManager defaultManager] fileExistsAtPath:VCU_FLAG];
        if (en) {
            vcuCloseCamera();
        } else {
            [@"1" writeToFile:VCU_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                (__bridge CFStringRef)VCU_NOTIFY_CTL, NULL, NULL, YES);
        }
    } @catch (NSException *e) {}
}

static void vcuPresentImagePicker(void) {
    UIViewController *vc = vcuTopVC();
    if (!vc) return;
    @try {
        Class uiHlp = NSClassFromString(@"UIHlp");
        id delegate = uiHlp ? [uiHlp performSelector:@selector(shared)] : nil;
        Class pickCls = NSClassFromString(@"UIImagePickerController");
        if (pickCls) {
            id p = [[pickCls alloc] init];
            [p setSourceType:UIImagePickerControllerSourceTypePhotoLibrary];
            [p setMediaTypes:@[@"public.image"]];
            if (delegate) [p setDelegate:delegate];
            [vc presentViewController:p animated:YES completion:nil];
        }
    } @catch (NSException *e) {}
}

static void vcuPresentPicker(void) {
    UIViewController *vc = vcuTopVC();
    if (!vc) return;
    @try {
        Class cfgCls = NSClassFromString(@"PHPickerConfiguration");
        Class pickCls = NSClassFromString(@"PHPickerViewController");
        Class fltCls = NSClassFromString(@"PHPickerFilter");
        Class uiHlp = NSClassFromString(@"UIHlp");
        id delegate = uiHlp ? [uiHlp performSelector:@selector(shared)] : nil;
        if (cfgCls && pickCls && fltCls) {
            id cfg = [[cfgCls alloc] init];
            [cfg setValue:[fltCls performSelector:@selector(videosFilter)] forKey:@"filter"];
            [cfg setValue:@1 forKey:@"selectionLimit"];
            [cfg setValue:@1 forKey:@"preferredAssetRepresentationMode"];
            id p = [[pickCls alloc] initWithConfiguration:cfg];
            if (delegate) [p setDelegate:delegate];
            [vc presentViewController:p animated:YES completion:nil];
        }
    } @catch (NSException *e) {}
}

// Toggle live stream on/off. On connect: write stream.conf, ensure enabled with
// PRESERVED control fields (M3 fix — never overwrite rotation/color settings),
// then [[MJRcv shared] startWithURL:]. On stop: [[MJRcv shared] stop].
static void vcuStreamInput(void) {
    @try {
        Class cls = objc_getClass("MJRcv");
        id rcv = cls ? [cls performSelector:@selector(shared)] : nil;
        if ([[VCUICtrl shared] streamActive]) {
            if (rcv) [rcv performSelector:@selector(stop)];
            [[VCUICtrl shared] setStreamActive:NO];
            [[VCUICtrl shared] updateStreamBtn];
            return;
        }
        UIViewController *vc = vcuTopVC();
        if (!vc) return;
        NSString *lastURL = [NSString stringWithContentsOfFile:VCU_STREAM encoding:NSUTF8StringEncoding error:nil];
        if (!lastURL || lastURL.length == 0) lastURL = @"http://192.168.1.100:8080";
        UIAlertController *input = [UIAlertController alertControllerWithTitle:@"MJPEG 直播流"
            message:@"输入 MJPEG 流地址\n例: http://电脑IP:端口"
            preferredStyle:UIAlertControllerStyleAlert];
        [input addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = lastURL;
            tf.placeholder = @"http://192.168.1.100:8080";
            tf.keyboardType = UIKeyboardTypeURL;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [input addAction:[UIAlertAction actionWithTitle:@"连接" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSString *url = input.textFields.firstObject.text;
            if (!url || url.length == 0) return;
            [url writeToFile:VCU_STREAM atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSMutableArray *p = vcuFlagParts();
            p[0] = @"1";
            vcuWriteFlagParts(p);
            Class c2 = objc_getClass("MJRcv");
            id r2 = c2 ? [c2 performSelector:@selector(shared)] : nil;
            if (r2) [r2 performSelector:@selector(startWithURL:) withObject:url];
            [[VCUICtrl shared] setStreamActive:YES];
            [[VCUICtrl shared] updateStreamBtn];
        }]];
        [input addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:input animated:YES completion:nil];
    } @catch (NSException *e) {}
}

#pragma mark - Controller

@implementation VCUICtrl {
    VCUWindow *_window;
    UIButton *_ball;
    UIScrollView *_panel;
    UIView *_contentView;
    BOOL _panelOpen;
    BOOL _dragged;
    BOOL _streamActive;
    NSTimer *_volTimer;
    UISwitch *_audioSwitch;
    UISlider *_volSlider;
    UILabel *_volLabel;
    UIButton *_colorBtn;
    UIButton *_streamBtn;
    UIButton *_camBtn;
}

+ (instancetype)shared {
    static VCUICtrl *inst; static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VCUICtrl alloc] init]; });
    return inst;
}

#pragma mark Ball

- (void)showBall {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (_window) { _window.hidden = NO; return; }
            UIWindowScene *scene = nil;
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
            }
            _window = scene ? [[VCUWindow alloc] initWithWindowScene:scene]
                            : [[VCUWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            _window.windowLevel = UIWindowLevelAlert + 100;
            _window.backgroundColor = [UIColor clearColor];
            UIViewController *vc = [[UIViewController alloc] init];
            vc.view.backgroundColor = [UIColor clearColor];
            _window.rootViewController = vc;
            _window.frame = [UIScreen mainScreen].bounds;

            CGFloat bw = 48, bx = [UIScreen mainScreen].bounds.size.width - bw - 12;
            CGFloat by = [UIScreen mainScreen].bounds.size.height * 0.6;
            _ball = [UIButton buttonWithType:UIButtonTypeCustom];
            _ball.frame = CGRectMake(bx, by, bw, bw);
            _ball.layer.cornerRadius = bw / 2;
            _ball.clipsToBounds = YES;
            _ball.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
            _ball.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
            _ball.layer.borderWidth = 1.5;
            [_ball setTitle:@"VC" forState:UIControlStateNormal];
            [_ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            _ball.titleLabel.font = [UIFont boldSystemFontOfSize:15];
            [_ball addTarget:self action:@selector(ballTapped) forControlEvents:UIControlEventTouchUpInside];
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(ballPanned:)];
            pan.maximumNumberOfTouches = 1;
            [_ball addGestureRecognizer:pan];
            [_window.rootViewController.view addSubview:_ball];
            if (!_panel) [self buildPanel];
            _window.hidden = NO;
        } @catch (NSException *e) {}
    });
}

- (BOOL)streamActive { return _streamActive; }
- (void)setStreamActive:(BOOL)on { _streamActive = on; }

- (void)updateStreamBtn {
    if (!_streamBtn) return;
    if (_streamActive) {
        [_streamBtn setTitle:@"停止直播流" forState:UIControlStateNormal];
        _streamBtn.backgroundColor = [UIColor colorWithRed:0.45 green:0.18 blue:0.15 alpha:1.0];
    } else {
        [_streamBtn setTitle:@"直播拉流" forState:UIControlStateNormal];
        _streamBtn.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    }
}

- (void)updateCamBtn {
    if (!_camBtn) return;
    BOOL en = [[NSFileManager defaultManager] fileExistsAtPath:VCU_FLAG];
    if (en) {
        [_camBtn setTitle:@"关闭虚拟相机" forState:UIControlStateNormal];
        _camBtn.backgroundColor = [UIColor colorWithRed:0.55 green:0.15 blue:0.15 alpha:1.0];
    } else {
        [_camBtn setTitle:@"开启虚拟相机" forState:UIControlStateNormal];
        _camBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.45 blue:0.25 alpha:1.0];
    }
}

- (void)updateColorBtn {
    if (!_colorBtn) return;
    NSMutableArray *p = vcuFlagParts();
    BOOL on = [p[7] intValue] != 0;
    if (on) {
        [_colorBtn setTitleColor:[UIColor systemGreenColor] forState:UIControlStateNormal];
        _colorBtn.layer.borderColor = [UIColor systemGreenColor].CGColor;
        _colorBtn.layer.borderWidth = 2;
    } else {
        [_colorBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _colorBtn.layer.borderColor = nil;
        _colorBtn.layer.borderWidth = 0;
    }
}

- (void)ballPanned:(UIPanGestureRecognizer *)g {
    UIView *sv = g.view;
    CGPoint t = [g translationInView:sv.superview];
    if (fabs(t.x) > 4 || fabs(t.y) > 4) _dragged = YES;
    CGPoint c = sv.center;
    c.x += t.x; c.y += t.y;
    sv.center = c;
    [g setTranslation:CGPointZero inView:sv.superview];
    if (_panelOpen) [self layoutPanel];
    if (g.state == UIGestureRecognizerStateEnded) {
        [self snapBall];
        dispatch_async(dispatch_get_main_queue(), ^{ _dragged = NO; });
    }
}

- (void)snapBall {
    @try {
        CGRect scr = [UIScreen mainScreen].bounds;
        CGPoint c = _ball.center;
        CGFloat half = _ball.frame.size.width / 2;
        c.x = (c.x < scr.size.width / 2) ? half + 4 : scr.size.width - half - 4;
        c.y = MAX(half + 4, MIN(c.y, scr.size.height - half - 4));
        [UIView animateWithDuration:0.22 animations:^{ _ball.center = c; }];
        if (_panelOpen) [self layoutPanel];
    } @catch (NSException *e) {}
}

- (void)ballTapped {
    if (_dragged) return;
    _panelOpen = !_panelOpen;
    [self layoutPanel];
}

#pragma mark Panel

- (void)layoutPanel {
    @try {
        CGRect scr = [UIScreen mainScreen].bounds;
        if (!_panel) return;
        CGFloat pw = 300;
        CGFloat ph = MIN(580.0, scr.size.height - 20.0);
        if (ph < 300) ph = 300;
        _panel.frame = CGRectMake(0, 0, pw, ph);
        _panel.contentSize = CGSizeMake(pw, 620);
        CGFloat anchorX = _ball.frame.origin.x;
        CGFloat px = (anchorX + _ball.frame.size.width + 8 + pw > scr.size.width)
                     ? anchorX - pw - 8 : anchorX + _ball.frame.size.width + 8;
        px = MAX(6, MIN(px, scr.size.width - pw - 6));
        CGFloat py = _ball.frame.origin.y + _ball.frame.size.height - ph;
        py = MAX(6, MIN(py, scr.size.height - ph - 6));
        if (_panelOpen) {
            _panel.frame = CGRectMake(px, py, pw, ph);
            _panel.hidden = NO;
            [_panel.superview bringSubviewToFront:_panel];
        } else {
            _panel.hidden = YES;
        }
    } @catch (NSException *e) {}
}

- (void)buildPanel {
    CGFloat w = 300, contentH = 620;
    _panel = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, w, MIN(580.0, [UIScreen mainScreen].bounds.size.height - 20.0))];
    _panel.contentSize = CGSizeMake(w, contentH);
    _panel.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.96];
    _panel.layer.cornerRadius = 18;
    _panel.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.12] CGColor];
    _panel.layer.borderWidth = 1;
    _panel.clipsToBounds = YES;
    _panel.showsVerticalScrollIndicator = NO;
    _contentView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, contentH)];
    _contentView.backgroundColor = [UIColor clearColor];
    [_panel addSubview:_contentView];
    [_window.rootViewController.view addSubview:_panel];
    _panel.hidden = YES;

    // Header
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 18, 200, 22)];
    title.text = @"VCam 控制面板";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    [_contentView addSubview:title];

    UIButton *closeX = [UIButton buttonWithType:UIButtonTypeCustom];
    closeX.frame = CGRectMake(w - 44, 14, 34, 30);
    [closeX setTitle:@"✕" forState:UIControlStateNormal];
    [closeX setTitleColor:[UIColor colorWithWhite:0.7 alpha:1] forState:UIControlStateNormal];
    [closeX addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [_contentView addSubview:closeX];

    CGFloat y = 54;
    y = [self addSection:@"视频输入" y:y];
    y = [self addRowButtons:@[@[@"选择视频", @"pickVideo"], @[@"选择图片", @"pickImage"], @[@"直播拉流", @"streamTapped"]] y:y streamRow:YES];
    y += 12;

    y = [self addSection:@"声音控制" y:y];
    // 声音开关
    UILabel *swLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, y + 6, 90, 20)];
    swLbl.text = @"声音开关";
    swLbl.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    swLbl.font = [UIFont systemFontOfSize:14];
    [_contentView addSubview:swLbl];
    _audioSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 72, y + 2, 60, 30)];
    NSArray *ap = vcuAudioParts();
    _audioSwitch.on = ([ap count] > 0 && [[ap objectAtIndex:0] intValue] != 0);
    [_audioSwitch addTarget:self action:@selector(audioToggled) forControlEvents:UIControlEventValueChanged];
    [_contentView addSubview:_audioSwitch];
    y += 40;
    // 音量
    UILabel *volLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, y + 6, 50, 20)];
    volLbl.text = @"音量";
    volLbl.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    volLbl.font = [UIFont systemFontOfSize:14];
    [_contentView addSubview:volLbl];
    _volSlider = [[UISlider alloc] initWithFrame:CGRectMake(74, y, 150, 30)];
    _volSlider.minimumValue = 0;
    _volSlider.maximumValue = 2.0f;
    _volSlider.value = ([ap count] > 2) ? [[ap objectAtIndex:2] floatValue] : 1.0f;
    [_volSlider addTarget:self action:@selector(volChanged) forControlEvents:UIControlEventValueChanged];
    [_volSlider addTarget:self action:@selector(volCommit) forControlEvents:UIControlEventTouchUpInside];
    [_volSlider addTarget:self action:@selector(volCommit) forControlEvents:UIControlEventTouchUpOutside];
    [_contentView addSubview:_volSlider];
    _volLabel = [[UILabel alloc] initWithFrame:CGRectMake(228, y + 4, 56, 20)];
    _volLabel.textColor = [UIColor whiteColor];
    _volLabel.font = [UIFont systemFontOfSize:12];
    _volLabel.textAlignment = NSTextAlignmentRight;
    _volLabel.text = [NSString stringWithFormat:@"%.0f%%", _volSlider.value * 100];
    [_contentView addSubview:_volLabel];
    y += 40;

    y = [self addSection:@"视频投放" y:y];
    y = [self addSlotRow:y];
    y += 12;

    y = [self addSection:@"颜色注入" y:y];
    y = [self addColorRow:y];
    y += 12;

    y = [self addSection:@"虚拟相机" y:y];
    y = [self addCamToggle:y];
    y += 12;

    y = [self addSection:@"视频控制" y:y];
    y = [self addRotateRow:y];

    [self updateStreamBtn];
    [self updateCamBtn];
    [self updateColorBtn];
    [self layoutPanel];
}

- (CGFloat)addSection:(NSString *)name y:(CGFloat)y {
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 200, 18)];
    lb.text = name;
    lb.textColor = [UIColor colorWithRed:0.35 green:0.78 blue:1.0 alpha:1.0];
    lb.font = [UIFont boldSystemFontOfSize:12];
    [_contentView addSubview:lb];
    return y + 24;
}

- (CGFloat)addRowButtons:(NSArray *)items y:(CGFloat)y streamRow:(BOOL)streamRow {
    CGFloat gap = 10;
    CGFloat bw = (300 - 20 - 20 - gap * (items.count - 1)) / items.count;
    for (int i = 0; i < items.count; i++) {
        NSArray *item = items[i];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(20 + i * (bw + gap), y, bw, 40);
        b.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
        b.layer.cornerRadius = 10;
        [b setTitle:item[0] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14];
        [b addTarget:self action:NSSelectorFromString(item[1]) forControlEvents:UIControlEventTouchUpInside];
        [_contentView addSubview:b];
        if (streamRow && [item[1] isEqualToString:@"streamTapped"]) _streamBtn = b;
    }
    return y + 50;
}

// 虚拟相机: 开启/关闭 toggle (H1 fix — 原"开启虚拟相机/关闭虚拟相机"双动作)
- (CGFloat)addCamToggle:(CGFloat)y {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(20, y, 260, 40);
    b.layer.cornerRadius = 10;
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14];
    [b addTarget:self action:@selector(camToggleTapped) forControlEvents:UIControlEventTouchUpInside];
    [_contentView addSubview:b];
    _camBtn = b;
    return y + 50;
}

- (CGFloat)addRotateRow:(CGFloat)y {
    NSArray *degs = @[@0, @90, @180, @270];
    CGFloat bw = 56, gap = 10;
    for (int i = 0; i < 4; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(20 + i * (bw + gap), y, bw, 38);
        b.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
        b.layer.cornerRadius = 9;
        b.tag = [degs[i] intValue];
        [b setTitle:[NSString stringWithFormat:@"%@°", degs[i]] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14];
        [b addTarget:self action:@selector(rotateTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_contentView addSubview:b];
    }
    return y + 48;
}

// 视频投放: 眼(1) / 嘴(2) / 头(3) — 对应原数字键 1-3, 投放到 VCAM_DIR/1.mp4 ~ 3.mp4
- (CGFloat)addSlotRow:(CGFloat)y {
    NSArray *slots = @[@[@"眼", @1], @[@"嘴", @2], @[@"头", @3]];
    CGFloat bw = 56, gap = 10;
    for (int i = 0; i < 3; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(20 + i * (bw + gap), y, bw, 38);
        b.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
        b.layer.cornerRadius = 9;
        b.tag = [slots[i][1] intValue];
        [b setTitle:slots[i][0] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [b addTarget:self action:@selector(slotTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_contentView addSubview:b];
    }
    return y + 48;
}

// 颜色注入: 彩(开关) / 强度+ / 强度-
- (CGFloat)addColorRow:(CGFloat)y {
    UIButton *toggle = [UIButton buttonWithType:UIButtonTypeCustom];
    toggle.frame = CGRectMake(20, y, 60, 38);
    toggle.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    toggle.layer.cornerRadius = 9;
    toggle.tag = 0;
    [toggle setTitle:@"彩" forState:UIControlStateNormal];
    [toggle setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    toggle.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [toggle addTarget:self action:@selector(colorToggleTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_contentView addSubview:toggle];
    _colorBtn = toggle;

    UIButton *plus = [UIButton buttonWithType:UIButtonTypeCustom];
    plus.frame = CGRectMake(90, y, 60, 38);
    plus.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    plus.layer.cornerRadius = 9;
    plus.tag = 1;
    [plus setTitle:@"强度+" forState:UIControlStateNormal];
    [plus setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    plus.titleLabel.font = [UIFont systemFontOfSize:13];
    [plus addTarget:self action:@selector(colorIntensityTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_contentView addSubview:plus];

    UIButton *minus = [UIButton buttonWithType:UIButtonTypeCustom];
    minus.frame = CGRectMake(160, y, 60, 38);
    minus.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    minus.layer.cornerRadius = 9;
    minus.tag = -1;
    [minus setTitle:@"强度-" forState:UIControlStateNormal];
    [minus setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    minus.titleLabel.font = [UIFont systemFontOfSize:13];
    [minus addTarget:self action:@selector(colorIntensityTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_contentView addSubview:minus];

    return y + 48;
}

#pragma mark Actions (all call ORIGINAL interfaces)

- (void)closeTapped {
    _panelOpen = NO;
    [self layoutPanel];
}

- (void)pickVideo { vcuPresentPicker(); }
- (void)pickImage { vcuPresentImagePicker(); }
- (void)streamTapped { vcuStreamInput(); }
- (void)camToggleTapped { vcuToggleCamera(); [self updateCamBtn]; }

- (void)audioToggled {
    @try {
        NSMutableArray *p = vcuAudioParts();
        if (p.count < 5) p = [@[@"0", @"", @"1.0", @"1", @"0"] mutableCopy];
        p[0] = _audioSwitch.on ? @"1" : @"0";
        vcuWriteAudio(p);
    } @catch (NSException *e) {}
}

- (void)volChanged {
    _volLabel.text = [NSString stringWithFormat:@"%.0f%%", _volSlider.value * 100];
    [_volTimer invalidate];
    _volTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(volCommit) userInfo:nil repeats:NO];
}

- (void)volCommit {
    @try {
        NSMutableArray *p = vcuAudioParts();
        if (p.count < 5) p = [@[@"0", @"", @"1.0", @"1", @"0"] mutableCopy];
        p[2] = [NSString stringWithFormat:@"%.2f", _volSlider.value];
        vcuWriteAudio(p);
    } @catch (NSException *e) {}
}

- (void)rotateTapped:(UIButton *)sender {
    vcuSetRotation((int)sender.tag);
}

- (void)slotTapped:(UIButton *)sender {
    vcuSwitchVideo((int)sender.tag);
}

- (void)colorToggleTapped:(UIButton *)sender {
    vcuColorToggle();
    [self updateColorBtn];
}

- (void)colorIntensityTapped:(UIButton *)sender {
    vcuColorIntensity((sender.tag > 0) ? 0.05 : -0.05);
}

@end

#pragma mark - Main menu interception (exact, structural — NOT containsString)

// Main menu = the "Virtual Camera v7.0" alert that only appears AFTER auth check
// passes in vcam_showMenu. Identify by structure (no text fields + known actions),
// so the ACTIVATION dialog ("Virtual Camera 授权", has a text field) is NEVER touched.
static BOOL vcuIsMainMenu(UIAlertController *ac) {
    if (ac.textFields.count > 0) return NO;
    for (UIAlertAction *a in ac.actions) {
        NSString *t = a.title;
        if ([t isEqualToString:@"选择视频"] || [t isEqualToString:@"悬浮控制"]) return YES;
    }
    return NO;
}

// Activation dialog detection is STRUCTURAL and title-independent, so it stays
// correct whether AudioSync has already mangled the title or not. The activation
// dialog is the only alert that carries a text field AND a "激活" action.
static BOOL vcuIsActivation(UIAlertController *ac) {
    if (ac.textFields.count == 0) return NO;
    for (UIAlertAction *a in ac.actions) {
        if (a.title && [a.title isEqualToString:@"激活"]) return YES;
    }
    return NO;
}

// Restore the activation dialog to its pristine original state (exact title, no
// injected 声音设置/旋转 actions). AudioSync's historical containsString hook may
// have renamed it to "vcam-iOS-V2" and injected buttons; we undo that. Runs AFTER
// the full present chain so any mangling has already happened.
static void vcuRepairActivation(UIAlertController *ac) {
    @try {
        if (![ac.title isEqualToString:@"Virtual Camera 授权"]) ac.title = @"Virtual Camera 授权";
        if ([ac respondsToSelector:@selector(removeAction:)]) {
            NSArray *junk = @[@"声音设置", @"旋转"];
            for (UIAlertAction *a in [ac.actions copy]) {
                for (NSString *t in junk) {
                    if (a.title && [a.title isEqualToString:t]) {
                        @try { [ac performSelector:@selector(removeAction:) withObject:a]; } @catch (NSException *e) {}
                        break;
                    }
                }
            }
        }
    } @catch (NSException *e) {}
}

static void vcuHookPresent(void) {
    @try {
        Method pm = class_getInstanceMethod([UIViewController class],
            @selector(presentViewController:animated:completion:));
        if (!pm || gVCUOrigPresent) return;
        gVCUOrigPresent = method_getImplementation(pm);
        IMP ni = imp_implementationWithBlock(^(id _self, UIViewController *vc, BOOL animated, void (^comp)(void)) {
            BOOL intercepted = NO;
            @try {
                if ([vc isKindOfClass:[UIAlertController class]]) {
                    UIAlertController *ac = (UIAlertController *)vc;
                    if (vcuIsMainMenu(ac)) {
                        [[VCUICtrl shared] showBall];
                        intercepted = YES;
                    } else if (vcuIsActivation(ac)) {
                        // Present through the full chain, then repair AudioSync's mangling.
                        ((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))gVCUOrigPresent)(
                            _self, @selector(presentViewController:animated:completion:), vc, animated, comp);
                        vcuRepairActivation(ac);
                        // The alert's labels are built during the presentation animation;
                        // re-apply the repair once more on the next runloop tick.
                        dispatch_async(dispatch_get_main_queue(), ^{ vcuRepairActivation(ac); });
                        return;
                    }
                }
            } @catch (NSException *e) {}
            if (!intercepted) {
                ((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))gVCUOrigPresent)(
                    _self, @selector(presentViewController:animated:completion:), vc, animated, comp);
            }
        });
        method_setImplementation(pm, ni);
    } @catch (NSException *e) {}
}

#pragma mark - Constructor

__attribute__((constructor))
static void vcamui_init(void) {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];
        NSArray *skip = @[@"mediaserverd", @"backboardd", @"runningboardd", @"configd",
            @"logd", @"wifid", @"locationd", @"Sileo", @"Filza",
            @"Zebra", @"Cydia", @"Installer", @"MobileSlideShow", @"PhotoPicker"];
        for (NSString *p in skip) {
            if ([proc containsString:p]) return;
        }
        @try {
            vcuHookPresent();
            // FWCtrl may not be loaded yet; retry panel build lazily on first show.
        } @catch (NSException *e) {}
    }
}
