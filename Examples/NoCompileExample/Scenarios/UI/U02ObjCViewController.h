//
//  U02ObjCViewController.h
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface U02ObjCViewController : UIViewController

@property (nonatomic, strong, readonly) UILabel *captionLabel;
+ (NSString *)probe;

@end

NS_ASSUME_NONNULL_END
