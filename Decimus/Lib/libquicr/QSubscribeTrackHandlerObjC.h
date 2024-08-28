#ifndef QSubscribeTrackHandlerObjC_h
#define QSubscribeTrackHandlerObjC_h

#ifdef __cplusplus
#include "QSubscribeTrackHandler.h"
#endif

#import <Foundation/Foundation.h>

@protocol QSubscribeTrackHandlerCallbacks
- (int) statusChanged: (int) status;
- (void) objectReceivedData: (uint8_t *) data length: (size_t) length;
@end

typedef struct SubFullTrackName
{
    NSString *nameSpace;
    NSString *name;
} SubFullTrackName;

@interface QSubscribeTrackHandlerObjC : NSObject
{
#ifdef __cplusplus
    std::shared_ptr<QSubscribeTrackHandler> handlerPtr;
#endif
}

-(id) initWithFullTrackName: (SubFullTrackName) full_track_name;

-(void)setCallbacks: (id<QSubscribeTrackHandlerCallbacks>) callbacks;

@end

#endif /* QSubscribeTrackHandlerObjC_h */
