#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <CoreAudio/CoreAudioTypes.h>
#import <MediaToolbox/MTAudioProcessingTap.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <stdint.h>

#define AS_DIR       @"/var/jb/var/mobile/Library/vcamplus"
#define AS_CFG       AS_DIR @"/audio.conf"
#define AS_CORE_FLAG AS_DIR @"/enabled"
#define AS_NOTIFY    @"com.vcamplus.audio.changed"
#define AS_MAX_QUEUE 40

static NSLock *gLock = nil;
static NSMutableArray *gBufQ = nil;
static AudioStreamBasicDescription gAppASBD;
static BOOL gAppASBDValid = NO;
static AVPlayer *gPlayer = nil;
static AudioStreamBasicDescription gTapASBD;
static BOOL gTapASBDValid = NO;
static AVAudioFormat *gTapFmt = nil;
static AVAudioFormat *gAppFmt = nil;
static AVAudioConverter *gConv = nil;
static BOOL gAudioOn = NO;
static BOOL gEngineActive = NO;
static NSString *gCfgURL = @"";
static float gVolume = 1.0f;
static int gSyncMode = 1;
static int gSrcType = 0;
static NSString *gAutoLastPath = nil;
static NSTimeInterval gLastAutoCheck = 0;
static NSTimeInterval gLastFlagCheck = 0;
static BOOL gLastFlagOn = NO;
static CMTime gLastInjPTS = kCMTimeInvalid;

static BOOL asCoreEnabled(void) {
    NSTimeInterval now = CACurrentMediaTime();
    if (now - gLastFlagCheck > 0.5) {
        gLastFlagCheck = now;
        gLastFlagOn = [[NSFileManager defaultManager] fileExistsAtPath:AS_CORE_FLAG];
    }
    return gLastFlagOn;
}

static void asWriteLog(NSString *msg) {
    @try {
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
        NSString *path = AS_DIR @"/audio.log";
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [[NSFileManager defaultManager] createDirectoryAtPath:AS_DIR withIntermediateDirectories:YES attributes:nil error:nil];
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
}

static void asReadConfig(void) {
    @try {
        NSString *content = [NSString stringWithContentsOfFile:AS_CFG encoding:NSUTF8StringEncoding error:nil];
        if (content.length < 3) { gAudioOn = NO; return; }
        NSArray *parts = [content componentsSeparatedByString:@","];
        gAudioOn = [parts[0] intValue] != 0;
        if (parts.count > 1) gCfgURL = parts[1];
        if (parts.count > 2) gVolume = [parts[2] floatValue];
        if (parts.count > 3) gSyncMode = [parts[3] intValue];
        if (parts.count > 4) gSrcType = [parts[4] intValue];
        asWriteLog([NSString stringWithFormat:@"config: on=%d url=%@ vol=%.2f mode=%d srctype=%d", gAudioOn, gCfgURL, gVolume, gSyncMode, gSrcType]);
    } @catch (NSException *e) {}
}

static void asWriteConfig(BOOL on, NSString *url, float vol, int mode, int srctype) {
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:AS_DIR withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *line = [NSString stringWithFormat:@"%d,%@,%.2f,%d,%d", on ? 1 : 0, url ?: @"", vol, mode, srctype];
        [line writeToFile:AS_CFG atomically:YES encoding:NSUTF8StringEncoding error:nil];
        asReadConfig();
    } @catch (NSException *e) {}
}

static void asFlushQueue(void) {
    if (!gLock || !gBufQ) return;
    [gLock lock];
    [gBufQ removeAllObjects];
    [gLock unlock];
}

static void asSchedulePull(void);

static void asTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut);
static void asTapFinalize(MTAudioProcessingTapRef tap);
static void asTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *processingFormat);
static void asTapUnprepare(MTAudioProcessingTapRef tap);
static void asTapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames, MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut, CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut);

static NSString *asResolveVideoPath(void) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *exts = @[@"mp4", @"MP4", @"mov", @"MOV", @"m4v", @"M4V"];
        NSString *content = [NSString stringWithContentsOfFile:AS_CORE_FLAG encoding:NSUTF8StringEncoding error:nil];
        if (content && content.length >= 3) {
            NSArray *parts = [content componentsSeparatedByString:@","];
            if (parts.count >= 2) {
                int idx = [parts[1] intValue];
                if (idx == 0) {
                    if ([fm fileExistsAtPath:AS_DIR @"/video.mp4"]) return AS_DIR @"/video.mp4";
                } else {
                    for (NSString *ext in exts) {
                        NSString *p = [NSString stringWithFormat:@"%@/%d.%@", AS_DIR, idx, ext];
                        if ([fm fileExistsAtPath:p]) return p;
                    }
                }
            }
        }
        if ([fm fileExistsAtPath:AS_DIR @"/video.mp4"]) return AS_DIR @"/video.mp4";
        for (int i = 1; i <= 6; i++) {
            for (NSString *ext in exts) {
                NSString *p = [NSString stringWithFormat:@"%@/%d.%@", AS_DIR, i, ext];
                if ([fm fileExistsAtPath:p]) return p;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

static NSString *asEffectiveURL(void) {
    if (gSrcType == 1) return asResolveVideoPath();
    return gCfgURL;
}

static BOOL asStartEngine(void) {
    if (gEngineActive) return YES;
    NSString *effectiveURL = asEffectiveURL();
    if (!effectiveURL.length) {
        asWriteLog(@"engine start skipped: no source");
        return NO;
    }
    if (gSrcType == 1) gAutoLastPath = effectiveURL;
    @try {
        NSURL *url = nil;
        if ([effectiveURL hasPrefix:@"/"]) url = [NSURL fileURLWithPath:effectiveURL];
        else url = [NSURL URLWithString:effectiveURL];
        if (!url) return NO;
        gBufQ = [NSMutableArray new];
        gTapASBDValid = NO;
        AVPlayerItem *item = [[AVPlayerItem alloc] initWithURL:url];
        AVAssetTrack *at = [[item asset] tracksWithMediaType:AVMediaTypeAudio].firstObject;
        MTAudioProcessingTapCallbacks cb = { 0 };
        cb.init = asTapInit;
        cb.finalize = asTapFinalize;
        cb.prepare = asTapPrepare;
        cb.unprepare = asTapUnprepare;
        cb.process = asTapProcess;
        cb.clientInfo = NULL;
        MTAudioProcessingTapRef tap = NULL;
        OSStatus ts = MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
        if (ts != noErr || !tap) {
            asWriteLog([NSString stringWithFormat:@"engine tap create failed: %d", (int)ts]);
            item = nil;
            return NO;
        }
        AVMutableAudioMixInputParameters *params = at
            ? [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:at]
            : [AVMutableAudioMixInputParameters audioMixInputParameters];
        params.audioTapProcessor = tap;
        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
        mix.inputParameters = @[params];
        item.audioMix = mix;
        CFRelease(tap);
        gPlayer = [[AVPlayer alloc] initWithPlayerItem:item];
        gPlayer.volume = 0.0f;
        [gPlayer play];
        gEngineActive = YES;
        asWriteLog([NSString stringWithFormat:@"engine start %@", effectiveURL]);
        asSchedulePull();
        return YES;
    } @catch (NSException *e) {
        asWriteLog([NSString stringWithFormat:@"engine start exception: %@", e]);
        return NO;
    }
}

static void asStopEngine(void) {
    if (!gEngineActive) return;
    @try {
        [gPlayer pause];
        gPlayer = nil;
        gTapASBDValid = NO;
        gTapFmt = nil;
        gAppFmt = nil;
        gConv = nil;
        gEngineActive = NO;
        asFlushQueue();
        asWriteLog(@"engine stop");
    } @catch (NSException *e) {}
}

static void asApplyGain(AVAudioPCMBuffer *buf, float gain) {
    if (gain == 1.0f) return;
    AudioBufferList *abl = buf.mutableAudioBufferList;
    for (UInt32 i = 0; i < abl->mNumberBuffers; i++) {
        AudioBuffer *b = &abl->mBuffers[i];
        if (!b->mData) continue;
        if (buf.format.commonFormat == AVAudioPCMFormatFloat32) {
            size_t n = b->mDataByteSize / 4;
            float *fp = (float *)b->mData;
            for (size_t j = 0; j < n; j++) fp[j] *= gain;
        } else if (buf.format.commonFormat == AVAudioPCMFormatInt16) {
            size_t n = b->mDataByteSize / 2;
            int16_t *sp = (int16_t *)b->mData;
            for (size_t j = 0; j < n; j++) sp[j] = (int16_t)(sp[j] * gain);
        }
    }
}

static void asTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    if (tapStorageOut) *tapStorageOut = NULL;
}

static void asTapFinalize(MTAudioProcessingTapRef tap) {}

static void asTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *processingFormat) {
    if (processingFormat) {
        gTapASBD = *processingFormat;
        gTapASBDValid = YES;
    }
}

