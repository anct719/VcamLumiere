/**
 * VcamVolumeObserver.h — Volume button toggle listener.
 */

#import <Foundation/Foundation.h>

@protocol VcamVolumeObserverDelegate <NSObject>
- (void)volumeToggleTriggered;
@end

@interface VcamVolumeObserver : NSObject

@property (nonatomic, weak) id<VcamVolumeObserverDelegate> delegate;

- (void)startObserving;
- (void)stopObserving;

@end
