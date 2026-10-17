//
//  ExHeaderUser.m
//

#import <ExCore/ExHeaderUser.h>
#import <ExCore/ExMacros.h>
#import <ExCore/ExInline.h>

@implementation ExHeaderUser

+ (NSString *)macroText {
    return [NSString stringWithFormat:@"ExCore:%@", EX_HEADER_TOKEN];
}

+ (NSString *)inlineText {
    return [NSString stringWithFormat:@"ExCore:%@", ExInlineGreeting()];
}

@end