static void asTapUnprepare(MTAudioProcessingTapRef tap) {}

static void asTapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
    MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut,
    CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    @autoreleasepool {
        CMTimeRange timeRange = kCMTimeRangeZero;
        MTAudioProcessingTapFlags srcFlags = 0;
        OSStatus st = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, &srcFlags, &timeRange, numberFramesOut);
        if (st != noErr || !bufferListInOut || !numberFramesOut || *numberFramesOut <= 0 || bufferListInOut->mNumberBuffers == 0) return;
        if (!gEngineActive || !gAudioOn || !gTapASBDValid || !gAppASBDValid) return;
        AudioBufferList *abl = bufferListInOut;
        if (!abl->mBuffers[0].mData) return;
        @try {
            if (!gTapFmt) gTapFmt = [[AVAudioFormat alloc] initWithStreamDescription:&gTapASBD];
            if (!gAppFmt) gAppFmt = [[AVAudioFormat alloc] initWithStreamDescription:&gAppASBD];
            if (!gTapFmt || !gAppFmt) return;
            if (gTapFmt.channelCount != abl->mNumberBuffers) return;
            if (!gConv) gConv = [[AVAudioConverter alloc] initFromFormat:gTapFmt toFormat:gAppFmt];
            if (!gConv) return;
            AVAudioPCMBuffer *inBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:gTapFmt
                bufferListNoCopy:abl deallocator:^(const AudioBufferList *list) {}];
            inBuf.frameLength = (AVAudioFrameCount)*numberFramesOut;
            AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:gAppFmt frameCapacity:16384];
            NSError *err = nil;
            BOOL ok = [gConv convertToBuffer:outBuf fromBuffer:inBuf error:&err];
            if (ok && outBuf.frameLength > 0) {
                asApplyGain(outBuf, gVolume);
                [gLock lock];
                if (gBufQ.count < AS_MAX_QUEUE) {
                    [gBufQ addObject:outBuf];
                }
                [gLock unlock];
            }
        } @catch (NSException *e) {}
    }
}

static void asSchedulePull(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            @try {
                if (gSrcType == 1 && gEngineActive) {
                    NSTimeInterval now = CACurrentMediaTime();
                    if (now - gLastAutoCheck > 1.0) {
                        gLastAutoCheck = now;
                        NSString *cur = asResolveVideoPath();
                        if (cur && ![cur isEqualToString:gAutoLastPath]) {
                            asWriteLog([NSString stringWithFormat:@"auto source switched: %@ -> %@", gAutoLastPath, cur]);
                            asStopEngine();
                            asStartEngine();
                            return;
                        }
                    }
                }
            } @catch (NSException *e) {}
            if (gEngineActive) asSchedulePull();
        });
}

static CMSampleBufferRef asBuildSampleBuffer(AVAudioPCMBuffer *pcm, CMTime pts, CMTime dur) {
    if (!pcm || pcm.frameLength == 0) return NULL;
    @try {
        AudioBufferList *abl = pcm.mutableAudioBufferList;
        if (abl->mNumberBuffers == 0 || !abl->mBuffers[0].mData) return NULL;
        size_t dataLen = abl->mBuffers[0].mDataByteSize;
        UInt32 channels = pcm.format.channelCount;
        size_t sampleSize = channels > 0 ? (dataLen / pcm.frameLength) / channels : 1;

        CMBlockBufferRef block = NULL;
        OSStatus st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, abl->mBuffers[0].mData, dataLen,
            kCFAllocatorNull, NULL, 0, dataLen, 0, &block);
        if (st != kCMBlockBufferNoErr) return NULL;

        AudioStreamBasicDescription asbd = *pcm.format.streamDescription;
        CMAudioFormatDescriptionRef fd = NULL;
        CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &fd);

        CMSampleTimingInfo timing = { dur, pts, pts };
        size_t sizes[1] = { sampleSize };
        CMSampleBufferRef out = NULL;
        CMSampleBufferCreateReady(kCFAllocatorDefault, block, fd, pcm.frameLength, 1, &timing, 1, sizes, &out);
        if (block) CFRelease(block);
        if (fd) CFRelease(fd);
        return out;
    } @catch (NSException *e) {
        return NULL;
    }
}

static CMSampleBufferRef asPopNextBuffer(CMTime refPTS) {
    CMSampleBufferRef out = NULL;
    [gLock lock];
    if (gBufQ.count > 0) {
        AVAudioPCMBuffer *pcm = [gBufQ firstObject];
        [gBufQ removeObjectAtIndex:0];
        CMTime dur = CMTimeMakeWithSeconds((double)pcm.frameLength / pcm.format.sampleRate, 1000);
        CMTime pts = (gSyncMode == 1) ? refPTS
            : CMTimeMakeWithSeconds(gPlayer ? CMTimeGetSeconds([gPlayer currentTime]) : 0.0, 1000);
        if (gSyncMode == 1) {
            CMTime delta = CMTimeSubtract(refPTS, gLastInjPTS);
            if (CMTIME_IS_VALID(gLastInjPTS) && CMTimeGetSeconds(delta) < -0.3) {
                while (gBufQ.count > 1) [gBufQ removeObjectAtIndex:0];
            }
        }
        gLastInjPTS = refPTS;
        out = asBuildSampleBuffer(pcm, pts, dur);
    }
    [gLock unlock];
    return out;
}

static void asUpdateEngineState(void) {
    BOOL want = gAudioOn && asCoreEnabled() && (gSrcType == 1 || gCfgURL.length > 0);
    if (want && !gEngineActive) {
        asStartEngine();
    } else if (!want && gEngineActive) {
        asStopEngine();
    }
}

static void asConfigChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    asReadConfig();
    asUpdateEngineState();
}

static IMP gOrigPresent = NULL;
static void (*gOrigSampleOutput)(id, SEL, id, CMSampleBufferRef, id) = NULL;

