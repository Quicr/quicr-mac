#import <Foundation/Foundation.h>

@interface SwiftInterop : NSObject

+ (BOOL)catchException:(void(^)(void))tryBlock error:(__autoreleasing NSError **)error;

@end
