#ifndef UrlEncoderObjC_h
#define UrlEncoderObjC_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
#include "UrlEncoderGW.h"
#include <memory>
#endif

@interface UrlEncoderGWObjC: NSObject {
#ifdef __cplusplus
    std::unique_ptr<UrlEncoderGW> urlEncoderGW;
#endif
}
-(id) init: (NSArray*) templates;
-(NSString*) encodeUrl: (NSString*) url;
@end

#endif /* UrlEncoderObjC */
