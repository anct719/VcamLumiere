/**
 * Tweak.m — VcamLumiereDaemon main entry point.
 *
 * Injects into mediaserverd.
 * Hooks:
 * 1. AVCaptureVideoDataOutput -setSampleBufferDelegate:queue:
 * 2. AVAssetWriterInput -appendSampleBuffer:
 * 3. AVAssetWriterInputPixelBufferAdaptor -appendPixelBuffer:withPresentationTime:
 * 4. Dynamic hook on camera delegate -captureOutput:didOutputSampleBuffer:fromConnection:
 *
 * Uses MSHookMessageEx directly (no Logos/Theos).
 */

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "VCamManager.h"
#import "../Shared/VcamConstants.h"

// CydiaSubstrate
extern void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old);

#pragma mark - Original IMPs

// setSampleBufferDelegate:queue:
typedef void (*origSetDelegate_t)(id, SEL, id, dispatch_queue_t);
static origSetDelegate_t orig_setSampleBufferDelegate;

// appendSampleBuffer:
typedef BOOL (*origAppendSample_t)(id, SEL, CMSampleBufferRef);
static origAppendSample_t orig_appendSampleBuffer;

// appendPixelBuffer:withPresentationTime:
typedef BOOL (*origAppendPixel_t)(id, SEL, CVPixelBufferRef, CMTime);
static origAppendPixel_t orig_appendPixelBuffer;

// captureOutput:didOutputSampleBuffer:fromConnection:
typedef void (*origCaptureOutput_t)(id, SEL, id, CMSampleBufferRef, id);
static origCaptureOutput_t orig_captureOutput;

// Track which delegate classes we've already hooked
static NSMutableSet *hookedDelegateClasses = nil;

#pragma mark - Pixel Buffer Replacement

static CVPixelBufferRef createReplacementBuffer(CVPixelBufferRef original,
                                                 CVPixelBufferRef vcamBuffer) {
    if (!original || !vcamBuffer) return NULL;

    size_t targetW = CVPixelBufferGetWidth(original);
    size_t targetH = CVPixelBufferGetHeight(original);
    OSType targetFmt = CVPixelBufferGetPixelFormatType(original);

    size_t srcW = CVPixelBufferGetWidth(vcamBuffer);
    size_t srcH = CVPixelBufferGetHeight(vcamBuffer);
    OSType srcFmt = CVPixelBufferGetPixelFormatType(vcamBuffer);

    // If dimensions and format match, use directly
    if (srcW == targetW && srcH == targetH && srcFmt == targetFmt) {
        CVPixelBufferRetain(vcamBuffer);
        return vcamBuffer;
    }

    // Need to scale/convert using VTPixelTransferSession
    VTPixelTransferSessionRef transferSession = NULL;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &transferSession);
    if (status != noErr || !transferSession) {
        return NULL;
    }

    // Set scaling mode
    VTSessionSetProperty(transferSession,
                         kVTPixelTransferPropertyKey_ScalingMode,
                         kVTScalingMode_Trim);

    // Create destination buffer
    CVPixelBufferRef destBuffer = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferWidthKey: @(targetW),
        (id)kCVPixelBufferHeightKey: @(targetH),
        (id)kCVPixelBufferPixelFormatTypeKey: @(targetFmt),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    status = CVPixelBufferCreate(kCFAllocatorDefault,
                                  targetW, targetH, targetFmt,
                                  (__bridge CFDictionaryRef)attrs,
                                  &destBuffer);
    if (status != noErr || !destBuffer) {
        CFRelease(transferSession);
        return NULL;
    }

    // Transfer (scale + convert)
    status = VTPixelTransferSessionTransferImage(transferSession, vcamBuffer, destBuffer);
    CFRelease(transferSession);

    if (status != noErr) {
        CVPixelBufferRelease(destBuffer);
        return NULL;
    }

    // Copy color space attachments from original to destination

    NSDictionary *attachments = (__bridge NSDictionary *)CVBufferGetAttachments(
        original, kCVAttachmentMode_ShouldPropagate);
    if (attachments) {
        CVBufferSetAttachments(destBuffer,
                               (__bridge CFDictionaryRef)attachments,
                               kCVAttachmentMode_ShouldPropagate);
    }

    return destBuffer;
}

static CMSampleBufferRef createReplacementSampleBuffer(CMSampleBufferRef original,
                                                        CVPixelBufferRef newPixelBuffer) {
    if (!original || !newPixelBuffer) return NULL;

    // Create format description for new pixel buffer
    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, newPixelBuffer, &formatDesc);
    if (status != noErr) return NULL;

    // Get timing from original
    CMSampleTimingInfo timing;
    CMSampleBufferGetSampleTimingInfo(original, 0, &timing);

    // Create new sample buffer
    CMSampleBufferRef newSampleBuf = NULL;
    status = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault,
        newPixelBuffer,
        formatDesc,
        &timing,
        &newSampleBuf
    );

    CFRelease(formatDesc);

    if (status != noErr) return NULL;
    return newSampleBuf;
}

#pragma mark - Hooked: captureOutput:didOutputSampleBuffer:fromConnection:

