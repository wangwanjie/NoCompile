//
//  H03Enums.h
//  场景 H03：枚举值 / 常量宏的变化需要重编所有使用方
//

#ifndef H03Enums_h
#define H03Enums_h

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, H03Kind) {
    H03KindA = 1,
    H03KindB = 2,
};

#define H03_LIMIT 100

#endif /* H03Enums_h */
