/**
 * VcamVolumeObserver.m — Volume button toggle listener.
 *
 * Monitors outputVolume via KVO on AVAudioSession.
 * Pattern: 3 rapid presses within 1.5s triggers toggle.
 */

#import "VcamVolumeObserver.h"
#import "../Shared/VcamConstants.h"
#import <AVFoundation/AVFoundation.h>

static void *kVolumeContext = &kVolumeContext;

@interface VcamVolumeObserver ()
@property (nonatomic, assign) float prevVolume;
@property (nonatomic, assign) NSInteger pressCount;
@property (nonatomic, assign) NSTimeInterval lastPressTime;
@property (nonatomic, assign) BOOL observing;
@end

@implementation VcamVolumeObserver

- (void)startObserving {
    if (self.observing) return;

    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setActive:YES error:nil];

    self.prevVolume = session.outputVolume;
    self.pressCount = 0;
    self.lastPressTime = 0;

    [session addObserver:self
              forKeyPath:@"outputVolume"
                 options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                 context:kVolumeContext];

    self.observing = YES;
    VCLog(@"VolumeObserver: started");
}

- (void)stopObserving {
    if (!self.observing) return;

    @try {
        [[AVAudioSession sharedInstance] removeObserver:self forKeyPath:@"outputVolume"];
    } @catch (NSException *e) {
        // Observer might not be registered
    }

    self.observing = NO;
    VCLog(@"VolumeObserver: stopped");
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (context != kVolumeContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    float newVolume = [change[NSKeyValueChangeNewKey] floatValue];
    float oldVolume = [change[NSKeyValueChangeOldKey] floatValue];

    if (fabsf(newVolume - oldVolume) < 0.001) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval elapsed = now - self.lastPressTime;

    if (elapsed > 1.5) {
        // Reset counter — too slow
        self.pressCount = 1;
    } else {
        self.pressCount++;
    }

    self.lastPressTime = now;
    self.prevVolume = newVolume;

    // Trigger on 3 rapid presses
    if (self.pressCount >= 3) {
        self.pressCount = 0;
        VCLog(@"VolumeObserver: toggle triggered!");
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(volumeToggleTriggered)]) {
                [self.delegate volumeToggleTriggered];
            }
        });
    }
}

- (void)dealloc {
    [self stopObserving];
}

@end
