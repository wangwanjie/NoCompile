//
//  ObjCBadgeView.m
//  ObjC 自定义视图：验证"被替换的视图类所在页面会自动重建"
//

#import "ObjCBadgeView.h"

@implementation ObjCBadgeView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self buildContent];
    }
    return self;
}

- (void)buildContent {
    // 👉 改这里：修改背景色、文案并保存
    self.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.15];
    NSString *text = @"🧩 ObjCBadgeView（UIView 子类）：第 1 版";

    self.layer.cornerRadius = 14;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    UILabel *label = [UILabel new];
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    label.textColor = UIColor.labelColor;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:self.topAnchor constant:14],
        [label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-14],
    ]];
}

@end