static void hooked_captureOutput(id self, SEL _cmd,
                                  id output,
                                  CMSampleBufferRef sampleBuffer,
                                  id connection) {
    VCamManager *mgr = [VCamManager sharedInstance];

    if (!mgr.isLive || !mgr.currentPixelBuffer) {
        orig_captureOutput(self, _cmd, output, sampleBuffer, connection);
        return;
    }

    @try {
        CVPixelBufferRef origBuf = CMSampleBufferGetImageBuffer(sampleBuffer);
        CVPixelBufferRef vcamBuf = mgr.currentPixelBuffer;

        if (!origBuf || !vcamBuf) {
            orig_captureOutput(self, _cmd, output, sampleBuffer, connection);
            return;
        }

        // Create replacement pixel buffer (scaled/converted to match original)
        CVPixelBufferRef replacement = createReplacementBuffer(origBuf, vcamBuf);
        if (!replacement) {
            orig_captureOutput(self, _cmd, output, sampleBuffer, connection);
            return;
        }

        // Create replacement sample buffer
        CMSampleBufferRef newSampleBuf = createReplacementSampleBuffer(sampleBuffer, replacement);
        CVPixelBufferRelease(replacement);

        if (!newSampleBuf) {
            orig_captureOutput(self, _cmd, output, sampleBuffer, connection);
            return;
        }

        // Call original with our replaced buffer
        orig_captureOutput(self, _cmd, output, newSampleBuf, connection);
        CFRelease(newSampleBuf);

    } @catch (NSException *e) {
        VCLog(@"captureOutput hook exception: %@", e);
        orig_captureOutput(self, _cmd, output, sampleBuffer, connection);
    }
}

#pragma mark - Hooked: setSampleBufferDelegate:queue:

static void hooked_setSampleBufferDelegate(id self, SEL _cmd,
                                            id delegate,
                                            dispatch_queue_t queue) {
    if (delegate) {
        Class delegateClass = [delegate class];
        NSString *className = NSStringFromClass(delegateClass);

        VCLog(@"AVCaptureVideoDataOutput delegate: %@", className);

        @synchronized (hookedDelegateClasses) {
            if (![hookedDelegateClasses containsObject:className]) {
                SEL captureSel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);

                if ([delegateClass instancesRespondToSelector:captureSel]) {
                    MSHookMessageEx(delegateClass, captureSel,
                                    (IMP)hooked_captureOutput,
                                    (IMP *)&orig_captureOutput);
                    [hookedDelegateClasses addObject:className];
                    VCLog(@"hooked captureOutput on %@", className);
                }
            }
        }
    }

    orig_setSampleBufferDelegate(self, _cmd, delegate, queue);
}

#pragma mark - Hooked: appendSampleBuffer:

static BOOL hooked_appendSampleBuffer(id self, SEL _cmd,
                                       CMSampleBufferRef sampleBuffer) {
    VCamManager *mgr = [VCamManager sharedInstance];

    if (mgr.isLive && mgr.currentPixelBuffer) {
        CVPixelBufferRef origBuf = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (origBuf) {
            CVPixelBufferRef replacement = createReplacementBuffer(origBuf, mgr.currentPixelBuffer);
            if (replacement) {
                CMSampleBufferRef newBuf = createReplacementSampleBuffer(sampleBuffer, replacement);
                CVPixelBufferRelease(replacement);
                if (newBuf) {
                    BOOL result = orig_appendSampleBuffer(self, _cmd, newBuf);
                    CFRelease(newBuf);
                    return result;
                }
            }
        }
    }

    return orig_appendSampleBuffer(self, _cmd, sampleBuffer);
}

#pragma mark - Hooked: appendPixelBuffer:withPresentationTime:

static BOOL hooked_appendPixelBuffer(id self, SEL _cmd,
                                      CVPixelBufferRef pixelBuffer,
                                      CMTime presentationTime) {
    VCamManager *mgr = [VCamManager sharedInstance];

    if (mgr.isLive && mgr.currentPixelBuffer) {
        CVPixelBufferRef replacement = createReplacementBuffer(pixelBuffer, mgr.currentPixelBuffer);
        if (replacement) {
            BOOL result = orig_appendPixelBuffer(self, _cmd, replacement, presentationTime);
            CVPixelBufferRelease(replacement);
            return result;
        }
    }

    return orig_appendPixelBuffer(self, _cmd, pixelBuffer, presentationTime);
}

#pragma mark - Constructor

__attribute__((constructor))
static void vcam_daemon_init(void) {
    @autoreleasepool {
        NSString *process = [[NSProcessInfo processInfo] processName];
        VCLog(@"inject into %@", process);

        hookedDelegateClasses = [NSMutableSet set];

        // Hook 1: AVCaptureVideoDataOutput -setSampleBufferDelegate:queue:
        Class cls1 = objc_getClass("AVCaptureVideoDataOutput");
        if (cls1) {
            MSHookMessageEx(cls1,
                            @selector(setSampleBufferDelegate:queue:),
                            (IMP)hooked_setSampleBufferDelegate,
                            (IMP *)&orig_setSampleBufferDelegate);
            VCLog(@"hooks installed (AVCaptureVideoDataOutput)");
        }

        // Hook 2: AVAssetWriterInput -appendSampleBuffer:
        Class cls2 = objc_getClass("AVAssetWriterInput");
        if (cls2) {
            MSHookMessageEx(cls2,
                            @selector(appendSampleBuffer:),
                            (IMP)hooked_appendSampleBuffer,
                            (IMP *)&orig_appendSampleBuffer);
            VCLog(@"hooks installed (AVAssetWriterInput)");
        }

        // Hook 3: AVAssetWriterInputPixelBufferAdaptor
        Class cls3 = objc_getClass("AVAssetWriterInputPixelBufferAdaptor");
        if (cls3) {
            MSHookMessageEx(cls3,
                            @selector(appendPixelBuffer:withPresentationTime:),
                            (IMP)hooked_appendPixelBuffer,
                            (IMP *)&orig_appendPixelBuffer);
            VCLog(@"hooks installed (AVAssetWriterInputPixelBufferAdaptor)");
        }

        VCLog(@"hooks installed (AVFoundation) in %@", process);

        // Initialize manager (will load config and auto-start if enabled)
        [VCamManager sharedInstance];

        VCLog(@"VcamLumiereDaemon %@ loaded", VCAM_VERSION);
    }
}
