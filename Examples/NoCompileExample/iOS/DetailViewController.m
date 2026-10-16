//
//  DetailViewController.m
//  ObjC 视图控制器：验证 ObjC 页面的热重载
//

#import "DetailViewController.h"

@implementation DetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Objective-C 页面";

    // 👉 改这里：修改背景色、标题、正文并保存，本页面会自动重建
    self.view.backgroundColor = UIColor.systemTealColor;
    NSString *headline = @"这是 ObjC 写的页面";
    NSString *body = @"修改 DetailViewController.m 中 viewDidLoad 的任意代码并保存，"
                     @"停留在本页即可看到变化，无需返回或重启。";

    UILabel *title = [UILabel new];
    title.text = headline;
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.numberOfLines = 0;

    UILabel *content = [UILabel new];
    content.text = body;
    content.font = [UIFont systemFontOfSize:16];
    content.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    content.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, content]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

@end
