/**
 * RTMPClient.h — RTMP stream puller using embedded librtmp.
 */

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@class H264Decoder;

@protocol RTMPClientDelegate <NSObject>
- (void)rtmpClientDidConnect:(id)client;
- (void)rtmpClientDidDisconnect:(id)client reason:(NSString *)reason;
- (void)rtmpClient:(id)client didReceiveVideoFrame:(CVPixelBufferRef)pixelBuffer;
- (void)rtmpClient:(id)client didFailWithError:(NSString *)error;
@end

@interface RTMPClient : NSObject

@property (nonatomic, weak) id<RTMPClientDelegate> delegate;
@property (nonatomic, strong, readonly) H264Decoder *decoder;
@property (nonatomic, assign, readonly) BOOL isConnected;
@property (nonatomic, assign, readonly) BOOL isRunning;

- (void)startWithRTMPURL:(NSString *)url;
- (void)stop;

@end

