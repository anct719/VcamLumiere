/**
 * VCamManager.h — Stream orchestrator and frame provider.
 */

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

@interface VCamManager : NSObject

@property (nonatomic, assign, readonly) BOOL isLive;
@property (nonatomic, assign, readonly) BOOL hasFirstFrame;
@property (atomic, assign) CVPixelBufferRef currentPixelBuffer;

+ (instancetype)sharedInstance;

- (void)startWithURL:(NSString *)url;
- (void)stop;
- (void)reloadConfig;

@end
