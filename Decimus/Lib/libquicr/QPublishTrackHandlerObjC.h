// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QPublishTrackHandlerObjC_h
#define QPublishTrackHandlerObjC_h

#ifdef __cplusplus
#include "QPublishTrackHandler.h"
#endif

#import <Foundation/Foundation.h>
#import "QFullTrackName.h"
#import "QPublishTrackHandlerCallbacks.h"
#import "QCommon.h"

typedef NS_ENUM(uint8_t, QTrackMode) {
    kDatagram,
    kStream,
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
    kQPublishObjectStatusPaused
};

@interface QPublishTrackHandlerObjC : NSObject
{
#ifdef __cplusplus
@public
    std::shared_ptr<QPublishTrackHandler> handlerPtr;
#endif
}

-(id _Nonnull) initWithFullTrackName: (id<QFullTrackName> _Nonnull) full_track_name trackMode: (QTrackMode) track_mode defaultPriority: (uint8_t) priority defaultTTL: (uint32_t) ttl;
-(id<QFullTrackName> _Nonnull) getFullTrackName;
-(QPublishObjectStatus)publishObject: (QObjectHeaders) objectHeaders
                                data: (NSData* _Nonnull) data
                          extensions: (NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable) extensions
                 immutableExtensions: (NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable) immutableExtensions
              streamHeaderProperties: (QStreamHeaderProperties* _Nullable) streamHeaderProperties;
-(QPublishObjectStatus)publishPartialObject: (QObjectHeaders) objectHeaders
                                       data: (NSData* _Nonnull) data
                                 extensions: (NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable) extensions
                        immutableExtensions: (NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable) immutableExtensions;
-(void) endSubgroup: (uint64_t) groupId
         subgroupId: (uint64_t) subgroupId
          completed: (bool) completed;
-(void) setCallbacks: (id<QPublishTrackHandlerCallbacks> _Nonnull) callbacks;
-(void) setDefaultPriority: (uint8_t) priority;
-(void) setDefaultTtl: (uint32_t) ttl;
-(void) setDefaultTrackMode: (QTrackMode) trackMode;
-(QPublishTrackHandlerStatus) getStatus;
-(bool) canPublish;
-(QStreamHeaderProperties* _Nullable) getStreamMode;

@end

#endif /* QPublishTrackHandlerObjC_h */
