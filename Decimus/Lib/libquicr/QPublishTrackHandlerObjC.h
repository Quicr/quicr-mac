#ifndef QPublishTrackHandlerObjC_h
#define QPublishTrackHandlerObjC_h

#ifdef __cplusplus
#include "QPublishTrackHandler.h"
#endif

#import <Foundation/Foundation.h>
#import "QPublishTrackHandlerCallbacks.h"
#import "QCommon.h"

typedef struct QObjectHeaders {
    uint64_t groupId;
    uint64_t objectId;
    uint64_t payloadLength;
    uint8_t priority;
    uint16_t ttl;
    // TODO: Headers.
} QObjectHeaders;

typedef NS_ENUM(uint8_t, QTrackMode) {
    kDatagram,
    kStreamPerObject,
    skStreamPerGroup,
    kStreamPerTrack
};

@interface QPublishTrackHandlerObjC : NSObject
{
#ifdef __cplusplus
@public
    std::shared_ptr<QPublishTrackHandler> handlerPtr;
#endif
}

-(id _Nonnull) initWithFullTrackName: (QFullTrackName) full_track_name trackMode: (QTrackMode) track_mode defaultPriority: (uint8_t) priority defaultTTL: (uint32_t) ttl;
-(int)publishObject: (QObjectHeaders) objectHeaders data: (NSData* _Nonnull) data;
-(void)setCallbacks: (id<QPublishTrackHandlerCallbacks> _Nonnull) callbacks;

@end

#endif /* QPublishTrackHandlerObjC_h */