static void vcamSwiAudioDelegate(id _self, SEL _cmd, id output, CMSampleBufferRef sb, id conn) {
    @autoreleasepool {
        @try {
            CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
            BOOL isAudio = fd && CMFormatDescriptionGetMediaType(fd) == kCMMediaType_Audio;
            if (isAudio) {
                if (!gAppASBDValid) {
                    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription((CMAudioFormatDescriptionRef)fd);
                    if (asbd) {
                        gAppASBD = *asbd;
                        gAppASBDValid = YES;
                        asWriteLog([NSString stringWithFormat:@"app audio format: %.1fHz %uch %ubit", asbd->mSampleRate, asbd->mChannelsPerFrame, asbd->mBitsPerChannel]);
                        asUpdateEngineState();
                    }
                }
                if (gEngineActive && gAppASBDValid && gAudioOn && asCoreEnabled()) {
                    CMSampleBufferRef replaced = asPopNextBuffer(CMSampleBufferGetPresentationTimeStamp(sb));
                    if (replaced) {
                        gOrigSampleOutput(_self, _cmd, output, replaced, conn);
                        CFRelease(replaced);
                        return;
                    }
                }
            }
        } @catch (NSException *e) {
            asWriteLog([NSString stringWithFormat:@"delegate exception: %@", e]);
        }
    }
    if (gOrigSampleOutput) gOrigSampleOutput(_self, _cmd, output, sb, conn);
}

static void vcamSwiAudioDelegateTramp(id _self, SEL _cmd, id output, CMSampleBufferRef sb, id conn) {
    vcamSwiAudioDelegate(_self, _cmd, output, sb, conn);
}

static void asHookAudioOutput(void) {
    @try {
        Class cls = objc_getClass("AVCaptureAudioDataOutput");
        if (!cls) return;
        SEL sel = @selector(setSampleBufferDelegate:queue:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return;
        typedef void (*F)(id, SEL, id, dispatch_queue_t);
        F orig = (F)method_getImplementation(m);
        IMP ni = imp_implementationWithBlock(^(id _self, id delegate, dispatch_queue_t queue) {
            @try {
                if (delegate) {
                    Class dcls = object_getClass(delegate);
                    if (dcls) {
                        SEL capSel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
                        Method capM = class_getInstanceMethod(dcls, capSel);
                        if (capM && !gOrigSampleOutput) {
                            gOrigSampleOutput = (void (*)(id, SEL, id, CMSampleBufferRef, id))method_getImplementation(capM);
                            method_setImplementation(capM, (IMP)vcamSwiAudioDelegateTramp);
                            asWriteLog([NSString stringWithFormat:@"hooked audio delegate %@", NSStringFromClass(dcls)]);
                        }
                    }
                }
            } @catch (NSException *e) {}
            if (orig) orig(_self, sel, delegate, queue);
        });
        method_setImplementation(m, ni);
    } @catch (NSException *e) {}
}

@interface SoundPanel : UIViewController
+ (void)present;
@end

@interface SoundPanel ()
@property (nonatomic, strong) UISwitch *onSwitch;
@property (nonatomic, strong) UISegmentedControl *typeSeg;
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UISlider *volSlider;
@property (nonatomic, strong) UILabel *volLabel;
@property (nonatomic, strong) UISegmentedControl *modeSeg;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *testBtn;
@end

static UIViewController *asTopVC(void) {
    UIViewController *top = nil;
    @try {
        UIWindow *win = [UIApplication sharedApplication].keyWindow;
        if (!win) win = [UIApplication sharedApplication].windows.firstObject;
        top = win.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
    } @catch (NSException *e) {}
    return top;
}

@implementation SoundPanel

+ (void)present {
    @try {
        UIViewController *top = asTopVC();
        if (!top) return;
        if ([top isKindOfClass:[self class]]) return;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[SoundPanel new]];
        [top presentViewController:nav animated:YES completion:nil];
    } @catch (NSException *e) {}
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    self.title = @"\u58F0\u97F3\u540C\u6B65\u8BBE\u7F6E";
    CGFloat w = self.view.bounds.size.width;
    CGFloat y = 20.0f;

    _onSwitch = [UISwitch new];
    _onSwitch.frame = CGRectMake(w - 80, y, 60, 30);
    _onSwitch.on = gAudioOn;
    [self.view addSubview:_onSwitch];
    [self addLabel:@"\u58F0\u97F3\u5F00\u5173" y:y + 2];
    y += 44;

    _typeSeg = [[UISegmentedControl alloc] initWithItems:@[@"\u81EA\u52A8(\u540C\u6E90)", @"HLS/MP3", @"\u672C\u5730\u6587\u4EF6"]];
    _typeSeg.frame = CGRectMake(w - 200, y, 200, 30);
    _typeSeg.selectedSegmentIndex = (gSrcType == 1) ? 0 : 1;
    [_typeSeg addTarget:self action:@selector(typeChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_typeSeg];
    [self addLabel:@"\u97F3\u9891\u6E90\u7C7B\u578B" y:y + 2];
    y += 44;

    _urlField = [[UITextField alloc] initWithFrame:CGRectMake(w - 200, y, 180, 32)];
    _urlField.text = gCfgURL;
    _urlField.placeholder = @"http://ip:8080/live/stream.m3u8";
    _urlField.borderStyle = UITextBorderStyleRoundedRect;
    _urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _urlField.autocorrectionType = UITextAutocorrectionTypeNo;
    _urlField.keyboardType = UIKeyboardTypeURL;
    _urlField.enabled = (gSrcType != 1);
    _urlField.textColor = _urlField.enabled ? [UIColor whiteColor] : [UIColor grayColor];
    [self.view addSubview:_urlField];
    [self addLabel:@"\u97F3\u9891\u5730\u5740 (OBS)" y:y + 4];
    y += 46;

    _testBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _testBtn.frame = CGRectMake(w - 200, y, 180, 30);
    [_testBtn setTitle:@"\u6D4B\u8BD5\u8FDE\u63A5" forState:UIControlStateNormal];
    [_testBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _testBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.4 blue:0.9 alpha:1.0];
    _testBtn.layer.cornerRadius = 6;
    [_testBtn addTarget:self action:@selector(testTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_testBtn];
    y += 44;

    _volSlider = [[UISlider alloc] initWithFrame:CGRectMake(w - 200, y, 150, 30)];
    _volSlider.minimumValue = 0;
    _volSlider.maximumValue = 2.0f;
    _volSlider.value = gVolume;
    [_volSlider addTarget:self action:@selector(volChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_volSlider];
    _volLabel = [[UILabel alloc] initWithFrame:CGRectMake(w - 44, y, 40, 30)];
    _volLabel.textColor = [UIColor whiteColor];
    _volLabel.font = [UIFont systemFontOfSize:13];
    _volLabel.text = [NSString stringWithFormat:@"%.0f%%", gVolume * 100];
    [self.view addSubview:_volLabel];
    [self addLabel:@"\u97F3\u91CF" y:y + 4];
    y += 44;

    _modeSeg = [[UISegmentedControl alloc] initWithItems:@[@"\u5B9E\u65F6", @"\u5BF9\u9F50"]];
    _modeSeg.frame = CGRectMake(w - 200, y, 180, 30);
    _modeSeg.selectedSegmentIndex = gSyncMode;
    [self.view addSubview:_modeSeg];
    [self addLabel:@"\u540C\u6B65\u65B9\u5F0F" y:y + 2];
    y += 44;

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w - 40, 36)];
    _statusLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    _statusLabel.font = [UIFont systemFontOfSize:12];
    _statusLabel.numberOfLines = 2;
    [self.view addSubview:_statusLabel];
    y += 50;

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    save.frame = CGRectMake(20, y, (w - 52) / 2, 38);
    [save setTitle:@"\u4FDD\u5B58" forState:UIControlStateNormal];
    save.backgroundColor = [UIColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:1.0];
    [save setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    save.layer.cornerRadius = 8;
    [save addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:save];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(w / 2 + 6, y, (w - 52) / 2, 38);
    [cancel setTitle:@"\u53D6\u6D88" forState:UIControlStateNormal];
    cancel.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    [cancel setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    cancel.layer.cornerRadius = 8;
    [cancel addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:cancel];

    [self refreshStatus];
}

- (void)addLabel:(NSString *)text y:(CGFloat)y {
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 140, 24)];
    lb.text = text;
    lb.textColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    lb.font = [UIFont systemFontOfSize:14];
    [self.view addSubview:lb];
}

- (void)refreshStatus {
    if (!_statusLabel) return;
    if (!_onSwitch.on) {
        _statusLabel.text = @"\u72B6\u6001: \u672A\u542F\u7528";
        _statusLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    } else if (gEngineActive) {
        _statusLabel.text = [NSString stringWithFormat:@"\u72B6\u6001: \u5DF2\u8FDE\u63A5 \u97F3\u753B\u540C\u6B65 %@",
            gSyncMode == 1 ? @"\u5BF9\u9F50" : @"\u5B9E\u65F6"];
        _statusLabel.textColor = [UIColor colorWithRed:0.13 green:0.85 blue:0.45 alpha:1.0];
    } else {
        _statusLabel.text = @"\u72B6\u6001: \u672A\u8FDE\u63A5 (\u5148\u4FDD\u5B58\u5E76\u5F00\u542F\u865A\u62DF\u76F8\u673A)";
        _statusLabel.textColor = [UIColor colorWithRed:1.0 green:0.6 blue:0.3 alpha:1.0];
    }
}

- (void)volChanged {
    _volLabel.text = [NSString stringWithFormat:@"%.0f%%", _volSlider.value * 100];
}

- (void)typeChanged {
    BOOL autoMode = (_typeSeg.selectedSegmentIndex == 0);
    _urlField.enabled = !autoMode;
    _urlField.textColor = autoMode ? [UIColor grayColor] : [UIColor whiteColor];
}

- (void)testTapped {
    @try {
        NSString *url = _urlField.text ?: @"";
        if (!url.length) return;
        [_testBtn setTitle:@"\u8FDE\u63A5\u4E2D..." forState:UIControlStateNormal];
        _testBtn.enabled = NO;
        NSURL *nsurl = [url hasPrefix:@"/"] ? [NSURL fileURLWithPath:url] : [NSURL URLWithString:url];
        AVPlayerItem *item = [[AVPlayerItem alloc] initWithURL:nsurl];
        __weak typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SoundPanel *sp = ws;
            if (!sp) return;
            if (item.status == AVPlayerItemStatusReadyToPlay) {
                sp->_statusLabel.text = @"\u72B6\u6001: \u6D4B\u8BD5\u6210\u529F, \u97F3\u9891\u6E90\u53EF\u7528";
                sp->_statusLabel.textColor = [UIColor colorWithRed:0.13 green:0.85 blue:0.45 alpha:1.0];
            } else if (item.status == AVPlayerItemStatusFailed) {
                sp->_statusLabel.text = [NSString stringWithFormat:@"\u72B6\u6001: \u8FDE\u63A5\u5931\u8D25 %@", item.error.localizedDescription];
                sp->_statusLabel.textColor = [UIColor redColor];
            } else {
                sp->_statusLabel.text = @"\u72B6\u6001: \u8FDE\u63A5\u8D85\u65F6";
                sp->_statusLabel.textColor = [UIColor redColor];
            }
            sp->_testBtn.enabled = YES;
            [sp->_testBtn setTitle:@"\u6D4B\u8BD5\u8FDE\u63A5" forState:UIControlStateNormal];
        });
    } @catch (NSException *e) {}
}

