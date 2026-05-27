/**
 * H264Decoder.m — VideoToolbox H264 hardware decoder.
 *
 * Pipeline:
 * 1. setupWithSPS:pps: → create VTDecompressionSession
 * 2. decodeAVCC:isKeyframe:timestamp: → parse AVCC NALUs, submit to VT
 * 3. vtCallback → output CVPixelBuffer via onFrame block
 */

#import "H264Decoder.h"
#import "../Shared/VcamConstants.h"
#import <VideoToolbox/VideoToolbox.h>

@implementation H264Decoder {
    VTDecompressionSessionRef _session;
    CMVideoFormatDescriptionRef _formatDesc;
}

- (void)dealloc {
    [self invalidate];
}

#pragma mark - Setup

- (void)setupWithSPS:(NSData *)sps pps:(NSData *)pps {
    [self invalidate];

    // Create format description from H264 parameter sets
    const uint8_t *paramSets[2] = {sps.bytes, pps.bytes};
    const size_t paramSetSizes[2] = {sps.length, pps.length};

    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault,
        2,                  // parameter set count
        paramSets,
        paramSetSizes,
        4,                  // NAL unit header length (AVCC = 4 bytes)
        &_formatDesc
    );

    if (status != noErr) {
        VCLog(@"H264Decoder: failed to create format desc: %d", (int)status);
        return;
    }

    // Get dimensions
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(_formatDesc);
    _width = dims.width;
    _height = dims.height;

    VCLog(@"H264Decoder: format created %dx%d", _width, _height);

    // Create decompression session
    NSDictionary *destAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferWidthKey: @(_width),
        (id)kCVPixelBufferHeightKey: @(_height),
    };

    VTDecompressionOutputCallbackRecord callbackRecord;
    callbackRecord.decompressionOutputCallback = vtCallback;
    callbackRecord.decompressionOutputRefCon = (__bridge void *)self;

    status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        _formatDesc,
        NULL,                                   // video decoder specification
        (__bridge CFDictionaryRef)destAttrs,
        &callbackRecord,
        &_session
    );

    if (status != noErr) {
        VCLog(@"H264Decoder: failed to create session: %d", (int)status);
        if (_formatDesc) { CFRelease(_formatDesc); _formatDesc = NULL; }
        return;
    }

    // Set real-time mode
    VTSessionSetProperty(_session,
                         kVTDecompressionPropertyKey_RealTime,
                         kCFBooleanTrue);

    _isReady = YES;
    VCLog(@"H264Decoder: session ready (%dx%d)", _width, _height);
}

#pragma mark - Decode

- (void)decodeAVCC:(NSData *)avccData isKeyframe:(BOOL)isKeyframe timestamp:(uint32_t)ts {
    if (!_isReady || !_session || !_formatDesc) return;
    if (!avccData || avccData.length < 5) return;

    // Create block buffer from AVCC data
    // AVCC format: [4-byte NAL size][NAL data][4-byte NAL size][NAL data]...
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        (void *)avccData.bytes,
        avccData.length,
        kCFAllocatorNull,       // don't deallocate
        NULL,
        0,
        avccData.length,
        0,
        &blockBuffer
    );

    if (status != noErr || !blockBuffer) {
        VCLog(@"H264Decoder: block buffer create failed: %d", (int)status);
        return;
    }

    // Create sample buffer
    CMSampleBufferRef sampleBuffer = NULL;
    const size_t sampleSize = avccData.length;

    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(1, 30);  // assume 30fps
    timing.presentationTimeStamp = CMTimeMake(ts, 1000);
    timing.decodeTimeStamp = kCMTimeInvalid;

    status = CMSampleBufferCreate(
        kCFAllocatorDefault,
        blockBuffer,
        true,           // data is ready
        NULL, NULL,     // no callback
        _formatDesc,
        1,              // sample count
        1,              // timing count
        &timing,
        1,              // sample size count
        &sampleSize,
        &sampleBuffer
    );

    CFRelease(blockBuffer);

    if (status != noErr || !sampleBuffer) {
        VCLog(@"H264Decoder: sample buffer create failed: %d", (int)status);
        return;
    }

    // Set keyframe attachment
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict,
                             kCMSampleAttachmentKey_DisplayImmediately,
                             isKeyframe ? kCFBooleanTrue : kCFBooleanFalse);
        CFDictionarySetValue(dict,
                             kCMSampleAttachmentKey_NotSync,
                             isKeyframe ? kCFBooleanFalse : kCFBooleanTrue);
    }

    // Decode
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    VTDecodeInfoFlags infoFlags;

    status = VTDecompressionSessionDecodeFrame(
        _session,
        sampleBuffer,
        flags,
        NULL,           // source frame refcon
        &infoFlags
    );

    CFRelease(sampleBuffer);

    if (status != noErr) {
        VCLog(@"H264Decoder: decode failed: %d (keyframe=%d)", (int)status, isKeyframe);
        if (status == kVTInvalidSessionErr) {
            VCLog(@"H264Decoder: session invalid, need re-setup");
            _isReady = NO;
        }
    }
}

#pragma mark - VT Callback

static void vtCallback(void *decompressionOutputRefCon,
                        void *sourceFrameRefCon,
                        OSStatus status,
                        VTDecodeInfoFlags infoFlags,
                        CVImageBufferRef imageBuffer,
                        CMTime presentationTimeStamp,
                        CMTime presentationDuration) {
    if (status != noErr || !imageBuffer) return;

    H264Decoder *decoder = (__bridge H264Decoder *)decompressionOutputRefCon;
    if (decoder.onFrame) {
        decoder.onFrame(imageBuffer, presentationTimeStamp);
    }
}

#pragma mark - Invalidate

- (void)invalidate {
    _isReady = NO;

    if (_session) {
        VTDecompressionSessionWaitForAsynchronousFrames(_session);
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }

    if (_formatDesc) {
        CFRelease(_formatDesc);
        _formatDesc = NULL;
    }

    VCLog(@"H264Decoder: invalidated");
}

@end
