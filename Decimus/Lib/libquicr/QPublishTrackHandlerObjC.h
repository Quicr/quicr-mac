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
    kQStreamHeaderTypeSubgroupZeroNoExtensions = 0x08,          // No extensions, Subgroup ID = 0
    kQStreamHeaderTypeSubgroupZeroWithExtensions = 0x09,        // With extensions, Subgroup ID = 0
    kQStreamHeaderTypeSubgroupFirstObjectNoExtensions = 0x0A,   // No extensions, Subgroup ID = First Object ID
    kQStreamHeaderTypeSubgroupFirstObjectWithExtensions = 0x0B, // With extensions, Subgroup ID = First Object ID
    kQStreamHeaderTypeSubgroupExplicitNoExtensions = 0x0C,      // No extensions, Explicit Subgroup ID
    kQStreamHeaderTypeSubgroupExplicitWithExtensions = 0x0D,    // With extensions, Explicit Subgroup ID
};

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
