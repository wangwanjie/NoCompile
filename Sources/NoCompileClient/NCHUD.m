//
//  NCHUD.m
//

#if DEBUG || NOCOMPILE_FORCE_ENABLE

#import "NCHUD.h"

#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>

@interface NCHUD ()
@property (nonatomic, strong) UILabel *label;
@end

@implementation NCHUD

+ (instancetype)shared {
    static NCHUD *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [NCHUD new];
    });
    return instance;
}

+ (void)showStatus:(NSString *)message state:(NSInteger)state {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[self shared] present:message state:state];
    });
}

- (void)present:(NSString *)message state:(NSInteger)state {
    UIWindow *window = [self keyWindow];
    if (!window) {
        return;
    }
    if (!self.label) {
        UILabel *label = [UILabel new];
        label.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
        label.textColor = UIColor.whiteColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.layer.cornerRadius = 12;
        label.layer.masksToBounds = YES;
        label.userInteractionEnabled = NO;
        self.label = label;
    }
    if (self.label.superview != window) {
        [window addSubview:self.label];
    }
    [window bringSubviewToFront:self.label];

    UIColor *background;
    switch (state) {
        case 0: background = [UIColor colorWithRed:0.20 green:0.70 blue:0.35 alpha:0.95]; break; // 成功
        case 2: background = [UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:0.95]; break; // 失败
        default: background = [UIColor colorWithRed:0.90 green:0.65 blue:0.15 alpha:0.95]; break; // 进行中
    }
    self.label.backgroundColor = background;
    self.label.text = [@"⚡ " stringByAppendingString:message];

    CGFloat width = MIN(window.bounds.size.width - 40, 260);
    CGFloat top = window.safeAreaInsets.top + 8;
    self.label.frame = CGRectMake((window.bounds.size.width - width) / 2, top, width, 28);
    self.label.alpha = 1;

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismiss) object:nil];
    if (state != 1) {
        [self performSelector:@selector(dismiss) withObject:nil afterDelay:1.5];
    }
}

- (void)dismiss {
    [UIView animateWithDuration:0.3 animations:^{
        self.label.alpha = 0;
    }];
}

- (UIWindow *)keyWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) {
                    return window;
                }
            }
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            UIWindow *window = ((UIWindowScene *)scene).windows.firstObject;
            if (window) {
                return window;
            }
        }
    }
    return nil;
}

@end

#else

// macOS：暂不画浮层，状态走日志
@implementation NCHUD
+ (void)showStatus:(NSString *)message state:(NSInteger)state {}
@end

#endif

#endif
