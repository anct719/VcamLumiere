/**
 * VcamLoginHelper.h — Login flow manager.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@protocol VcamLoginDelegate <NSObject>
- (void)loginDidSucceed;
- (void)loginDidFailWithError:(NSString *)error;
@end

@interface VcamLoginHelper : NSObject

@property (nonatomic, weak) id<VcamLoginDelegate> delegate;

- (void)doLoginWithUsername:(NSString *)username
                   password:(NSString *)password;

- (void)doLogout;

@end
