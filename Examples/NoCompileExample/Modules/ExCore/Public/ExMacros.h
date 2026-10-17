//
//  ExMacros.h
//  宏定义头文件：场景 H01（宏变更 → 引用方重编）
//

#ifndef ExMacros_h
#define ExMacros_h

/// 被 ExHeaderUser.m（本模块）和 App 里的 HeaderUserApp.m 同时使用
#define EX_HEADER_TOKEN @"@@v1@@"

#define EX_SAFE_STRING(s) ((s) ?: @"")

#endif /* ExMacros_h */
