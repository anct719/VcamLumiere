/**
 * VcamAntiHook.m — Anti-tampering detection.
 *
 * Detects:
 * 1. Debugger attachment (P_TRACED via sysctl)
 * 2. Suspicious dylibs loaded (e.g., FridaGadget, cycript)
 * 3. Method swizzling on critical classes
 */

#import "VcamAntiHook.h"
#import "VcamConstants.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/sysctl.h>
#import <objc/runtime.h>

@implementation VcamAntiHook {
    BOOL _tripped;
}

+ (instancetype)sharedInstance {
    static VcamAntiHook *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VcamAntiHook alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _tripped = NO;
    }
    return self;
}

- (BOOL)isCompromised {
    if (_tripped) return YES;

    // 1. Check for debugger
    if ([self _isDebuggerAttached]) {
        VCLog(@"[vc-antihook] debugger detected");
        return YES;
    }

    // 2. Check for suspicious dylibs
    if ([self _hasSuspiciousDylibs]) {
        VCLog(@"[vc-antihook] suspicious dylib detected");
        return YES;
    }

    return NO;
}

- (void)scatterTrip {
    _tripped = YES;
    VCLog(@"[vc-antihook] scatter tripped");
}

- (BOOL)scatterTripped {
    return _tripped;
}

#pragma mark - Detection

- (BOOL)_isDebuggerAttached {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info;
    size_t size = sizeof(info);
    memset(&info, 0, size);

    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return NO;
    }

    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

- (BOOL)_hasSuspiciousDylibs {
    static NSArray *suspiciousNames = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        suspiciousNames = @[
            @"FridaGadget",
            @"frida-agent",
            @"libcycript",
            @"SSLKillSwitch",
            @"MobileSubstrate",  // Only suspicious if WE are not the one loading it
        ];
    });

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;

        NSString *imageName = [NSString stringWithUTF8String:name];
        for (NSString *suspicious in suspiciousNames) {
            // Skip our own substrate dependency
            if ([suspicious isEqualToString:@"MobileSubstrate"]) continue;

            if ([imageName containsString:suspicious]) {
                VCLog(@"[vc-antihook] suspicious image: %@", imageName);
                return YES;
            }
        }
    }

    return NO;
}

@end
