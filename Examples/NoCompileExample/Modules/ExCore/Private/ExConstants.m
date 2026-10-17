//
//  ExConstants.m
//

#import <ExCore/ExConstants.h>

// 场景 M-CONST：外部常量（数据符号）
NSString *const ExStatusToken = @"@@v1@@";

ExPoint ExPointMake(double x, double y) {
    ExPoint point = {x, y, 7};
    return point;
}

NSString *ExPlayModeName(ExPlayMode mode) {
    switch (mode) {
        case ExPlayModeSequence:
            return @"sequence";
        case ExPlayModeLoop:
            return @"loop";
        case ExPlayModeShuffle:
            return @"shuffle";
    }
    return @"unknown";
}