- (void)saveTapped {
    @try {
        int st = (_typeSeg.selectedSegmentIndex == 0) ? 1 : 0;
        NSString *url = _urlField.text ?: @"";
        if (_onSwitch.on && st == 0 && !url.length) {
            _statusLabel.text = @"\u72B6\u6001: \u8BF7\u5148\u8F93\u5165\u97F3\u9891\u5730\u5740";
            _statusLabel.textColor = [UIColor redColor];
            return;
        }
        NSString *trimmed = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        asWriteConfig(_onSwitch.on, trimmed, _volSlider.value, (int)_modeSeg.selectedSegmentIndex, st);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)AS_NOTIFY, NULL, NULL, YES);
        asUpdateEngineState();
        [self dismissViewControllerAnimated:YES completion:nil];
    } @catch (NSException *e) {}
}

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static void asTidyMainMenu(UIAlertController *ac) {
    @try {
        NSArray *removeTitles = @[@"\u9009\u62E9\u56FE\u7247", @"\u60AC\u6D6E\u63A7\u5236"];
        NSMutableArray *toRemove = [NSMutableArray new];
        for (UIAlertAction *a in ac.actions) {
            for (NSString *t in removeTitles) {
                if (a.title && [a.title isEqualToString:t]) {
                    [toRemove addObject:a];
                    break;
                }
            }
        }
        if (toRemove.count > 0 && [ac respondsToSelector:@selector(removeAction:)]) {
            for (UIAlertAction *a in toRemove) {
                @try {
                    [ac performSelector:@selector(removeAction:) withObject:a];
                } @catch (NSException *e) {}
            }
        }
    } @catch (NSException *e) {}
}

static __weak UIButton *gPanelCamBtn = nil;

static void asPanelStream(void) {
    @try {
        UIViewController *top = asTopVC();
        if (!top) return;
        NSString *lastURL = [NSString stringWithContentsOfFile:AS_DIR @"/stream.conf" encoding:NSUTF8StringEncoding error:nil];
        if (!lastURL || lastURL.length == 0) lastURL = @"http://192.168.1.100:8080";
        UIAlertController *input = [UIAlertController alertControllerWithTitle:@"MJPEG \u76F4\u64AD\u6D41"
            message:@"\u8F93\u5165 MJPEG \u6D41\u5730\u5740\n\u4F8B: http://\u7535\u8111IP:\u7AEF\u53E3"
            preferredStyle:UIAlertControllerStyleAlert];
        [input addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = lastURL;
            tf.placeholder = @"http://192.168.1.100:8080";
            tf.keyboardType = UIKeyboardTypeURL;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [input addAction:[UIAlertAction actionWithTitle:@"\u8FDE\u63A5" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x2) {
            @try {
                NSString *url = input.textFields.firstObject.text;
                if (!url || url.length == 0) return;
                [url writeToFile:AS_DIR @"/stream.conf" atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [@"1" writeToFile:AS_CORE_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
                Class cls = objc_getClass("MJRcv");
                id rcv = cls ? [cls performSelector:@selector(shared)] : nil;
                if (rcv) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [rcv performSelector:@selector(startWithURL:) withObject:url];
                    #pragma clang diagnostic pop
                }
                asWriteLog([NSString stringWithFormat:@"panel stream connect: %@", url]);
            } @catch (NSException *e) {}
        }]];
        [input addAction:[UIAlertAction actionWithTitle:@"\u53D6\u6D88" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:input animated:YES completion:nil];
    } @catch (NSException *e) {}
}

static void asPanelToggleReplace(void) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:AS_CORE_FLAG]) {
            [fm removeItemAtPath:AS_CORE_FLAG error:nil];
            asWriteLog(@"panel replace OFF");
        } else {
            [@"1" writeToFile:AS_CORE_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
            asWriteLog(@"panel replace ON");
        }
    } @catch (NSException *e) {}
}

