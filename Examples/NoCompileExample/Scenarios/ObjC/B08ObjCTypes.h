//
//  B08ObjCTypes.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, B08Kind) {
    B08KindSong = 1,
    B08KindAlbum,
};

typedef NS_OPTIONS(NSUInteger, B08Flags) {
    B08FlagsNone = 0,
    B08FlagsHD = 1 << 0,
    B08FlagsVIP = 1 << 1,
};

@protocol B08Delegate <NSObject>
- (NSString *)handle:(B08Kind)kind;
@optional
- (NSString *)optionalHandle;
@end

@interface B08ObjCTypes : NSObject <B08Delegate>

@property (nonatomic, weak, nullable) id<B08Delegate> delegate;
@property (nonatomic, copy) NSArray<NSString *> *names;
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *scores;

+ (NSString *)probe;

@end

NS_ASSUME_NONNULL_END
