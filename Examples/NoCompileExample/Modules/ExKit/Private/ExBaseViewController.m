//
//  ExBaseViewController.m
//  场景 M05：framework 内的 ObjC 基类
//

#import <ExKit/ExBaseViewController.h>

@interface ExBaseViewController ()
@property (nonatomic, strong, readwrite) UILabel *infoLabel;
@end

@implementation ExBaseViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = [self exTitle];
    self.infoLabel = [[UILabel alloc] init];
    self.infoLabel.numberOfLines = 0;
    self.infoLabel.text = [self baseDescription];
    self.infoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.infoLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.infoLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [self.infoLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.infoLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
    ]];
    [self exSetupUI];
}

- (NSString *)exTitle {
    return @"ExBase";
}

- (void)exSetupUI {
}

- (NSString *)baseDescription {
    return @"ExBase:@@v1@@";
}

@end