static UIButton *asMakePanelButton(UIView *panel, id target, int tag, NSString *title, CGRect frame) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    b.layer.cornerRadius = 6;
    b.clipsToBounds = YES;
    b.backgroundColor = [UIColor whiteColor];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15];
    b.tag = tag;
    [b addTarget:target action:@selector(btnTap:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:b];
    return b;
}

@interface ASPanelTarget : NSObject
@property (nonatomic, copy) void (^action)(void);
@end
@implementation ASPanelTarget
- (void)fire { if (_action) _action(); }
@end

static NSMutableArray *gTargets = nil;

static UIColor *cRGB(int r, int g, int b) {
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
}

static void asTidyFloatPanel(UIView *panel) {
    @try {
        if (!panel) return;
        for (UIView *sv in [panel.subviews copy]) [sv removeFromSuperview];

        CGFloat scrW = [UIScreen mainScreen].bounds.size.width;
        CGFloat scale = 1.0;
        if (scrW < 450) scale = (scrW - 16) / 420.0;

        CGRect pfr = panel.frame;
        pfr.size = CGSizeMake(420 * scale, 440 * scale);
        panel.frame = pfr;

        panel.backgroundColor = cRGB(22, 33, 62);
        panel.layer.cornerRadius = 14 * scale;
        panel.layer.borderColor = cRGB(58, 90, 140).CGColor;
        panel.layer.borderWidth = 1.5;
        panel.clipsToBounds = YES;

        Class cls = objc_getClass("FWCtrl");
        id inst = cls ? [cls performSelector:@selector(shared)] : nil;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20 * scale, 28 * scale, 300 * scale, 24 * scale)];
        title.text = @"vcam-iOS-V2 \u63A7\u5236\u9762\u677F";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:15 * scale];
        [panel addSubview:title];

        UIButton *closeX = [UIButton buttonWithType:UIButtonTypeCustom];
        closeX.frame = CGRectMake(358 * scale, 28 * scale, 42 * scale, 24 * scale);
        [closeX setTitle:@"\u2715" forState:UIControlStateNormal];
        [closeX setTitleColor:cRGB(255, 107, 107) forState:UIControlStateNormal];
        closeX.titleLabel.font = [UIFont systemFontOfSize:16 * scale];
        closeX.tag = 109;
        if (inst) [closeX addTarget:inst action:@selector(btnTap:) forControlEvents:UIControlEventTouchUpInside];
        [panel addSubview:closeX];

        UIView *leftZone = [[UIView alloc] initWithFrame:CGRectMake(16 * scale, 44 * scale, 196 * scale, 380 * scale)];
        leftZone.backgroundColor = cRGB(16, 26, 46);
        leftZone.layer.cornerRadius = 10 * scale;
        leftZone.layer.borderColor = cRGB(44, 74, 122).CGColor;
        leftZone.layer.borderWidth = 1;
        leftZone.clipsToBounds = YES;
        [panel addSubview:leftZone];

        UIView *rightZone = [[UIView alloc] initWithFrame:CGRectMake(226 * scale, 44 * scale, 178 * scale, 380 * scale)];
        rightZone.backgroundColor = cRGB(15, 52, 96);
        rightZone.layer.cornerRadius = 10 * scale;
        rightZone.layer.borderColor = cRGB(34, 197, 94).CGColor;
        rightZone.layer.borderWidth = 1;
        rightZone.clipsToBounds = YES;
        [panel addSubview:rightZone];

        UIButton *(^mkBtn)(int, NSString *, CGRect) = ^UIButton *(int tag, NSString *t, CGRect f) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(f.origin.x * scale, f.origin.y * scale, f.size.width * scale, f.size.height * scale);
            b.layer.cornerRadius = 5 * scale;
            b.clipsToBounds = YES;
            [b setTitle:t forState:UIControlStateNormal];
            [b setTitleColor:cRGB(207, 216, 227) forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:11 * scale];
            b.backgroundColor = cRGB(29, 44, 77);
            b.layer.borderWidth = 1;
            b.layer.borderColor = cRGB(44, 74, 122).CGColor;
            b.tag = tag;
            if (inst) [b addTarget:inst action:@selector(btnTap:) forControlEvents:UIControlEventTouchUpInside];
            [panel addSubview:b];
            return b;
        };

        UILabel *(^mkLabel)(NSString *, CGRect) = ^UILabel *(NSString *t, CGRect f) {
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(f.origin.x * scale, f.origin.y * scale, f.size.width * scale, f.size.height * scale)];
            l.text = t;
            l.textColor = cRGB(125, 141, 161);
            l.font = [UIFont systemFontOfSize:10 * scale];
            [panel addSubview:l];
            return l;
        };

        UILabel *fTitle = [[UILabel alloc] initWithFrame:CGRectMake(28 * scale, 64 * scale, 120 * scale, 16 * scale)];
        fTitle.text = @"\u529F\u80FD\u83DC\u5355";
        fTitle.textColor = cRGB(159, 179, 200);
        fTitle.font = [UIFont systemFontOfSize:11 * scale];
        [panel addSubview:fTitle];

        mkLabel(@"\u89C6\u9891\u5207\u6362 (tag 1-6)", CGRectMake(28, 86, 160, 14));
        mkBtn(1, @"1", CGRectMake(28, 92, 42, 30));
        mkBtn(2, @"2", CGRectMake(74, 92, 42, 30));
        mkBtn(3, @"3", CGRectMake(120, 92, 42, 30));
        mkBtn(4, @"4", CGRectMake(28, 126, 42, 30));
        mkBtn(5, @"5", CGRectMake(74, 126, 42, 30));
        mkBtn(6, @"6", CGRectMake(120, 126, 42, 30));

        mkLabel(@"\u753B\u9762\u63A7\u5236", CGRectMake(28, 174, 150, 14));
        mkBtn(100, @"\u2191100", CGRectMake(28, 180, 42, 30));
        UIButton *rot = mkBtn(101, @"\u8F6C", CGRectMake(74, 180, 42, 30));
        rot.backgroundColor = cRGB(29, 44, 77);
        rot.layer.borderColor = cRGB(34, 197, 94).CGColor;
        [rot setTitleColor:cRGB(74, 222, 128) forState:UIControlStateNormal];
        mkBtn(105, @"\u2193105", CGRectMake(120, 180, 42, 30));
        mkBtn(102, @"\u2190102", CGRectMake(28, 214, 42, 30));
        mkBtn(103, @"\u6B63103", CGRectMake(74, 214, 42, 30));
        mkBtn(104, @"\u2192104", CGRectMake(120, 214, 42, 30));
        mkBtn(107, @"\u25B6107", CGRectMake(28, 248, 42, 30));
        mkBtn(106, @"\u7FFB106", CGRectMake(74, 248, 42, 30));
        mkBtn(108, @"\u23F8108", CGRectMake(120, 248, 42, 30));

        mkLabel(@"\u5FEB\u6377", CGRectMake(28, 296, 150, 14));
        UIButton *liveBtn = mkBtn(200, @"\u76F4\u64AD", CGRectMake(28, 302, 42, 30));
        liveBtn.backgroundColor = cRGB(20, 83, 45);
        liveBtn.layer.borderColor = cRGB(34, 197, 94).CGColor;
        [liveBtn setTitleColor:cRGB(74, 222, 128) forState:UIControlStateNormal];
        gPanelCamBtn = mkBtn(201, @"\u76F8\u673A", CGRectMake(74, 302, 42, 30));
        gPanelCamBtn.backgroundColor = cRGB(20, 83, 45);
        gPanelCamBtn.layer.borderColor = cRGB(34, 197, 94).CGColor;
        [gPanelCamBtn setTitleColor:cRGB(74, 222, 128) forState:UIControlStateNormal];
        UIButton *offBtn = mkBtn(109, @"\u5173\u95ED", CGRectMake(120, 302, 42, 30));
        offBtn.backgroundColor = cRGB(127, 29, 29);
        offBtn.layer.borderColor = cRGB(255, 107, 107).CGColor;
        [offBtn setTitleColor:cRGB(255, 155, 155) forState:UIControlStateNormal];

        mkLabel(@"\u989C\u8272\u6CE8\u5165", CGRectMake(28, 352, 150, 14));
        mkBtn(110, @"\u5F69110", CGRectMake(28, 358, 42, 30));
        mkBtn(111, @"+111", CGRectMake(74, 358, 42, 30));
        mkBtn(112, @"-112", CGRectMake(120, 358, 42, 30));

        UILabel *rTitle = [[UILabel alloc] initWithFrame:CGRectMake(238 * scale, 64 * scale, 150 * scale, 16 * scale)];
        rTitle.text = @"\u58F0\u97F3\u540C\u6B65\u8BBE\u7F6E";
        rTitle.textColor = cRGB(74, 222, 128);
        rTitle.font = [UIFont boldSystemFontOfSize:11 * scale];
        [panel addSubview:rTitle];

        UILabel *swLbl = [[UILabel alloc] initWithFrame:CGRectMake(238 * scale, 90 * scale, 70 * scale, 20 * scale)];
        swLbl.text = @"\u58F0\u97F3\u5F00\u5173";
        swLbl.textColor = cRGB(207, 216, 227);
        swLbl.font = [UIFont systemFontOfSize:11 * scale];
        [panel addSubview:swLbl];

        UISwitch *onSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(310 * scale, 78 * scale, 72 * scale, 24 * scale)];
        onSwitch.on = gAudioOn;
        [panel addSubview:onSwitch];

        UILabel *tyLbl = [[UILabel alloc] initWithFrame:CGRectMake(238 * scale, 116 * scale, 100 * scale, 14 * scale)];
        tyLbl.text = @"\u97F3\u9891\u6E90\u7C7B\u578B";
        tyLbl.textColor = cRGB(207, 216, 227);
        tyLbl.font = [UIFont systemFontOfSize:11 * scale];
        [panel addSubview:tyLbl];

        UISegmentedControl *typeSeg = [[UISegmentedControl alloc] initWithItems:@[@"\u81EA\u52A8(\u540C\u6E90)", @"HLS/MP3"]];
        typeSeg.frame = CGRectMake(238 * scale, 122 * scale, 154 * scale, 24 * scale);
        typeSeg.selectedSegmentIndex = (gSrcType == 1) ? 0 : 1;
        [panel addSubview:typeSeg];

        UILabel *urlLbl = [[UILabel alloc] initWithFrame:CGRectMake(238 * scale, 158 * scale, 120 * scale, 14 * scale)];
        urlLbl.text = @"\u97F3\u9891\u5730\u5740 (OBS)";
        urlLbl.textColor = cRGB(207, 216, 227);
        urlLbl.font = [UIFont systemFontOfSize:11 * scale];
        [panel addSubview:urlLbl];

        UITextField *urlField = [[UITextField alloc] initWithFrame:CGRectMake(238 * scale, 164 * scale, 154 * scale, 24 * scale)];
        urlField.text = gCfgURL;
        urlField.placeholder = @"http://ip:8080/stream.m3u8";
        urlField.borderStyle = UITextBorderStyleRoundedRect;
        urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        urlField.autocorrectionType = UITextAutocorrectionTypeNo;
        urlField.keyboardType = UIKeyboardTypeURL;
        urlField.enabled = (gSrcType != 1);
        urlField.textColor = urlField.enabled ? [UIColor whiteColor] : [UIColor grayColor];
        urlField.font = [UIFont systemFontOfSize:10 * scale];
        [panel addSubview:urlField];

        UIButton *testBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        testBtn.frame = CGRectMake(238 * scale, 194 * scale, 154 * scale, 22 * scale);
        [testBtn setTitle:@"\u6D4B\u8BD5\u8FDE\u63A5" forState:UIControlStateNormal];
        [testBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        testBtn.backgroundColor = cRGB(37, 99, 235);
        testBtn.layer.cornerRadius = 5 * scale;
        testBtn.titleLabel.font = [UIFont systemFontOfSize:11 * scale];
        [panel addSubview:testBtn];

        UILabel *volLbl = [[UILabel alloc] initWithFrame:CGRectMake(238 * scale, 238 * scale, 50 * scale, 20 * scale)];
        volLbl.text = @"\u97F3\u91CF";
        volLbl.textColor = cRGB(207, 216, 227);
        volLbl.font = [UIFont systemFontOfSize:11 * scale];
        [panel addSubview:volLbl];

        UISlider *volSlider = [[UISlider alloc] initWithFrame:CGRectMake(270 * scale, 224 * scale, 90 * scale, 24 * scale)];
        volSlider.minimumValue = 0;
        volSlider.maximumValue = 2.0f;
        volSlider.value = gVolume;
        [panel addSubview:volSlider];

        UILabel *volVal = [[UILabel alloc] initWithFrame:CGRectMake(358 * scale, 238 * scale, 30 * scale, 20 * scale)];
        volVal.textColor = [UIColor whiteColor];
        volVal.font = [UIFont systemFontOfSize:10 * scale];
        volVal.text = [NSString stringWithFormat:@"%.0f%%", gVolume * 100];
        [panel addSubview:volVal];

        UILabel *modeLbl = [[UILabel alloc] initWithFrame:CGRectMake(238 * scale, 268 * scale, 70 * scale, 14 * scale)];
        modeLbl.text = @"\u540C\u6B65\u65B9\u5F0F";
        modeLbl.textColor = cRGB(207, 216, 227);
        modeLbl.font = [UIFont systemFontOfSize:11 * scale];
        [panel addSubview:modeLbl];

        UISegmentedControl *modeSeg = [[UISegmentedControl alloc] initWithItems:@[@"\u5B9E\u65F6", @"\u5BF9\u9F50"]];
        modeSeg.frame = CGRectMake(238 * scale, 274 * scale, 120 * scale, 22 * scale);
        modeSeg.selectedSegmentIndex = gSyncMode;
        [panel addSubview:modeSeg];

        UILabel *statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(238 * scale, 306 * scale, 154 * scale, 34 * scale)];
        statusLbl.textColor = cRGB(125, 141, 161);
        statusLbl.font = [UIFont systemFontOfSize:10 * scale];
        statusLbl.numberOfLines = 2;
        [panel addSubview:statusLbl];

        UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        saveBtn.frame = CGRectMake(238 * scale, 352 * scale, 74 * scale, 26 * scale);
        [saveBtn setTitle:@"\u4FDD\u5B58" forState:UIControlStateNormal];
        [saveBtn setTitleColor:cRGB(6, 44, 20) forState:UIControlStateNormal];
        saveBtn.backgroundColor = cRGB(34, 197, 94);
        saveBtn.layer.cornerRadius = 6 * scale;
        saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11 * scale];
        [panel addSubview:saveBtn];

        UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        cancelBtn.frame = CGRectMake(318 * scale, 352 * scale, 74 * scale, 26 * scale);
        [cancelBtn setTitle:@"\u53D6\u6D88" forState:UIControlStateNormal];
        [cancelBtn setTitleColor:cRGB(207, 216, 227) forState:UIControlStateNormal];
        cancelBtn.backgroundColor = cRGB(51, 65, 85);
        cancelBtn.layer.cornerRadius = 6 * scale;
        cancelBtn.titleLabel.font = [UIFont systemFontOfSize:11 * scale];
        [panel addSubview:cancelBtn];

        void (^refreshStatus)(void) = ^{
            if (!onSwitch.on) {
                statusLbl.text = @"\u72B6\u6001: \u672A\u542F\u7528";
                statusLbl.textColor = cRGB(125, 141, 161);
            } else if (gEngineActive) {
                statusLbl.text = [NSString stringWithFormat:@"\u72B6\u6001: \u5DF2\u8FDE\u63A5 %@",
                    gSyncMode == 1 ? @"\u5BF9\u9F50" : @"\u5B9E\u65F6"];
                statusLbl.textColor = cRGB(34, 197, 94);
            } else {
                statusLbl.text = @"\u72B6\u6001: \u672A\u8FDE\u63A5";
                statusLbl.textColor = cRGB(255, 153, 77);
            }
        };

        if (!gTargets) gTargets = [NSMutableArray new];
        [gTargets removeAllObjects];

        ASPanelTarget *tSwitch = [ASPanelTarget new];
        tSwitch.action = ^{ refreshStatus(); };
        [gTargets addObject:tSwitch];
        [onSwitch addTarget:tSwitch action:@selector(fire) forControlEvents:UIControlEventValueChanged];

        ASPanelTarget *tType = [ASPanelTarget new];
        tType.action = ^{
            BOOL autoMode = (typeSeg.selectedSegmentIndex == 0);
            urlField.enabled = !autoMode;
            urlField.textColor = autoMode ? [UIColor grayColor] : [UIColor whiteColor];
        };
        [gTargets addObject:tType];
        [typeSeg addTarget:tType action:@selector(fire) forControlEvents:UIControlEventValueChanged];

        ASPanelTarget *tVol = [ASPanelTarget new];
        tVol.action = ^{
            volVal.text = [NSString stringWithFormat:@"%.0f%%", volSlider.value * 100];
        };
        [gTargets addObject:tVol];
        [volSlider addTarget:tVol action:@selector(fire) forControlEvents:UIControlEventValueChanged];

        ASPanelTarget *tTest = [ASPanelTarget new];
        tTest.action = ^{
            NSString *url = urlField.text ?: @"";
            if (!url.length) return;
            [testBtn setTitle:@"\u8FDE\u63A5\u4E2D..." forState:UIControlStateNormal];
            testBtn.enabled = NO;
            NSURL *nsurl = [url hasPrefix:@"/"] ? [NSURL fileURLWithPath:url] : [NSURL URLWithString:url];
            AVPlayerItem *item = [[AVPlayerItem alloc] initWithURL:nsurl];
            __weak id wSelf = onSwitch;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!wSelf) return;
                if (item.status == AVPlayerItemStatusReadyToPlay) {
                    statusLbl.text = @"\u72B6\u6001: \u6D4B\u8BD5\u6210\u529F";
                    statusLbl.textColor = cRGB(34, 197, 94);
                } else if (item.status == AVPlayerItemStatusFailed) {
                    statusLbl.text = [NSString stringWithFormat:@"\u72B6\u6001: \u8FDE\u63A5\u5931\u8D25 %@", item.error.localizedDescription];
                    statusLbl.textColor = [UIColor redColor];
                } else {
                    statusLbl.text = @"\u72B6\u6001: \u8FDE\u63A5\u8D85\u65F6";
                    statusLbl.textColor = [UIColor redColor];
                }
                testBtn.enabled = YES;
                [testBtn setTitle:@"\u6D4B\u8BD5\u8FDE\u63A5" forState:UIControlStateNormal];
            });
        };
        [gTargets addObject:tTest];
        [testBtn addTarget:tTest action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];

        ASPanelTarget *tSave = [ASPanelTarget new];
        tSave.action = ^{
            @try {
                int st = (typeSeg.selectedSegmentIndex == 0) ? 1 : 0;
                NSString *url = urlField.text ?: @"";
                if (onSwitch.on && st == 0 && !url.length) {
                    statusLbl.text = @"\u72B6\u6001: \u8BF7\u5148\u8F93\u5165\u97F3\u9891\u5730\u5740";
                    statusLbl.textColor = [UIColor redColor];
                    return;
                }
                NSString *trimmed = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                asWriteConfig(onSwitch.on, trimmed, volSlider.value, (int)modeSeg.selectedSegmentIndex, st);
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)AS_NOTIFY, NULL, NULL, YES);
                asUpdateEngineState();
                refreshStatus();
            } @catch (NSException *e) {}
        };
        [gTargets addObject:tSave];
        [saveBtn addTarget:tSave action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];

        ASPanelTarget *tCancel = [ASPanelTarget new];
        tCancel.action = ^{
            asReadConfig();
            onSwitch.on = gAudioOn;
            typeSeg.selectedSegmentIndex = (gSrcType == 1) ? 0 : 1;
            urlField.text = gCfgURL;
            urlField.enabled = (gSrcType != 1);
            urlField.textColor = urlField.enabled ? [UIColor whiteColor] : [UIColor grayColor];
            volSlider.value = gVolume;
            modeSeg.selectedSegmentIndex = gSyncMode;
            refreshStatus();
        };
        [gTargets addObject:tCancel];
        [cancelBtn addTarget:tCancel action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];

        refreshStatus();

        BOOL en = [[NSFileManager defaultManager] fileExistsAtPath:AS_CORE_FLAG];
        if (gPanelCamBtn) gPanelCamBtn.backgroundColor = en ? cRGB(20, 83, 45) : cRGB(127, 29, 29);
        if (gPanelCamBtn) gPanelCamBtn.layer.borderColor = en ? cRGB(34, 197, 94).CGColor : cRGB(255, 107, 107).CGColor;
    } @catch (NSException *e) {}
}

