/**
 * VcamHelper.h — Main UI coordinator.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface VcamHelper : NSObject

+ (instancetype)sharedInstance;

- (void)showFloatingButton;
- (void)hideFloatingButton;
- (void)togglePanel;
- (void)showLoginAlert;

@end
