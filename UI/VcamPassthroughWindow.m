/**
 * VcamPassthroughWindow.m — Touch-passthrough UIWindow.
 *
 * Only accepts touches on subviews (floating button, settings panel).
 * All other touches pass through to underlying app.
 */

#import "VcamPassthroughWindow.h"

@implementation VcamPassthroughWindow

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    // Only accept touches that hit a subview
    for (UIView *subview in self.subviews) {
        if (!subview.hidden && subview.alpha > 0.01 && subview.userInteractionEnabled) {
            CGPoint subPoint = [subview convertPoint:point fromView:self];
            if ([subview pointInside:subPoint withEvent:event]) {
                return YES;
            }
        }
    }
    return NO;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = NO;
    }
    return self;
}

@end
