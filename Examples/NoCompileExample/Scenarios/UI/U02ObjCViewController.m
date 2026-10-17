//
//  U02ObjCViewController.m
//  场景 U02：ObjC 页面，viewDidLoad 里手写布局
//

#import "U02ObjCViewController.h"

@interface U02ObjCViewController ()
@property (nonatomic, strong, readwrite) UILabel *captionLabel;
@end

@implementation U02ObjCViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.captionLabel = [[UILabel alloc] init];
    self.captionLabel.text = @"U02(@@v1@@)";
    [self.view addSubview:self.captionLabel];
}

+ (NSString *)probe {
    U02ObjCViewController *controller = [[U02ObjCViewController alloc] init];
    [controller loadViewIfNeeded];
    return controller.captionLabel.text;
}

@end