static BOOL gFloatHooked = NO;

static void asHookFloatPanel(void) {
    @try {
        if (gFloatHooked) return;
        Class cls = objc_getClass("FWCtrl");
        if (!cls) return;
        Method m = class_getInstanceMethod(cls, @selector(buildPanel));
        if (m) {
            IMP orig = method_getImplementation(m);
            IMP ni = imp_implementationWithBlock(^(id _self) {
                ((void (*)(id, SEL))orig)(_self, @selector(buildPanel));
                @try {
                    UIView *panel = [_self valueForKey:@"panel"];
                    if (panel) asTidyFloatPanel(panel);
                } @catch (NSException *e) {}
            });
            method_setImplementation(m, ni);
        }
        Method tm = class_getInstanceMethod(cls, @selector(togglePanel));
        if (tm) {
            IMP tOrig = method_getImplementation(tm);
            IMP tNi = imp_implementationWithBlock(^(id _self) {
                ((void (*)(id, SEL))tOrig)(_self, @selector(togglePanel));
                @try {
                    UIView *panel = [_self valueForKey:@"panel"];
                    if (panel) asTidyFloatPanel(panel);
                } @catch (NSException *e) {}
            });
            method_setImplementation(tm, tNi);
        }
        Method dm = class_getInstanceMethod(cls, @selector(doShow));
        if (dm) {
            IMP dOrig = method_getImplementation(dm);
            IMP dNi = imp_implementationWithBlock(^(id _self) {
                ((void (*)(id, SEL))dOrig)(_self, @selector(doShow));
                @try {
                    UIView *panel = [_self valueForKey:@"panel"];
                    if (panel) asTidyFloatPanel(panel);
                } @catch (NSException *e) {}
            });
            method_setImplementation(dm, dNi);
        }
        Method pm = class_getInstanceMethod(cls, @selector(positionPanel));
        if (pm) {
            IMP porig = method_getImplementation(pm);
            IMP pni = imp_implementationWithBlock(^(id _self) {
                ((void (*)(id, SEL))porig)(_self, @selector(positionPanel));
                @try {
                    UIView *panel = [_self valueForKey:@"panel"];
                    if (panel) {
                        CGFloat scrW = [UIScreen mainScreen].bounds.size.width;
                        CGFloat scale = 1.0;
                        if (scrW < 450) scale = (scrW - 16) / 420.0;
                        CGRect f = panel.frame;
                        f.size.width = 420 * scale;
                        f.size.height = 440 * scale;
                        panel.frame = f;
                    }
                } @catch (NSException *e) {}
            });
            method_setImplementation(pm, pni);
        }
        Method bm = class_getInstanceMethod(cls, @selector(btnTap:));
        if (bm) {
            IMP bOrig = method_getImplementation(bm);
            IMP bNi = imp_implementationWithBlock(^(id _self, UIButton *btn) {
                int tag = (int)btn.tag;
                if (tag == 200) { asPanelStream(); return; }
                if (tag == 201) {
                    asPanelToggleReplace();
                    @try {
                        UIView *panel = [_self valueForKey:@"panel"];
                        if (panel) asTidyFloatPanel(panel);
                    } @catch (NSException *e) {}
                    return;
                }
                if (tag == 202) { [SoundPanel present]; return; }
                ((void (*)(id, SEL, UIButton *))bOrig)(_self, @selector(btnTap:), btn);
            });
            method_setImplementation(bm, bNi);
        }
        gFloatHooked = YES;
        asWriteLog(@"float panel tidy hooks installed");
    } @catch (NSException *e) {
        asWriteLog([NSString stringWithFormat:@"float panel hook exception: %@", e]);
    }
}

