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

typedef NS_ENUM(uint8_t, QStreamHeaderType) {
    kSubgroup0NotEndOfGroupNoExtensions = 0x10,
    kSubgroup0NotEndOfGroupWithExtensions = 0x11,
    kSubgroupFirstObjectNotEndOfGroupNoExtensions = 0x12,
    kSubgroupFirstObjectNotEndOfGroupWithExtensions = 0x13,
    kSubgroupExplicitNotEndOfGroupNoExtensions = 0x14,
    kSubgroupExplicitNotEndOfGroupWithExtensions = 0x15,
    kSubgroup0EndOfGroupNoExtensions = 0x18,
    kSubgroup0EndOfGroupWithExtensions = 0x19,
    kSubgroupFirstObjectEndOfGroupNoExtensions = 0x1A,
    kSubgroupFirstObjectEndOfGroupWithExtensions = 0x1B,
    kSubgroupExplicitEndOfGroupNoExtensions = 0x1C,
    kSubgroupExplicitEndOfGroupWithExtensions = 0x1D
};

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
-(QPublishObjectStatus)publishObject: (QObjectHeaders) objectHeaders data: (NSData* _Nonnull) data extensions: (NSDictionary<NSNumber*, NSData*>* _Nullable) extensions;
-(QPublishObjectStatus)publishPartialObject: (QObjectHeaders) objectHeaders data: (NSData* _Nonnull) data extensions: (NSDictionary<NSNumber*, NSData*>* _Nullable) extensions;
-(void) setCallbacks: (id<QPublishTrackHandlerCallbacks> _Nonnull) callbacks;
-(void) setDefaultPriority: (uint8_t) priority;
-(void) setDefaultTtl: (uint32_t) ttl;
-(void) setDefaultTrackMode: (QTrackMode) trackMode;
-(QPublishTrackHandlerStatus) getStatus;
-(QStreamHeaderType) getStreamMode;

@end

#endif /* QPublishTrackHandlerObjC_h */
