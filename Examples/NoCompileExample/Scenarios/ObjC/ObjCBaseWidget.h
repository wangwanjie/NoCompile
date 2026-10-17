//
//  ObjCBaseWidget.h
//  供 Swift 子类继承的 ObjC 基类（场景 A15）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCBaseWidget : NSObject

- (NSString *)title;
- (NSString *)renderBody;

@end

NS_ASSUME_NONNULL_END