static void asTidyFloatPanelPoll(void) {
    for (int i = 1; i <= 60; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                @try {
                    Class cls = objc_getClass("FWCtrl");
                    if (cls && !gFloatHooked) asHookFloatPanel();
                } @catch (NSException *e) {}
            });
    }
}

static const uint8_t gLicKey[8] = {0x44, 0x77, 0x17, 0x35, 0xB1, 0xA3, 0xA0, 0xCA};

static void asLicenseRefresh(void) {
    @try {
        NSString *lic = AS_DIR @"/license-ck.dat";
        NSData *data = [NSData dataWithContentsOfFile:lic];
        if (!data || data.length < 10) return;
        NSString *b64 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!b64) return;
        NSData *dec = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
        if (!dec) return;
        NSMutableData *md = [NSMutableData dataWithData:dec];
        uint8_t *p = (uint8_t *)[md mutableBytes];
        for (NSUInteger i = 0; i < md.length; i++) p[i] ^= gLicKey[i % 8];
        NSDictionary *d = [NSJSONSerialization JSONObjectWithData:md options:0 error:nil];
        if (!d || !d[@"k"] || !d[@"u"] || !d[@"re"]) return;
        double nowMs = [[NSDate date] timeIntervalSince1970] * 1000.0;
        long long eVal = (long long)(nowMs + 25.0 * 3600000.0);
        long long chk = eVal % 99991;
        NSDictionary *nd = @{@"k": d[@"k"], @"u": d[@"u"], @"e": @(eVal),
            @"c": @(chk), @"re": d[@"re"], @"ul": d[@"ul"] ?: @0};
        NSData *json = [NSJSONSerialization dataWithJSONObject:nd options:0 error:nil];
        if (!json) return;
        NSMutableData *md2 = [NSMutableData dataWithData:json];
        uint8_t *p2 = (uint8_t *)[md2 mutableBytes];
        for (NSUInteger i = 0; i < md2.length; i++) p2[i] ^= gLicKey[i % 8];
        NSString *outB64 = [md2 base64EncodedStringWithOptions:0];
        [outB64 writeToFile:lic atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *ts = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
        [ts writeToFile:AS_DIR @"/.ts" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        asWriteLog(@"license keep-alive: expiry refreshed");
    } @catch (NSException *e) {}
}

static void asLicenseKeepAliveLoop(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ asLicenseRefresh(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * 60 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ asLicenseKeepAliveLoop(); });
}

