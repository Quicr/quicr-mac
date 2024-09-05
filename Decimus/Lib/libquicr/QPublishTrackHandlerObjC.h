// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QPublishTrackHandlerObjC_h
#define QPublishTrackHandlerObjC_h

#ifdef __cplusplus
#include "QPublishTrackHandler.h"
#endif

#import <Foundation/Foundation.h>
#import "QPublishTrackHandlerCallbacks.h"
#import "QCommon.h"

typedef NS_ENUM(uint8_t, QTrackMode) {
    kQTrackModeDatagram,
    kQTrackModeStreamPerObject,
    kQTrackModeStreamPerGroup,
    kQTrackModeStreamPerTrack
};

typedef NS_ENUM(uint8_t, QPublishObjectStatus) {
    kQPublishObjectStatusOk,
    kQPublishObjectStatusInternalError,
    kQPublishObjectStatusNotAuthorized,
    kQPublishObjectStatusNotAnnounced,
    kQPublishObjectStatusNoSubscribers,
    kQPublishObjectStatusObjectPayloadLengthExceeded,
    kQPublishObjectStatusPreviousObjectTruncated,
    kQPublishObjectStatusNoPreviousObject,
    kQPublishObjectStatusObjectDataComplete,
    kQPublishObjectStatusObjectContinuationDataNeeded,
    kQPublishObjectStatusObjectDataIncomplete,
    kQPublishObjectStatusObjectDataTooLarge,
    kQPublishObjectStatusPreviousObjectNotCompleteMustStartNewGroup,
    kQPublishObjectStatusPreviousObjectNotCompleteMustStartNewTrack,
};

@interface QPublishTrackHandlerObjC : NSObject
{
#ifdef __cplusplus
@public
    std::shared_ptr<QPublishTrackHandler> handlerPtr;
#endif
}

-(id _Nonnull) initWithFullTrackName: (QFullTrackName) full_track_name trackMode: (QTrackMode) track_mode defaultPriority: (uint8_t) priority defaultTTL: (uint32_t) ttl;
-(QPublishObjectStatus)publishObject: (QObjectHeaders) objectHeaders data: (NSData* _Nonnull) data extensions: (NSDictionary<NSNumber*, NSData*>* _Nonnull) extensions;
-(QPublishObjectStatus)publishPartialObject: (QObjectHeaders) objectHeaders data: (NSData* _Nonnull) data extensions: (NSDictionary<NSNumber*, NSData*>* _Nonnull) extensions;
-(void) setCallbacks: (id<QPublishTrackHandlerCallbacks> _Nonnull) callbacks;
-(void) setDefaultPriority: (uint8_t) priority;
-(void) setDefaultTtl: (uint32_t) ttl;
-(QPublishTrackHandlerStatus) getStatus;

@end

#endif /* QPublishTrackHandlerObjC_h */
