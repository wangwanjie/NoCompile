//
//  ExampleCommonPrefix.h
//  场景 H04：被 PCH 引入的公共头文件。每个 ObjC 文件都隐式依赖它，
//  修改这里的宏只应影响真正用到该宏的文件
//

#ifndef ExampleCommonPrefix_h
#define ExampleCommonPrefix_h

#import <Foundation/Foundation.h>

#define EX_PREFIX_TOKEN @"@@v1@@"
#define EX_PREFIX_UNUSED_TOKEN @"unused-1"

#endif /* ExampleCommonPrefix_h */
