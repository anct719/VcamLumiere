/**
 * Tweak.m — VcamLumiereUI entry point.
 *
 * Injects into SpringBoard.
 * Initializes the floating UI after SpringBoard finishes launching.
 * Uses MSHookMessageEx directly (no Logos).
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "VcamHelper.h"
#import "../Shared/VcamConstants.h"
#import "../Shared/VcamSharedAuth.h"
#import "../Shared/VcamAntiHook.h"

// CydiaSubstrate
extern void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old);

#pragma mark - Hook SpringBoard applicationDidFinishLaunching

typedef void (*origDidFinishLaunching_t)(id, SEL, UIApplication *);
static origDidFinishLaunching_t orig_didFinishLaunching;
static dispatch_once_t uiInitializationOnce;

static void scheduleVcamUIInitialization(void) {
    dispatch_once(&uiInitializationOnce, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            VCLog(@"Initializing VcamLumiere UI...");

            if ([[VcamAntiHook sharedInstance] isCompromised]) {
                VCLog(@"[vc-antihook] compromised -> refusing to show UI");
                return;
            }

            NSDictionary *auth = [[VcamSharedAuth sharedInstance] readVerifiedAuth];
            if (auth) {
                [[VcamHelper sharedInstance] showFloatingButton];
            } else {
                [[VcamHelper sharedInstance] showLoginAlert];
            }
        });
    });
}

static void hooked_didFinishLaunching(id self, SEL _cmd, UIApplication *application) {
    // Call original first
    if (orig_didFinishLaunching) {
        orig_didFinishLaunching(self, _cmd, application);
    }

    VCLog(@"SpringBoard did finish launching");

    scheduleVcamUIInitialization();
}

#pragma mark - Constructor

__attribute__((constructor))
static void vcam_ui_init(void) {
    @autoreleasepool {
        NSString *process = [[NSProcessInfo processInfo] processName];
        VCLog(@"inject into %@", process);

        // Hook SpringBoard's applicationDidFinishLaunching:
        Class sbAppDelegate = objc_getClass("SpringBoard");
        if (sbAppDelegate) {
            MSHookMessageEx(
                sbAppDelegate,
                @selector(applicationDidFinishLaunching:),
                (IMP)hooked_didFinishLaunching,
                (IMP *)&orig_didFinishLaunching
            );
            VCLog(@"hooked SpringBoard applicationDidFinishLaunching:");
        } else {
            VCLog(@"WARNING: SpringBoard class not found!");
        }

        // Fallback for injection after applicationDidFinishLaunching: already ran.
        scheduleVcamUIInitialization();

        VCLog(@"VcamLumiereUI %@ loaded", VCAM_VERSION);
    }
}