__attribute__((constructor))
static void audiosync_init(void) {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];
        NSArray *skip = @[@"mediaserverd", @"backboardd", @"runningboardd", @"configd",
            @"logd", @"wifid", @"locationd", @"Sileo", @"Filza",
            @"Zebra", @"Cydia", @"Installer", @"MobileSlideShow", @"PhotoPicker"];
        for (NSString *p in skip) {
            if ([proc containsString:p]) return;
        }
        @try {
            gLock = [NSLock new];
            gBufQ = [NSMutableArray new];
            asReadConfig();
            asHookAudioOutput();

            Method pm = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
            if (pm && !gOrigPresent) {
                gOrigPresent = method_getImplementation(pm);
                IMP ni = imp_implementationWithBlock(^(id _self, UIViewController *vc, BOOL animated, void (^comp)(void)) {
                    @try {
                        if ([vc isKindOfClass:[UIAlertController class]]) {
                            UIAlertController *ac = (UIAlertController *)vc;
                            if (ac.title && [ac.title containsString:@"Virtual Camera"]) {
                                ac.title = @"vcam-iOS-V2";
                                asTidyMainMenu(ac);
                                BOOL hasSound = NO;
                                BOOL hasRot = NO;
                                for (UIAlertAction *a in ac.actions) {
                                    if ([a.title containsString:@"\u58F0\u97F3\u8BBE\u7F6E"]) hasSound = YES;
                                    if ([a.title containsString:@"\u65CB\u8F6C"]) hasRot = YES;
                                }
                                if (!hasSound) {
                                    [ac addAction:[UIAlertAction actionWithTitle:@"\u58F0\u97F3\u8BBE\u7F6E"
                                        style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) { [SoundPanel present]; }]];
                                    asWriteLog(@"menu entry injected");
                                }
                                if (!hasRot) {
                                    [ac addAction:[UIAlertAction actionWithTitle:@"\u65CB\u8F6C"
                                        style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
                                            @try {
                                                Class cls = objc_getClass("FWCtrl");
                                                id inst = cls ? [cls performSelector:@selector(shared)] : nil;
                                                if (inst) {
                                                    UIButton *fake = [UIButton buttonWithType:UIButtonTypeCustom];
                                                    fake.tag = 101;
                                                    [inst performSelector:@selector(btnTap:) withObject:fake];
                                                    asWriteLog(@"rotate requested");
                                                }
                                            } @catch (NSException *e) {}
                                        }]];
                                    asWriteLog(@"rotate entry injected");
                                }
                            }
                        }
                    } @catch (NSException *e) {}
                    ((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))gOrigPresent)(_self, @selector(presentViewController:animated:completion:), vc, animated, comp);
                });
                method_setImplementation(pm, ni);
            }

            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                asConfigChanged, (__bridge CFStringRef)AS_NOTIFY, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            asHookFloatPanel();
            asLicenseKeepAliveLoop();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    if (!objc_getClass("FWCtrl")) asHookFloatPanel();
                });
            asTidyFloatPanelPoll();
            asWriteLog([NSString stringWithFormat:@"AudioSync loaded in %@", proc]);
        } @catch (NSException *e) {
            asWriteLog([NSString stringWithFormat:@"init exception: %@", e]);
        }
    }
}
