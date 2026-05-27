/**
 * H264Decoder.h — VideoToolbox H264 decoder.
 */

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

typedef void(^VCFrameCallback)(CVPixelBufferRef pixelBuffer, CMTime pts);

@interface H264Decoder : NSObject

@property (nonatomic, copy) VCFrameCallback onFrame;
@property (nonatomic, assign, readonly) BOOL isReady;
@property (nonatomic, assign, readonly) int width;
@property (nonatomic, assign, readonly) int height;

- (void)setupWithSPS:(NSData *)sps pps:(NSData *)pps;
- (void)decodeAVCC:(NSData *)avccData isKeyframe:(BOOL)isKeyframe timestamp:(uint32_t)ts;
- (void)invalidate;

@end
