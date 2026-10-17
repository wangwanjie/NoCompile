//
//  ExCardCell.m
//

#import <ExKit/ExCardCell.h>

@implementation ExCardCell

+ (NSString *)reuseIdentifier {
    return @"ExCardCell";
}

- (void)configureWithTitle:(NSString *)title {
    self.textLabel.text = [NSString stringWithFormat:@"%@|ExCard:@@v1@@", title];
}

@end
