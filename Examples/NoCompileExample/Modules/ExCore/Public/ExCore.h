//
//  ExCore.h
//  ExCore 伞头文件（仿 KuGou 的 KGSafeKit / KGCommontools：ObjC + C 的基础库，以动态 framework 形式集成）
//

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT double ExCoreVersionNumber;
FOUNDATION_EXPORT const unsigned char ExCoreVersionString[];

#import <ExCore/ExConstants.h>
#import <ExCore/ExMacros.h>
#import <ExCore/ExInline.h>
#import <ExCore/ExMath.h>
#import <ExCore/ExLogger.h>
#import <ExCore/ExEventBus.h>
#import <ExCore/ExMediator.h>
#import <ExCore/ExSwizzleTarget.h>
#import <ExCore/NSArray+ExSafe.h>
#import <ExCore/NSString+ExPath.h>
#import <ExCore/ExHeaderUser.h>
