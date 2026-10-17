//
//  ExBadgeLabel.m
//

#import <ExKit/ExBadgeLabel.h>

@implementation ExBadgeLabel

- (NSString *)renderedText {
    return [NSString stringWithFormat:@"%@|ExBadge:@@v1@@", self.text ?: @""];
}

- (void)drawRect:(CGRect)rect {
    [[UIColor systemOrangeColor] setFill];
    UIRectFill(rect);
    [[self renderedText] drawInRect:rect withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12]}];
}

@end
